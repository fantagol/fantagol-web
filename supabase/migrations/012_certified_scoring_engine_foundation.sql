-- ============================================================
-- FANTAGOL
-- MIGRATION 012
-- CERTIFIED SCORING ENGINE FOUNDATION — FINAL
--
-- Architectural layers:
--   1. Prediction Domain
--   2. Versioned League Scoring Rules
--   3. Postponed Match Governance
--   4. Calculation Runtime (mutable previews)
--   5. Certification Archive (immutable official history)
--   6. Certified Inputs / Outputs
--   7. Ranking Ledger
--
-- This migration creates the foundation only.
-- Scoring formulas and controlled SECURITY DEFINER RPCs
-- will be introduced in subsequent migrations.
-- ============================================================

begin;

create extension if not exists pgcrypto;

-- ============================================================
-- 0. ALIGN LEAGUE ROUND LIFECYCLE
-- ============================================================

alter table public.league_rounds
  drop constraint if exists league_rounds_status_check;

alter table public.league_rounds
  add constraint league_rounds_status_check
  check (
    status in (
      'scheduled',
      'predictions_open',
      'predictions_locked',
      'live',
      'waiting_postponed',
      'final_calculable',
      'scoring',
      'official',
      'recalculated',
      'archived',
      'cancelled'
    )
  );

-- ============================================================
-- 1. PREDICTION DOMAIN
-- ============================================================

alter table public.predictions
  add column if not exists league_round_id uuid,
  add column if not exists league_member_id uuid,
  add column if not exists status text not null default 'draft',
  add column if not exists submitted_at timestamptz,
  add column if not exists locked_at timestamptz,
  add column if not exists source text not null default 'standard',
  add column if not exists version integer not null default 1;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'predictions_league_round_id_fkey'
      and conrelid = 'public.predictions'::regclass
  ) then
    alter table public.predictions
      add constraint predictions_league_round_id_fkey
      foreign key (league_round_id)
      references public.league_rounds(id)
      on delete cascade;
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conname = 'predictions_league_member_id_fkey'
      and conrelid = 'public.predictions'::regclass
  ) then
    alter table public.predictions
      add constraint predictions_league_member_id_fkey
      foreign key (league_member_id)
      references public.league_members(id)
      on delete restrict;
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conname = 'predictions_status_check'
      and conrelid = 'public.predictions'::regclass
  ) then
    alter table public.predictions
      add constraint predictions_status_check
      check (status in ('draft', 'submitted', 'locked', 'void'));
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conname = 'predictions_source_check'
      and conrelid = 'public.predictions'::regclass
  ) then
    alter table public.predictions
      add constraint predictions_source_check
      check (
        source in (
          'standard',
          'admin_recovery',
          'postponed_reopen'
        )
      );
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conname = 'predictions_version_positive_check'
      and conrelid = 'public.predictions'::regclass
  ) then
    alter table public.predictions
      add constraint predictions_version_positive_check
      check (version > 0);
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conname = 'predictions_lifecycle_dates_check'
      and conrelid = 'public.predictions'::regclass
  ) then
    alter table public.predictions
      add constraint predictions_lifecycle_dates_check
      check (
        (submitted_at is null or submitted_at >= created_at)
        and
        (
          locked_at is null
          or submitted_at is null
          or locked_at >= submitted_at
        )
      );
  end if;
end;
$$;

create index if not exists predictions_league_round_idx
  on public.predictions(league_round_id);

create index if not exists predictions_league_member_idx
  on public.predictions(league_member_id);

create unique index if not exists predictions_round_member_match_unique
  on public.predictions(league_round_id, league_member_id, match_id)
  where league_round_id is not null
    and league_member_id is not null;

create table if not exists public.prediction_versions (
  id uuid primary key default gen_random_uuid(),
  prediction_id uuid not null
    references public.predictions(id)
    on delete cascade,
  version integer not null,
  home_prediction integer not null,
  away_prediction integer not null,
  status text not null,
  source text not null,
  changed_by_user_id uuid,
  changed_by_member_id uuid
    references public.league_members(id)
    on delete set null,
  changed_at timestamptz not null default now(),
  metadata jsonb not null default '{}'::jsonb,

  constraint prediction_versions_home_check
    check (home_prediction between 0 and 9),

  constraint prediction_versions_away_check
    check (away_prediction between 0 and 9),

  constraint prediction_versions_version_positive_check
    check (version > 0),

  constraint prediction_versions_status_check
    check (status in ('draft', 'submitted', 'locked', 'void')),

  constraint prediction_versions_source_check
    check (
      source in (
        'standard',
        'admin_recovery',
        'postponed_reopen'
      )
    ),

  constraint prediction_versions_prediction_version_unique
    unique (prediction_id, version)
);

create index if not exists prediction_versions_prediction_idx
  on public.prediction_versions(prediction_id, version desc);

-- ============================================================
-- 2. VERSIONED LEAGUE SCORING RULES
-- ============================================================

create table if not exists public.league_scoring_profiles (
  id uuid primary key default gen_random_uuid(),
  league_id uuid not null
    references public.leagues(id)
    on delete cascade,
  version integer not null,
  effective_from_league_round_id uuid
    references public.league_rounds(id)
    on delete restrict,

  -- Core scoring is fixed by the official FantaGol rules.
  exact_points numeric(6,2) not null default 6,
  sign_points numeric(6,2) not null default 3,
  over_under_points numeric(6,2) not null default 1,
  goal_no_goal_points numeric(6,2) not null default 1,

  -- Each league may enable or disable only bonus/malus items.
  surprise_bonus_enabled boolean not null default true,
  goal_show_bonus_enabled boolean not null default true,
  grand_slam_bonus_enabled boolean not null default true,
  cantonata_malus_enabled boolean not null default true,
  opposite_sign_malus_enabled boolean not null default true,

  surprise_bonus_points numeric(6,2) not null default 2,
  goal_show_bonus_points numeric(6,2) not null default 1,
  grand_slam_bonus_points numeric(6,2) not null default 1,
  cantonata_malus_points numeric(6,2) not null default -2,
  opposite_sign_malus_points numeric(6,2) not null default -1,

  -- Mode-specific rules are snapshotted and versioned.
  fantacalcio_rules jsonb not null default jsonb_build_object(
    'attack_exact_multiplier', 2,
    'attack_opposite_sign_multiplier', 2,
    'attack_cantonata_multiplier', 2,
    'attack_surprise_multiplier', 2,
    'defence_malus_divisor', 2
  ),
  one_to_one_rules jsonb not null default jsonb_build_object(
    'match_count', 10,
    'pairing_matrix', '10x10'
  ),

  created_by_member_id uuid
    references public.league_members(id)
    on delete set null,
  created_at timestamptz not null default now(),
  reason text,
  active boolean not null default true,

  constraint league_scoring_profiles_version_positive_check
    check (version > 0),

  constraint league_scoring_profiles_core_points_check
    check (
      exact_points = 6
      and sign_points = 3
      and over_under_points = 1
      and goal_no_goal_points = 1
    ),

  constraint league_scoring_profiles_bonus_values_check
    check (
      surprise_bonus_points >= 0
      and goal_show_bonus_points >= 0
      and grand_slam_bonus_points >= 0
      and cantonata_malus_points <= 0
      and opposite_sign_malus_points <= 0
    ),

  constraint league_scoring_profiles_league_version_unique
    unique (league_id, version)
);

create unique index if not exists league_scoring_profiles_one_active_idx
  on public.league_scoring_profiles(league_id)
  where active = true;

create index if not exists league_scoring_profiles_effective_round_idx
  on public.league_scoring_profiles(effective_from_league_round_id);

-- ============================================================
-- 3. POSTPONED MATCH GOVERNANCE
-- ============================================================

create table if not exists public.league_round_match_decisions (
  id uuid primary key default gen_random_uuid(),
  league_round_id uuid not null
    references public.league_rounds(id)
    on delete cascade,
  match_id uuid not null
    references public.matches(id)
    on delete restrict,
  decision text not null default 'included',
  detected_by text not null default 'provider',
  decided_by_member_id uuid
    references public.league_members(id)
    on delete set null,
  detected_at timestamptz,
  decided_at timestamptz,
  reason text,
  previous_kickoff timestamptz,
  current_kickoff timestamptz,
  prediction_reopened_at timestamptz,
  prediction_relock_at timestamptz,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint league_round_match_decisions_decision_check
    check (
      decision in (
        'included',
        'postponed_waiting',
        'postponed_reopened',
        'excluded'
      )
    ),

  constraint league_round_match_decisions_detected_by_check
    check (detected_by in ('provider', 'admin', 'system')),

  constraint league_round_match_decisions_version_positive_check
    check (version > 0),

  constraint league_round_match_decisions_reopen_dates_check
    check (
      prediction_reopened_at is null
      or prediction_relock_at is null
      or prediction_relock_at > prediction_reopened_at
    ),

  constraint league_round_match_decisions_unique
    unique (league_round_id, match_id)
);

create index if not exists league_round_match_decisions_round_idx
  on public.league_round_match_decisions(league_round_id);

create index if not exists league_round_match_decisions_state_idx
  on public.league_round_match_decisions(decision);

-- ============================================================
-- 4. CALCULATION RUNTIME
-- Mutable previews live here. They are not official history.
-- ============================================================

create table if not exists public.round_calculation_runs (
  id uuid primary key default gen_random_uuid(),
  league_round_id uuid not null
    references public.league_rounds(id)
    on delete cascade,
  run_version integer not null,
  status text not null default 'building',

  match_set_version integer not null,
  scoring_profile_id uuid not null
    references public.league_scoring_profiles(id)
    on delete restrict,
  scoring_profile_version integer not null,
  engine_version text not null,
  snapshot_schema_version integer not null default 1,

  input_snapshot jsonb not null default '{}'::jsonb,
  output_snapshot jsonb not null default '{}'::jsonb,
  standings_snapshot jsonb not null default '{}'::jsonb,

  input_hash text,
  output_hash text,
  preview_hash text,

  created_by_member_id uuid
    references public.league_members(id)
    on delete set null,
  created_at timestamptz not null default now(),
  completed_at timestamptz,
  failed_at timestamptz,
  failure_details jsonb,
  committed_certification_id uuid,

  constraint round_calculation_runs_version_positive_check
    check (run_version > 0),

  constraint round_calculation_runs_match_set_version_positive_check
    check (match_set_version > 0),

  constraint round_calculation_runs_profile_version_positive_check
    check (scoring_profile_version > 0),

  constraint round_calculation_runs_schema_version_positive_check
    check (snapshot_schema_version > 0),

  constraint round_calculation_runs_engine_not_blank_check
    check (btrim(engine_version) <> ''),

  constraint round_calculation_runs_status_check
    check (
      status in (
        'building',
        'preview_ready',
        'committed',
        'failed',
        'discarded'
      )
    ),

  constraint round_calculation_runs_dates_check
    check (
      (completed_at is null or completed_at >= created_at)
      and
      (failed_at is null or failed_at >= created_at)
    ),

  constraint round_calculation_runs_round_version_unique
    unique (league_round_id, run_version)
);

create index if not exists round_calculation_runs_round_idx
  on public.round_calculation_runs(league_round_id, run_version desc);

create index if not exists round_calculation_runs_status_idx
  on public.round_calculation_runs(status);

-- ============================================================
-- 5. IMMUTABLE CERTIFICATION ARCHIVE
-- Only a committed runtime preview may produce a certification.
-- ============================================================

create table if not exists public.round_certifications (
  id uuid primary key default gen_random_uuid(),
  league_round_id uuid not null
    references public.league_rounds(id)
    on delete restrict,
  source_run_id uuid not null
    references public.round_calculation_runs(id)
    on delete restrict,

  certification_version integer not null,
  previous_certification_id uuid
    references public.round_certifications(id)
    on delete restrict,

  status text not null default 'official',
  active boolean not null default true,

  match_set_version integer not null,
  scoring_profile_id uuid not null
    references public.league_scoring_profiles(id)
    on delete restrict,
  scoring_profile_version integer not null,
  engine_version text not null,
  snapshot_schema_version integer not null,

  input_snapshot jsonb not null,
  output_snapshot jsonb not null,
  standings_snapshot jsonb not null,

  input_hash text not null,
  output_hash text not null,
  certification_hash text not null,

  committed_by_member_id uuid
    references public.league_members(id)
    on delete set null,
  reason text,
  committed_at timestamptz not null default now(),
  superseded_at timestamptz,
  created_at timestamptz not null default now(),

  constraint round_certifications_version_positive_check
    check (certification_version > 0),

  constraint round_certifications_match_set_version_positive_check
    check (match_set_version > 0),

  constraint round_certifications_profile_version_positive_check
    check (scoring_profile_version > 0),

  constraint round_certifications_schema_version_positive_check
    check (snapshot_schema_version > 0),

  constraint round_certifications_engine_not_blank_check
    check (btrim(engine_version) <> ''),

  constraint round_certifications_status_check
    check (status in ('official', 'superseded')),

  constraint round_certifications_hashes_check
    check (
      input_hash ~ '^[0-9a-f]{64}$'
      and output_hash ~ '^[0-9a-f]{64}$'
      and certification_hash ~ '^[0-9a-f]{64}$'
    ),

  constraint round_certifications_dates_check
    check (
      superseded_at is null
      or superseded_at >= committed_at
    ),

  constraint round_certifications_source_run_unique
    unique (source_run_id),

  constraint round_certifications_round_version_unique
    unique (league_round_id, certification_version)
);

alter table public.round_calculation_runs
  drop constraint if exists round_calculation_runs_committed_certification_id_fkey;

alter table public.round_calculation_runs
  add constraint round_calculation_runs_committed_certification_id_fkey
  foreign key (committed_certification_id)
  references public.round_certifications(id)
  on delete set null;

create unique index if not exists round_certifications_one_active_idx
  on public.round_certifications(league_round_id)
  where active = true;

create unique index if not exists round_certifications_hash_unique
  on public.round_certifications(certification_hash);

create index if not exists round_certifications_round_idx
  on public.round_certifications(league_round_id, certification_version desc);

-- ============================================================
-- 6. CERTIFIED MATCH INPUTS
-- ============================================================

create table if not exists public.round_certification_matches (
  id uuid primary key default gen_random_uuid(),
  certification_id uuid not null
    references public.round_certifications(id)
    on delete restrict,
  match_id uuid not null
    references public.matches(id)
    on delete restrict,
  slot_number integer not null,
  included boolean not null,
  exclusion_reason text,
  kickoff timestamptz,
  match_status text not null,
  home_score integer,
  away_score integer,
  provider_updated_at timestamptz,
  source_snapshot jsonb not null default '{}'::jsonb,

  constraint round_certification_matches_slot_positive_check
    check (slot_number > 0),

  constraint round_certification_matches_scores_check
    check (
      (home_score is null or home_score >= 0)
      and
      (away_score is null or away_score >= 0)
    ),

  constraint round_certification_matches_exclusion_check
    check (
      included = true
      or nullif(btrim(exclusion_reason), '') is not null
    ),

  constraint round_certification_matches_cert_match_unique
    unique (certification_id, match_id),

  constraint round_certification_matches_cert_slot_unique
    unique (certification_id, slot_number)
);

-- ============================================================
-- 7. CERTIFIED PREDICTION INPUTS
-- Missing predictions are represented with NULL scores.
-- ============================================================

create table if not exists public.round_certification_predictions (
  id uuid primary key default gen_random_uuid(),
  certification_id uuid not null
    references public.round_certifications(id)
    on delete restrict,
  prediction_id uuid
    references public.predictions(id)
    on delete set null,
  prediction_version integer,
  league_member_id uuid not null
    references public.league_members(id)
    on delete restrict,
  match_id uuid not null
    references public.matches(id)
    on delete restrict,
  home_prediction integer,
  away_prediction integer,
  prediction_status text,
  source text,
  snapshot jsonb not null default '{}'::jsonb,

  constraint round_certification_predictions_scores_check
    check (
      (home_prediction is null or home_prediction between 0 and 9)
      and
      (away_prediction is null or away_prediction between 0 and 9)
      and
      (
        (home_prediction is null and away_prediction is null)
        or
        (home_prediction is not null and away_prediction is not null)
      )
    ),

  constraint round_certification_predictions_version_check
    check (prediction_version is null or prediction_version > 0),

  constraint round_certification_predictions_unique
    unique (certification_id, league_member_id, match_id)
);

-- ============================================================
-- 8. CERTIFIED MEMBER RESULTS
-- ============================================================

create table if not exists public.round_certification_results (
  id uuid primary key default gen_random_uuid(),
  certification_id uuid not null
    references public.round_certifications(id)
    on delete restrict,
  league_member_id uuid not null
    references public.league_members(id)
    on delete restrict,

  pure_points numeric(10,2) not null default 0,
  exact_count integer not null default 0,
  sign_count integer not null default 0,
  over_under_count integer not null default 0,
  goal_no_goal_count integer not null default 0,
  surprise_count integer not null default 0,
  goal_show_count integer not null default 0,
  grand_slam_count integer not null default 0,
  cantonata_count integer not null default 0,
  opposite_sign_count integer not null default 0,

  details jsonb not null default '{}'::jsonb,
  result_hash text not null,
  created_at timestamptz not null default now(),

  constraint round_certification_results_counts_nonnegative_check
    check (
      exact_count >= 0
      and sign_count >= 0
      and over_under_count >= 0
      and goal_no_goal_count >= 0
      and surprise_count >= 0
      and goal_show_count >= 0
      and grand_slam_count >= 0
      and cantonata_count >= 0
      and opposite_sign_count >= 0
    ),

  constraint round_certification_results_hash_check
    check (result_hash ~ '^[0-9a-f]{64}$'),

  constraint round_certification_results_member_unique
    unique (certification_id, league_member_id)
);

-- ============================================================
-- 9. RANKING LEDGER
-- Old certification entries become inactive when superseded.
-- ============================================================

create table if not exists public.league_ranking_ledger (
  id uuid primary key default gen_random_uuid(),
  league_id uuid not null
    references public.leagues(id)
    on delete cascade,
  league_round_id uuid not null
    references public.league_rounds(id)
    on delete cascade,
  league_member_id uuid not null
    references public.league_members(id)
    on delete restrict,
  certification_id uuid not null
    references public.round_certifications(id)
    on delete restrict,
  mode text not null,
  points_delta numeric(10,2) not null default 0,
  standings_delta jsonb not null default '{}'::jsonb,
  active boolean not null default true,
  created_at timestamptz not null default now(),

  constraint league_ranking_ledger_mode_check
    check (mode in ('pure_points', 'fantacalcio', 'one_to_one')),

  constraint league_ranking_ledger_unique
    unique (certification_id, league_member_id, mode)
);

create unique index if not exists league_ranking_ledger_one_active_round_entry
  on public.league_ranking_ledger(
    league_round_id,
    league_member_id,
    mode
  )
  where active = true;

create index if not exists league_ranking_ledger_league_mode_idx
  on public.league_ranking_ledger(league_id, mode);

create index if not exists league_ranking_ledger_member_idx
  on public.league_ranking_ledger(league_member_id);

-- ============================================================
-- 10. CANONICAL HASH HELPERS
-- ============================================================

create or replace function public.compute_jsonb_sha256(
  p_payload jsonb
)
returns text
language sql
immutable
strict
set search_path = public, extensions
as $function$
  select encode(
    extensions.digest(
      convert_to(p_payload::text, 'UTF8'),
      'sha256'::text
    ),
    'hex'
  );
$function$;

create or replace function public.compute_certification_hash(
  p_league_round_id uuid,
  p_certification_version integer,
  p_snapshot_schema_version integer,
  p_input_snapshot jsonb,
  p_output_snapshot jsonb,
  p_standings_snapshot jsonb,
  p_engine_version text,
  p_match_set_version integer,
  p_scoring_profile_version integer
)
returns text
language sql
immutable
strict
set search_path = public
as $function$
  select public.compute_jsonb_sha256(
    jsonb_build_object(
      'league_round_id', p_league_round_id,
      'certification_version', p_certification_version,
      'snapshot_schema_version', p_snapshot_schema_version,
      'input', p_input_snapshot,
      'output', p_output_snapshot,
      'standings', p_standings_snapshot,
      'engine_version', p_engine_version,
      'match_set_version', p_match_set_version,
      'scoring_profile_version', p_scoring_profile_version
    )
  );
$function$;

-- ============================================================
-- 11. IMMUTABILITY GUARDS
-- ============================================================

create or replace function public.prevent_certified_row_mutation()
returns trigger
language plpgsql
set search_path = public
as $function$
begin
  raise exception
    'CERTIFIED_SCORING_ROW_IMMUTABLE table=% operation=%',
    tg_table_name,
    tg_op;
end;
$function$;

drop trigger if exists round_certification_matches_immutable
  on public.round_certification_matches;
create trigger round_certification_matches_immutable
before update or delete on public.round_certification_matches
for each row execute function public.prevent_certified_row_mutation();

drop trigger if exists round_certification_predictions_immutable
  on public.round_certification_predictions;
create trigger round_certification_predictions_immutable
before update or delete on public.round_certification_predictions
for each row execute function public.prevent_certified_row_mutation();

drop trigger if exists round_certification_results_immutable
  on public.round_certification_results;
create trigger round_certification_results_immutable
before update or delete on public.round_certification_results
for each row execute function public.prevent_certified_row_mutation();

-- Certification snapshots cannot be edited. Only the lifecycle fields
-- active/status/superseded_at may change when a newer version replaces it.
create or replace function public.guard_round_certification_update()
returns trigger
language plpgsql
set search_path = public
as $function$
begin
  if tg_op = 'DELETE' then
    raise exception 'ROUND_CERTIFICATION_DELETE_FORBIDDEN';
  end if;

  if new.id <> old.id
     or new.league_round_id <> old.league_round_id
     or new.source_run_id <> old.source_run_id
     or new.certification_version <> old.certification_version
     or new.previous_certification_id is distinct from old.previous_certification_id
     or new.match_set_version <> old.match_set_version
     or new.scoring_profile_id <> old.scoring_profile_id
     or new.scoring_profile_version <> old.scoring_profile_version
     or new.engine_version <> old.engine_version
     or new.snapshot_schema_version <> old.snapshot_schema_version
     or new.input_snapshot <> old.input_snapshot
     or new.output_snapshot <> old.output_snapshot
     or new.standings_snapshot <> old.standings_snapshot
     or new.input_hash <> old.input_hash
     or new.output_hash <> old.output_hash
     or new.certification_hash <> old.certification_hash
     or new.committed_by_member_id is distinct from old.committed_by_member_id
     or new.reason is distinct from old.reason
     or new.committed_at <> old.committed_at
     or new.created_at <> old.created_at
  then
    raise exception 'ROUND_CERTIFICATION_CONTENT_IMMUTABLE';
  end if;

  if old.status = 'official'
     and new.status = 'superseded'
     and old.active = true
     and new.active = false
     and new.superseded_at is not null
  then
    return new;
  end if;

  if new.status = old.status
     and new.active = old.active
     and new.superseded_at is not distinct from old.superseded_at
  then
    return new;
  end if;

  raise exception 'ROUND_CERTIFICATION_INVALID_LIFECYCLE_TRANSITION';
end;
$function$;

drop trigger if exists round_certifications_guard
  on public.round_certifications;
create trigger round_certifications_guard
before update or delete on public.round_certifications
for each row execute function public.guard_round_certification_update();

-- ============================================================
-- 12. RLS
-- ============================================================

alter table public.prediction_versions enable row level security;
alter table public.league_scoring_profiles enable row level security;
alter table public.league_round_match_decisions enable row level security;
alter table public.round_calculation_runs enable row level security;
alter table public.round_certifications enable row level security;
alter table public.round_certification_matches enable row level security;
alter table public.round_certification_predictions enable row level security;
alter table public.round_certification_results enable row level security;
alter table public.league_ranking_ledger enable row level security;

drop policy if exists "Public read predictions"
  on public.predictions;
drop policy if exists predictions_select_visibility
  on public.predictions;

create policy predictions_select_visibility
on public.predictions
for select
to authenticated
using (
  exists (
    select 1
    from public.league_members owner_member
    where owner_member.id = predictions.league_member_id
      and owner_member.user_id = auth.uid()
      and owner_member.status = 'active'
  )
  or
  exists (
    select 1
    from public.league_rounds lr
    join public.league_members viewer
      on viewer.league_id = lr.league_id
     and viewer.user_id = auth.uid()
     and viewer.status = 'active'
    where lr.id = predictions.league_round_id
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

drop policy if exists prediction_versions_select_visibility
  on public.prediction_versions;
create policy prediction_versions_select_visibility
on public.prediction_versions
for select
to authenticated
using (
  exists (
    select 1
    from public.predictions p
    join public.league_members owner_member
      on owner_member.id = p.league_member_id
    where p.id = prediction_versions.prediction_id
      and owner_member.user_id = auth.uid()
      and owner_member.status = 'active'
  )
  or
  exists (
    select 1
    from public.predictions p
    join public.league_rounds lr
      on lr.id = p.league_round_id
    join public.league_members viewer
      on viewer.league_id = lr.league_id
     and viewer.user_id = auth.uid()
     and viewer.status = 'active'
    where p.id = prediction_versions.prediction_id
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

drop policy if exists league_scoring_profiles_select_members
  on public.league_scoring_profiles;
create policy league_scoring_profiles_select_members
on public.league_scoring_profiles
for select
to authenticated
using (
  exists (
    select 1
    from public.league_members lm
    where lm.league_id = league_scoring_profiles.league_id
      and lm.user_id = auth.uid()
      and lm.status = 'active'
  )
);

drop policy if exists league_round_match_decisions_select_members
  on public.league_round_match_decisions;
create policy league_round_match_decisions_select_members
on public.league_round_match_decisions
for select
to authenticated
using (
  exists (
    select 1
    from public.league_rounds lr
    join public.league_members lm
      on lm.league_id = lr.league_id
     and lm.user_id = auth.uid()
     and lm.status = 'active'
    where lr.id = league_round_match_decisions.league_round_id
  )
);

drop policy if exists round_calculation_runs_select_members
  on public.round_calculation_runs;
create policy round_calculation_runs_select_members
on public.round_calculation_runs
for select
to authenticated
using (
  exists (
    select 1
    from public.league_rounds lr
    join public.league_members lm
      on lm.league_id = lr.league_id
     and lm.user_id = auth.uid()
     and lm.status = 'active'
    where lr.id = round_calculation_runs.league_round_id
  )
);

drop policy if exists round_certifications_select_members
  on public.round_certifications;
create policy round_certifications_select_members
on public.round_certifications
for select
to authenticated
using (
  exists (
    select 1
    from public.league_rounds lr
    join public.league_members lm
      on lm.league_id = lr.league_id
     and lm.user_id = auth.uid()
     and lm.status = 'active'
    where lr.id = round_certifications.league_round_id
  )
);

drop policy if exists round_certification_matches_select_members
  on public.round_certification_matches;
create policy round_certification_matches_select_members
on public.round_certification_matches
for select
to authenticated
using (
  exists (
    select 1
    from public.round_certifications rc
    join public.league_rounds lr
      on lr.id = rc.league_round_id
    join public.league_members lm
      on lm.league_id = lr.league_id
     and lm.user_id = auth.uid()
     and lm.status = 'active'
    where rc.id = round_certification_matches.certification_id
  )
);

drop policy if exists round_certification_predictions_select_members
  on public.round_certification_predictions;
create policy round_certification_predictions_select_members
on public.round_certification_predictions
for select
to authenticated
using (
  exists (
    select 1
    from public.round_certifications rc
    join public.league_rounds lr
      on lr.id = rc.league_round_id
    join public.league_members lm
      on lm.league_id = lr.league_id
     and lm.user_id = auth.uid()
     and lm.status = 'active'
    where rc.id = round_certification_predictions.certification_id
  )
);

drop policy if exists round_certification_results_select_members
  on public.round_certification_results;
create policy round_certification_results_select_members
on public.round_certification_results
for select
to authenticated
using (
  exists (
    select 1
    from public.round_certifications rc
    join public.league_rounds lr
      on lr.id = rc.league_round_id
    join public.league_members lm
      on lm.league_id = lr.league_id
     and lm.user_id = auth.uid()
     and lm.status = 'active'
    where rc.id = round_certification_results.certification_id
  )
);

drop policy if exists league_ranking_ledger_select_members
  on public.league_ranking_ledger;
create policy league_ranking_ledger_select_members
on public.league_ranking_ledger
for select
to authenticated
using (
  exists (
    select 1
    from public.league_members lm
    where lm.league_id = league_ranking_ledger.league_id
      and lm.user_id = auth.uid()
      and lm.status = 'active'
  )
);

-- No direct INSERT/UPDATE/DELETE client policies are created.

-- ============================================================
-- 13. PUBLIC ADMIN EVENT TYPES
-- ============================================================

alter table public.league_admin_events
  drop constraint if exists league_admin_events_action_type_check;

alter table public.league_admin_events
  add constraint league_admin_events_action_type_check
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
      'postponed_match_detected',
      'postponed_match_reopened',
      'postponed_match_excluded',
      'calculation_preview_created',
      'calculation_preview_failed',
      'round_certification_committed',
      'round_certification_superseded',
      'scoring_profile_changed',
      'league_settings_changed'
    )
  );

-- ============================================================
-- 14. TECHNICAL AUDIT
-- ============================================================

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
  'certified_scoring_engine_foundation_created',
  'system',
  '00000000-0000-4000-8000-000000000012'::uuid,
  null,
  jsonb_build_object(
    'prediction_history', true,
    'versioned_scoring_profiles', true,
    'postponed_match_governance', true,
    'runtime_preview_layer', true,
    'immutable_certification_archive', true,
    'sha256_hashing', true,
    'certified_inputs_outputs', true,
    'ranking_ledger', true,
    'public_admin_audit', true
  ),
  'Created the final Certified Scoring Engine foundation',
  '00000000-0000-4000-8000-000000000012'::uuid
where not exists (
  select 1
  from public.competition_audit_log
  where action = 'certified_scoring_engine_foundation_created'
);

commit;
