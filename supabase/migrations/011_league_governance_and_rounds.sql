-- ============================================================
-- FANTAGOL
-- MIGRATION 011
-- LEAGUE GOVERNANCE, LIFECYCLE AND LEAGUE ROUNDS FOUNDATION
--
-- Covers:
--   - league lifecycle and late-season start
--   - roster lock / reopen before first official score
--   - admin / vice / member governance
--   - automatic succession data model
--   - league rounds with independent numbering
--   - partial prediction recovery after global lock
--   - immutable public admin activity log
--
-- Notes:
--   - preserves legacy leagues.status for frontend/RPC compatibility
--   - behavioural rules will be enforced by controlled RPCs
--   - direct client writes remain disabled by RLS
-- ============================================================

begin;

-- ------------------------------------------------------------
-- 1. EXTEND LEAGUES
-- ------------------------------------------------------------

alter table public.leagues
  add column if not exists edition_id uuid,
  add column if not exists lifecycle_status text not null default 'draft',
  add column if not exists roster_status text not null default 'open',
  add column if not exists roster_locked_at timestamptz,
  add column if not exists started_at timestamptz,
  add column if not exists reopened_at timestamptz,
  add column if not exists first_scored_at timestamptz,
  add column if not exists starts_from_fantagol_round_id uuid,
  add column if not exists vice_required boolean not null default true,
  add column if not exists updated_at timestamptz not null default now(),
  add column if not exists version integer not null default 1;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'leagues_edition_id_fkey'
  ) then
    alter table public.leagues
      add constraint leagues_edition_id_fkey
      foreign key (edition_id)
      references public.competition_editions(id)
      on delete restrict;
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'leagues_starts_from_fantagol_round_id_fkey'
  ) then
    alter table public.leagues
      add constraint leagues_starts_from_fantagol_round_id_fkey
      foreign key (starts_from_fantagol_round_id)
      references public.fantagol_rounds(id)
      on delete restrict;
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'leagues_lifecycle_status_check'
  ) then
    alter table public.leagues
      add constraint leagues_lifecycle_status_check
      check (
        lifecycle_status in (
          'draft',
          'open',
          'locked',
          'active',
          'completed',
          'archived'
        )
      );
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'leagues_roster_status_check'
  ) then
    alter table public.leagues
      add constraint leagues_roster_status_check
      check (roster_status in ('open', 'locked'));
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'leagues_version_positive_check'
  ) then
    alter table public.leagues
      add constraint leagues_version_positive_check
      check (version > 0);
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'leagues_roster_lock_dates_check'
  ) then
    alter table public.leagues
      add constraint leagues_roster_lock_dates_check
      check (
        roster_status = 'open'
        or
        (roster_status = 'locked' and roster_locked_at is not null)
      );
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'leagues_first_scored_after_started_check'
  ) then
    alter table public.leagues
      add constraint leagues_first_scored_after_started_check
      check (
        first_scored_at is null
        or started_at is null
        or first_scored_at >= started_at
      );
  end if;
end;
$$;

create index if not exists leagues_edition_id_idx
  on public.leagues(edition_id);

create index if not exists leagues_starts_from_round_idx
  on public.leagues(starts_from_fantagol_round_id);

create index if not exists leagues_lifecycle_status_idx
  on public.leagues(lifecycle_status);

-- ------------------------------------------------------------
-- 2. GOVERNANCE ROLES
-- ------------------------------------------------------------

alter table public.league_members
  drop constraint if exists league_members_role_check;

alter table public.league_members
  add constraint league_members_role_check
  check (role in ('admin', 'vice', 'member'));

-- At most one active admin and one active vice per league.
create unique index if not exists league_members_one_active_admin_idx
  on public.league_members(league_id)
  where role = 'admin' and status = 'active';

create unique index if not exists league_members_one_active_vice_idx
  on public.league_members(league_id)
  where role = 'vice' and status = 'active';

create index if not exists league_members_active_role_idx
  on public.league_members(league_id, role)
  where status = 'active';

-- ------------------------------------------------------------
-- 3. LEAGUE ROUNDS
-- ------------------------------------------------------------

create table if not exists public.league_rounds (
  id uuid primary key default gen_random_uuid(),
  league_id uuid not null
    references public.leagues(id)
    on delete cascade,
  fantagol_round_id uuid not null
    references public.fantagol_rounds(id)
    on delete restrict,
  league_round_number integer not null,
  status text not null default 'scheduled',
  enabled boolean not null default true,
  first_official_score_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version integer not null default 1,

  constraint league_rounds_number_positive_check
    check (league_round_number > 0),

  constraint league_rounds_status_check
    check (
      status in (
        'scheduled',
        'predictions_open',
        'predictions_locked',
        'live',
        'scoring',
        'official',
        'archived',
        'cancelled'
      )
    ),

  constraint league_rounds_version_positive_check
    check (version > 0),

  constraint league_rounds_league_fantagol_unique
    unique (league_id, fantagol_round_id),

  constraint league_rounds_league_number_unique
    unique (league_id, league_round_number)
);

create index if not exists league_rounds_league_id_idx
  on public.league_rounds(league_id);

create index if not exists league_rounds_fantagol_round_id_idx
  on public.league_rounds(fantagol_round_id);

create index if not exists league_rounds_status_idx
  on public.league_rounds(status);

-- ------------------------------------------------------------
-- 4. PARTIAL PREDICTION RECOVERY
-- ------------------------------------------------------------

create table if not exists public.prediction_recovery_authorizations (
  id uuid primary key default gen_random_uuid(),
  league_id uuid not null
    references public.leagues(id)
    on delete cascade,
  league_round_id uuid not null
    references public.league_rounds(id)
    on delete cascade,
  target_member_id uuid not null
    references public.league_members(id)
    on delete restrict,
  opened_by_member_id uuid not null
    references public.league_members(id)
    on delete restrict,
  status text not null default 'open',
  opened_at timestamptz not null default now(),
  expires_at timestamptz not null,
  used_at timestamptz,
  revoked_at timestamptz,
  reason text,
  eligible_match_count integer not null,
  excluded_started_match_count integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version integer not null default 1,

  constraint prediction_recovery_status_check
    check (status in ('open', 'used', 'expired', 'revoked')),

  constraint prediction_recovery_dates_check
    check (
      expires_at > opened_at
      and (used_at is null or used_at >= opened_at)
      and (revoked_at is null or revoked_at >= opened_at)
    ),

  constraint prediction_recovery_eligible_positive_check
    check (eligible_match_count > 0),

  constraint prediction_recovery_excluded_nonnegative_check
    check (excluded_started_match_count >= 0),

  constraint prediction_recovery_version_positive_check
    check (version > 0),

  constraint prediction_recovery_member_round_unique
    unique (league_round_id, target_member_id)
);

create index if not exists prediction_recovery_league_round_idx
  on public.prediction_recovery_authorizations(league_round_id);

create index if not exists prediction_recovery_target_member_idx
  on public.prediction_recovery_authorizations(target_member_id);

create index if not exists prediction_recovery_open_idx
  on public.prediction_recovery_authorizations(status, expires_at)
  where status = 'open';

-- ------------------------------------------------------------
-- 5. PUBLIC LEAGUE ADMIN EVENT LOG
-- ------------------------------------------------------------

create table if not exists public.league_admin_events (
  id uuid primary key default gen_random_uuid(),
  league_id uuid not null
    references public.leagues(id)
    on delete cascade,
  actor_member_id uuid
    references public.league_members(id)
    on delete set null,
  actor_user_id uuid
    references auth.users(id)
    on delete set null,
  actor_type text not null default 'member',
  action_type text not null,
  target_member_id uuid
    references public.league_members(id)
    on delete set null,
  league_round_id uuid
    references public.league_rounds(id)
    on delete set null,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),

  constraint league_admin_events_actor_type_check
    check (actor_type in ('member', 'system')),

  constraint league_admin_events_action_type_check
    check (
      action_type in (
        'roster_locked',
        'roster_reopened',
        'league_started',
        'league_archived',
        'vice_assigned',
        'vice_revoked',
        'admin_resigned',
        'admin_demoted_for_inactivity',
        'vice_promoted_to_admin',
        'admin_assigned_from_ranking',
        'admin_assigned_by_seniority',
        'member_removed',
        'member_withdrawn',
        'prediction_recovery_opened',
        'prediction_recovery_used',
        'prediction_recovery_revoked',
        'prediction_recovery_expired',
        'league_settings_changed'
      )
    )
);

create index if not exists league_admin_events_league_created_idx
  on public.league_admin_events(league_id, created_at desc);

create index if not exists league_admin_events_target_member_idx
  on public.league_admin_events(target_member_id);

create index if not exists league_admin_events_round_idx
  on public.league_admin_events(league_round_id);

-- ------------------------------------------------------------
-- 6. RLS
-- ------------------------------------------------------------

alter table public.league_rounds enable row level security;
alter table public.prediction_recovery_authorizations enable row level security;
alter table public.league_admin_events enable row level security;

drop policy if exists league_rounds_select_members
  on public.league_rounds;

create policy league_rounds_select_members
on public.league_rounds
for select
to authenticated
using (
  exists (
    select 1
    from public.league_members lm
    where lm.league_id = league_rounds.league_id
      and lm.user_id = auth.uid()
      and lm.status = 'active'
  )
);

drop policy if exists prediction_recovery_select_target_or_admin
  on public.prediction_recovery_authorizations;

create policy prediction_recovery_select_target_or_admin
on public.prediction_recovery_authorizations
for select
to authenticated
using (
  exists (
    select 1
    from public.league_members lm
    where lm.league_id = prediction_recovery_authorizations.league_id
      and lm.user_id = auth.uid()
      and lm.status = 'active'
      and (
        lm.id = prediction_recovery_authorizations.target_member_id
        or lm.role = 'admin'
      )
  )
);

drop policy if exists league_admin_events_select_members
  on public.league_admin_events;

create policy league_admin_events_select_members
on public.league_admin_events
for select
to authenticated
using (
  exists (
    select 1
    from public.league_members lm
    where lm.league_id = league_admin_events.league_id
      and lm.user_id = auth.uid()
      and lm.status = 'active'
  )
);

-- No direct client INSERT/UPDATE/DELETE policies are created.
-- All mutations will be performed by controlled SECURITY DEFINER RPCs.

-- ------------------------------------------------------------
-- 7. TECHNICAL AUDIT
-- ------------------------------------------------------------

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
  'league_governance_foundation_created',
  'system',
  '00000000-0000-4000-8000-000000000011'::uuid,
  null,
  jsonb_build_object(
    'league_lifecycle_added', true,
    'roster_lock_added', true,
    'league_rounds_created', true,
    'admin_vice_governance_added', true,
    'prediction_recovery_added', true,
    'public_admin_log_added', true,
    'late_season_start_supported', true
  ),
  'Created the League Governance, League Round and recovery foundation',
  '00000000-0000-4000-8000-000000000011'::uuid
where not exists (
  select 1
  from public.competition_audit_log cal
  where cal.action = 'league_governance_foundation_created'
);

commit;
