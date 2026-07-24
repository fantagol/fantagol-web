-- ============================================================================
-- FANTAGOL
-- PUBLIC LEAGUE VISIBILITY AND SCHEDULE FOUNDATION E2E TEST v1
-- Validates migration 141.
--
-- The test is non-destructive and runs inside a transaction that is rolled back.
-- Execute after applying migration 141.
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 1. STRUCTURAL CONTRACT
-- ----------------------------------------------------------------------------

do $$
declare
  v_missing text[] := array[]::text[];
  v_column text;
begin
  foreach v_column in array array[
    'visibility',
    'first_useful_kickoff_at',
    'automatic_join_close_at',
    'inactivity_evaluation_round_id',
    'inactivity_evaluation_at',
    'public_schedule_version'
  ]
  loop
    if not exists (
      select 1
      from information_schema.columns
      where table_schema = 'public'
        and table_name = 'leagues'
        and column_name = v_column
    ) then
      v_missing := array_append(v_missing, v_column);
    end if;
  end loop;

  if cardinality(v_missing) > 0 then
    raise exception
      'PUBLIC_LEAGUE_141_COLUMN_ASSERTION_FAILED: missing columns %',
      array_to_string(v_missing, ', ');
  end if;
end;
$$;

do $$
declare
  v_constraint text;
begin
  foreach v_constraint in array array[
    'leagues_inactivity_evaluation_round_id_fkey',
    'leagues_visibility_check',
    'leagues_public_schedule_version_positive_check',
    'leagues_public_schedule_required_check',
    'leagues_public_join_close_exact_check',
    'leagues_public_inactivity_after_start_check',
    'leagues_public_schedule_all_or_none_check'
  ]
  loop
    if not exists (
      select 1
      from pg_constraint
      where conrelid = 'public.leagues'::regclass
        and conname = v_constraint
    ) then
      raise exception
        'PUBLIC_LEAGUE_141_CONSTRAINT_ASSERTION_FAILED: missing constraint %',
        v_constraint;
    end if;
  end loop;
end;
$$;

do $$
declare
  v_index text;
begin
  foreach v_index in array array[
    'leagues_visibility_idx',
    'leagues_public_catalog_foundation_idx',
    'leagues_public_join_close_due_idx',
    'leagues_public_inactivity_due_idx',
    'leagues_inactivity_evaluation_round_idx'
  ]
  loop
    if to_regclass('public.' || v_index) is null then
      raise exception
        'PUBLIC_LEAGUE_141_INDEX_ASSERTION_FAILED: missing index %',
        v_index;
    end if;
  end loop;
end;
$$;

do $$
begin
  if to_regprocedure(
    'public.resolve_public_league_schedule_internal(uuid,timestamp with time zone)'
  ) is null then
    raise exception
      'PUBLIC_LEAGUE_141_FUNCTION_ASSERTION_FAILED: internal resolver missing';
  end if;

  if to_regprocedure(
    'public.resolve_public_league_schedule_rpc(uuid,timestamp with time zone)'
  ) is null then
    raise exception
      'PUBLIC_LEAGUE_141_FUNCTION_ASSERTION_FAILED: preview RPC missing';
  end if;
end;
$$;

-- ----------------------------------------------------------------------------
-- 2. BACKFILL AND DEFAULT CONTRACT
-- ----------------------------------------------------------------------------

do $$
begin
  if exists (
    select 1
    from public.leagues
    where visibility is distinct from 'private'
      and visibility is distinct from 'public'
  ) then
    raise exception
      'PUBLIC_LEAGUE_141_BACKFILL_ASSERTION_FAILED: invalid visibility found';
  end if;

  if exists (
    select 1
    from public.leagues
    where public_schedule_version <= 0
  ) then
    raise exception
      'PUBLIC_LEAGUE_141_VERSION_ASSERTION_FAILED: non-positive schedule version found';
  end if;
end;
$$;

-- ----------------------------------------------------------------------------
-- 3. FUNCTIONAL RESOLVER CONTRACT
-- ----------------------------------------------------------------------------

do $$
declare
  v_edition_id uuid;
  v_reference_at timestamptz;
  v_first_round_start timestamptz;
  v_result record;
  v_expected_start_round_id uuid;
  v_expected_inactivity_round_id uuid;
begin
  select fr.edition_id, min(fr.starts_at)
  into v_edition_id, v_first_round_start
  from public.fantagol_rounds fr
  join public.competition_editions ce on ce.id = fr.edition_id
  where fr.active = true
    and fr.status not in ('draft', 'cancelled', 'final_official', 'recalculated')
    and fr.starts_at is not null
    and ce.active = true
    and ce.status in ('scheduled', 'active')
  group by fr.edition_id
  having count(*) filter (
    where fr.active = true
      and fr.status not in ('draft', 'cancelled')
      and fr.starts_at is not null
  ) >= 2
  order by min(fr.starts_at), fr.edition_id
  limit 1;

  if v_edition_id is null then
    raise exception
      'PUBLIC_LEAGUE_141_FIXTURE_ASSERTION_FAILED: no edition with at least two usable rounds';
  end if;

  v_reference_at := v_first_round_start - interval '48 hours';

  select fr.id
  into v_expected_start_round_id
  from public.fantagol_rounds fr
  where fr.edition_id = v_edition_id
    and fr.active = true
    and fr.status not in ('draft', 'cancelled', 'final_official', 'recalculated')
    and fr.starts_at is not null
    and v_reference_at < fr.starts_at - interval '24 hours'
  order by fr.sequence, fr.starts_at, fr.id
  limit 1;

  select fr.id
  into v_expected_inactivity_round_id
  from public.fantagol_rounds fr
  join public.fantagol_rounds start_fr
    on start_fr.id = v_expected_start_round_id
  where fr.edition_id = v_edition_id
    and fr.active = true
    and fr.status not in ('draft', 'cancelled')
    and fr.starts_at is not null
    and (
      fr.sequence > start_fr.sequence
      or (
        fr.sequence = start_fr.sequence
        and fr.starts_at > start_fr.starts_at
      )
      or (
        fr.sequence = start_fr.sequence
        and fr.starts_at = start_fr.starts_at
        and fr.id > start_fr.id
      )
    )
  order by fr.sequence, fr.starts_at, fr.id
  limit 1;

  select *
  into v_result
  from public.resolve_public_league_schedule_internal(
    v_edition_id,
    v_reference_at
  );

  if v_result.starts_from_fantagol_round_id is distinct from v_expected_start_round_id then
    raise exception
      'PUBLIC_LEAGUE_141_START_ROUND_ASSERTION_FAILED: expected %, received %',
      v_expected_start_round_id,
      v_result.starts_from_fantagol_round_id;
  end if;

  if v_result.inactivity_evaluation_round_id is distinct from v_expected_inactivity_round_id then
    raise exception
      'PUBLIC_LEAGUE_141_INACTIVITY_ROUND_ASSERTION_FAILED: expected %, received %',
      v_expected_inactivity_round_id,
      v_result.inactivity_evaluation_round_id;
  end if;

  if v_result.automatic_join_close_at
     is distinct from v_result.first_useful_kickoff_at - interval '24 hours' then
    raise exception
      'PUBLIC_LEAGUE_141_JOIN_CLOSE_ASSERTION_FAILED';
  end if;

  if v_result.inactivity_evaluation_at <= v_result.first_useful_kickoff_at then
    raise exception
      'PUBLIC_LEAGUE_141_INACTIVITY_TIME_ASSERTION_FAILED';
  end if;

  if v_result.schedule_version <> 1 then
    raise exception
      'PUBLIC_LEAGUE_141_SCHEDULE_VERSION_ASSERTION_FAILED: received %',
      v_result.schedule_version;
  end if;
end;
$$;

-- ----------------------------------------------------------------------------
-- 4. BOUNDARY: EXACTLY 24 HOURS IS NOT ELIGIBLE
-- ----------------------------------------------------------------------------

do $$
declare
  v_edition_id uuid;
  v_round_id uuid;
  v_round_start timestamptz;
  v_result record;
begin
  select fr.edition_id, fr.id, fr.starts_at
  into v_edition_id, v_round_id, v_round_start
  from public.fantagol_rounds fr
  join public.competition_editions ce on ce.id = fr.edition_id
  where fr.active = true
    and fr.status not in ('draft', 'cancelled', 'final_official', 'recalculated')
    and fr.starts_at is not null
    and ce.active = true
    and ce.status in ('scheduled', 'active')
    and exists (
      select 1
      from public.fantagol_rounds next_fr
      where next_fr.edition_id = fr.edition_id
        and next_fr.active = true
        and next_fr.status not in ('draft', 'cancelled')
        and next_fr.starts_at is not null
        and next_fr.sequence > fr.sequence
    )
  order by fr.starts_at, fr.sequence, fr.id
  limit 1;

  if v_round_id is null then
    raise exception
      'PUBLIC_LEAGUE_141_BOUNDARY_FIXTURE_ASSERTION_FAILED';
  end if;

  select *
  into v_result
  from public.resolve_public_league_schedule_internal(
    v_edition_id,
    v_round_start - interval '24 hours'
  );

  if v_result.starts_from_fantagol_round_id = v_round_id then
    raise exception
      'PUBLIC_LEAGUE_141_BOUNDARY_ASSERTION_FAILED: round at exact 24h was accepted';
  end if;
end;
$$;

-- ----------------------------------------------------------------------------
-- 5. PRIVILEGE CONTRACT
-- ----------------------------------------------------------------------------

do $$
begin
  if has_function_privilege(
    'anon',
    'public.resolve_public_league_schedule_rpc(uuid,timestamp with time zone)',
    'EXECUTE'
  ) then
    raise exception
      'PUBLIC_LEAGUE_141_PRIVILEGE_ASSERTION_FAILED: anon can execute preview RPC';
  end if;

  if not has_function_privilege(
    'authenticated',
    'public.resolve_public_league_schedule_rpc(uuid,timestamp with time zone)',
    'EXECUTE'
  ) then
    raise exception
      'PUBLIC_LEAGUE_141_PRIVILEGE_ASSERTION_FAILED: authenticated cannot execute preview RPC';
  end if;

  if has_function_privilege(
    'authenticated',
    'public.resolve_public_league_schedule_internal(uuid,timestamp with time zone)',
    'EXECUTE'
  ) then
    raise exception
      'PUBLIC_LEAGUE_141_PRIVILEGE_ASSERTION_FAILED: authenticated can execute internal resolver';
  end if;
end;
$$;

select
  'PUBLIC_LEAGUE_VISIBILITY_AND_SCHEDULE_FOUNDATION_E2E_TEST_PASSED' as certification_marker;

rollback;
