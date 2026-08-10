-- ============================================================================
-- FANTAGOL
-- Migration 220
-- POSTPONED MATCH GOVERNANCE RUNTIME ACTIVATION
--
-- Scope:
--   * provider-detected postponed match materialization
--   * explicit per-League-Round administrator decision
--   * keep predictions / reopen one match / exclude one match
--   * match-scoped prediction reopen window
--   * dedicated postponed prediction write path
--   * no global League Round prediction reopening
--   * idempotent and auditable governance
-- ============================================================================

begin;

-- ============================================================================
-- 0. PRECONDITIONS
-- ============================================================================

do $$
begin
  if to_regclass('public.league_round_match_decisions') is null then
    raise exception
      'POSTPONED_RUNTIME_PRECONDITION_FAILED: league_round_match_decisions';
  end if;

  if to_regclass('public.league_postponed_match_policies') is null then
    raise exception
      'POSTPONED_RUNTIME_PRECONDITION_FAILED: league_postponed_match_policies';
  end if;

  if to_regclass('public.predictions') is null then
    raise exception
      'POSTPONED_RUNTIME_PRECONDITION_FAILED: predictions';
  end if;
end;
$$;

-- ============================================================================
-- 1. MATCH-SCOPED REOPEN RESOLVER
-- ============================================================================

create or replace function public.is_postponed_prediction_reopen_active(
  p_league_round_id uuid,
  p_match_id uuid,
  p_at timestamptz default clock_timestamp()
)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $function$
  select exists (
    select 1
    from public.league_round_match_decisions d
    where d.league_round_id = p_league_round_id
      and d.match_id = p_match_id
      and d.decision = 'postponed_reopened'
      and d.prediction_reopened_at is not null
      and d.prediction_relock_at is not null
      and p_at >= d.prediction_reopened_at
      and p_at < d.prediction_relock_at
  );
$function$;

-- ============================================================================
-- 2. PROVIDER-DETECTED POSTPONED MATERIALIZATION
--
-- Provider reports a FACT only.
-- This routine does not silently alter Prediction values.
-- Existing Admin decision always wins over repeated provider observations.
-- ============================================================================

create or replace function public.materialize_postponed_match_internal(
  p_match_id uuid,
  p_previous_kickoff timestamptz default null,
  p_current_kickoff timestamptz default null
)
returns table(
  league_round_id uuid,
  decision text,
  created boolean
)
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_match public.matches%rowtype;
  v_row record;
  v_existing public.league_round_match_decisions%rowtype;
  v_created boolean;
  v_now timestamptz := clock_timestamp();
begin
  if p_match_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'POSTPONED_MATCH_ID_REQUIRED';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(
      'postponed-match:' || p_match_id::text,
      0
    )
  );

  select m.*
  into v_match
  from public.matches m
  where m.id = p_match_id;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'POSTPONED_MATCH_NOT_FOUND';
  end if;

  if v_match.status <> 'postponed' then
    raise exception using
      errcode = 'P0001',
      message = 'MATCH_NOT_POSTPONED';
  end if;

  for v_row in
    select
      lr.id as league_round_id,
      lr.league_id
    from public.league_rounds lr
    join public.fantagol_round_matches frm
      on frm.fantagol_round_id = lr.fantagol_round_id
     and frm.match_id = p_match_id
     and frm.removed_at is null
     and frm.required = true
    where lr.enabled = true
      and lr.status not in (
        'official',
        'recalculated',
        'archived',
        'cancelled'
      )
    order by lr.id
  loop
    select d.*
    into v_existing
    from public.league_round_match_decisions d
    where d.league_round_id = v_row.league_round_id
      and d.match_id = p_match_id
    for update;

    v_created := false;

    if not found then
      insert into public.league_round_match_decisions (
        league_round_id,
        match_id,
        decision,
        reason,
        detected_by,
        detected_at,
        previous_kickoff,
        current_kickoff
      )
      values (
        v_row.league_round_id,
        p_match_id,
        'postponed_waiting',
        'Provider detected postponed match; awaiting League administrator governance',
        'provider',
        v_now,
        coalesce(p_previous_kickoff, v_match.kickoff),
        coalesce(p_current_kickoff, v_match.kickoff)
      );

      v_created := true;
    else
      -- Never overwrite an explicit administrator decision.
      if v_existing.detected_by <> 'admin'
         and v_existing.decision = 'postponed_waiting' then
        update public.league_round_match_decisions d
        set
          current_kickoff =
            coalesce(
              p_current_kickoff,
              d.current_kickoff,
              v_match.kickoff
            ),
          updated_at = v_now,
          version = d.version + 1
        where d.id = v_existing.id;
      end if;
    end if;

    update public.league_rounds lr
    set
      status = case
        when lr.status in (
          'predictions_locked',
          'live',
          'waiting_postponed'
        )
          then 'waiting_postponed'
        else lr.status
      end,
      updated_at = v_now,
      version = case
        when lr.status in (
          'predictions_locked',
          'live'
        )
          then lr.version + 1
        else lr.version
      end
    where lr.id = v_row.league_round_id;

    return query
    select
      v_row.league_round_id,
      coalesce(
        (
          select d.decision
          from public.league_round_match_decisions d
          where d.league_round_id = v_row.league_round_id
            and d.match_id = p_match_id
        ),
        'postponed_waiting'
      ),
      v_created;
  end loop;
end;
$function$;

-- ============================================================================
-- 3. ADMIN PER-MATCH GOVERNANCE RPC
--
-- Actions:
--   wait_keep_predictions
--   wait_reopen_predictions
--   exclude_from_round
-- ============================================================================

create or replace function public.set_postponed_match_decision_rpc(
  p_league_round_id uuid,
  p_match_id uuid,
  p_action text,
  p_new_kickoff timestamptz default null,
  p_reason text default null
)
returns table(
  league_round_id uuid,
  match_id uuid,
  decision text,
  prediction_reopened_at timestamptz,
  prediction_relock_at timestamptz,
  decision_version integer
)
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_user_id uuid := auth.uid();
  v_round public.league_rounds%rowtype;
  v_match public.matches%rowtype;
  v_admin_member_id uuid;
  v_existing public.league_round_match_decisions%rowtype;
  v_decision text;
  v_reopened_at timestamptz;
  v_relock_at timestamptz;
  v_now timestamptz := clock_timestamp();
begin
  if v_user_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'AUTHENTICATION_REQUIRED';
  end if;

  if p_action not in (
    'wait_keep_predictions',
    'wait_reopen_predictions',
    'exclude_from_round'
  ) then
    raise exception using
      errcode = 'P0001',
      message = 'POSTPONED_ACTION_INVALID';
  end if;

  select lr.*
  into v_round
  from public.league_rounds lr
  where lr.id = p_league_round_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_ROUND_NOT_FOUND';
  end if;

  select lm.id
  into v_admin_member_id
  from public.league_members lm
  where lm.league_id = v_round.league_id
    and lm.user_id = v_user_id
    and lm.role = 'admin'
    and lm.status = 'active'
  limit 1;

  if v_admin_member_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'ACTIVE_LEAGUE_ADMIN_REQUIRED';
  end if;

  if not exists (
    select 1
    from public.fantagol_round_matches frm
    where frm.fantagol_round_id = v_round.fantagol_round_id
      and frm.match_id = p_match_id
      and frm.removed_at is null
      and frm.required = true
  ) then
    raise exception using
      errcode = 'P0001',
      message = 'MATCH_NOT_IN_LEAGUE_ROUND';
  end if;

  select m.*
  into v_match
  from public.matches m
  where m.id = p_match_id;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'MATCH_NOT_FOUND';
  end if;

  if v_match.status <> 'postponed'
     and p_action <> 'exclude_from_round' then
    raise exception using
      errcode = 'P0001',
      message = 'MATCH_NOT_POSTPONED';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(
      'postponed-decision:' ||
      p_league_round_id::text || ':' ||
      p_match_id::text,
      0
    )
  );

  select d.*
  into v_existing
  from public.league_round_match_decisions d
  where d.league_round_id = p_league_round_id
    and d.match_id = p_match_id
  for update;

  v_decision :=
    case p_action
      when 'wait_keep_predictions'
        then 'postponed_waiting'
      when 'wait_reopen_predictions'
        then 'postponed_reopened'
      when 'exclude_from_round'
        then 'excluded'
    end;

  if p_action = 'wait_reopen_predictions' then
    if p_new_kickoff is null then
      raise exception using
        errcode = 'P0001',
        message = 'POSTPONED_NEW_KICKOFF_REQUIRED';
    end if;

    if p_new_kickoff <= v_now then
      raise exception using
        errcode = 'P0001',
        message = 'POSTPONED_NEW_KICKOFF_NOT_FUTURE';
    end if;

    v_reopened_at := v_now;
    v_relock_at := p_new_kickoff;
  else
    v_reopened_at := null;
    v_relock_at := null;
  end if;

  if v_existing.id is null then
    insert into public.league_round_match_decisions (
      league_round_id,
      match_id,
      decision,
      reason,
      detected_by,
      decided_by_member_id,
      detected_at,
      decided_at,
      previous_kickoff,
      current_kickoff,
      prediction_reopened_at,
      prediction_relock_at
    )
    values (
      p_league_round_id,
      p_match_id,
      v_decision,
      coalesce(
        nullif(btrim(p_reason), ''),
        'Postponed Match administrator governance'
      ),
      'admin',
      v_admin_member_id,
      v_now,
      v_now,
      v_match.kickoff,
      coalesce(p_new_kickoff, v_match.kickoff),
      v_reopened_at,
      v_relock_at
    );
  else
    update public.league_round_match_decisions d
    set
      decision = v_decision,
      reason = coalesce(
        nullif(btrim(p_reason), ''),
        d.reason,
        'Postponed Match administrator governance'
      ),
      detected_by = 'admin',
      decided_by_member_id = v_admin_member_id,
      decided_at = v_now,
      current_kickoff =
        coalesce(
          p_new_kickoff,
          d.current_kickoff,
          v_match.kickoff
        ),
      prediction_reopened_at = v_reopened_at,
      prediction_relock_at = v_relock_at,
      updated_at = v_now,
      version = d.version + 1
    where d.id = v_existing.id;
  end if;

  if v_decision in (
    'postponed_waiting',
    'postponed_reopened'
  ) then
    update public.league_rounds lr
    set
      status = 'waiting_postponed',
      updated_at = v_now,
      version = lr.version + 1
    where lr.id = p_league_round_id
      and lr.status <> 'waiting_postponed';
  end if;

  return query
  select
    d.league_round_id,
    d.match_id,
    d.decision,
    d.prediction_reopened_at,
    d.prediction_relock_at,
    d.version
  from public.league_round_match_decisions d
  where d.league_round_id = p_league_round_id
    and d.match_id = p_match_id;
end;
$function$;

-- ============================================================================
-- 4. DEDICATED POSTPONED PREDICTION DRAFT WRITE
--
-- Only the specifically reopened Match may be changed.
-- The League Round itself remains waiting_postponed.
-- ============================================================================

create or replace function public.save_postponed_prediction_draft_rpc(
  p_league_round_id uuid,
  p_match_id uuid,
  p_home_prediction integer,
  p_away_prediction integer
)
returns table(
  prediction_id uuid,
  prediction_version integer,
  prediction_status text,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_user_id uuid := auth.uid();
  v_round public.league_rounds%rowtype;
  v_member_id uuid;
  v_prediction public.predictions%rowtype;
  v_now timestamptz := clock_timestamp();
begin
  if v_user_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'AUTHENTICATION_REQUIRED';
  end if;

  if p_home_prediction is null
     or p_away_prediction is null
     or p_home_prediction < 0
     or p_home_prediction > 9
     or p_away_prediction < 0
     or p_away_prediction > 9 then
    raise exception using
      errcode = 'P0001',
      message = 'PREDICTION_SCORE_INVALID';
  end if;

  select lr.*
  into v_round
  from public.league_rounds lr
  where lr.id = p_league_round_id;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_ROUND_NOT_FOUND';
  end if;

  if not v_round.enabled
     or v_round.status <> 'waiting_postponed' then
    raise exception using
      errcode = 'P0001',
      message = 'POSTPONED_PREDICTION_WINDOW_NOT_OPEN';
  end if;

  if not public.is_postponed_prediction_reopen_active(
    p_league_round_id,
    p_match_id,
    v_now
  ) then
    raise exception using
      errcode = 'P0001',
      message = 'POSTPONED_PREDICTION_NOT_EDITABLE';
  end if;

  select lm.id
  into v_member_id
  from public.league_members lm
  where lm.league_id = v_round.league_id
    and lm.user_id = v_user_id
    and lm.status = 'active'
  limit 1;

  if v_member_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'ACTIVE_LEAGUE_MEMBERSHIP_REQUIRED';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(
      'postponed-prediction:' ||
      p_league_round_id::text || ':' ||
      v_member_id::text || ':' ||
      p_match_id::text,
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

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'POSTPONED_PREDICTION_NOT_FOUND';
  end if;

  -- Locked is expected here. The explicit reopen decision is the authority
  -- that permits this single Match to become a draft again.
  update public.predictions p
  set
    home_prediction = p_home_prediction,
    away_prediction = p_away_prediction,
    status = 'draft',
    source = 'postponed_reopen',
    submitted_at = null,
    locked_at = null,
    updated_at = v_now,
    version = p.version + 1
  where p.id = v_prediction.id
  returning p.*
  into v_prediction;

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
    'postponed_reopen',
    v_user_id,
    v_member_id,
    v_now,
    jsonb_build_object(
      'command',
      'SavePostponedPredictionDraft',
      'reason',
      'postponed_match_reopened',
      'league_round_id',
      p_league_round_id,
      'match_id',
      p_match_id
    )
  );

  return query
  select
    v_prediction.id,
    v_prediction.version,
    v_prediction.status,
    v_prediction.updated_at;
end;
$function$;

-- ============================================================================
-- 5. DEDICATED POSTPONED PREDICTION SUBMISSION
-- ============================================================================

create or replace function public.submit_postponed_prediction_rpc(
  p_league_round_id uuid,
  p_match_id uuid
)
returns table(
  prediction_id uuid,
  submitted_version integer,
  submitted_at timestamptz
)
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_user_id uuid := auth.uid();
  v_round public.league_rounds%rowtype;
  v_member_id uuid;
  v_prediction public.predictions%rowtype;
  v_now timestamptz := clock_timestamp();
begin
  if v_user_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'AUTHENTICATION_REQUIRED';
  end if;

  select lr.*
  into v_round
  from public.league_rounds lr
  where lr.id = p_league_round_id;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_ROUND_NOT_FOUND';
  end if;

  if not public.is_postponed_prediction_reopen_active(
    p_league_round_id,
    p_match_id,
    v_now
  ) then
    raise exception using
      errcode = 'P0001',
      message = 'POSTPONED_PREDICTION_WINDOW_CLOSED';
  end if;

  select lm.id
  into v_member_id
  from public.league_members lm
  where lm.league_id = v_round.league_id
    and lm.user_id = v_user_id
    and lm.status = 'active'
  limit 1;

  if v_member_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'ACTIVE_LEAGUE_MEMBERSHIP_REQUIRED';
  end if;

  select p.*
  into v_prediction
  from public.predictions p
  where p.league_round_id = p_league_round_id
    and p.league_member_id = v_member_id
    and p.match_id = p_match_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'POSTPONED_PREDICTION_NOT_FOUND';
  end if;

  if v_prediction.status <> 'draft' then
    raise exception using
      errcode = 'P0001',
      message = 'POSTPONED_PREDICTION_NOT_DRAFT';
  end if;

  update public.predictions p
  set
    status = 'submitted',
    submitted_at = v_now,
    official_submitted_at = v_now,
    source = 'postponed_reopen',
    updated_at = v_now,
    version = p.version + 1,
    submitted_version = p.version + 1
  where p.id = v_prediction.id
  returning p.*
  into v_prediction;

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
    'submitted',
    'postponed_reopen',
    v_user_id,
    v_member_id,
    v_now,
    jsonb_build_object(
      'command',
      'SubmitPostponedPrediction',
      'reason',
      'postponed_match_reopened',
      'league_round_id',
      p_league_round_id,
      'match_id',
      p_match_id,
      'official_submitted_version',
      v_prediction.submitted_version
    )
  );

  return query
  select
    v_prediction.id,
    v_prediction.submitted_version,
    v_prediction.official_submitted_at;
end;
$function$;

-- ============================================================================
-- 6. MATCH-SCOPED POSTPONED READ MODEL
-- ============================================================================

create or replace function public.get_my_postponed_match_prediction_rpc(
  p_league_round_id uuid,
  p_match_id uuid
)
returns table(
  league_round_id uuid,
  match_id uuid,
  decision text,
  current_kickoff timestamptz,
  prediction_reopened_at timestamptz,
  prediction_relock_at timestamptz,
  can_edit boolean,
  seconds_to_lock bigint,
  prediction_id uuid,
  home_prediction integer,
  away_prediction integer,
  prediction_status text,
  prediction_version integer,
  submitted_version integer
)
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_user_id uuid := auth.uid();
  v_member_id uuid;
  v_now timestamptz := clock_timestamp();
begin
  if v_user_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'AUTHENTICATION_REQUIRED';
  end if;

  select lm.id
  into v_member_id
  from public.league_rounds lr
  join public.league_members lm
    on lm.league_id = lr.league_id
   and lm.user_id = v_user_id
   and lm.status = 'active'
  where lr.id = p_league_round_id
  limit 1;

  if v_member_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'ACTIVE_LEAGUE_MEMBERSHIP_REQUIRED';
  end if;

  return query
  select
    d.league_round_id,
    d.match_id,
    d.decision,
    d.current_kickoff,
    d.prediction_reopened_at,
    d.prediction_relock_at,
    public.is_postponed_prediction_reopen_active(
      d.league_round_id,
      d.match_id,
      v_now
    ),
    case
      when d.prediction_relock_at is not null
       and v_now < d.prediction_relock_at
        then greatest(
          floor(
            extract(
              epoch from (d.prediction_relock_at - v_now)
            )
          )::bigint,
          0
        )
      else 0
    end,
    p.id,
    p.home_prediction,
    p.away_prediction,
    p.status,
    p.version,
    p.submitted_version
  from public.league_round_match_decisions d
  left join public.predictions p
    on p.league_round_id = d.league_round_id
   and p.match_id = d.match_id
   and p.league_member_id = v_member_id
  where d.league_round_id = p_league_round_id
    and d.match_id = p_match_id;
end;
$function$;

-- ============================================================================
-- 7. SECURITY
-- ============================================================================

revoke all on function
  public.materialize_postponed_match_internal(
    uuid,
    timestamptz,
    timestamptz
  )
from public, anon, authenticated;

grant execute on function
  public.materialize_postponed_match_internal(
    uuid,
    timestamptz,
    timestamptz
  )
to service_role;

revoke all on function
  public.is_postponed_prediction_reopen_active(
    uuid,
    uuid,
    timestamptz
  )
from public, anon;

grant execute on function
  public.is_postponed_prediction_reopen_active(
    uuid,
    uuid,
    timestamptz
  )
to authenticated, service_role;

revoke all on function
  public.set_postponed_match_decision_rpc(
    uuid,
    uuid,
    text,
    timestamptz,
    text
  )
from public, anon;

grant execute on function
  public.set_postponed_match_decision_rpc(
    uuid,
    uuid,
    text,
    timestamptz,
    text
  )
to authenticated, service_role;

revoke all on function
  public.save_postponed_prediction_draft_rpc(
    uuid,
    uuid,
    integer,
    integer
  )
from public, anon;

grant execute on function
  public.save_postponed_prediction_draft_rpc(
    uuid,
    uuid,
    integer,
    integer
  )
to authenticated;

revoke all on function
  public.submit_postponed_prediction_rpc(
    uuid,
    uuid
  )
from public, anon;

grant execute on function
  public.submit_postponed_prediction_rpc(
    uuid,
    uuid
  )
to authenticated;

revoke all on function
  public.get_my_postponed_match_prediction_rpc(
    uuid,
    uuid
  )
from public, anon;

grant execute on function
  public.get_my_postponed_match_prediction_rpc(
    uuid,
    uuid
  )
to authenticated;

commit;