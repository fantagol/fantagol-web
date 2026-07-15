-- ============================================================================
-- FANTAGOL
-- Migration 024: Prediction Workspace and Official Submission Snapshot
--
-- Workspace:
--   current values in predictions, autosaved and private.
-- Official submission:
--   prediction_versions row referenced by predictions.submitted_version.
--
-- Rules:
-- - first complete workspace may be auto-submitted at lock;
-- - after an official submission, unconfirmed workspace edits never replace it;
-- - Reinvia explicitly promotes the current complete workspace;
-- - lock restores and locks the latest official submitted version.
-- ============================================================================

begin;

alter table public.predictions
  add column if not exists submitted_version integer null,
  add column if not exists official_submitted_at timestamptz null;

alter table public.predictions
  drop constraint if exists predictions_submitted_version_positive_check;

alter table public.predictions
  add constraint predictions_submitted_version_positive_check
  check (submitted_version is null or submitted_version > 0);

create index if not exists predictions_submitted_version_idx
  on public.predictions (league_round_id, league_member_id, submitted_version);

-- Existing submitted/locked rows become the initial official snapshot.
update public.predictions
set
  submitted_version = coalesce(submitted_version, version),
  official_submitted_at = coalesce(official_submitted_at, submitted_at, updated_at)
where status in ('submitted', 'locked')
  and submitted_version is null;

-- --------------------------------------------------------------------------
-- Save workspace draft
-- --------------------------------------------------------------------------
create or replace function public.save_prediction_draft_rpc(
  p_league_round_id uuid,
  p_match_id uuid,
  p_home_prediction integer,
  p_away_prediction integer
)
returns table (
  prediction_id uuid,
  league_round_id uuid,
  league_member_id uuid,
  match_id uuid,
  home_prediction integer,
  away_prediction integer,
  prediction_status text,
  prediction_version integer,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path to public, pg_temp
as $function$
declare
  v_user_id uuid;
  v_league_id uuid;
  v_fantagol_round_id uuid;
  v_league_round_status text;
  v_league_round_enabled boolean;
  v_round_opens_at timestamptz;
  v_round_lock_at timestamptz;
  v_member_id uuid;
  v_prediction public.predictions%rowtype;
  v_previous_status text;
  v_previous_version integer;
  v_operation text;
  v_now timestamptz := clock_timestamp();
begin
  v_user_id := auth.uid();

  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTHENTICATION_REQUIRED';
  end if;

  if p_league_round_id is null or p_match_id is null then
    raise exception using errcode = 'P0001', message = 'PREDICTION_TARGET_REQUIRED';
  end if;

  if p_home_prediction is null or p_away_prediction is null
     or p_home_prediction < 0 or p_home_prediction > 9
     or p_away_prediction < 0 or p_away_prediction > 9 then
    raise exception using errcode = 'P0001', message = 'PREDICTION_SCORE_INVALID';
  end if;

  select lr.league_id, lr.fantagol_round_id, lr.status, lr.enabled,
         fr.opens_at, fr.lock_at
  into v_league_id, v_fantagol_round_id, v_league_round_status,
       v_league_round_enabled, v_round_opens_at, v_round_lock_at
  from public.league_rounds lr
  join public.fantagol_rounds fr on fr.id = lr.fantagol_round_id
  where lr.id = p_league_round_id
  for update of lr;

  if not found then
    raise exception using errcode = 'P0001', message = 'LEAGUE_ROUND_NOT_FOUND';
  end if;

  if not v_league_round_enabled then
    raise exception using errcode = 'P0001', message = 'LEAGUE_ROUND_DISABLED';
  end if;

  if v_league_round_status <> 'predictions_open' or v_now < v_round_opens_at then
    raise exception using errcode = 'P0001', message = 'PREDICTION_WINDOW_NOT_OPEN';
  end if;

  if v_now >= v_round_lock_at then
    raise exception using errcode = 'P0001', message = 'PREDICTION_WINDOW_CLOSED';
  end if;

  select lm.id
  into v_member_id
  from public.league_members lm
  where lm.league_id = v_league_id
    and lm.user_id = v_user_id
    and lm.status = 'active'
  limit 1;

  if v_member_id is null then
    raise exception using errcode = 'P0001', message = 'ACTIVE_LEAGUE_MEMBERSHIP_REQUIRED';
  end if;

  if not exists (
    select 1
    from public.fantagol_round_matches frm
    where frm.fantagol_round_id = v_fantagol_round_id
      and frm.match_id = p_match_id
      and frm.removed_at is null
  ) then
    raise exception using errcode = 'P0001', message = 'MATCH_NOT_IN_LEAGUE_ROUND';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(
      p_league_round_id::text || ':' || v_member_id::text || ':' || p_match_id::text,
      0
    )
  );

  select p.*
  into v_prediction
  from public.predictions p
  where p.league_round_id = p_league_round_id
    and p.league_member_id = v_member_id
    and p.match_id = p_match_id
  for update;

  if found then
    if v_prediction.status in ('locked', 'void') then
      raise exception using errcode = 'P0001', message = 'PREDICTION_NOT_EDITABLE';
    end if;

    if v_prediction.home_prediction = p_home_prediction
       and v_prediction.away_prediction = p_away_prediction then
      return query
      select v_prediction.id, v_prediction.league_round_id,
             v_prediction.league_member_id, v_prediction.match_id,
             v_prediction.home_prediction, v_prediction.away_prediction,
             v_prediction.status, v_prediction.version, v_prediction.updated_at;
      return;
    end if;

    v_previous_status := v_prediction.status;
    v_previous_version := v_prediction.version;
    v_operation := 'update';

    update public.predictions p
    set
      home_prediction = p_home_prediction,
      away_prediction = p_away_prediction,
      status = 'draft',
      submitted_at = null,
      updated_at = v_now,
      version = p.version + 1
    where p.id = v_prediction.id
    returning p.* into v_prediction;
  else
    v_previous_status := null;
    v_previous_version := null;
    v_operation := 'insert';

    insert into public.predictions (
      league_id, user_id, match_id, home_prediction, away_prediction,
      league_round_id, league_member_id, status, submitted_at, locked_at,
      source, version, created_at, updated_at, submitted_version,
      official_submitted_at
    )
    values (
      v_league_id, v_user_id, p_match_id, p_home_prediction, p_away_prediction,
      p_league_round_id, v_member_id, 'draft', null, null,
      'standard', 1, v_now, v_now, null, null
    )
    returning * into v_prediction;
  end if;

  insert into public.prediction_versions (
    prediction_id, version, home_prediction, away_prediction, status, source,
    changed_by_user_id, changed_by_member_id, changed_at, metadata
  )
  values (
    v_prediction.id, v_prediction.version, v_prediction.home_prediction,
    v_prediction.away_prediction, v_prediction.status, v_prediction.source,
    v_user_id, v_member_id, v_now,
    jsonb_build_object(
      'command', 'SavePredictionDraft',
      'reason', 'workspace_save',
      'operation', v_operation,
      'league_id', v_league_id,
      'league_round_id', p_league_round_id,
      'match_id', p_match_id,
      'previous_status', v_previous_status,
      'new_status', v_prediction.status,
      'previous_version', v_previous_version,
      'new_version', v_prediction.version,
      'official_submitted_version', v_prediction.submitted_version
    )
  );

  return query
  select v_prediction.id, v_prediction.league_round_id,
         v_prediction.league_member_id, v_prediction.match_id,
         v_prediction.home_prediction, v_prediction.away_prediction,
         v_prediction.status, v_prediction.version, v_prediction.updated_at;
end;
$function$;

comment on function public.save_prediction_draft_rpc(uuid, uuid, integer, integer)
is 'Autosaves one private workspace prediction. Edits after submission remain unconfirmed until an explicit resubmit.';

revoke all on function public.save_prediction_draft_rpc(uuid, uuid, integer, integer) from public;
revoke all on function public.save_prediction_draft_rpc(uuid, uuid, integer, integer) from anon;
revoke all on function public.save_prediction_draft_rpc(uuid, uuid, integer, integer) from service_role;
grant execute on function public.save_prediction_draft_rpc(uuid, uuid, integer, integer) to authenticated;

-- --------------------------------------------------------------------------
-- Submit or resubmit complete workspace
-- --------------------------------------------------------------------------
create or replace function public.submit_round_predictions_rpc(
  p_league_round_id uuid
)
returns table (
  league_round_id uuid,
  league_member_id uuid,
  required_prediction_count integer,
  submitted_prediction_count integer,
  already_submitted boolean,
  submitted_at timestamptz
)
language plpgsql
security definer
set search_path to public, pg_temp
as $function$
declare
  v_user_id uuid;
  v_league_id uuid;
  v_fantagol_round_id uuid;
  v_round_status text;
  v_round_enabled boolean;
  v_opens_at timestamptz;
  v_lock_at timestamptz;
  v_member_id uuid;
  v_required_count integer;
  v_present_count integer;
  v_invalid_count integer;
  v_unconfirmed_count integer;
  v_submitted_at timestamptz;
  v_now timestamptz := clock_timestamp();
begin
  v_user_id := auth.uid();

  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTHENTICATION_REQUIRED';
  end if;

  select lr.league_id, lr.fantagol_round_id, lr.status, lr.enabled,
         fr.opens_at, fr.lock_at
  into v_league_id, v_fantagol_round_id, v_round_status, v_round_enabled,
       v_opens_at, v_lock_at
  from public.league_rounds lr
  join public.fantagol_rounds fr on fr.id = lr.fantagol_round_id
  where lr.id = p_league_round_id
  for update of lr;

  if not found then
    raise exception using errcode = 'P0001', message = 'LEAGUE_ROUND_NOT_FOUND';
  end if;

  if not v_round_enabled then
    raise exception using errcode = 'P0001', message = 'LEAGUE_ROUND_DISABLED';
  end if;

  if v_round_status <> 'predictions_open' or v_now < v_opens_at then
    raise exception using errcode = 'P0001', message = 'PREDICTION_WINDOW_NOT_OPEN';
  end if;

  if v_now >= v_lock_at then
    raise exception using errcode = 'P0001', message = 'PREDICTION_WINDOW_CLOSED';
  end if;

  select lm.id into v_member_id
  from public.league_members lm
  where lm.league_id = v_league_id
    and lm.user_id = v_user_id
    and lm.status = 'active'
  limit 1;

  if v_member_id is null then
    raise exception using errcode = 'P0001', message = 'ACTIVE_LEAGUE_MEMBERSHIP_REQUIRED';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('submit:' || p_league_round_id::text || ':' || v_member_id::text, 0)
  );

  select count(*)::integer into v_required_count
  from public.fantagol_round_matches frm
  where frm.fantagol_round_id = v_fantagol_round_id
    and frm.removed_at is null
    and frm.required;

  perform 1
  from public.predictions p
  where p.league_round_id = p_league_round_id
    and p.league_member_id = v_member_id
  for update;

  select
    count(*) filter (where frm.match_id is not null)::integer,
    count(*) filter (
      where frm.match_id is null or p.status in ('locked', 'void')
    )::integer,
    count(*) filter (
      where p.submitted_version is null
         or p.submitted_version <> p.version
         or p.status <> 'submitted'
    )::integer
  into v_present_count, v_invalid_count, v_unconfirmed_count
  from public.predictions p
  left join public.fantagol_round_matches frm
    on frm.fantagol_round_id = v_fantagol_round_id
   and frm.match_id = p.match_id
   and frm.removed_at is null
   and frm.required
  where p.league_round_id = p_league_round_id
    and p.league_member_id = v_member_id;

  if v_invalid_count > 0 then
    raise exception using errcode = 'P0001', message = 'ROUND_PREDICTION_SET_INVALID';
  end if;

  if v_present_count <> v_required_count then
    raise exception using
      errcode = 'P0001',
      message = 'ROUND_PREDICTIONS_INCOMPLETE',
      detail = format('required=%s present=%s', v_required_count, v_present_count);
  end if;

  if v_unconfirmed_count = 0 then
    select min(p.official_submitted_at)
    into v_submitted_at
    from public.predictions p
    where p.league_round_id = p_league_round_id
      and p.league_member_id = v_member_id;

    return query
    select p_league_round_id, v_member_id, v_required_count,
           v_required_count, true, v_submitted_at;
    return;
  end if;

  with changed as (
    update public.predictions p
    set
      status = 'submitted',
      submitted_at = v_now,
      official_submitted_at = v_now,
      updated_at = v_now,
      version = p.version + 1,
      submitted_version = p.version + 1
    where p.league_round_id = p_league_round_id
      and p.league_member_id = v_member_id
    returning p.*
  )
  insert into public.prediction_versions (
    prediction_id, version, home_prediction, away_prediction, status, source,
    changed_by_user_id, changed_by_member_id, changed_at, metadata
  )
  select
    c.id, c.version, c.home_prediction, c.away_prediction, c.status, c.source,
    v_user_id, v_member_id, v_now,
    jsonb_build_object(
      'command', 'SubmitRoundPredictions',
      'reason', case when c.submitted_version = 2 then 'initial_submit' else 'resubmit' end,
      'operation', 'official_snapshot',
      'league_id', v_league_id,
      'league_round_id', p_league_round_id,
      'match_id', c.match_id,
      'new_status', 'submitted',
      'official_submitted_version', c.submitted_version
    )
  from changed c;

  return query
  select p_league_round_id, v_member_id, v_required_count,
         v_required_count, false, v_now;
end;
$function$;

comment on function public.submit_round_predictions_rpc(uuid)
is 'Atomically promotes the complete current workspace to the official submitted snapshot.';

revoke all on function public.submit_round_predictions_rpc(uuid) from public;
revoke all on function public.submit_round_predictions_rpc(uuid) from anon;
revoke all on function public.submit_round_predictions_rpc(uuid) from service_role;
grant execute on function public.submit_round_predictions_rpc(uuid) to authenticated;

-- --------------------------------------------------------------------------
-- Lock: preserve official snapshot; only first never-submitted complete set
-- may be auto-submitted.
-- Return type changes, so recreate.
-- --------------------------------------------------------------------------
drop function if exists public.lock_round_predictions_rpc(uuid);

create function public.lock_round_predictions_rpc(
  p_league_round_id uuid
)
returns table (
  league_round_id uuid,
  locked_prediction_count integer,
  auto_submitted_prediction_count integer,
  restored_official_prediction_count integer,
  voided_draft_count integer,
  already_locked boolean,
  locked_at timestamptz
)
language plpgsql
security definer
set search_path to public, pg_temp
as $function$
declare
  v_league_id uuid;
  v_fantagol_round_id uuid;
  v_round_status text;
  v_round_enabled boolean;
  v_lock_at timestamptz;
  v_required_count integer;
  v_auto_count integer := 0;
  v_restored_count integer := 0;
  v_locked_count integer := 0;
  v_void_count integer := 0;
  v_now timestamptz := clock_timestamp();
begin
  select lr.league_id, lr.fantagol_round_id, lr.status, lr.enabled, fr.lock_at
  into v_league_id, v_fantagol_round_id, v_round_status, v_round_enabled, v_lock_at
  from public.league_rounds lr
  join public.fantagol_rounds fr on fr.id = lr.fantagol_round_id
  where lr.id = p_league_round_id
  for update of lr;

  if not found then
    raise exception using errcode = 'P0001', message = 'LEAGUE_ROUND_NOT_FOUND';
  end if;

  if not v_round_enabled then
    raise exception using errcode = 'P0001', message = 'LEAGUE_ROUND_DISABLED';
  end if;

  if v_now < v_lock_at then
    raise exception using errcode = 'P0001', message = 'ROUND_LOCK_TIME_NOT_REACHED';
  end if;

  if v_round_status in (
    'predictions_locked','live','waiting_postponed','final_calculable',
    'scoring','official','recalculated','archived'
  ) then
    return query
    select p_league_round_id,
           count(*) filter (where p.status = 'locked')::integer,
           0, 0,
           count(*) filter (where p.status = 'void')::integer,
           true, v_lock_at
    from public.predictions p
    where p.league_round_id = p_league_round_id;
    return;
  end if;

  if v_round_status <> 'predictions_open' then
    raise exception using errcode = 'P0001', message = 'LEAGUE_ROUND_NOT_LOCKABLE';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('lock:' || p_league_round_id::text, 0));

  select count(*)::integer into v_required_count
  from public.fantagol_round_matches frm
  where frm.fantagol_round_id = v_fantagol_round_id
    and frm.removed_at is null
    and frm.required;

  perform 1
  from public.predictions p
  where p.league_round_id = p_league_round_id
  for update;

  -- First submission protection: complete workspace with no prior official
  -- snapshot is promoted automatically.
  with never_submitted_complete_members as (
    select p.league_member_id
    from public.predictions p
    join public.fantagol_round_matches frm
      on frm.fantagol_round_id = v_fantagol_round_id
     and frm.match_id = p.match_id
     and frm.removed_at is null
     and frm.required
    where p.league_round_id = p_league_round_id
    group by p.league_member_id
    having count(distinct p.match_id) = v_required_count
       and count(p.submitted_version) = 0
  ),
  changed as (
    update public.predictions p
    set status = 'submitted',
        submitted_at = v_now,
        official_submitted_at = v_now,
        updated_at = v_now,
        version = p.version + 1,
        submitted_version = p.version + 1
    where p.league_round_id = p_league_round_id
      and p.league_member_id in (
        select league_member_id from never_submitted_complete_members
      )
    returning p.*
  ),
  versioned as (
    insert into public.prediction_versions (
      prediction_id, version, home_prediction, away_prediction, status, source,
      changed_by_user_id, changed_by_member_id, changed_at, metadata
    )
    select
      c.id, c.version, c.home_prediction, c.away_prediction, c.status, c.source,
      null, c.league_member_id, v_now,
      jsonb_build_object(
        'command','LockRoundPredictions',
        'reason','auto_submit_first_complete_workspace_at_lock',
        'operation','official_snapshot',
        'league_id',v_league_id,
        'league_round_id',p_league_round_id,
        'match_id',c.match_id,
        'official_submitted_version',c.submitted_version
      )
    from changed c
    returning 1
  )
  select count(*)::integer into v_auto_count from versioned;

  -- Restore every existing official snapshot, discarding unconfirmed workspace
  -- experiments, and lock the official values.
  with official_members as (
    select p.league_member_id
    from public.predictions p
    join public.fantagol_round_matches frm
      on frm.fantagol_round_id = v_fantagol_round_id
     and frm.match_id = p.match_id
     and frm.removed_at is null
     and frm.required
    where p.league_round_id = p_league_round_id
    group by p.league_member_id
    having count(distinct p.match_id) = v_required_count
       and count(p.submitted_version) = v_required_count
  ),
  changed as (
    update public.predictions p
    set
      home_prediction = pv.home_prediction,
      away_prediction = pv.away_prediction,
      status = 'locked',
      submitted_at = p.official_submitted_at,
      locked_at = v_now,
      updated_at = v_now,
      version = p.version + 1
    from public.prediction_versions pv
    where p.league_round_id = p_league_round_id
      and p.league_member_id in (select league_member_id from official_members)
      and pv.prediction_id = p.id
      and pv.version = p.submitted_version
    returning p.*, pv.home_prediction as official_home, pv.away_prediction as official_away
  ),
  versioned as (
    insert into public.prediction_versions (
      prediction_id, version, home_prediction, away_prediction, status, source,
      changed_by_user_id, changed_by_member_id, changed_at, metadata
    )
    select
      c.id, c.version, c.home_prediction, c.away_prediction, c.status, c.source,
      null, c.league_member_id, v_now,
      jsonb_build_object(
        'command','LockRoundPredictions',
        'reason','official_snapshot_locked',
        'operation','restore_and_lock',
        'league_id',v_league_id,
        'league_round_id',p_league_round_id,
        'match_id',c.match_id,
        'official_submitted_version',c.submitted_version
      )
    from changed c
    returning 1
  )
  select count(*)::integer into v_locked_count from versioned;

  v_restored_count := v_locked_count;

  -- Rows without a complete official set are invalid.
  with changed as (
    update public.predictions p
    set status = 'void', locked_at = v_now, updated_at = v_now,
        version = p.version + 1
    where p.league_round_id = p_league_round_id
      and p.status <> 'locked'
    returning p.*
  ),
  versioned as (
    insert into public.prediction_versions (
      prediction_id, version, home_prediction, away_prediction, status, source,
      changed_by_user_id, changed_by_member_id, changed_at, metadata
    )
    select
      c.id, c.version, c.home_prediction, c.away_prediction, c.status, c.source,
      null, c.league_member_id, v_now,
      jsonb_build_object(
        'command','LockRoundPredictions',
        'reason','incomplete_workspace_voided_at_lock',
        'operation','status_transition',
        'league_id',v_league_id,
        'league_round_id',p_league_round_id,
        'match_id',c.match_id
      )
    from changed c
    returning 1
  )
  select count(*)::integer into v_void_count from versioned;

  update public.league_rounds
  set status = 'predictions_locked', updated_at = v_now, version = version + 1
  where id = p_league_round_id;

  return query
  select p_league_round_id, v_locked_count, v_auto_count,
         v_restored_count, v_void_count, false, v_now;
end;
$function$;

comment on function public.lock_round_predictions_rpc(uuid)
is 'Locks the latest official submitted snapshot. Unconfirmed post-submit workspace edits are discarded; only a first never-submitted complete workspace may be auto-submitted.';

revoke all on function public.lock_round_predictions_rpc(uuid) from public;
revoke all on function public.lock_round_predictions_rpc(uuid) from anon;
revoke all on function public.lock_round_predictions_rpc(uuid) from authenticated;
grant execute on function public.lock_round_predictions_rpc(uuid) to service_role;

-- --------------------------------------------------------------------------
-- Query: expose workspace and official snapshot state.
-- Return type changes, so recreate.
-- --------------------------------------------------------------------------
drop function if exists public.get_my_round_predictions_rpc(uuid);

create function public.get_my_round_predictions_rpc(
  p_league_round_id uuid
)
returns table (
  league_round_id uuid, league_id uuid, league_round_number integer,
  league_round_status text, league_round_enabled boolean,
  fantagol_round_id uuid, round_opens_at timestamptz, round_lock_at timestamptz,
  prediction_window_state text, can_edit boolean, seconds_to_lock bigint,
  league_member_id uuid, slot_number integer, required boolean, match_id uuid,
  kickoff timestamptz, match_status text, home_score integer, away_score integer,
  home_team_id uuid, home_team_name text, home_team_short_name text,
  home_team_logo_url text, home_team_crest_reference text,
  away_team_id uuid, away_team_name text, away_team_short_name text,
  away_team_logo_url text, away_team_crest_reference text,
  prediction_id uuid, home_prediction integer, away_prediction integer,
  prediction_status text, prediction_version integer,
  prediction_submitted_at timestamptz, prediction_locked_at timestamptz,
  prediction_updated_at timestamptz, filled_prediction_count integer,
  required_prediction_count integer, is_complete boolean,
  has_official_submission boolean, has_unconfirmed_changes boolean,
  official_home_prediction integer, official_away_prediction integer,
  official_submitted_at timestamptz
)
language plpgsql
security definer
set search_path to public, pg_temp
as $function$
declare
  v_user_id uuid := auth.uid();
  v_league_id uuid;
  v_fantagol_round_id uuid;
  v_number integer;
  v_status text;
  v_enabled boolean;
  v_opens timestamptz;
  v_lock timestamptz;
  v_member uuid;
  v_now timestamptz := clock_timestamp();
  v_window text;
  v_edit boolean;
  v_seconds bigint;
  v_required integer;
  v_filled integer;
begin
  if v_user_id is null then
    raise exception using errcode='P0001', message='AUTHENTICATION_REQUIRED';
  end if;

  select lr.league_id, lr.fantagol_round_id, lr.league_round_number,
         lr.status, lr.enabled, fr.opens_at, fr.lock_at
  into v_league_id, v_fantagol_round_id, v_number, v_status, v_enabled,
       v_opens, v_lock
  from public.league_rounds lr
  join public.fantagol_rounds fr on fr.id=lr.fantagol_round_id
  where lr.id=p_league_round_id;

  if not found then
    raise exception using errcode='P0001', message='LEAGUE_ROUND_NOT_FOUND';
  end if;

  select id into v_member from public.league_members
  where league_id=v_league_id and user_id=v_user_id and status='active'
  limit 1;

  if v_member is null then
    raise exception using errcode='P0001', message='ACTIVE_LEAGUE_MEMBERSHIP_REQUIRED';
  end if;

  v_window := case
    when not v_enabled then 'disabled'
    when v_status in ('predictions_locked','live','waiting_postponed',
      'final_calculable','scoring','official','recalculated','archived') then 'closed'
    when v_status='cancelled' then 'cancelled'
    when v_now < v_opens then 'not_open'
    when v_now >= v_lock then 'closed'
    when v_status='predictions_open' then 'open'
    else 'scheduled'
  end;

  v_edit := v_enabled and v_status='predictions_open'
            and v_now>=v_opens and v_now<v_lock;
  v_seconds := case when v_now<v_lock
    then greatest(floor(extract(epoch from (v_lock-v_now)))::bigint,0)
    else 0 end;

  select count(*)::integer into v_required
  from public.fantagol_round_matches
  where fantagol_round_id=v_fantagol_round_id
    and removed_at is null and required;

  select count(*)::integer into v_filled
  from public.predictions p
  join public.fantagol_round_matches frm
    on frm.fantagol_round_id=v_fantagol_round_id
   and frm.match_id=p.match_id and frm.removed_at is null and frm.required
  where p.league_round_id=p_league_round_id
    and p.league_member_id=v_member
    and p.status in ('draft','submitted','locked');

  return query
  select
    p_league_round_id, v_league_id, v_number, v_status, v_enabled,
    v_fantagol_round_id, v_opens, v_lock, v_window, v_edit, v_seconds,
    v_member, frm.slot_number, frm.required, m.id, m.kickoff, m.status,
    m.home_score, m.away_score,
    ht.id, ht.name, ht.short_name, ht.logo_url, ht.crest_reference,
    at.id, at.name, at.short_name, at.logo_url, at.crest_reference,
    p.id, p.home_prediction, p.away_prediction, coalesce(p.status,'missing'),
    p.version, p.submitted_at, p.locked_at, p.updated_at,
    v_filled, v_required, (v_required>0 and v_filled=v_required),
    (p.submitted_version is not null),
    (p.submitted_version is not null and
      (p.version<>p.submitted_version or p.status<>'submitted')),
    opv.home_prediction, opv.away_prediction, p.official_submitted_at
  from public.fantagol_round_matches frm
  join public.matches m on m.id=frm.match_id
  join public.teams ht on ht.id=m.home_team_id
  join public.teams at on at.id=m.away_team_id
  left join public.predictions p
    on p.league_round_id=p_league_round_id
   and p.league_member_id=v_member and p.match_id=m.id
  left join public.prediction_versions opv
    on opv.prediction_id=p.id and opv.version=p.submitted_version
  where frm.fantagol_round_id=v_fantagol_round_id
    and frm.removed_at is null
  order by frm.slot_number;
end;
$function$;

comment on function public.get_my_round_predictions_rpc(uuid)
is 'Returns private workspace values plus the latest official submitted snapshot and unconfirmed-change state.';

revoke all on function public.get_my_round_predictions_rpc(uuid) from public;
revoke all on function public.get_my_round_predictions_rpc(uuid) from anon;
grant execute on function public.get_my_round_predictions_rpc(uuid) to authenticated;

commit;
