-- ============================================================
-- FANTAGOL MIGRATION 001 — FOUNDATION COMPETITION CORE (RC2)
-- Non-destructive foundation migration for the existing
-- production Supabase schema.
--
-- Scope:
--   - universal competition registry
--   - provider abstraction registry
--   - FantaGol round model
--   - non-destructive extensions to teams and matches
--   - RLS, indexes, triggers, read models and pure helpers
--
-- Important:
--   - preserves seasons, matchdays, predictions and all legacy data
--   - does NOT create Strategy Engine tables
--   - review and run only after production preflight
-- ============================================================

begin;

-- ------------------------------------------------------------
-- PRE-FLIGHT: REQUIRED LEGACY OBJECTS AND DATA INVARIANTS
-- ------------------------------------------------------------

do $$
begin
  if to_regclass('public.teams') is null
     or to_regclass('public.matches') is null
     or to_regclass('public.seasons') is null
     or to_regclass('public.matchdays') is null
     or to_regclass('public.predictions') is null then
    raise exception using
      errcode = 'P0001',
      message = 'FOUNDATION_PREFLIGHT_REQUIRED_LEGACY_TABLE_MISSING';
  end if;

  if exists (
    select 1
    from public.matches
    where home_team_id = away_team_id
  ) then
    raise exception using
      errcode = 'P0001',
      message = 'FOUNDATION_PREFLIGHT_MATCH_WITH_IDENTICAL_TEAMS';
  end if;

  if exists (
    select 1
    from public.matches
    where status in ('finished', 'awarded')
      and (home_score is null or away_score is null)
  ) then
    raise exception using
      errcode = 'P0001',
      message = 'FOUNDATION_PREFLIGHT_FINISHED_MATCH_WITHOUT_SCORE';
  end if;

  if exists (
    select 1
    from public.matches
    where home_score < 0 or away_score < 0
  ) then
    raise exception using
      errcode = 'P0001',
      message = 'FOUNDATION_PREFLIGHT_NEGATIVE_MATCH_SCORE';
  end if;

  if (
    select count(*)
    from information_schema.columns required
    where required.table_schema = 'public'
      and (required.table_name, required.column_name) in (
        ('teams', 'id'),
        ('teams', 'name'),
        ('matches', 'id'),
        ('matches', 'season_id'),
        ('matches', 'matchday_id'),
        ('matches', 'home_team_id'),
        ('matches', 'away_team_id'),
        ('matches', 'kickoff'),
        ('matches', 'status')
      )
  ) <> 9 then
    raise exception using
      errcode = 'P0001',
      message = 'FOUNDATION_PREFLIGHT_LEGACY_COLUMN_MISMATCH';
  end if;
end
$$;

-- ------------------------------------------------------------
-- 0. SHARED FUNCTIONS
-- ------------------------------------------------------------

create or replace function public.set_updated_at()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create or replace function public.increment_row_version()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  new.version = old.version + 1;
  return new;
end;
$$;

-- ------------------------------------------------------------
-- 1. SPORTS
-- ------------------------------------------------------------

create table if not exists public.sports (
  id uuid primary key default gen_random_uuid(),
  code text not null,
  name_key text not null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version integer not null default 1,

  constraint sports_code_unique unique (code),
  constraint sports_code_not_blank_check check (btrim(code) <> ''),
  constraint sports_name_key_not_blank_check check (btrim(name_key) <> ''),
  constraint sports_version_positive_check check (version > 0)
);

create index if not exists sports_active_idx
  on public.sports (active);

-- ------------------------------------------------------------
-- 2. COMPETITIONS
-- ------------------------------------------------------------

create table if not exists public.competitions (
  id uuid primary key default gen_random_uuid(),
  sport_id uuid not null references public.sports(id) on delete restrict,
  code text not null,
  name_key text not null,
  short_name_key text,
  country_code text,
  confederation_code text,
  competition_type text not null,
  scope text not null,
  gender text not null default 'male',
  enabled boolean not null default false,
  public boolean not null default false,
  beta boolean not null default false,
  launch_date date,
  priority integer not null default 100,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version integer not null default 1,

  constraint competitions_code_unique unique (code),
  constraint competitions_code_not_blank_check check (btrim(code) <> ''),
  constraint competitions_name_key_not_blank_check check (btrim(name_key) <> ''),
  constraint competitions_type_check check (
    competition_type in (
      'league',
      'domestic_cup',
      'continental_club',
      'national_team_tournament',
      'qualifier',
      'super_cup',
      'friendly_tournament'
    )
  ),
  constraint competitions_scope_check check (
    scope in ('domestic', 'continental', 'international')
  ),
  constraint competitions_gender_check check (
    gender in ('male', 'female', 'mixed')
  ),
  constraint competitions_priority_nonnegative_check check (priority >= 0),
  constraint competitions_version_positive_check check (version > 0)
);

create index if not exists competitions_sport_idx
  on public.competitions (sport_id);

create index if not exists competitions_enabled_public_idx
  on public.competitions (enabled, public);

create index if not exists competitions_priority_idx
  on public.competitions (priority);

create index if not exists competitions_country_idx
  on public.competitions (country_code);

-- ------------------------------------------------------------
-- 3. COMPETITION EDITIONS
-- ------------------------------------------------------------

create table if not exists public.competition_editions (
  id uuid primary key default gen_random_uuid(),
  competition_id uuid not null references public.competitions(id) on delete restrict,
  label text not null,
  provider_label text,
  year_start integer not null,
  year_end integer,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  status text not null default 'draft',
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version integer not null default 1,

  constraint competition_editions_competition_label_unique
    unique (competition_id, label),
  constraint competition_editions_label_not_blank_check
    check (btrim(label) <> ''),
  constraint competition_editions_year_start_check
    check (year_start between 1900 and 2200),
  constraint competition_editions_year_end_check
    check (
      year_end is null
      or year_end between year_start and year_start + 2
    ),
  constraint competition_editions_dates_check
    check (starts_at < ends_at),
  constraint competition_editions_status_check
    check (
      status in (
        'draft',
        'scheduled',
        'active',
        'completed',
        'archived',
        'cancelled'
      )
    ),
  constraint competition_editions_version_positive_check
    check (version > 0)
);

create index if not exists competition_editions_competition_idx
  on public.competition_editions (competition_id);

create index if not exists competition_editions_status_idx
  on public.competition_editions (status);

create index if not exists competition_editions_active_idx
  on public.competition_editions (active);

create index if not exists competition_editions_dates_idx
  on public.competition_editions (starts_at, ends_at);

-- ------------------------------------------------------------
-- 4. COMPETITION STAGES
-- ------------------------------------------------------------

create table if not exists public.competition_stages (
  id uuid primary key default gen_random_uuid(),
  edition_id uuid not null references public.competition_editions(id) on delete cascade,
  code text not null,
  name_key text not null,
  stage_type text not null,
  sequence integer not null,
  starts_at timestamptz,
  ends_at timestamptz,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version integer not null default 1,

  constraint competition_stages_edition_code_unique
    unique (edition_id, code),
  constraint competition_stages_edition_sequence_unique
    unique (edition_id, sequence),
  constraint competition_stages_code_not_blank_check
    check (btrim(code) <> ''),
  constraint competition_stages_name_key_not_blank_check
    check (btrim(name_key) <> ''),
  constraint competition_stages_type_check
    check (
      stage_type in (
        'regular_season',
        'league_phase',
        'group_stage',
        'playoff',
        'knockout_round',
        'round_of_64',
        'round_of_32',
        'round_of_16',
        'quarter_final',
        'semi_final',
        'third_place',
        'final',
        'qualifier'
      )
    ),
  constraint competition_stages_sequence_positive_check
    check (sequence > 0),
  constraint competition_stages_dates_check
    check (
      starts_at is null
      or ends_at is null
      or starts_at < ends_at
    ),
  constraint competition_stages_version_positive_check
    check (version > 0)
);

create index if not exists competition_stages_edition_idx
  on public.competition_stages (edition_id);

create index if not exists competition_stages_type_idx
  on public.competition_stages (stage_type);

create index if not exists competition_stages_active_idx
  on public.competition_stages (active);

-- ------------------------------------------------------------
-- 5. LEGACY TEAM EXTENSION
-- ------------------------------------------------------------

alter table public.teams
  add column if not exists sport_id uuid,
  add column if not exists team_type text not null default 'club',
  add column if not exists code text,
  add column if not exists country_code text,
  add column if not exists federation_code text,
  add column if not exists crest_reference text,
  add column if not exists active boolean not null default true,
  add column if not exists updated_at timestamptz not null default now(),
  add column if not exists version integer not null default 1;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'teams_sport_id_fkey'
      and conrelid = 'public.teams'::regclass
  ) then
    alter table public.teams
      add constraint teams_sport_id_fkey
      foreign key (sport_id)
      references public.sports(id)
      on delete restrict;
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conname = 'teams_team_type_check'
      and conrelid = 'public.teams'::regclass
  ) then
    alter table public.teams
      add constraint teams_team_type_check
      check (team_type in ('club', 'national_team'));
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conname = 'teams_version_positive_check'
      and conrelid = 'public.teams'::regclass
  ) then
    alter table public.teams
      add constraint teams_version_positive_check
      check (version > 0);
  end if;
end
$$;

create index if not exists teams_sport_idx
  on public.teams (sport_id);

create index if not exists teams_type_idx
  on public.teams (team_type);

create index if not exists teams_country_idx
  on public.teams (country_code);

create index if not exists teams_active_idx
  on public.teams (active);

-- ------------------------------------------------------------
-- 6. COMPETITION TEAMS
-- ------------------------------------------------------------

create table if not exists public.competition_teams (
  id uuid primary key default gen_random_uuid(),
  edition_id uuid not null references public.competition_editions(id) on delete cascade,
  team_id uuid not null references public.teams(id) on delete restrict,
  group_code text,
  seed integer,
  active boolean not null default true,
  joined_at timestamptz not null default now(),
  left_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint competition_teams_edition_team_unique
    unique (edition_id, team_id),
  constraint competition_teams_seed_positive_check
    check (seed is null or seed > 0),
  constraint competition_teams_dates_check
    check (left_at is null or left_at >= joined_at)
);

create index if not exists competition_teams_edition_idx
  on public.competition_teams (edition_id);

create index if not exists competition_teams_team_idx
  on public.competition_teams (team_id);

create index if not exists competition_teams_group_idx
  on public.competition_teams (edition_id, group_code);

-- ------------------------------------------------------------
-- 7. DATA PROVIDERS
-- ------------------------------------------------------------

create table if not exists public.data_providers (
  id uuid primary key default gen_random_uuid(),
  code text not null,
  name text not null,
  provider_type text not null,
  active boolean not null default true,
  priority integer not null default 100,
  base_url text,
  rate_limit_per_minute integer,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint data_providers_code_unique unique (code),
  constraint data_providers_code_not_blank_check check (btrim(code) <> ''),
  constraint data_providers_name_not_blank_check check (btrim(name) <> ''),
  constraint data_providers_type_check
    check (provider_type in ('calendar', 'live_score', 'odds', 'multi')),
  constraint data_providers_priority_nonnegative_check
    check (priority >= 0),
  constraint data_providers_rate_limit_positive_check
    check (rate_limit_per_minute is null or rate_limit_per_minute > 0)
);

create index if not exists data_providers_active_priority_idx
  on public.data_providers (active, priority);

-- ------------------------------------------------------------
-- 8. PROVIDER ENTITY MAPS
-- ------------------------------------------------------------

create table if not exists public.provider_entity_maps (
  id uuid primary key default gen_random_uuid(),
  provider_id uuid not null references public.data_providers(id) on delete cascade,
  entity_type text not null,
  internal_id uuid not null,
  external_id text not null,
  external_parent_id text,
  metadata jsonb not null default '{}'::jsonb,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint provider_entity_maps_external_unique
    unique (provider_id, entity_type, external_id),
  constraint provider_entity_maps_internal_unique
    unique (provider_id, entity_type, internal_id),
  constraint provider_entity_maps_entity_type_check
    check (
      entity_type in (
        'competition',
        'edition',
        'stage',
        'team',
        'provider_round',
        'match'
      )
    ),
  constraint provider_entity_maps_external_id_not_blank_check
    check (btrim(external_id) <> '')
);

create index if not exists provider_entity_maps_internal_idx
  on public.provider_entity_maps (entity_type, internal_id);

create index if not exists provider_entity_maps_external_idx
  on public.provider_entity_maps (provider_id, entity_type, external_id);

create index if not exists provider_entity_maps_active_idx
  on public.provider_entity_maps (active);

-- ------------------------------------------------------------
-- 9. PROVIDER ROUNDS
-- ------------------------------------------------------------

create table if not exists public.provider_rounds (
  id uuid primary key default gen_random_uuid(),
  provider_id uuid not null references public.data_providers(id) on delete restrict,
  edition_id uuid not null references public.competition_editions(id) on delete cascade,
  stage_id uuid references public.competition_stages(id) on delete set null,
  external_id text not null,
  name text not null,
  number integer,
  starts_at timestamptz,
  ends_at timestamptz,
  source_payload_hash text,
  synced_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version integer not null default 1,

  constraint provider_rounds_provider_edition_external_unique
    unique (provider_id, edition_id, external_id),
  constraint provider_rounds_external_id_not_blank_check
    check (btrim(external_id) <> ''),
  constraint provider_rounds_name_not_blank_check
    check (btrim(name) <> ''),
  constraint provider_rounds_number_positive_check
    check (number is null or number > 0),
  constraint provider_rounds_dates_check
    check (
      starts_at is null
      or ends_at is null
      or starts_at <= ends_at
    ),
  constraint provider_rounds_version_positive_check
    check (version > 0)
);

create index if not exists provider_rounds_edition_idx
  on public.provider_rounds (edition_id);

create index if not exists provider_rounds_stage_idx
  on public.provider_rounds (stage_id);

create index if not exists provider_rounds_number_idx
  on public.provider_rounds (edition_id, number);

create index if not exists provider_rounds_synced_idx
  on public.provider_rounds (synced_at);

-- ------------------------------------------------------------
-- 10. LEGACY MATCH EXTENSION
-- ------------------------------------------------------------

alter table public.matches
  add column if not exists edition_id uuid,
  add column if not exists stage_id uuid,
  add column if not exists provider_round_id uuid,
  add column if not exists venue_name text,
  add column if not exists minute integer,
  add column if not exists period text,
  add column if not exists provider_updated_at timestamptz,
  add column if not exists finalised_at timestamptz,
  add column if not exists active boolean not null default true,
  add column if not exists updated_at timestamptz not null default now(),
  add column if not exists version integer not null default 1;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'matches_edition_id_fkey'
      and conrelid = 'public.matches'::regclass
  ) then
    alter table public.matches
      add constraint matches_edition_id_fkey
      foreign key (edition_id)
      references public.competition_editions(id)
      on delete restrict;
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conname = 'matches_stage_id_fkey'
      and conrelid = 'public.matches'::regclass
  ) then
    alter table public.matches
      add constraint matches_stage_id_fkey
      foreign key (stage_id)
      references public.competition_stages(id)
      on delete set null;
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conname = 'matches_provider_round_id_fkey'
      and conrelid = 'public.matches'::regclass
  ) then
    alter table public.matches
      add constraint matches_provider_round_id_fkey
      foreign key (provider_round_id)
      references public.provider_rounds(id)
      on delete set null;
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conname = 'matches_teams_different_check'
      and conrelid = 'public.matches'::regclass
  ) then
    alter table public.matches
      add constraint matches_teams_different_check
      check (home_team_id <> away_team_id);
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conname = 'matches_minute_range_check'
      and conrelid = 'public.matches'::regclass
  ) then
    alter table public.matches
      add constraint matches_minute_range_check
      check (minute is null or minute between 0 and 200);
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conname = 'matches_home_score_nonnegative_check'
      and conrelid = 'public.matches'::regclass
  ) then
    alter table public.matches
      add constraint matches_home_score_nonnegative_check
      check (home_score is null or home_score >= 0);
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conname = 'matches_away_score_nonnegative_check'
      and conrelid = 'public.matches'::regclass
  ) then
    alter table public.matches
      add constraint matches_away_score_nonnegative_check
      check (away_score is null or away_score >= 0);
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conname = 'matches_version_positive_check'
      and conrelid = 'public.matches'::regclass
  ) then
    alter table public.matches
      add constraint matches_version_positive_check
      check (version > 0);
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conname = 'matches_finished_score_required_check'
      and conrelid = 'public.matches'::regclass
  ) then
    alter table public.matches
      add constraint matches_finished_score_required_check
      check (
        status not in ('finished', 'awarded')
        or (home_score is not null and away_score is not null)
      );
  end if;
end
$$;

create index if not exists matches_edition_idx
  on public.matches (edition_id);

create index if not exists matches_stage_idx
  on public.matches (stage_id);

create index if not exists matches_provider_round_idx
  on public.matches (provider_round_id);

create index if not exists matches_kickoff_idx
  on public.matches (kickoff);

create index if not exists matches_status_idx
  on public.matches (status);

create index if not exists matches_active_idx
  on public.matches (active);

create index if not exists matches_live_idx
  on public.matches (status, kickoff);

-- ------------------------------------------------------------
-- 11. FANTAGOL ROUNDS
-- ------------------------------------------------------------

create table if not exists public.fantagol_rounds (
  id uuid primary key default gen_random_uuid(),
  edition_id uuid not null references public.competition_editions(id) on delete cascade,
  stage_id uuid references public.competition_stages(id) on delete set null,
  name text not null,
  sequence integer not null,
  target_match_count integer not null,
  minimum_match_count integer not null,
  maximum_match_count integer not null,
  selection_policy text not null,
  opens_at timestamptz not null,
  lock_at timestamptz not null,
  starts_at timestamptz not null,
  ends_at timestamptz,
  status text not null default 'draft',
  active boolean not null default true,
  official_match_set_version integer,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version integer not null default 1,

  constraint fantagol_rounds_edition_sequence_unique
    unique (edition_id, sequence),
  constraint fantagol_rounds_name_not_blank_check
    check (btrim(name) <> ''),
  constraint fantagol_rounds_sequence_positive_check
    check (sequence > 0),
  constraint fantagol_rounds_target_count_positive_check
    check (target_match_count > 0),
  constraint fantagol_rounds_minimum_count_positive_check
    check (minimum_match_count > 0),
  constraint fantagol_rounds_counts_check
    check (
      maximum_match_count >= minimum_match_count
      and target_match_count between minimum_match_count and maximum_match_count
    ),
  constraint fantagol_rounds_dates_check
    check (
      opens_at < lock_at
      and lock_at <= starts_at
      and (ends_at is null or ends_at >= starts_at)
    ),
  constraint fantagol_rounds_status_check
    check (
      status in (
        'draft',
        'scheduled',
        'predictions_open',
        'predictions_locked',
        'live',
        'partial_finished',
        'waiting_postponed',
        'final_calculable',
        'final_official',
        'recalculated',
        'cancelled'
      )
    ),
  constraint fantagol_rounds_selection_policy_check
    check (
      selection_policy in (
        'official_matchweek',
        'chronological_first_n',
        'chronological_window',
        'provider_group',
        'manual_admin',
        'balanced_stage',
        'custom_curated'
      )
    ),
  constraint fantagol_rounds_match_set_version_positive_check
    check (official_match_set_version is null or official_match_set_version > 0),
  constraint fantagol_rounds_version_positive_check
    check (version > 0)
);

create index if not exists fantagol_rounds_edition_idx
  on public.fantagol_rounds (edition_id);

create index if not exists fantagol_rounds_stage_idx
  on public.fantagol_rounds (stage_id);

create index if not exists fantagol_rounds_status_idx
  on public.fantagol_rounds (status);

create index if not exists fantagol_rounds_active_idx
  on public.fantagol_rounds (active);

create index if not exists fantagol_rounds_dates_idx
  on public.fantagol_rounds (opens_at, lock_at, starts_at);

create index if not exists fantagol_rounds_current_idx
  on public.fantagol_rounds (edition_id, active, status);

-- ------------------------------------------------------------
-- 12. FANTAGOL ROUND MATCHES
-- ------------------------------------------------------------

create table if not exists public.fantagol_round_matches (
  id uuid primary key default gen_random_uuid(),
  fantagol_round_id uuid not null references public.fantagol_rounds(id) on delete cascade,
  match_id uuid not null references public.matches(id) on delete restrict,
  slot_number integer not null,
  selection_reason text not null,
  source_provider_round_id uuid references public.provider_rounds(id) on delete set null,
  required boolean not null default true,
  included_at timestamptz not null default now(),
  removed_at timestamptz,
  version integer not null default 1,

  constraint fantagol_round_matches_round_match_unique
    unique (fantagol_round_id, match_id),
  constraint fantagol_round_matches_round_slot_unique
    unique (fantagol_round_id, slot_number),
  constraint fantagol_round_matches_slot_positive_check
    check (slot_number > 0),
  constraint fantagol_round_matches_reason_not_blank_check
    check (btrim(selection_reason) <> ''),
  constraint fantagol_round_matches_dates_check
    check (removed_at is null or removed_at >= included_at),
  constraint fantagol_round_matches_version_positive_check
    check (version > 0)
);

create index if not exists fantagol_round_matches_round_idx
  on public.fantagol_round_matches (fantagol_round_id);

create index if not exists fantagol_round_matches_match_idx
  on public.fantagol_round_matches (match_id);

create index if not exists fantagol_round_matches_slot_idx
  on public.fantagol_round_matches (fantagol_round_id, slot_number);

create index if not exists fantagol_round_matches_required_idx
  on public.fantagol_round_matches (fantagol_round_id, required);

-- ------------------------------------------------------------
-- 13. MATCH SET VERSIONS
-- ------------------------------------------------------------

create table if not exists public.match_set_versions (
  id uuid primary key default gen_random_uuid(),
  fantagol_round_id uuid not null references public.fantagol_rounds(id) on delete cascade,
  version integer not null,
  match_ids_ordered uuid[] not null,
  reason text not null,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  official boolean not null default false,

  constraint match_set_versions_round_version_unique
    unique (fantagol_round_id, version),
  constraint match_set_versions_version_positive_check
    check (version > 0),
  constraint match_set_versions_not_empty_check
    check (cardinality(match_ids_ordered) > 0),
  constraint match_set_versions_no_null_match_id_check
    check (array_position(match_ids_ordered, null) is null),
  constraint match_set_versions_reason_not_blank_check
    check (btrim(reason) <> '')
);

create unique index if not exists match_set_versions_one_official_idx
  on public.match_set_versions (fantagol_round_id)
  where official = true;

create index if not exists match_set_versions_round_idx
  on public.match_set_versions (fantagol_round_id);

-- ------------------------------------------------------------
-- 14. TEAM ALIASES
-- ------------------------------------------------------------

create table if not exists public.team_aliases (
  id uuid primary key default gen_random_uuid(),
  team_id uuid not null references public.teams(id) on delete cascade,
  locale text not null,
  alias text not null,
  alias_type text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint team_aliases_identity_unique
    unique (team_id, locale, alias, alias_type),
  constraint team_aliases_locale_not_blank_check
    check (btrim(locale) <> ''),
  constraint team_aliases_alias_not_blank_check
    check (btrim(alias) <> ''),
  constraint team_aliases_type_check
    check (
      alias_type in (
        'official',
        'short',
        'translated',
        'provider',
        'historical'
      )
    )
);

create index if not exists team_aliases_team_idx
  on public.team_aliases (team_id);

create index if not exists team_aliases_locale_idx
  on public.team_aliases (locale);

create index if not exists team_aliases_alias_search_idx
  on public.team_aliases (lower(alias));

-- ------------------------------------------------------------
-- 15. COMPETITION AUDIT LOG
-- ------------------------------------------------------------

create table if not exists public.competition_audit_log (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid references auth.users(id) on delete set null,
  action text not null,
  aggregate_type text not null,
  aggregate_id uuid not null,
  before_json jsonb,
  after_json jsonb,
  reason text,
  correlation_id uuid,
  created_at timestamptz not null default now(),

  constraint competition_audit_log_action_not_blank_check
    check (btrim(action) <> ''),
  constraint competition_audit_log_aggregate_type_not_blank_check
    check (btrim(aggregate_type) <> '')
);

create index if not exists competition_audit_log_aggregate_idx
  on public.competition_audit_log (aggregate_type, aggregate_id);

create index if not exists competition_audit_log_actor_idx
  on public.competition_audit_log (actor_id);

create index if not exists competition_audit_log_created_idx
  on public.competition_audit_log (created_at);

create index if not exists competition_audit_log_correlation_idx
  on public.competition_audit_log (correlation_id);

-- ------------------------------------------------------------
-- 16. MINIMUM IDEMPOTENT SEED
-- ------------------------------------------------------------

insert into public.sports (
  id,
  code,
  name_key,
  active
)
values (
  '00000000-0000-4000-8000-000000000001'::uuid,
  'football',
  'sport.football',
  true
)
on conflict (code) do update
set
  name_key = excluded.name_key,
  active = excluded.active;

insert into public.competitions (
  id,
  sport_id,
  code,
  name_key,
  short_name_key,
  country_code,
  competition_type,
  scope,
  gender,
  enabled,
  public,
  beta,
  priority
)
select
  '00000000-0000-4000-8000-000000000101'::uuid,
  s.id,
  'serie_a',
  'competition.serie_a',
  'competition.serie_a.short',
  'IT',
  'league',
  'domestic',
  'male',
  true,
  true,
  true,
  10
from public.sports s
where s.code = 'football'
on conflict (code) do update
set
  sport_id = excluded.sport_id,
  name_key = excluded.name_key,
  short_name_key = excluded.short_name_key,
  country_code = excluded.country_code,
  competition_type = excluded.competition_type,
  scope = excluded.scope,
  gender = excluded.gender,
  enabled = excluded.enabled,
  public = excluded.public,
  beta = excluded.beta,
  priority = excluded.priority;

-- Provider records are created only after a real provider is selected.

-- Existing legacy teams are football clubs unless later reclassified.
update public.teams
set sport_id = (
  select id
  from public.sports
  where code = 'football'
  limit 1
)
where sport_id is null;

-- ------------------------------------------------------------
-- 17. COMPETITION SCOPE CONSISTENCY
-- ------------------------------------------------------------

create or replace function public.validate_provider_round_scope()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_stage_edition_id uuid;
begin
  if new.stage_id is not null then
    select edition_id
    into v_stage_edition_id
    from public.competition_stages
    where id = new.stage_id;

    if v_stage_edition_id is distinct from new.edition_id then
      raise exception using
        errcode = 'P0001',
        message = 'PROVIDER_ROUND_STAGE_EDITION_MISMATCH';
    end if;
  end if;

  return new;
end;
$$;

create or replace function public.validate_match_competition_scope()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_stage_edition_id uuid;
  v_provider_round_edition_id uuid;
  v_provider_round_stage_id uuid;
begin
  if new.stage_id is not null then
    select edition_id
    into v_stage_edition_id
    from public.competition_stages
    where id = new.stage_id;

    if v_stage_edition_id is distinct from new.edition_id then
      raise exception using
        errcode = 'P0001',
        message = 'MATCH_STAGE_EDITION_MISMATCH';
    end if;
  end if;

  if new.provider_round_id is not null then
    select edition_id, stage_id
    into v_provider_round_edition_id, v_provider_round_stage_id
    from public.provider_rounds
    where id = new.provider_round_id;

    if v_provider_round_edition_id is distinct from new.edition_id then
      raise exception using
        errcode = 'P0001',
        message = 'MATCH_PROVIDER_ROUND_EDITION_MISMATCH';
    end if;

    if new.stage_id is not null
       and v_provider_round_stage_id is not null
       and v_provider_round_stage_id <> new.stage_id then
      raise exception using
        errcode = 'P0001',
        message = 'MATCH_PROVIDER_ROUND_STAGE_MISMATCH';
    end if;
  end if;

  return new;
end;
$$;

create or replace function public.validate_fantagol_round_scope()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_stage_edition_id uuid;
begin
  if new.stage_id is not null then
    select edition_id
    into v_stage_edition_id
    from public.competition_stages
    where id = new.stage_id;

    if v_stage_edition_id is distinct from new.edition_id then
      raise exception using
        errcode = 'P0001',
        message = 'FANTAGOL_ROUND_STAGE_EDITION_MISMATCH';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists validate_provider_round_scope on public.provider_rounds;
create trigger validate_provider_round_scope
before insert or update of edition_id, stage_id on public.provider_rounds
for each row execute function public.validate_provider_round_scope();

drop trigger if exists validate_match_competition_scope on public.matches;
create trigger validate_match_competition_scope
before insert or update of edition_id, stage_id, provider_round_id on public.matches
for each row execute function public.validate_match_competition_scope();

drop trigger if exists validate_fantagol_round_scope on public.fantagol_rounds;
create trigger validate_fantagol_round_scope
before insert or update of edition_id, stage_id on public.fantagol_rounds
for each row execute function public.validate_fantagol_round_scope();

-- ------------------------------------------------------------
-- 18. UPDATED_AT AND VERSION TRIGGERS
-- ------------------------------------------------------------

drop trigger if exists set_sports_updated_at on public.sports;
create trigger set_sports_updated_at
before update on public.sports
for each row execute function public.set_updated_at();

drop trigger if exists increment_sports_version on public.sports;
create trigger increment_sports_version
before update on public.sports
for each row execute function public.increment_row_version();

drop trigger if exists set_competitions_updated_at on public.competitions;
create trigger set_competitions_updated_at
before update on public.competitions
for each row execute function public.set_updated_at();

drop trigger if exists increment_competitions_version on public.competitions;
create trigger increment_competitions_version
before update on public.competitions
for each row execute function public.increment_row_version();

drop trigger if exists set_competition_editions_updated_at on public.competition_editions;
create trigger set_competition_editions_updated_at
before update on public.competition_editions
for each row execute function public.set_updated_at();

drop trigger if exists increment_competition_editions_version on public.competition_editions;
create trigger increment_competition_editions_version
before update on public.competition_editions
for each row execute function public.increment_row_version();

drop trigger if exists set_competition_stages_updated_at on public.competition_stages;
create trigger set_competition_stages_updated_at
before update on public.competition_stages
for each row execute function public.set_updated_at();

drop trigger if exists increment_competition_stages_version on public.competition_stages;
create trigger increment_competition_stages_version
before update on public.competition_stages
for each row execute function public.increment_row_version();

drop trigger if exists set_teams_updated_at on public.teams;
create trigger set_teams_updated_at
before update on public.teams
for each row execute function public.set_updated_at();

drop trigger if exists increment_teams_version on public.teams;
create trigger increment_teams_version
before update on public.teams
for each row execute function public.increment_row_version();

drop trigger if exists set_competition_teams_updated_at on public.competition_teams;
create trigger set_competition_teams_updated_at
before update on public.competition_teams
for each row execute function public.set_updated_at();

drop trigger if exists set_data_providers_updated_at on public.data_providers;
create trigger set_data_providers_updated_at
before update on public.data_providers
for each row execute function public.set_updated_at();

drop trigger if exists set_provider_entity_maps_updated_at on public.provider_entity_maps;
create trigger set_provider_entity_maps_updated_at
before update on public.provider_entity_maps
for each row execute function public.set_updated_at();

drop trigger if exists set_provider_rounds_updated_at on public.provider_rounds;
create trigger set_provider_rounds_updated_at
before update on public.provider_rounds
for each row execute function public.set_updated_at();

drop trigger if exists increment_provider_rounds_version on public.provider_rounds;
create trigger increment_provider_rounds_version
before update on public.provider_rounds
for each row execute function public.increment_row_version();

drop trigger if exists set_matches_updated_at on public.matches;
create trigger set_matches_updated_at
before update on public.matches
for each row execute function public.set_updated_at();

drop trigger if exists increment_matches_version on public.matches;
create trigger increment_matches_version
before update on public.matches
for each row execute function public.increment_row_version();

drop trigger if exists set_fantagol_rounds_updated_at on public.fantagol_rounds;
create trigger set_fantagol_rounds_updated_at
before update on public.fantagol_rounds
for each row execute function public.set_updated_at();

drop trigger if exists increment_fantagol_rounds_version on public.fantagol_rounds;
create trigger increment_fantagol_rounds_version
before update on public.fantagol_rounds
for each row execute function public.increment_row_version();

drop trigger if exists increment_fantagol_round_matches_version on public.fantagol_round_matches;
create trigger increment_fantagol_round_matches_version
before update on public.fantagol_round_matches
for each row execute function public.increment_row_version();

drop trigger if exists set_team_aliases_updated_at on public.team_aliases;
create trigger set_team_aliases_updated_at
before update on public.team_aliases
for each row execute function public.set_updated_at();

-- ------------------------------------------------------------
-- 19. MATCH SET PROTECTION AND VERSION CONSISTENCY
-- ------------------------------------------------------------

create or replace function public.protect_fantagol_round_match_after_lock()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_status text;
  v_round_id uuid;
  v_override_enabled boolean;
begin
  v_round_id := case
    when tg_op = 'DELETE' then old.fantagol_round_id
    else new.fantagol_round_id
  end;

  v_override_enabled :=
    coalesce(current_setting('fantagol.allow_locked_match_set_mutation', true), '') = 'on';

  select status
  into v_status
  from public.fantagol_rounds
  where id = v_round_id;

  if not v_override_enabled
     and v_status in (
       'predictions_locked',
       'live',
       'partial_finished',
       'waiting_postponed',
       'final_calculable',
       'final_official',
       'recalculated'
     ) then
    raise exception using
      errcode = 'P0001',
      message = 'ROUND_MATCH_SET_LOCKED';
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;

  return new;
end;
$$;

drop trigger if exists protect_fantagol_round_match_after_lock
  on public.fantagol_round_matches;

create trigger protect_fantagol_round_match_after_lock
before insert or update or delete on public.fantagol_round_matches
for each row execute function public.protect_fantagol_round_match_after_lock();

create or replace function public.validate_fantagol_round_match_write()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_round_edition_id uuid;
  v_round_maximum_match_count integer;
  v_match_edition_id uuid;
  v_match_status text;
  v_match_kickoff timestamptz;
  v_provider_round_edition_id uuid;
begin
  select edition_id, maximum_match_count
  into v_round_edition_id, v_round_maximum_match_count
  from public.fantagol_rounds
  where id = new.fantagol_round_id;

  select edition_id, status, kickoff
  into v_match_edition_id, v_match_status, v_match_kickoff
  from public.matches
  where id = new.match_id;

  if v_match_edition_id is null
     or v_match_edition_id <> v_round_edition_id then
    raise exception using
      errcode = 'P0001',
      message = 'ROUND_MATCH_EDITION_MISMATCH';
  end if;

  if v_match_status = 'cancelled' then
    raise exception using
      errcode = 'P0001',
      message = 'ROUND_MATCH_CANCELLED';
  end if;

  if v_match_kickoff is null then
    raise exception using
      errcode = 'P0001',
      message = 'ROUND_KICKOFF_MISSING';
  end if;

  if new.slot_number > v_round_maximum_match_count then
    raise exception using
      errcode = 'P0001',
      message = 'ROUND_SLOT_EXCEEDS_MAXIMUM_MATCH_COUNT';
  end if;

  if new.source_provider_round_id is not null then
    select edition_id
    into v_provider_round_edition_id
    from public.provider_rounds
    where id = new.source_provider_round_id;

    if v_provider_round_edition_id is distinct from v_round_edition_id then
      raise exception using
        errcode = 'P0001',
        message = 'ROUND_PROVIDER_ROUND_EDITION_MISMATCH';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists validate_fantagol_round_match_write
  on public.fantagol_round_matches;

create trigger validate_fantagol_round_match_write
before insert or update on public.fantagol_round_matches
for each row execute function public.validate_fantagol_round_match_write();

create or replace function public.validate_match_set_version_write()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_expected_match_ids uuid[];
  v_distinct_count integer;
begin
  select array_agg(frm.match_id order by frm.slot_number)
  into v_expected_match_ids
  from public.fantagol_round_matches frm
  where frm.fantagol_round_id = new.fantagol_round_id
    and frm.removed_at is null;

  select count(distinct match_id)::integer
  into v_distinct_count
  from unnest(new.match_ids_ordered) as match_id;

  if v_expected_match_ids is null
     or new.match_ids_ordered is distinct from v_expected_match_ids then
    raise exception using
      errcode = 'P0001',
      message = 'MATCH_SET_VERSION_DOES_NOT_MATCH_CURRENT_ROUND';
  end if;

  if v_distinct_count <> cardinality(new.match_ids_ordered) then
    raise exception using
      errcode = 'P0001',
      message = 'MATCH_SET_VERSION_DUPLICATE_MATCH';
  end if;

  return new;
end;
$$;

drop trigger if exists validate_match_set_version_write
  on public.match_set_versions;

create trigger validate_match_set_version_write
before insert or update on public.match_set_versions
for each row execute function public.validate_match_set_version_write();

create or replace function public.protect_match_set_version_immutability()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_override_enabled boolean;
begin
  v_override_enabled :=
    coalesce(current_setting('fantagol.allow_match_set_version_mutation', true), '') = 'on';

  if v_override_enabled then
    if tg_op = 'DELETE' then
      return old;
    end if;
    return new;
  end if;

  if tg_op = 'DELETE' then
    raise exception using
      errcode = 'P0001',
      message = 'MATCH_SET_VERSION_IMMUTABLE';
  end if;

  if old.fantagol_round_id is distinct from new.fantagol_round_id
     or old.version is distinct from new.version
     or old.match_ids_ordered is distinct from new.match_ids_ordered
     or old.reason is distinct from new.reason
     or old.created_by is distinct from new.created_by
     or old.created_at is distinct from new.created_at
     or old.official = true
     or new.official = false then
    raise exception using
      errcode = 'P0001',
      message = 'MATCH_SET_VERSION_IMMUTABLE';
  end if;

  return new;
end;
$$;

drop trigger if exists protect_match_set_version_immutability
  on public.match_set_versions;

create trigger protect_match_set_version_immutability
before update or delete on public.match_set_versions
for each row execute function public.protect_match_set_version_immutability();

create or replace function public.sync_official_match_set_version()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  if tg_op = 'DELETE' then
    if old.official then
      update public.fantagol_rounds
      set official_match_set_version = null
      where id = old.fantagol_round_id
        and official_match_set_version = old.version;
    end if;
    return old;
  end if;

  if new.official then
    update public.fantagol_rounds
    set official_match_set_version = new.version
    where id = new.fantagol_round_id;
  elsif tg_op = 'UPDATE' and old.official then
    update public.fantagol_rounds
    set official_match_set_version = null
    where id = old.fantagol_round_id
      and official_match_set_version = old.version;
  end if;

  return new;
end;
$$;

drop trigger if exists sync_official_match_set_version
  on public.match_set_versions;

create trigger sync_official_match_set_version
after insert or update of official or delete on public.match_set_versions
for each row execute function public.sync_official_match_set_version();

-- ------------------------------------------------------------
-- 20. PURE DATABASE HELPERS
-- ------------------------------------------------------------

create or replace function public.get_round_match_count(
  p_fantagol_round_id uuid
)
returns integer
language sql
stable
security invoker
set search_path = public
as $$
  select count(*)::integer
  from public.fantagol_round_matches frm
  where frm.fantagol_round_id = p_fantagol_round_id
    and frm.removed_at is null;
$$;

create or replace function public.compute_round_lock_at(
  p_fantagol_round_id uuid
)
returns timestamptz
language sql
stable
security invoker
set search_path = public
as $$
  select min(m.kickoff)
  from public.fantagol_round_matches frm
  join public.matches m on m.id = frm.match_id
  where frm.fantagol_round_id = p_fantagol_round_id
    and frm.removed_at is null;
$$;

create or replace function public.compute_round_capabilities(
  p_fantagol_round_id uuid
)
returns table (
  supports_points_pure boolean,
  supports_fantacalcio boolean,
  supports_one_to_one boolean
)
language sql
stable
security invoker
set search_path = public
as $$
  with match_count as (
    select public.get_round_match_count(p_fantagol_round_id) as value
  )
  select
    value >= 1,
    value = 10,
    value = 10
  from match_count;
$$;

create or replace function public.validate_fantagol_round_structure(
  p_fantagol_round_id uuid
)
returns table (
  valid boolean,
  error_codes text[],
  match_count integer
)
language plpgsql
stable
security invoker
set search_path = public
as $$
declare
  v_round public.fantagol_rounds%rowtype;
  v_match_count integer;
  v_distinct_match_count integer;
  v_distinct_slot_count integer;
  v_min_slot integer;
  v_max_slot integer;
  v_edition_mismatch_count integer;
  v_cancelled_count integer;
  v_missing_kickoff_count integer;
  v_errors text[] := array[]::text[];
begin
  select *
  into v_round
  from public.fantagol_rounds
  where id = p_fantagol_round_id;

  if not found then
    return query
    select false, array['ROUND_NOT_FOUND']::text[], 0;
    return;
  end if;

  select
    count(*)::integer,
    count(distinct frm.match_id)::integer,
    count(distinct frm.slot_number)::integer,
    min(frm.slot_number),
    max(frm.slot_number),
    count(*) filter (where m.edition_id is distinct from v_round.edition_id)::integer,
    count(*) filter (where m.status = 'cancelled')::integer,
    count(*) filter (where m.kickoff is null)::integer
  into
    v_match_count,
    v_distinct_match_count,
    v_distinct_slot_count,
    v_min_slot,
    v_max_slot,
    v_edition_mismatch_count,
    v_cancelled_count,
    v_missing_kickoff_count
  from public.fantagol_round_matches frm
  join public.matches m on m.id = frm.match_id
  where frm.fantagol_round_id = p_fantagol_round_id
    and frm.removed_at is null;

  if v_match_count < v_round.minimum_match_count
     or v_match_count > v_round.maximum_match_count then
    v_errors := array_append(v_errors, 'ROUND_MATCH_COUNT_INVALID');
  end if;

  if v_distinct_match_count <> v_match_count then
    v_errors := array_append(v_errors, 'ROUND_DUPLICATE_MATCH');
  end if;

  if v_distinct_slot_count <> v_match_count
     or coalesce(v_min_slot, 0) <> 1
     or coalesce(v_max_slot, 0) <> v_match_count then
    v_errors := array_append(v_errors, 'ROUND_SLOT_SEQUENCE_INVALID');
  end if;

  if v_edition_mismatch_count > 0 then
    v_errors := array_append(v_errors, 'ROUND_MATCH_EDITION_MISMATCH');
  end if;

  if v_cancelled_count > 0 then
    v_errors := array_append(v_errors, 'ROUND_MATCH_CANCELLED');
  end if;

  if v_missing_kickoff_count > 0 then
    v_errors := array_append(v_errors, 'ROUND_KICKOFF_MISSING');
  end if;

  if not (v_round.opens_at < v_round.lock_at
          and v_round.lock_at <= v_round.starts_at) then
    v_errors := array_append(v_errors, 'ROUND_DATES_INVALID');
  end if;

  return query
  select cardinality(v_errors) = 0, v_errors, v_match_count;
end;
$$;

-- ------------------------------------------------------------
-- 21. READ MODELS
-- ------------------------------------------------------------

create or replace view public.active_competitions_view
with (security_invoker = true)
as
select
  c.id as competition_id,
  c.code,
  c.name_key,
  c.country_code,
  c.competition_type,
  c.scope,
  c.beta,
  c.launch_date,
  c.priority
from public.competitions c
where c.enabled = true
  and c.public = true;

create or replace view public.competition_edition_overview_view
with (security_invoker = true)
as
select
  ce.id as edition_id,
  ce.competition_id,
  c.code as competition_code,
  ce.label,
  ce.status,
  ce.starts_at,
  ce.ends_at,
  count(distinct cs.id)::integer as stage_count,
  count(distinct ct.team_id)::integer as team_count,
  count(distinct m.id)::integer as match_count
from public.competition_editions ce
join public.competitions c on c.id = ce.competition_id
left join public.competition_stages cs on cs.edition_id = ce.id
left join public.competition_teams ct on ct.edition_id = ce.id
left join public.matches m on m.edition_id = ce.id
group by ce.id, ce.competition_id, c.code, ce.label, ce.status, ce.starts_at, ce.ends_at;

create or replace view public.current_fantagol_round_view
with (security_invoker = true)
as
with ranked_rounds as (
  select
    fr.*,
    row_number() over (
      partition by fr.edition_id
      order by
        case fr.status
          when 'live' then 1
          when 'partial_finished' then 2
          when 'waiting_postponed' then 3
          when 'predictions_locked' then 4
          when 'predictions_open' then 5
          when 'scheduled' then 6
          else 7
        end,
        fr.starts_at asc,
        fr.sequence asc
    ) as current_rank
  from public.fantagol_rounds fr
  where fr.active = true
    and fr.status not in ('draft', 'final_official', 'recalculated', 'cancelled')
)
select
  fr.id as round_id,
  fr.edition_id,
  ce.competition_id,
  fr.name,
  fr.sequence,
  fr.status,
  fr.opens_at,
  fr.lock_at,
  fr.starts_at,
  fr.ends_at,
  public.get_round_match_count(fr.id) as match_count,
  caps.supports_points_pure,
  caps.supports_fantacalcio,
  caps.supports_one_to_one
from ranked_rounds fr
join public.competition_editions ce on ce.id = fr.edition_id
cross join lateral public.compute_round_capabilities(fr.id) caps
where fr.current_rank = 1;

create or replace view public.round_match_set_view
with (security_invoker = true)
as
select
  frm.fantagol_round_id as round_id,
  frm.slot_number,
  m.id as match_id,
  m.kickoff,
  m.home_team_id,
  ht.name as home_team_name,
  m.away_team_id,
  at.name as away_team_name,
  m.status,
  m.home_score,
  m.away_score,
  frm.required
from public.fantagol_round_matches frm
join public.matches m on m.id = frm.match_id
join public.teams ht on ht.id = m.home_team_id
join public.teams at on at.id = m.away_team_id
where frm.removed_at is null;

create or replace view public.upcoming_matches_view
with (security_invoker = true)
as
select
  c.id as competition_id,
  m.edition_id,
  m.stage_id,
  m.id as match_id,
  m.kickoff,
  ht.name as home_team,
  at.name as away_team,
  m.status
from public.matches m
join public.competition_editions ce on ce.id = m.edition_id
join public.competitions c on c.id = ce.competition_id
join public.teams ht on ht.id = m.home_team_id
join public.teams at on at.id = m.away_team_id
where m.active = true
  and m.status in ('scheduled', 'postponed')
  and (m.kickoff is null or m.kickoff >= now());

create or replace view public.competition_calendar_view
with (security_invoker = true)
as
select
  c.id as competition_id,
  m.edition_id,
  m.provider_round_id,
  pr.number as provider_round_number,
  m.id as match_id,
  m.kickoff,
  ht.name as home_team,
  at.name as away_team,
  m.status,
  m.home_score,
  m.away_score
from public.matches m
join public.competition_editions ce on ce.id = m.edition_id
join public.competitions c on c.id = ce.competition_id
left join public.provider_rounds pr on pr.id = m.provider_round_id
join public.teams ht on ht.id = m.home_team_id
join public.teams at on at.id = m.away_team_id
where m.active = true;

-- ------------------------------------------------------------
-- 22. ROW LEVEL SECURITY
-- ------------------------------------------------------------

alter table public.sports enable row level security;
alter table public.competitions enable row level security;
alter table public.competition_editions enable row level security;
alter table public.competition_stages enable row level security;
alter table public.competition_teams enable row level security;
alter table public.data_providers enable row level security;
alter table public.provider_entity_maps enable row level security;
alter table public.provider_rounds enable row level security;
alter table public.fantagol_rounds enable row level security;
alter table public.fantagol_round_matches enable row level security;
alter table public.match_set_versions enable row level security;
alter table public.team_aliases enable row level security;
alter table public.competition_audit_log enable row level security;

drop policy if exists "Public can read active sports" on public.sports;
create policy "Public can read active sports"
on public.sports
for select
to anon, authenticated
using (active = true);

drop policy if exists "Public can read public competitions" on public.competitions;
create policy "Public can read public competitions"
on public.competitions
for select
to anon
using (enabled = true and public = true);

drop policy if exists "Authenticated can read enabled competitions" on public.competitions;
create policy "Authenticated can read enabled competitions"
on public.competitions
for select
to authenticated
using (enabled = true);

drop policy if exists "Public can read public competition editions" on public.competition_editions;
create policy "Public can read public competition editions"
on public.competition_editions
for select
to anon
using (
  exists (
    select 1
    from public.competitions c
    where c.id = competition_id
      and c.enabled = true
      and c.public = true
  )
);

drop policy if exists "Authenticated can read enabled competition editions" on public.competition_editions;
create policy "Authenticated can read enabled competition editions"
on public.competition_editions
for select
to authenticated
using (
  exists (
    select 1
    from public.competitions c
    where c.id = competition_id
      and c.enabled = true
  )
);

drop policy if exists "Public can read public competition stages" on public.competition_stages;
create policy "Public can read public competition stages"
on public.competition_stages
for select
to anon
using (
  exists (
    select 1
    from public.competition_editions ce
    join public.competitions c on c.id = ce.competition_id
    where ce.id = edition_id
      and c.enabled = true
      and c.public = true
  )
);

drop policy if exists "Authenticated can read enabled competition stages" on public.competition_stages;
create policy "Authenticated can read enabled competition stages"
on public.competition_stages
for select
to authenticated
using (
  exists (
    select 1
    from public.competition_editions ce
    join public.competitions c on c.id = ce.competition_id
    where ce.id = edition_id
      and c.enabled = true
  )
);

drop policy if exists "Public can read public competition teams" on public.competition_teams;
create policy "Public can read public competition teams"
on public.competition_teams
for select
to anon
using (
  exists (
    select 1
    from public.competition_editions ce
    join public.competitions c on c.id = ce.competition_id
    where ce.id = edition_id
      and c.enabled = true
      and c.public = true
  )
);

drop policy if exists "Authenticated can read enabled competition teams" on public.competition_teams;
create policy "Authenticated can read enabled competition teams"
on public.competition_teams
for select
to authenticated
using (
  exists (
    select 1
    from public.competition_editions ce
    join public.competitions c on c.id = ce.competition_id
    where ce.id = edition_id
      and c.enabled = true
  )
);

drop policy if exists "Public can read public provider rounds" on public.provider_rounds;
create policy "Public can read public provider rounds"
on public.provider_rounds
for select
to anon
using (
  exists (
    select 1
    from public.competition_editions ce
    join public.competitions c on c.id = ce.competition_id
    where ce.id = edition_id
      and c.enabled = true
      and c.public = true
  )
);

drop policy if exists "Authenticated can read enabled provider rounds" on public.provider_rounds;
create policy "Authenticated can read enabled provider rounds"
on public.provider_rounds
for select
to authenticated
using (
  exists (
    select 1
    from public.competition_editions ce
    join public.competitions c on c.id = ce.competition_id
    where ce.id = edition_id
      and c.enabled = true
  )
);

drop policy if exists "Public can read public FantaGol rounds" on public.fantagol_rounds;
create policy "Public can read public FantaGol rounds"
on public.fantagol_rounds
for select
to anon
using (
  exists (
    select 1
    from public.competition_editions ce
    join public.competitions c on c.id = ce.competition_id
    where ce.id = edition_id
      and c.enabled = true
      and c.public = true
      and fantagol_rounds.active = true
      and fantagol_rounds.status <> 'draft'
  )
);

drop policy if exists "Authenticated can read enabled FantaGol rounds" on public.fantagol_rounds;
create policy "Authenticated can read enabled FantaGol rounds"
on public.fantagol_rounds
for select
to authenticated
using (
  exists (
    select 1
    from public.competition_editions ce
    join public.competitions c on c.id = ce.competition_id
    where ce.id = edition_id
      and c.enabled = true
      and fantagol_rounds.active = true
      and fantagol_rounds.status <> 'draft'
  )
);

drop policy if exists "Public can read visible FantaGol round matches" on public.fantagol_round_matches;
create policy "Public can read visible FantaGol round matches"
on public.fantagol_round_matches
for select
to anon
using (
  exists (
    select 1
    from public.fantagol_rounds fr
    join public.competition_editions ce on ce.id = fr.edition_id
    join public.competitions c on c.id = ce.competition_id
    where fr.id = fantagol_round_id
      and c.enabled = true
      and c.public = true
      and fr.active = true
      and fr.status <> 'draft'
  )
);

drop policy if exists "Authenticated can read enabled FantaGol round matches" on public.fantagol_round_matches;
create policy "Authenticated can read enabled FantaGol round matches"
on public.fantagol_round_matches
for select
to authenticated
using (
  exists (
    select 1
    from public.fantagol_rounds fr
    join public.competition_editions ce on ce.id = fr.edition_id
    join public.competitions c on c.id = ce.competition_id
    where fr.id = fantagol_round_id
      and c.enabled = true
      and fr.active = true
      and fr.status <> 'draft'
  )
);

drop policy if exists "Public can read official match set versions" on public.match_set_versions;
create policy "Public can read official match set versions"
on public.match_set_versions
for select
to anon
using (
  official = true
  and exists (
    select 1
    from public.fantagol_rounds fr
    join public.competition_editions ce on ce.id = fr.edition_id
    join public.competitions c on c.id = ce.competition_id
    where fr.id = fantagol_round_id
      and fr.active = true
      and fr.status <> 'draft'
      and c.enabled = true
      and c.public = true
  )
);

drop policy if exists "Authenticated can read official match set versions" on public.match_set_versions;
create policy "Authenticated can read official match set versions"
on public.match_set_versions
for select
to authenticated
using (
  official = true
  and exists (
    select 1
    from public.fantagol_rounds fr
    join public.competition_editions ce on ce.id = fr.edition_id
    join public.competitions c on c.id = ce.competition_id
    where fr.id = fantagol_round_id
      and fr.active = true
      and fr.status <> 'draft'
      and c.enabled = true
  )
);

drop policy if exists "Public can read team aliases" on public.team_aliases;
create policy "Public can read team aliases"
on public.team_aliases
for select
to anon, authenticated
using (true);

-- No direct client policies for:
--   data_providers
--   provider_entity_maps
--   competition_audit_log
-- Writes are restricted to trusted backend/service-role paths.

-- ------------------------------------------------------------
-- 23. TABLE AND VIEW PRIVILEGES
-- ------------------------------------------------------------

revoke all on public.sports from anon, authenticated;
revoke all on public.competitions from anon, authenticated;
revoke all on public.competition_editions from anon, authenticated;
revoke all on public.competition_stages from anon, authenticated;
revoke all on public.competition_teams from anon, authenticated;
revoke all on public.data_providers from anon, authenticated;
revoke all on public.provider_entity_maps from anon, authenticated;
revoke all on public.provider_rounds from anon, authenticated;
revoke all on public.fantagol_rounds from anon, authenticated;
revoke all on public.fantagol_round_matches from anon, authenticated;
revoke all on public.match_set_versions from anon, authenticated;
revoke all on public.team_aliases from anon, authenticated;
revoke all on public.competition_audit_log from anon, authenticated;

grant select on public.sports to anon, authenticated;
grant select on public.competitions to anon, authenticated;
grant select on public.competition_editions to anon, authenticated;
grant select on public.competition_stages to anon, authenticated;
grant select on public.competition_teams to anon, authenticated;
grant select on public.provider_rounds to anon, authenticated;
grant select on public.fantagol_rounds to anon, authenticated;
grant select on public.fantagol_round_matches to anon, authenticated;
grant select on public.match_set_versions to anon, authenticated;
grant select on public.team_aliases to anon, authenticated;

grant select on public.active_competitions_view to anon, authenticated;
grant select on public.competition_edition_overview_view to anon, authenticated;
grant select on public.current_fantagol_round_view to anon, authenticated;
grant select on public.round_match_set_view to anon, authenticated;
grant select on public.upcoming_matches_view to anon, authenticated;
grant select on public.competition_calendar_view to anon, authenticated;

grant all on public.sports to service_role;
grant all on public.competitions to service_role;
grant all on public.competition_editions to service_role;
grant all on public.competition_stages to service_role;
grant all on public.competition_teams to service_role;
grant all on public.data_providers to service_role;
grant all on public.provider_entity_maps to service_role;
grant all on public.provider_rounds to service_role;
grant all on public.fantagol_rounds to service_role;
grant all on public.fantagol_round_matches to service_role;
grant all on public.match_set_versions to service_role;
grant all on public.team_aliases to service_role;
grant all on public.competition_audit_log to service_role;

revoke all on function public.set_updated_at() from public;
revoke all on function public.increment_row_version() from public;
revoke all on function public.validate_provider_round_scope() from public;
revoke all on function public.validate_match_competition_scope() from public;
revoke all on function public.validate_fantagol_round_scope() from public;
revoke all on function public.protect_fantagol_round_match_after_lock() from public;
revoke all on function public.validate_fantagol_round_match_write() from public;
revoke all on function public.validate_match_set_version_write() from public;
revoke all on function public.protect_match_set_version_immutability() from public;
revoke all on function public.sync_official_match_set_version() from public;
revoke all on function public.get_round_match_count(uuid) from public;
revoke all on function public.compute_round_lock_at(uuid) from public;
revoke all on function public.compute_round_capabilities(uuid) from public;
revoke all on function public.validate_fantagol_round_structure(uuid) from public;

-- Helper functions used by public read models.
grant execute on function public.get_round_match_count(uuid) to anon, authenticated, service_role;
grant execute on function public.compute_round_lock_at(uuid) to anon, authenticated, service_role;
grant execute on function public.compute_round_capabilities(uuid) to anon, authenticated, service_role;
grant execute on function public.validate_fantagol_round_structure(uuid) to authenticated, service_role;


commit;

-- ============================================================
-- POST-MIGRATION VERIFICATION (run separately, read-only)
-- ============================================================
--
-- select
--   to_regclass('public.sports') as sports,
--   to_regclass('public.competitions') as competitions,
--   to_regclass('public.competition_editions') as competition_editions,
--   to_regclass('public.competition_stages') as competition_stages,
--   to_regclass('public.competition_teams') as competition_teams,
--   to_regclass('public.data_providers') as data_providers,
--   to_regclass('public.provider_entity_maps') as provider_entity_maps,
--   to_regclass('public.provider_rounds') as provider_rounds,
--   to_regclass('public.fantagol_rounds') as fantagol_rounds,
--   to_regclass('public.fantagol_round_matches') as fantagol_round_matches,
--   to_regclass('public.match_set_versions') as match_set_versions,
--   to_regclass('public.team_aliases') as team_aliases,
--   to_regclass('public.competition_audit_log') as competition_audit_log;
--
-- select code, enabled, public, beta
-- from public.competitions
-- order by priority, code;
--
-- select
--   count(*) filter (where sport_id is null) as teams_without_sport,
--   count(*) as total_teams
-- from public.teams;
