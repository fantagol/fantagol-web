-- Migration 026: Unified Strategy Engine Foundation
-- Purpose:
--   - introduce one generic Strategy aggregate for all strategic game modes;
--   - preserve a private mutable workspace;
--   - preserve immutable version history;
--   - prepare official submission, lock and certified scoring in later command migrations.
--
-- This migration intentionally creates the structural foundation only.
-- Mode-specific validation and lifecycle RPCs will be added incrementally
-- after this schema is applied and verified.

begin;

-- ============================================================
-- 1. STRATEGY WORKSPACE
-- ============================================================

create table if not exists public.strategies (
  id uuid primary key default gen_random_uuid(),

  league_id uuid not null
    references public.leagues(id) on delete cascade,

  league_round_id uuid not null
    references public.league_rounds(id) on delete cascade,

  league_member_id uuid not null
    references public.league_members(id) on delete restrict,

  user_id uuid null
    references auth.users(id) on delete set null,

  league_fixture_id uuid null
    references public.league_fixtures(id) on delete set null,

  strategy_type text not null,

  -- Current private workspace.
  payload jsonb not null default '{}'::jsonb,

  status text not null default 'draft',
  source text not null default 'standard',

  -- Current workspace version.
  version integer not null default 1,

  -- Version promoted as the latest official submitted snapshot.
  submitted_version integer null,

  submitted_at timestamptz null,
  official_submitted_at timestamptz null,
  locked_at timestamptz null,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint strategies_type_check
    check (strategy_type in ('fantacalcio', 'one_to_one')),

  constraint strategies_payload_object_check
    check (jsonb_typeof(payload) = 'object'),

  constraint strategies_status_check
    check (status in ('draft', 'submitted', 'locked', 'void')),

  constraint strategies_source_check
    check (source in ('standard', 'admin_recovery', 'postponed_reopen')),

  constraint strategies_version_positive_check
    check (version > 0),

  constraint strategies_submitted_version_positive_check
    check (submitted_version is null or submitted_version > 0),

  constraint strategies_submitted_version_not_future_check
    check (submitted_version is null or submitted_version <= version),

  constraint strategies_lifecycle_dates_check
    check (
      (submitted_at is null or submitted_at >= created_at)
      and
      (
        official_submitted_at is null
        or official_submitted_at >= created_at
      )
      and
      (
        locked_at is null
        or coalesce(official_submitted_at, submitted_at, created_at) <= locked_at
      )
    ),

  constraint strategies_round_member_type_unique
    unique (league_round_id, league_member_id, strategy_type)
);

comment on table public.strategies is
'Unified private strategy workspace. The current payload is mutable before lock; submitted_version identifies the official immutable version.';

comment on column public.strategies.payload is
'Current private workspace document. Mode-specific migrations validate its exact shape.';

comment on column public.strategies.submitted_version is
'Version number of the latest officially submitted Strategy Snapshot.';

create index if not exists strategies_league_idx
  on public.strategies (league_id);

create index if not exists strategies_round_idx
  on public.strategies (league_round_id);

create index if not exists strategies_member_idx
  on public.strategies (league_member_id);

create index if not exists strategies_fixture_idx
  on public.strategies (league_fixture_id)
  where league_fixture_id is not null;

create index if not exists strategies_round_type_idx
  on public.strategies (league_round_id, strategy_type);

create index if not exists strategies_submitted_version_idx
  on public.strategies (
    league_round_id,
    league_member_id,
    strategy_type,
    submitted_version
  );

create index if not exists strategies_status_idx
  on public.strategies (status);


-- ============================================================
-- 2. IMMUTABLE STRATEGY VERSION HISTORY
-- ============================================================

create table if not exists public.strategy_versions (
  id uuid primary key default gen_random_uuid(),

  strategy_id uuid not null
    references public.strategies(id) on delete cascade,

  version integer not null,

  payload jsonb not null,

  status text not null,
  source text not null,

  changed_by_user_id uuid null
    references auth.users(id) on delete set null,

  changed_by_member_id uuid null
    references public.league_members(id) on delete set null,

  changed_at timestamptz not null default now(),

  metadata jsonb not null default '{}'::jsonb,

  constraint strategy_versions_strategy_version_unique
    unique (strategy_id, version),

  constraint strategy_versions_version_positive_check
    check (version > 0),

  constraint strategy_versions_payload_object_check
    check (jsonb_typeof(payload) = 'object'),

  constraint strategy_versions_status_check
    check (status in ('draft', 'submitted', 'locked', 'void')),

  constraint strategy_versions_source_check
    check (source in ('standard', 'admin_recovery', 'postponed_reopen')),

  constraint strategy_versions_metadata_object_check
    check (jsonb_typeof(metadata) = 'object')
);

comment on table public.strategy_versions is
'Append-only immutable history of every Strategy workspace, submission, restoration and lock version.';

create index if not exists strategy_versions_strategy_idx
  on public.strategy_versions (strategy_id, version desc);

create index if not exists strategy_versions_changed_member_idx
  on public.strategy_versions (changed_by_member_id)
  where changed_by_member_id is not null;

create index if not exists strategy_versions_changed_at_idx
  on public.strategy_versions (changed_at desc);


-- ============================================================
-- 3. UPDATED_AT AND VERSION-HISTORY IMMUTABILITY
-- ============================================================

drop trigger if exists set_strategies_updated_at on public.strategies;

create trigger set_strategies_updated_at
before update on public.strategies
for each row
execute function public.set_updated_at();


create or replace function public.protect_strategy_version_immutability()
returns trigger
language plpgsql
security definer
set search_path = public
as $function$
begin
  raise exception using
    errcode = 'P0001',
    message = 'STRATEGY_VERSION_IMMUTABLE';
end;
$function$;

comment on function public.protect_strategy_version_immutability()
is 'Prevents UPDATE and DELETE of append-only Strategy version history.';

drop trigger if exists protect_strategy_versions_immutability
  on public.strategy_versions;

create trigger protect_strategy_versions_immutability
before update or delete on public.strategy_versions
for each row
execute function public.protect_strategy_version_immutability();


-- ============================================================
-- 4. ROW LEVEL SECURITY
-- ============================================================

alter table public.strategies enable row level security;
alter table public.strategy_versions enable row level security;

drop policy if exists strategies_select_visibility
  on public.strategies;

create policy strategies_select_visibility
on public.strategies
for select
to authenticated
using (
  -- Before lock, only the owner can read the private workspace.
  exists (
    select 1
    from public.league_members owner_member
    where owner_member.id = strategies.league_member_id
      and owner_member.user_id = auth.uid()
      and owner_member.status = 'active'
  )
  or
  -- From lock onward, active members of the same league can read it.
  exists (
    select 1
    from public.league_rounds lr
    join public.league_members viewer
      on viewer.league_id = lr.league_id
     and viewer.user_id = auth.uid()
     and viewer.status = 'active'
    where lr.id = strategies.league_round_id
      and lr.status in (
        'predictions_locked',
        'live',
        'waiting_postponed',
        'final_calculable',
        'scoring',
        'official',
        'recalculated',
        'archived'
      )
  )
);

drop policy if exists strategy_versions_select_visibility
  on public.strategy_versions;

create policy strategy_versions_select_visibility
on public.strategy_versions
for select
to authenticated
using (
  exists (
    select 1
    from public.strategies s
    join public.league_members owner_member
      on owner_member.id = s.league_member_id
    where s.id = strategy_versions.strategy_id
      and owner_member.user_id = auth.uid()
      and owner_member.status = 'active'
  )
  or
  exists (
    select 1
    from public.strategies s
    join public.league_rounds lr
      on lr.id = s.league_round_id
    join public.league_members viewer
      on viewer.league_id = lr.league_id
     and viewer.user_id = auth.uid()
     and viewer.status = 'active'
    where s.id = strategy_versions.strategy_id
      and lr.status in (
        'predictions_locked',
        'live',
        'waiting_postponed',
        'final_calculable',
        'scoring',
        'official',
        'recalculated',
        'archived'
      )
  )
);


-- ============================================================
-- 5. PRIVILEGES
-- ============================================================

revoke all on table public.strategies from public;
revoke all on table public.strategies from anon;
revoke insert, update, delete, truncate, references, trigger
  on table public.strategies from authenticated;

grant select on table public.strategies to authenticated;
grant all on table public.strategies to service_role;


revoke all on table public.strategy_versions from public;
revoke all on table public.strategy_versions from anon;
revoke insert, update, delete, truncate, references, trigger
  on table public.strategy_versions from authenticated;

grant select on table public.strategy_versions to authenticated;
grant all on table public.strategy_versions to service_role;


revoke all on function public.protect_strategy_version_immutability()
  from public;
revoke all on function public.protect_strategy_version_immutability()
  from anon;
revoke all on function public.protect_strategy_version_immutability()
  from authenticated;
grant execute on function public.protect_strategy_version_immutability()
  to service_role;


commit;
