-- ============================================================================
-- FANTAGOL
-- MIGRATION 146
-- PUBLIC LEAGUE ADMIN LIFECYCLE CONSTRAINT HOTFIX
--
-- Milestone 12.9.4.4
--
-- Purpose:
--   - align public league schedule constraints with the admin-controlled
--     lifecycle introduced by migration 145;
--   - retain the canonical starting round and first useful kickoff;
--   - require automatic registration-close and inactivity fields to remain null;
--   - restore create_league_v2_rpc public league insertion.
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 1. NORMALIZE THE ADMIN-CONTROLLED PUBLIC LIFECYCLE
-- ----------------------------------------------------------------------------

update public.leagues
set
  automatic_join_close_at = null,
  inactivity_evaluation_round_id = null,
  inactivity_evaluation_at = null
where visibility = 'public'
  and (
    automatic_join_close_at is not null
    or inactivity_evaluation_round_id is not null
    or inactivity_evaluation_at is not null
  );

-- ----------------------------------------------------------------------------
-- 2. REPLACE LEGACY AUTOMATIC-LIFECYCLE CONSTRAINTS
-- ----------------------------------------------------------------------------

alter table public.leagues
  drop constraint if exists leagues_public_schedule_required_check;

alter table public.leagues
  drop constraint if exists leagues_public_schedule_all_or_none_check;

alter table public.leagues
  add constraint leagues_public_schedule_required_check
  check (
    visibility <> 'public'
    or (
      starts_from_fantagol_round_id is not null
      and first_useful_kickoff_at is not null
      and automatic_join_close_at is null
      and inactivity_evaluation_round_id is null
      and inactivity_evaluation_at is null
    )
  );

alter table public.leagues
  add constraint leagues_public_schedule_all_or_none_check
  check (
    (
      first_useful_kickoff_at is null
      and automatic_join_close_at is null
      and inactivity_evaluation_round_id is null
      and inactivity_evaluation_at is null
    )
    or
    (
      starts_from_fantagol_round_id is not null
      and first_useful_kickoff_at is not null
      and automatic_join_close_at is null
      and inactivity_evaluation_round_id is null
      and inactivity_evaluation_at is null
    )
  );

-- ----------------------------------------------------------------------------
-- 3. UPDATED CONSTRAINT DOCUMENTATION
-- ----------------------------------------------------------------------------

comment on constraint leagues_public_schedule_required_check
on public.leagues
is
'Public leagues must retain their canonical starting round and first useful kickoff. Automatic registration-close and inactivity-cleanup fields must remain null under the admin-controlled lifecycle.';

comment on constraint leagues_public_schedule_all_or_none_check
on public.leagues
is
'Schedule snapshots may be absent, or may contain the canonical starting round and first useful kickoff. Deprecated automatic lifecycle fields must remain null.';

-- ----------------------------------------------------------------------------
-- 4. STRUCTURAL AND DATA VERIFICATION
-- ----------------------------------------------------------------------------

do $verification$
declare
  v_required_definition text;
  v_all_or_none_definition text;
  v_invalid_public_leagues bigint;
begin
  select pg_get_constraintdef(c.oid)
  into v_required_definition
  from pg_constraint c
  where c.conrelid = 'public.leagues'::regclass
    and c.conname = 'leagues_public_schedule_required_check';

  if v_required_definition is null then
    raise exception
      'PUBLIC_LEAGUE_REQUIRED_CONSTRAINT_MISSING';
  end if;

  if position(
    'automatic_join_close_at IS NULL'
    in v_required_definition
  ) = 0 then
    raise exception
      'PUBLIC_LEAGUE_REQUIRED_CONSTRAINT_ADMIN_POLICY_MISSING';
  end if;

  select pg_get_constraintdef(c.oid)
  into v_all_or_none_definition
  from pg_constraint c
  where c.conrelid = 'public.leagues'::regclass
    and c.conname = 'leagues_public_schedule_all_or_none_check';

  if v_all_or_none_definition is null then
    raise exception
      'PUBLIC_LEAGUE_ALL_OR_NONE_CONSTRAINT_MISSING';
  end if;

  if position(
    'inactivity_evaluation_at IS NULL'
    in v_all_or_none_definition
  ) = 0 then
    raise exception
      'PUBLIC_LEAGUE_ALL_OR_NONE_ADMIN_POLICY_MISSING';
  end if;

  select count(*)
  into v_invalid_public_leagues
  from public.leagues l
  where l.visibility = 'public'
    and (
      l.starts_from_fantagol_round_id is null
      or l.first_useful_kickoff_at is null
      or l.automatic_join_close_at is not null
      or l.inactivity_evaluation_round_id is not null
      or l.inactivity_evaluation_at is not null
    );

  if v_invalid_public_leagues <> 0 then
    raise exception
      'INVALID_ADMIN_CONTROLLED_PUBLIC_LEAGUES_REMAIN: %',
      v_invalid_public_leagues;
  end if;

  raise notice
    'PUBLIC_LEAGUE_ADMIN_LIFECYCLE_CONSTRAINT_HOTFIX_OK';
end;
$verification$;

commit;