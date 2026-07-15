-- Migration 028: Strategy Fixture Identity Refinement
-- Purpose:
--   - make the active League Fixture the canonical context of every Strategy;
--   - remove duplicated strategy_type state;
--   - enforce one Strategy per fixture and participating member;
--   - prevent strategies for inactive schedule versions, mismatched league/round,
--     non-participating members and bye fixtures.
--
-- Preconditions:
--   - Migrations 026 and 027 have been applied;
--   - no Strategy command RPCs are active yet;
--   - no production Strategy rows exist.

begin;

-- ============================================================
-- 1. DEFENSIVE PRECONDITION
-- ============================================================

do $block$
begin
  if exists (select 1 from public.strategies limit 1) then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_FIXTURE_REFINEMENT_REQUIRES_EMPTY_TABLE';
  end if;
end;
$block$;


-- ============================================================
-- 2. REMOVE REDUNDANT STRATEGY TYPE
-- ============================================================

drop index if exists public.strategies_round_type_idx;
drop index if exists public.strategies_submitted_version_idx;

alter table public.strategies
  drop constraint if exists strategies_round_member_type_unique;

alter table public.strategies
  drop constraint if exists strategies_type_check;

alter table public.strategies
  drop column if exists strategy_type;


-- ============================================================
-- 3. REQUIRE FIXTURE IDENTITY
-- ============================================================

alter table public.strategies
  alter column league_fixture_id set not null;

alter table public.strategies
  add constraint strategies_fixture_member_unique
  unique (league_fixture_id, league_member_id);

create index if not exists strategies_round_member_idx
  on public.strategies (league_round_id, league_member_id);

create index if not exists strategies_submitted_version_idx
  on public.strategies (
    league_round_id,
    league_member_id,
    submitted_version
  );


-- ============================================================
-- 4. CROSS-ENTITY CONSISTENCY
-- ============================================================

create or replace function public.validate_strategy_fixture_context()
returns trigger
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_fixture public.league_fixtures%rowtype;
  v_schedule_active boolean;
  v_member_league_id uuid;
  v_member_status text;
begin
  select lf.*
  into v_fixture
  from public.league_fixtures lf
  where lf.id = new.league_fixture_id;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_FIXTURE_NOT_FOUND';
  end if;

  select lsv.active
  into v_schedule_active
  from public.league_schedule_versions lsv
  where lsv.id = v_fixture.schedule_version_id;

  if coalesce(v_schedule_active, false) is not true then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_FIXTURE_SCHEDULE_NOT_ACTIVE';
  end if;

  if v_fixture.is_bye then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_NOT_REQUIRED_FOR_BYE';
  end if;

  if new.league_id <> v_fixture.league_id then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_LEAGUE_FIXTURE_MISMATCH';
  end if;

  if new.league_round_id <> v_fixture.league_round_id then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_ROUND_FIXTURE_MISMATCH';
  end if;

  select lm.league_id, lm.status
  into v_member_league_id, v_member_status
  from public.league_members lm
  where lm.id = new.league_member_id;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_MEMBER_NOT_FOUND';
  end if;

  if v_member_league_id <> new.league_id then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_MEMBER_LEAGUE_MISMATCH';
  end if;

  if v_member_status <> 'active' then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_MEMBER_NOT_ACTIVE';
  end if;

  if new.league_member_id <> v_fixture.home_member_id
     and new.league_member_id is distinct from v_fixture.away_member_id then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_MEMBER_NOT_IN_FIXTURE';
  end if;

  if new.user_id is not null
     and not exists (
       select 1
       from public.league_members lm
       where lm.id = new.league_member_id
         and lm.user_id = new.user_id
     ) then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_USER_MEMBER_MISMATCH';
  end if;

  return new;
end;
$function$;

comment on function public.validate_strategy_fixture_context()
is 'Validates active schedule ownership, fixture participation, non-bye status and league/round/member consistency for every Strategy aggregate.';

drop trigger if exists validate_strategy_fixture_context
  on public.strategies;

create trigger validate_strategy_fixture_context
before insert or update of
  league_id,
  league_round_id,
  league_member_id,
  user_id,
  league_fixture_id
on public.strategies
for each row
execute function public.validate_strategy_fixture_context();


-- ============================================================
-- 5. DOCUMENT THE FINAL IDENTITY MODEL
-- ============================================================

comment on table public.strategies is
'Unified Strategy lifecycle aggregate. Every Strategy belongs to one active non-bye League Fixture and one participating League Member. The mode is inherited from league_fixtures.mode. Payloads exist only in immutable strategy_versions rows.';

comment on column public.strategies.league_fixture_id is
'Canonical Strategy context. Must reference an active, non-bye fixture containing league_member_id.';

comment on column public.strategies.league_id is
'Denormalized query and RLS key validated against league_fixture_id.';

comment on column public.strategies.league_round_id is
'Denormalized query and lifecycle key validated against league_fixture_id.';


-- ============================================================
-- 6. PRIVILEGES
-- ============================================================

revoke all on function public.validate_strategy_fixture_context()
  from public;
revoke all on function public.validate_strategy_fixture_context()
  from anon;
revoke all on function public.validate_strategy_fixture_context()
  from authenticated;
grant execute on function public.validate_strategy_fixture_context()
  to service_role;


commit;
