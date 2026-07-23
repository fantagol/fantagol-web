-- =============================================================================
-- FANTAGOL
-- Migration: 110_commercial_provider_registry_foundation.sql
-- Milestone: Commercial Platform - Provider Registry and Governance Foundation
--
-- Purpose:
--   - Introduce a single provider-independent commercial provider registry
--   - Model provider capabilities without coupling engines to concrete vendors
--   - Introduce immutable provider configuration versions
--   - Govern provider activation through readiness and explicit approval
--   - Provide canonical bindings to reward sources and commercial campaigns
--   - Record an append-only lifecycle timeline
--
-- Safety guarantees:
--   - No concrete payment, advertising or store provider is inserted
--   - No provider is enabled or activated by this migration
--   - No external credential or secret is stored
--   - No campaign is activated
--   - No reward, claim, purchase, ledger movement or wallet mutation is generated
--   - No frontend role receives write access
-- =============================================================================

begin;

-- =============================================================================
-- 0. DEPENDENCY ASSERTIONS
-- =============================================================================

do $$
begin
  if to_regclass('public.reward_sources') is null
     or to_regclass('public.reward_campaigns') is null
     or to_regclass('public.commercial_campaign_runtime_states') is null then
    raise exception using
      errcode = 'P0001',
      message = 'MIGRATION_110_REQUIRES_COMMERCIAL_CAMPAIGN_FOUNDATION';
  end if;
end;
$$;

-- =============================================================================
-- 1. CANONICAL COMMERCIAL PROVIDER REGISTRY
-- =============================================================================

create table if not exists public.commercial_providers (
  id uuid primary key default gen_random_uuid(),
  provider_code text not null unique,
  display_name text not null,
  legal_name text null,

  provider_type text not null,
  ownership_type text not null default 'external',
  integration_mode text not null default 'adapter',
  adapter_key text null,

  enabled boolean not null default false,
  public boolean not null default false,
  test_mode boolean not null default true,

  documentation_url text null,
  configuration jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  version integer not null default 1,

  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),

  constraint commercial_providers_code_check
    check (
      provider_code = upper(provider_code)
      and provider_code ~ '^[A-Z][A-Z0-9_]{1,95}$'
    ),

  constraint commercial_providers_display_name_check
    check (length(btrim(display_name)) between 1 and 160),

  constraint commercial_providers_type_check
    check (provider_type in (
      'internal',
      'payment_gateway',
      'advertising_network',
      'mobile_store',
      'sponsor',
      'partner',
      'marketplace',
      'other'
    )),

  constraint commercial_providers_ownership_check
    check (ownership_type in ('internal', 'external')),

  constraint commercial_providers_integration_mode_check
    check (integration_mode in ('internal', 'adapter', 'manual', 'none')),

  constraint commercial_providers_adapter_check
    check (
      (integration_mode = 'adapter' and adapter_key is not null and length(btrim(adapter_key)) > 0)
      or
      (integration_mode <> 'adapter')
    ),

  constraint commercial_providers_configuration_object_check
    check (jsonb_typeof(configuration) = 'object'),

  constraint commercial_providers_metadata_object_check
    check (jsonb_typeof(metadata) = 'object'),

  constraint commercial_providers_version_check
    check (version > 0),

  constraint commercial_providers_public_check
    check (not public or enabled)
);

create index if not exists commercial_providers_type_idx
  on public.commercial_providers (provider_type, enabled, provider_code);

comment on table public.commercial_providers is
  'Canonical provider-independent registry. Concrete vendors are inserted only by later certified migrations or backend operations.';

-- =============================================================================
-- 2. PROVIDER CAPABILITIES
-- =============================================================================

create table if not exists public.commercial_provider_capabilities (
  id uuid primary key default gen_random_uuid(),
  provider_id uuid not null,
  capability_code text not null,
  capability_status text not null default 'declared',
  certification_status text not null default 'not_certified',
  certified_at timestamptz null,
  certified_by text null,
  configuration jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),

  constraint commercial_provider_capabilities_provider_id_fkey
    foreign key (provider_id)
    references public.commercial_providers (id)
    on delete restrict,

  constraint commercial_provider_capabilities_unique
    unique (provider_id, capability_code),

  constraint commercial_provider_capabilities_code_check
    check (
      capability_code = upper(capability_code)
      and capability_code ~ '^[A-Z][A-Z0-9_]{1,95}$'
    ),

  constraint commercial_provider_capabilities_status_check
    check (capability_status in ('declared', 'available', 'suspended', 'retired')),

  constraint commercial_provider_capabilities_certification_check
    check (certification_status in ('not_certified', 'certified', 'revoked')),

  constraint commercial_provider_capabilities_certified_fields_check
    check (
      (certification_status = 'certified' and certified_at is not null and certified_by is not null)
      or
      (certification_status <> 'certified')
    ),

  constraint commercial_provider_capabilities_configuration_object_check
    check (jsonb_typeof(configuration) = 'object'),

  constraint commercial_provider_capabilities_metadata_object_check
    check (jsonb_typeof(metadata) = 'object')
);

create index if not exists commercial_provider_capabilities_lookup_idx
  on public.commercial_provider_capabilities (
    provider_id,
    capability_status,
    certification_status,
    capability_code
  );

comment on table public.commercial_provider_capabilities is
  'Declared and certified provider capabilities such as PAYMENT_CAPTURE, REWARDED_AD_VERIFICATION or STORE_PURCHASE_VALIDATION.';

-- =============================================================================
-- 3. IMMUTABLE PROVIDER CONFIGURATION VERSIONS
-- =============================================================================

create table if not exists public.commercial_provider_versions (
  id uuid primary key default gen_random_uuid(),
  provider_id uuid not null,
  provider_code text not null,
  version_number integer not null,
  version_status text not null default 'draft',

  configuration_snapshot jsonb not null,
  configuration_hash text not null,
  change_summary text null,

  created_by text not null,
  approved_by text null,
  approved_at timestamptz null,
  superseded_at timestamptz null,
  retired_at timestamptz null,

  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp(),

  constraint commercial_provider_versions_provider_id_fkey
    foreign key (provider_id)
    references public.commercial_providers (id)
    on delete restrict,

  constraint commercial_provider_versions_unique
    unique (provider_id, version_number),

  constraint commercial_provider_versions_code_check
    check (
      provider_code = upper(provider_code)
      and provider_code ~ '^[A-Z][A-Z0-9_]{1,95}$'
    ),

  constraint commercial_provider_versions_number_check
    check (version_number > 0),

  constraint commercial_provider_versions_status_check
    check (version_status in ('draft', 'approved', 'superseded', 'retired')),

  constraint commercial_provider_versions_snapshot_object_check
    check (jsonb_typeof(configuration_snapshot) = 'object'),

  constraint commercial_provider_versions_hash_check
    check (configuration_hash ~ '^[a-f0-9]{32}$'),

  constraint commercial_provider_versions_created_by_check
    check (length(btrim(created_by)) between 1 and 160),

  constraint commercial_provider_versions_metadata_object_check
    check (jsonb_typeof(metadata) = 'object'),

  constraint commercial_provider_versions_approval_check
    check (
      (version_status = 'draft' and approved_at is null and approved_by is null)
      or
      (version_status <> 'draft' and approved_at is not null and approved_by is not null)
    )
);

create unique index if not exists commercial_provider_versions_one_approved_idx
  on public.commercial_provider_versions (provider_id)
  where version_status = 'approved';

create index if not exists commercial_provider_versions_provider_idx
  on public.commercial_provider_versions (provider_id, version_number desc);

comment on table public.commercial_provider_versions is
  'Immutable non-secret provider configuration snapshots. Secret values must remain in the deployment secret manager.';

-- =============================================================================
-- 4. PROVIDER ACTIVATION REQUESTS
-- =============================================================================

create table if not exists public.commercial_provider_activation_requests (
  id uuid primary key default gen_random_uuid(),
  provider_id uuid not null,
  provider_version_id uuid not null,

  request_status text not null default 'pending',
  requested_mode text not null default 'test',
  readiness_status text not null default 'not_evaluated',
  readiness_report jsonb not null default '{}'::jsonb,
  readiness_evaluated_at timestamptz null,

  requested_by text not null,
  request_reason text null,
  reviewed_by text null,
  review_reason text null,
  reviewed_at timestamptz null,

  correlation_id uuid not null default gen_random_uuid(),
  causation_id uuid null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),

  constraint commercial_provider_activation_requests_provider_id_fkey
    foreign key (provider_id)
    references public.commercial_providers (id)
    on delete restrict,

  constraint commercial_provider_activation_requests_version_id_fkey
    foreign key (provider_version_id)
    references public.commercial_provider_versions (id)
    on delete restrict,

  constraint commercial_provider_activation_requests_status_check
    check (request_status in ('pending', 'approved', 'rejected', 'cancelled')),

  constraint commercial_provider_activation_requests_mode_check
    check (requested_mode in ('test', 'production')),

  constraint commercial_provider_activation_requests_readiness_check
    check (readiness_status in ('not_evaluated', 'ready', 'blocked')),

  constraint commercial_provider_activation_requests_report_object_check
    check (jsonb_typeof(readiness_report) = 'object'),

  constraint commercial_provider_activation_requests_requested_by_check
    check (length(btrim(requested_by)) between 1 and 160),

  constraint commercial_provider_activation_requests_metadata_object_check
    check (jsonb_typeof(metadata) = 'object'),

  constraint commercial_provider_activation_requests_review_check
    check (
      (request_status = 'pending' and reviewed_at is null and reviewed_by is null)
      or
      (request_status <> 'pending' and reviewed_at is not null and reviewed_by is not null)
    )
);

create unique index if not exists commercial_provider_activation_requests_one_pending_idx
  on public.commercial_provider_activation_requests (provider_id)
  where request_status = 'pending';

create index if not exists commercial_provider_activation_requests_status_idx
  on public.commercial_provider_activation_requests (request_status, created_at);

comment on table public.commercial_provider_activation_requests is
  'Explicit governance requests for activating a certified provider version in test or production mode.';

-- =============================================================================
-- 5. AUTHORITATIVE PROVIDER RUNTIME STATE
-- =============================================================================

create table if not exists public.commercial_provider_runtime_states (
  provider_id uuid primary key,
  provider_code text not null,
  runtime_state text not null default 'inactive',
  active_version_id uuid null,
  activation_request_id uuid null,
  active_mode text null,

  readiness_status text not null default 'not_evaluated',
  readiness_report jsonb not null default '{}'::jsonb,
  last_evaluated_at timestamptz null,

  activated_at timestamptz null,
  suspended_at timestamptz null,
  retired_at timestamptz null,
  state_reason text null,

  correlation_id uuid null,
  causation_id uuid null,
  metadata jsonb not null default '{}'::jsonb,
  version integer not null default 1,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),

  constraint commercial_provider_runtime_states_provider_id_fkey
    foreign key (provider_id)
    references public.commercial_providers (id)
    on delete restrict,

  constraint commercial_provider_runtime_states_active_version_id_fkey
    foreign key (active_version_id)
    references public.commercial_provider_versions (id)
    on delete restrict,

  constraint commercial_provider_runtime_states_activation_request_id_fkey
    foreign key (activation_request_id)
    references public.commercial_provider_activation_requests (id)
    on delete restrict,

  constraint commercial_provider_runtime_states_code_check
    check (
      provider_code = upper(provider_code)
      and provider_code ~ '^[A-Z][A-Z0-9_]{1,95}$'
    ),

  constraint commercial_provider_runtime_states_state_check
    check (runtime_state in (
      'inactive',
      'activation_pending',
      'active_test',
      'active_production',
      'suspended',
      'blocked',
      'retired'
    )),

  constraint commercial_provider_runtime_states_mode_check
    check (active_mode is null or active_mode in ('test', 'production')),

  constraint commercial_provider_runtime_states_readiness_check
    check (readiness_status in ('not_evaluated', 'ready', 'blocked')),

  constraint commercial_provider_runtime_states_report_object_check
    check (jsonb_typeof(readiness_report) = 'object'),

  constraint commercial_provider_runtime_states_metadata_object_check
    check (jsonb_typeof(metadata) = 'object'),

  constraint commercial_provider_runtime_states_version_check
    check (version > 0)
);

create index if not exists commercial_provider_runtime_states_state_idx
  on public.commercial_provider_runtime_states (runtime_state, updated_at);

comment on table public.commercial_provider_runtime_states is
  'Authoritative operational projection for commercial provider activation and readiness.';

-- =============================================================================
-- 6. APPEND-ONLY PROVIDER LIFECYCLE EVENTS
-- =============================================================================

create table if not exists public.commercial_provider_lifecycle_events (
  id uuid primary key default gen_random_uuid(),
  provider_id uuid not null,
  provider_version_id uuid null,
  activation_request_id uuid null,
  provider_code text not null,
  event_type text not null,
  previous_state text null,
  next_state text null,
  actor text not null,
  reason text null,
  correlation_id uuid not null default gen_random_uuid(),
  causation_id uuid null,
  payload jsonb not null default '{}'::jsonb,
  occurred_at timestamptz not null default clock_timestamp(),

  constraint commercial_provider_lifecycle_events_provider_id_fkey
    foreign key (provider_id)
    references public.commercial_providers (id)
    on delete restrict,

  constraint commercial_provider_lifecycle_events_version_id_fkey
    foreign key (provider_version_id)
    references public.commercial_provider_versions (id)
    on delete restrict,

  constraint commercial_provider_lifecycle_events_request_id_fkey
    foreign key (activation_request_id)
    references public.commercial_provider_activation_requests (id)
    on delete restrict,

  constraint commercial_provider_lifecycle_events_code_check
    check (
      provider_code = upper(provider_code)
      and provider_code ~ '^[A-Z][A-Z0-9_]{1,95}$'
    ),

  constraint commercial_provider_lifecycle_events_type_check
    check (event_type in (
      'PROVIDER_REGISTERED',
      'CAPABILITY_DECLARED',
      'CAPABILITY_CERTIFIED',
      'PROVIDER_VERSION_CREATED',
      'PROVIDER_VERSION_APPROVED',
      'PROVIDER_VERSION_SUPERSEDED',
      'PROVIDER_READINESS_EVALUATED',
      'PROVIDER_ACTIVATION_REQUESTED',
      'PROVIDER_ACTIVATION_APPROVED',
      'PROVIDER_ACTIVATION_REJECTED',
      'PROVIDER_SUSPENDED',
      'PROVIDER_RETIRED',
      'SOURCE_BINDING_CREATED',
      'CAMPAIGN_BINDING_CREATED'
    )),

  constraint commercial_provider_lifecycle_events_actor_check
    check (length(btrim(actor)) between 1 and 160),

  constraint commercial_provider_lifecycle_events_payload_object_check
    check (jsonb_typeof(payload) = 'object')
);

create index if not exists commercial_provider_lifecycle_events_timeline_idx
  on public.commercial_provider_lifecycle_events (provider_id, occurred_at, id);

create index if not exists commercial_provider_lifecycle_events_correlation_idx
  on public.commercial_provider_lifecycle_events (correlation_id, occurred_at);

comment on table public.commercial_provider_lifecycle_events is
  'Append-only audit timeline for provider registry, certification and runtime transitions.';

-- =============================================================================
-- 7. CANONICAL BINDINGS
-- =============================================================================

create table if not exists public.commercial_provider_source_bindings (
  id uuid primary key default gen_random_uuid(),
  provider_id uuid not null,
  reward_source_id uuid not null,
  binding_role text not null,
  enabled boolean not null default false,
  configuration jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),

  constraint commercial_provider_source_bindings_provider_id_fkey
    foreign key (provider_id)
    references public.commercial_providers (id)
    on delete restrict,

  constraint commercial_provider_source_bindings_reward_source_id_fkey
    foreign key (reward_source_id)
    references public.reward_sources (id)
    on delete restrict,

  constraint commercial_provider_source_bindings_unique
    unique (provider_id, reward_source_id, binding_role),

  constraint commercial_provider_source_bindings_role_check
    check (binding_role in ('funding', 'verification', 'settlement', 'distribution')),

  constraint commercial_provider_source_bindings_configuration_object_check
    check (jsonb_typeof(configuration) = 'object'),

  constraint commercial_provider_source_bindings_metadata_object_check
    check (jsonb_typeof(metadata) = 'object')
);

create index if not exists commercial_provider_source_bindings_lookup_idx
  on public.commercial_provider_source_bindings (reward_source_id, enabled, binding_role);

create table if not exists public.commercial_campaign_provider_bindings (
  id uuid primary key default gen_random_uuid(),
  campaign_id uuid not null,
  provider_id uuid not null,
  binding_role text not null,
  required boolean not null default true,
  enabled boolean not null default false,
  configuration jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),

  constraint commercial_campaign_provider_bindings_campaign_id_fkey
    foreign key (campaign_id)
    references public.reward_campaigns (id)
    on delete restrict,

  constraint commercial_campaign_provider_bindings_provider_id_fkey
    foreign key (provider_id)
    references public.commercial_providers (id)
    on delete restrict,

  constraint commercial_campaign_provider_bindings_unique
    unique (campaign_id, provider_id, binding_role),

  constraint commercial_campaign_provider_bindings_role_check
    check (binding_role in ('funding', 'verification', 'settlement', 'distribution')),

  constraint commercial_campaign_provider_bindings_configuration_object_check
    check (jsonb_typeof(configuration) = 'object'),

  constraint commercial_campaign_provider_bindings_metadata_object_check
    check (jsonb_typeof(metadata) = 'object')
);

create index if not exists commercial_campaign_provider_bindings_lookup_idx
  on public.commercial_campaign_provider_bindings (campaign_id, enabled, binding_role);

comment on table public.commercial_provider_source_bindings is
  'Disabled-by-default bridge between providers and canonical reward sources.';

comment on table public.commercial_campaign_provider_bindings is
  'Disabled-by-default bridge between governed campaigns and commercial providers.';

-- =============================================================================
-- 8. IMMUTABILITY GUARDS
-- =============================================================================

create or replace function public.protect_commercial_provider_version_internal()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'DELETE' then
    raise exception using
      errcode = 'P0001',
      message = 'COMMERCIAL_PROVIDER_VERSION_DELETE_FORBIDDEN';
  end if;

  if old.version_status <> 'draft' then
    if new.provider_id is distinct from old.provider_id
       or new.provider_code is distinct from old.provider_code
       or new.version_number is distinct from old.version_number
       or new.configuration_snapshot is distinct from old.configuration_snapshot
       or new.configuration_hash is distinct from old.configuration_hash
       or new.created_by is distinct from old.created_by
       or new.created_at is distinct from old.created_at then
      raise exception using
        errcode = 'P0001',
        message = 'APPROVED_COMMERCIAL_PROVIDER_VERSION_IMMUTABLE';
    end if;
  end if;

  return new;
end;
$$;

create or replace function public.protect_commercial_provider_lifecycle_event_internal()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  raise exception using
    errcode = 'P0001',
    message = 'COMMERCIAL_PROVIDER_LIFECYCLE_EVENT_IMMUTABLE';
end;
$$;

drop trigger if exists commercial_provider_versions_guard
  on public.commercial_provider_versions;
create trigger commercial_provider_versions_guard
before update or delete on public.commercial_provider_versions
for each row execute function public.protect_commercial_provider_version_internal();

drop trigger if exists commercial_provider_lifecycle_events_guard
  on public.commercial_provider_lifecycle_events;
create trigger commercial_provider_lifecycle_events_guard
before update or delete on public.commercial_provider_lifecycle_events
for each row execute function public.protect_commercial_provider_lifecycle_event_internal();

-- =============================================================================
-- 9. EVENT APPEND FUNCTION
-- =============================================================================

create or replace function public.append_commercial_provider_lifecycle_event_internal(
  p_provider_id uuid,
  p_provider_version_id uuid,
  p_activation_request_id uuid,
  p_event_type text,
  p_previous_state text,
  p_next_state text,
  p_actor text,
  p_reason text default null,
  p_correlation_id uuid default null,
  p_causation_id uuid default null,
  p_payload jsonb default '{}'::jsonb
)
returns public.commercial_provider_lifecycle_events
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_provider public.commercial_providers;
  v_result public.commercial_provider_lifecycle_events;
begin
  select *
  into v_provider
  from public.commercial_providers
  where id = p_provider_id;

  if v_provider.id is null then
    raise exception using errcode = 'P0001', message = 'COMMERCIAL_PROVIDER_NOT_FOUND';
  end if;

  insert into public.commercial_provider_lifecycle_events (
    provider_id,
    provider_version_id,
    activation_request_id,
    provider_code,
    event_type,
    previous_state,
    next_state,
    actor,
    reason,
    correlation_id,
    causation_id,
    payload
  ) values (
    v_provider.id,
    p_provider_version_id,
    p_activation_request_id,
    v_provider.provider_code,
    p_event_type,
    p_previous_state,
    p_next_state,
    btrim(p_actor),
    p_reason,
    coalesce(p_correlation_id, gen_random_uuid()),
    p_causation_id,
    coalesce(p_payload, '{}'::jsonb)
  )
  returning * into v_result;

  return v_result;
end;
$$;

-- =============================================================================
-- 10. PROVIDER REGISTRATION
-- =============================================================================

create or replace function public.register_commercial_provider_internal(
  p_provider_code text,
  p_display_name text,
  p_provider_type text,
  p_ownership_type text default 'external',
  p_integration_mode text default 'adapter',
  p_adapter_key text default null,
  p_legal_name text default null,
  p_configuration jsonb default '{}'::jsonb,
  p_metadata jsonb default '{}'::jsonb,
  p_actor text default 'SYSTEM',
  p_correlation_id uuid default null,
  p_causation_id uuid default null
)
returns public.commercial_providers
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_result public.commercial_providers;
  v_correlation_id uuid := coalesce(p_correlation_id, gen_random_uuid());
begin
  insert into public.commercial_providers (
    provider_code,
    display_name,
    legal_name,
    provider_type,
    ownership_type,
    integration_mode,
    adapter_key,
    enabled,
    public,
    test_mode,
    configuration,
    metadata
  ) values (
    upper(btrim(p_provider_code)),
    btrim(p_display_name),
    nullif(btrim(p_legal_name), ''),
    p_provider_type,
    p_ownership_type,
    p_integration_mode,
    nullif(btrim(p_adapter_key), ''),
    false,
    false,
    true,
    coalesce(p_configuration, '{}'::jsonb),
    coalesce(p_metadata, '{}'::jsonb)
  )
  returning * into v_result;

  insert into public.commercial_provider_runtime_states (
    provider_id,
    provider_code,
    runtime_state,
    readiness_status,
    correlation_id,
    causation_id
  ) values (
    v_result.id,
    v_result.provider_code,
    'inactive',
    'not_evaluated',
    v_correlation_id,
    p_causation_id
  );

  perform public.append_commercial_provider_lifecycle_event_internal(
    v_result.id,
    null,
    null,
    'PROVIDER_REGISTERED',
    null,
    'inactive',
    p_actor,
    'Commercial provider registered in disabled state',
    v_correlation_id,
    p_causation_id,
    jsonb_build_object(
      'provider_type', v_result.provider_type,
      'integration_mode', v_result.integration_mode,
      'enabled', false,
      'public', false
    )
  );

  return v_result;
end;
$$;

-- =============================================================================
-- 11. CAPABILITY DECLARATION AND CERTIFICATION
-- =============================================================================

create or replace function public.declare_commercial_provider_capability_internal(
  p_provider_id uuid,
  p_capability_code text,
  p_configuration jsonb default '{}'::jsonb,
  p_metadata jsonb default '{}'::jsonb,
  p_actor text default 'SYSTEM',
  p_correlation_id uuid default null,
  p_causation_id uuid default null
)
returns public.commercial_provider_capabilities
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_result public.commercial_provider_capabilities;
begin
  insert into public.commercial_provider_capabilities (
    provider_id,
    capability_code,
    capability_status,
    certification_status,
    configuration,
    metadata
  ) values (
    p_provider_id,
    upper(btrim(p_capability_code)),
    'declared',
    'not_certified',
    coalesce(p_configuration, '{}'::jsonb),
    coalesce(p_metadata, '{}'::jsonb)
  )
  returning * into v_result;

  perform public.append_commercial_provider_lifecycle_event_internal(
    p_provider_id,
    null,
    null,
    'CAPABILITY_DECLARED',
    null,
    'declared',
    p_actor,
    null,
    p_correlation_id,
    p_causation_id,
    jsonb_build_object('capability_code', v_result.capability_code)
  );

  return v_result;
end;
$$;

create or replace function public.certify_commercial_provider_capability_internal(
  p_capability_id uuid,
  p_certified_by text,
  p_reason text default null,
  p_correlation_id uuid default null,
  p_causation_id uuid default null
)
returns public.commercial_provider_capabilities
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_capability public.commercial_provider_capabilities;
  v_result public.commercial_provider_capabilities;
begin
  select * into v_capability
  from public.commercial_provider_capabilities
  where id = p_capability_id
  for update;

  if v_capability.id is null then
    raise exception using errcode = 'P0001', message = 'COMMERCIAL_PROVIDER_CAPABILITY_NOT_FOUND';
  end if;

  update public.commercial_provider_capabilities
  set capability_status = 'available',
      certification_status = 'certified',
      certified_at = clock_timestamp(),
      certified_by = btrim(p_certified_by),
      updated_at = clock_timestamp()
  where id = p_capability_id
  returning * into v_result;

  perform public.append_commercial_provider_lifecycle_event_internal(
    v_result.provider_id,
    null,
    null,
    'CAPABILITY_CERTIFIED',
    v_capability.certification_status,
    v_result.certification_status,
    p_certified_by,
    p_reason,
    p_correlation_id,
    p_causation_id,
    jsonb_build_object('capability_code', v_result.capability_code)
  );

  return v_result;
end;
$$;

-- =============================================================================
-- 12. PROVIDER VERSIONING
-- =============================================================================

create or replace function public.create_commercial_provider_version_internal(
  p_provider_id uuid,
  p_created_by text,
  p_change_summary text default null,
  p_metadata jsonb default '{}'::jsonb,
  p_correlation_id uuid default null,
  p_causation_id uuid default null
)
returns public.commercial_provider_versions
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_provider public.commercial_providers;
  v_snapshot jsonb;
  v_version_number integer;
  v_result public.commercial_provider_versions;
begin
  select * into v_provider
  from public.commercial_providers
  where id = p_provider_id
  for update;

  if v_provider.id is null then
    raise exception using errcode = 'P0001', message = 'COMMERCIAL_PROVIDER_NOT_FOUND';
  end if;

  if exists (
    select 1 from public.commercial_provider_versions
    where provider_id = p_provider_id and version_status = 'draft'
  ) then
    raise exception using errcode = 'P0001', message = 'COMMERCIAL_PROVIDER_DRAFT_VERSION_ALREADY_EXISTS';
  end if;

  select coalesce(max(version_number), 0) + 1
  into v_version_number
  from public.commercial_provider_versions
  where provider_id = p_provider_id;

  v_snapshot := jsonb_build_object(
    'provider_code', v_provider.provider_code,
    'display_name', v_provider.display_name,
    'legal_name', v_provider.legal_name,
    'provider_type', v_provider.provider_type,
    'ownership_type', v_provider.ownership_type,
    'integration_mode', v_provider.integration_mode,
    'adapter_key', v_provider.adapter_key,
    'test_mode', v_provider.test_mode,
    'documentation_url', v_provider.documentation_url,
    'configuration', v_provider.configuration,
    'metadata', v_provider.metadata,
    'capabilities', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'capability_code', c.capability_code,
          'capability_status', c.capability_status,
          'certification_status', c.certification_status,
          'configuration', c.configuration
        ) order by c.capability_code
      )
      from public.commercial_provider_capabilities c
      where c.provider_id = v_provider.id
    ), '[]'::jsonb)
  );

  insert into public.commercial_provider_versions (
    provider_id,
    provider_code,
    version_number,
    version_status,
    configuration_snapshot,
    configuration_hash,
    change_summary,
    created_by,
    metadata
  ) values (
    v_provider.id,
    v_provider.provider_code,
    v_version_number,
    'draft',
    v_snapshot,
    md5(v_snapshot::text),
    p_change_summary,
    btrim(p_created_by),
    coalesce(p_metadata, '{}'::jsonb)
  )
  returning * into v_result;

  perform public.append_commercial_provider_lifecycle_event_internal(
    v_provider.id,
    v_result.id,
    null,
    'PROVIDER_VERSION_CREATED',
    null,
    'draft',
    p_created_by,
    p_change_summary,
    p_correlation_id,
    p_causation_id,
    jsonb_build_object('version_number', v_result.version_number)
  );

  return v_result;
end;
$$;

create or replace function public.approve_commercial_provider_version_internal(
  p_provider_version_id uuid,
  p_approved_by text,
  p_reason text default null,
  p_correlation_id uuid default null,
  p_causation_id uuid default null
)
returns public.commercial_provider_versions
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_version public.commercial_provider_versions;
  v_superseded public.commercial_provider_versions;
  v_result public.commercial_provider_versions;
begin
  select * into v_version
  from public.commercial_provider_versions
  where id = p_provider_version_id
  for update;

  if v_version.id is null then
    raise exception using errcode = 'P0001', message = 'COMMERCIAL_PROVIDER_VERSION_NOT_FOUND';
  end if;

  if v_version.version_status <> 'draft' then
    raise exception using errcode = 'P0001', message = 'COMMERCIAL_PROVIDER_VERSION_NOT_DRAFT';
  end if;

  select * into v_superseded
  from public.commercial_provider_versions
  where provider_id = v_version.provider_id
    and version_status = 'approved'
  for update;

  if v_superseded.id is not null then
    update public.commercial_provider_versions
    set version_status = 'superseded',
        superseded_at = clock_timestamp()
    where id = v_superseded.id;

    perform public.append_commercial_provider_lifecycle_event_internal(
      v_version.provider_id,
      v_superseded.id,
      null,
      'PROVIDER_VERSION_SUPERSEDED',
      'approved',
      'superseded',
      p_approved_by,
      p_reason,
      p_correlation_id,
      p_causation_id,
      jsonb_build_object('superseded_by_version_id', v_version.id)
    );
  end if;

  update public.commercial_provider_versions
  set version_status = 'approved',
      approved_by = btrim(p_approved_by),
      approved_at = clock_timestamp()
  where id = v_version.id
  returning * into v_result;

  perform public.append_commercial_provider_lifecycle_event_internal(
    v_result.provider_id,
    v_result.id,
    null,
    'PROVIDER_VERSION_APPROVED',
    'draft',
    'approved',
    p_approved_by,
    p_reason,
    p_correlation_id,
    p_causation_id,
    jsonb_build_object('version_number', v_result.version_number)
  );

  return v_result;
end;
$$;

-- =============================================================================
-- 13. READINESS AND ACTIVATION GOVERNANCE
-- =============================================================================

create or replace function public.evaluate_commercial_provider_readiness_internal(
  p_provider_id uuid,
  p_provider_version_id uuid default null,
  p_requested_mode text default 'test'
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_provider public.commercial_providers;
  v_version public.commercial_provider_versions;
  v_blockers jsonb := '[]'::jsonb;
  v_capability_count bigint;
  v_certified_capability_count bigint;
begin
  select * into v_provider
  from public.commercial_providers
  where id = p_provider_id;

  if v_provider.id is null then
    return jsonb_build_object(
      'ready', false,
      'status', 'blocked',
      'blockers', jsonb_build_array('PROVIDER_NOT_FOUND')
    );
  end if;

  if p_provider_version_id is null then
    select * into v_version
    from public.commercial_provider_versions
    where provider_id = p_provider_id
      and version_status = 'approved';
  else
    select * into v_version
    from public.commercial_provider_versions
    where id = p_provider_version_id
      and provider_id = p_provider_id;
  end if;

  if v_version.id is null then
    v_blockers := v_blockers || '"APPROVED_PROVIDER_VERSION_MISSING"'::jsonb;
  elsif v_version.version_status <> 'approved' then
    v_blockers := v_blockers || '"PROVIDER_VERSION_NOT_APPROVED"'::jsonb;
  end if;

  if v_provider.integration_mode = 'adapter'
     and nullif(btrim(v_provider.adapter_key), '') is null then
    v_blockers := v_blockers || '"ADAPTER_KEY_MISSING"'::jsonb;
  end if;

  select count(*),
         count(*) filter (
           where capability_status = 'available'
             and certification_status = 'certified'
         )
  into v_capability_count, v_certified_capability_count
  from public.commercial_provider_capabilities
  where provider_id = p_provider_id;

  if v_capability_count = 0 then
    v_blockers := v_blockers || '"PROVIDER_CAPABILITIES_MISSING"'::jsonb;
  elsif v_certified_capability_count = 0 then
    v_blockers := v_blockers || '"CERTIFIED_PROVIDER_CAPABILITY_MISSING"'::jsonb;
  end if;

  if p_requested_mode not in ('test', 'production') then
    v_blockers := v_blockers || '"REQUESTED_MODE_INVALID"'::jsonb;
  end if;

  if p_requested_mode = 'production' and v_provider.test_mode then
    v_blockers := v_blockers || '"PROVIDER_STILL_IN_TEST_MODE"'::jsonb;
  end if;

  return jsonb_build_object(
    'ready', jsonb_array_length(v_blockers) = 0,
    'status', case when jsonb_array_length(v_blockers) = 0 then 'ready' else 'blocked' end,
    'blockers', v_blockers,
    'provider_id', v_provider.id,
    'provider_code', v_provider.provider_code,
    'provider_version_id', v_version.id,
    'requested_mode', p_requested_mode,
    'declared_capability_count', v_capability_count,
    'certified_capability_count', v_certified_capability_count,
    'evaluated_at', clock_timestamp()
  );
end;
$$;

create or replace function public.request_commercial_provider_activation_internal(
  p_provider_id uuid,
  p_provider_version_id uuid,
  p_requested_by text,
  p_requested_mode text default 'test',
  p_request_reason text default null,
  p_metadata jsonb default '{}'::jsonb,
  p_correlation_id uuid default null,
  p_causation_id uuid default null
)
returns public.commercial_provider_activation_requests
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_provider public.commercial_providers;
  v_version public.commercial_provider_versions;
  v_readiness jsonb;
  v_result public.commercial_provider_activation_requests;
  v_correlation_id uuid := coalesce(p_correlation_id, gen_random_uuid());
begin
  select * into v_provider
  from public.commercial_providers
  where id = p_provider_id
  for update;

  if v_provider.id is null then
    raise exception using errcode = 'P0001', message = 'COMMERCIAL_PROVIDER_NOT_FOUND';
  end if;

  select * into v_version
  from public.commercial_provider_versions
  where id = p_provider_version_id
    and provider_id = p_provider_id;

  if v_version.id is null then
    raise exception using errcode = 'P0001', message = 'COMMERCIAL_PROVIDER_VERSION_NOT_FOUND';
  end if;

  if v_version.version_status <> 'approved' then
    raise exception using errcode = 'P0001', message = 'COMMERCIAL_PROVIDER_VERSION_NOT_APPROVED';
  end if;

  v_readiness := public.evaluate_commercial_provider_readiness_internal(
    p_provider_id,
    p_provider_version_id,
    p_requested_mode
  );

  insert into public.commercial_provider_activation_requests (
    provider_id,
    provider_version_id,
    request_status,
    requested_mode,
    readiness_status,
    readiness_report,
    readiness_evaluated_at,
    requested_by,
    request_reason,
    correlation_id,
    causation_id,
    metadata
  ) values (
    p_provider_id,
    p_provider_version_id,
    'pending',
    p_requested_mode,
    v_readiness->>'status',
    v_readiness,
    clock_timestamp(),
    btrim(p_requested_by),
    p_request_reason,
    v_correlation_id,
    p_causation_id,
    coalesce(p_metadata, '{}'::jsonb)
  )
  returning * into v_result;

  update public.commercial_provider_runtime_states
  set runtime_state = 'activation_pending',
      active_version_id = p_provider_version_id,
      activation_request_id = v_result.id,
      active_mode = null,
      readiness_status = v_readiness->>'status',
      readiness_report = v_readiness,
      last_evaluated_at = clock_timestamp(),
      state_reason = 'PROVIDER_ACTIVATION_REQUESTED',
      correlation_id = v_correlation_id,
      causation_id = p_causation_id,
      version = version + 1,
      updated_at = clock_timestamp()
  where provider_id = p_provider_id;

  perform public.append_commercial_provider_lifecycle_event_internal(
    p_provider_id,
    p_provider_version_id,
    v_result.id,
    'PROVIDER_READINESS_EVALUATED',
    'not_evaluated',
    v_readiness->>'status',
    p_requested_by,
    null,
    v_correlation_id,
    p_causation_id,
    v_readiness
  );

  perform public.append_commercial_provider_lifecycle_event_internal(
    p_provider_id,
    p_provider_version_id,
    v_result.id,
    'PROVIDER_ACTIVATION_REQUESTED',
    'inactive',
    'activation_pending',
    p_requested_by,
    p_request_reason,
    v_correlation_id,
    p_causation_id,
    jsonb_build_object(
      'requested_mode', p_requested_mode,
      'readiness_status', v_readiness->>'status'
    )
  );

  return v_result;
end;
$$;

create or replace function public.approve_commercial_provider_activation_internal(
  p_activation_request_id uuid,
  p_approved_by text,
  p_review_reason text default null,
  p_causation_id uuid default null
)
returns public.commercial_provider_runtime_states
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_request public.commercial_provider_activation_requests;
  v_readiness jsonb;
  v_next_state text;
  v_result public.commercial_provider_runtime_states;
begin
  select * into v_request
  from public.commercial_provider_activation_requests
  where id = p_activation_request_id
  for update;

  if v_request.id is null then
    raise exception using errcode = 'P0001', message = 'COMMERCIAL_PROVIDER_ACTIVATION_REQUEST_NOT_FOUND';
  end if;

  if v_request.request_status <> 'pending' then
    raise exception using errcode = 'P0001', message = 'COMMERCIAL_PROVIDER_ACTIVATION_REQUEST_NOT_PENDING';
  end if;

  v_readiness := public.evaluate_commercial_provider_readiness_internal(
    v_request.provider_id,
    v_request.provider_version_id,
    v_request.requested_mode
  );

  if coalesce((v_readiness->>'ready')::boolean, false) is not true then
    raise exception using
      errcode = 'P0001',
      message = 'COMMERCIAL_PROVIDER_ACTIVATION_BLOCKED',
      detail = v_readiness::text;
  end if;

  v_next_state := case
    when v_request.requested_mode = 'production' then 'active_production'
    else 'active_test'
  end;

  update public.commercial_provider_activation_requests
  set request_status = 'approved',
      readiness_status = 'ready',
      readiness_report = v_readiness,
      readiness_evaluated_at = clock_timestamp(),
      reviewed_by = btrim(p_approved_by),
      review_reason = p_review_reason,
      reviewed_at = clock_timestamp(),
      updated_at = clock_timestamp()
  where id = v_request.id;

  update public.commercial_providers
  set enabled = true,
      public = false,
      test_mode = (v_request.requested_mode = 'test'),
      version = version + 1,
      updated_at = clock_timestamp()
  where id = v_request.provider_id;

  update public.commercial_provider_runtime_states
  set runtime_state = v_next_state,
      active_version_id = v_request.provider_version_id,
      activation_request_id = v_request.id,
      active_mode = v_request.requested_mode,
      readiness_status = 'ready',
      readiness_report = v_readiness,
      last_evaluated_at = clock_timestamp(),
      activated_at = clock_timestamp(),
      suspended_at = null,
      state_reason = 'PROVIDER_ACTIVATION_APPROVED',
      correlation_id = v_request.correlation_id,
      causation_id = coalesce(p_causation_id, v_request.causation_id),
      version = version + 1,
      updated_at = clock_timestamp()
  where provider_id = v_request.provider_id
  returning * into v_result;

  perform public.append_commercial_provider_lifecycle_event_internal(
    v_request.provider_id,
    v_request.provider_version_id,
    v_request.id,
    'PROVIDER_ACTIVATION_APPROVED',
    'activation_pending',
    v_next_state,
    p_approved_by,
    p_review_reason,
    v_request.correlation_id,
    coalesce(p_causation_id, v_request.causation_id),
    jsonb_build_object('active_mode', v_request.requested_mode)
  );

  return v_result;
end;
$$;

create or replace function public.reject_commercial_provider_activation_internal(
  p_activation_request_id uuid,
  p_rejected_by text,
  p_review_reason text,
  p_causation_id uuid default null
)
returns public.commercial_provider_activation_requests
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_request public.commercial_provider_activation_requests;
  v_result public.commercial_provider_activation_requests;
begin
  select * into v_request
  from public.commercial_provider_activation_requests
  where id = p_activation_request_id
  for update;

  if v_request.id is null then
    raise exception using errcode = 'P0001', message = 'COMMERCIAL_PROVIDER_ACTIVATION_REQUEST_NOT_FOUND';
  end if;

  if v_request.request_status <> 'pending' then
    raise exception using errcode = 'P0001', message = 'COMMERCIAL_PROVIDER_ACTIVATION_REQUEST_NOT_PENDING';
  end if;

  update public.commercial_provider_activation_requests
  set request_status = 'rejected',
      reviewed_by = btrim(p_rejected_by),
      review_reason = p_review_reason,
      reviewed_at = clock_timestamp(),
      updated_at = clock_timestamp()
  where id = v_request.id
  returning * into v_result;

  update public.commercial_provider_runtime_states
  set runtime_state = 'inactive',
      active_version_id = v_request.provider_version_id,
      activation_request_id = v_request.id,
      active_mode = null,
      state_reason = 'PROVIDER_ACTIVATION_EXPLICITLY_REJECTED',
      correlation_id = v_request.correlation_id,
      causation_id = coalesce(p_causation_id, v_request.causation_id),
      version = version + 1,
      updated_at = clock_timestamp()
  where provider_id = v_request.provider_id;

  perform public.append_commercial_provider_lifecycle_event_internal(
    v_request.provider_id,
    v_request.provider_version_id,
    v_request.id,
    'PROVIDER_ACTIVATION_REJECTED',
    'activation_pending',
    'inactive',
    p_rejected_by,
    p_review_reason,
    v_request.correlation_id,
    coalesce(p_causation_id, v_request.causation_id),
    '{}'::jsonb
  );

  return v_result;
end;
$$;

create or replace function public.suspend_commercial_provider_internal(
  p_provider_id uuid,
  p_actor text,
  p_reason text,
  p_correlation_id uuid default null,
  p_causation_id uuid default null
)
returns public.commercial_provider_runtime_states
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_state public.commercial_provider_runtime_states;
  v_result public.commercial_provider_runtime_states;
begin
  select * into v_state
  from public.commercial_provider_runtime_states
  where provider_id = p_provider_id
  for update;

  if v_state.provider_id is null then
    raise exception using errcode = 'P0001', message = 'COMMERCIAL_PROVIDER_RUNTIME_STATE_NOT_FOUND';
  end if;

  if v_state.runtime_state not in ('active_test', 'active_production', 'blocked') then
    raise exception using errcode = 'P0001', message = 'COMMERCIAL_PROVIDER_NOT_SUSPENDABLE';
  end if;

  update public.commercial_providers
  set enabled = false,
      public = false,
      version = version + 1,
      updated_at = clock_timestamp()
  where id = p_provider_id;

  update public.commercial_provider_runtime_states
  set runtime_state = 'suspended',
      active_mode = null,
      suspended_at = clock_timestamp(),
      state_reason = p_reason,
      correlation_id = coalesce(p_correlation_id, gen_random_uuid()),
      causation_id = p_causation_id,
      version = version + 1,
      updated_at = clock_timestamp()
  where provider_id = p_provider_id
  returning * into v_result;

  perform public.append_commercial_provider_lifecycle_event_internal(
    p_provider_id,
    v_state.active_version_id,
    v_state.activation_request_id,
    'PROVIDER_SUSPENDED',
    v_state.runtime_state,
    'suspended',
    p_actor,
    p_reason,
    v_result.correlation_id,
    p_causation_id,
    '{}'::jsonb
  );

  return v_result;
end;
$$;

create or replace function public.retire_commercial_provider_internal(
  p_provider_id uuid,
  p_actor text,
  p_reason text,
  p_correlation_id uuid default null,
  p_causation_id uuid default null
)
returns public.commercial_provider_runtime_states
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_state public.commercial_provider_runtime_states;
  v_result public.commercial_provider_runtime_states;
begin
  select * into v_state
  from public.commercial_provider_runtime_states
  where provider_id = p_provider_id
  for update;

  if v_state.provider_id is null then
    raise exception using errcode = 'P0001', message = 'COMMERCIAL_PROVIDER_RUNTIME_STATE_NOT_FOUND';
  end if;

  update public.commercial_providers
  set enabled = false,
      public = false,
      version = version + 1,
      updated_at = clock_timestamp()
  where id = p_provider_id;

  update public.commercial_provider_source_bindings
  set enabled = false,
      updated_at = clock_timestamp()
  where provider_id = p_provider_id;

  update public.commercial_campaign_provider_bindings
  set enabled = false,
      updated_at = clock_timestamp()
  where provider_id = p_provider_id;

  update public.commercial_provider_runtime_states
  set runtime_state = 'retired',
      active_mode = null,
      retired_at = clock_timestamp(),
      state_reason = p_reason,
      correlation_id = coalesce(p_correlation_id, gen_random_uuid()),
      causation_id = p_causation_id,
      version = version + 1,
      updated_at = clock_timestamp()
  where provider_id = p_provider_id
  returning * into v_result;

  perform public.append_commercial_provider_lifecycle_event_internal(
    p_provider_id,
    v_state.active_version_id,
    v_state.activation_request_id,
    'PROVIDER_RETIRED',
    v_state.runtime_state,
    'retired',
    p_actor,
    p_reason,
    v_result.correlation_id,
    p_causation_id,
    '{}'::jsonb
  );

  return v_result;
end;
$$;

-- =============================================================================
-- 14. READ MODELS
-- =============================================================================

create or replace function public.get_commercial_provider_runtime_states_internal()
returns table (
  provider_id uuid,
  provider_code text,
  display_name text,
  provider_type text,
  ownership_type text,
  integration_mode text,
  adapter_key text,
  provider_enabled boolean,
  provider_public boolean,
  test_mode boolean,
  runtime_state text,
  readiness_status text,
  active_mode text,
  active_version_id uuid,
  active_version_number integer,
  activation_request_id uuid,
  declared_capability_count bigint,
  certified_capability_count bigint,
  updated_at timestamptz
)
language sql
security definer
set search_path = public, pg_temp
as $$
  select
    p.id,
    p.provider_code,
    p.display_name,
    p.provider_type,
    p.ownership_type,
    p.integration_mode,
    p.adapter_key,
    p.enabled,
    p.public,
    p.test_mode,
    s.runtime_state,
    s.readiness_status,
    s.active_mode,
    s.active_version_id,
    v.version_number,
    s.activation_request_id,
    count(c.id),
    count(c.id) filter (
      where c.capability_status = 'available'
        and c.certification_status = 'certified'
    ),
    s.updated_at
  from public.commercial_providers p
  join public.commercial_provider_runtime_states s
    on s.provider_id = p.id
  left join public.commercial_provider_versions v
    on v.id = s.active_version_id
  left join public.commercial_provider_capabilities c
    on c.provider_id = p.id
  group by p.id, s.provider_id, v.id
  order by p.provider_code;
$$;

create or replace function public.get_commercial_provider_lifecycle_internal(
  p_provider_id uuid
)
returns setof public.commercial_provider_lifecycle_events
language sql
security definer
set search_path = public, pg_temp
as $$
  select e.*
  from public.commercial_provider_lifecycle_events e
  where e.provider_id = p_provider_id
  order by e.occurred_at, e.id;
$$;

-- =============================================================================
-- 15. RLS, PRIVILEGES AND BACKEND-ONLY EXECUTION
-- =============================================================================

alter table public.commercial_providers enable row level security;
alter table public.commercial_provider_capabilities enable row level security;
alter table public.commercial_provider_versions enable row level security;
alter table public.commercial_provider_activation_requests enable row level security;
alter table public.commercial_provider_runtime_states enable row level security;
alter table public.commercial_provider_lifecycle_events enable row level security;
alter table public.commercial_provider_source_bindings enable row level security;
alter table public.commercial_campaign_provider_bindings enable row level security;

revoke all on table public.commercial_providers from public, anon, authenticated;
revoke all on table public.commercial_provider_capabilities from public, anon, authenticated;
revoke all on table public.commercial_provider_versions from public, anon, authenticated;
revoke all on table public.commercial_provider_activation_requests from public, anon, authenticated;
revoke all on table public.commercial_provider_runtime_states from public, anon, authenticated;
revoke all on table public.commercial_provider_lifecycle_events from public, anon, authenticated;
revoke all on table public.commercial_provider_source_bindings from public, anon, authenticated;
revoke all on table public.commercial_campaign_provider_bindings from public, anon, authenticated;

revoke all on function public.protect_commercial_provider_version_internal() from public, anon, authenticated;
revoke all on function public.protect_commercial_provider_lifecycle_event_internal() from public, anon, authenticated;
revoke all on function public.append_commercial_provider_lifecycle_event_internal(uuid, uuid, uuid, text, text, text, text, text, uuid, uuid, jsonb) from public, anon, authenticated;
revoke all on function public.register_commercial_provider_internal(text, text, text, text, text, text, text, jsonb, jsonb, text, uuid, uuid) from public, anon, authenticated;
revoke all on function public.declare_commercial_provider_capability_internal(uuid, text, jsonb, jsonb, text, uuid, uuid) from public, anon, authenticated;
revoke all on function public.certify_commercial_provider_capability_internal(uuid, text, text, uuid, uuid) from public, anon, authenticated;
revoke all on function public.create_commercial_provider_version_internal(uuid, text, text, jsonb, uuid, uuid) from public, anon, authenticated;
revoke all on function public.approve_commercial_provider_version_internal(uuid, text, text, uuid, uuid) from public, anon, authenticated;
revoke all on function public.evaluate_commercial_provider_readiness_internal(uuid, uuid, text) from public, anon, authenticated;
revoke all on function public.request_commercial_provider_activation_internal(uuid, uuid, text, text, text, jsonb, uuid, uuid) from public, anon, authenticated;
revoke all on function public.approve_commercial_provider_activation_internal(uuid, text, text, uuid) from public, anon, authenticated;
revoke all on function public.reject_commercial_provider_activation_internal(uuid, text, text, uuid) from public, anon, authenticated;
revoke all on function public.suspend_commercial_provider_internal(uuid, text, text, uuid, uuid) from public, anon, authenticated;
revoke all on function public.retire_commercial_provider_internal(uuid, text, text, uuid, uuid) from public, anon, authenticated;
revoke all on function public.get_commercial_provider_runtime_states_internal() from public, anon, authenticated;
revoke all on function public.get_commercial_provider_lifecycle_internal(uuid) from public, anon, authenticated;

grant select, insert, update on table public.commercial_providers to service_role;
grant select, insert, update on table public.commercial_provider_capabilities to service_role;
grant select, insert, update on table public.commercial_provider_versions to service_role;
grant select, insert, update on table public.commercial_provider_activation_requests to service_role;
grant select, insert, update on table public.commercial_provider_runtime_states to service_role;
grant select, insert on table public.commercial_provider_lifecycle_events to service_role;
grant select, insert, update on table public.commercial_provider_source_bindings to service_role;
grant select, insert, update on table public.commercial_campaign_provider_bindings to service_role;

grant execute on function public.append_commercial_provider_lifecycle_event_internal(uuid, uuid, uuid, text, text, text, text, text, uuid, uuid, jsonb) to service_role;
grant execute on function public.register_commercial_provider_internal(text, text, text, text, text, text, text, jsonb, jsonb, text, uuid, uuid) to service_role;
grant execute on function public.declare_commercial_provider_capability_internal(uuid, text, jsonb, jsonb, text, uuid, uuid) to service_role;
grant execute on function public.certify_commercial_provider_capability_internal(uuid, text, text, uuid, uuid) to service_role;
grant execute on function public.create_commercial_provider_version_internal(uuid, text, text, jsonb, uuid, uuid) to service_role;
grant execute on function public.approve_commercial_provider_version_internal(uuid, text, text, uuid, uuid) to service_role;
grant execute on function public.evaluate_commercial_provider_readiness_internal(uuid, uuid, text) to service_role;
grant execute on function public.request_commercial_provider_activation_internal(uuid, uuid, text, text, text, jsonb, uuid, uuid) to service_role;
grant execute on function public.approve_commercial_provider_activation_internal(uuid, text, text, uuid) to service_role;
grant execute on function public.reject_commercial_provider_activation_internal(uuid, text, text, uuid) to service_role;
grant execute on function public.suspend_commercial_provider_internal(uuid, text, text, uuid, uuid) to service_role;
grant execute on function public.retire_commercial_provider_internal(uuid, text, text, uuid, uuid) to service_role;
grant execute on function public.get_commercial_provider_runtime_states_internal() to service_role;
grant execute on function public.get_commercial_provider_lifecycle_internal(uuid) to service_role;

-- =============================================================================
-- 16. INSTALLATION CERTIFICATION
-- =============================================================================

do $$
declare
  v_provider_count bigint;
  v_enabled_count bigint;
  v_public_count bigint;
  v_runtime_count bigint;
  v_binding_count bigint;
begin
  select count(*),
         count(*) filter (where enabled),
         count(*) filter (where public)
  into v_provider_count, v_enabled_count, v_public_count
  from public.commercial_providers;

  select count(*)
  into v_runtime_count
  from public.commercial_provider_runtime_states;

  select
    (select count(*) from public.commercial_provider_source_bindings)
    +
    (select count(*) from public.commercial_campaign_provider_bindings)
  into v_binding_count;

  if v_provider_count <> 0
     or v_enabled_count <> 0
     or v_public_count <> 0
     or v_runtime_count <> 0
     or v_binding_count <> 0 then
    raise exception using
      errcode = 'P0001',
      message = 'MIGRATION_110_PASSIVE_FOUNDATION_ASSERTION_FAILED',
      detail = format(
        'provider_count=%s enabled_count=%s public_count=%s runtime_count=%s binding_count=%s',
        v_provider_count,
        v_enabled_count,
        v_public_count,
        v_runtime_count,
        v_binding_count
      );
  end if;

  if exists (select 1 from public.reward_campaigns where enabled or public) then
    raise exception using
      errcode = 'P0001',
      message = 'MIGRATION_110_CAMPAIGN_SAFETY_ASSERTION_FAILED';
  end if;

  raise notice
    'MIGRATION_110_CERTIFIED provider_count=%, runtime_count=%, binding_count=%, enabled_count=%, public_count=%',
    v_provider_count,
    v_runtime_count,
    v_binding_count,
    v_enabled_count,
    v_public_count;
end;
$$;

commit;
