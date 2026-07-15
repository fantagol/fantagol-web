-- Migration 034: Strategy Lock Command Engine
-- Purpose:
--   - lock all Strategy aggregates for one League Round;
--   - preserve and restore the latest explicitly submitted official snapshot;
--   - auto-submit only a first never-submitted complete workspace;
--   - void incomplete never-submitted workspaces;
--   - exclude bye fixtures and report missing Strategy workspaces;
--   - expose execution only to service_role.
--
-- Lifecycle rule:
--   explicit official snapshot > unconfirmed workspace
--
-- Existing official snapshot:
--   copy official payload into a new immutable locked version.
--
-- Never-submitted complete workspace:
--   create an official submitted snapshot, then a locked version.
--
-- Never-submitted incomplete workspace:
--   create an immutable void version.
--
-- Missing workspace:
--   no artificial Strategy aggregate is created; it is reported as missing.

begin;

create or replace function public.lock_round_strategies_rpc(
  p_league_round_id uuid
)
returns table (
  league_round_id uuid,
  expected_strategy_count integer,
  locked_strategy_count integer,
  restored_official_strategy_count integer,
  auto_submitted_strategy_count integer,
  voided_strategy_count integer,
  missing_strategy_count integer,
  skipped_bye_fixture_count integer,
  already_terminal_strategy_count integer,
  locked_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_now timestamptz := now();

  v_league_id uuid;
  v_round_status text;
  v_fantagol_round_id uuid;
  v_match_set_version integer;

  v_expected_count integer := 0;
  v_locked_count integer := 0;
  v_restored_count integer := 0;
  v_auto_submitted_count integer := 0;
  v_voided_count integer := 0;
  v_missing_count integer := 0;
  v_bye_count integer := 0;
  v_terminal_count integer := 0;

  v_item record;
  v_strategy public.strategies%rowtype;

  v_workspace_payload jsonb;
  v_official_payload jsonb;

  v_submission_version integer;
  v_locked_version integer;
  v_void_version integer;

  v_workspace_valid boolean;
  v_validation_error text;
begin
  if p_league_round_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_ROUND_REQUIRED';
  end if;

  -- Serialize Strategy locking for the whole League Round.
  perform pg_advisory_xact_lock(
    hashtextextended(
      'strategy-lock:' || p_league_round_id::text,
      0
    )
  );

  select
    lr.league_id,
    lr.status,
    lr.fantagol_round_id,
    fr.official_match_set_version
  into
    v_league_id,
    v_round_status,
    v_fantagol_round_id,
    v_match_set_version
  from public.league_rounds lr
  join public.fantagol_rounds fr
    on fr.id = lr.fantagol_round_id
  where lr.id = p_league_round_id
    and lr.enabled = true
  for update of lr;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_ROUND_NOT_FOUND';
  end if;

  if v_round_status in (
    'live',
    'waiting_postponed',
    'final_calculable',
    'scoring',
    'official',
    'recalculated',
    'archived',
    'cancelled'
  ) then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_ROUND_ALREADY_CLOSED';
  end if;

  if v_round_status not in ('predictions_open', 'predictions_locked') then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_ROUND_NOT_LOCKABLE',
      detail = format('round_status=%s', v_round_status);
  end if;

  if v_match_set_version is null then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_OFFICIAL_MATCH_SET_NOT_FOUND';
  end if;

  -- Count bye fixtures from the active schedule. They intentionally require no
  -- Strategy and therefore do not enter expected_strategy_count.
  select count(*)::integer
  into v_bye_count
  from public.league_fixtures lf
  join public.league_schedule_versions lsv
    on lsv.id = lf.schedule_version_id
   and lsv.active = true
  where lf.league_id = v_league_id
    and lf.league_round_id = p_league_round_id
    and lf.mode in ('fantacalcio', 'one_to_one')
    and lf.is_bye = true;

  -- Every non-bye active fixture contributes one expected Strategy for each
  -- participating member.
  for v_item in
    with active_fixture_members as (
      select
        lf.id as league_fixture_id,
        lf.mode,
        lf.home_member_id as league_member_id
      from public.league_fixtures lf
      join public.league_schedule_versions lsv
        on lsv.id = lf.schedule_version_id
       and lsv.active = true
      where lf.league_id = v_league_id
        and lf.league_round_id = p_league_round_id
        and lf.mode in ('fantacalcio', 'one_to_one')
        and lf.is_bye = false

      union all

      select
        lf.id as league_fixture_id,
        lf.mode,
        lf.away_member_id as league_member_id
      from public.league_fixtures lf
      join public.league_schedule_versions lsv
        on lsv.id = lf.schedule_version_id
       and lsv.active = true
      where lf.league_id = v_league_id
        and lf.league_round_id = p_league_round_id
        and lf.mode in ('fantacalcio', 'one_to_one')
        and lf.is_bye = false
        and lf.away_member_id is not null
    )
    select
      afm.league_fixture_id,
      afm.mode,
      afm.league_member_id
    from active_fixture_members afm
    order by
      afm.mode,
      afm.league_fixture_id,
      afm.league_member_id
  loop
    v_expected_count := v_expected_count + 1;

    select s.*
    into v_strategy
    from public.strategies s
    where s.league_fixture_id = v_item.league_fixture_id
      and s.league_member_id = v_item.league_member_id
    for update;

    if not found then
      v_missing_count := v_missing_count + 1;
      continue;
    end if;

    if v_strategy.status in ('locked', 'void') then
      v_terminal_count := v_terminal_count + 1;
      continue;
    end if;

    -- --------------------------------------------------------
    -- A. Explicit official snapshot exists
    -- --------------------------------------------------------

    if v_strategy.submitted_version is not null then
      select sv.payload
      into v_official_payload
      from public.strategy_versions sv
      where sv.strategy_id = v_strategy.id
        and sv.version = v_strategy.submitted_version;

      if v_official_payload is null then
        raise exception using
          errcode = 'P0001',
          message = 'STRATEGY_OFFICIAL_VERSION_NOT_FOUND',
          detail = format(
            'strategy_id=%s submitted_version=%s',
            v_strategy.id,
            v_strategy.submitted_version
          );
      end if;

      -- Revalidate the official payload against the certified Match Set.
      perform public.validate_strategy_submission_payload(
        v_item.mode,
        v_official_payload,
        p_league_round_id
      );

      v_locked_version := v_strategy.version + 1;

      insert into public.strategy_versions (
        strategy_id,
        version,
        payload,
        status,
        source,
        changed_by_user_id,
        changed_by_member_id,
        changed_at,
        metadata
      )
      values (
        v_strategy.id,
        v_locked_version,
        v_official_payload,
        'locked',
        v_strategy.source,
        null,
        null,
        v_now,
        jsonb_build_object(
          'operation',
          case
            when v_strategy.version <> v_strategy.submitted_version
              or v_strategy.status <> 'submitted'
            then 'restore_official_and_lock'
            else 'lock_official'
          end,
          'mode', v_item.mode,
          'schema_version',
            (v_official_payload ->> 'schema_version')::integer,
          'match_set_version', v_match_set_version,
          'official_submitted_version', v_strategy.submitted_version,
          'discarded_workspace_version',
            case
              when v_strategy.version <> v_strategy.submitted_version
              then v_strategy.version
              else null
            end,
          'league_round_id', p_league_round_id,
          'league_fixture_id', v_item.league_fixture_id
        )
      );

      update public.strategies s
      set
        status = 'locked',
        version = v_locked_version,
        locked_at = v_now
      where s.id = v_strategy.id;

      v_locked_count := v_locked_count + 1;

      if v_strategy.version <> v_strategy.submitted_version
         or v_strategy.status <> 'submitted' then
        v_restored_count := v_restored_count + 1;
      end if;

      continue;
    end if;

    -- --------------------------------------------------------
    -- B. No official snapshot: validate the first workspace
    -- --------------------------------------------------------

    select sv.payload
    into v_workspace_payload
    from public.strategy_versions sv
    where sv.strategy_id = v_strategy.id
      and sv.version = v_strategy.version;

    if v_workspace_payload is null then
      raise exception using
        errcode = 'P0001',
        message = 'STRATEGY_WORKSPACE_VERSION_NOT_FOUND',
        detail = format(
          'strategy_id=%s workspace_version=%s',
          v_strategy.id,
          v_strategy.version
        );
    end if;

    v_workspace_valid := true;
    v_validation_error := null;

    begin
      perform public.validate_strategy_submission_payload(
        v_item.mode,
        v_workspace_payload,
        p_league_round_id
      );
    exception
      when sqlstate 'P0001' then
        v_workspace_valid := false;
        v_validation_error := sqlerrm;
    end;

    if v_workspace_valid then
      -- First complete never-submitted workspace:
      -- 1) create the official submitted snapshot;
      -- 2) create the locked state from that exact payload.
      v_submission_version := v_strategy.version + 1;
      v_locked_version := v_strategy.version + 2;

      insert into public.strategy_versions (
        strategy_id,
        version,
        payload,
        status,
        source,
        changed_by_user_id,
        changed_by_member_id,
        changed_at,
        metadata
      )
      values (
        v_strategy.id,
        v_submission_version,
        v_workspace_payload,
        'submitted',
        v_strategy.source,
        null,
        null,
        v_now,
        jsonb_build_object(
          'operation', 'auto_submit_first_complete_workspace_at_lock',
          'mode', v_item.mode,
          'schema_version',
            (v_workspace_payload ->> 'schema_version')::integer,
          'match_set_version', v_match_set_version,
          'workspace_source_version', v_strategy.version,
          'official_submitted_version', v_submission_version,
          'league_round_id', p_league_round_id,
          'league_fixture_id', v_item.league_fixture_id
        )
      );

      insert into public.strategy_versions (
        strategy_id,
        version,
        payload,
        status,
        source,
        changed_by_user_id,
        changed_by_member_id,
        changed_at,
        metadata
      )
      values (
        v_strategy.id,
        v_locked_version,
        v_workspace_payload,
        'locked',
        v_strategy.source,
        null,
        null,
        v_now,
        jsonb_build_object(
          'operation', 'lock_auto_submitted_strategy',
          'mode', v_item.mode,
          'schema_version',
            (v_workspace_payload ->> 'schema_version')::integer,
          'match_set_version', v_match_set_version,
          'official_submitted_version', v_submission_version,
          'league_round_id', p_league_round_id,
          'league_fixture_id', v_item.league_fixture_id
        )
      );

      update public.strategies s
      set
        status = 'locked',
        version = v_locked_version,
        submitted_version = v_submission_version,
        submitted_at = v_now,
        official_submitted_at = v_now,
        locked_at = v_now
      where s.id = v_strategy.id;

      v_auto_submitted_count := v_auto_submitted_count + 1;
      v_locked_count := v_locked_count + 1;
    else
      -- Incomplete never-submitted workspace becomes void.
      v_void_version := v_strategy.version + 1;

      insert into public.strategy_versions (
        strategy_id,
        version,
        payload,
        status,
        source,
        changed_by_user_id,
        changed_by_member_id,
        changed_at,
        metadata
      )
      values (
        v_strategy.id,
        v_void_version,
        v_workspace_payload,
        'void',
        v_strategy.source,
        null,
        null,
        v_now,
        jsonb_build_object(
          'operation', 'incomplete_workspace_voided_at_lock',
          'mode', v_item.mode,
          'schema_version',
            case
              when jsonb_typeof(v_workspace_payload -> 'schema_version') = 'number'
              then (v_workspace_payload ->> 'schema_version')::integer
              else null
            end,
          'match_set_version', v_match_set_version,
          'workspace_source_version', v_strategy.version,
          'validation_error', v_validation_error,
          'league_round_id', p_league_round_id,
          'league_fixture_id', v_item.league_fixture_id
        )
      );

      update public.strategies s
      set
        status = 'void',
        version = v_void_version,
        locked_at = v_now
      where s.id = v_strategy.id;

      v_voided_count := v_voided_count + 1;
    end if;
  end loop;

  return query
  select
    p_league_round_id,
    v_expected_count,
    v_locked_count,
    v_restored_count,
    v_auto_submitted_count,
    v_voided_count,
    v_missing_count,
    v_bye_count,
    v_terminal_count,
    v_now;
end;
$function$;

comment on function public.lock_round_strategies_rpc(uuid)
is 'Locks all non-bye active-fixture Strategies for one League Round. Explicit official snapshots are authoritative; only a first complete never-submitted workspace is auto-submitted; incomplete workspaces become void; missing workspaces are reported.';


-- ============================================================
-- PRIVILEGES
-- ============================================================

revoke all on function public.lock_round_strategies_rpc(uuid)
  from public;
revoke all on function public.lock_round_strategies_rpc(uuid)
  from anon;
revoke all on function public.lock_round_strategies_rpc(uuid)
  from authenticated;
grant execute on function public.lock_round_strategies_rpc(uuid)
  to service_role;

commit;
