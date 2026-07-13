-- ============================================================
-- FANTAGOL — MIGRATION 020
-- Prediction Round Lock + Audit Metadata Refinement
-- ============================================================
-- Scope:
--   1. Enrich SavePredictionDraft version metadata.
--   2. Enrich SubmitRoundPredictions version metadata.
--   3. Add the service-only atomic round prediction lock command.
--   4. Lock submitted predictions and void unsubmitted drafts.
-- ============================================================

begin;

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
  v_operation text;
  v_previous_version integer;
  v_previous_status text;
  v_now timestamptz := clock_timestamp();
begin
  -- ----------------------------------------------------------
  -- Authentication and input validation
  -- ----------------------------------------------------------
  v_user_id := auth.uid();

  if v_user_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'AUTHENTICATION_REQUIRED';
  end if;

  if p_league_round_id is null or p_match_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'PREDICTION_TARGET_REQUIRED';
  end if;

  if p_home_prediction is null or p_away_prediction is null
     or p_home_prediction < 0 or p_home_prediction > 9
     or p_away_prediction < 0 or p_away_prediction > 9 then
    raise exception using
      errcode = 'P0001',
      message = 'PREDICTION_SCORE_INVALID';
  end if;

  -- ----------------------------------------------------------
  -- Resolve and lock the League Round lifecycle row
  -- ----------------------------------------------------------
  select
    lr.league_id,
    lr.fantagol_round_id,
    lr.status,
    lr.enabled,
    fr.opens_at,
    fr.lock_at
  into
    v_league_id,
    v_fantagol_round_id,
    v_league_round_status,
    v_league_round_enabled,
    v_round_opens_at,
    v_round_lock_at
  from public.league_rounds lr
  join public.fantagol_rounds fr
    on fr.id = lr.fantagol_round_id
  where lr.id = p_league_round_id
  for update of lr;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_ROUND_NOT_FOUND';
  end if;

  if not v_league_round_enabled then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_ROUND_DISABLED';
  end if;

  if v_league_round_status <> 'predictions_open' then
    raise exception using
      errcode = 'P0001',
      message = 'PREDICTION_WINDOW_NOT_OPEN';
  end if;

  if v_now < v_round_opens_at then
    raise exception using
      errcode = 'P0001',
      message = 'PREDICTION_WINDOW_NOT_OPEN';
  end if;

  if v_now >= v_round_lock_at then
    raise exception using
      errcode = 'P0001',
      message = 'PREDICTION_WINDOW_CLOSED';
  end if;

  -- ----------------------------------------------------------
  -- Resolve active membership from auth.uid(); never trust a
  -- member id supplied by the client.
  -- ----------------------------------------------------------
  select lm.id
  into v_member_id
  from public.league_members lm
  where lm.league_id = v_league_id
    and lm.user_id = v_user_id
    and lm.status = 'active'
  limit 1;

  if v_member_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'ACTIVE_LEAGUE_MEMBERSHIP_REQUIRED';
  end if;

  -- ----------------------------------------------------------
  -- The match must belong to the official active Match Set of
  -- the FantaGol Round connected to this League Round.
  -- ----------------------------------------------------------
  if not exists (
    select 1
    from public.fantagol_round_matches frm
    where frm.fantagol_round_id = v_fantagol_round_id
      and frm.match_id = p_match_id
      and frm.removed_at is null
  ) then
    raise exception using
      errcode = 'P0001',
      message = 'MATCH_NOT_IN_LEAGUE_ROUND';
  end if;

  -- Serialize writes for the same member/round/match, including
  -- the first insert where no row exists yet.
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
    v_operation := 'update';
    v_previous_version := v_prediction.version;
    v_previous_status := v_prediction.status;

    if v_prediction.status in ('locked', 'void') then
      raise exception using
        errcode = 'P0001',
        message = 'PREDICTION_NOT_EDITABLE';
    end if;

    -- Idempotent retry: equal values produce no new version.
    if v_prediction.home_prediction = p_home_prediction
       and v_prediction.away_prediction = p_away_prediction then
      return query
      select
        v_prediction.id,
        v_prediction.league_round_id,
        v_prediction.league_member_id,
        v_prediction.match_id,
        v_prediction.home_prediction,
        v_prediction.away_prediction,
        v_prediction.status,
        v_prediction.version,
        v_prediction.updated_at;
      return;
    end if;

    update public.predictions p
    set
      home_prediction = p_home_prediction,
      away_prediction = p_away_prediction,
      updated_at = v_now,
      version = p.version + 1
    where p.id = v_prediction.id
    returning p.* into v_prediction;
  else
    v_operation := 'insert';
    v_previous_version := null;
    v_previous_status := null;

    insert into public.predictions (
      league_id,
      user_id,
      match_id,
      home_prediction,
      away_prediction,
      league_round_id,
      league_member_id,
      status,
      submitted_at,
      locked_at,
      source,
      version,
      created_at,
      updated_at
    )
    values (
      v_league_id,
      v_user_id,
      p_match_id,
      p_home_prediction,
      p_away_prediction,
      p_league_round_id,
      v_member_id,
      'draft',
      null,
      null,
      'standard',
      1,
      v_now,
      v_now
    )
    returning * into v_prediction;
  end if;

  -- Immutable history row written in the same transaction.
  insert into public.prediction_versions (
    prediction_id,
    version,
    home_prediction,
    away_prediction,
    status,
    source,
    changed_by_user_id,
    changed_by_member_id,
    changed_at,
    metadata
  )
  values (
    v_prediction.id,
    v_prediction.version,
    v_prediction.home_prediction,
    v_prediction.away_prediction,
    v_prediction.status,
    v_prediction.source,
    v_user_id,
    v_member_id,
    v_now,
    jsonb_build_object(
      'command', 'SavePredictionDraft',
      'reason', 'draft_save',
      'operation', v_operation,
      'league_id', v_league_id,
      'league_round_id', p_league_round_id,
      'match_id', p_match_id,
      'previous_status', v_previous_status,
      'new_status', v_prediction.status,
      'previous_version', v_previous_version,
      'new_version', v_prediction.version
    )
  );

  return query
  select
    v_prediction.id,
    v_prediction.league_round_id,
    v_prediction.league_member_id,
    v_prediction.match_id,
    v_prediction.home_prediction,
    v_prediction.away_prediction,
    v_prediction.status,
    v_prediction.version,
    v_prediction.updated_at;
end;
$function$;

comment on function public.save_prediction_draft_rpc(uuid, uuid, integer, integer) is
  'Command: atomically insert/update one prediction draft and persist an immutable version with full audit metadata.';

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
  v_league_round_status text;
  v_league_round_enabled boolean;
  v_round_opens_at timestamptz;
  v_round_lock_at timestamptz;
  v_member_id uuid;
  v_required_count integer;
  v_prediction_count integer;
  v_invalid_count integer;
  v_draft_count integer;
  v_submitted_count integer;
  v_existing_submitted_at timestamptz;
  v_now timestamptz := clock_timestamp();
begin
  v_user_id := auth.uid();

  if v_user_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'AUTHENTICATION_REQUIRED';
  end if;

  if p_league_round_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_ROUND_REQUIRED';
  end if;

  -- Lock the lifecycle row so submit cannot race with round lock.
  select
    lr.league_id,
    lr.fantagol_round_id,
    lr.status,
    lr.enabled,
    fr.opens_at,
    fr.lock_at
  into
    v_league_id,
    v_fantagol_round_id,
    v_league_round_status,
    v_league_round_enabled,
    v_round_opens_at,
    v_round_lock_at
  from public.league_rounds lr
  join public.fantagol_rounds fr
    on fr.id = lr.fantagol_round_id
  where lr.id = p_league_round_id
  for update of lr;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_ROUND_NOT_FOUND';
  end if;

  if not v_league_round_enabled then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_ROUND_DISABLED';
  end if;

  if v_league_round_status <> 'predictions_open' then
    raise exception using
      errcode = 'P0001',
      message = 'PREDICTION_WINDOW_NOT_OPEN';
  end if;

  if v_now < v_round_opens_at then
    raise exception using
      errcode = 'P0001',
      message = 'PREDICTION_WINDOW_NOT_OPEN';
  end if;

  if v_now >= v_round_lock_at then
    raise exception using
      errcode = 'P0001',
      message = 'PREDICTION_WINDOW_CLOSED';
  end if;

  select lm.id
  into v_member_id
  from public.league_members lm
  where lm.league_id = v_league_id
    and lm.user_id = v_user_id
    and lm.status = 'active'
  limit 1;

  if v_member_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'ACTIVE_LEAGUE_MEMBERSHIP_REQUIRED';
  end if;

  -- Serialize all submissions for the same member and round.
  perform pg_advisory_xact_lock(
    hashtextextended(
      'submit:' || p_league_round_id::text || ':' || v_member_id::text,
      0
    )
  );

  select count(*)::integer
  into v_required_count
  from public.fantagol_round_matches frm
  where frm.fantagol_round_id = v_fantagol_round_id
    and frm.removed_at is null
    and frm.required;

  if v_required_count <= 0 then
    raise exception using
      errcode = 'P0001',
      message = 'ROUND_MATCH_SET_EMPTY';
  end if;

  -- Lock all current predictions for this member and round.
  perform 1
  from public.predictions p
  where p.league_round_id = p_league_round_id
    and p.league_member_id = v_member_id
  for update;

  select
    count(*) filter (
      where frm.match_id is not null
        and p.status in ('draft', 'submitted')
    )::integer,
    count(*) filter (
      where frm.match_id is null
         or p.status not in ('draft', 'submitted')
    )::integer,
    count(*) filter (where p.status = 'draft')::integer,
    count(*) filter (where p.status = 'submitted')::integer,
    min(p.submitted_at) filter (where p.status = 'submitted')
  into
    v_prediction_count,
    v_invalid_count,
    v_draft_count,
    v_submitted_count,
    v_existing_submitted_at
  from public.predictions p
  left join public.fantagol_round_matches frm
    on frm.fantagol_round_id = v_fantagol_round_id
   and frm.match_id = p.match_id
   and frm.removed_at is null
   and frm.required
  where p.league_round_id = p_league_round_id
    and p.league_member_id = v_member_id;

  if v_invalid_count > 0 then
    raise exception using
      errcode = 'P0001',
      message = 'ROUND_PREDICTION_SET_INVALID';
  end if;

  if v_prediction_count <> v_required_count then
    raise exception using
      errcode = 'P0001',
      message = 'ROUND_PREDICTIONS_INCOMPLETE',
      detail = format(
        'required=%s present=%s missing=%s',
        v_required_count,
        v_prediction_count,
        greatest(v_required_count - v_prediction_count, 0)
      );
  end if;

  -- Idempotent retry: all required predictions are already submitted.
  if v_draft_count = 0 and v_submitted_count = v_required_count then
    return query
    select
      p_league_round_id,
      v_member_id,
      v_required_count,
      v_submitted_count,
      true,
      v_existing_submitted_at;
    return;
  end if;

  -- Change only draft rows. Already-submitted rows remain untouched.
  with changed as (
    update public.predictions p
    set
      status = 'submitted',
      submitted_at = coalesce(p.submitted_at, v_now),
      updated_at = v_now,
      version = p.version + 1
    where p.league_round_id = p_league_round_id
      and p.league_member_id = v_member_id
      and p.status = 'draft'
    returning p.*
  )
  insert into public.prediction_versions (
    prediction_id,
    version,
    home_prediction,
    away_prediction,
    status,
    source,
    changed_by_user_id,
    changed_by_member_id,
    changed_at,
    metadata
  )
  select
    c.id,
    c.version,
    c.home_prediction,
    c.away_prediction,
    c.status,
    c.source,
    v_user_id,
    v_member_id,
    v_now,
    jsonb_build_object(
      'command', 'SubmitRoundPredictions',
      'reason', 'submit',
      'operation', 'status_transition',
      'league_id', v_league_id,
      'league_round_id', p_league_round_id,
      'match_id', c.match_id,
      'previous_status', 'draft',
      'new_status', 'submitted',
      'previous_version', c.version - 1,
      'new_version', c.version
    )
  from changed c;

  select count(*)::integer, min(p.submitted_at)
  into v_submitted_count, v_existing_submitted_at
  from public.predictions p
  where p.league_round_id = p_league_round_id
    and p.league_member_id = v_member_id
    and p.status = 'submitted';

  if v_submitted_count <> v_required_count then
    raise exception using
      errcode = 'P0001',
      message = 'ROUND_SUBMISSION_INVARIANT_FAILED';
  end if;

  return query
  select
    p_league_round_id,
    v_member_id,
    v_required_count,
    v_submitted_count,
    false,
    v_existing_submitted_at;
end;
$function$;

comment on function public.submit_round_predictions_rpc(uuid) is
  'Command: atomically submit the authenticated member complete round prediction set with full audit metadata.';

create or replace function public.lock_round_predictions_rpc(
  p_league_round_id uuid
)
returns table (
  league_round_id uuid,
  locked_prediction_count integer,
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
  v_league_round_status text;
  v_league_round_enabled boolean;
  v_round_lock_at timestamptz;
  v_existing_locked_count integer;
  v_existing_void_count integer;
  v_locked_count integer := 0;
  v_voided_count integer := 0;
  v_now timestamptz := clock_timestamp();
begin
  if p_league_round_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_ROUND_REQUIRED';
  end if;

  select
    lr.league_id,
    lr.fantagol_round_id,
    lr.status,
    lr.enabled,
    fr.lock_at
  into
    v_league_id,
    v_fantagol_round_id,
    v_league_round_status,
    v_league_round_enabled,
    v_round_lock_at
  from public.league_rounds lr
  join public.fantagol_rounds fr
    on fr.id = lr.fantagol_round_id
  where lr.id = p_league_round_id
  for update of lr;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_ROUND_NOT_FOUND';
  end if;

  if not v_league_round_enabled then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_ROUND_DISABLED';
  end if;

  if v_now < v_round_lock_at then
    raise exception using
      errcode = 'P0001',
      message = 'ROUND_LOCK_TIME_NOT_REACHED';
  end if;

  if v_league_round_status in (
    'predictions_locked',
    'live',
    'waiting_postponed',
    'final_calculable',
    'scoring',
    'official',
    'recalculated',
    'archived'
  ) then
    select
      count(*) filter (where p.status = 'locked')::integer,
      count(*) filter (where p.status = 'void')::integer
    into
      v_existing_locked_count,
      v_existing_void_count
    from public.predictions p
    where p.league_round_id = p_league_round_id;

    return query
    select
      p_league_round_id,
      coalesce(v_existing_locked_count, 0),
      coalesce(v_existing_void_count, 0),
      true,
      v_round_lock_at;
    return;
  end if;

  if v_league_round_status <> 'predictions_open' then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_ROUND_NOT_LOCKABLE';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('lock:' || p_league_round_id::text, 0)
  );

  perform 1
  from public.predictions p
  where p.league_round_id = p_league_round_id
  for update;

  with changed as (
    update public.predictions p
    set
      status = 'locked',
      locked_at = v_now,
      updated_at = v_now,
      version = p.version + 1
    where p.league_round_id = p_league_round_id
      and p.status = 'submitted'
    returning p.*
  ), versioned as (
    insert into public.prediction_versions (
      prediction_id,
      version,
      home_prediction,
      away_prediction,
      status,
      source,
      changed_by_user_id,
      changed_by_member_id,
      changed_at,
      metadata
    )
    select
      c.id,
      c.version,
      c.home_prediction,
      c.away_prediction,
      c.status,
      c.source,
      null,
      c.league_member_id,
      v_now,
      jsonb_build_object(
        'command', 'LockRoundPredictions',
        'reason', 'auto_lock',
        'operation', 'status_transition',
        'league_id', v_league_id,
        'league_round_id', p_league_round_id,
        'match_id', c.match_id,
        'previous_status', 'submitted',
        'new_status', 'locked',
        'previous_version', c.version - 1,
        'new_version', c.version
      )
    from changed c
    returning 1
  )
  select count(*)::integer into v_locked_count from versioned;

  with changed as (
    update public.predictions p
    set
      status = 'void',
      locked_at = v_now,
      updated_at = v_now,
      version = p.version + 1
    where p.league_round_id = p_league_round_id
      and p.status = 'draft'
    returning p.*
  ), versioned as (
    insert into public.prediction_versions (
      prediction_id,
      version,
      home_prediction,
      away_prediction,
      status,
      source,
      changed_by_user_id,
      changed_by_member_id,
      changed_at,
      metadata
    )
    select
      c.id,
      c.version,
      c.home_prediction,
      c.away_prediction,
      c.status,
      c.source,
      null,
      c.league_member_id,
      v_now,
      jsonb_build_object(
        'command', 'LockRoundPredictions',
        'reason', 'unsubmitted_draft_voided',
        'operation', 'status_transition',
        'league_id', v_league_id,
        'league_round_id', p_league_round_id,
        'match_id', c.match_id,
        'previous_status', 'draft',
        'new_status', 'void',
        'previous_version', c.version - 1,
        'new_version', c.version
      )
    from changed c
    returning 1
  )
  select count(*)::integer into v_voided_count from versioned;

  update public.league_rounds lr
  set
    status = 'predictions_locked',
    updated_at = v_now,
    version = lr.version + 1
  where lr.id = p_league_round_id;

  return query
  select
    p_league_round_id,
    v_locked_count,
    v_voided_count,
    false,
    v_now;
end;
$function$;

comment on function public.lock_round_predictions_rpc(uuid) is
  'Service command: after lock_at, atomically lock submitted predictions, void unsubmitted drafts and close the League Round prediction lifecycle.';

revoke all on function public.lock_round_predictions_rpc(uuid) from public;
revoke all on function public.lock_round_predictions_rpc(uuid) from anon;
revoke all on function public.lock_round_predictions_rpc(uuid) from authenticated;
grant execute on function public.lock_round_predictions_rpc(uuid) to service_role;

commit;
