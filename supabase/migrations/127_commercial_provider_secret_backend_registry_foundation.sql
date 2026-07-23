-- =============================================================================
-- FANTAGOL
-- Migration: 127_commercial_provider_secret_backend_registry_foundation.sql
-- Milestone: Commercial Platform - Provider Secret Backend Registry
--
-- Purpose:
--   Introduce the passive registry and governance layer for future provider
--   secret backends. The registry stores only backend identity, declared
--   capabilities, immutable contract versions, opaque reference fingerprints,
--   passive bindings, validation receipts and append-only events.
--
-- Safety posture:
--   - backend registration and capability governance are enabled;
--   - version registration, validation and passive binding are enabled;
--   - endpoint discovery is disabled;
--   - backend probing and backend contact are disabled;
--   - authentication, secret lookup, resolution and decryption are disabled;
--   - credential material loading and delivery are disabled;
--   - network access is disabled;
--   - plaintext secrets, credentials, URLs and connection strings are forbidden.
-- =============================================================================

\set ON_ERROR_STOP on

begin;

create extension if not exists pgcrypto with schema extensions;

do $$
begin
  if to_regclass('public.commercial_provider_credential_bindings') is null then
    raise exception
      'MIGRATION_127_DEPENDENCY_MISSING commercial_provider_credential_bindings';
  end if;

  if to_regclass('public.commercial_secret_resolution_policies') is null then
    raise exception
      'MIGRATION_127_DEPENDENCY_MISSING commercial_secret_resolution_policies';
  end if;

  if to_regclass('public.commercial_secret_resolution_plans') is null then
    raise exception
      'MIGRATION_127_DEPENDENCY_MISSING commercial_secret_resolution_plans';
  end if;

  if to_regprocedure(
    'public.record_blocked_secret_resolution_attempt(uuid,uuid,text,text)'
  ) is null then
    raise exception
      'MIGRATION_127_DEPENDENCY_MISSING record_blocked_secret_resolution_attempt';
  end if;
end
$$;

-- =============================================================================
-- 1. REGISTRY POLICY
-- =============================================================================

create table public.commercial_secret_backend_registry_policies (
  id uuid primary key default gen_random_uuid(),
  policy_code text not null,
  environment text not null default 'production',
  policy_status text not null default 'draft',
  policy_version integer not null default 1,

  backend_registration_enabled boolean not null default true,
  version_registration_enabled boolean not null default true,
  capability_governance_enabled boolean not null default true,
  validation_enabled boolean not null default true,
  passive_binding_enabled boolean not null default true,
  blocked_probe_recording_enabled boolean not null default true,

  endpoint_discovery_enabled boolean not null default false,
  backend_probe_enabled boolean not null default false,
  backend_contact_enabled boolean not null default false,
  backend_authentication_enabled boolean not null default false,
  secret_lookup_enabled boolean not null default false,
  secret_resolution_enabled boolean not null default false,
  secret_decryption_enabled boolean not null default false,
  credential_material_loading_enabled boolean not null default false,
  credential_delivery_enabled boolean not null default false,
  network_access_enabled boolean not null default false,

  maximum_versions_per_backend integer not null default 50,
  maximum_capabilities_per_version integer not null default 32,
  maximum_bindings_per_backend integer not null default 1000,

  created_by text not null,
  approved_by text,
  approved_at timestamptz,
  policy_metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp(),

  constraint commercial_secret_backend_registry_policy_unique
    unique (policy_code, environment),

  constraint commercial_secret_backend_registry_policy_code_check
    check (
      policy_code = lower(policy_code)
      and policy_code ~ '^[a-z][a-z0-9:_-]{7,159}$'
      and environment in ('development','test','staging','production')
    ),

  constraint commercial_secret_backend_registry_policy_status_check
    check (policy_status in ('draft','approved','retired')),

  constraint commercial_secret_backend_registry_policy_limits_check
    check (
      policy_version > 0
      and maximum_versions_per_backend between 1 and 1000
      and maximum_capabilities_per_version between 1 and 128
      and maximum_bindings_per_backend between 1 and 100000
    ),

  constraint commercial_secret_backend_registry_policy_json_check
    check (
      jsonb_typeof(policy_metadata) = 'object'
      and not (policy_metadata ?| array[
        'secret','secret_value','password','private_key','access_token',
        'refresh_token','api_key','client_secret','plaintext','ciphertext',
        'url','uri','endpoint','connection_string','dsn','host','hostname'
      ])
    ),

  constraint commercial_secret_backend_registry_policy_actor_check
    check (
      length(btrim(created_by)) between 1 and 160
      and (approved_by is null or length(btrim(approved_by)) between 1 and 160)
    ),

  constraint commercial_secret_backend_registry_policy_passive_check
    check (
      endpoint_discovery_enabled = false
      and backend_probe_enabled = false
      and backend_contact_enabled = false
      and backend_authentication_enabled = false
      and secret_lookup_enabled = false
      and secret_resolution_enabled = false
      and secret_decryption_enabled = false
      and credential_material_loading_enabled = false
      and credential_delivery_enabled = false
      and network_access_enabled = false
    )
);

comment on table public.commercial_secret_backend_registry_policies is
'Immutable passive governance policy for the commercial provider secret-backend registry.';

-- =============================================================================
-- 2. BACKEND REGISTRY
-- =============================================================================

create table public.commercial_secret_backends (
  id uuid primary key default gen_random_uuid(),
  backend_code text not null,
  backend_name text not null,
  backend_type text not null,
  environment text not null default 'production',
  backend_status text not null default 'draft',
  trust_tier text not null default 'untrusted',

  ownership_scope text not null default 'platform',
  provider_scope text,
  region_code text,
  residency_class text not null default 'unspecified',

  reference_namespace text not null,
  reference_fingerprint text not null,
  registration_hash text not null,

  active_version_id uuid,
  registered_by text not null,
  approved_by text,
  approved_at timestamptz,
  retired_by text,
  retired_at timestamptz,
  retirement_reason text,

  backend_metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),

  constraint commercial_secret_backend_unique
    unique (backend_code, environment),

  constraint commercial_secret_backend_code_check
    check (
      backend_code = lower(backend_code)
      and backend_code ~ '^[a-z][a-z0-9:_-]{5,127}$'
      and length(btrim(backend_name)) between 1 and 160
    ),

  constraint commercial_secret_backend_type_check
    check (backend_type in (
      'managed_vault',
      'cloud_secret_manager',
      'hsm_backed_vault',
      'database_vault',
      'external_broker',
      'development_stub'
    )),

  constraint commercial_secret_backend_environment_check
    check (environment in ('development','test','staging','production')),

  constraint commercial_secret_backend_status_check
    check (backend_status in ('draft','validated','approved','suspended','retired')),

  constraint commercial_secret_backend_trust_check
    check (trust_tier in ('untrusted','registered','validated','approved')),

  constraint commercial_secret_backend_scope_check
    check (
      ownership_scope in ('platform','provider','tenant')
      and (provider_scope is null or length(btrim(provider_scope)) between 1 and 160)
      and (region_code is null or region_code ~ '^[A-Z0-9-]{2,24}$')
      and residency_class in ('unspecified','regional','eu','us','global')
    ),

  constraint commercial_secret_backend_reference_check
    check (
      reference_namespace = lower(reference_namespace)
      and reference_namespace ~ '^[a-z][a-z0-9:_-]{5,127}$'
      and reference_fingerprint ~ '^[a-f0-9]{64}$'
      and registration_hash ~ '^[a-f0-9]{64}$'
    ),

  constraint commercial_secret_backend_actor_check
    check (
      length(btrim(registered_by)) between 1 and 160
      and (approved_by is null or length(btrim(approved_by)) between 1 and 160)
      and (retired_by is null or length(btrim(retired_by)) between 1 and 160)
    ),

  constraint commercial_secret_backend_json_check
    check (
      jsonb_typeof(backend_metadata) = 'object'
      and not (backend_metadata ?| array[
        'secret','secret_value','password','private_key','access_token',
        'refresh_token','api_key','client_secret','plaintext','ciphertext',
        'url','uri','endpoint','connection_string','dsn','host','hostname'
      ])
    )
);

create index commercial_secret_backends_status_idx
  on public.commercial_secret_backends
  (environment, backend_status, trust_tier, created_at);

comment on table public.commercial_secret_backends is
'Passive registry identity for a secret backend. Only opaque namespaces and hashes are stored.';

-- =============================================================================
-- 3. IMMUTABLE BACKEND VERSIONS
-- =============================================================================

create table public.commercial_secret_backend_versions (
  id uuid primary key default gen_random_uuid(),
  secret_backend_id uuid not null,
  version_number integer not null,
  version_status text not null default 'draft',

  contract_name text not null,
  contract_version text not null,
  contract_hash text not null,
  reference_schema_hash text not null,

  supports_reference_validation boolean not null default true,
  supports_versioned_references boolean not null default false,
  supports_rotation_metadata boolean not null default false,
  supports_expiry_metadata boolean not null default false,
  supports_scope_metadata boolean not null default false,

  supports_endpoint_discovery boolean not null default false,
  supports_backend_probe boolean not null default false,
  supports_backend_contact boolean not null default false,
  supports_authentication boolean not null default false,
  supports_secret_lookup boolean not null default false,
  supports_secret_resolution boolean not null default false,
  supports_decryption boolean not null default false,
  supports_material_loading boolean not null default false,
  supports_delivery boolean not null default false,
  supports_network_access boolean not null default false,

  registered_by text not null,
  validated_by text,
  validated_at timestamptz,
  approved_by text,
  approved_at timestamptz,
  version_metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp(),

  constraint commercial_secret_backend_version_backend_fkey
    foreign key (secret_backend_id)
    references public.commercial_secret_backends(id)
    on delete restrict,

  constraint commercial_secret_backend_version_unique
    unique (secret_backend_id, version_number),

  constraint commercial_secret_backend_version_status_check
    check (version_status in ('draft','validated','approved','retired')),

  constraint commercial_secret_backend_version_contract_check
    check (
      version_number > 0
      and length(btrim(contract_name)) between 1 and 160
      and length(btrim(contract_version)) between 1 and 80
      and contract_hash ~ '^[a-f0-9]{64}$'
      and reference_schema_hash ~ '^[a-f0-9]{64}$'
    ),

  constraint commercial_secret_backend_version_actor_check
    check (
      length(btrim(registered_by)) between 1 and 160
      and (validated_by is null or length(btrim(validated_by)) between 1 and 160)
      and (approved_by is null or length(btrim(approved_by)) between 1 and 160)
    ),

  constraint commercial_secret_backend_version_json_check
    check (
      jsonb_typeof(version_metadata) = 'object'
      and not (version_metadata ?| array[
        'secret','secret_value','password','private_key','access_token',
        'refresh_token','api_key','client_secret','plaintext','ciphertext',
        'url','uri','endpoint','connection_string','dsn','host','hostname'
      ])
    ),

  constraint commercial_secret_backend_version_passive_check
    check (
      supports_endpoint_discovery = false
      and supports_backend_probe = false
      and supports_backend_contact = false
      and supports_authentication = false
      and supports_secret_lookup = false
      and supports_secret_resolution = false
      and supports_decryption = false
      and supports_material_loading = false
      and supports_delivery = false
      and supports_network_access = false
    )
);

alter table public.commercial_secret_backends
  add constraint commercial_secret_backend_active_version_fkey
  foreign key (active_version_id)
  references public.commercial_secret_backend_versions(id)
  on delete restrict
  deferrable initially deferred;

comment on table public.commercial_secret_backend_versions is
'Immutable contract version for a registered backend. Executable capabilities remain structurally false.';

-- =============================================================================
-- 4. CAPABILITY CATALOG
-- =============================================================================

create table public.commercial_secret_backend_capabilities (
  id uuid primary key default gen_random_uuid(),
  secret_backend_version_id uuid not null,
  capability_code text not null,
  capability_class text not null,
  capability_status text not null default 'declared',

  passive_only boolean not null default true,
  requires_backend_contact boolean not null default false,
  requires_authentication boolean not null default false,
  requires_secret_material boolean not null default false,
  requires_network boolean not null default false,

  declared_by text not null,
  validated_by text,
  validated_at timestamptz,
  capability_metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp(),

  constraint commercial_secret_backend_capability_version_fkey
    foreign key (secret_backend_version_id)
    references public.commercial_secret_backend_versions(id)
    on delete restrict,

  constraint commercial_secret_backend_capability_unique
    unique (secret_backend_version_id, capability_code),

  constraint commercial_secret_backend_capability_code_check
    check (
      capability_code = lower(capability_code)
      and capability_code ~ '^[a-z][a-z0-9:_-]{3,95}$'
    ),

  constraint commercial_secret_backend_capability_class_check
    check (capability_class in (
      'reference_validation',
      'version_metadata',
      'rotation_metadata',
      'expiry_metadata',
      'scope_metadata'
    )),

  constraint commercial_secret_backend_capability_status_check
    check (capability_status in ('declared','validated','retired')),

  constraint commercial_secret_backend_capability_actor_check
    check (
      length(btrim(declared_by)) between 1 and 160
      and (validated_by is null or length(btrim(validated_by)) between 1 and 160)
    ),

  constraint commercial_secret_backend_capability_json_check
    check (
      jsonb_typeof(capability_metadata) = 'object'
      and not (capability_metadata ?| array[
        'secret','secret_value','password','private_key','access_token',
        'refresh_token','api_key','client_secret','plaintext','ciphertext',
        'url','uri','endpoint','connection_string','dsn','host','hostname'
      ])
    ),

  constraint commercial_secret_backend_capability_passive_check
    check (
      passive_only = true
      and requires_backend_contact = false
      and requires_authentication = false
      and requires_secret_material = false
      and requires_network = false
    )
);

comment on table public.commercial_secret_backend_capabilities is
'Declared passive metadata capabilities for a backend contract version.';

-- =============================================================================
-- 5. PASSIVE BACKEND BINDINGS
-- =============================================================================

create table public.commercial_secret_backend_bindings (
  id uuid primary key default gen_random_uuid(),
  binding_key text not null unique,
  secret_backend_id uuid not null,
  secret_backend_version_id uuid not null,
  credential_binding_id uuid,
  orchestrator_policy_id uuid not null,

  binding_status text not null default 'draft',
  binding_scope text not null default 'credential_binding',
  priority integer not null default 100,
  reference_namespace text not null,
  binding_hash text not null,

  backend_contact_allowed boolean not null default false,
  authentication_allowed boolean not null default false,
  secret_lookup_allowed boolean not null default false,
  secret_resolution_allowed boolean not null default false,
  decryption_allowed boolean not null default false,
  material_loading_allowed boolean not null default false,
  delivery_allowed boolean not null default false,
  network_access_allowed boolean not null default false,

  bound_by text not null,
  validated_by text,
  validated_at timestamptz,
  suspended_by text,
  suspended_at timestamptz,
  suspension_reason text,
  binding_metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),

  constraint commercial_secret_backend_binding_backend_fkey
    foreign key (secret_backend_id)
    references public.commercial_secret_backends(id)
    on delete restrict,

  constraint commercial_secret_backend_binding_version_fkey
    foreign key (secret_backend_version_id)
    references public.commercial_secret_backend_versions(id)
    on delete restrict,

  constraint commercial_secret_backend_binding_credential_fkey
    foreign key (credential_binding_id)
    references public.commercial_provider_credential_bindings(id)
    on delete restrict,

  constraint commercial_secret_backend_binding_policy_fkey
    foreign key (orchestrator_policy_id)
    references public.commercial_secret_resolution_policies(id)
    on delete restrict,

  constraint commercial_secret_backend_binding_unique
    unique (
      secret_backend_id,
      secret_backend_version_id,
      credential_binding_id,
      orchestrator_policy_id
    ),

  constraint commercial_secret_backend_binding_key_check
    check (
      binding_key = lower(binding_key)
      and binding_key ~ '^[a-z][a-z0-9:_-]{7,159}$'
      and binding_scope in ('credential_binding','provider','platform')
      and priority between 1 and 10000
      and reference_namespace = lower(reference_namespace)
      and reference_namespace ~ '^[a-z][a-z0-9:_-]{5,127}$'
      and binding_hash ~ '^[a-f0-9]{64}$'
    ),

  constraint commercial_secret_backend_binding_status_check
    check (binding_status in ('draft','validated','suspended','retired')),

  constraint commercial_secret_backend_binding_actor_check
    check (
      length(btrim(bound_by)) between 1 and 160
      and (validated_by is null or length(btrim(validated_by)) between 1 and 160)
      and (suspended_by is null or length(btrim(suspended_by)) between 1 and 160)
    ),

  constraint commercial_secret_backend_binding_json_check
    check (
      jsonb_typeof(binding_metadata) = 'object'
      and not (binding_metadata ?| array[
        'secret','secret_value','password','private_key','access_token',
        'refresh_token','api_key','client_secret','plaintext','ciphertext',
        'url','uri','endpoint','connection_string','dsn','host','hostname'
      ])
    ),

  constraint commercial_secret_backend_binding_passive_check
    check (
      backend_contact_allowed = false
      and authentication_allowed = false
      and secret_lookup_allowed = false
      and secret_resolution_allowed = false
      and decryption_allowed = false
      and material_loading_allowed = false
      and delivery_allowed = false
      and network_access_allowed = false
    )
);

create index commercial_secret_backend_bindings_lookup_idx
  on public.commercial_secret_backend_bindings
  (credential_binding_id, binding_status, priority, created_at);

comment on table public.commercial_secret_backend_bindings is
'Passive binding between backend metadata, credential governance and the secret-resolution orchestrator.';

-- =============================================================================
-- 6. VALIDATION RECEIPTS
-- =============================================================================

create table public.commercial_secret_backend_validation_receipts (
  id uuid primary key default gen_random_uuid(),
  secret_backend_id uuid not null,
  secret_backend_version_id uuid,
  secret_backend_binding_id uuid,
  receipt_type text not null,
  validation_status text not null,
  normalized_payload jsonb not null default '{}'::jsonb,
  content_hash text not null,
  issued_by text not null,
  correlation_id uuid not null,
  metadata jsonb not null default '{}'::jsonb,
  issued_at timestamptz not null default clock_timestamp(),

  constraint commercial_secret_backend_receipt_backend_fkey
    foreign key (secret_backend_id)
    references public.commercial_secret_backends(id)
    on delete restrict,

  constraint commercial_secret_backend_receipt_version_fkey
    foreign key (secret_backend_version_id)
    references public.commercial_secret_backend_versions(id)
    on delete restrict,

  constraint commercial_secret_backend_receipt_binding_fkey
    foreign key (secret_backend_binding_id)
    references public.commercial_secret_backend_bindings(id)
    on delete restrict,

  constraint commercial_secret_backend_receipt_type_check
    check (receipt_type in (
      'backend_registered',
      'version_registered',
      'version_validated',
      'binding_registered',
      'binding_validated',
      'probe_blocked'
    )),

  constraint commercial_secret_backend_receipt_status_check
    check (validation_status in ('accepted','validated','blocked')),

  constraint commercial_secret_backend_receipt_json_check
    check (
      jsonb_typeof(normalized_payload) = 'object'
      and jsonb_typeof(metadata) = 'object'
      and not (normalized_payload ?| array[
        'secret','secret_value','password','private_key','access_token',
        'refresh_token','api_key','client_secret','plaintext','ciphertext',
        'url','uri','endpoint','connection_string','dsn','host','hostname'
      ])
      and not (metadata ?| array[
        'secret','secret_value','password','private_key','access_token',
        'refresh_token','api_key','client_secret','plaintext','ciphertext',
        'url','uri','endpoint','connection_string','dsn','host','hostname'
      ])
      and content_hash ~ '^[a-f0-9]{64}$'
      and length(btrim(issued_by)) between 1 and 160
    )
);

comment on table public.commercial_secret_backend_validation_receipts is
'Append-only validation evidence for passive backend registry operations.';

-- =============================================================================
-- 7. BLOCKED BACKEND PROBE ATTEMPTS
-- =============================================================================

create table public.commercial_secret_backend_probe_attempts (
  id uuid primary key default gen_random_uuid(),
  secret_backend_id uuid not null,
  secret_backend_version_id uuid,
  secret_backend_binding_id uuid,
  attempt_number integer not null,
  attempt_status text not null default 'blocked',

  endpoint_discovery_requested boolean not null default false,
  endpoint_discovery_performed boolean not null default false,
  backend_probe_requested boolean not null default false,
  backend_probe_performed boolean not null default false,
  backend_contact_requested boolean not null default false,
  backend_contact_performed boolean not null default false,
  authentication_requested boolean not null default false,
  authentication_performed boolean not null default false,
  secret_lookup_requested boolean not null default false,
  secret_lookup_performed boolean not null default false,
  secret_material_observed boolean not null default false,
  network_attempted boolean not null default false,

  normalized_error_code text not null default 'SECRET_BACKEND_PROBE_DISABLED',
  retry_class text not null default 'never',
  recorded_by text not null,
  reason text not null,
  attempt_metadata jsonb not null default '{}'::jsonb,
  recorded_at timestamptz not null default clock_timestamp(),

  constraint commercial_secret_backend_probe_backend_fkey
    foreign key (secret_backend_id)
    references public.commercial_secret_backends(id)
    on delete restrict,

  constraint commercial_secret_backend_probe_version_fkey
    foreign key (secret_backend_version_id)
    references public.commercial_secret_backend_versions(id)
    on delete restrict,

  constraint commercial_secret_backend_probe_binding_fkey
    foreign key (secret_backend_binding_id)
    references public.commercial_secret_backend_bindings(id)
    on delete restrict,

  constraint commercial_secret_backend_probe_unique
    unique (secret_backend_id, attempt_number),

  constraint commercial_secret_backend_probe_status_check
    check (
      attempt_number > 0
      and attempt_status in ('blocked','abandoned')
      and retry_class in ('never','manual')
      and length(btrim(recorded_by)) between 1 and 160
      and length(btrim(reason)) between 1 and 500
    ),

  constraint commercial_secret_backend_probe_json_check
    check (
      jsonb_typeof(attempt_metadata) = 'object'
      and not (attempt_metadata ?| array[
        'secret','secret_value','password','private_key','access_token',
        'refresh_token','api_key','client_secret','plaintext','ciphertext',
        'url','uri','endpoint','connection_string','dsn','host','hostname'
      ])
    ),

  constraint commercial_secret_backend_probe_passive_check
    check (
      endpoint_discovery_requested = false
      and endpoint_discovery_performed = false
      and backend_probe_requested = false
      and backend_probe_performed = false
      and backend_contact_requested = false
      and backend_contact_performed = false
      and authentication_requested = false
      and authentication_performed = false
      and secret_lookup_requested = false
      and secret_lookup_performed = false
      and secret_material_observed = false
      and network_attempted = false
    )
);

comment on table public.commercial_secret_backend_probe_attempts is
'Blocked backend probe evidence. Migration 127 cannot discover, contact or authenticate to a backend.';

-- =============================================================================
-- 8. APPEND-ONLY EVENTS
-- =============================================================================

create table public.commercial_secret_backend_events (
  id uuid primary key default gen_random_uuid(),
  event_type text not null,
  registry_policy_id uuid,
  secret_backend_id uuid,
  secret_backend_version_id uuid,
  secret_backend_capability_id uuid,
  secret_backend_binding_id uuid,
  validation_receipt_id uuid,
  probe_attempt_id uuid,
  previous_status text,
  new_status text,
  reason text,
  actor text not null,
  correlation_id uuid not null,
  causation_id uuid,
  payload jsonb not null default '{}'::jsonb,
  occurred_at timestamptz not null default clock_timestamp(),

  constraint commercial_secret_backend_event_policy_fkey
    foreign key (registry_policy_id)
    references public.commercial_secret_backend_registry_policies(id)
    on delete restrict,

  constraint commercial_secret_backend_event_backend_fkey
    foreign key (secret_backend_id)
    references public.commercial_secret_backends(id)
    on delete restrict,

  constraint commercial_secret_backend_event_version_fkey
    foreign key (secret_backend_version_id)
    references public.commercial_secret_backend_versions(id)
    on delete restrict,

  constraint commercial_secret_backend_event_capability_fkey
    foreign key (secret_backend_capability_id)
    references public.commercial_secret_backend_capabilities(id)
    on delete restrict,

  constraint commercial_secret_backend_event_binding_fkey
    foreign key (secret_backend_binding_id)
    references public.commercial_secret_backend_bindings(id)
    on delete restrict,

  constraint commercial_secret_backend_event_receipt_fkey
    foreign key (validation_receipt_id)
    references public.commercial_secret_backend_validation_receipts(id)
    on delete restrict,

  constraint commercial_secret_backend_event_probe_fkey
    foreign key (probe_attempt_id)
    references public.commercial_secret_backend_probe_attempts(id)
    on delete restrict,

  constraint commercial_secret_backend_event_type_check
    check (
      event_type = upper(event_type)
      and event_type ~ '^[A-Z][A-Z0-9_]{2,95}$'
    ),

  constraint commercial_secret_backend_event_json_check
    check (
      length(btrim(actor)) between 1 and 160
      and jsonb_typeof(payload) = 'object'
      and not (payload ?| array[
        'secret','secret_value','password','private_key','access_token',
        'refresh_token','api_key','client_secret','plaintext','ciphertext',
        'url','uri','endpoint','connection_string','dsn','host','hostname'
      ])
    )
);

create index commercial_secret_backend_events_timeline_idx
  on public.commercial_secret_backend_events
  (
    coalesce(secret_backend_id, '00000000-0000-0000-0000-000000000000'::uuid),
    occurred_at,
    id
  );

comment on table public.commercial_secret_backend_events is
'Append-only event stream for secret-backend registry governance.';

-- =============================================================================
-- 9. PROTECTION FUNCTIONS AND TRIGGERS
-- =============================================================================

create or replace function public.protect_commercial_secret_backend_registry_policy()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  raise exception 'COMMERCIAL_SECRET_BACKEND_REGISTRY_POLICY_IMMUTABLE';
end
$$;

create or replace function public.protect_commercial_secret_backend_version()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  raise exception 'COMMERCIAL_SECRET_BACKEND_VERSION_IMMUTABLE';
end
$$;

create or replace function public.protect_commercial_secret_backend_capability()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  raise exception 'COMMERCIAL_SECRET_BACKEND_CAPABILITY_IMMUTABLE';
end
$$;

create or replace function public.protect_commercial_secret_backend_receipt()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  raise exception 'COMMERCIAL_SECRET_BACKEND_RECEIPT_APPEND_ONLY';
end
$$;

create or replace function public.protect_commercial_secret_backend_event()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  raise exception 'COMMERCIAL_SECRET_BACKEND_EVENT_APPEND_ONLY';
end
$$;

create or replace function public.set_commercial_secret_backend_updated_at()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  new.updated_at := clock_timestamp();
  return new;
end
$$;

create trigger commercial_secret_backend_registry_policy_protect
before update or delete on public.commercial_secret_backend_registry_policies
for each row execute function public.protect_commercial_secret_backend_registry_policy();

create trigger commercial_secret_backend_version_protect
before update or delete on public.commercial_secret_backend_versions
for each row execute function public.protect_commercial_secret_backend_version();

create trigger commercial_secret_backend_capability_protect
before update or delete on public.commercial_secret_backend_capabilities
for each row execute function public.protect_commercial_secret_backend_capability();

create trigger commercial_secret_backend_receipt_protect
before update or delete on public.commercial_secret_backend_validation_receipts
for each row execute function public.protect_commercial_secret_backend_receipt();

create trigger commercial_secret_backend_event_protect
before update or delete on public.commercial_secret_backend_events
for each row execute function public.protect_commercial_secret_backend_event();

create trigger commercial_secret_backend_updated_at
before update on public.commercial_secret_backends
for each row execute function public.set_commercial_secret_backend_updated_at();

create trigger commercial_secret_backend_binding_updated_at
before update on public.commercial_secret_backend_bindings
for each row execute function public.set_commercial_secret_backend_updated_at();

-- =============================================================================
-- 10. EVENT AND RECEIPT APPEND
-- =============================================================================

create or replace function public.append_commercial_secret_backend_event(
  p_event_type text,
  p_actor text,
  p_correlation_id uuid,
  p_registry_policy_id uuid default null,
  p_secret_backend_id uuid default null,
  p_secret_backend_version_id uuid default null,
  p_secret_backend_capability_id uuid default null,
  p_secret_backend_binding_id uuid default null,
  p_validation_receipt_id uuid default null,
  p_probe_attempt_id uuid default null,
  p_previous_status text default null,
  p_new_status text default null,
  p_reason text default null,
  p_causation_id uuid default null,
  p_payload jsonb default '{}'::jsonb
)
returns public.commercial_secret_backend_events
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_result public.commercial_secret_backend_events;
begin
  insert into public.commercial_secret_backend_events (
    event_type, registry_policy_id, secret_backend_id,
    secret_backend_version_id, secret_backend_capability_id,
    secret_backend_binding_id, validation_receipt_id, probe_attempt_id,
    previous_status, new_status, reason, actor, correlation_id,
    causation_id, payload
  ) values (
    upper(btrim(p_event_type)), p_registry_policy_id, p_secret_backend_id,
    p_secret_backend_version_id, p_secret_backend_capability_id,
    p_secret_backend_binding_id, p_validation_receipt_id, p_probe_attempt_id,
    p_previous_status, p_new_status, p_reason, btrim(p_actor),
    p_correlation_id, p_causation_id, coalesce(p_payload, '{}'::jsonb)
  )
  returning * into v_result;

  return v_result;
end
$$;

create or replace function public.append_commercial_secret_backend_receipt(
  p_secret_backend_id uuid,
  p_secret_backend_version_id uuid,
  p_secret_backend_binding_id uuid,
  p_receipt_type text,
  p_validation_status text,
  p_normalized_payload jsonb,
  p_issued_by text,
  p_correlation_id uuid,
  p_metadata jsonb default '{}'::jsonb
)
returns public.commercial_secret_backend_validation_receipts
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_hash text;
  v_result public.commercial_secret_backend_validation_receipts;
begin
  v_hash := encode(
    extensions.digest(
      jsonb_build_object(
        'secret_backend_id', p_secret_backend_id,
        'secret_backend_version_id', p_secret_backend_version_id,
        'secret_backend_binding_id', p_secret_backend_binding_id,
        'receipt_type', lower(btrim(p_receipt_type)),
        'validation_status', lower(btrim(p_validation_status)),
        'normalized_payload', coalesce(p_normalized_payload, '{}'::jsonb),
        'correlation_id', p_correlation_id
      )::text,
      'sha256'
    ),
    'hex'
  );

  insert into public.commercial_secret_backend_validation_receipts (
    secret_backend_id, secret_backend_version_id, secret_backend_binding_id,
    receipt_type, validation_status, normalized_payload, content_hash,
    issued_by, correlation_id, metadata
  ) values (
    p_secret_backend_id, p_secret_backend_version_id, p_secret_backend_binding_id,
    lower(btrim(p_receipt_type)), lower(btrim(p_validation_status)),
    coalesce(p_normalized_payload, '{}'::jsonb), v_hash,
    btrim(p_issued_by), p_correlation_id, coalesce(p_metadata, '{}'::jsonb)
  )
  returning * into v_result;

  return v_result;
end
$$;

-- =============================================================================
-- 11. BACKEND REGISTRATION
-- =============================================================================

create or replace function public.register_commercial_secret_backend(
  p_backend_code text,
  p_backend_name text,
  p_backend_type text,
  p_environment text,
  p_ownership_scope text,
  p_provider_scope text,
  p_region_code text,
  p_residency_class text,
  p_reference_namespace text,
  p_reference_fingerprint text,
  p_registered_by text,
  p_correlation_id uuid,
  p_backend_metadata jsonb default '{}'::jsonb
)
returns public.commercial_secret_backends
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_policy public.commercial_secret_backend_registry_policies;
  v_hash text;
  v_result public.commercial_secret_backends;
  v_receipt public.commercial_secret_backend_validation_receipts;
begin
  select * into strict v_policy
  from public.commercial_secret_backend_registry_policies
  where environment = lower(btrim(p_environment))
    and policy_status = 'approved'
  order by policy_version desc
  limit 1;

  if v_policy.backend_registration_enabled is not true then
    raise exception 'COMMERCIAL_SECRET_BACKEND_REGISTRATION_DISABLED';
  end if;

  v_hash := encode(
    extensions.digest(
      jsonb_build_object(
        'backend_code', lower(btrim(p_backend_code)),
        'backend_name', btrim(p_backend_name),
        'backend_type', lower(btrim(p_backend_type)),
        'environment', lower(btrim(p_environment)),
        'ownership_scope', lower(btrim(p_ownership_scope)),
        'provider_scope', p_provider_scope,
        'region_code', p_region_code,
        'residency_class', lower(btrim(p_residency_class)),
        'reference_namespace', lower(btrim(p_reference_namespace)),
        'reference_fingerprint', lower(btrim(p_reference_fingerprint)),
        'backend_metadata', coalesce(p_backend_metadata, '{}'::jsonb)
      )::text,
      'sha256'
    ),
    'hex'
  );

  insert into public.commercial_secret_backends (
    backend_code, backend_name, backend_type, environment, backend_status,
    trust_tier, ownership_scope, provider_scope, region_code, residency_class,
    reference_namespace, reference_fingerprint, registration_hash,
    registered_by, backend_metadata
  ) values (
    lower(btrim(p_backend_code)), btrim(p_backend_name),
    lower(btrim(p_backend_type)), lower(btrim(p_environment)), 'draft',
    'registered', lower(btrim(p_ownership_scope)), nullif(btrim(p_provider_scope),''),
    nullif(upper(btrim(p_region_code)),''),
    lower(btrim(p_residency_class)), lower(btrim(p_reference_namespace)),
    lower(btrim(p_reference_fingerprint)), v_hash,
    btrim(p_registered_by), coalesce(p_backend_metadata, '{}'::jsonb)
  )
  returning * into v_result;

  v_receipt := public.append_commercial_secret_backend_receipt(
    v_result.id, null, null, 'backend_registered', 'accepted',
    jsonb_build_object(
      'backend_code', v_result.backend_code,
      'backend_type', v_result.backend_type,
      'environment', v_result.environment,
      'reference_fingerprint', v_result.reference_fingerprint
    ),
    p_registered_by, p_correlation_id
  );

  perform public.append_commercial_secret_backend_event(
    'SECRET_BACKEND_REGISTERED', p_registered_by, p_correlation_id,
    v_policy.id, v_result.id, null, null, null, v_receipt.id, null,
    null, 'draft', 'Passive secret backend registered', null,
    jsonb_build_object('registration_hash', v_hash)
  );

  return v_result;
end
$$;

-- =============================================================================
-- 12. VERSION AND CAPABILITY REGISTRATION
-- =============================================================================

create or replace function public.register_commercial_secret_backend_version(
  p_secret_backend_id uuid,
  p_version_number integer,
  p_contract_name text,
  p_contract_version text,
  p_contract_hash text,
  p_reference_schema_hash text,
  p_supports_versioned_references boolean,
  p_supports_rotation_metadata boolean,
  p_supports_expiry_metadata boolean,
  p_supports_scope_metadata boolean,
  p_registered_by text,
  p_correlation_id uuid,
  p_version_metadata jsonb default '{}'::jsonb
)
returns public.commercial_secret_backend_versions
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_backend public.commercial_secret_backends;
  v_policy public.commercial_secret_backend_registry_policies;
  v_count bigint;
  v_result public.commercial_secret_backend_versions;
  v_receipt public.commercial_secret_backend_validation_receipts;
begin
  select * into strict v_backend
  from public.commercial_secret_backends
  where id = p_secret_backend_id;

  select * into strict v_policy
  from public.commercial_secret_backend_registry_policies
  where environment = v_backend.environment
    and policy_status = 'approved'
  order by policy_version desc
  limit 1;

  if v_policy.version_registration_enabled is not true then
    raise exception 'COMMERCIAL_SECRET_BACKEND_VERSION_REGISTRATION_DISABLED';
  end if;

  select count(*) into v_count
  from public.commercial_secret_backend_versions
  where secret_backend_id = v_backend.id;

  if v_count >= v_policy.maximum_versions_per_backend then
    raise exception 'COMMERCIAL_SECRET_BACKEND_VERSION_LIMIT_REACHED';
  end if;

  insert into public.commercial_secret_backend_versions (
    secret_backend_id, version_number, version_status, contract_name,
    contract_version, contract_hash, reference_schema_hash,
    supports_reference_validation, supports_versioned_references,
    supports_rotation_metadata, supports_expiry_metadata,
    supports_scope_metadata, registered_by, version_metadata
  ) values (
    v_backend.id, p_version_number, 'draft', btrim(p_contract_name),
    btrim(p_contract_version), lower(btrim(p_contract_hash)),
    lower(btrim(p_reference_schema_hash)), true,
    coalesce(p_supports_versioned_references,false),
    coalesce(p_supports_rotation_metadata,false),
    coalesce(p_supports_expiry_metadata,false),
    coalesce(p_supports_scope_metadata,false),
    btrim(p_registered_by), coalesce(p_version_metadata, '{}'::jsonb)
  )
  returning * into v_result;

  v_receipt := public.append_commercial_secret_backend_receipt(
    v_backend.id, v_result.id, null, 'version_registered', 'accepted',
    jsonb_build_object(
      'version_number', v_result.version_number,
      'contract_hash', v_result.contract_hash,
      'reference_schema_hash', v_result.reference_schema_hash
    ),
    p_registered_by, p_correlation_id
  );

  perform public.append_commercial_secret_backend_event(
    'SECRET_BACKEND_VERSION_REGISTERED', p_registered_by, p_correlation_id,
    v_policy.id, v_backend.id, v_result.id, null, null, v_receipt.id, null,
    null, 'draft', 'Passive backend contract version registered', null,
    '{}'::jsonb
  );

  return v_result;
end
$$;

create or replace function public.register_commercial_secret_backend_capability(
  p_secret_backend_version_id uuid,
  p_capability_code text,
  p_capability_class text,
  p_declared_by text,
  p_correlation_id uuid,
  p_capability_metadata jsonb default '{}'::jsonb
)
returns public.commercial_secret_backend_capabilities
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_version public.commercial_secret_backend_versions;
  v_backend public.commercial_secret_backends;
  v_policy public.commercial_secret_backend_registry_policies;
  v_count bigint;
  v_result public.commercial_secret_backend_capabilities;
begin
  select * into strict v_version
  from public.commercial_secret_backend_versions
  where id = p_secret_backend_version_id;

  select * into strict v_backend
  from public.commercial_secret_backends
  where id = v_version.secret_backend_id;

  select * into strict v_policy
  from public.commercial_secret_backend_registry_policies
  where environment = v_backend.environment
    and policy_status = 'approved'
  order by policy_version desc
  limit 1;

  if v_policy.capability_governance_enabled is not true then
    raise exception 'COMMERCIAL_SECRET_BACKEND_CAPABILITY_GOVERNANCE_DISABLED';
  end if;

  select count(*) into v_count
  from public.commercial_secret_backend_capabilities
  where secret_backend_version_id = v_version.id;

  if v_count >= v_policy.maximum_capabilities_per_version then
    raise exception 'COMMERCIAL_SECRET_BACKEND_CAPABILITY_LIMIT_REACHED';
  end if;

  insert into public.commercial_secret_backend_capabilities (
    secret_backend_version_id, capability_code, capability_class,
    capability_status, declared_by, capability_metadata
  ) values (
    v_version.id, lower(btrim(p_capability_code)),
    lower(btrim(p_capability_class)), 'declared',
    btrim(p_declared_by), coalesce(p_capability_metadata, '{}'::jsonb)
  )
  returning * into v_result;

  perform public.append_commercial_secret_backend_event(
    'SECRET_BACKEND_CAPABILITY_DECLARED', p_declared_by, p_correlation_id,
    v_policy.id, v_backend.id, v_version.id, v_result.id, null, null, null,
    null, 'declared', 'Passive backend capability declared', null,
    jsonb_build_object(
      'capability_code', v_result.capability_code,
      'capability_class', v_result.capability_class
    )
  );

  return v_result;
end
$$;

-- =============================================================================
-- 13. PASSIVE VERSION VALIDATION
-- =============================================================================

create or replace function public.validate_commercial_secret_backend_version(
  p_secret_backend_version_id uuid,
  p_validated_by text,
  p_correlation_id uuid
)
returns public.commercial_secret_backend_versions
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_version public.commercial_secret_backend_versions;
  v_backend public.commercial_secret_backends;
  v_policy public.commercial_secret_backend_registry_policies;
  v_capability_count bigint;
  v_receipt public.commercial_secret_backend_validation_receipts;
begin
  select * into strict v_version
  from public.commercial_secret_backend_versions
  where id = p_secret_backend_version_id;

  select * into strict v_backend
  from public.commercial_secret_backends
  where id = v_version.secret_backend_id
  for update;

  select * into strict v_policy
  from public.commercial_secret_backend_registry_policies
  where environment = v_backend.environment
    and policy_status = 'approved'
  order by policy_version desc
  limit 1;

  if v_policy.validation_enabled is not true then
    raise exception 'COMMERCIAL_SECRET_BACKEND_VALIDATION_DISABLED';
  end if;

  if v_version.version_status <> 'draft' then
    return v_version;
  end if;

  select count(*) into v_capability_count
  from public.commercial_secret_backend_capabilities
  where secret_backend_version_id = v_version.id;

  if v_capability_count < 1 then
    raise exception 'COMMERCIAL_SECRET_BACKEND_CAPABILITY_REQUIRED';
  end if;

  if exists (
    select 1
    from public.commercial_secret_backend_capabilities
    where secret_backend_version_id = v_version.id
      and (
        passive_only is not true
        or requires_backend_contact
        or requires_authentication
        or requires_secret_material
        or requires_network
      )
  ) then
    raise exception 'COMMERCIAL_SECRET_BACKEND_UNSAFE_CAPABILITY';
  end if;

  -- Temporarily bypass the immutable-version trigger only inside this trusted
  -- validation function. The configuration is transaction-local.
  perform set_config('fantagol.allow_secret_backend_version_transition','true',true);

  update public.commercial_secret_backend_versions
  set version_status = 'validated',
      validated_by = btrim(p_validated_by),
      validated_at = clock_timestamp()
  where id = v_version.id
  returning * into v_version;

  update public.commercial_secret_backend_capabilities
  set capability_status = 'validated',
      validated_by = btrim(p_validated_by),
      validated_at = clock_timestamp()
  where secret_backend_version_id = v_version.id;

  perform set_config('fantagol.allow_secret_backend_version_transition','false',true);

  update public.commercial_secret_backends
  set backend_status = 'validated',
      trust_tier = 'validated',
      active_version_id = v_version.id
  where id = v_backend.id
  returning * into v_backend;

  v_receipt := public.append_commercial_secret_backend_receipt(
    v_backend.id, v_version.id, null, 'version_validated', 'validated',
    jsonb_build_object(
      'capability_count', v_capability_count,
      'backend_contact_enabled', false,
      'secret_lookup_enabled', false,
      'network_access_enabled', false
    ),
    p_validated_by, p_correlation_id
  );

  perform public.append_commercial_secret_backend_event(
    'SECRET_BACKEND_VERSION_VALIDATED', p_validated_by, p_correlation_id,
    v_policy.id, v_backend.id, v_version.id, null, null, v_receipt.id, null,
    'draft', 'validated', 'Passive backend version validated', null,
    jsonb_build_object('capability_count', v_capability_count)
  );

  return v_version;
end
$$;

-- Replace version/capability protection functions to allow only trusted
-- validation transitions through transaction-local flags.
create or replace function public.protect_commercial_secret_backend_version()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if current_setting(
    'fantagol.allow_secret_backend_version_transition',
    true
  ) = 'true'
  and tg_op = 'UPDATE'
  and old.id = new.id
  and old.secret_backend_id = new.secret_backend_id
  and old.version_number = new.version_number
  and old.contract_name = new.contract_name
  and old.contract_version = new.contract_version
  and old.contract_hash = new.contract_hash
  and old.reference_schema_hash = new.reference_schema_hash
  and old.registered_by = new.registered_by
  and old.version_metadata = new.version_metadata
  and old.created_at = new.created_at then
    return new;
  end if;

  raise exception 'COMMERCIAL_SECRET_BACKEND_VERSION_IMMUTABLE';
end
$$;

create or replace function public.protect_commercial_secret_backend_capability()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if current_setting(
    'fantagol.allow_secret_backend_version_transition',
    true
  ) = 'true'
  and tg_op = 'UPDATE'
  and old.id = new.id
  and old.secret_backend_version_id = new.secret_backend_version_id
  and old.capability_code = new.capability_code
  and old.capability_class = new.capability_class
  and old.passive_only = new.passive_only
  and old.requires_backend_contact = new.requires_backend_contact
  and old.requires_authentication = new.requires_authentication
  and old.requires_secret_material = new.requires_secret_material
  and old.requires_network = new.requires_network
  and old.declared_by = new.declared_by
  and old.capability_metadata = new.capability_metadata
  and old.created_at = new.created_at then
    return new;
  end if;

  raise exception 'COMMERCIAL_SECRET_BACKEND_CAPABILITY_IMMUTABLE';
end
$$;

-- =============================================================================
-- 14. PASSIVE BINDING REGISTRATION AND VALIDATION
-- =============================================================================

create or replace function public.register_commercial_secret_backend_binding(
  p_binding_key text,
  p_secret_backend_id uuid,
  p_secret_backend_version_id uuid,
  p_credential_binding_id uuid,
  p_orchestrator_policy_id uuid,
  p_binding_scope text,
  p_priority integer,
  p_reference_namespace text,
  p_bound_by text,
  p_correlation_id uuid,
  p_binding_metadata jsonb default '{}'::jsonb
)
returns public.commercial_secret_backend_bindings
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_backend public.commercial_secret_backends;
  v_version public.commercial_secret_backend_versions;
  v_policy public.commercial_secret_backend_registry_policies;
  v_hash text;
  v_result public.commercial_secret_backend_bindings;
  v_receipt public.commercial_secret_backend_validation_receipts;
begin
  select * into strict v_backend
  from public.commercial_secret_backends
  where id = p_secret_backend_id;

  select * into strict v_version
  from public.commercial_secret_backend_versions
  where id = p_secret_backend_version_id
    and secret_backend_id = v_backend.id;

  select * into strict v_policy
  from public.commercial_secret_backend_registry_policies
  where environment = v_backend.environment
    and policy_status = 'approved'
  order by policy_version desc
  limit 1;

  if v_policy.passive_binding_enabled is not true then
    raise exception 'COMMERCIAL_SECRET_BACKEND_BINDING_DISABLED';
  end if;

  if v_backend.backend_status <> 'validated'
     or v_version.version_status <> 'validated' then
    raise exception 'COMMERCIAL_SECRET_BACKEND_NOT_VALIDATED';
  end if;

  if p_credential_binding_id is not null
     and not exists (
       select 1
       from public.commercial_provider_credential_bindings
       where id = p_credential_binding_id
     ) then
    raise exception 'COMMERCIAL_SECRET_BACKEND_CREDENTIAL_BINDING_NOT_FOUND';
  end if;

  if not exists (
    select 1
    from public.commercial_secret_resolution_policies
    where id = p_orchestrator_policy_id
      and policy_status = 'approved'
  ) then
    raise exception 'COMMERCIAL_SECRET_BACKEND_ORCHESTRATOR_POLICY_NOT_APPROVED';
  end if;

  v_hash := encode(
    extensions.digest(
      jsonb_build_object(
        'binding_key', lower(btrim(p_binding_key)),
        'secret_backend_id', v_backend.id,
        'secret_backend_version_id', v_version.id,
        'credential_binding_id', p_credential_binding_id,
        'orchestrator_policy_id', p_orchestrator_policy_id,
        'binding_scope', lower(btrim(p_binding_scope)),
        'priority', p_priority,
        'reference_namespace', lower(btrim(p_reference_namespace)),
        'binding_metadata', coalesce(p_binding_metadata, '{}'::jsonb)
      )::text,
      'sha256'
    ),
    'hex'
  );

  insert into public.commercial_secret_backend_bindings (
    binding_key, secret_backend_id, secret_backend_version_id,
    credential_binding_id, orchestrator_policy_id, binding_status,
    binding_scope, priority, reference_namespace, binding_hash,
    bound_by, binding_metadata
  ) values (
    lower(btrim(p_binding_key)), v_backend.id, v_version.id,
    p_credential_binding_id, p_orchestrator_policy_id, 'draft',
    lower(btrim(p_binding_scope)), p_priority,
    lower(btrim(p_reference_namespace)), v_hash,
    btrim(p_bound_by), coalesce(p_binding_metadata, '{}'::jsonb)
  )
  returning * into v_result;

  v_receipt := public.append_commercial_secret_backend_receipt(
    v_backend.id, v_version.id, v_result.id,
    'binding_registered', 'accepted',
    jsonb_build_object(
      'binding_scope', v_result.binding_scope,
      'reference_namespace', v_result.reference_namespace,
      'binding_hash', v_result.binding_hash
    ),
    p_bound_by, p_correlation_id
  );

  perform public.append_commercial_secret_backend_event(
    'SECRET_BACKEND_BINDING_REGISTERED', p_bound_by, p_correlation_id,
    v_policy.id, v_backend.id, v_version.id, null, v_result.id,
    v_receipt.id, null, null, 'draft',
    'Passive secret-backend binding registered', null, '{}'::jsonb
  );

  return v_result;
end
$$;

create or replace function public.validate_commercial_secret_backend_binding(
  p_secret_backend_binding_id uuid,
  p_validated_by text,
  p_correlation_id uuid
)
returns public.commercial_secret_backend_bindings
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_binding public.commercial_secret_backend_bindings;
  v_backend public.commercial_secret_backends;
  v_version public.commercial_secret_backend_versions;
  v_policy public.commercial_secret_backend_registry_policies;
  v_receipt public.commercial_secret_backend_validation_receipts;
begin
  select * into strict v_binding
  from public.commercial_secret_backend_bindings
  where id = p_secret_backend_binding_id
  for update;

  select * into strict v_backend
  from public.commercial_secret_backends
  where id = v_binding.secret_backend_id;

  select * into strict v_version
  from public.commercial_secret_backend_versions
  where id = v_binding.secret_backend_version_id;

  select * into strict v_policy
  from public.commercial_secret_backend_registry_policies
  where environment = v_backend.environment
    and policy_status = 'approved'
  order by policy_version desc
  limit 1;

  if v_binding.binding_status <> 'draft' then
    return v_binding;
  end if;

  if v_backend.backend_status <> 'validated'
     or v_version.version_status <> 'validated'
     or v_backend.active_version_id <> v_version.id
     or v_binding.reference_namespace <> v_backend.reference_namespace then
    raise exception 'COMMERCIAL_SECRET_BACKEND_BINDING_VALIDATION_FAILED';
  end if;

  if v_binding.backend_contact_allowed
     or v_binding.authentication_allowed
     or v_binding.secret_lookup_allowed
     or v_binding.secret_resolution_allowed
     or v_binding.decryption_allowed
     or v_binding.material_loading_allowed
     or v_binding.delivery_allowed
     or v_binding.network_access_allowed then
    raise exception 'COMMERCIAL_SECRET_BACKEND_BINDING_UNSAFE';
  end if;

  update public.commercial_secret_backend_bindings
  set binding_status = 'validated',
      validated_by = btrim(p_validated_by),
      validated_at = clock_timestamp()
  where id = v_binding.id
  returning * into v_binding;

  v_receipt := public.append_commercial_secret_backend_receipt(
    v_backend.id, v_version.id, v_binding.id,
    'binding_validated', 'validated',
    jsonb_build_object(
      'binding_status', v_binding.binding_status,
      'backend_contact_allowed', false,
      'secret_resolution_allowed', false,
      'network_access_allowed', false
    ),
    p_validated_by, p_correlation_id
  );

  perform public.append_commercial_secret_backend_event(
    'SECRET_BACKEND_BINDING_VALIDATED', p_validated_by, p_correlation_id,
    v_policy.id, v_backend.id, v_version.id, null, v_binding.id,
    v_receipt.id, null, 'draft', 'validated',
    'Passive secret-backend binding validated', null, '{}'::jsonb
  );

  return v_binding;
end
$$;

-- =============================================================================
-- 15. BLOCKED PROBE RECORDING
-- =============================================================================

create or replace function public.record_blocked_secret_backend_probe(
  p_secret_backend_id uuid,
  p_secret_backend_version_id uuid,
  p_secret_backend_binding_id uuid,
  p_recorded_by text,
  p_reason text,
  p_correlation_id uuid
)
returns public.commercial_secret_backend_probe_attempts
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_backend public.commercial_secret_backends;
  v_policy public.commercial_secret_backend_registry_policies;
  v_attempt_number integer;
  v_attempt public.commercial_secret_backend_probe_attempts;
  v_receipt public.commercial_secret_backend_validation_receipts;
begin
  select * into strict v_backend
  from public.commercial_secret_backends
  where id = p_secret_backend_id;

  select * into strict v_policy
  from public.commercial_secret_backend_registry_policies
  where environment = v_backend.environment
    and policy_status = 'approved'
  order by policy_version desc
  limit 1;

  if v_policy.blocked_probe_recording_enabled is not true then
    raise exception 'COMMERCIAL_SECRET_BACKEND_PROBE_RECORDING_DISABLED';
  end if;

  if p_secret_backend_version_id is not null
     and not exists (
       select 1
       from public.commercial_secret_backend_versions
       where id = p_secret_backend_version_id
         and secret_backend_id = v_backend.id
     ) then
    raise exception 'COMMERCIAL_SECRET_BACKEND_VERSION_MISMATCH';
  end if;

  if p_secret_backend_binding_id is not null
     and not exists (
       select 1
       from public.commercial_secret_backend_bindings
       where id = p_secret_backend_binding_id
         and secret_backend_id = v_backend.id
     ) then
    raise exception 'COMMERCIAL_SECRET_BACKEND_BINDING_MISMATCH';
  end if;

  select coalesce(max(attempt_number),0) + 1
  into v_attempt_number
  from public.commercial_secret_backend_probe_attempts
  where secret_backend_id = v_backend.id;

  insert into public.commercial_secret_backend_probe_attempts (
    secret_backend_id, secret_backend_version_id, secret_backend_binding_id,
    attempt_number, attempt_status, recorded_by, reason, attempt_metadata
  ) values (
    v_backend.id, p_secret_backend_version_id, p_secret_backend_binding_id,
    v_attempt_number, 'blocked', btrim(p_recorded_by), btrim(p_reason),
    jsonb_build_object('passive', true)
  )
  returning * into v_attempt;

  v_receipt := public.append_commercial_secret_backend_receipt(
    v_backend.id, p_secret_backend_version_id, p_secret_backend_binding_id,
    'probe_blocked', 'blocked',
    jsonb_build_object(
      'reason', p_reason,
      'endpoint_discovery_performed', false,
      'backend_probe_performed', false,
      'backend_contact_performed', false,
      'authentication_performed', false,
      'secret_lookup_performed', false,
      'secret_material_observed', false,
      'network_attempted', false
    ),
    p_recorded_by, p_correlation_id
  );

  perform public.append_commercial_secret_backend_event(
    'SECRET_BACKEND_PROBE_BLOCKED', p_recorded_by, p_correlation_id,
    v_policy.id, v_backend.id, p_secret_backend_version_id, null,
    p_secret_backend_binding_id, v_receipt.id, v_attempt.id,
    null, 'blocked', p_reason, null,
    jsonb_build_object('attempt_number', v_attempt.attempt_number)
  );

  return v_attempt;
end
$$;

-- =============================================================================
-- 16. READ MODEL
-- =============================================================================

create or replace view public.commercial_secret_backend_registry_read_model as
select
  b.id as secret_backend_id,
  b.backend_code,
  b.backend_name,
  b.backend_type,
  b.environment,
  b.backend_status,
  b.trust_tier,
  b.ownership_scope,
  b.provider_scope,
  b.region_code,
  b.residency_class,
  b.reference_namespace,
  b.reference_fingerprint,
  b.registration_hash,
  b.active_version_id,
  v.version_number as active_version_number,
  v.version_status as active_version_status,
  v.contract_name,
  v.contract_version,
  v.contract_hash,
  coalesce(c.capability_count,0) as capability_count,
  coalesce(x.validated_capability_count,0) as validated_capability_count,
  coalesce(bind.binding_count,0) as binding_count,
  coalesce(bind.validated_binding_count,0) as validated_binding_count,
  coalesce(r.receipt_count,0) as receipt_count,
  coalesce(p.probe_attempt_count,0) as probe_attempt_count,
  coalesce(e.event_count,0) as event_count,
  pol.endpoint_discovery_enabled,
  pol.backend_probe_enabled,
  pol.backend_contact_enabled,
  pol.backend_authentication_enabled,
  pol.secret_lookup_enabled,
  pol.secret_resolution_enabled,
  pol.secret_decryption_enabled,
  pol.credential_material_loading_enabled,
  pol.credential_delivery_enabled,
  pol.network_access_enabled,
  b.created_at,
  b.updated_at
from public.commercial_secret_backends b
join public.commercial_secret_backend_registry_policies pol
  on pol.environment = b.environment
 and pol.policy_status = 'approved'
left join public.commercial_secret_backend_versions v
  on v.id = b.active_version_id
left join lateral (
  select count(*)::bigint as capability_count
  from public.commercial_secret_backend_capabilities q
  where q.secret_backend_version_id = v.id
) c on true
left join lateral (
  select count(*)::bigint as validated_capability_count
  from public.commercial_secret_backend_capabilities q
  where q.secret_backend_version_id = v.id
    and q.capability_status = 'validated'
) x on true
left join lateral (
  select
    count(*)::bigint as binding_count,
    count(*) filter (where q.binding_status='validated')::bigint
      as validated_binding_count
  from public.commercial_secret_backend_bindings q
  where q.secret_backend_id = b.id
) bind on true
left join lateral (
  select count(*)::bigint as receipt_count
  from public.commercial_secret_backend_validation_receipts q
  where q.secret_backend_id = b.id
) r on true
left join lateral (
  select count(*)::bigint as probe_attempt_count
  from public.commercial_secret_backend_probe_attempts q
  where q.secret_backend_id = b.id
) p on true
left join lateral (
  select count(*)::bigint as event_count
  from public.commercial_secret_backend_events q
  where q.secret_backend_id = b.id
) e on true;

comment on view public.commercial_secret_backend_registry_read_model is
'Operational read model for passive commercial provider secret-backend governance.';

-- =============================================================================
-- 17. FOUNDATION POLICY AND INITIAL EVENT
-- =============================================================================

insert into public.commercial_secret_backend_registry_policies (
  policy_code,
  environment,
  policy_status,
  policy_version,
  created_by,
  approved_by,
  approved_at,
  policy_metadata
) values (
  'commercial:provider_secret_backend_registry:v1',
  'production',
  'approved',
  1,
  'MIGRATION_127',
  'MIGRATION_127',
  clock_timestamp(),
  jsonb_build_object(
    'foundation', true,
    'mode', 'passive_registry',
    'opaque_references_only', true
  )
);

select public.append_commercial_secret_backend_event(
  'SECRET_BACKEND_REGISTRY_INITIALIZED',
  'MIGRATION_127',
  gen_random_uuid(),
  (
    select id
    from public.commercial_secret_backend_registry_policies
    where policy_code = 'commercial:provider_secret_backend_registry:v1'
      and environment = 'production'
  ),
  null, null, null, null, null, null, null, 'approved',
  'Provider secret-backend registry initialized in passive mode',
  null,
  jsonb_build_object(
    'endpoint_discovery_enabled', false,
    'backend_probe_enabled', false,
    'backend_contact_enabled', false,
    'backend_authentication_enabled', false,
    'secret_lookup_enabled', false,
    'secret_resolution_enabled', false,
    'secret_decryption_enabled', false,
    'credential_material_loading_enabled', false,
    'credential_delivery_enabled', false,
    'network_access_enabled', false
  )
);

-- =============================================================================
-- 18. RLS AND PRIVILEGES
-- =============================================================================

alter table public.commercial_secret_backend_registry_policies enable row level security;
alter table public.commercial_secret_backends enable row level security;
alter table public.commercial_secret_backend_versions enable row level security;
alter table public.commercial_secret_backend_capabilities enable row level security;
alter table public.commercial_secret_backend_bindings enable row level security;
alter table public.commercial_secret_backend_validation_receipts enable row level security;
alter table public.commercial_secret_backend_probe_attempts enable row level security;
alter table public.commercial_secret_backend_events enable row level security;

revoke all on table public.commercial_secret_backend_registry_policies from public, anon, authenticated;
revoke all on table public.commercial_secret_backends from public, anon, authenticated;
revoke all on table public.commercial_secret_backend_versions from public, anon, authenticated;
revoke all on table public.commercial_secret_backend_capabilities from public, anon, authenticated;
revoke all on table public.commercial_secret_backend_bindings from public, anon, authenticated;
revoke all on table public.commercial_secret_backend_validation_receipts from public, anon, authenticated;
revoke all on table public.commercial_secret_backend_probe_attempts from public, anon, authenticated;
revoke all on table public.commercial_secret_backend_events from public, anon, authenticated;
revoke all on table public.commercial_secret_backend_registry_read_model from public, anon, authenticated;

grant select, insert, update, delete on table public.commercial_secret_backend_registry_policies to service_role;
grant select, insert, update, delete on table public.commercial_secret_backends to service_role;
grant select, insert, update, delete on table public.commercial_secret_backend_versions to service_role;
grant select, insert, update, delete on table public.commercial_secret_backend_capabilities to service_role;
grant select, insert, update, delete on table public.commercial_secret_backend_bindings to service_role;
grant select, insert, update, delete on table public.commercial_secret_backend_validation_receipts to service_role;
grant select, insert, update, delete on table public.commercial_secret_backend_probe_attempts to service_role;
grant select, insert, update, delete on table public.commercial_secret_backend_events to service_role;
grant select on table public.commercial_secret_backend_registry_read_model to service_role;

revoke all on function public.protect_commercial_secret_backend_registry_policy()
  from public, anon, authenticated;
revoke all on function public.protect_commercial_secret_backend_version()
  from public, anon, authenticated;
revoke all on function public.protect_commercial_secret_backend_capability()
  from public, anon, authenticated;
revoke all on function public.protect_commercial_secret_backend_receipt()
  from public, anon, authenticated;
revoke all on function public.protect_commercial_secret_backend_event()
  from public, anon, authenticated;
revoke all on function public.set_commercial_secret_backend_updated_at()
  from public, anon, authenticated;

revoke all on function public.append_commercial_secret_backend_event(
  text,text,uuid,uuid,uuid,uuid,uuid,uuid,uuid,uuid,text,text,text,uuid,jsonb
) from public, anon, authenticated;
revoke all on function public.append_commercial_secret_backend_receipt(
  uuid,uuid,uuid,text,text,jsonb,text,uuid,jsonb
) from public, anon, authenticated;
revoke all on function public.register_commercial_secret_backend(
  text,text,text,text,text,text,text,text,text,text,text,uuid,jsonb
) from public, anon, authenticated;
revoke all on function public.register_commercial_secret_backend_version(
  uuid,integer,text,text,text,text,boolean,boolean,boolean,boolean,text,uuid,jsonb
) from public, anon, authenticated;
revoke all on function public.register_commercial_secret_backend_capability(
  uuid,text,text,text,uuid,jsonb
) from public, anon, authenticated;
revoke all on function public.validate_commercial_secret_backend_version(
  uuid,text,uuid
) from public, anon, authenticated;
revoke all on function public.register_commercial_secret_backend_binding(
  text,uuid,uuid,uuid,uuid,text,integer,text,text,uuid,jsonb
) from public, anon, authenticated;
revoke all on function public.validate_commercial_secret_backend_binding(
  uuid,text,uuid
) from public, anon, authenticated;
revoke all on function public.record_blocked_secret_backend_probe(
  uuid,uuid,uuid,text,text,uuid
) from public, anon, authenticated;

grant execute on function public.append_commercial_secret_backend_event(
  text,text,uuid,uuid,uuid,uuid,uuid,uuid,uuid,uuid,text,text,text,uuid,jsonb
) to service_role;
grant execute on function public.append_commercial_secret_backend_receipt(
  uuid,uuid,uuid,text,text,jsonb,text,uuid,jsonb
) to service_role;
grant execute on function public.register_commercial_secret_backend(
  text,text,text,text,text,text,text,text,text,text,text,uuid,jsonb
) to service_role;
grant execute on function public.register_commercial_secret_backend_version(
  uuid,integer,text,text,text,text,boolean,boolean,boolean,boolean,text,uuid,jsonb
) to service_role;
grant execute on function public.register_commercial_secret_backend_capability(
  uuid,text,text,text,uuid,jsonb
) to service_role;
grant execute on function public.validate_commercial_secret_backend_version(
  uuid,text,uuid
) to service_role;
grant execute on function public.register_commercial_secret_backend_binding(
  text,uuid,uuid,uuid,uuid,text,integer,text,text,uuid,jsonb
) to service_role;
grant execute on function public.validate_commercial_secret_backend_binding(
  uuid,text,uuid
) to service_role;
grant execute on function public.record_blocked_secret_backend_probe(
  uuid,uuid,uuid,text,text,uuid
) to service_role;

-- =============================================================================
-- 19. FOUNDATION CERTIFICATION
-- =============================================================================

do $$
declare
  v_policy public.commercial_secret_backend_registry_policies;
  v_policy_count bigint;
  v_backend_count bigint;
  v_version_count bigint;
  v_capability_count bigint;
  v_binding_count bigint;
  v_receipt_count bigint;
  v_probe_count bigint;
  v_event_count bigint;
begin
  select * into strict v_policy
  from public.commercial_secret_backend_registry_policies
  where policy_code = 'commercial:provider_secret_backend_registry:v1'
    and environment = 'production';

  select count(*) into v_policy_count
  from public.commercial_secret_backend_registry_policies;

  select count(*) into v_backend_count
  from public.commercial_secret_backends;

  select count(*) into v_version_count
  from public.commercial_secret_backend_versions;

  select count(*) into v_capability_count
  from public.commercial_secret_backend_capabilities;

  select count(*) into v_binding_count
  from public.commercial_secret_backend_bindings;

  select count(*) into v_receipt_count
  from public.commercial_secret_backend_validation_receipts;

  select count(*) into v_probe_count
  from public.commercial_secret_backend_probe_attempts;

  select count(*) into v_event_count
  from public.commercial_secret_backend_events;

  if v_policy_count <> 1
     or v_backend_count <> 0
     or v_version_count <> 0
     or v_capability_count <> 0
     or v_binding_count <> 0
     or v_receipt_count <> 0
     or v_probe_count <> 0
     or v_event_count <> 1 then
    raise exception
      'MIGRATION_127_COUNT_ASSERTION_FAILED policy=%, backend=%, version=%, capability=%, binding=%, receipt=%, probe=%, event=%',
      v_policy_count, v_backend_count, v_version_count, v_capability_count,
      v_binding_count, v_receipt_count, v_probe_count, v_event_count;
  end if;

  if v_policy.backend_registration_enabled is not true
     or v_policy.version_registration_enabled is not true
     or v_policy.capability_governance_enabled is not true
     or v_policy.validation_enabled is not true
     or v_policy.passive_binding_enabled is not true
     or v_policy.blocked_probe_recording_enabled is not true then
    raise exception 'MIGRATION_127_PASSIVE_CAPABILITY_ASSERTION_FAILED';
  end if;

  if v_policy.endpoint_discovery_enabled
     or v_policy.backend_probe_enabled
     or v_policy.backend_contact_enabled
     or v_policy.backend_authentication_enabled
     or v_policy.secret_lookup_enabled
     or v_policy.secret_resolution_enabled
     or v_policy.secret_decryption_enabled
     or v_policy.credential_material_loading_enabled
     or v_policy.credential_delivery_enabled
     or v_policy.network_access_enabled then
    raise exception 'MIGRATION_127_SAFETY_POSTURE_ASSERTION_FAILED';
  end if;

  if to_regprocedure(
    'public.record_blocked_secret_backend_probe(uuid,uuid,uuid,text,text,uuid)'
  ) is null then
    raise exception 'MIGRATION_127_CANONICAL_FUNCTION_ASSERTION_FAILED';
  end if;

  raise notice
    'MIGRATION_127_CERTIFIED policy_count=%, backend_count=%, version_count=%, capability_count=%, binding_count=%, receipt_count=%, probe_attempt_count=%, event_count=%, backend_registration_enabled=%, version_registration_enabled=%, capability_governance_enabled=%, validation_enabled=%, passive_binding_enabled=%, blocked_probe_recording_enabled=%, endpoint_discovery_enabled=%, backend_probe_enabled=%, backend_contact_enabled=%, backend_authentication_enabled=%, secret_lookup_enabled=%, secret_resolution_enabled=%, secret_decryption_enabled=%, credential_material_loading_enabled=%, credential_delivery_enabled=%, network_access_enabled=%, opaque_references_only=true, plaintext_storage_forbidden=true',
    v_policy_count, v_backend_count, v_version_count, v_capability_count,
    v_binding_count, v_receipt_count, v_probe_count, v_event_count,
    v_policy.backend_registration_enabled,
    v_policy.version_registration_enabled,
    v_policy.capability_governance_enabled,
    v_policy.validation_enabled,
    v_policy.passive_binding_enabled,
    v_policy.blocked_probe_recording_enabled,
    v_policy.endpoint_discovery_enabled,
    v_policy.backend_probe_enabled,
    v_policy.backend_contact_enabled,
    v_policy.backend_authentication_enabled,
    v_policy.secret_lookup_enabled,
    v_policy.secret_resolution_enabled,
    v_policy.secret_decryption_enabled,
    v_policy.credential_material_loading_enabled,
    v_policy.credential_delivery_enabled,
    v_policy.network_access_enabled;
end
$$;

commit;
