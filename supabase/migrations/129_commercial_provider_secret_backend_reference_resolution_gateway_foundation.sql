-- =============================================================================
-- FANTAGOL
-- Migration: 129_commercial_provider_secret_backend_reference_resolution_gateway_foundation.sql
-- Milestone: Commercial Platform - Secret Backend Reference Resolution Gateway
--
-- Purpose:
--   Introduce a deterministic, passive gateway that resolves only governance
--   metadata for an opaque secret reference:
--
--     validated registry policy
--     validated backend binding
--     validated backend and active contract version
--     approved orchestrator policy
--     opaque reference namespace
--     passive capability availability
--     deterministic route decision and route manifest
--
-- Safety posture:
--   The gateway cannot discover endpoints, probe or contact a backend,
--   authenticate, look up or resolve a secret, decrypt or load material,
--   deliver credentials, dispatch work, or use the network.
-- =============================================================================

\set ON_ERROR_STOP on

begin;

create extension if not exists pgcrypto with schema extensions;

do $$
begin
  if to_regclass('public.commercial_secret_backend_registry_policies') is null
     or to_regclass('public.commercial_secret_backends') is null
     or to_regclass('public.commercial_secret_backend_versions') is null
     or to_regclass('public.commercial_secret_backend_capabilities') is null
     or to_regclass('public.commercial_secret_backend_bindings') is null
     or to_regclass('public.commercial_secret_resolution_policies') is null
     or to_regclass('public.commercial_secret_resolution_plans') is null then
    raise exception 'MIGRATION_129_DEPENDENCY_MISSING';
  end if;
end
$$;

-- =============================================================================
-- 1. GATEWAY POLICY
-- =============================================================================

create table public.commercial_secret_reference_gateway_policies (
  id uuid primary key default gen_random_uuid(),
  policy_code text not null,
  environment text not null default 'production',
  policy_status text not null default 'draft',
  policy_version integer not null default 1,

  intake_enabled boolean not null default true,
  idempotency_enabled boolean not null default true,
  policy_evaluation_enabled boolean not null default true,
  binding_selection_enabled boolean not null default true,
  namespace_validation_enabled boolean not null default true,
  capability_validation_enabled boolean not null default true,
  route_manifest_generation_enabled boolean not null default true,
  blocked_attempt_recording_enabled boolean not null default true,

  automatic_dispatch_enabled boolean not null default false,
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

  maximum_candidates integer not null default 20,
  maximum_attempts integer not null default 3,
  default_hold_seconds integer not null default 60,

  created_by text not null,
  approved_by text,
  approved_at timestamptz,
  policy_metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp(),

  constraint commercial_secret_reference_gateway_policy_unique
    unique (policy_code, environment),

  constraint commercial_secret_reference_gateway_policy_code_check
    check (
      policy_code = lower(policy_code)
      and policy_code ~ '^[a-z][a-z0-9:_-]{7,159}$'
      and environment in ('development','test','staging','production')
    ),

  constraint commercial_secret_reference_gateway_policy_status_check
    check (policy_status in ('draft','approved','retired')),

  constraint commercial_secret_reference_gateway_policy_limits_check
    check (
      policy_version > 0
      and maximum_candidates between 1 and 100
      and maximum_attempts between 1 and 20
      and default_hold_seconds between 15 and 3600
    ),

  constraint commercial_secret_reference_gateway_policy_json_check
    check (
      jsonb_typeof(policy_metadata) = 'object'
      and not (policy_metadata ?| array[
        'secret','secret_value','password','private_key','access_token',
        'refresh_token','api_key','client_secret','plaintext','ciphertext',
        'url','uri','endpoint','connection_string','dsn','host','hostname'
      ])
    ),

  constraint commercial_secret_reference_gateway_policy_actor_check
    check (
      length(btrim(created_by)) between 1 and 160
      and (approved_by is null or length(btrim(approved_by)) between 1 and 160)
    ),

  constraint commercial_secret_reference_gateway_policy_passive_check
    check (
      automatic_dispatch_enabled = false
      and endpoint_discovery_enabled = false
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

comment on table public.commercial_secret_reference_gateway_policies is
'Immutable passive policy for opaque secret-reference routing metadata.';

-- =============================================================================
-- 2. GATEWAY REQUESTS
-- =============================================================================

create table public.commercial_secret_reference_gateway_requests (
  id uuid primary key default gen_random_uuid(),
  request_key text not null unique,
  idempotency_key text not null unique,

  gateway_policy_id uuid not null,
  resolution_plan_id uuid,
  credential_binding_id uuid,

  requested_environment text not null default 'production',
  requested_namespace text not null,
  requested_capability text not null default 'reference_validation',
  requested_scope text not null default 'platform',
  requested_operation text not null default 'route_reference',

  request_status text not null default 'received',
  correlation_id uuid not null,
  causation_id uuid,
  requested_by text not null,
  requested_at timestamptz not null default clock_timestamp(),
  evaluated_at timestamptz,
  routed_at timestamptz,
  held_at timestamptz,
  terminal_reason text,

  request_metadata jsonb not null default '{}'::jsonb,
  request_hash text not null,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),

  constraint commercial_secret_reference_gateway_request_policy_fkey
    foreign key (gateway_policy_id)
    references public.commercial_secret_reference_gateway_policies(id)
    on delete restrict,

  constraint commercial_secret_reference_gateway_request_plan_fkey
    foreign key (resolution_plan_id)
    references public.commercial_secret_resolution_plans(id)
    on delete restrict,

  constraint commercial_secret_reference_gateway_request_credential_fkey
    foreign key (credential_binding_id)
    references public.commercial_provider_credential_bindings(id)
    on delete restrict,

  constraint commercial_secret_reference_gateway_request_key_check
    check (
      request_key = lower(request_key)
      and request_key ~ '^[a-z][a-z0-9:_-]{7,159}$'
      and length(idempotency_key) between 8 and 240
    ),

  constraint commercial_secret_reference_gateway_request_values_check
    check (
      requested_environment in ('development','test','staging','production')
      and requested_namespace = lower(requested_namespace)
      and requested_namespace ~ '^[a-z][a-z0-9:_-]{5,127}$'
      and requested_capability = lower(requested_capability)
      and requested_capability ~ '^[a-z][a-z0-9:_-]{3,95}$'
      and requested_scope in ('credential_binding','provider','platform')
      and requested_operation = 'route_reference'
      and request_hash ~ '^[a-f0-9]{64}$'
    ),

  constraint commercial_secret_reference_gateway_request_status_check
    check (request_status in (
      'received','evaluated','routed','held','blocked','cancelled'
    )),

  constraint commercial_secret_reference_gateway_request_json_check
    check (
      jsonb_typeof(request_metadata) = 'object'
      and not (request_metadata ?| array[
        'secret','secret_value','password','private_key','access_token',
        'refresh_token','api_key','client_secret','plaintext','ciphertext',
        'url','uri','endpoint','connection_string','dsn','host','hostname'
      ])
    ),

  constraint commercial_secret_reference_gateway_request_actor_check
    check (length(btrim(requested_by)) between 1 and 160)
);

create index commercial_secret_reference_gateway_requests_queue_idx
  on public.commercial_secret_reference_gateway_requests
  (request_status, requested_at, id);

-- =============================================================================
-- 3. IDEMPOTENCY
-- =============================================================================

create table public.commercial_secret_reference_gateway_idempotency (
  id uuid primary key default gen_random_uuid(),
  idempotency_key text not null unique,
  request_hash text not null,
  gateway_request_id uuid not null,
  first_seen_at timestamptz not null default clock_timestamp(),
  last_seen_at timestamptz not null default clock_timestamp(),
  replay_count integer not null default 0,

  constraint commercial_secret_reference_gateway_idempotency_request_fkey
    foreign key (gateway_request_id)
    references public.commercial_secret_reference_gateway_requests(id)
    on delete restrict,

  constraint commercial_secret_reference_gateway_idempotency_values_check
    check (
      length(idempotency_key) between 8 and 240
      and request_hash ~ '^[a-f0-9]{64}$'
      and replay_count >= 0
    )
);

-- =============================================================================
-- 4. CANDIDATE SNAPSHOTS
-- =============================================================================

create table public.commercial_secret_reference_gateway_candidates (
  id uuid primary key default gen_random_uuid(),
  gateway_request_id uuid not null,
  candidate_rank integer not null,

  secret_backend_binding_id uuid not null,
  secret_backend_id uuid not null,
  secret_backend_version_id uuid not null,
  orchestrator_policy_id uuid not null,

  binding_status text not null,
  backend_status text not null,
  backend_trust_tier text not null,
  backend_version_status text not null,
  reference_namespace text not null,
  requested_capability text not null,
  capability_available boolean not null,
  candidate_status text not null default 'eligible',
  rejection_reason text,

  candidate_hash text not null,
  snapshot_metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp(),

  constraint commercial_secret_reference_gateway_candidate_request_fkey
    foreign key (gateway_request_id)
    references public.commercial_secret_reference_gateway_requests(id)
    on delete restrict,

  constraint commercial_secret_reference_gateway_candidate_binding_fkey
    foreign key (secret_backend_binding_id)
    references public.commercial_secret_backend_bindings(id)
    on delete restrict,

  constraint commercial_secret_reference_gateway_candidate_backend_fkey
    foreign key (secret_backend_id)
    references public.commercial_secret_backends(id)
    on delete restrict,

  constraint commercial_secret_reference_gateway_candidate_version_fkey
    foreign key (secret_backend_version_id)
    references public.commercial_secret_backend_versions(id)
    on delete restrict,

  constraint commercial_secret_reference_gateway_candidate_policy_fkey
    foreign key (orchestrator_policy_id)
    references public.commercial_secret_resolution_policies(id)
    on delete restrict,

  constraint commercial_secret_reference_gateway_candidate_unique
    unique (gateway_request_id, candidate_rank),

  constraint commercial_secret_reference_gateway_candidate_values_check
    check (
      candidate_rank between 1 and 100
      and binding_status in ('draft','validated','suspended','retired')
      and backend_status in ('draft','validated','approved','suspended','retired')
      and backend_trust_tier in ('untrusted','registered','validated','approved')
      and backend_version_status in ('draft','validated','approved','retired')
      and reference_namespace = lower(reference_namespace)
      and requested_capability = lower(requested_capability)
      and candidate_status in ('eligible','rejected','selected')
      and candidate_hash ~ '^[a-f0-9]{64}$'
      and jsonb_typeof(snapshot_metadata) = 'object'
      and not (snapshot_metadata ?| array[
        'secret','secret_value','password','private_key','access_token',
        'refresh_token','api_key','client_secret','plaintext','ciphertext',
        'url','uri','endpoint','connection_string','dsn','host','hostname'
      ])
    )
);

-- =============================================================================
-- 5. DECISIONS
-- =============================================================================

create table public.commercial_secret_reference_gateway_decisions (
  id uuid primary key default gen_random_uuid(),
  gateway_request_id uuid not null unique,
  decision_status text not null,
  decision_code text not null,

  selected_candidate_id uuid,
  selected_backend_binding_id uuid,
  selected_backend_id uuid,
  selected_backend_version_id uuid,
  selected_orchestrator_policy_id uuid,

  requested_namespace text not null,
  resolved_namespace text,
  requested_capability text not null,
  capability_available boolean not null default false,

  backend_contact_allowed boolean not null default false,
  authentication_allowed boolean not null default false,
  secret_lookup_allowed boolean not null default false,
  secret_resolution_allowed boolean not null default false,
  decryption_allowed boolean not null default false,
  material_loading_allowed boolean not null default false,
  delivery_allowed boolean not null default false,
  network_access_allowed boolean not null default false,

  decided_by text not null,
  decision_reason text,
  decision_hash text not null,
  decision_metadata jsonb not null default '{}'::jsonb,
  decided_at timestamptz not null default clock_timestamp(),

  constraint commercial_secret_reference_gateway_decision_request_fkey
    foreign key (gateway_request_id)
    references public.commercial_secret_reference_gateway_requests(id)
    on delete restrict,

  constraint commercial_secret_reference_gateway_decision_candidate_fkey
    foreign key (selected_candidate_id)
    references public.commercial_secret_reference_gateway_candidates(id)
    on delete restrict,

  constraint commercial_secret_reference_gateway_decision_binding_fkey
    foreign key (selected_backend_binding_id)
    references public.commercial_secret_backend_bindings(id)
    on delete restrict,

  constraint commercial_secret_reference_gateway_decision_backend_fkey
    foreign key (selected_backend_id)
    references public.commercial_secret_backends(id)
    on delete restrict,

  constraint commercial_secret_reference_gateway_decision_version_fkey
    foreign key (selected_backend_version_id)
    references public.commercial_secret_backend_versions(id)
    on delete restrict,

  constraint commercial_secret_reference_gateway_decision_policy_fkey
    foreign key (selected_orchestrator_policy_id)
    references public.commercial_secret_resolution_policies(id)
    on delete restrict,

  constraint commercial_secret_reference_gateway_decision_status_check
    check (decision_status in ('accepted','held','blocked')),

  constraint commercial_secret_reference_gateway_decision_code_check
    check (decision_code in (
      'ROUTE_METADATA_ACCEPTED',
      'NO_ELIGIBLE_BINDING',
      'BINDING_NOT_VALIDATED',
      'BACKEND_NOT_VALIDATED',
      'VERSION_NOT_ACTIVE',
      'NAMESPACE_MISMATCH',
      'CAPABILITY_MISSING',
      'ORCHESTRATOR_POLICY_NOT_APPROVED',
      'GATEWAY_POLICY_DISABLED'
    )),

  constraint commercial_secret_reference_gateway_decision_values_check
    check (
      requested_namespace = lower(requested_namespace)
      and (resolved_namespace is null or resolved_namespace = lower(resolved_namespace))
      and requested_capability = lower(requested_capability)
      and decision_hash ~ '^[a-f0-9]{64}$'
      and length(btrim(decided_by)) between 1 and 160
      and jsonb_typeof(decision_metadata) = 'object'
      and not (decision_metadata ?| array[
        'secret','secret_value','password','private_key','access_token',
        'refresh_token','api_key','client_secret','plaintext','ciphertext',
        'url','uri','endpoint','connection_string','dsn','host','hostname'
      ])
    ),

  constraint commercial_secret_reference_gateway_decision_passive_check
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

-- =============================================================================
-- 6. PASSIVE ROUTE MANIFESTS
-- =============================================================================

create table public.commercial_secret_reference_route_manifests (
  id uuid primary key default gen_random_uuid(),
  gateway_request_id uuid not null unique,
  gateway_decision_id uuid not null unique,

  manifest_status text not null default 'held',
  route_class text not null default 'opaque_reference_metadata',
  backend_code text not null,
  backend_type text not null,
  backend_contract_name text not null,
  backend_contract_version text not null,
  reference_namespace text not null,
  capability_code text not null,
  binding_priority integer not null,

  dispatch_allowed boolean not null default false,
  endpoint_discovery_allowed boolean not null default false,
  backend_probe_allowed boolean not null default false,
  backend_contact_allowed boolean not null default false,
  authentication_allowed boolean not null default false,
  secret_lookup_allowed boolean not null default false,
  secret_resolution_allowed boolean not null default false,
  decryption_allowed boolean not null default false,
  material_loading_allowed boolean not null default false,
  delivery_allowed boolean not null default false,
  network_access_allowed boolean not null default false,

  generated_by text not null,
  manifest_hash text not null,
  manifest_metadata jsonb not null default '{}'::jsonb,
  generated_at timestamptz not null default clock_timestamp(),

  constraint commercial_secret_reference_route_manifest_request_fkey
    foreign key (gateway_request_id)
    references public.commercial_secret_reference_gateway_requests(id)
    on delete restrict,

  constraint commercial_secret_reference_route_manifest_decision_fkey
    foreign key (gateway_decision_id)
    references public.commercial_secret_reference_gateway_decisions(id)
    on delete restrict,

  constraint commercial_secret_reference_route_manifest_values_check
    check (
      manifest_status = 'held'
      and route_class = 'opaque_reference_metadata'
      and backend_code = lower(backend_code)
      and reference_namespace = lower(reference_namespace)
      and capability_code = lower(capability_code)
      and binding_priority between 1 and 10000
      and manifest_hash ~ '^[a-f0-9]{64}$'
      and length(btrim(generated_by)) between 1 and 160
      and jsonb_typeof(manifest_metadata) = 'object'
      and not (manifest_metadata ?| array[
        'secret','secret_value','password','private_key','access_token',
        'refresh_token','api_key','client_secret','plaintext','ciphertext',
        'url','uri','endpoint','connection_string','dsn','host','hostname'
      ])
    ),

  constraint commercial_secret_reference_route_manifest_passive_check
    check (
      dispatch_allowed = false
      and endpoint_discovery_allowed = false
      and backend_probe_allowed = false
      and backend_contact_allowed = false
      and authentication_allowed = false
      and secret_lookup_allowed = false
      and secret_resolution_allowed = false
      and decryption_allowed = false
      and material_loading_allowed = false
      and delivery_allowed = false
      and network_access_allowed = false
    )
);

-- =============================================================================
-- 7. BLOCKED EXECUTION ATTEMPTS
-- =============================================================================

create table public.commercial_secret_reference_gateway_attempts (
  id uuid primary key default gen_random_uuid(),
  gateway_request_id uuid not null,
  gateway_decision_id uuid,
  route_manifest_id uuid,
  attempt_number integer not null,
  attempt_status text not null default 'blocked',

  dispatch_requested boolean not null default false,
  dispatch_performed boolean not null default false,
  endpoint_discovery_requested boolean not null default false,
  endpoint_discovery_performed boolean not null default false,
  backend_contact_requested boolean not null default false,
  backend_contact_performed boolean not null default false,
  authentication_requested boolean not null default false,
  authentication_performed boolean not null default false,
  secret_lookup_requested boolean not null default false,
  secret_lookup_performed boolean not null default false,
  secret_material_observed boolean not null default false,
  network_attempted boolean not null default false,

  normalized_error_code text not null default 'SECRET_REFERENCE_GATEWAY_EXECUTION_DISABLED',
  retry_class text not null default 'never',
  recorded_by text not null,
  reason text not null,
  attempt_metadata jsonb not null default '{}'::jsonb,
  recorded_at timestamptz not null default clock_timestamp(),

  constraint commercial_secret_reference_gateway_attempt_request_fkey
    foreign key (gateway_request_id)
    references public.commercial_secret_reference_gateway_requests(id)
    on delete restrict,

  constraint commercial_secret_reference_gateway_attempt_decision_fkey
    foreign key (gateway_decision_id)
    references public.commercial_secret_reference_gateway_decisions(id)
    on delete restrict,

  constraint commercial_secret_reference_gateway_attempt_manifest_fkey
    foreign key (route_manifest_id)
    references public.commercial_secret_reference_route_manifests(id)
    on delete restrict,

  constraint commercial_secret_reference_gateway_attempt_unique
    unique (gateway_request_id, attempt_number),

  constraint commercial_secret_reference_gateway_attempt_values_check
    check (
      attempt_number > 0
      and attempt_status in ('blocked','abandoned')
      and retry_class in ('never','manual')
      and length(btrim(recorded_by)) between 1 and 160
      and length(btrim(reason)) between 1 and 500
      and jsonb_typeof(attempt_metadata) = 'object'
      and not (attempt_metadata ?| array[
        'secret','secret_value','password','private_key','access_token',
        'refresh_token','api_key','client_secret','plaintext','ciphertext',
        'url','uri','endpoint','connection_string','dsn','host','hostname'
      ])
    ),

  constraint commercial_secret_reference_gateway_attempt_passive_check
    check (
      dispatch_requested = false
      and dispatch_performed = false
      and endpoint_discovery_requested = false
      and endpoint_discovery_performed = false
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

-- =============================================================================
-- 8. RECEIPTS AND EVENTS
-- =============================================================================

create table public.commercial_secret_reference_gateway_receipts (
  id uuid primary key default gen_random_uuid(),
  gateway_request_id uuid not null,
  gateway_decision_id uuid,
  route_manifest_id uuid,
  attempt_id uuid,
  receipt_type text not null,
  receipt_status text not null,
  normalized_payload jsonb not null default '{}'::jsonb,
  content_hash text not null,
  issued_by text not null,
  correlation_id uuid not null,
  issued_at timestamptz not null default clock_timestamp(),

  constraint commercial_secret_reference_gateway_receipt_request_fkey
    foreign key (gateway_request_id)
    references public.commercial_secret_reference_gateway_requests(id)
    on delete restrict,

  constraint commercial_secret_reference_gateway_receipt_decision_fkey
    foreign key (gateway_decision_id)
    references public.commercial_secret_reference_gateway_decisions(id)
    on delete restrict,

  constraint commercial_secret_reference_gateway_receipt_manifest_fkey
    foreign key (route_manifest_id)
    references public.commercial_secret_reference_route_manifests(id)
    on delete restrict,

  constraint commercial_secret_reference_gateway_receipt_attempt_fkey
    foreign key (attempt_id)
    references public.commercial_secret_reference_gateway_attempts(id)
    on delete restrict,

  constraint commercial_secret_reference_gateway_receipt_type_check
    check (receipt_type in (
      'request_received','request_replayed','decision_recorded',
      'route_manifest_generated','execution_blocked'
    )),

  constraint commercial_secret_reference_gateway_receipt_status_check
    check (receipt_status in ('accepted','held','blocked')),

  constraint commercial_secret_reference_gateway_receipt_values_check
    check (
      content_hash ~ '^[a-f0-9]{64}$'
      and length(btrim(issued_by)) between 1 and 160
      and jsonb_typeof(normalized_payload) = 'object'
      and not (normalized_payload ?| array[
        'secret','secret_value','password','private_key','access_token',
        'refresh_token','api_key','client_secret','plaintext','ciphertext',
        'url','uri','endpoint','connection_string','dsn','host','hostname'
      ])
    )
);

create table public.commercial_secret_reference_gateway_events (
  id uuid primary key default gen_random_uuid(),
  event_type text not null,
  gateway_policy_id uuid,
  gateway_request_id uuid,
  gateway_candidate_id uuid,
  gateway_decision_id uuid,
  route_manifest_id uuid,
  attempt_id uuid,
  receipt_id uuid,
  previous_status text,
  new_status text,
  reason text,
  actor text not null,
  correlation_id uuid not null,
  causation_id uuid,
  payload jsonb not null default '{}'::jsonb,
  occurred_at timestamptz not null default clock_timestamp(),

  constraint commercial_secret_reference_gateway_event_policy_fkey
    foreign key (gateway_policy_id)
    references public.commercial_secret_reference_gateway_policies(id)
    on delete restrict,

  constraint commercial_secret_reference_gateway_event_request_fkey
    foreign key (gateway_request_id)
    references public.commercial_secret_reference_gateway_requests(id)
    on delete restrict,

  constraint commercial_secret_reference_gateway_event_candidate_fkey
    foreign key (gateway_candidate_id)
    references public.commercial_secret_reference_gateway_candidates(id)
    on delete restrict,

  constraint commercial_secret_reference_gateway_event_decision_fkey
    foreign key (gateway_decision_id)
    references public.commercial_secret_reference_gateway_decisions(id)
    on delete restrict,

  constraint commercial_secret_reference_gateway_event_manifest_fkey
    foreign key (route_manifest_id)
    references public.commercial_secret_reference_route_manifests(id)
    on delete restrict,

  constraint commercial_secret_reference_gateway_event_attempt_fkey
    foreign key (attempt_id)
    references public.commercial_secret_reference_gateway_attempts(id)
    on delete restrict,

  constraint commercial_secret_reference_gateway_event_receipt_fkey
    foreign key (receipt_id)
    references public.commercial_secret_reference_gateway_receipts(id)
    on delete restrict,

  constraint commercial_secret_reference_gateway_event_values_check
    check (
      event_type = upper(event_type)
      and event_type ~ '^[A-Z][A-Z0-9_]{2,95}$'
      and length(btrim(actor)) between 1 and 160
      and jsonb_typeof(payload) = 'object'
      and not (payload ?| array[
        'secret','secret_value','password','private_key','access_token',
        'refresh_token','api_key','client_secret','plaintext','ciphertext',
        'url','uri','endpoint','connection_string','dsn','host','hostname'
      ])
    )
);

create index commercial_secret_reference_gateway_events_timeline_idx
  on public.commercial_secret_reference_gateway_events
  (gateway_request_id, occurred_at, id);

-- =============================================================================
-- 9. PROTECTION AND UPDATED-AT FUNCTIONS
-- =============================================================================

create or replace function public.protect_commercial_secret_reference_gateway_policy()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  raise exception 'COMMERCIAL_SECRET_REFERENCE_GATEWAY_POLICY_IMMUTABLE';
end
$$;

create or replace function public.protect_commercial_secret_reference_gateway_candidate()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  raise exception 'COMMERCIAL_SECRET_REFERENCE_GATEWAY_CANDIDATE_IMMUTABLE';
end
$$;

create or replace function public.protect_commercial_secret_reference_gateway_decision()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  raise exception 'COMMERCIAL_SECRET_REFERENCE_GATEWAY_DECISION_IMMUTABLE';
end
$$;

create or replace function public.protect_commercial_secret_reference_route_manifest()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  raise exception 'COMMERCIAL_SECRET_REFERENCE_ROUTE_MANIFEST_IMMUTABLE';
end
$$;

create or replace function public.protect_commercial_secret_reference_gateway_receipt()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  raise exception 'COMMERCIAL_SECRET_REFERENCE_GATEWAY_RECEIPT_APPEND_ONLY';
end
$$;

create or replace function public.protect_commercial_secret_reference_gateway_event()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  raise exception 'COMMERCIAL_SECRET_REFERENCE_GATEWAY_EVENT_APPEND_ONLY';
end
$$;

create or replace function public.set_commercial_secret_reference_gateway_updated_at()
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

create trigger commercial_secret_reference_gateway_policy_protect
before update or delete
on public.commercial_secret_reference_gateway_policies
for each row execute function public.protect_commercial_secret_reference_gateway_policy();

create trigger commercial_secret_reference_gateway_candidate_protect
before update or delete
on public.commercial_secret_reference_gateway_candidates
for each row execute function public.protect_commercial_secret_reference_gateway_candidate();

create trigger commercial_secret_reference_gateway_decision_protect
before update or delete
on public.commercial_secret_reference_gateway_decisions
for each row execute function public.protect_commercial_secret_reference_gateway_decision();

create trigger commercial_secret_reference_route_manifest_protect
before update or delete
on public.commercial_secret_reference_route_manifests
for each row execute function public.protect_commercial_secret_reference_route_manifest();

create trigger commercial_secret_reference_gateway_receipt_protect
before update or delete
on public.commercial_secret_reference_gateway_receipts
for each row execute function public.protect_commercial_secret_reference_gateway_receipt();

create trigger commercial_secret_reference_gateway_event_protect
before update or delete
on public.commercial_secret_reference_gateway_events
for each row execute function public.protect_commercial_secret_reference_gateway_event();

create trigger commercial_secret_reference_gateway_request_updated_at
before update
on public.commercial_secret_reference_gateway_requests
for each row execute function public.set_commercial_secret_reference_gateway_updated_at();

-- =============================================================================
-- 10. APPEND HELPERS
-- =============================================================================

create or replace function public.append_commercial_secret_reference_gateway_receipt(
  p_gateway_request_id uuid,
  p_gateway_decision_id uuid,
  p_route_manifest_id uuid,
  p_attempt_id uuid,
  p_receipt_type text,
  p_receipt_status text,
  p_normalized_payload jsonb,
  p_issued_by text,
  p_correlation_id uuid
)
returns public.commercial_secret_reference_gateway_receipts
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_hash text;
  v_result public.commercial_secret_reference_gateway_receipts;
begin
  v_hash := encode(
    extensions.digest(
      jsonb_build_object(
        'gateway_request_id',p_gateway_request_id,
        'gateway_decision_id',p_gateway_decision_id,
        'route_manifest_id',p_route_manifest_id,
        'attempt_id',p_attempt_id,
        'receipt_type',lower(btrim(p_receipt_type)),
        'receipt_status',lower(btrim(p_receipt_status)),
        'normalized_payload',coalesce(p_normalized_payload,'{}'::jsonb),
        'correlation_id',p_correlation_id
      )::text,
      'sha256'
    ),
    'hex'
  );

  insert into public.commercial_secret_reference_gateway_receipts (
    gateway_request_id,gateway_decision_id,route_manifest_id,attempt_id,
    receipt_type,receipt_status,normalized_payload,content_hash,
    issued_by,correlation_id
  ) values (
    p_gateway_request_id,p_gateway_decision_id,p_route_manifest_id,p_attempt_id,
    lower(btrim(p_receipt_type)),lower(btrim(p_receipt_status)),
    coalesce(p_normalized_payload,'{}'::jsonb),v_hash,
    btrim(p_issued_by),p_correlation_id
  )
  returning * into v_result;

  return v_result;
end
$$;

create or replace function public.append_commercial_secret_reference_gateway_event(
  p_event_type text,
  p_actor text,
  p_correlation_id uuid,
  p_gateway_policy_id uuid default null,
  p_gateway_request_id uuid default null,
  p_gateway_candidate_id uuid default null,
  p_gateway_decision_id uuid default null,
  p_route_manifest_id uuid default null,
  p_attempt_id uuid default null,
  p_receipt_id uuid default null,
  p_previous_status text default null,
  p_new_status text default null,
  p_reason text default null,
  p_causation_id uuid default null,
  p_payload jsonb default '{}'::jsonb
)
returns public.commercial_secret_reference_gateway_events
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_result public.commercial_secret_reference_gateway_events;
begin
  insert into public.commercial_secret_reference_gateway_events (
    event_type,gateway_policy_id,gateway_request_id,gateway_candidate_id,
    gateway_decision_id,route_manifest_id,attempt_id,receipt_id,
    previous_status,new_status,reason,actor,correlation_id,causation_id,payload
  ) values (
    upper(btrim(p_event_type)),p_gateway_policy_id,p_gateway_request_id,
    p_gateway_candidate_id,p_gateway_decision_id,p_route_manifest_id,
    p_attempt_id,p_receipt_id,p_previous_status,p_new_status,p_reason,
    btrim(p_actor),p_correlation_id,p_causation_id,
    coalesce(p_payload,'{}'::jsonb)
  )
  returning * into v_result;

  return v_result;
end
$$;

-- =============================================================================
-- 11. REQUEST INTAKE WITH IDEMPOTENCY
-- =============================================================================

create or replace function public.enqueue_commercial_secret_reference_gateway_request(
  p_request_key text,
  p_idempotency_key text,
  p_resolution_plan_id uuid,
  p_credential_binding_id uuid,
  p_requested_environment text,
  p_requested_namespace text,
  p_requested_capability text,
  p_requested_scope text,
  p_requested_by text,
  p_correlation_id uuid,
  p_causation_id uuid default null,
  p_request_metadata jsonb default '{}'::jsonb
)
returns public.commercial_secret_reference_gateway_requests
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_policy public.commercial_secret_reference_gateway_policies;
  v_hash text;
  v_existing public.commercial_secret_reference_gateway_idempotency;
  v_request public.commercial_secret_reference_gateway_requests;
  v_receipt public.commercial_secret_reference_gateway_receipts;
begin
  select * into strict v_policy
  from public.commercial_secret_reference_gateway_policies
  where environment = lower(btrim(p_requested_environment))
    and policy_status = 'approved'
  order by policy_version desc
  limit 1;

  if v_policy.intake_enabled is not true then
    raise exception 'COMMERCIAL_SECRET_REFERENCE_GATEWAY_INTAKE_DISABLED';
  end if;

  v_hash := encode(
    extensions.digest(
      jsonb_build_object(
        'request_key',lower(btrim(p_request_key)),
        'resolution_plan_id',p_resolution_plan_id,
        'credential_binding_id',p_credential_binding_id,
        'requested_environment',lower(btrim(p_requested_environment)),
        'requested_namespace',lower(btrim(p_requested_namespace)),
        'requested_capability',lower(btrim(p_requested_capability)),
        'requested_scope',lower(btrim(p_requested_scope)),
        'requested_operation','route_reference',
        'request_metadata',coalesce(p_request_metadata,'{}'::jsonb)
      )::text,
      'sha256'
    ),
    'hex'
  );

  select *
  into v_existing
  from public.commercial_secret_reference_gateway_idempotency
  where idempotency_key = p_idempotency_key
  for update;

  if found then
    if v_existing.request_hash <> v_hash then
      raise exception 'COMMERCIAL_SECRET_REFERENCE_GATEWAY_IDEMPOTENCY_CONFLICT';
    end if;

    update public.commercial_secret_reference_gateway_idempotency
    set replay_count = replay_count + 1,
        last_seen_at = clock_timestamp()
    where id = v_existing.id;

    select * into strict v_request
    from public.commercial_secret_reference_gateway_requests
    where id = v_existing.gateway_request_id;

    v_receipt := public.append_commercial_secret_reference_gateway_receipt(
      v_request.id,null,null,null,'request_replayed','accepted',
      jsonb_build_object('replay',true,'request_hash',v_hash),
      p_requested_by,p_correlation_id
    );

    perform public.append_commercial_secret_reference_gateway_event(
      'SECRET_REFERENCE_GATEWAY_REQUEST_REPLAYED',
      p_requested_by,p_correlation_id,v_policy.id,v_request.id,
      null,null,null,null,v_receipt.id,
      v_request.request_status,v_request.request_status,
      'Idempotent gateway request replay',p_causation_id,
      jsonb_build_object('request_hash',v_hash)
    );

    return v_request;
  end if;

  insert into public.commercial_secret_reference_gateway_requests (
    request_key,idempotency_key,gateway_policy_id,resolution_plan_id,
    credential_binding_id,requested_environment,requested_namespace,
    requested_capability,requested_scope,requested_operation,
    request_status,correlation_id,causation_id,requested_by,
    request_metadata,request_hash
  ) values (
    lower(btrim(p_request_key)),p_idempotency_key,v_policy.id,p_resolution_plan_id,
    p_credential_binding_id,lower(btrim(p_requested_environment)),
    lower(btrim(p_requested_namespace)),lower(btrim(p_requested_capability)),
    lower(btrim(p_requested_scope)),'route_reference','received',
    p_correlation_id,p_causation_id,btrim(p_requested_by),
    coalesce(p_request_metadata,'{}'::jsonb),v_hash
  )
  returning * into v_request;

  insert into public.commercial_secret_reference_gateway_idempotency (
    idempotency_key,request_hash,gateway_request_id
  ) values (
    p_idempotency_key,v_hash,v_request.id
  );

  v_receipt := public.append_commercial_secret_reference_gateway_receipt(
    v_request.id,null,null,null,'request_received','accepted',
    jsonb_build_object('request_hash',v_hash),
    p_requested_by,p_correlation_id
  );

  perform public.append_commercial_secret_reference_gateway_event(
    'SECRET_REFERENCE_GATEWAY_REQUEST_RECEIVED',
    p_requested_by,p_correlation_id,v_policy.id,v_request.id,
    null,null,null,null,v_receipt.id,
    null,'received','Gateway request accepted',p_causation_id,
    jsonb_build_object('request_hash',v_hash)
  );

  return v_request;
end
$$;

-- =============================================================================
-- 12. DETERMINISTIC EVALUATION AND ROUTE DECISION
-- =============================================================================

create or replace function public.evaluate_commercial_secret_reference_gateway_request(
  p_gateway_request_id uuid,
  p_evaluated_by text
)
returns public.commercial_secret_reference_gateway_decisions
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_request public.commercial_secret_reference_gateway_requests;
  v_policy public.commercial_secret_reference_gateway_policies;
  v_binding public.commercial_secret_backend_bindings;
  v_backend public.commercial_secret_backends;
  v_version public.commercial_secret_backend_versions;
  v_orchestrator_policy public.commercial_secret_resolution_policies;
  v_capability_available boolean := false;
  v_candidate public.commercial_secret_reference_gateway_candidates;
  v_decision public.commercial_secret_reference_gateway_decisions;
  v_receipt public.commercial_secret_reference_gateway_receipts;
  v_decision_status text;
  v_decision_code text;
  v_decision_reason text;
  v_hash text;
begin
  select * into strict v_request
  from public.commercial_secret_reference_gateway_requests
  where id = p_gateway_request_id
  for update;

  select * into strict v_policy
  from public.commercial_secret_reference_gateway_policies
  where id = v_request.gateway_policy_id;

  select *
  into v_binding
  from public.commercial_secret_backend_bindings b
  where b.binding_status = 'validated'
    and b.reference_namespace = v_request.requested_namespace
    and (
      (v_request.credential_binding_id is not null
       and b.credential_binding_id = v_request.credential_binding_id)
      or
      (v_request.credential_binding_id is null
       and b.binding_scope = v_request.requested_scope)
    )
  order by
    case when b.credential_binding_id is not null then 0 else 1 end,
    b.priority asc,
    b.created_at asc,
    b.id asc
  limit 1;

  if not found then
    v_decision_status := 'blocked';
    v_decision_code := 'NO_ELIGIBLE_BINDING';
    v_decision_reason := 'No validated backend binding matched the request';
  else
    select * into strict v_backend
    from public.commercial_secret_backends
    where id = v_binding.secret_backend_id;

    select * into strict v_version
    from public.commercial_secret_backend_versions
    where id = v_binding.secret_backend_version_id;

    select * into strict v_orchestrator_policy
    from public.commercial_secret_resolution_policies
    where id = v_binding.orchestrator_policy_id;

    select exists (
      select 1
      from public.commercial_secret_backend_capabilities c
      where c.secret_backend_version_id = v_version.id
        and c.capability_code = v_request.requested_capability
        and c.capability_status = 'validated'
        and c.passive_only is true
        and c.requires_backend_contact is false
        and c.requires_authentication is false
        and c.requires_secret_material is false
        and c.requires_network is false
    )
    into v_capability_available;

    v_hash := encode(
      extensions.digest(
        jsonb_build_object(
          'gateway_request_id',v_request.id,
          'secret_backend_binding_id',v_binding.id,
          'secret_backend_id',v_backend.id,
          'secret_backend_version_id',v_version.id,
          'orchestrator_policy_id',v_orchestrator_policy.id,
          'reference_namespace',v_binding.reference_namespace,
          'requested_capability',v_request.requested_capability,
          'capability_available',v_capability_available
        )::text,
        'sha256'
      ),
      'hex'
    );

    insert into public.commercial_secret_reference_gateway_candidates (
      gateway_request_id,candidate_rank,secret_backend_binding_id,
      secret_backend_id,secret_backend_version_id,orchestrator_policy_id,
      binding_status,backend_status,backend_trust_tier,
      backend_version_status,reference_namespace,requested_capability,
      capability_available,candidate_status,rejection_reason,candidate_hash,
      snapshot_metadata
    ) values (
      v_request.id,1,v_binding.id,v_backend.id,v_version.id,
      v_orchestrator_policy.id,v_binding.binding_status,v_backend.backend_status,
      v_backend.trust_tier,v_version.version_status,v_binding.reference_namespace,
      v_request.requested_capability,v_capability_available,'eligible',null,v_hash,
      jsonb_build_object('deterministic_rank',1,'passive_only',true)
    )
    returning * into v_candidate;

    if v_backend.backend_status not in ('validated','approved')
       or v_backend.trust_tier not in ('validated','approved') then
      v_decision_status := 'blocked';
      v_decision_code := 'BACKEND_NOT_VALIDATED';
      v_decision_reason := 'Selected backend is not validated';
    elsif v_version.version_status not in ('validated','approved')
       or v_backend.active_version_id <> v_version.id then
      v_decision_status := 'blocked';
      v_decision_code := 'VERSION_NOT_ACTIVE';
      v_decision_reason := 'Selected backend version is not active';
    elsif v_binding.reference_namespace <> v_request.requested_namespace then
      v_decision_status := 'blocked';
      v_decision_code := 'NAMESPACE_MISMATCH';
      v_decision_reason := 'Opaque reference namespace mismatch';
    elsif v_capability_available is not true then
      v_decision_status := 'blocked';
      v_decision_code := 'CAPABILITY_MISSING';
      v_decision_reason := 'Required passive capability is unavailable';
    elsif v_orchestrator_policy.policy_status <> 'approved' then
      v_decision_status := 'blocked';
      v_decision_code := 'ORCHESTRATOR_POLICY_NOT_APPROVED';
      v_decision_reason := 'Orchestrator policy is not approved';
    else
      v_decision_status := 'accepted';
      v_decision_code := 'ROUTE_METADATA_ACCEPTED';
      v_decision_reason := 'Passive route metadata accepted';
    end if;
  end if;

  v_hash := encode(
    extensions.digest(
      jsonb_build_object(
        'gateway_request_id',v_request.id,
        'decision_status',v_decision_status,
        'decision_code',v_decision_code,
        'selected_candidate_id',v_candidate.id,
        'selected_backend_binding_id',v_binding.id,
        'selected_backend_id',v_backend.id,
        'selected_backend_version_id',v_version.id,
        'selected_orchestrator_policy_id',v_orchestrator_policy.id,
        'requested_namespace',v_request.requested_namespace,
        'resolved_namespace',v_binding.reference_namespace,
        'requested_capability',v_request.requested_capability,
        'capability_available',v_capability_available
      )::text,
      'sha256'
    ),
    'hex'
  );

  insert into public.commercial_secret_reference_gateway_decisions (
    gateway_request_id,decision_status,decision_code,selected_candidate_id,
    selected_backend_binding_id,selected_backend_id,
    selected_backend_version_id,selected_orchestrator_policy_id,
    requested_namespace,resolved_namespace,requested_capability,
    capability_available,decided_by,decision_reason,decision_hash,
    decision_metadata
  ) values (
    v_request.id,v_decision_status,v_decision_code,v_candidate.id,
    v_binding.id,v_backend.id,v_version.id,v_orchestrator_policy.id,
    v_request.requested_namespace,v_binding.reference_namespace,
    v_request.requested_capability,v_capability_available,
    btrim(p_evaluated_by),v_decision_reason,v_hash,
    jsonb_build_object('passive_only',true,'candidate_rank',v_candidate.candidate_rank)
  )
  returning * into v_decision;

  update public.commercial_secret_reference_gateway_requests
  set request_status = case
        when v_decision_status = 'accepted' then 'evaluated'
        else 'blocked'
      end,
      evaluated_at = clock_timestamp(),
      terminal_reason = case
        when v_decision_status = 'accepted' then null
        else v_decision_reason
      end
  where id = v_request.id;

  v_receipt := public.append_commercial_secret_reference_gateway_receipt(
    v_request.id,v_decision.id,null,null,'decision_recorded',
    case when v_decision_status='accepted' then 'accepted' else 'blocked' end,
    jsonb_build_object(
      'decision_code',v_decision.decision_code,
      'capability_available',v_decision.capability_available
    ),
    p_evaluated_by,v_request.correlation_id
  );

  perform public.append_commercial_secret_reference_gateway_event(
    'SECRET_REFERENCE_GATEWAY_DECISION_RECORDED',
    p_evaluated_by,v_request.correlation_id,v_policy.id,v_request.id,
    v_candidate.id,v_decision.id,null,null,v_receipt.id,
    'received',
    case when v_decision_status='accepted' then 'evaluated' else 'blocked' end,
    v_decision_reason,v_request.causation_id,
    jsonb_build_object('decision_code',v_decision.decision_code)
  );

  return v_decision;
end
$$;

-- =============================================================================
-- 13. ROUTE MANIFEST GENERATION
-- =============================================================================

create or replace function public.build_commercial_secret_reference_route_manifest(
  p_gateway_request_id uuid,
  p_generated_by text
)
returns public.commercial_secret_reference_route_manifests
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_request public.commercial_secret_reference_gateway_requests;
  v_decision public.commercial_secret_reference_gateway_decisions;
  v_binding public.commercial_secret_backend_bindings;
  v_backend public.commercial_secret_backends;
  v_version public.commercial_secret_backend_versions;
  v_manifest public.commercial_secret_reference_route_manifests;
  v_receipt public.commercial_secret_reference_gateway_receipts;
  v_hash text;
begin
  select * into strict v_request
  from public.commercial_secret_reference_gateway_requests
  where id = p_gateway_request_id
  for update;

  select * into strict v_decision
  from public.commercial_secret_reference_gateway_decisions
  where gateway_request_id = v_request.id;

  if v_decision.decision_status <> 'accepted'
     or v_decision.decision_code <> 'ROUTE_METADATA_ACCEPTED' then
    raise exception 'COMMERCIAL_SECRET_REFERENCE_GATEWAY_ROUTE_NOT_ACCEPTED';
  end if;

  select * into strict v_binding
  from public.commercial_secret_backend_bindings
  where id = v_decision.selected_backend_binding_id;

  select * into strict v_backend
  from public.commercial_secret_backends
  where id = v_decision.selected_backend_id;

  select * into strict v_version
  from public.commercial_secret_backend_versions
  where id = v_decision.selected_backend_version_id;

  v_hash := encode(
    extensions.digest(
      jsonb_build_object(
        'gateway_request_id',v_request.id,
        'gateway_decision_id',v_decision.id,
        'route_class','opaque_reference_metadata',
        'backend_code',v_backend.backend_code,
        'backend_type',v_backend.backend_type,
        'backend_contract_name',v_version.contract_name,
        'backend_contract_version',v_version.contract_version,
        'reference_namespace',v_binding.reference_namespace,
        'capability_code',v_request.requested_capability,
        'binding_priority',v_binding.priority,
        'execution_allowed',false
      )::text,
      'sha256'
    ),
    'hex'
  );

  insert into public.commercial_secret_reference_route_manifests (
    gateway_request_id,gateway_decision_id,manifest_status,route_class,
    backend_code,backend_type,backend_contract_name,
    backend_contract_version,reference_namespace,capability_code,
    binding_priority,generated_by,manifest_hash,manifest_metadata
  ) values (
    v_request.id,v_decision.id,'held','opaque_reference_metadata',
    v_backend.backend_code,v_backend.backend_type,v_version.contract_name,
    v_version.contract_version,v_binding.reference_namespace,
    v_request.requested_capability,v_binding.priority,btrim(p_generated_by),
    v_hash,jsonb_build_object('passive_only',true,'opaque_references_only',true)
  )
  returning * into v_manifest;

  update public.commercial_secret_reference_gateway_requests
  set request_status = 'held',
      routed_at = clock_timestamp(),
      held_at = clock_timestamp(),
      terminal_reason = 'PASSIVE_ROUTE_MANIFEST_HELD'
  where id = v_request.id;

  v_receipt := public.append_commercial_secret_reference_gateway_receipt(
    v_request.id,v_decision.id,v_manifest.id,null,
    'route_manifest_generated','held',
    jsonb_build_object(
      'manifest_hash',v_hash,
      'manifest_status','held',
      'route_class','opaque_reference_metadata'
    ),
    p_generated_by,v_request.correlation_id
  );

  perform public.append_commercial_secret_reference_gateway_event(
    'SECRET_REFERENCE_ROUTE_MANIFEST_GENERATED',
    p_generated_by,v_request.correlation_id,v_request.gateway_policy_id,
    v_request.id,null,v_decision.id,v_manifest.id,null,v_receipt.id,
    'evaluated','held','Passive route manifest generated and held',
    v_request.causation_id,
    jsonb_build_object('manifest_hash',v_hash)
  );

  return v_manifest;
end
$$;

-- =============================================================================
-- 14. BLOCKED EXECUTION RECORDING
-- =============================================================================

create or replace function public.record_blocked_secret_reference_gateway_attempt(
  p_gateway_request_id uuid,
  p_recorded_by text,
  p_reason text
)
returns public.commercial_secret_reference_gateway_attempts
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_request public.commercial_secret_reference_gateway_requests;
  v_decision public.commercial_secret_reference_gateway_decisions;
  v_manifest public.commercial_secret_reference_route_manifests;
  v_attempt_number integer;
  v_attempt public.commercial_secret_reference_gateway_attempts;
  v_receipt public.commercial_secret_reference_gateway_receipts;
begin
  select * into strict v_request
  from public.commercial_secret_reference_gateway_requests
  where id = p_gateway_request_id;

  select * into v_decision
  from public.commercial_secret_reference_gateway_decisions
  where gateway_request_id = v_request.id;

  select * into v_manifest
  from public.commercial_secret_reference_route_manifests
  where gateway_request_id = v_request.id;

  select coalesce(max(attempt_number),0)+1
  into v_attempt_number
  from public.commercial_secret_reference_gateway_attempts
  where gateway_request_id = v_request.id;

  insert into public.commercial_secret_reference_gateway_attempts (
    gateway_request_id,gateway_decision_id,route_manifest_id,
    attempt_number,attempt_status,recorded_by,reason,attempt_metadata
  ) values (
    v_request.id,v_decision.id,v_manifest.id,v_attempt_number,'blocked',
    btrim(p_recorded_by),btrim(p_reason),
    jsonb_build_object('passive_only',true)
  )
  returning * into v_attempt;

  v_receipt := public.append_commercial_secret_reference_gateway_receipt(
    v_request.id,v_decision.id,v_manifest.id,v_attempt.id,
    'execution_blocked','blocked',
    jsonb_build_object(
      'dispatch_performed',false,
      'endpoint_discovery_performed',false,
      'backend_contact_performed',false,
      'authentication_performed',false,
      'secret_lookup_performed',false,
      'secret_material_observed',false,
      'network_attempted',false
    ),
    p_recorded_by,v_request.correlation_id
  );

  perform public.append_commercial_secret_reference_gateway_event(
    'SECRET_REFERENCE_GATEWAY_EXECUTION_BLOCKED',
    p_recorded_by,v_request.correlation_id,v_request.gateway_policy_id,
    v_request.id,null,v_decision.id,v_manifest.id,v_attempt.id,v_receipt.id,
    v_request.request_status,v_request.request_status,p_reason,
    v_request.causation_id,
    jsonb_build_object('attempt_number',v_attempt.attempt_number)
  );

  return v_attempt;
end
$$;

-- =============================================================================
-- 15. READ MODEL
-- =============================================================================

create or replace view public.commercial_secret_reference_gateway_read_model as
select
  r.id as gateway_request_id,
  r.request_key,
  r.idempotency_key,
  r.request_status,
  r.requested_environment,
  r.requested_namespace,
  r.requested_capability,
  r.requested_scope,
  r.resolution_plan_id,
  r.credential_binding_id,
  d.id as gateway_decision_id,
  d.decision_status,
  d.decision_code,
  d.selected_backend_binding_id,
  d.selected_backend_id,
  d.selected_backend_version_id,
  d.selected_orchestrator_policy_id,
  d.capability_available,
  m.id as route_manifest_id,
  m.manifest_status,
  m.route_class,
  m.backend_code,
  m.backend_type,
  m.backend_contract_name,
  m.backend_contract_version,
  m.reference_namespace as resolved_namespace,
  m.capability_code,
  m.binding_priority,
  m.dispatch_allowed,
  m.endpoint_discovery_allowed,
  m.backend_probe_allowed,
  m.backend_contact_allowed,
  m.authentication_allowed,
  m.secret_lookup_allowed,
  m.secret_resolution_allowed,
  m.decryption_allowed,
  m.material_loading_allowed,
  m.delivery_allowed,
  m.network_access_allowed,
  coalesce(c.candidate_count,0) as candidate_count,
  coalesce(a.attempt_count,0) as attempt_count,
  coalesce(x.receipt_count,0) as receipt_count,
  coalesce(e.event_count,0) as event_count,
  i.replay_count,
  r.requested_at,
  r.evaluated_at,
  r.routed_at,
  r.held_at,
  r.terminal_reason
from public.commercial_secret_reference_gateway_requests r
left join public.commercial_secret_reference_gateway_decisions d
  on d.gateway_request_id = r.id
left join public.commercial_secret_reference_route_manifests m
  on m.gateway_request_id = r.id
left join public.commercial_secret_reference_gateway_idempotency i
  on i.gateway_request_id = r.id
left join lateral (
  select count(*)::bigint as candidate_count
  from public.commercial_secret_reference_gateway_candidates q
  where q.gateway_request_id = r.id
) c on true
left join lateral (
  select count(*)::bigint as attempt_count
  from public.commercial_secret_reference_gateway_attempts q
  where q.gateway_request_id = r.id
) a on true
left join lateral (
  select count(*)::bigint as receipt_count
  from public.commercial_secret_reference_gateway_receipts q
  where q.gateway_request_id = r.id
) x on true
left join lateral (
  select count(*)::bigint as event_count
  from public.commercial_secret_reference_gateway_events q
  where q.gateway_request_id = r.id
) e on true;

comment on view public.commercial_secret_reference_gateway_read_model is
'Passive read model for deterministic opaque-reference routing decisions.';

-- =============================================================================
-- 16. FOUNDATION POLICY AND INITIAL EVENT
-- =============================================================================

insert into public.commercial_secret_reference_gateway_policies (
  policy_code,environment,policy_status,policy_version,
  created_by,approved_by,approved_at,policy_metadata
) values (
  'commercial:provider_secret_reference_gateway:v1',
  'production',
  'approved',
  1,
  'MIGRATION_129',
  'MIGRATION_129',
  clock_timestamp(),
  jsonb_build_object(
    'foundation',true,
    'mode','passive_reference_routing',
    'opaque_references_only',true
  )
);

select public.append_commercial_secret_reference_gateway_event(
  'SECRET_REFERENCE_GATEWAY_INITIALIZED',
  'MIGRATION_129',
  gen_random_uuid(),
  (
    select id
    from public.commercial_secret_reference_gateway_policies
    where policy_code='commercial:provider_secret_reference_gateway:v1'
      and environment='production'
  ),
  null,null,null,null,null,null,null,'approved',
  'Secret-reference gateway initialized in passive mode',
  null,
  jsonb_build_object(
    'automatic_dispatch_enabled',false,
    'endpoint_discovery_enabled',false,
    'backend_probe_enabled',false,
    'backend_contact_enabled',false,
    'backend_authentication_enabled',false,
    'secret_lookup_enabled',false,
    'secret_resolution_enabled',false,
    'secret_decryption_enabled',false,
    'credential_material_loading_enabled',false,
    'credential_delivery_enabled',false,
    'network_access_enabled',false
  )
);

-- =============================================================================
-- 17. RLS AND PRIVILEGES
-- =============================================================================

alter table public.commercial_secret_reference_gateway_policies enable row level security;
alter table public.commercial_secret_reference_gateway_requests enable row level security;
alter table public.commercial_secret_reference_gateway_idempotency enable row level security;
alter table public.commercial_secret_reference_gateway_candidates enable row level security;
alter table public.commercial_secret_reference_gateway_decisions enable row level security;
alter table public.commercial_secret_reference_route_manifests enable row level security;
alter table public.commercial_secret_reference_gateway_attempts enable row level security;
alter table public.commercial_secret_reference_gateway_receipts enable row level security;
alter table public.commercial_secret_reference_gateway_events enable row level security;

revoke all on table public.commercial_secret_reference_gateway_policies from public,anon,authenticated;
revoke all on table public.commercial_secret_reference_gateway_requests from public,anon,authenticated;
revoke all on table public.commercial_secret_reference_gateway_idempotency from public,anon,authenticated;
revoke all on table public.commercial_secret_reference_gateway_candidates from public,anon,authenticated;
revoke all on table public.commercial_secret_reference_gateway_decisions from public,anon,authenticated;
revoke all on table public.commercial_secret_reference_route_manifests from public,anon,authenticated;
revoke all on table public.commercial_secret_reference_gateway_attempts from public,anon,authenticated;
revoke all on table public.commercial_secret_reference_gateway_receipts from public,anon,authenticated;
revoke all on table public.commercial_secret_reference_gateway_events from public,anon,authenticated;
revoke all on table public.commercial_secret_reference_gateway_read_model from public,anon,authenticated;

grant select,insert,update,delete on table public.commercial_secret_reference_gateway_policies to service_role;
grant select,insert,update,delete on table public.commercial_secret_reference_gateway_requests to service_role;
grant select,insert,update,delete on table public.commercial_secret_reference_gateway_idempotency to service_role;
grant select,insert,update,delete on table public.commercial_secret_reference_gateway_candidates to service_role;
grant select,insert,update,delete on table public.commercial_secret_reference_gateway_decisions to service_role;
grant select,insert,update,delete on table public.commercial_secret_reference_route_manifests to service_role;
grant select,insert,update,delete on table public.commercial_secret_reference_gateway_attempts to service_role;
grant select,insert,update,delete on table public.commercial_secret_reference_gateway_receipts to service_role;
grant select,insert,update,delete on table public.commercial_secret_reference_gateway_events to service_role;
grant select on table public.commercial_secret_reference_gateway_read_model to service_role;

revoke all on function public.append_commercial_secret_reference_gateway_receipt(
  uuid,uuid,uuid,uuid,text,text,jsonb,text,uuid
) from public,anon,authenticated;
revoke all on function public.append_commercial_secret_reference_gateway_event(
  text,text,uuid,uuid,uuid,uuid,uuid,uuid,uuid,uuid,text,text,text,uuid,jsonb
) from public,anon,authenticated;
revoke all on function public.enqueue_commercial_secret_reference_gateway_request(
  text,text,uuid,uuid,text,text,text,text,text,uuid,uuid,jsonb
) from public,anon,authenticated;
revoke all on function public.evaluate_commercial_secret_reference_gateway_request(
  uuid,text
) from public,anon,authenticated;
revoke all on function public.build_commercial_secret_reference_route_manifest(
  uuid,text
) from public,anon,authenticated;
revoke all on function public.record_blocked_secret_reference_gateway_attempt(
  uuid,text,text
) from public,anon,authenticated;

grant execute on function public.append_commercial_secret_reference_gateway_receipt(
  uuid,uuid,uuid,uuid,text,text,jsonb,text,uuid
) to service_role;
grant execute on function public.append_commercial_secret_reference_gateway_event(
  text,text,uuid,uuid,uuid,uuid,uuid,uuid,uuid,uuid,text,text,text,uuid,jsonb
) to service_role;
grant execute on function public.enqueue_commercial_secret_reference_gateway_request(
  text,text,uuid,uuid,text,text,text,text,text,uuid,uuid,jsonb
) to service_role;
grant execute on function public.evaluate_commercial_secret_reference_gateway_request(
  uuid,text
) to service_role;
grant execute on function public.build_commercial_secret_reference_route_manifest(
  uuid,text
) to service_role;
grant execute on function public.record_blocked_secret_reference_gateway_attempt(
  uuid,text,text
) to service_role;

-- =============================================================================
-- 18. FOUNDATION CERTIFICATION
-- =============================================================================

do $$
declare
  v_policy public.commercial_secret_reference_gateway_policies;
  v_policy_count bigint;
  v_request_count bigint;
  v_idempotency_count bigint;
  v_candidate_count bigint;
  v_decision_count bigint;
  v_manifest_count bigint;
  v_attempt_count bigint;
  v_receipt_count bigint;
  v_event_count bigint;
begin
  select * into strict v_policy
  from public.commercial_secret_reference_gateway_policies
  where policy_code='commercial:provider_secret_reference_gateway:v1'
    and environment='production';

  select count(*) into v_policy_count
  from public.commercial_secret_reference_gateway_policies;

  select count(*) into v_request_count
  from public.commercial_secret_reference_gateway_requests;

  select count(*) into v_idempotency_count
  from public.commercial_secret_reference_gateway_idempotency;

  select count(*) into v_candidate_count
  from public.commercial_secret_reference_gateway_candidates;

  select count(*) into v_decision_count
  from public.commercial_secret_reference_gateway_decisions;

  select count(*) into v_manifest_count
  from public.commercial_secret_reference_route_manifests;

  select count(*) into v_attempt_count
  from public.commercial_secret_reference_gateway_attempts;

  select count(*) into v_receipt_count
  from public.commercial_secret_reference_gateway_receipts;

  select count(*) into v_event_count
  from public.commercial_secret_reference_gateway_events;

  if v_policy_count <> 1
     or v_request_count <> 0
     or v_idempotency_count <> 0
     or v_candidate_count <> 0
     or v_decision_count <> 0
     or v_manifest_count <> 0
     or v_attempt_count <> 0
     or v_receipt_count <> 0
     or v_event_count <> 1 then
    raise exception
      'MIGRATION_129_COUNT_ASSERTION_FAILED policy=%, request=%, idempotency=%, candidate=%, decision=%, manifest=%, attempt=%, receipt=%, event=%',
      v_policy_count,v_request_count,v_idempotency_count,v_candidate_count,
      v_decision_count,v_manifest_count,v_attempt_count,v_receipt_count,
      v_event_count;
  end if;

  if v_policy.intake_enabled is not true
     or v_policy.idempotency_enabled is not true
     or v_policy.policy_evaluation_enabled is not true
     or v_policy.binding_selection_enabled is not true
     or v_policy.namespace_validation_enabled is not true
     or v_policy.capability_validation_enabled is not true
     or v_policy.route_manifest_generation_enabled is not true
     or v_policy.blocked_attempt_recording_enabled is not true then
    raise exception 'MIGRATION_129_PASSIVE_CAPABILITY_ASSERTION_FAILED';
  end if;

  if v_policy.automatic_dispatch_enabled
     or v_policy.endpoint_discovery_enabled
     or v_policy.backend_probe_enabled
     or v_policy.backend_contact_enabled
     or v_policy.backend_authentication_enabled
     or v_policy.secret_lookup_enabled
     or v_policy.secret_resolution_enabled
     or v_policy.secret_decryption_enabled
     or v_policy.credential_material_loading_enabled
     or v_policy.credential_delivery_enabled
     or v_policy.network_access_enabled then
    raise exception 'MIGRATION_129_SAFETY_POSTURE_ASSERTION_FAILED';
  end if;

  raise notice
    'MIGRATION_129_CERTIFIED policy_count=%, request_count=%, idempotency_count=%, candidate_count=%, decision_count=%, manifest_count=%, attempt_count=%, receipt_count=%, event_count=%, intake_enabled=%, idempotency_enabled=%, policy_evaluation_enabled=%, binding_selection_enabled=%, namespace_validation_enabled=%, capability_validation_enabled=%, route_manifest_generation_enabled=%, blocked_attempt_recording_enabled=%, automatic_dispatch_enabled=%, endpoint_discovery_enabled=%, backend_probe_enabled=%, backend_contact_enabled=%, backend_authentication_enabled=%, secret_lookup_enabled=%, secret_resolution_enabled=%, secret_decryption_enabled=%, credential_material_loading_enabled=%, credential_delivery_enabled=%, network_access_enabled=%, opaque_references_only=true, plaintext_storage_forbidden=true',
    v_policy_count,v_request_count,v_idempotency_count,v_candidate_count,
    v_decision_count,v_manifest_count,v_attempt_count,v_receipt_count,
    v_event_count,v_policy.intake_enabled,v_policy.idempotency_enabled,
    v_policy.policy_evaluation_enabled,v_policy.binding_selection_enabled,
    v_policy.namespace_validation_enabled,v_policy.capability_validation_enabled,
    v_policy.route_manifest_generation_enabled,
    v_policy.blocked_attempt_recording_enabled,
    v_policy.automatic_dispatch_enabled,v_policy.endpoint_discovery_enabled,
    v_policy.backend_probe_enabled,v_policy.backend_contact_enabled,
    v_policy.backend_authentication_enabled,v_policy.secret_lookup_enabled,
    v_policy.secret_resolution_enabled,v_policy.secret_decryption_enabled,
    v_policy.credential_material_loading_enabled,
    v_policy.credential_delivery_enabled,v_policy.network_access_enabled;
end
$$;

commit;
