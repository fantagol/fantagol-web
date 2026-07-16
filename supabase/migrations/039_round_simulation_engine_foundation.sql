-- ============================================================================
-- FANTAGOL
-- Migration 039: Round Simulation Engine Foundation
--
-- Scope:
--   - persistent Round Simulation aggregate;
--   - immutable Digital Twin snapshots;
--   - builder execution registry;
--   - append-only simulation event timeline;
--   - publication registry for downstream clients;
--   - read models for latest valid simulation and manifest composition.
--
-- Out of scope:
--   - Points Preview Builder;
--   - Fantacalcio Preview Builder;
--   - One-to-One Preview Builder;
--   - Standings Preview Builder;
--   - UI Snapshot Builder;
--   - Analytics Seed Builder;
--   - Live State Engine orchestration;
--   - certification commit and ledger updates.
--
-- Architectural rule:
--   The Simulation Engine composes existing authoritative artifacts.
--   It never recalculates Prediction Resolution outputs.
-- ============================================================================

begin;

-- ============================================================================
-- 1. ROUND SIMULATIONS
-- ============================================================================

create table if not exists public.round_simulations (
  id uuid primary key default gen_random_uuid(),

  league_round_id uuid not null
    references public.league_rounds(id)
    on delete cascade,

  calculation_run_id uuid not null
    references public.round_calculation_runs(id)
    on delete restrict,

  simulation_version integer not null,
  engine_version text not null,
  snapshot_schema_version integer not null default 1,

  status text not null default 'building',
  preview boolean not null default true,
  publishable boolean not null default false,

  digital_twin jsonb not null default '{}'::jsonb,

  input_hash text,
  output_hash text,
  simulation_hash text,

  correlation_id uuid,
  created_by_member_id uuid
    references public.league_members(id)
    on delete set null,

  certification_id uuid
    references public.round_certifications(id)
    on delete set null,

  ledger_version integer,

  created_at timestamptz not null default now(),
  completed_at timestamptz,
  invalidated_at timestamptz,
  certified_at timestamptz,
  archived_at timestamptz,
  failed_at timestamptz,

  invalidation_reason text,
  failure_details jsonb,

  constraint round_simulations_version_positive_check
    check (simulation_version > 0),

  constraint round_simulations_schema_version_positive_check
    check (snapshot_schema_version > 0),

  constraint round_simulations_engine_not_blank_check
    check (btrim(engine_version) <> ''),

  constraint round_simulations_status_check
    check (
      status in (
        'building',
        'preview_ready',
        'preview_invalidated',
        'awaiting_certification',
        'certified',
        'archived',
        'failed'
      )
    ),

  constraint round_simulations_hashes_check
    check (
      (input_hash is null or input_hash ~ '^[0-9a-f]{64}$')
      and
      (output_hash is null or output_hash ~ '^[0-9a-f]{64}$')
      and
      (simulation_hash is null or simulation_hash ~ '^[0-9a-f]{64}$')
    ),

  constraint round_simulations_dates_check
    check (
      (completed_at is null or completed_at >= created_at)
      and
      (invalidated_at is null or invalidated_at >= created_at)
      and
      (certified_at is null or certified_at >= created_at)
      and
      (archived_at is null or archived_at >= created_at)
      and
      (failed_at is null or failed_at >= created_at)
    ),

  constraint round_simulations_status_payload_check
    check (
      (status = 'building')
      or
      (status = 'failed' and failed_at is not null)
      or
      (
        status in ('preview_ready', 'awaiting_certification', 'certified', 'archived')
        and completed_at is not null
        and input_hash is not null
        and output_hash is not null
        and simulation_hash is not null
      )
      or
      (
        status = 'preview_invalidated'
        and completed_at is not null
        and invalidated_at is not null
        and input_hash is not null
        and output_hash is not null
        and simulation_hash is not null
      )
    ),

  constraint round_simulations_publishable_status_check
    check (
      not publishable
      or status in ('preview_ready', 'awaiting_certification', 'certified')
    ),

  constraint round_simulations_preview_check
    check (
      preview
      or status in ('certified', 'archived')
    ),

  constraint round_simulations_certification_state_check
    check (
      certification_id is null
      or status in ('certified', 'archived')
    ),

  constraint round_simulations_certified_fields_check
    check (
      status <> 'certified'
      or (
        certification_id is not null
        and certified_at is not null
        and preview = false
      )
    ),

  constraint round_simulations_ledger_version_check
    check (ledger_version is null or ledger_version > 0),

  constraint round_simulations_round_version_unique
    unique (league_round_id, simulation_version),

  constraint round_simulations_source_unique
    unique (league_round_id, calculation_run_id, engine_version)
);

create index if not exists round_simulations_round_idx
  on public.round_simulations(league_round_id, simulation_version desc);

create index if not exists round_simulations_calculation_run_idx
  on public.round_simulations(calculation_run_id);

create index if not exists round_simulations_status_idx
  on public.round_simulations(status);

create index if not exists round_simulations_created_idx
  on public.round_simulations(created_at desc);

create index if not exists round_simulations_certification_idx
  on public.round_simulations(certification_id);

create unique index if not exists round_simulations_one_publishable_idx
  on public.round_simulations(league_round_id)
  where publishable = true
    and status in ('preview_ready', 'awaiting_certification', 'certified');

-- ============================================================================
-- 2. BUILDER EXECUTION REGISTRY
-- ============================================================================

create table if not exists public.round_simulation_builder_runs (
  id uuid primary key default gen_random_uuid(),

  simulation_id uuid not null
    references public.round_simulations(id)
    on delete cascade,

  builder_name text not null,
  builder_version text not null,
  builder_order integer not null,
  required boolean not null default true,

  status text not null default 'pending',

  started_at timestamptz,
  completed_at timestamptz,

  input_hash text,
  output_hash text,

  error_code text,
  error_message text,
  metadata jsonb not null default '{}'::jsonb,

  created_at timestamptz not null default now(),

  constraint round_simulation_builder_runs_name_check
    check (
      builder_name in (
        'PointsPreviewBuilder',
        'FantacalcioPreviewBuilder',
        'OneToOnePreviewBuilder',
        'StandingsPreviewBuilder',
        'UISnapshotBuilder',
        'AnalyticsSeedBuilder'
      )
    ),

  constraint round_simulation_builder_runs_version_check
    check (btrim(builder_version) <> ''),

  constraint round_simulation_builder_runs_order_check
    check (builder_order > 0),

  constraint round_simulation_builder_runs_status_check
    check (status in ('pending', 'running', 'completed', 'failed', 'skipped')),

  constraint round_simulation_builder_runs_dates_check
    check (
      (started_at is null or started_at >= created_at)
      and
      (completed_at is null or started_at is not null)
      and
      (completed_at is null or completed_at >= started_at)
    ),

  constraint round_simulation_builder_runs_hashes_check
    check (
      (input_hash is null or input_hash ~ '^[0-9a-f]{64}$')
      and
      (output_hash is null or output_hash ~ '^[0-9a-f]{64}$')
    ),

  constraint round_simulation_builder_runs_state_check
    check (
      status not in ('completed', 'failed', 'skipped')
      or completed_at is not null
    ),

  constraint round_simulation_builder_runs_error_check
    check (
      status <> 'failed'
      or error_code is not null
      or error_message is not null
    ),

  constraint round_simulation_builder_runs_unique
    unique (simulation_id, builder_name),

  constraint round_simulation_builder_runs_order_unique
    unique (simulation_id, builder_order)
);

create index if not exists round_simulation_builder_runs_simulation_idx
  on public.round_simulation_builder_runs(simulation_id, builder_order);

create index if not exists round_simulation_builder_runs_status_idx
  on public.round_simulation_builder_runs(status);

-- ============================================================================
-- 3. ROUND SIMULATION EVENTS
-- ============================================================================

create table if not exists public.round_simulation_events (
  id uuid primary key default gen_random_uuid(),

  simulation_id uuid not null
    references public.round_simulations(id)
    on delete cascade,

  league_round_id uuid not null
    references public.league_rounds(id)
    on delete cascade,

  calculation_run_id uuid not null
    references public.round_calculation_runs(id)
    on delete restrict,

  event_type text not null,
  event_version integer not null default 1,

  payload jsonb not null default '{}'::jsonb,

  correlation_id uuid,
  causation_id uuid,
  actor_member_id uuid
    references public.league_members(id)
    on delete set null,

  occurred_at timestamptz not null default clock_timestamp(),
  created_at timestamptz not null default now(),

  constraint round_simulation_events_type_check
    check (
      event_type in (
        'RoundSimulationBuilding',
        'RoundSimulationReady',
        'RoundSimulationInvalidated',
        'RoundSimulationAwaitingCertification',
        'RoundSimulationCertified',
        'RoundSimulationArchived',
        'RoundSimulationFailed',
        'SimulationBuilderCompleted',
        'SimulationBuilderFailed',
        'SimulationPublished'
      )
    ),

  constraint round_simulation_events_version_check
    check (event_version > 0),

  constraint round_simulation_events_dates_check
    check (occurred_at <= created_at + interval '5 minutes')
);

create index if not exists round_simulation_events_simulation_idx
  on public.round_simulation_events(simulation_id, occurred_at);

create index if not exists round_simulation_events_round_idx
  on public.round_simulation_events(league_round_id, occurred_at);

create index if not exists round_simulation_events_correlation_idx
  on public.round_simulation_events(correlation_id);

create index if not exists round_simulation_events_type_idx
  on public.round_simulation_events(event_type, occurred_at);

-- ============================================================================
-- 4. ROUND SIMULATION PUBLICATIONS
-- ============================================================================

create table if not exists public.round_simulation_publications (
  id uuid primary key default gen_random_uuid(),

  simulation_id uuid not null
    references public.round_simulations(id)
    on delete cascade,

  league_round_id uuid not null
    references public.league_rounds(id)
    on delete cascade,

  publication_version integer not null,
  channel text not null,
  status text not null default 'published',

  simulation_version integer not null,
  simulation_hash text not null,

  published_at timestamptz not null default clock_timestamp(),
  superseded_at timestamptz,

  metadata jsonb not null default '{}'::jsonb,

  constraint round_simulation_publications_version_check
    check (publication_version > 0),

  constraint round_simulation_publications_simulation_version_check
    check (simulation_version > 0),

  constraint round_simulation_publications_channel_check
    check (channel in ('web', 'android', 'internal', 'realtime')),

  constraint round_simulation_publications_status_check
    check (status in ('published', 'superseded', 'withdrawn')),

  constraint round_simulation_publications_hash_check
    check (simulation_hash ~ '^[0-9a-f]{64}$'),

  constraint round_simulation_publications_dates_check
    check (
      superseded_at is null
      or superseded_at >= published_at
    ),

  constraint round_simulation_publications_state_check
    check (
      status = 'published'
      or superseded_at is not null
    ),

  constraint round_simulation_publications_simulation_channel_unique
    unique (simulation_id, channel),

  constraint round_simulation_publications_round_channel_version_unique
    unique (league_round_id, channel, publication_version)
);

create index if not exists round_simulation_publications_round_idx
  on public.round_simulation_publications(
    league_round_id,
    channel,
    publication_version desc
  );

create index if not exists round_simulation_publications_status_idx
  on public.round_simulation_publications(status);

create unique index if not exists round_simulation_publications_one_current_idx
  on public.round_simulation_publications(league_round_id, channel)
  where status = 'published';

-- ============================================================================
-- 5. TRANSITION VALIDATOR
-- ============================================================================

create or replace function public.validate_round_simulation_transition()
returns trigger
language plpgsql
security invoker
set search_path to public, pg_temp
as $function$
begin
  if new.status = old.status then
    return new;
  end if;

  if not (
    (old.status = 'building' and new.status in ('preview_ready', 'failed'))
    or
    (old.status = 'preview_ready' and new.status in (
      'preview_invalidated',
      'awaiting_certification'
    ))
    or
    (old.status = 'preview_invalidated' and new.status = 'archived')
    or
    (old.status = 'awaiting_certification' and new.status = 'certified')
    or
    (old.status = 'certified' and new.status = 'archived')
  ) then
    raise exception using
      errcode = 'P0001',
      message = 'ROUND_SIMULATION_TRANSITION_INVALID',
      detail = format('%s -> %s', old.status, new.status);
  end if;

  return new;
end;
$function$;

-- ============================================================================
-- 6. SOURCE CONSISTENCY VALIDATOR
-- ============================================================================

create or replace function public.validate_round_simulation_source_consistency()
returns trigger
language plpgsql
security invoker
set search_path to public, pg_temp
as $function$
declare
  v_source_round_id uuid;
  v_cert_round_id uuid;
  v_cert_source_run_id uuid;
begin
  select rcr.league_round_id
  into v_source_round_id
  from public.round_calculation_runs rcr
  where rcr.id = new.calculation_run_id;

  if v_source_round_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'ROUND_SIMULATION_CALCULATION_RUN_NOT_FOUND';
  end if;

  if v_source_round_id <> new.league_round_id then
    raise exception using
      errcode = 'P0001',
      message = 'ROUND_SIMULATION_SOURCE_ROUND_MISMATCH';
  end if;

  if new.certification_id is not null then
    select rc.league_round_id, rc.source_run_id
    into v_cert_round_id, v_cert_source_run_id
    from public.round_certifications rc
    where rc.id = new.certification_id;

    if v_cert_round_id is null then
      raise exception using
        errcode = 'P0001',
        message = 'ROUND_SIMULATION_CERTIFICATION_NOT_FOUND';
    end if;

    if v_cert_round_id <> new.league_round_id then
      raise exception using
        errcode = 'P0001',
        message = 'ROUND_SIMULATION_CERTIFICATION_ROUND_MISMATCH';
    end if;

    if v_cert_source_run_id <> new.calculation_run_id then
      raise exception using
        errcode = 'P0001',
        message = 'ROUND_SIMULATION_CERTIFICATION_RUN_MISMATCH';
    end if;
  end if;

  return new;
end;
$function$;

-- ============================================================================
-- 7. IMMUTABILITY GUARDS
-- ============================================================================

create or replace function public.guard_round_simulation_digital_twin_update()
returns trigger
language plpgsql
security invoker
set search_path to public, pg_temp
as $function$
begin
  if old.status <> 'building'
     and new.digital_twin is distinct from old.digital_twin then
    raise exception using
      errcode = 'P0001',
      message = 'ROUND_SIMULATION_DIGITAL_TWIN_IMMUTABLE';
  end if;

  if old.status <> 'building'
     and (
       new.input_hash is distinct from old.input_hash
       or new.output_hash is distinct from old.output_hash
       or new.simulation_hash is distinct from old.simulation_hash
       or new.engine_version is distinct from old.engine_version
       or new.snapshot_schema_version is distinct from old.snapshot_schema_version
       or new.calculation_run_id is distinct from old.calculation_run_id
       or new.league_round_id is distinct from old.league_round_id
       or new.simulation_version is distinct from old.simulation_version
     ) then
    raise exception using
      errcode = 'P0001',
      message = 'ROUND_SIMULATION_CORE_IMMUTABLE';
  end if;

  return new;
end;
$function$;

create or replace function public.guard_round_simulation_append_only()
returns trigger
language plpgsql
security invoker
set search_path to public, pg_temp
as $function$
begin
  raise exception using
    errcode = 'P0001',
    message = 'ROUND_SIMULATION_ARTIFACT_APPEND_ONLY';
end;
$function$;

-- ============================================================================
-- 8. TRIGGERS
-- ============================================================================

drop trigger if exists round_simulations_transition_guard
  on public.round_simulations;

create trigger round_simulations_transition_guard
before update of status
on public.round_simulations
for each row
execute function public.validate_round_simulation_transition();

drop trigger if exists round_simulations_source_consistency_guard
  on public.round_simulations;

create trigger round_simulations_source_consistency_guard
before insert or update of
  league_round_id,
  calculation_run_id,
  certification_id
on public.round_simulations
for each row
execute function public.validate_round_simulation_source_consistency();

drop trigger if exists round_simulations_immutability_guard
  on public.round_simulations;

create trigger round_simulations_immutability_guard
before update
on public.round_simulations
for each row
execute function public.guard_round_simulation_digital_twin_update();

drop trigger if exists round_simulation_events_append_only_guard
  on public.round_simulation_events;

create trigger round_simulation_events_append_only_guard
before update or delete
on public.round_simulation_events
for each row
execute function public.guard_round_simulation_append_only();

-- ============================================================================
-- 9. READ MODELS
-- ============================================================================

create or replace view public.latest_round_simulation_v
with (security_invoker = true)
as
select distinct on (rs.league_round_id)
  rs.id as simulation_id,
  rs.league_round_id,
  rs.calculation_run_id,
  rs.simulation_version,
  rs.engine_version,
  rs.snapshot_schema_version,
  rs.status,
  rs.preview,
  rs.publishable,
  rs.digital_twin,
  rs.input_hash,
  rs.output_hash,
  rs.simulation_hash,
  rs.certification_id,
  rs.ledger_version,
  rs.created_at,
  rs.completed_at,
  rs.certified_at
from public.round_simulations rs
where rs.publishable = true
  and rs.status in ('preview_ready', 'awaiting_certification', 'certified')
order by
  rs.league_round_id,
  rs.simulation_version desc;

create or replace view public.round_simulation_manifest_v
with (security_invoker = true)
as
select
  rs.id as simulation_id,
  rs.league_round_id,
  rs.calculation_run_id,
  rs.simulation_version,
  rs.status as simulation_status,
  rs.preview,
  rs.publishable,
  rs.engine_version as simulation_engine_version,
  rs.snapshot_schema_version as simulation_schema_version,
  rs.input_hash as simulation_input_hash,
  rs.output_hash as simulation_output_hash,
  rs.simulation_hash,
  rs.certification_id,
  rs.ledger_version,
  rs.created_at as simulation_created_at,
  rs.completed_at as simulation_completed_at,

  rcr.run_version as calculation_run_version,
  rcr.status as calculation_status,
  rcr.engine_version as resolution_engine_version,
  rcr.snapshot_schema_version as resolution_schema_version,
  rcr.match_set_version,
  rcr.scoring_profile_id,
  rcr.scoring_profile_version,
  rcr.input_hash as calculation_input_hash,
  rcr.output_hash as calculation_output_hash,
  rcr.preview_hash as calculation_preview_hash,
  rcr.committed_certification_id
from public.round_simulations rs
join public.round_calculation_runs rcr
  on rcr.id = rs.calculation_run_id;

-- ============================================================================
-- 10. RLS
-- ============================================================================

alter table public.round_simulations
  enable row level security;

alter table public.round_simulation_builder_runs
  enable row level security;

alter table public.round_simulation_events
  enable row level security;

alter table public.round_simulation_publications
  enable row level security;

-- Round simulations

drop policy if exists round_simulations_select_members
  on public.round_simulations;

create policy round_simulations_select_members
on public.round_simulations
for select
to authenticated
using (
  exists (
    select 1
    from public.league_rounds lr
    join public.league_members lm
      on lm.league_id = lr.league_id
    where lr.id = round_simulations.league_round_id
      and lm.user_id = auth.uid()
      and lm.status = 'active'
  )
);

-- Builder runs

drop policy if exists round_simulation_builder_runs_select_members
  on public.round_simulation_builder_runs;

create policy round_simulation_builder_runs_select_members
on public.round_simulation_builder_runs
for select
to authenticated
using (
  exists (
    select 1
    from public.round_simulations rs
    join public.league_rounds lr
      on lr.id = rs.league_round_id
    join public.league_members lm
      on lm.league_id = lr.league_id
    where rs.id = round_simulation_builder_runs.simulation_id
      and lm.user_id = auth.uid()
      and lm.status = 'active'
  )
);

-- Events

drop policy if exists round_simulation_events_select_members
  on public.round_simulation_events;

create policy round_simulation_events_select_members
on public.round_simulation_events
for select
to authenticated
using (
  exists (
    select 1
    from public.league_rounds lr
    join public.league_members lm
      on lm.league_id = lr.league_id
    where lr.id = round_simulation_events.league_round_id
      and lm.user_id = auth.uid()
      and lm.status = 'active'
  )
);

-- Publications

drop policy if exists round_simulation_publications_select_members
  on public.round_simulation_publications;

create policy round_simulation_publications_select_members
on public.round_simulation_publications
for select
to authenticated
using (
  exists (
    select 1
    from public.league_rounds lr
    join public.league_members lm
      on lm.league_id = lr.league_id
    where lr.id = round_simulation_publications.league_round_id
      and lm.user_id = auth.uid()
      and lm.status = 'active'
  )
);

-- ============================================================================
-- 11. GRANTS
-- ============================================================================

revoke all on table public.round_simulations from public;
revoke all on table public.round_simulations from anon;
revoke all on table public.round_simulations from authenticated;

grant select on table public.round_simulations
  to authenticated;

grant select, insert, update, delete
on table public.round_simulations
  to service_role;

revoke all on table public.round_simulation_builder_runs from public;
revoke all on table public.round_simulation_builder_runs from anon;
revoke all on table public.round_simulation_builder_runs from authenticated;

grant select on table public.round_simulation_builder_runs
  to authenticated;

grant select, insert, update, delete
on table public.round_simulation_builder_runs
  to service_role;

revoke all on table public.round_simulation_events from public;
revoke all on table public.round_simulation_events from anon;
revoke all on table public.round_simulation_events from authenticated;

grant select on table public.round_simulation_events
  to authenticated;

grant select, insert
on table public.round_simulation_events
  to service_role;

revoke all on table public.round_simulation_publications from public;
revoke all on table public.round_simulation_publications from anon;
revoke all on table public.round_simulation_publications from authenticated;

grant select on table public.round_simulation_publications
  to authenticated;

grant select, insert, update, delete
on table public.round_simulation_publications
  to service_role;

revoke all on table public.latest_round_simulation_v from public;
revoke all on table public.latest_round_simulation_v from anon;
revoke all on table public.latest_round_simulation_v from authenticated;

grant select on table public.latest_round_simulation_v
  to authenticated, service_role;

revoke all on table public.round_simulation_manifest_v from public;
revoke all on table public.round_simulation_manifest_v from anon;
revoke all on table public.round_simulation_manifest_v from authenticated;

grant select on table public.round_simulation_manifest_v
  to authenticated, service_role;

revoke all on function public.validate_round_simulation_transition()
  from public;
revoke all on function public.validate_round_simulation_source_consistency()
  from public;
revoke all on function public.guard_round_simulation_digital_twin_update()
  from public;
revoke all on function public.guard_round_simulation_append_only()
  from public;

-- Trigger functions are not intended for direct client execution.

-- ============================================================================
-- 12. COMMENTS
-- ============================================================================

comment on table public.round_simulations is
'Versioned Round Simulation aggregate. Each row is an immutable Digital Twin derived from one authoritative Calculation Run. The Simulation Engine composes outputs and never recalculates Prediction Resolution results.';

comment on table public.round_simulation_builder_runs is
'Execution registry for independent Round Simulation builders. Foundation only: builders are implemented in later migrations.';

comment on table public.round_simulation_events is
'Append-only technical and domain timeline for the Round Simulation lifecycle.';

comment on table public.round_simulation_publications is
'Registry of Round Simulation versions exposed to downstream channels such as web, Android, internal services and realtime.';

comment on view public.latest_round_simulation_v is
'Latest valid and publishable Round Simulation for each League Round.';

comment on view public.round_simulation_manifest_v is
'Composed manifest joining Round Simulation identity with the authoritative source Calculation Run, without duplicating Resolution Engine metadata.';

comment on function public.validate_round_simulation_transition() is
'Validates the official Round Simulation state machine.';

comment on function public.validate_round_simulation_source_consistency() is
'Guarantees that League Round, Calculation Run and optional Certification belong to the same aggregate and source chain.';

comment on function public.guard_round_simulation_digital_twin_update() is
'Prevents mutation of Digital Twin and core identity fields after the simulation leaves building state.';

comment on function public.guard_round_simulation_append_only() is
'Generic append-only guard for immutable Round Simulation artifacts.';

commit;
