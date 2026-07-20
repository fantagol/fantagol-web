-- ============================================================================
-- FANTAGOL
-- Migration 077: Platform Governance Engine Foundation
-- Phase 8.1
--
-- Purpose
--   Introduce the canonical governance layer for platform identity,
--   installed engines, feature flags, runtime policies and capabilities.
--
-- Compatibility
--   Additive and backward compatible. No existing runtime object is altered.
--
-- Security model
--   - direct table writes: service_role only;
--   - direct table reads: service_role only;
--   - stable read contracts: authenticated and service_role RPCs;
--   - no client-side write RPC is introduced by this migration.
-- ============================================================================

begin;

-- --------------------------------------------------------------------------
-- 1. Shared governance utilities
-- --------------------------------------------------------------------------

create or replace function public.set_platform_governance_updated_at()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $function$
begin
  new.updated_at := clock_timestamp();
  return new;
end;
$function$;

comment on function public.set_platform_governance_updated_at() is
  'Maintains updated_at for mutable Platform Governance Engine aggregates.';

-- --------------------------------------------------------------------------
-- 2. Platform configuration
--    Singleton aggregate. The fixed key prevents accidental parallel roots.
-- --------------------------------------------------------------------------

create table if not exists public.platform_configuration (
  configuration_key text primary key default 'primary',
  platform_name text not null default 'FantaGol',
  platform_version text not null,
  schema_version integer not null,
  environment text not null,
  release_channel text not null default 'stable',
  operational_status text not null default 'operational',
  maintenance_mode boolean not null default false,
  default_timezone text not null default 'Europe/Rome',
  governance_engine_version text not null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint platform_configuration_singleton_ck
    check (configuration_key = 'primary'),
  constraint platform_configuration_platform_name_ck
    check (btrim(platform_name) <> ''),
  constraint platform_configuration_platform_version_ck
    check (platform_version ~ '^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$'),
  constraint platform_configuration_schema_version_ck
    check (schema_version > 0),
  constraint platform_configuration_environment_ck
    check (environment in ('development', 'preview', 'staging', 'production', 'test')),
  constraint platform_configuration_release_channel_ck
    check (release_channel in ('development', 'preview', 'beta', 'stable', 'lts')),
  constraint platform_configuration_operational_status_ck
    check (operational_status in ('operational', 'degraded', 'maintenance', 'suspended')),
  constraint platform_configuration_governance_version_ck
    check (governance_engine_version ~ '^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$'),
  constraint platform_configuration_timezone_ck
    check (btrim(default_timezone) <> ''),
  constraint platform_configuration_metadata_object_ck
    check (jsonb_typeof(metadata) = 'object'),
  constraint platform_configuration_maintenance_status_ck
    check (not maintenance_mode or operational_status in ('maintenance', 'degraded'))
);

comment on table public.platform_configuration is
  'Singleton source of truth for FantaGol platform identity and global operating state.';

-- --------------------------------------------------------------------------
-- 3. Engine registry
-- --------------------------------------------------------------------------

create table if not exists public.platform_engine_registry (
  engine_code text primary key,
  engine_name text not null,
  engine_version text not null,
  engine_kind text not null,
  lifecycle_status text not null default 'active',
  runtime_enabled boolean not null default true,
  is_certified boolean not null default false,
  certification_version text,
  certified_at timestamptz,
  owner_scope text not null default 'platform',
  installation_order integer not null,
  dependencies jsonb not null default '[]'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint platform_engine_registry_code_ck
    check (engine_code ~ '^[a-z][a-z0-9_]*$'),
  constraint platform_engine_registry_name_ck
    check (btrim(engine_name) <> ''),
  constraint platform_engine_registry_version_ck
    check (engine_version ~ '^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$'),
  constraint platform_engine_registry_kind_ck
    check (engine_kind in ('foundation', 'domain', 'runtime', 'orchestration', 'governance', 'observability', 'maintenance')),
  constraint platform_engine_registry_lifecycle_ck
    check (lifecycle_status in ('planned', 'installed', 'active', 'degraded', 'disabled', 'deprecated', 'retired')),
  constraint platform_engine_registry_certification_version_ck
    check (certification_version is null or certification_version ~ '^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$'),
  constraint platform_engine_registry_certification_state_ck
    check (
      (is_certified and certified_at is not null and certification_version is not null)
      or
      (not is_certified and certified_at is null and certification_version is null)
    ),
  constraint platform_engine_registry_owner_scope_ck
    check (btrim(owner_scope) <> ''),
  constraint platform_engine_registry_installation_order_ck
    check (installation_order > 0),
  constraint platform_engine_registry_dependencies_array_ck
    check (jsonb_typeof(dependencies) = 'array'),
  constraint platform_engine_registry_metadata_object_ck
    check (jsonb_typeof(metadata) = 'object')
);

create unique index if not exists platform_engine_registry_installation_order_uq
  on public.platform_engine_registry (installation_order);

create index if not exists platform_engine_registry_runtime_idx
  on public.platform_engine_registry (runtime_enabled, lifecycle_status);

comment on table public.platform_engine_registry is
  'Canonical inventory of installed FantaGol engines, versions and certification state.';

-- --------------------------------------------------------------------------
-- 4. Feature flags
-- --------------------------------------------------------------------------

create table if not exists public.platform_feature_flags (
  feature_key text primary key,
  feature_name text not null,
  description text not null,
  enabled boolean not null default false,
  rollout_percentage numeric(5,2) not null default 0,
  audience text not null default 'internal',
  environment_scope text[] not null default array['production']::text[],
  owner_engine_code text,
  effective_from timestamptz,
  effective_until timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint platform_feature_flags_key_ck
    check (feature_key ~ '^[a-z][a-z0-9_.-]*$'),
  constraint platform_feature_flags_name_ck
    check (btrim(feature_name) <> ''),
  constraint platform_feature_flags_description_ck
    check (btrim(description) <> ''),
  constraint platform_feature_flags_rollout_ck
    check (rollout_percentage >= 0 and rollout_percentage <= 100),
  constraint platform_feature_flags_enabled_rollout_ck
    check (enabled or rollout_percentage = 0),
  constraint platform_feature_flags_audience_ck
    check (audience in ('internal', 'authenticated', 'admin', 'service', 'public')),
  constraint platform_feature_flags_environment_scope_ck
    check (
      cardinality(environment_scope) > 0
      and environment_scope <@ array['development', 'preview', 'staging', 'production', 'test']::text[]
    ),
  constraint platform_feature_flags_effective_window_ck
    check (effective_until is null or effective_from is null or effective_until > effective_from),
  constraint platform_feature_flags_metadata_object_ck
    check (jsonb_typeof(metadata) = 'object'),
  constraint platform_feature_flags_owner_fk
    foreign key (owner_engine_code)
    references public.platform_engine_registry(engine_code)
    on update cascade
    on delete restrict
);

create index if not exists platform_feature_flags_enabled_idx
  on public.platform_feature_flags (enabled, feature_key);

comment on table public.platform_feature_flags is
  'Central feature activation registry. Flags are changed only through controlled migrations or service operations.';

-- --------------------------------------------------------------------------
-- 5. Runtime policies
-- --------------------------------------------------------------------------

create table if not exists public.platform_runtime_policies (
  policy_key text primary key,
  policy_name text not null,
  description text not null,
  policy_type text not null,
  policy_value jsonb not null,
  validation_contract jsonb not null default '{}'::jsonb,
  owner_engine_code text,
  enforcement_level text not null default 'required',
  enabled boolean not null default true,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint platform_runtime_policies_key_ck
    check (policy_key ~ '^[a-z][a-z0-9_.-]*$'),
  constraint platform_runtime_policies_name_ck
    check (btrim(policy_name) <> ''),
  constraint platform_runtime_policies_description_ck
    check (btrim(description) <> ''),
  constraint platform_runtime_policies_type_ck
    check (policy_type in ('boolean', 'integer', 'numeric', 'text', 'duration', 'object', 'array')),
  constraint platform_runtime_policies_validation_object_ck
    check (jsonb_typeof(validation_contract) = 'object'),
  constraint platform_runtime_policies_enforcement_ck
    check (enforcement_level in ('advisory', 'required', 'critical')),
  constraint platform_runtime_policies_metadata_object_ck
    check (jsonb_typeof(metadata) = 'object'),
  constraint platform_runtime_policies_value_type_ck
    check (
      (policy_type = 'boolean' and jsonb_typeof(policy_value) = 'boolean')
      or (policy_type = 'integer' and jsonb_typeof(policy_value) = 'number' and (policy_value #>> '{}') ~ '^-?[0-9]+$')
      or (policy_type = 'numeric' and jsonb_typeof(policy_value) = 'number')
      or (policy_type in ('text', 'duration') and jsonb_typeof(policy_value) = 'string')
      or (policy_type = 'object' and jsonb_typeof(policy_value) = 'object')
      or (policy_type = 'array' and jsonb_typeof(policy_value) = 'array')
    ),
  constraint platform_runtime_policies_owner_fk
    foreign key (owner_engine_code)
    references public.platform_engine_registry(engine_code)
    on update cascade
    on delete restrict
);

create index if not exists platform_runtime_policies_owner_idx
  on public.platform_runtime_policies (owner_engine_code, enabled);

comment on table public.platform_runtime_policies is
  'Typed runtime policy registry used as the canonical source for operational limits and behaviour.';

-- --------------------------------------------------------------------------
-- 6. Capability registry
-- --------------------------------------------------------------------------

create table if not exists public.platform_capabilities (
  capability_key text primary key,
  capability_name text not null,
  description text not null,
  provider_engine_code text not null,
  capability_version text not null,
  lifecycle_status text not null default 'active',
  runtime_available boolean not null default true,
  invocation_mode text not null,
  contract jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint platform_capabilities_key_ck
    check (capability_key ~ '^[a-z][a-z0-9_.-]*$'),
  constraint platform_capabilities_name_ck
    check (btrim(capability_name) <> ''),
  constraint platform_capabilities_description_ck
    check (btrim(description) <> ''),
  constraint platform_capabilities_version_ck
    check (capability_version ~ '^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$'),
  constraint platform_capabilities_lifecycle_ck
    check (lifecycle_status in ('planned', 'active', 'degraded', 'disabled', 'deprecated', 'retired')),
  constraint platform_capabilities_invocation_mode_ck
    check (invocation_mode in ('rpc', 'job', 'trigger', 'read_model', 'internal', 'scheduler')),
  constraint platform_capabilities_contract_object_ck
    check (jsonb_typeof(contract) = 'object'),
  constraint platform_capabilities_metadata_object_ck
    check (jsonb_typeof(metadata) = 'object'),
  constraint platform_capabilities_provider_fk
    foreign key (provider_engine_code)
    references public.platform_engine_registry(engine_code)
    on update cascade
    on delete restrict
);

create index if not exists platform_capabilities_provider_idx
  on public.platform_capabilities (provider_engine_code, lifecycle_status, runtime_available);

comment on table public.platform_capabilities is
  'Machine-readable registry of capabilities exposed by installed platform engines.';

-- --------------------------------------------------------------------------
-- 7. updated_at triggers
-- --------------------------------------------------------------------------

drop trigger if exists trg_platform_configuration_updated_at
  on public.platform_configuration;
create trigger trg_platform_configuration_updated_at
before update on public.platform_configuration
for each row execute function public.set_platform_governance_updated_at();

drop trigger if exists trg_platform_engine_registry_updated_at
  on public.platform_engine_registry;
create trigger trg_platform_engine_registry_updated_at
before update on public.platform_engine_registry
for each row execute function public.set_platform_governance_updated_at();

drop trigger if exists trg_platform_feature_flags_updated_at
  on public.platform_feature_flags;
create trigger trg_platform_feature_flags_updated_at
before update on public.platform_feature_flags
for each row execute function public.set_platform_governance_updated_at();

drop trigger if exists trg_platform_runtime_policies_updated_at
  on public.platform_runtime_policies;
create trigger trg_platform_runtime_policies_updated_at
before update on public.platform_runtime_policies
for each row execute function public.set_platform_governance_updated_at();

drop trigger if exists trg_platform_capabilities_updated_at
  on public.platform_capabilities;
create trigger trg_platform_capabilities_updated_at
before update on public.platform_capabilities
for each row execute function public.set_platform_governance_updated_at();

-- --------------------------------------------------------------------------
-- 8. Row Level Security and direct privileges
-- --------------------------------------------------------------------------

alter table public.platform_configuration enable row level security;
alter table public.platform_engine_registry enable row level security;
alter table public.platform_feature_flags enable row level security;
alter table public.platform_runtime_policies enable row level security;
alter table public.platform_capabilities enable row level security;

revoke all on table public.platform_configuration from anon, authenticated;
revoke all on table public.platform_engine_registry from anon, authenticated;
revoke all on table public.platform_feature_flags from anon, authenticated;
revoke all on table public.platform_runtime_policies from anon, authenticated;
revoke all on table public.platform_capabilities from anon, authenticated;

grant select, insert, update, delete on table public.platform_configuration to service_role;
grant select, insert, update, delete on table public.platform_engine_registry to service_role;
grant select, insert, update, delete on table public.platform_feature_flags to service_role;
grant select, insert, update, delete on table public.platform_runtime_policies to service_role;
grant select, insert, update, delete on table public.platform_capabilities to service_role;

-- Explicit service policies document intended access and also support roles
-- that do not rely on the service_role bypassrls attribute.
drop policy if exists platform_configuration_service_all on public.platform_configuration;
create policy platform_configuration_service_all
  on public.platform_configuration
  for all
  to service_role
  using (true)
  with check (true);

drop policy if exists platform_engine_registry_service_all on public.platform_engine_registry;
create policy platform_engine_registry_service_all
  on public.platform_engine_registry
  for all
  to service_role
  using (true)
  with check (true);

drop policy if exists platform_feature_flags_service_all on public.platform_feature_flags;
create policy platform_feature_flags_service_all
  on public.platform_feature_flags
  for all
  to service_role
  using (true)
  with check (true);

drop policy if exists platform_runtime_policies_service_all on public.platform_runtime_policies;
create policy platform_runtime_policies_service_all
  on public.platform_runtime_policies
  for all
  to service_role
  using (true)
  with check (true);

drop policy if exists platform_capabilities_service_all on public.platform_capabilities;
create policy platform_capabilities_service_all
  on public.platform_capabilities
  for all
  to service_role
  using (true)
  with check (true);

-- --------------------------------------------------------------------------
-- 9. Seed: platform identity and certified engine inventory
-- --------------------------------------------------------------------------

insert into public.platform_configuration (
  configuration_key,
  platform_name,
  platform_version,
  schema_version,
  environment,
  release_channel,
  operational_status,
  maintenance_mode,
  default_timezone,
  governance_engine_version,
  metadata
)
values (
  'primary',
  'FantaGol',
  '1.0.0',
  77,
  'production',
  'stable',
  'operational',
  false,
  'Europe/Rome',
  '1.0.0',
  jsonb_build_object(
    'phase', '8.1',
    'foundation_migration', 77,
    'governance_contract', 'platform-governance-v1'
  )
)
on conflict (configuration_key) do update
set
  schema_version = greatest(public.platform_configuration.schema_version, excluded.schema_version),
  governance_engine_version = excluded.governance_engine_version,
  metadata = public.platform_configuration.metadata || excluded.metadata;

insert into public.platform_engine_registry (
  engine_code,
  engine_name,
  engine_version,
  engine_kind,
  lifecycle_status,
  runtime_enabled,
  is_certified,
  certification_version,
  certified_at,
  owner_scope,
  installation_order,
  dependencies,
  metadata
)
values
  ('core_engine', 'Core Engine', '1.0.0', 'foundation', 'active', true, true, '1.0.0', now(), 'platform', 10, '[]'::jsonb, '{"contract":"core-engine-v1"}'::jsonb),
  ('competition_engine', 'Competition Engine', '1.0.0', 'domain', 'active', true, true, '1.0.0', now(), 'platform', 20, '["core_engine"]'::jsonb, '{"contract":"competition-engine-v1"}'::jsonb),
  ('live_state_engine', 'Live State Engine', '1.0.0', 'runtime', 'active', true, true, '1.0.0', now(), 'platform', 30, '["core_engine","competition_engine"]'::jsonb, '{"contract":"live-state-engine-v1"}'::jsonb),
  ('round_simulation_engine', 'Round Simulation Engine', '1.0.0', 'domain', 'active', true, true, '1.0.0', now(), 'platform', 40, '["core_engine","competition_engine"]'::jsonb, '{"contract":"round-simulation-engine-v1"}'::jsonb),
  ('publication_engine', 'Publication Engine', '1.0.0', 'runtime', 'active', true, true, '1.0.0', now(), 'platform', 50, '["core_engine","round_simulation_engine"]'::jsonb, '{"contract":"publication-engine-v1"}'::jsonb),
  ('workflow_engine', 'Workflow Engine', '1.0.0', 'orchestration', 'active', true, true, '1.0.0', now(), 'platform', 60, '["core_engine","publication_engine"]'::jsonb, '{"contract":"workflow-engine-v1"}'::jsonb),
  ('round_certification_engine', 'Round Certification Engine', '1.0.0', 'runtime', 'active', true, true, '1.0.0', now(), 'platform', 70, '["competition_engine","round_simulation_engine","publication_engine","workflow_engine"]'::jsonb, '{"contract":"round-certification-v1"}'::jsonb),
  ('recovery_engine', 'Recovery Engine', '1.0.0', 'orchestration', 'active', true, true, '1.0.0', now(), 'platform', 80, '["workflow_engine"]'::jsonb, '{"contract":"workflow-recovery-v1"}'::jsonb),
  ('maintenance_engine', 'Maintenance Engine', '1.0.0', 'maintenance', 'active', true, true, '1.0.0', now(), 'platform', 90, '["workflow_engine","recovery_engine"]'::jsonb, '{"contract":"maintenance-runtime-v1"}'::jsonb),
  ('platform_governance_engine', 'Platform Governance Engine', '1.0.0', 'governance', 'active', true, false, null, null, 'platform', 100, '["core_engine"]'::jsonb, '{"contract":"platform-governance-v1","phase":"8.1"}'::jsonb)
on conflict (engine_code) do update
set
  engine_name = excluded.engine_name,
  engine_version = excluded.engine_version,
  engine_kind = excluded.engine_kind,
  lifecycle_status = excluded.lifecycle_status,
  runtime_enabled = excluded.runtime_enabled,
  owner_scope = excluded.owner_scope,
  installation_order = excluded.installation_order,
  dependencies = excluded.dependencies,
  metadata = public.platform_engine_registry.metadata || excluded.metadata;

-- Foundation flags are intentionally conservative: registration does not
-- activate behavioural changes in already certified runtimes.
insert into public.platform_feature_flags (
  feature_key,
  feature_name,
  description,
  enabled,
  rollout_percentage,
  audience,
  environment_scope,
  owner_engine_code,
  metadata
)
values
  ('platform.governance.read_model', 'Platform governance read model', 'Expose the consolidated platform governance read contract.', true, 100, 'authenticated', array['development','preview','staging','production','test'], 'platform_governance_engine', '{"contract":"platform-governance-v1"}'::jsonb),
  ('platform.maintenance_mode', 'Platform maintenance mode', 'Global feature switch reflecting controlled maintenance-mode activation.', false, 0, 'service', array['development','preview','staging','production','test'], 'maintenance_engine', '{"mirrors_configuration":true}'::jsonb),
  ('runtime.capability_enforcement', 'Runtime capability enforcement', 'Require runtime jobs to validate declared capabilities before execution.', false, 0, 'service', array['development','preview','staging','production','test'], 'platform_governance_engine', '{"planned_phase":"8.3"}'::jsonb),
  ('runtime.dependency_enforcement', 'Runtime dependency enforcement', 'Require engine dependency validation before runtime activation.', false, 0, 'service', array['development','preview','staging','production','test'], 'platform_governance_engine', '{"planned_phase":"8.2"}'::jsonb)
on conflict (feature_key) do update
set
  feature_name = excluded.feature_name,
  description = excluded.description,
  owner_engine_code = excluded.owner_engine_code,
  metadata = public.platform_feature_flags.metadata || excluded.metadata;

insert into public.platform_runtime_policies (
  policy_key,
  policy_name,
  description,
  policy_type,
  policy_value,
  validation_contract,
  owner_engine_code,
  enforcement_level,
  enabled,
  metadata
)
values
  ('runtime.retry.max_attempts', 'Maximum runtime retry attempts', 'Upper bound for retryable workflow and runtime jobs.', 'integer', '5'::jsonb, '{"minimum":0,"maximum":20}'::jsonb, 'workflow_engine', 'required', true, '{"unit":"attempts"}'::jsonb),
  ('runtime.job.lease_duration', 'Runtime job lease duration', 'Canonical worker lease duration used to prevent concurrent execution.', 'duration', '"PT5M"'::jsonb, '{"format":"ISO-8601-duration"}'::jsonb, 'workflow_engine', 'critical', true, '{}'::jsonb),
  ('runtime.recovery.enabled', 'Runtime recovery enabled', 'Controls whether failed recoverable workflows may enter automatic recovery.', 'boolean', 'true'::jsonb, '{}'::jsonb, 'recovery_engine', 'critical', true, '{}'::jsonb),
  ('runtime.maintenance.scheduler_enabled', 'Maintenance scheduler enabled', 'Controls execution of scheduled runtime maintenance planning.', 'boolean', 'true'::jsonb, '{}'::jsonb, 'maintenance_engine', 'required', true, '{}'::jsonb),
  ('runtime.publication.timeout', 'Publication timeout', 'Maximum expected duration for one publication execution.', 'duration', '"PT10M"'::jsonb, '{"format":"ISO-8601-duration"}'::jsonb, 'publication_engine', 'required', true, '{}'::jsonb)
on conflict (policy_key) do update
set
  policy_name = excluded.policy_name,
  description = excluded.description,
  policy_type = excluded.policy_type,
  validation_contract = excluded.validation_contract,
  owner_engine_code = excluded.owner_engine_code,
  enforcement_level = excluded.enforcement_level,
  metadata = public.platform_runtime_policies.metadata || excluded.metadata;

insert into public.platform_capabilities (
  capability_key,
  capability_name,
  description,
  provider_engine_code,
  capability_version,
  lifecycle_status,
  runtime_available,
  invocation_mode,
  contract,
  metadata
)
values
  ('competition.lifecycle.manage', 'Competition lifecycle management', 'Manage the canonical lifecycle of leagues, rounds and competition state.', 'competition_engine', '1.0.0', 'active', true, 'rpc', '{"scope":"competition"}'::jsonb, '{}'::jsonb),
  ('live_state.snapshot.build', 'Live-state snapshot building', 'Build canonical live-state snapshots from certified provider input.', 'live_state_engine', '1.0.0', 'active', true, 'job', '{"scope":"live-runtime"}'::jsonb, '{}'::jsonb),
  ('round.simulation.build', 'Round simulation building', 'Build deterministic preview and official round simulations.', 'round_simulation_engine', '1.0.0', 'active', true, 'rpc', '{"scope":"round"}'::jsonb, '{}'::jsonb),
  ('publication.snapshot.publish', 'Snapshot publication', 'Publish certified snapshots through the runtime publication pipeline.', 'publication_engine', '1.0.0', 'active', true, 'job', '{"scope":"publication"}'::jsonb, '{}'::jsonb),
  ('workflow.runtime.orchestrate', 'Workflow runtime orchestration', 'Schedule, lease and execute durable platform workflows.', 'workflow_engine', '1.0.0', 'active', true, 'job', '{"scope":"runtime"}'::jsonb, '{}'::jsonb),
  ('round.certification.certify', 'Round certification', 'Create the immutable official certification of a completed league round.', 'round_certification_engine', '1.0.0', 'active', true, 'job', '{"scope":"round"}'::jsonb, '{}'::jsonb),
  ('workflow.recovery.execute', 'Workflow recovery execution', 'Evaluate and execute deterministic recovery for failed workflows.', 'recovery_engine', '1.0.0', 'active', true, 'job', '{"scope":"runtime"}'::jsonb, '{}'::jsonb),
  ('runtime.maintenance.plan', 'Runtime maintenance planning', 'Plan retention, reconciliation and health maintenance work.', 'maintenance_engine', '1.0.0', 'active', true, 'scheduler', '{"scope":"runtime"}'::jsonb, '{}'::jsonb),
  ('platform.governance.read', 'Platform governance read', 'Read the canonical platform configuration, engines, flags, policies and capabilities.', 'platform_governance_engine', '1.0.0', 'active', true, 'rpc', '{"contract":"platform-governance-v1"}'::jsonb, '{}')
on conflict (capability_key) do update
set
  capability_name = excluded.capability_name,
  description = excluded.description,
  provider_engine_code = excluded.provider_engine_code,
  capability_version = excluded.capability_version,
  lifecycle_status = excluded.lifecycle_status,
  runtime_available = excluded.runtime_available,
  invocation_mode = excluded.invocation_mode,
  contract = excluded.contract,
  metadata = public.platform_capabilities.metadata || excluded.metadata;

-- --------------------------------------------------------------------------
-- 10. Stable read RPCs
-- --------------------------------------------------------------------------

create or replace function public.get_platform_configuration_rpc()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $function$
  select jsonb_build_object(
    'configuration_key', c.configuration_key,
    'platform_name', c.platform_name,
    'platform_version', c.platform_version,
    'schema_version', c.schema_version,
    'environment', c.environment,
    'release_channel', c.release_channel,
    'operational_status', c.operational_status,
    'maintenance_mode', c.maintenance_mode,
    'default_timezone', c.default_timezone,
    'governance_engine_version', c.governance_engine_version,
    'metadata', c.metadata,
    'created_at', c.created_at,
    'updated_at', c.updated_at
  )
  from public.platform_configuration c
  where c.configuration_key = 'primary';
$function$;

create or replace function public.get_platform_engine_registry_rpc(
  p_include_inactive boolean default false
)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $function$
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'engine_code', e.engine_code,
        'engine_name', e.engine_name,
        'engine_version', e.engine_version,
        'engine_kind', e.engine_kind,
        'lifecycle_status', e.lifecycle_status,
        'runtime_enabled', e.runtime_enabled,
        'is_certified', e.is_certified,
        'certification_version', e.certification_version,
        'certified_at', e.certified_at,
        'owner_scope', e.owner_scope,
        'installation_order', e.installation_order,
        'dependencies', e.dependencies,
        'metadata', e.metadata,
        'created_at', e.created_at,
        'updated_at', e.updated_at
      )
      order by e.installation_order, e.engine_code
    ),
    '[]'::jsonb
  )
  from public.platform_engine_registry e
  where p_include_inactive
     or (e.lifecycle_status = 'active' and e.runtime_enabled);
$function$;

create or replace function public.get_platform_feature_flags_rpc(
  p_environment text default null,
  p_include_disabled boolean default false
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $function$
declare
  v_environment text;
  v_result jsonb;
begin
  select coalesce(p_environment, c.environment)
    into v_environment
  from public.platform_configuration c
  where c.configuration_key = 'primary';

  if v_environment is null or v_environment not in ('development', 'preview', 'staging', 'production', 'test') then
    raise exception 'PLATFORM_GOVERNANCE_INVALID_ENVIRONMENT: %', coalesce(v_environment, '<null>')
      using errcode = '22023';
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'feature_key', f.feature_key,
        'feature_name', f.feature_name,
        'description', f.description,
        'enabled', f.enabled,
        'rollout_percentage', f.rollout_percentage,
        'audience', f.audience,
        'environment_scope', f.environment_scope,
        'owner_engine_code', f.owner_engine_code,
        'effective_from', f.effective_from,
        'effective_until', f.effective_until,
        'is_effective', (
          f.enabled
          and v_environment = any(f.environment_scope)
          and (f.effective_from is null or f.effective_from <= now())
          and (f.effective_until is null or f.effective_until > now())
        ),
        'metadata', f.metadata,
        'updated_at', f.updated_at
      )
      order by f.feature_key
    ),
    '[]'::jsonb
  )
  into v_result
  from public.platform_feature_flags f
  where v_environment = any(f.environment_scope)
    and (
      p_include_disabled
      or (
        f.enabled
        and (f.effective_from is null or f.effective_from <= now())
        and (f.effective_until is null or f.effective_until > now())
      )
    );

  return v_result;
end;
$function$;

create or replace function public.get_platform_runtime_policies_rpc(
  p_owner_engine_code text default null,
  p_include_disabled boolean default false
)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $function$
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'policy_key', p.policy_key,
        'policy_name', p.policy_name,
        'description', p.description,
        'policy_type', p.policy_type,
        'policy_value', p.policy_value,
        'validation_contract', p.validation_contract,
        'owner_engine_code', p.owner_engine_code,
        'enforcement_level', p.enforcement_level,
        'enabled', p.enabled,
        'metadata', p.metadata,
        'updated_at', p.updated_at
      )
      order by p.policy_key
    ),
    '[]'::jsonb
  )
  from public.platform_runtime_policies p
  where (p_owner_engine_code is null or p.owner_engine_code = p_owner_engine_code)
    and (p_include_disabled or p.enabled);
$function$;

create or replace function public.get_platform_capabilities_rpc(
  p_provider_engine_code text default null,
  p_include_unavailable boolean default false
)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $function$
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'capability_key', c.capability_key,
        'capability_name', c.capability_name,
        'description', c.description,
        'provider_engine_code', c.provider_engine_code,
        'capability_version', c.capability_version,
        'lifecycle_status', c.lifecycle_status,
        'runtime_available', c.runtime_available,
        'invocation_mode', c.invocation_mode,
        'contract', c.contract,
        'metadata', c.metadata,
        'updated_at', c.updated_at
      )
      order by c.provider_engine_code, c.capability_key
    ),
    '[]'::jsonb
  )
  from public.platform_capabilities c
  where (p_provider_engine_code is null or c.provider_engine_code = p_provider_engine_code)
    and (
      p_include_unavailable
      or (c.lifecycle_status = 'active' and c.runtime_available)
    );
$function$;

create or replace function public.get_platform_governance_snapshot_rpc()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $function$
  select jsonb_build_object(
    'contract_version', 'platform-governance-v1',
    'generated_at', now(),
    'configuration', public.get_platform_configuration_rpc(),
    'engines', public.get_platform_engine_registry_rpc(false),
    'feature_flags', public.get_platform_feature_flags_rpc(null, false),
    'runtime_policies', public.get_platform_runtime_policies_rpc(null, false),
    'capabilities', public.get_platform_capabilities_rpc(null, false)
  );
$function$;

comment on function public.get_platform_configuration_rpc() is
  'Returns the canonical singleton platform configuration.';
comment on function public.get_platform_engine_registry_rpc(boolean) is
  'Returns the ordered platform engine registry, optionally including inactive engines.';
comment on function public.get_platform_feature_flags_rpc(text, boolean) is
  'Returns feature flags effective for an environment, optionally including disabled flags.';
comment on function public.get_platform_runtime_policies_rpc(text, boolean) is
  'Returns typed runtime policies, optionally filtered by owner engine.';
comment on function public.get_platform_capabilities_rpc(text, boolean) is
  'Returns runtime capabilities, optionally filtered by provider engine.';
comment on function public.get_platform_governance_snapshot_rpc() is
  'Returns the consolidated Platform Governance Engine v1 read model.';

revoke all on function public.get_platform_configuration_rpc() from public, anon;
revoke all on function public.get_platform_engine_registry_rpc(boolean) from public, anon;
revoke all on function public.get_platform_feature_flags_rpc(text, boolean) from public, anon;
revoke all on function public.get_platform_runtime_policies_rpc(text, boolean) from public, anon;
revoke all on function public.get_platform_capabilities_rpc(text, boolean) from public, anon;
revoke all on function public.get_platform_governance_snapshot_rpc() from public, anon;

grant execute on function public.get_platform_configuration_rpc() to authenticated, service_role;
grant execute on function public.get_platform_engine_registry_rpc(boolean) to authenticated, service_role;
grant execute on function public.get_platform_feature_flags_rpc(text, boolean) to authenticated, service_role;
grant execute on function public.get_platform_runtime_policies_rpc(text, boolean) to authenticated, service_role;
grant execute on function public.get_platform_capabilities_rpc(text, boolean) to authenticated, service_role;
grant execute on function public.get_platform_governance_snapshot_rpc() to authenticated, service_role;

-- --------------------------------------------------------------------------
-- 11. Migration assertions
-- --------------------------------------------------------------------------

do $assertions$
declare
  v_configuration_count integer;
  v_engine_count integer;
  v_capability_count integer;
begin
  select count(*) into v_configuration_count
  from public.platform_configuration
  where configuration_key = 'primary';

  if v_configuration_count <> 1 then
    raise exception 'PLATFORM_GOVERNANCE_ASSERTION_FAILED: expected one primary configuration, found %', v_configuration_count;
  end if;

  select count(*) into v_engine_count
  from public.platform_engine_registry;

  if v_engine_count < 10 then
    raise exception 'PLATFORM_GOVERNANCE_ASSERTION_FAILED: expected at least 10 registered engines, found %', v_engine_count;
  end if;

  select count(*) into v_capability_count
  from public.platform_capabilities
  where lifecycle_status = 'active';

  if v_capability_count < 9 then
    raise exception 'PLATFORM_GOVERNANCE_ASSERTION_FAILED: expected at least 9 active capabilities, found %', v_capability_count;
  end if;

  if not exists (
    select 1
    from public.platform_engine_registry
    where engine_code = 'platform_governance_engine'
      and engine_version = '1.0.0'
      and lifecycle_status = 'active'
  ) then
    raise exception 'PLATFORM_GOVERNANCE_ASSERTION_FAILED: governance engine registry seed missing';
  end if;
end;
$assertions$;

commit;
