begin;

-- ============================================================================
-- FANTAGOL 157
-- PRE-DEADLINE LEAGUE COMPOSITION AUTO REGENERATION
-- ============================================================================
--
-- Mission:
--   Keep the active Fantacalcio and One-to-One schedules aligned with the
--   current active roster when a member leaves or is removed before the
--   canonical first League Round prediction lock.
--
-- Canonical deadline:
--   leagues.starts_from_fantagol_round_id
--     -> fantagol_rounds.lock_at
--
-- Invariants:
--   * reuse public.generate_league_competitions(...);
--   * never introduce a second schedule generator;
--   * never rewrite or delete predictions;
--   * never alter the manual lock/regeneration path;
--   * never regenerate after the canonical first-round lock;
--   * preserve all current authorization and public-league governance guards;
--   * execute membership mutation and schedule regeneration atomically.
-- ============================================================================


-- ============================================================================
-- 1. Internal League Composition Governance Engine.
-- ============================================================================

create or replace function public.apply_league_composition_change(
  p_league_id uuid,
  p_change_reason text
)
returns table(
  calendar_changed boolean,
  decision_reason text,
  schedule_version_id uuid,
  schedule_version integer,
  active_member_count integer,
  fixture_count integer,
  bye_count integer,
  deadline_at timestamptz
)
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_league public.leagues%rowtype;
  v_start_round public.fantagol_rounds%rowtype;
  v_active_schedule public.league_schedule_versions%rowtype;
  v_admin_member_id uuid;
  v_active_member_count integer := 0;
  v_generated_schedule record;
  v_change_reason text;
begin
  /*
   * Canonical League Composition Governance reason.
   *
   * Free-form reasons are intentionally rejected so every composition mutation
   * remains queryable, auditable and stable across all current and future
   * membership workflows.
   */
  v_change_reason := upper(nullif(btrim(p_change_reason), ''));

  if v_change_reason is null
     or v_change_reason not in (
       'VOLUNTARY_MEMBER_LEAVE',
       'ADMIN_MEMBER_REMOVAL',
       'MEMBER_RESTORED',
       'MEMBER_JOINED',
       'SYSTEM_COMPOSITION_UPDATE'
     ) then
    raise exception using
      errcode = 'P0001',
      message = 'INVALID_LEAGUE_COMPOSITION_CHANGE_REASON';
  end if;


  /*
   * Serialize every composition decision on the canonical League row.
   */
  select l.*
  into v_league
  from public.leagues l
  where l.id = p_league_id
  for update;

  if v_league.id is null then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_NOT_FOUND';
  end if;

  /*
   * A completed or archived League has immutable competitive composition.
   */
  if v_league.lifecycle_status in ('completed', 'archived') then
    return query
    select
      false,
      'LEAGUE_NOT_EDITABLE'::text,
      null::uuid,
      null::integer,
      0,
      null::integer,
      null::integer,
      null::timestamptz;

    return;
  end if;

  /*
   * Automatic regeneration applies only when an active schedule already
   * exists. If no schedule exists, the next normal roster lock will generate
   * the first canonical schedule.
   */
  select lsv.*
  into v_active_schedule
  from public.league_schedule_versions lsv
  where lsv.league_id = p_league_id
    and lsv.active = true
  order by lsv.version desc
  limit 1
  for update;

  if v_active_schedule.id is null then
    select count(*)::integer
    into v_active_member_count
    from public.league_members lm
    where lm.league_id = p_league_id
      and lm.status = 'active';

    return query
    select
      false,
      'NO_ACTIVE_SCHEDULE'::text,
      null::uuid,
      null::integer,
      v_active_member_count,
      null::integer,
      null::integer,
      null::timestamptz;

    return;
  end if;

  /*
   * Reuse exactly the same first-round reference used by
   * lock_league_roster_rpc().
   */
  if v_league.starts_from_fantagol_round_id is null then
    return query
    select
      false,
      'LEAGUE_START_ROUND_NOT_ASSIGNED'::text,
      v_active_schedule.id,
      v_active_schedule.version,
      v_active_schedule.member_count,
      null::integer,
      null::integer,
      null::timestamptz;

    return;
  end if;

  select fr.*
  into v_start_round
  from public.fantagol_rounds fr
  where fr.id = v_league.starts_from_fantagol_round_id
    and fr.edition_id = v_league.edition_id
    and fr.active = true;

  if v_start_round.id is null then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_START_ROUND_NOT_FOUND';
  end if;

  /*
   * Once the canonical first-round lock is reached, historical schedules and
   * every dependent competitive datum remain immutable.
   */
  if now() >= v_start_round.lock_at then
    select count(*)::integer
    into v_active_member_count
    from public.league_members lm
    where lm.league_id = p_league_id
      and lm.status = 'active';

    return query
    select
      false,
      'FIRST_ROUND_LOCK_REACHED'::text,
      v_active_schedule.id,
      v_active_schedule.version,
      v_active_member_count,
      null::integer,
      null::integer,
      v_start_round.lock_at;

    return;
  end if;

  /*
   * The canonical generator requires an active administrator as the
   * generation authority. The departing member does not need to be Admin.
   */
  select lm.id
  into v_admin_member_id
  from public.league_members lm
  where lm.league_id = p_league_id
    and lm.role = 'admin'
    and lm.status = 'active'
  order by lm.joined_at, lm.id
  limit 1
  for update;

  if v_admin_member_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'ACTIVE_ADMIN_REQUIRED';
  end if;

  select count(*)::integer
  into v_active_member_count
  from public.league_members lm
  where lm.league_id = p_league_id
    and lm.status = 'active';

  /*
   * Preserve the existing membership mutation contract if the departure leaves
   * fewer than two active members. No valid H2H schedule can be generated.
   */
  if v_active_member_count < 2 then
    return query
    select
      false,
      'MINIMUM_TWO_ACTIVE_MEMBERS_NOT_AVAILABLE'::text,
      v_active_schedule.id,
      v_active_schedule.version,
      v_active_member_count,
      null::integer,
      null::integer,
      v_start_round.lock_at;

    return;
  end if;

  /*
   * Canonical deterministic and versioned schedule generation.
   *
   * This call:
   *   * deactivates the previous schedule version;
   *   * creates a new active schedule version;
   *   * regenerates Fantacalcio fixtures;
   *   * regenerates One-to-One fixtures;
   *   * recalculates BYEs;
   *   * certifies cross-mode BYE coordination.
   */
  select *
  into v_generated_schedule
  from public.generate_league_competitions(
    p_league_id,
    v_admin_member_id,
    v_change_reason
  );

  return query
  select
    true,
    'SCHEDULE_REGENERATED'::text,
    v_generated_schedule.schedule_version_id,
    v_generated_schedule.schedule_version,
    v_generated_schedule.member_count,
    v_generated_schedule.fixture_count,
    v_generated_schedule.bye_fixture_count,
    v_start_round.lock_at;
end;
$function$;

comment on function public.apply_league_composition_change(
  uuid,
  text
) is
'Internal League Composition Governance Engine. Applies the governance consequences of a canonical membership composition change and regenerates the active versioned Fantacalcio and One-to-One schedules only while the canonical first League Round lock_at is still in the future. It never modifies predictions and never changes the manual roster-lock regeneration contract.';

revoke all on function public.apply_league_composition_change(
  uuid,
  text
) from public;

grant execute on function public.apply_league_composition_change(
  uuid,
  text
) to postgres, service_role;


-- ============================================================================
-- 2. Voluntary member departure.
-- ============================================================================

create or replace function public.leave_league_rpc(
  target_league_id uuid
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_user_id uuid := auth.uid();
  v_member public.league_members%rowtype;
  v_regeneration record;
begin
  if v_user_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'AUTH_REQUIRED';
  end if;

  /*
   * Lock the League first so membership departure and schedule regeneration
   * share one deterministic serialization boundary.
   */
  perform 1
  from public.leagues l
  where l.id = target_league_id
    and l.lifecycle_status not in ('completed', 'archived')
  for update;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_NOT_EDITABLE';
  end if;

  select lm.*
  into v_member
  from public.league_members lm
  where lm.league_id = target_league_id
    and lm.user_id = v_user_id
    and lm.status = 'active'
  for update;

  if v_member.id is null then
    raise exception using
      errcode = 'P0001',
      message = 'ACTIVE_MEMBERSHIP_NOT_FOUND';
  end if;

  if v_member.role = 'admin' then
    raise exception using
      errcode = 'P0001',
      message = 'ADMIN_MUST_TRANSFER_ROLE_BEFORE_LEAVING';
  end if;

  update public.league_members
  set
    status = 'left',
    role = 'member'
  where id = v_member.id;

  /*
   * Membership mutation and any pre-deadline schedule regeneration remain in
   * this same PostgreSQL transaction.
   */
  select *
  into v_regeneration
  from public.apply_league_composition_change(
    target_league_id,
    'VOLUNTARY_MEMBER_LEAVE'
  );

  update public.profiles
  set last_active_league_id = null
  where id = v_user_id
    and last_active_league_id = target_league_id;

  perform public.write_league_admin_event(
    target_league_id,
    v_member.id,
    v_user_id,
    'member',
    'member_withdrawn',
    v_member.id,
    null,
    jsonb_build_object(
      'return_requires_admin', false,
      'calendar_changed', v_regeneration.calendar_changed,
      'schedule_decision_reason', v_regeneration.decision_reason,
      'schedule_version_id', v_regeneration.schedule_version_id,
      'schedule_version', v_regeneration.schedule_version,
      'active_member_count', v_regeneration.active_member_count,
      'fixture_count', v_regeneration.fixture_count,
      'bye_count', v_regeneration.bye_count,
      'composition_deadline_at', v_regeneration.deadline_at,
      'future_missing_predictions_score', 0,
      'predictions_modified', false
    )
  );
end;
$function$;

comment on function public.leave_league_rpc(uuid) is
'Allows a non-admin active member to leave a League. If an active schedule exists and the canonical first-round lock_at has not been reached, the schedule is regenerated atomically from the remaining active roster. After the deadline, historical schedules and predictions remain unchanged.';

revoke all on function public.leave_league_rpc(uuid) from public;
grant execute on function public.leave_league_rpc(uuid) to authenticated;
grant execute on function public.leave_league_rpc(uuid) to service_role;


-- ============================================================================
-- 3. Private-League administrative member removal.
-- ============================================================================

create or replace function public.remove_league_member_rpc(
  target_league_id uuid,
  target_member_id uuid,
  removal_reason text default null
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_user_id uuid := auth.uid();
  v_admin_member_id uuid;
  v_target public.league_members%rowtype;
  v_league_visibility text;
  v_regeneration record;
begin
  if v_user_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'AUTH_REQUIRED';
  end if;

  v_admin_member_id :=
    public.get_active_admin_member_id(
      target_league_id,
      v_user_id
    );

  if v_admin_member_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'ACTIVE_ADMIN_REQUIRED';
  end if;

  select l.visibility
  into v_league_visibility
  from public.leagues l
  where l.id = target_league_id
    and l.lifecycle_status not in ('completed', 'archived')
  for update;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_NOT_EDITABLE';
  end if;

  /*
   * Preserve the certified public-League governance contract introduced by
   * migration 153.
   */
  if v_league_visibility = 'public' then
    raise exception using
      errcode = 'P0001',
      message = 'PUBLIC_LEAGUE_ADMIN_MEMBER_REMOVAL_FORBIDDEN';
  end if;

  select lm.*
  into v_target
  from public.league_members lm
  where lm.id = target_member_id
    and lm.league_id = target_league_id
    and lm.status = 'active'
  for update;

  if v_target.id is null then
    raise exception using
      errcode = 'P0001',
      message = 'TARGET_ACTIVE_MEMBER_NOT_FOUND';
  end if;

  if v_target.role = 'admin' then
    raise exception using
      errcode = 'P0001',
      message = 'ADMIN_CANNOT_REMOVE_SELF';
  end if;

  update public.league_members
  set
    status = 'removed',
    role = 'member'
  where id = target_member_id;

  select *
  into v_regeneration
  from public.apply_league_composition_change(
    target_league_id,
    'ADMIN_MEMBER_REMOVAL'
  );

  update public.profiles
  set last_active_league_id = null
  where id = v_target.user_id
    and last_active_league_id = target_league_id;

  perform public.write_league_admin_event(
    target_league_id,
    v_admin_member_id,
    v_user_id,
    'member',
    'member_removed',
    target_member_id,
    null,
    jsonb_build_object(
      'reason', nullif(trim(removal_reason), ''),
      'return_requires_admin', true,
      'calendar_changed', v_regeneration.calendar_changed,
      'schedule_decision_reason', v_regeneration.decision_reason,
      'schedule_version_id', v_regeneration.schedule_version_id,
      'schedule_version', v_regeneration.schedule_version,
      'active_member_count', v_regeneration.active_member_count,
      'fixture_count', v_regeneration.fixture_count,
      'bye_count', v_regeneration.bye_count,
      'composition_deadline_at', v_regeneration.deadline_at,
      'future_missing_predictions_score', 0,
      'predictions_modified', false
    )
  );
end;
$function$;

comment on function public.remove_league_member_rpc(uuid, uuid, text) is
'Removes an active member from a private League through an authenticated active administrator. Public-League administrator removals remain forbidden. Before the canonical first-round lock_at, an existing active schedule is regenerated atomically; after the deadline, schedules and predictions remain unchanged.';

revoke all on function public.remove_league_member_rpc(
  uuid,
  uuid,
  text
) from public;

grant execute on function public.remove_league_member_rpc(
  uuid,
  uuid,
  text
) to authenticated;

grant execute on function public.remove_league_member_rpc(
  uuid,
  uuid,
  text
) to service_role;


-- ============================================================================
-- 4. Installation assertions.
-- ============================================================================

do $verification$
declare
  v_engine_definition text;
  v_leave_definition text;
  v_remove_definition text;
  v_lock_definition text;
begin
  select pg_get_functiondef(
    'public.apply_league_composition_change(uuid,text)'::regprocedure
  )
  into v_engine_definition;

  select pg_get_functiondef(
    'public.leave_league_rpc(uuid)'::regprocedure
  )
  into v_leave_definition;

  select pg_get_functiondef(
    'public.remove_league_member_rpc(uuid,uuid,text)'::regprocedure
  )
  into v_remove_definition;

  select pg_get_functiondef(
    'public.lock_league_roster_rpc(uuid,boolean)'::regprocedure
  )
  into v_lock_definition;

  if position(
    'generate_league_competitions'
    in v_engine_definition
  ) = 0 then
    raise exception
      'CANONICAL_SCHEDULE_GENERATOR_NOT_USED';
  end if;

  if position(
    'now() >= v_start_round.lock_at'
    in v_engine_definition
  ) = 0 then
    raise exception
      'CANONICAL_FIRST_ROUND_LOCK_GUARD_NOT_INSTALLED';
  end if;

  if position(
    'NO_ACTIVE_SCHEDULE'
    in v_engine_definition
  ) = 0 then
    raise exception
      'NO_ACTIVE_SCHEDULE_DECISION_NOT_INSTALLED';
  end if;

  if position(
    'INVALID_LEAGUE_COMPOSITION_CHANGE_REASON'
    in v_engine_definition
  ) = 0 then
    raise exception
      'CANONICAL_COMPOSITION_CHANGE_REASON_GUARD_NOT_INSTALLED';
  end if;

  if position(
    'VOLUNTARY_MEMBER_LEAVE'
    in v_engine_definition
  ) = 0
  or position(
    'ADMIN_MEMBER_REMOVAL'
    in v_engine_definition
  ) = 0 then
    raise exception
      'CANONICAL_COMPOSITION_CHANGE_REASONS_NOT_INSTALLED';
  end if;

  if position(
    'apply_league_composition_change'
    in v_leave_definition
  ) = 0 then
    raise exception
      'VOLUNTARY_DEPARTURE_REGENERATION_NOT_INSTALLED';
  end if;

  if position(
    'apply_league_composition_change'
    in v_remove_definition
  ) = 0 then
    raise exception
      'ADMIN_REMOVAL_REGENERATION_NOT_INSTALLED';
  end if;

  if position(
    'PUBLIC_LEAGUE_ADMIN_MEMBER_REMOVAL_FORBIDDEN'
    in v_remove_definition
  ) = 0 then
    raise exception
      'PUBLIC_LEAGUE_ADMIN_REMOVAL_GUARD_LOST';
  end if;

  if position(
    'regenerate_schedules boolean'
    in v_lock_definition
  ) = 0 then
    raise exception
      'MANUAL_REGENERATION_CONTRACT_LOST';
  end if;

  if position(
    'generate_league_competitions'
    in v_lock_definition
  ) = 0 then
    raise exception
      'MANUAL_CANONICAL_GENERATOR_CALL_LOST';
  end if;
end;
$verification$;


-- ============================================================================
-- 5. Migration audit.
-- ============================================================================

insert into public.competition_audit_log (
  actor_id,
  action,
  aggregate_type,
  aggregate_id,
  before_json,
  after_json,
  reason,
  correlation_id
)
select
  null,
  'pre_deadline_league_composition_auto_regeneration_installed',
  'competition_edition',
  ce.id,
  null,
  jsonb_build_object(
    'migration', '157_pre_deadline_league_composition_auto_regeneration',
    'canonical_generator_reused', true,
    'canonical_deadline_reused', true,
    'composition_governance_engine_installed', true,
    'canonical_change_reasons_enforced', true,
    'voluntary_departure_covered', true,
    'private_admin_removal_covered', true,
    'public_admin_removal_guard_preserved', true,
    'manual_regeneration_path_preserved', true,
    'predictions_modified', false,
    'same_transaction', true
  ),
  'Install atomic pre-deadline schedule regeneration after League membership departure',
  null
from public.competition_editions ce
where ce.active = true
order by ce.starts_at, ce.id
limit 1;

commit;


-- ============================================================================
-- 6. Post-installation diagnostics.
-- ============================================================================

select
  p.oid::regprocedure::text as function_signature,
  pg_get_functiondef(p.oid) like
    '%generate_league_competitions%'
    as uses_canonical_generator,
  pg_get_functiondef(p.oid) like
    '%now() >= v_start_round.lock_at%'
    as has_canonical_deadline_guard,
  pg_get_functiondef(p.oid) like
    '%NO_ACTIVE_SCHEDULE%'
    as handles_missing_active_schedule,
  pg_get_functiondef(p.oid) like
    '%INVALID_LEAGUE_COMPOSITION_CHANGE_REASON%'
    as enforces_canonical_change_reason,
  pg_get_functiondef(p.oid) like
    '%VOLUNTARY_MEMBER_LEAVE%'
    and pg_get_functiondef(p.oid) like
      '%ADMIN_MEMBER_REMOVAL%'
    as has_current_canonical_reasons
from pg_proc p
join pg_namespace n
  on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname =
    'apply_league_composition_change';

select
  p.oid::regprocedure::text as function_signature,
  pg_get_functiondef(p.oid) like
    '%apply_league_composition_change%'
    as uses_composition_governance_engine,
  pg_get_functiondef(p.oid) like
    '%calendar_changed%'
    as records_calendar_changed
from pg_proc p
join pg_namespace n
  on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'leave_league_rpc',
    'remove_league_member_rpc'
  )
order by p.proname;

select
  has_function_privilege(
    'authenticated',
    'public.leave_league_rpc(uuid)',
    'EXECUTE'
  ) as authenticated_can_leave_league,
  has_function_privilege(
    'authenticated',
    'public.remove_league_member_rpc(uuid,uuid,text)',
    'EXECUTE'
  ) as authenticated_can_remove_private_member,
  not has_function_privilege(
    'authenticated',
    'public.apply_league_composition_change(uuid,text)',
    'EXECUTE'
  ) as composition_engine_hidden_from_authenticated;

\echo MILESTONE_12_9_5_12_PRE_DEADLINE_COMPOSITION_AUTO_REGENERATION_READY