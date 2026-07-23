-- =============================================================================
-- FANTAGOL
-- Migration: 117_commercial_provider_adapter_contract_foundation.sql
-- Milestone: Commercial Platform - Provider Adapter Contract Foundation
--
-- Purpose:
--   - Define the canonical, provider-independent adapter contract
--   - Version adapter schemas and operation envelopes immutably
--   - Normalize provider errors into stable FantaGol error categories
--   - Bind commercial providers to approved adapter versions passively
--   - Validate structural readiness without dispatching provider operations
--   - Record an append-only adapter governance timeline
--
-- Safety guarantees:
--   - No provider API is called
--   - No HTTP request is emitted
--   - No credential or secret is stored
--   - No checkout request is dispatched
--   - No callback is processed
--   - No purchase is confirmed or refunded
--   - No wallet, ledger or outbox mutation is generated
--   - No adapter binding becomes active automatically
--   - No frontend role receives write access
-- =============================================================================

begin;

create extension if not exists pgcrypto;

-- =============================================================================
-- 0. DEPENDENCY ASSERTIONS
-- =============================================================================

do $$
begin
  if to_regclass('public.commercial_providers') is null
     or to_regclass('public.commercial_provider_capabilities') is null
     or to_regclass('public.commercial_provider_versions') is null then
    raise exception using
      errcode = 'P0001',
      message = 'MIGRATION_117_REQUIRES_COMMERCIAL_PROVIDER_REGISTRY_FOUNDATION';
  end if;

  if to_regclass('public.commercial_checkout_orchestration_policies') is null
     or to_regclass('public.commercial_checkout_sessions') is null
     or to_regclass('public.commercial_checkout_provider_requests') is null
     or to_regclass('public.commercial_checkout_callbacks') is null then
    raise exception using
      errcode = 'P0001',
      message = 'MIGRATION_117_REQUIRES_CHECKOUT_ORCHESTRATION_FOUNDATION';
  end if;
end
$$;

-- =============================================================================
-- 1. ADAPTER GOVERNANCE POLICIES
-- =============================================================================

create table public.commercial_provider_adapter_policies (
  id uuid primary key default gen_random_uuid(),
  policy_code text not null,
  version_number integer not null,
  policy_status text not null default 'draft',
  environment text not null default 'test',

  adapter_execution_enabled boolean not null default false,
  network_access_enabled boolean not null default false,
  credential_resolution_enabled boolean not null default false,
  callback_verification_enabled boolean not null default false,
  automatic_binding_activation_enabled boolean not null default false,

  maximum_request_payload_bytes integer not null default 65536,
  maximum_response_payload_bytes integer not null default 262144,
  operation_timeout_ms integer not null default 15000,

  configuration jsonb not null default '{}'::jsonb,
  content_hash text not null,
  created_by text not null,
  approved_by text,
  approved_at timestamptz,
  retired_at timestamptz,
  created_at timestamptz not null default clock_timestamp(),

  constraint comm_adapter_policies_unique
    unique (policy_code, version_number, environment),

  constraint comm_adapter_policies_code_check
    check (
      policy_code = upper(policy_code)
      and policy_code ~ '^[A-Z][A-Z0-9_]{2,95}$'
    ),

  constraint comm_adapter_policies_version_check
    check (version_number > 0),

  constraint comm_adapter_policies_status_check
    check (policy_status in ('draft','approved','retired')),

  constraint comm_adapter_policies_environment_check
    check (environment in ('test','production')),

  constraint comm_adapter_policies_limits_check
    check (
      maximum_request_payload_bytes between 1024 and 1048576
      and maximum_response_payload_bytes between 1024 and 4194304
      and operation_timeout_ms between 1000 and 120000
    ),

  constraint comm_adapter_policies_configuration_check
    check (jsonb_typeof(configuration) = 'object'),

  constraint comm_adapter_policies_hash_check
    check (content_hash ~ '^[a-f0-9]{64}$'),

  constraint comm_adapter_policies_created_by_check
    check (length(btrim(created_by)) between 1 and 160),

  constraint comm_adapter_policies_approval_check
    check (
      (policy_status = 'draft' and approved_at is null and approved_by is null)
      or
      (policy_status <> 'draft' and approved_at is not null and approved_by is not null)
    )
);

create unique index comm_adapter_policies_one_approved_idx
  on public.commercial_provider_adapter_policies (policy_code, environment)
  where policy_status = 'approved';

comment on table public.commercial_provider_adapter_policies is
'Governance policy for provider adapter contracts. Migration 117 keeps all execution, network and credential resolution capabilities disabled.';

-- =============================================================================
-- 2. CANONICAL ADAPTER CONTRACTS
-- =============================================================================

create table public.commercial_provider_adapter_contracts (
  id uuid primary key default gen_random_uuid(),
  adapter_key text not null unique,
  display_name text not null,
  adapter_family text not null,
  contract_status text not null default 'draft',
  protocol_name text not null default 'FANTAGOL_PROVIDER_ADAPTER',
  protocol_major_version integer not null default 1,

  execution_mode text not null default 'passive',
  implementation_location text not null default 'backend_only',
  secrets_location text not null default 'external_secret_manager',

  current_approved_version_id uuid,
  metadata jsonb not null default '{}'::jsonb,
  created_by text not null,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),

  constraint comm_adapter_contracts_key_check
    check (
      adapter_key = lower(adapter_key)
      and adapter_key ~ '^[a-z][a-z0-9_]{2,95}$'
    ),

  constraint comm_adapter_contracts_name_check
    check (length(btrim(display_name)) between 1 and 160),

  constraint comm_adapter_contracts_family_check
    check (adapter_family in (
      'payment_gateway',
      'mobile_store',
      'advertising_network',
      'sponsor',
      'partner',
      'marketplace',
      'generic'
    )),

  constraint comm_adapter_contracts_status_check
    check (contract_status in ('draft','approved','suspended','retired')),

  constraint comm_adapter_contracts_protocol_check
    check (
      protocol_name = 'FANTAGOL_PROVIDER_ADAPTER'
      and protocol_major_version > 0
    ),

  constraint comm_adapter_contracts_execution_check
    check (execution_mode in ('passive','enabled')),

  constraint comm_adapter_contracts_location_check
    check (implementation_location = 'backend_only'),

  constraint comm_adapter_contracts_secret_check
    check (secrets_location = 'external_secret_manager'),

  constraint comm_adapter_contracts_metadata_check
    check (jsonb_typeof(metadata) = 'object'),

  constraint comm_adapter_contracts_created_by_check
    check (length(btrim(created_by)) between 1 and 160),

  constraint comm_adapter_contracts_foundation_hold_check
    check (execution_mode = 'passive')
);

create index comm_adapter_contracts_lookup_idx
  on public.commercial_provider_adapter_contracts
  (adapter_family, contract_status, adapter_key);

comment on table public.commercial_provider_adapter_contracts is
'Provider-independent adapter identity and protocol boundary. Implementations are backend-only and passive in migration 117.';

-- =============================================================================
-- 3. IMMUTABLE ADAPTER CONTRACT VERSIONS
-- =============================================================================

create table public.commercial_provider_adapter_versions (
  id uuid primary key default gen_random_uuid(),
  adapter_contract_id uuid not null,
  version_number integer not null,
  version_status text not null default 'draft',

  request_envelope_schema jsonb not null,
  response_envelope_schema jsonb not null,
  callback_envelope_schema jsonb not null,
  error_envelope_schema jsonb not null,

  contract_snapshot jsonb not null,
  content_hash text not null,
  change_summary text,
  created_by text not null,
  approved_by text,
  approved_at timestamptz,
  superseded_at timestamptz,
  retired_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp(),

  constraint comm_adapter_versions_contract_fkey
    foreign key (adapter_contract_id)
    references public.commercial_provider_adapter_contracts(id)
    on delete restrict,

  constraint comm_adapter_versions_unique
    unique (adapter_contract_id, version_number),

  constraint comm_adapter_versions_number_check
    check (version_number > 0),

  constraint comm_adapter_versions_status_check
    check (version_status in ('draft','approved','superseded','retired')),

  constraint comm_adapter_versions_schemas_check
    check (
      jsonb_typeof(request_envelope_schema) = 'object'
      and jsonb_typeof(response_envelope_schema) = 'object'
      and jsonb_typeof(callback_envelope_schema) = 'object'
      and jsonb_typeof(error_envelope_schema) = 'object'
      and jsonb_typeof(contract_snapshot) = 'object'
      and jsonb_typeof(metadata) = 'object'
    ),

  constraint comm_adapter_versions_hash_check
    check (content_hash ~ '^[a-f0-9]{64}$'),

  constraint comm_adapter_versions_created_by_check
    check (length(btrim(created_by)) between 1 and 160),

  constraint comm_adapter_versions_approval_check
    check (
      (version_status = 'draft' and approved_at is null and approved_by is null)
      or
      (version_status <> 'draft' and approved_at is not null and approved_by is not null)
    )
);

alter table public.commercial_provider_adapter_contracts
  add constraint comm_adapter_contracts_current_version_fkey
  foreign key (current_approved_version_id)
  references public.commercial_provider_adapter_versions(id)
  on delete restrict;

create unique index comm_adapter_versions_one_approved_idx
  on public.commercial_provider_adapter_versions(adapter_contract_id)
  where version_status = 'approved';

create index comm_adapter_versions_contract_idx
  on public.commercial_provider_adapter_versions
  (adapter_contract_id, version_number desc);

comment on table public.commercial_provider_adapter_versions is
'Immutable adapter protocol snapshots. They contain schemas and non-secret contract metadata only.';

-- =============================================================================
-- 4. CANONICAL ADAPTER OPERATIONS
-- =============================================================================

create table public.commercial_provider_adapter_operations (
  id uuid primary key default gen_random_uuid(),
  adapter_version_id uuid not null,
  operation_code text not null,
  operation_status text not null default 'declared',

  direction text not null,
  semantic_kind text not null,
  idempotency_required boolean not null default true,
  callback_driven boolean not null default false,
  supports_retrieval boolean not null default false,

  request_schema jsonb not null default '{}'::jsonb,
  response_schema jsonb not null default '{}'::jsonb,
  timeout_ms integer not null default 15000,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp(),

  constraint comm_adapter_operations_version_fkey
    foreign key (adapter_version_id)
    references public.commercial_provider_adapter_versions(id)
    on delete restrict,

  constraint comm_adapter_operations_unique
    unique (adapter_version_id, operation_code),

  constraint comm_adapter_operations_code_check
    check (
      operation_code = upper(operation_code)
      and operation_code ~ '^[A-Z][A-Z0-9_]{2,95}$'
    ),

  constraint comm_adapter_operations_status_check
    check (operation_status in ('declared','certified','suspended','retired')),

  constraint comm_adapter_operations_direction_check
    check (direction in ('outbound','inbound','bidirectional')),

  constraint comm_adapter_operations_kind_check
    check (semantic_kind in (
      'create_checkout',
      'retrieve_checkout',
      'cancel_checkout',
      'retrieve_payment',
      'retrieve_refund',
      'verify_callback',
      'normalize_callback',
      'health_check',
      'other'
    )),

  constraint comm_adapter_operations_schema_check
    check (
      jsonb_typeof(request_schema) = 'object'
      and jsonb_typeof(response_schema) = 'object'
      and jsonb_typeof(metadata) = 'object'
    ),

  constraint comm_adapter_operations_timeout_check
    check (timeout_ms between 1000 and 120000)
);

create index comm_adapter_operations_lookup_idx
  on public.commercial_provider_adapter_operations
  (adapter_version_id, operation_status, operation_code);

comment on table public.commercial_provider_adapter_operations is
'Canonical operation declarations. Rows describe contracts only and do not authorize execution.';

-- =============================================================================
-- 5. NORMALIZED ERROR MAPPINGS
-- =============================================================================

create table public.commercial_provider_adapter_error_mappings (
  id uuid primary key default gen_random_uuid(),
  adapter_version_id uuid not null,
  provider_error_code text not null,
  normalized_error_code text not null,
  error_category text not null,
  retry_class text not null default 'never',
  severity text not null default 'error',
  customer_safe_message_key text,
  mapping_status text not null default 'draft',
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp(),

  constraint comm_adapter_errors_version_fkey
    foreign key (adapter_version_id)
    references public.commercial_provider_adapter_versions(id)
    on delete restrict,

  constraint comm_adapter_errors_unique
    unique (adapter_version_id, provider_error_code),

  constraint comm_adapter_errors_provider_code_check
    check (length(btrim(provider_error_code)) between 1 and 160),

  constraint comm_adapter_errors_normalized_code_check
    check (
      normalized_error_code = upper(normalized_error_code)
      and normalized_error_code ~ '^COMMERCIAL_PROVIDER_[A-Z0-9_]{3,95}$'
    ),

  constraint comm_adapter_errors_category_check
    check (error_category in (
      'authentication',
      'authorization',
      'validation',
      'idempotency',
      'rate_limit',
      'timeout',
      'network',
      'provider_unavailable',
      'payment_declined',
      'payment_pending',
      'not_found',
      'conflict',
      'callback_verification',
      'configuration',
      'unknown'
    )),

  constraint comm_adapter_errors_retry_check
    check (retry_class in ('never','immediate','backoff','manual_review')),

  constraint comm_adapter_errors_severity_check
    check (severity in ('info','warning','error','critical')),

  constraint comm_adapter_errors_status_check
    check (mapping_status in ('draft','approved','retired')),

  constraint comm_adapter_errors_metadata_check
    check (jsonb_typeof(metadata) = 'object')
);

create index comm_adapter_errors_lookup_idx
  on public.commercial_provider_adapter_error_mappings
  (adapter_version_id, normalized_error_code, mapping_status);

comment on table public.commercial_provider_adapter_error_mappings is
'Stable mapping from provider-specific errors to canonical FantaGol commercial error categories.';

-- =============================================================================
-- 6. PASSIVE PROVIDER-ADAPTER BINDINGS
-- =============================================================================

create table public.commercial_provider_adapter_bindings (
  id uuid primary key default gen_random_uuid(),
  provider_id uuid not null,
  provider_version_id uuid,
  adapter_contract_id uuid not null,
  adapter_version_id uuid not null,
  policy_id uuid not null,

  binding_status text not null default 'draft',
  readiness_status text not null default 'not_evaluated',
  readiness_report jsonb not null default '{}'::jsonb,
  evaluated_at timestamptz,
  evaluated_by text,

  activation_requested_at timestamptz,
  activated_at timestamptz,
  activated_by text,
  suspended_at timestamptz,
  retired_at timestamptz,

  configuration jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),

  constraint comm_adapter_bindings_provider_fkey
    foreign key (provider_id)
    references public.commercial_providers(id)
    on delete restrict,

  constraint comm_adapter_bindings_provider_version_fkey
    foreign key (provider_version_id)
    references public.commercial_provider_versions(id)
    on delete restrict,

  constraint comm_adapter_bindings_contract_fkey
    foreign key (adapter_contract_id)
    references public.commercial_provider_adapter_contracts(id)
    on delete restrict,

  constraint comm_adapter_bindings_version_fkey
    foreign key (adapter_version_id)
    references public.commercial_provider_adapter_versions(id)
    on delete restrict,

  constraint comm_adapter_bindings_policy_fkey
    foreign key (policy_id)
    references public.commercial_provider_adapter_policies(id)
    on delete restrict,

  constraint comm_adapter_bindings_unique
    unique (provider_id, adapter_contract_id),

  constraint comm_adapter_bindings_status_check
    check (binding_status in (
      'draft','validated','activation_requested',
      'active','suspended','retired'
    )),

  constraint comm_adapter_bindings_readiness_check
    check (readiness_status in ('not_evaluated','ready','blocked','attention')),

  constraint comm_adapter_bindings_json_check
    check (
      jsonb_typeof(readiness_report) = 'object'
      and jsonb_typeof(configuration) = 'object'
      and jsonb_typeof(metadata) = 'object'
    ),

  constraint comm_adapter_bindings_activation_check
    check (
      (binding_status = 'active' and activated_at is not null and activated_by is not null)
      or
      (binding_status <> 'active')
    ),

  constraint comm_adapter_bindings_foundation_hold_check
    check (binding_status in ('draft','validated','activation_requested','suspended','retired'))
);

create index comm_adapter_bindings_lookup_idx
  on public.commercial_provider_adapter_bindings
  (provider_id, binding_status, readiness_status);

comment on table public.commercial_provider_adapter_bindings is
'Passive provider-to-adapter binding. Migration 117 structurally forbids active bindings.';

-- =============================================================================
-- 7. VALIDATION RECORDS
-- =============================================================================

create table public.commercial_provider_adapter_validations (
  id uuid primary key default gen_random_uuid(),
  adapter_contract_id uuid not null,
  adapter_version_id uuid not null,
  provider_id uuid,
  binding_id uuid,
  validation_status text not null,
  validation_scope text not null default 'structural',
  checks jsonb not null default '[]'::jsonb,
  failures jsonb not null default '[]'::jsonb,
  warnings jsonb not null default '[]'::jsonb,
  validated_by text not null,
  validated_at timestamptz not null default clock_timestamp(),
  correlation_id uuid not null default gen_random_uuid(),
  metadata jsonb not null default '{}'::jsonb,

  constraint comm_adapter_validations_contract_fkey
    foreign key (adapter_contract_id)
    references public.commercial_provider_adapter_contracts(id)
    on delete restrict,

  constraint comm_adapter_validations_version_fkey
    foreign key (adapter_version_id)
    references public.commercial_provider_adapter_versions(id)
    on delete restrict,

  constraint comm_adapter_validations_provider_fkey
    foreign key (provider_id)
    references public.commercial_providers(id)
    on delete set null,

  constraint comm_adapter_validations_binding_fkey
    foreign key (binding_id)
    references public.commercial_provider_adapter_bindings(id)
    on delete set null,

  constraint comm_adapter_validations_status_check
    check (validation_status in ('passed','failed','attention')),

  constraint comm_adapter_validations_scope_check
    check (validation_scope in ('structural','binding','certification')),

  constraint comm_adapter_validations_json_check
    check (
      jsonb_typeof(checks) = 'array'
      and jsonb_typeof(failures) = 'array'
      and jsonb_typeof(warnings) = 'array'
      and jsonb_typeof(metadata) = 'object'
    ),

  constraint comm_adapter_validations_actor_check
    check (length(btrim(validated_by)) between 1 and 160)
);

create index comm_adapter_validations_timeline_idx
  on public.commercial_provider_adapter_validations
  (adapter_contract_id, validated_at desc, id);

comment on table public.commercial_provider_adapter_validations is
'Append-only evidence from structural adapter and binding validation. No network execution is performed.';

-- =============================================================================
-- 8. APPEND-ONLY GOVERNANCE EVENTS
-- =============================================================================

create table public.commercial_provider_adapter_events (
  id uuid primary key default gen_random_uuid(),
  event_type text not null,
  adapter_contract_id uuid,
  adapter_version_id uuid,
  operation_id uuid,
  error_mapping_id uuid,
  provider_id uuid,
  binding_id uuid,
  validation_id uuid,
  previous_state text,
  next_state text,
  actor text not null,
  reason text,
  correlation_id uuid not null default gen_random_uuid(),
  causation_id uuid,
  payload jsonb not null default '{}'::jsonb,
  occurred_at timestamptz not null default clock_timestamp(),

  constraint comm_adapter_events_contract_fkey
    foreign key (adapter_contract_id)
    references public.commercial_provider_adapter_contracts(id)
    on delete set null,

  constraint comm_adapter_events_version_fkey
    foreign key (adapter_version_id)
    references public.commercial_provider_adapter_versions(id)
    on delete set null,

  constraint comm_adapter_events_operation_fkey
    foreign key (operation_id)
    references public.commercial_provider_adapter_operations(id)
    on delete set null,

  constraint comm_adapter_events_error_fkey
    foreign key (error_mapping_id)
    references public.commercial_provider_adapter_error_mappings(id)
    on delete set null,

  constraint comm_adapter_events_provider_fkey
    foreign key (provider_id)
    references public.commercial_providers(id)
    on delete set null,

  constraint comm_adapter_events_binding_fkey
    foreign key (binding_id)
    references public.commercial_provider_adapter_bindings(id)
    on delete set null,

  constraint comm_adapter_events_validation_fkey
    foreign key (validation_id)
    references public.commercial_provider_adapter_validations(id)
    on delete set null,

  constraint comm_adapter_events_type_check
    check (
      event_type = upper(event_type)
      and event_type ~ '^[A-Z][A-Z0-9_]{2,127}$'
    ),

  constraint comm_adapter_events_actor_check
    check (length(btrim(actor)) between 1 and 160),

  constraint comm_adapter_events_payload_check
    check (jsonb_typeof(payload) = 'object')
);

create index comm_adapter_events_timeline_idx
  on public.commercial_provider_adapter_events
  (adapter_contract_id, occurred_at, id);

comment on table public.commercial_provider_adapter_events is
'Append-only provider adapter governance and validation timeline.';

-- =============================================================================
-- 9. IMMUTABILITY AND UPDATED_AT GUARDS
-- =============================================================================

create or replace function public.protect_commercial_provider_adapter_policy_internal()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if old.policy_status in ('approved','retired') then
    raise exception using
      errcode = '55000',
      message = 'COMMERCIAL_PROVIDER_ADAPTER_POLICY_IMMUTABLE';
  end if;

  return new;
end
$$;

create or replace function public.protect_commercial_provider_adapter_version_internal()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if old.version_status in ('approved','superseded','retired') then
    raise exception using
      errcode = '55000',
      message = 'COMMERCIAL_PROVIDER_ADAPTER_VERSION_IMMUTABLE';
  end if;

  return new;
end
$$;

create or replace function public.protect_commercial_provider_adapter_validation_internal()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  raise exception using
    errcode = '55000',
    message = 'COMMERCIAL_PROVIDER_ADAPTER_VALIDATION_APPEND_ONLY';
end
$$;

create or replace function public.protect_commercial_provider_adapter_event_internal()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  raise exception using
    errcode = '55000',
    message = 'COMMERCIAL_PROVIDER_ADAPTER_EVENT_APPEND_ONLY';
end
$$;

create or replace function public.set_commercial_provider_adapter_updated_at_internal()
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

create trigger comm_adapter_policies_immutability_trg
before update or delete on public.commercial_provider_adapter_policies
for each row execute function public.protect_commercial_provider_adapter_policy_internal();

create trigger comm_adapter_versions_immutability_trg
before update or delete on public.commercial_provider_adapter_versions
for each row execute function public.protect_commercial_provider_adapter_version_internal();

create trigger comm_adapter_validations_append_only_trg
before update or delete on public.commercial_provider_adapter_validations
for each row execute function public.protect_commercial_provider_adapter_validation_internal();

create trigger comm_adapter_events_append_only_trg
before update or delete on public.commercial_provider_adapter_events
for each row execute function public.protect_commercial_provider_adapter_event_internal();

create trigger comm_adapter_contracts_updated_at_trg
before update on public.commercial_provider_adapter_contracts
for each row execute function public.set_commercial_provider_adapter_updated_at_internal();

create trigger comm_adapter_bindings_updated_at_trg
before update on public.commercial_provider_adapter_bindings
for each row execute function public.set_commercial_provider_adapter_updated_at_internal();

-- =============================================================================
-- 10. INTERNAL FUNCTIONS
-- =============================================================================

create or replace function public.append_commercial_provider_adapter_event_internal(
  p_event_type text,
  p_actor text,
  p_adapter_contract_id uuid default null,
  p_adapter_version_id uuid default null,
  p_operation_id uuid default null,
  p_error_mapping_id uuid default null,
  p_provider_id uuid default null,
  p_binding_id uuid default null,
  p_validation_id uuid default null,
  p_previous_state text default null,
  p_next_state text default null,
  p_reason text default null,
  p_correlation_id uuid default null,
  p_causation_id uuid default null,
  p_payload jsonb default '{}'::jsonb
)
returns public.commercial_provider_adapter_events
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_result public.commercial_provider_adapter_events;
begin
  insert into public.commercial_provider_adapter_events (
    event_type,
    adapter_contract_id,
    adapter_version_id,
    operation_id,
    error_mapping_id,
    provider_id,
    binding_id,
    validation_id,
    previous_state,
    next_state,
    actor,
    reason,
    correlation_id,
    causation_id,
    payload
  ) values (
    upper(btrim(p_event_type)),
    p_adapter_contract_id,
    p_adapter_version_id,
    p_operation_id,
    p_error_mapping_id,
    p_provider_id,
    p_binding_id,
    p_validation_id,
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
end
$$;

create or replace function public.register_commercial_provider_adapter_contract_internal(
  p_adapter_key text,
  p_display_name text,
  p_adapter_family text,
  p_created_by text,
  p_metadata jsonb default '{}'::jsonb
)
returns public.commercial_provider_adapter_contracts
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_result public.commercial_provider_adapter_contracts;
begin
  insert into public.commercial_provider_adapter_contracts (
    adapter_key,
    display_name,
    adapter_family,
    contract_status,
    protocol_name,
    protocol_major_version,
    execution_mode,
    implementation_location,
    secrets_location,
    metadata,
    created_by
  ) values (
    lower(btrim(p_adapter_key)),
    btrim(p_display_name),
    p_adapter_family,
    'draft',
    'FANTAGOL_PROVIDER_ADAPTER',
    1,
    'passive',
    'backend_only',
    'external_secret_manager',
    coalesce(p_metadata, '{}'::jsonb),
    btrim(p_created_by)
  )
  returning * into v_result;

  perform public.append_commercial_provider_adapter_event_internal(
    'ADAPTER_CONTRACT_REGISTERED',
    p_created_by,
    v_result.id,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    'draft',
    'Provider adapter contract registered',
    null,
    null,
    jsonb_build_object(
      'adapter_key', v_result.adapter_key,
      'adapter_family', v_result.adapter_family,
      'execution_mode', v_result.execution_mode
    )
  );

  return v_result;
end
$$;

create or replace function public.create_commercial_provider_adapter_version_internal(
  p_adapter_contract_id uuid,
  p_request_envelope_schema jsonb,
  p_response_envelope_schema jsonb,
  p_callback_envelope_schema jsonb,
  p_error_envelope_schema jsonb,
  p_change_summary text,
  p_created_by text,
  p_metadata jsonb default '{}'::jsonb
)
returns public.commercial_provider_adapter_versions
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_contract public.commercial_provider_adapter_contracts;
  v_next_version integer;
  v_snapshot jsonb;
  v_result public.commercial_provider_adapter_versions;
begin
  select *
  into strict v_contract
  from public.commercial_provider_adapter_contracts
  where id = p_adapter_contract_id
  for update;

  if v_contract.contract_status in ('suspended','retired') then
    raise exception 'COMMERCIAL_PROVIDER_ADAPTER_CONTRACT_NOT_VERSIONABLE';
  end if;

  select coalesce(max(version_number), 0) + 1
  into v_next_version
  from public.commercial_provider_adapter_versions
  where adapter_contract_id = p_adapter_contract_id;

  v_snapshot := jsonb_build_object(
    'adapter_key', v_contract.adapter_key,
    'protocol_name', v_contract.protocol_name,
    'protocol_major_version', v_contract.protocol_major_version,
    'execution_mode', v_contract.execution_mode,
    'request_envelope_schema', coalesce(p_request_envelope_schema, '{}'::jsonb),
    'response_envelope_schema', coalesce(p_response_envelope_schema, '{}'::jsonb),
    'callback_envelope_schema', coalesce(p_callback_envelope_schema, '{}'::jsonb),
    'error_envelope_schema', coalesce(p_error_envelope_schema, '{}'::jsonb)
  );

  insert into public.commercial_provider_adapter_versions (
    adapter_contract_id,
    version_number,
    version_status,
    request_envelope_schema,
    response_envelope_schema,
    callback_envelope_schema,
    error_envelope_schema,
    contract_snapshot,
    content_hash,
    change_summary,
    created_by,
    metadata
  ) values (
    p_adapter_contract_id,
    v_next_version,
    'draft',
    coalesce(p_request_envelope_schema, '{}'::jsonb),
    coalesce(p_response_envelope_schema, '{}'::jsonb),
    coalesce(p_callback_envelope_schema, '{}'::jsonb),
    coalesce(p_error_envelope_schema, '{}'::jsonb),
    v_snapshot,
    encode(digest(v_snapshot::text, 'sha256'), 'hex'),
    p_change_summary,
    btrim(p_created_by),
    coalesce(p_metadata, '{}'::jsonb)
  )
  returning * into v_result;

  perform public.append_commercial_provider_adapter_event_internal(
    'ADAPTER_VERSION_CREATED',
    p_created_by,
    p_adapter_contract_id,
    v_result.id,
    null,
    null,
    null,
    null,
    null,
    null,
    'draft',
    p_change_summary,
    null,
    null,
    jsonb_build_object(
      'version_number', v_result.version_number,
      'content_hash', v_result.content_hash
    )
  );

  return v_result;
end
$$;

create or replace function public.declare_commercial_provider_adapter_operation_internal(
  p_adapter_version_id uuid,
  p_operation_code text,
  p_direction text,
  p_semantic_kind text,
  p_idempotency_required boolean,
  p_callback_driven boolean,
  p_supports_retrieval boolean,
  p_request_schema jsonb,
  p_response_schema jsonb,
  p_timeout_ms integer,
  p_actor text,
  p_metadata jsonb default '{}'::jsonb
)
returns public.commercial_provider_adapter_operations
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_version public.commercial_provider_adapter_versions;
  v_result public.commercial_provider_adapter_operations;
begin
  select *
  into strict v_version
  from public.commercial_provider_adapter_versions
  where id = p_adapter_version_id;

  if v_version.version_status <> 'draft' then
    raise exception 'COMMERCIAL_PROVIDER_ADAPTER_VERSION_NOT_DRAFT';
  end if;

  insert into public.commercial_provider_adapter_operations (
    adapter_version_id,
    operation_code,
    operation_status,
    direction,
    semantic_kind,
    idempotency_required,
    callback_driven,
    supports_retrieval,
    request_schema,
    response_schema,
    timeout_ms,
    metadata
  ) values (
    p_adapter_version_id,
    upper(btrim(p_operation_code)),
    'declared',
    p_direction,
    p_semantic_kind,
    p_idempotency_required,
    p_callback_driven,
    p_supports_retrieval,
    coalesce(p_request_schema, '{}'::jsonb),
    coalesce(p_response_schema, '{}'::jsonb),
    p_timeout_ms,
    coalesce(p_metadata, '{}'::jsonb)
  )
  returning * into v_result;

  perform public.append_commercial_provider_adapter_event_internal(
    'ADAPTER_OPERATION_DECLARED',
    p_actor,
    v_version.adapter_contract_id,
    p_adapter_version_id,
    v_result.id,
    null,
    null,
    null,
    null,
    null,
    'declared',
    'Canonical adapter operation declared',
    null,
    null,
    jsonb_build_object(
      'operation_code', v_result.operation_code,
      'semantic_kind', v_result.semantic_kind,
      'direction', v_result.direction
    )
  );

  return v_result;
end
$$;

create or replace function public.map_commercial_provider_adapter_error_internal(
  p_adapter_version_id uuid,
  p_provider_error_code text,
  p_normalized_error_code text,
  p_error_category text,
  p_retry_class text,
  p_severity text,
  p_customer_safe_message_key text,
  p_actor text,
  p_metadata jsonb default '{}'::jsonb
)
returns public.commercial_provider_adapter_error_mappings
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_version public.commercial_provider_adapter_versions;
  v_result public.commercial_provider_adapter_error_mappings;
begin
  select *
  into strict v_version
  from public.commercial_provider_adapter_versions
  where id = p_adapter_version_id;

  if v_version.version_status <> 'draft' then
    raise exception 'COMMERCIAL_PROVIDER_ADAPTER_VERSION_NOT_DRAFT';
  end if;

  insert into public.commercial_provider_adapter_error_mappings (
    adapter_version_id,
    provider_error_code,
    normalized_error_code,
    error_category,
    retry_class,
    severity,
    customer_safe_message_key,
    mapping_status,
    metadata
  ) values (
    p_adapter_version_id,
    btrim(p_provider_error_code),
    upper(btrim(p_normalized_error_code)),
    p_error_category,
    p_retry_class,
    p_severity,
    p_customer_safe_message_key,
    'draft',
    coalesce(p_metadata, '{}'::jsonb)
  )
  returning * into v_result;

  perform public.append_commercial_provider_adapter_event_internal(
    'ADAPTER_ERROR_MAPPING_DECLARED',
    p_actor,
    v_version.adapter_contract_id,
    p_adapter_version_id,
    null,
    v_result.id,
    null,
    null,
    null,
    null,
    'draft',
    'Provider error mapping declared',
    null,
    null,
    jsonb_build_object(
      'provider_error_code', v_result.provider_error_code,
      'normalized_error_code', v_result.normalized_error_code,
      'retry_class', v_result.retry_class
    )
  );

  return v_result;
end
$$;

create or replace function public.validate_commercial_provider_adapter_version_internal(
  p_adapter_version_id uuid,
  p_actor text,
  p_metadata jsonb default '{}'::jsonb
)
returns public.commercial_provider_adapter_validations
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_version public.commercial_provider_adapter_versions;
  v_contract public.commercial_provider_adapter_contracts;
  v_operation_count bigint;
  v_duplicate_semantic_count bigint;
  v_failure_count integer := 0;
  v_warning_count integer := 0;
  v_checks jsonb := '[]'::jsonb;
  v_failures jsonb := '[]'::jsonb;
  v_warnings jsonb := '[]'::jsonb;
  v_status text;
  v_result public.commercial_provider_adapter_validations;
begin
  select *
  into strict v_version
  from public.commercial_provider_adapter_versions
  where id = p_adapter_version_id;

  select *
  into strict v_contract
  from public.commercial_provider_adapter_contracts
  where id = v_version.adapter_contract_id;

  select count(*)
  into v_operation_count
  from public.commercial_provider_adapter_operations
  where adapter_version_id = p_adapter_version_id
    and operation_status in ('declared','certified');

  select count(*)
  into v_duplicate_semantic_count
  from (
    select semantic_kind
    from public.commercial_provider_adapter_operations
    where adapter_version_id = p_adapter_version_id
      and semantic_kind <> 'other'
    group by semantic_kind
    having count(*) > 1
  ) d;

  v_checks := v_checks || jsonb_build_array(jsonb_build_object(
    'check', 'protocol_identity',
    'passed', v_contract.protocol_name = 'FANTAGOL_PROVIDER_ADAPTER'
      and v_contract.protocol_major_version > 0
  ));

  if v_contract.protocol_name <> 'FANTAGOL_PROVIDER_ADAPTER'
     or v_contract.protocol_major_version <= 0 then
    v_failure_count := v_failure_count + 1;
    v_failures := v_failures || jsonb_build_array(jsonb_build_object(
      'code', 'INVALID_PROTOCOL_IDENTITY'
    ));
  end if;

  v_checks := v_checks || jsonb_build_array(jsonb_build_object(
    'check', 'backend_only_implementation',
    'passed', v_contract.implementation_location = 'backend_only'
  ));

  if v_contract.implementation_location <> 'backend_only' then
    v_failure_count := v_failure_count + 1;
    v_failures := v_failures || jsonb_build_array(jsonb_build_object(
      'code', 'IMPLEMENTATION_NOT_BACKEND_ONLY'
    ));
  end if;

  v_checks := v_checks || jsonb_build_array(jsonb_build_object(
    'check', 'external_secret_manager',
    'passed', v_contract.secrets_location = 'external_secret_manager'
  ));

  if v_contract.secrets_location <> 'external_secret_manager' then
    v_failure_count := v_failure_count + 1;
    v_failures := v_failures || jsonb_build_array(jsonb_build_object(
      'code', 'INVALID_SECRET_LOCATION'
    ));
  end if;

  v_checks := v_checks || jsonb_build_array(jsonb_build_object(
    'check', 'operation_contract_present',
    'passed', v_operation_count > 0,
    'operation_count', v_operation_count
  ));

  if v_operation_count = 0 then
    v_failure_count := v_failure_count + 1;
    v_failures := v_failures || jsonb_build_array(jsonb_build_object(
      'code', 'NO_OPERATIONS_DECLARED'
    ));
  end if;

  v_checks := v_checks || jsonb_build_array(jsonb_build_object(
    'check', 'semantic_operation_uniqueness',
    'passed', v_duplicate_semantic_count = 0
  ));

  if v_duplicate_semantic_count > 0 then
    v_failure_count := v_failure_count + 1;
    v_failures := v_failures || jsonb_build_array(jsonb_build_object(
      'code', 'DUPLICATE_SEMANTIC_OPERATION'
    ));
  end if;

  if not exists (
    select 1
    from public.commercial_provider_adapter_error_mappings
    where adapter_version_id = p_adapter_version_id
  ) then
    v_warning_count := v_warning_count + 1;
    v_warnings := v_warnings || jsonb_build_array(jsonb_build_object(
      'code', 'NO_PROVIDER_ERROR_MAPPINGS'
    ));
  end if;

  v_status := case
    when v_failure_count > 0 then 'failed'
    when v_warning_count > 0 then 'attention'
    else 'passed'
  end;

  insert into public.commercial_provider_adapter_validations (
    adapter_contract_id,
    adapter_version_id,
    validation_status,
    validation_scope,
    checks,
    failures,
    warnings,
    validated_by,
    metadata
  ) values (
    v_contract.id,
    v_version.id,
    v_status,
    'structural',
    v_checks,
    v_failures,
    v_warnings,
    btrim(p_actor),
    coalesce(p_metadata, '{}'::jsonb)
  )
  returning * into v_result;

  perform public.append_commercial_provider_adapter_event_internal(
    'ADAPTER_VERSION_VALIDATED',
    p_actor,
    v_contract.id,
    v_version.id,
    null,
    null,
    null,
    null,
    v_result.id,
    v_version.version_status,
    v_status,
    'Structural adapter validation completed without provider execution',
    v_result.correlation_id,
    null,
    jsonb_build_object(
      'validation_status', v_status,
      'operation_count', v_operation_count,
      'failure_count', v_failure_count,
      'warning_count', v_warning_count,
      'network_accessed', false
    )
  );

  return v_result;
end
$$;

create or replace function public.approve_commercial_provider_adapter_version_internal(
  p_adapter_version_id uuid,
  p_actor text,
  p_reason text default null
)
returns public.commercial_provider_adapter_versions
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_version public.commercial_provider_adapter_versions;
  v_contract public.commercial_provider_adapter_contracts;
  v_validation public.commercial_provider_adapter_validations;
  v_result public.commercial_provider_adapter_versions;
begin
  select *
  into strict v_version
  from public.commercial_provider_adapter_versions
  where id = p_adapter_version_id
  for update;

  if v_version.version_status <> 'draft' then
    raise exception 'COMMERCIAL_PROVIDER_ADAPTER_VERSION_NOT_DRAFT';
  end if;

  select *
  into strict v_validation
  from public.commercial_provider_adapter_validations
  where adapter_version_id = p_adapter_version_id
  order by validated_at desc, id desc
  limit 1;

  if v_validation.validation_status <> 'passed' then
    raise exception 'COMMERCIAL_PROVIDER_ADAPTER_VERSION_NOT_VALIDATED';
  end if;

  update public.commercial_provider_adapter_versions
  set
    version_status = 'approved',
    approved_by = btrim(p_actor),
    approved_at = clock_timestamp()
  where id = p_adapter_version_id
  returning * into v_result;

  update public.commercial_provider_adapter_contracts
  set
    contract_status = 'approved',
    current_approved_version_id = v_result.id
  where id = v_result.adapter_contract_id
  returning * into v_contract;

  update public.commercial_provider_adapter_operations
  set operation_status = 'certified'
  where adapter_version_id = p_adapter_version_id
    and operation_status = 'declared';

  update public.commercial_provider_adapter_error_mappings
  set mapping_status = 'approved'
  where adapter_version_id = p_adapter_version_id
    and mapping_status = 'draft';

  perform public.append_commercial_provider_adapter_event_internal(
    'ADAPTER_VERSION_APPROVED',
    p_actor,
    v_contract.id,
    v_result.id,
    null,
    null,
    null,
    null,
    v_validation.id,
    'draft',
    'approved',
    p_reason,
    v_validation.correlation_id,
    v_validation.id,
    jsonb_build_object(
      'version_number', v_result.version_number,
      'execution_mode', v_contract.execution_mode,
      'network_accessed', false
    )
  );

  return v_result;
end
$$;

create or replace function public.create_commercial_provider_adapter_binding_internal(
  p_provider_id uuid,
  p_provider_version_id uuid,
  p_adapter_version_id uuid,
  p_policy_id uuid,
  p_actor text,
  p_configuration jsonb default '{}'::jsonb,
  p_metadata jsonb default '{}'::jsonb
)
returns public.commercial_provider_adapter_bindings
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_provider public.commercial_providers;
  v_version public.commercial_provider_adapter_versions;
  v_policy public.commercial_provider_adapter_policies;
  v_result public.commercial_provider_adapter_bindings;
begin
  select *
  into strict v_provider
  from public.commercial_providers
  where id = p_provider_id;

  select *
  into strict v_version
  from public.commercial_provider_adapter_versions
  where id = p_adapter_version_id;

  select *
  into strict v_policy
  from public.commercial_provider_adapter_policies
  where id = p_policy_id;

  if v_version.version_status <> 'approved' then
    raise exception 'COMMERCIAL_PROVIDER_ADAPTER_VERSION_NOT_APPROVED';
  end if;

  if v_policy.policy_status <> 'approved' then
    raise exception 'COMMERCIAL_PROVIDER_ADAPTER_POLICY_NOT_APPROVED';
  end if;

  if v_policy.adapter_execution_enabled
     or v_policy.network_access_enabled
     or v_policy.credential_resolution_enabled
     or v_policy.callback_verification_enabled
     or v_policy.automatic_binding_activation_enabled then
    raise exception 'COMMERCIAL_PROVIDER_ADAPTER_POLICY_UNSAFE_FOR_FOUNDATION';
  end if;

  if v_provider.integration_mode <> 'adapter'
     or v_provider.adapter_key is distinct from (
       select adapter_key
       from public.commercial_provider_adapter_contracts
       where id = v_version.adapter_contract_id
     ) then
    raise exception 'COMMERCIAL_PROVIDER_ADAPTER_KEY_MISMATCH';
  end if;

  insert into public.commercial_provider_adapter_bindings (
    provider_id,
    provider_version_id,
    adapter_contract_id,
    adapter_version_id,
    policy_id,
    binding_status,
    readiness_status,
    configuration,
    metadata
  ) values (
    p_provider_id,
    p_provider_version_id,
    v_version.adapter_contract_id,
    p_adapter_version_id,
    p_policy_id,
    'draft',
    'not_evaluated',
    coalesce(p_configuration, '{}'::jsonb),
    coalesce(p_metadata, '{}'::jsonb)
  )
  returning * into v_result;

  perform public.append_commercial_provider_adapter_event_internal(
    'ADAPTER_BINDING_CREATED',
    p_actor,
    v_result.adapter_contract_id,
    v_result.adapter_version_id,
    null,
    null,
    v_result.provider_id,
    v_result.id,
    null,
    null,
    'draft',
    'Passive provider adapter binding created',
    null,
    null,
    jsonb_build_object(
      'provider_code', v_provider.provider_code,
      'adapter_key', v_provider.adapter_key,
      'binding_status', v_result.binding_status
    )
  );

  return v_result;
end
$$;

create or replace function public.evaluate_commercial_provider_adapter_binding_internal(
  p_binding_id uuid,
  p_actor text
)
returns public.commercial_provider_adapter_bindings
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_binding public.commercial_provider_adapter_bindings;
  v_provider public.commercial_providers;
  v_contract public.commercial_provider_adapter_contracts;
  v_version public.commercial_provider_adapter_versions;
  v_policy public.commercial_provider_adapter_policies;
  v_blockers jsonb := '[]'::jsonb;
  v_readiness text;
  v_report jsonb;
  v_validation public.commercial_provider_adapter_validations;
  v_result public.commercial_provider_adapter_bindings;
begin
  select *
  into strict v_binding
  from public.commercial_provider_adapter_bindings
  where id = p_binding_id
  for update;

  select * into strict v_provider
  from public.commercial_providers
  where id = v_binding.provider_id;

  select * into strict v_contract
  from public.commercial_provider_adapter_contracts
  where id = v_binding.adapter_contract_id;

  select * into strict v_version
  from public.commercial_provider_adapter_versions
  where id = v_binding.adapter_version_id;

  select * into strict v_policy
  from public.commercial_provider_adapter_policies
  where id = v_binding.policy_id;

  select *
  into v_validation
  from public.commercial_provider_adapter_validations
  where adapter_version_id = v_binding.adapter_version_id
  order by validated_at desc, id desc
  limit 1;

  if v_provider.integration_mode <> 'adapter' then
    v_blockers := v_blockers || jsonb_build_array('PROVIDER_NOT_ADAPTER_MODE');
  end if;

  if v_provider.adapter_key is distinct from v_contract.adapter_key then
    v_blockers := v_blockers || jsonb_build_array('ADAPTER_KEY_MISMATCH');
  end if;

  if v_contract.contract_status <> 'approved'
     or v_version.version_status <> 'approved' then
    v_blockers := v_blockers || jsonb_build_array('ADAPTER_CONTRACT_NOT_APPROVED');
  end if;

  if v_policy.policy_status <> 'approved' then
    v_blockers := v_blockers || jsonb_build_array('ADAPTER_POLICY_NOT_APPROVED');
  end if;

  if v_validation.id is null or v_validation.validation_status <> 'passed' then
    v_blockers := v_blockers || jsonb_build_array('ADAPTER_VALIDATION_NOT_PASSED');
  end if;

  if not exists (
    select 1
    from public.commercial_provider_adapter_operations
    where adapter_version_id = v_binding.adapter_version_id
      and operation_status = 'certified'
  ) then
    v_blockers := v_blockers || jsonb_build_array('NO_CERTIFIED_OPERATIONS');
  end if;

  v_readiness := case
    when jsonb_array_length(v_blockers) = 0 then 'ready'
    else 'blocked'
  end;

  v_report := jsonb_build_object(
    'provider_code', v_provider.provider_code,
    'adapter_key', v_contract.adapter_key,
    'adapter_version', v_version.version_number,
    'readiness_status', v_readiness,
    'blockers', v_blockers,
    'execution_enabled', false,
    'network_access_enabled', false,
    'credential_resolution_enabled', false,
    'validated_without_provider_call', true
  );

  update public.commercial_provider_adapter_bindings
  set
    binding_status = case
      when v_readiness = 'ready' then 'validated'
      else 'draft'
    end,
    readiness_status = v_readiness,
    readiness_report = v_report,
    evaluated_at = clock_timestamp(),
    evaluated_by = btrim(p_actor)
  where id = p_binding_id
  returning * into v_result;

  perform public.append_commercial_provider_adapter_event_internal(
    'ADAPTER_BINDING_READINESS_EVALUATED',
    p_actor,
    v_result.adapter_contract_id,
    v_result.adapter_version_id,
    null,
    null,
    v_result.provider_id,
    v_result.id,
    v_validation.id,
    v_binding.readiness_status,
    v_result.readiness_status,
    'Passive adapter binding readiness evaluated',
    null,
    null,
    v_report
  );

  return v_result;
end
$$;

create or replace function public.get_commercial_provider_adapter_contract_internal(
  p_adapter_contract_id uuid
)
returns jsonb
language sql
security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'contract', to_jsonb(c),
    'versions', coalesce((
      select jsonb_agg(to_jsonb(v) order by v.version_number desc)
      from public.commercial_provider_adapter_versions v
      where v.adapter_contract_id = c.id
    ), '[]'::jsonb),
    'operations', coalesce((
      select jsonb_agg(to_jsonb(o) order by o.operation_code)
      from public.commercial_provider_adapter_operations o
      join public.commercial_provider_adapter_versions v
        on v.id = o.adapter_version_id
      where v.adapter_contract_id = c.id
    ), '[]'::jsonb),
    'error_mappings', coalesce((
      select jsonb_agg(to_jsonb(e) order by e.provider_error_code)
      from public.commercial_provider_adapter_error_mappings e
      join public.commercial_provider_adapter_versions v
        on v.id = e.adapter_version_id
      where v.adapter_contract_id = c.id
    ), '[]'::jsonb),
    'bindings', coalesce((
      select jsonb_agg(to_jsonb(b) order by b.created_at, b.id)
      from public.commercial_provider_adapter_bindings b
      where b.adapter_contract_id = c.id
    ), '[]'::jsonb),
    'validations', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.validated_at, x.id)
      from public.commercial_provider_adapter_validations x
      where x.adapter_contract_id = c.id
    ), '[]'::jsonb),
    'events', coalesce((
      select jsonb_agg(to_jsonb(ev) order by ev.occurred_at, ev.id)
      from public.commercial_provider_adapter_events ev
      where ev.adapter_contract_id = c.id
    ), '[]'::jsonb)
  )
  from public.commercial_provider_adapter_contracts c
  where c.id = p_adapter_contract_id;
$$;

-- =============================================================================
-- 11. DEFAULT PASSIVE POLICY
-- =============================================================================

insert into public.commercial_provider_adapter_policies (
  policy_code,
  version_number,
  policy_status,
  environment,
  adapter_execution_enabled,
  network_access_enabled,
  credential_resolution_enabled,
  callback_verification_enabled,
  automatic_binding_activation_enabled,
  maximum_request_payload_bytes,
  maximum_response_payload_bytes,
  operation_timeout_ms,
  configuration,
  content_hash,
  created_by
) values (
  'DEFAULT_PROVIDER_ADAPTER_CONTRACT',
  1,
  'draft',
  'test',
  false,
  false,
  false,
  false,
  false,
  65536,
  262144,
  15000,
  jsonb_build_object(
    'protocol', 'FANTAGOL_PROVIDER_ADAPTER',
    'mode', 'passive',
    'provider_dispatch', 'disabled',
    'network_access', 'disabled',
    'credential_resolution', 'disabled',
    'callback_verification', 'disabled',
    'automatic_activation', 'disabled',
    'economic_mutation', 'forbidden'
  ),
  encode(
    digest(
      'DEFAULT_PROVIDER_ADAPTER_CONTRACT|1|test|passive|all_execution_disabled',
      'sha256'
    ),
    'hex'
  ),
  'MIGRATION_117'
);

select public.append_commercial_provider_adapter_event_internal(
  'ADAPTER_CONTRACT_FOUNDATION_INITIALIZED',
  'MIGRATION_117',
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  'draft',
  'Provider-independent adapter contract foundation initialized',
  null,
  null,
  jsonb_build_object(
    'policy_code', 'DEFAULT_PROVIDER_ADAPTER_CONTRACT',
    'adapter_execution_enabled', false,
    'network_access_enabled', false,
    'credential_resolution_enabled', false,
    'callback_verification_enabled', false,
    'automatic_binding_activation_enabled', false
  )
);

-- =============================================================================
-- 12. RLS, PRIVILEGES AND INTERNAL-ONLY ACCESS
-- =============================================================================

alter table public.commercial_provider_adapter_policies enable row level security;
alter table public.commercial_provider_adapter_contracts enable row level security;
alter table public.commercial_provider_adapter_versions enable row level security;
alter table public.commercial_provider_adapter_operations enable row level security;
alter table public.commercial_provider_adapter_error_mappings enable row level security;
alter table public.commercial_provider_adapter_bindings enable row level security;
alter table public.commercial_provider_adapter_validations enable row level security;
alter table public.commercial_provider_adapter_events enable row level security;

revoke all on table public.commercial_provider_adapter_policies from public, anon, authenticated;
revoke all on table public.commercial_provider_adapter_contracts from public, anon, authenticated;
revoke all on table public.commercial_provider_adapter_versions from public, anon, authenticated;
revoke all on table public.commercial_provider_adapter_operations from public, anon, authenticated;
revoke all on table public.commercial_provider_adapter_error_mappings from public, anon, authenticated;
revoke all on table public.commercial_provider_adapter_bindings from public, anon, authenticated;
revoke all on table public.commercial_provider_adapter_validations from public, anon, authenticated;
revoke all on table public.commercial_provider_adapter_events from public, anon, authenticated;

grant select, insert, update on table public.commercial_provider_adapter_policies to service_role;
grant select, insert, update on table public.commercial_provider_adapter_contracts to service_role;
grant select, insert, update on table public.commercial_provider_adapter_versions to service_role;
grant select, insert, update on table public.commercial_provider_adapter_operations to service_role;
grant select, insert, update on table public.commercial_provider_adapter_error_mappings to service_role;
grant select, insert, update on table public.commercial_provider_adapter_bindings to service_role;
grant select, insert on table public.commercial_provider_adapter_validations to service_role;
grant select, insert on table public.commercial_provider_adapter_events to service_role;

revoke all on function public.protect_commercial_provider_adapter_policy_internal() from public, anon, authenticated;
revoke all on function public.protect_commercial_provider_adapter_version_internal() from public, anon, authenticated;
revoke all on function public.protect_commercial_provider_adapter_validation_internal() from public, anon, authenticated;
revoke all on function public.protect_commercial_provider_adapter_event_internal() from public, anon, authenticated;
revoke all on function public.set_commercial_provider_adapter_updated_at_internal() from public, anon, authenticated;
revoke all on function public.append_commercial_provider_adapter_event_internal(text,text,uuid,uuid,uuid,uuid,uuid,uuid,uuid,text,text,text,uuid,uuid,jsonb) from public, anon, authenticated;
revoke all on function public.register_commercial_provider_adapter_contract_internal(text,text,text,text,jsonb) from public, anon, authenticated;
revoke all on function public.create_commercial_provider_adapter_version_internal(uuid,jsonb,jsonb,jsonb,jsonb,text,text,jsonb) from public, anon, authenticated;
revoke all on function public.declare_commercial_provider_adapter_operation_internal(uuid,text,text,text,boolean,boolean,boolean,jsonb,jsonb,integer,text,jsonb) from public, anon, authenticated;
revoke all on function public.map_commercial_provider_adapter_error_internal(uuid,text,text,text,text,text,text,text,jsonb) from public, anon, authenticated;
revoke all on function public.validate_commercial_provider_adapter_version_internal(uuid,text,jsonb) from public, anon, authenticated;
revoke all on function public.approve_commercial_provider_adapter_version_internal(uuid,text,text) from public, anon, authenticated;
revoke all on function public.create_commercial_provider_adapter_binding_internal(uuid,uuid,uuid,uuid,text,jsonb,jsonb) from public, anon, authenticated;
revoke all on function public.evaluate_commercial_provider_adapter_binding_internal(uuid,text) from public, anon, authenticated;
revoke all on function public.get_commercial_provider_adapter_contract_internal(uuid) from public, anon, authenticated;

grant execute on function public.append_commercial_provider_adapter_event_internal(text,text,uuid,uuid,uuid,uuid,uuid,uuid,uuid,text,text,text,uuid,uuid,jsonb) to service_role;
grant execute on function public.register_commercial_provider_adapter_contract_internal(text,text,text,text,jsonb) to service_role;
grant execute on function public.create_commercial_provider_adapter_version_internal(uuid,jsonb,jsonb,jsonb,jsonb,text,text,jsonb) to service_role;
grant execute on function public.declare_commercial_provider_adapter_operation_internal(uuid,text,text,text,boolean,boolean,boolean,jsonb,jsonb,integer,text,jsonb) to service_role;
grant execute on function public.map_commercial_provider_adapter_error_internal(uuid,text,text,text,text,text,text,text,jsonb) to service_role;
grant execute on function public.validate_commercial_provider_adapter_version_internal(uuid,text,jsonb) to service_role;
grant execute on function public.approve_commercial_provider_adapter_version_internal(uuid,text,text) to service_role;
grant execute on function public.create_commercial_provider_adapter_binding_internal(uuid,uuid,uuid,uuid,text,jsonb,jsonb) to service_role;
grant execute on function public.evaluate_commercial_provider_adapter_binding_internal(uuid,text) to service_role;
grant execute on function public.get_commercial_provider_adapter_contract_internal(uuid) to service_role;

-- =============================================================================
-- 13. FOUNDATION CERTIFICATION
-- =============================================================================

do $$
declare
  v_policy_count bigint;
  v_contract_count bigint;
  v_version_count bigint;
  v_operation_count bigint;
  v_error_count bigint;
  v_binding_count bigint;
  v_validation_count bigint;
  v_event_count bigint;
begin
  select count(*) into v_policy_count
  from public.commercial_provider_adapter_policies;

  select count(*) into v_contract_count
  from public.commercial_provider_adapter_contracts;

  select count(*) into v_version_count
  from public.commercial_provider_adapter_versions;

  select count(*) into v_operation_count
  from public.commercial_provider_adapter_operations;

  select count(*) into v_error_count
  from public.commercial_provider_adapter_error_mappings;

  select count(*) into v_binding_count
  from public.commercial_provider_adapter_bindings;

  select count(*) into v_validation_count
  from public.commercial_provider_adapter_validations;

  select count(*) into v_event_count
  from public.commercial_provider_adapter_events;

  if v_policy_count <> 1 then
    raise exception
      'MIGRATION_117_POLICY_ASSERTION_FAILED count=%',
      v_policy_count;
  end if;

  if v_contract_count <> 0
     or v_version_count <> 0
     or v_operation_count <> 0
     or v_error_count <> 0
     or v_binding_count <> 0
     or v_validation_count <> 0 then
    raise exception
      'MIGRATION_117_PASSIVE_STATE_ASSERTION_FAILED contracts=%, versions=%, operations=%, errors=%, bindings=%, validations=%',
      v_contract_count,
      v_version_count,
      v_operation_count,
      v_error_count,
      v_binding_count,
      v_validation_count;
  end if;

  if v_event_count <> 1 then
    raise exception
      'MIGRATION_117_EVENT_ASSERTION_FAILED count=%',
      v_event_count;
  end if;

  if exists (
    select 1
    from public.commercial_provider_adapter_policies
    where adapter_execution_enabled
       or network_access_enabled
       or credential_resolution_enabled
       or callback_verification_enabled
       or automatic_binding_activation_enabled
  ) then
    raise exception 'MIGRATION_117_POLICY_SAFETY_ASSERTION_FAILED';
  end if;

  if exists (
    select 1
    from public.commercial_provider_adapter_contracts
    where execution_mode <> 'passive'
       or implementation_location <> 'backend_only'
       or secrets_location <> 'external_secret_manager'
  ) then
    raise exception 'MIGRATION_117_CONTRACT_SAFETY_ASSERTION_FAILED';
  end if;

  if exists (
    select 1
    from public.commercial_provider_adapter_bindings
    where binding_status = 'active'
  ) then
    raise exception 'MIGRATION_117_ACTIVE_BINDING_ASSERTION_FAILED';
  end if;

  raise notice
    'MIGRATION_117_CERTIFIED policy_count=%, contract_count=%, version_count=%, operation_count=%, error_mapping_count=%, binding_count=%, validation_count=%, event_count=%, adapter_execution_enabled=false, network_access_enabled=false, credential_resolution_enabled=false, callback_verification_enabled=false, automatic_binding_activation_enabled=false',
    v_policy_count,
    v_contract_count,
    v_version_count,
    v_operation_count,
    v_error_count,
    v_binding_count,
    v_validation_count,
    v_event_count;
end
$$;

commit;
