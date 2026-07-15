-- ============================================================================
-- FANTAGOL
-- Migration 023: Complete Draft Auto-Submit at Lock Hotfix
-- ============================================================================

begin;

drop function if exists public.lock_round_predictions_rpc(uuid);

create function public.lock_round_predictions_rpc(
  p_league_round_id uuid
)
returns table (
  league_round_id uuid,
  locked_prediction_count integer,
  auto_submitted_prediction_count integer,
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
  v_required_count integer;
  v_auto_submitted_count integer := 0;
  v_locked_count integer := 0;
  v_voided_count integer := 0;
  v_existing_locked_count integer := 0;
  v_existing_void_count integer := 0;
  v_now timestamptz := clock_timestamp();
begin
  if p_league_round_id is null then
    raise exception using errcode = 'P0001', message = 'LEAGUE_ROUND_REQUIRED';
  end if;

  select lr.league_id, lr.fantagol_round_id, lr.status, lr.enabled, fr.lock_at
  into v_league_id, v_fantagol_round_id, v_league_round_status,
       v_league_round_enabled, v_round_lock_at
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

  if v_now < v_round_lock_at then
    raise exception using errcode = 'P0001', message = 'ROUND_LOCK_TIME_NOT_REACHED';
  end if;

  if v_league_round_status in (
    'predictions_locked','live','waiting_postponed','final_calculable',
    'scoring','official','recalculated','archived'
  ) then
    select
      count(*) filter (where p.status = 'locked')::integer,
      count(*) filter (where p.status = 'void')::integer
    into v_existing_locked_count, v_existing_void_count
    from public.predictions p
    where p.league_round_id = p_league_round_id;

    return query
    select p_league_round_id, coalesce(v_existing_locked_count, 0), 0,
           coalesce(v_existing_void_count, 0), true, v_round_lock_at;
    return;
  end if;

  if v_league_round_status <> 'predictions_open' then
    raise exception using errcode = 'P0001', message = 'LEAGUE_ROUND_NOT_LOCKABLE';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('lock:' || p_league_round_id::text, 0)
  );

  select count(*)::integer
  into v_required_count
  from public.fantagol_round_matches frm
  where frm.fantagol_round_id = v_fantagol_round_id
    and frm.removed_at is null
    and frm.required;

  if v_required_count <= 0 then
    raise exception using errcode = 'P0001', message = 'ROUND_MATCH_SET_EMPTY';
  end if;

  perform 1
  from public.predictions p
  where p.league_round_id = p_league_round_id
  for update;

  -- Complete draft sets become submitted automatically.
  with complete_members as (
    select p.league_member_id
    from public.predictions p
    join public.fantagol_round_matches frm
      on frm.fantagol_round_id = v_fantagol_round_id
     and frm.match_id = p.match_id
     and frm.removed_at is null
     and frm.required
    where p.league_round_id = p_league_round_id
      and p.status in ('draft', 'submitted')
    group by p.league_member_id
    having count(distinct p.match_id) = v_required_count
  ),
  changed as (
    update public.predictions p
    set status = 'submitted',
        submitted_at = coalesce(p.submitted_at, v_now),
        updated_at = v_now,
        version = p.version + 1
    where p.league_round_id = p_league_round_id
      and p.status = 'draft'
      and p.league_member_id in (
        select cm.league_member_id from complete_members cm
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
        'command', 'LockRoundPredictions',
        'reason', 'auto_submit_complete_draft_at_lock',
        'operation', 'status_transition',
        'league_id', v_league_id,
        'league_round_id', p_league_round_id,
        'match_id', c.match_id,
        'previous_status', 'draft',
        'new_status', 'submitted',
        'previous_version', c.version - 1,
        'new_version', c.version
      )
    from changed c
    returning 1
  )
  select count(*)::integer into v_auto_submitted_count from versioned;

  -- Manual and automatic submissions become locked.
  with changed as (
    update public.predictions p
    set status = 'locked',
        locked_at = v_now,
        updated_at = v_now,
        version = p.version + 1
    where p.league_round_id = p_league_round_id
      and p.status = 'submitted'
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
        'command', 'LockRoundPredictions',
        'reason', 'submitted_then_locked',
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

  -- Remaining drafts are incomplete and become void.
  with changed as (
    update public.predictions p
    set status = 'void',
        locked_at = v_now,
        updated_at = v_now,
        version = p.version + 1
    where p.league_round_id = p_league_round_id
      and p.status = 'draft'
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
        'command', 'LockRoundPredictions',
        'reason', 'incomplete_draft_set_voided_at_lock',
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
  set status = 'predictions_locked',
      updated_at = v_now,
      version = lr.version + 1
  where lr.id = p_league_round_id;

  return query
  select p_league_round_id, v_locked_count, v_auto_submitted_count,
         v_voided_count, false, v_now;
end;
$function$;

comment on function public.lock_round_predictions_rpc(uuid)
is 'Locks a League Round: complete draft sets are auto-submitted and locked; incomplete draft sets are voided. Service role only.';

revoke all on function public.lock_round_predictions_rpc(uuid) from public;
revoke all on function public.lock_round_predictions_rpc(uuid) from anon;
revoke all on function public.lock_round_predictions_rpc(uuid) from authenticated;
grant execute on function public.lock_round_predictions_rpc(uuid) to service_role;

commit;
