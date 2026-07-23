-- =============================================================================
-- FANTAGOL
-- Migration: 135_commercial_secret_resolution_execution_permit_foundation.sql
-- Milestone: Commercial Secret Resolution Execution Permit Foundation
--
-- Purpose:
--   Establish the governance boundary that may attest future eligibility for a
--   secret-resolution operation after a certified passive handoff.
--
-- IMPORTANT:
--   A permit created by this foundation is:
--     - metadata-only;
--     - opaque-reference-only;
--     - non-executable;
--     - time-bounded;
--     - independently revocable;
--     - incapable of contacting a backend or accessing secret material.
--
-- This migration DOES NOT:
--   - dispatch work;
--   - discover endpoints;
--   - probe or contact backends;
--   - authenticate;
--   - look up, resolve, decrypt or load secrets;
--   - deliver credential material;
--   - perform network access;
--   - mutate commercial purchases, checkout, wallets, ledger or runtime outbox.
-- =============================================================================

\set ON_ERROR_STOP on
\timing on

begin;

create extension if not exists pgcrypto with schema extensions;

-- =============================================================================
-- 0. DEPENDENCY ASSERTIONS
-- =============================================================================

do $$
begin
  if to_regclass('public.commercial_secret_reference_handoff_requests') is null
     or to_regclass('public.commercial_secret_reference_handoff_decisions') is null
     or to_regclass('public.commercial_secret_reference_handoff_manifests') is null
     or to_regclass('public.commercial_secret_reference_handoff_read_model') is null
     or to_regclass('public.commercial_secret_reference_authorization_requests') is null
     or to_regclass('public.commercial_secret_reference_authorization_decisions') is null
     or to_regclass('public.commercial_secret_backend_bindings') is null
     or to_regclass('public.commercial_secret_backends') is null
     or to_regclass('public.commercial_secret_backend_versions') is null then
    raise exception 'MIGRATION_135_REQUIRES_MIGRATIONS_127_TO_134';
  end if;
end
$$;

-- =============================================================================
-- 1. EXECUTION PERMIT POLICY
-- =============================================================================

create table public.commercial_secret_resolution_execution_permit_policies (
  id uuid primary key default gen_random_uuid(),
  policy_code text not null,
  environment text not null default 'production',
  policy_status text not null default 'draft',
  policy_version integer not null default 1,

  intake_enabled boolean not null default true,
  handoff_verification_enabled boolean not null default true,
  manifest_integrity_verification_enabled boolean not null default true,
  scope_integrity_verification_enabled boolean not null default true,
  capability_integrity_verification_enabled boolean not null default true,
  backend_binding_integrity_enabled boolean not null default true,
  expiry_enforcement_enabled boolean not null default true,
  revocation_enabled boolean not null default true,
  decision_recording_enabled boolean not null default true,
  permit_issuance_enabled boolean not null default true,

  maximum_permit_lifetime_seconds integer not null default 300,
  default_permit_lifetime_seconds integer not null default 120,
  clock_skew_tolerance_seconds integer not null default 15,

  automatic_dispatch_enabled boolean not null default false,
  permit_execution_enabled boolean not null default false,
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

  opaque_references_only boolean not null default true,
  plaintext_storage_forbidden boolean not null default true,
  metadata_only boolean not null default true,
  executable_permits_forbidden boolean not null default true,

  default_decision text not null default 'held',
  created_by text not null,
  approved_by text,
  approved_at timestamptz,
  policy_metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp(),

  constraint commercial_secret_resolution_permit_policy_unique
    unique(policy_code,environment),

  constraint commercial_secret_resolution_permit_policy_values_check
    check (
      policy_code=lower(policy_code)
      and policy_code ~ '^[a-z][a-z0-9:_-]{7,159}$'
      and environment in ('development','test','staging','production')
      and policy_status in ('draft','approved','retired')
      and policy_version>0
      and maximum_permit_lifetime_seconds between 1 and 3600
      and default_permit_lifetime_seconds between 1 and maximum_permit_lifetime_seconds
      and clock_skew_tolerance_seconds between 0 and 300
      and default_decision in ('held','blocked')
      and opaque_references_only=true
      and plaintext_storage_forbidden=true
      and metadata_only=true
      and executable_permits_forbidden=true
      and jsonb_typeof(policy_metadata)='object'
      and not (policy_metadata ?| array[
        'secret','secret_value','password','private_key','access_token',
        'refresh_token','api_key','client_secret','plaintext','ciphertext',
        'url','uri','endpoint','connection_string','dsn','host','hostname'
      ])
    ),

  constraint commercial_secret_resolution_permit_policy_passive_check
    check (
      automatic_dispatch_enabled=false
      and permit_execution_enabled=false
      and endpoint_discovery_enabled=false
      and backend_probe_enabled=false
      and backend_contact_enabled=false
      and backend_authentication_enabled=false
      and secret_lookup_enabled=false
      and secret_resolution_enabled=false
      and secret_decryption_enabled=false
      and credential_material_loading_enabled=false
      and credential_delivery_enabled=false
      and network_access_enabled=false
    )
);

comment on table public.commercial_secret_resolution_execution_permit_policies is
'Immutable policy governing non-executable, metadata-only and revocable secret-resolution permits.';

-- =============================================================================
-- 2. PERMIT REQUESTS AND IDEMPOTENCY
-- =============================================================================

create table public.commercial_secret_resolution_execution_permit_requests (
  id uuid primary key default gen_random_uuid(),
  request_key text not null unique,
  idempotency_key text not null unique,
  permit_policy_id uuid not null,

  handoff_request_id uuid not null,
  handoff_decision_id uuid not null,
  handoff_manifest_id uuid not null,
  authorization_request_id uuid not null,
  authorization_decision_id uuid not null,

  requested_environment text not null,
  requested_scope_type text not null,
  requested_scope_key text not null,
  requested_namespace text not null,
  requested_capability text not null,
  requested_operation text not null default 'secret_resolution',
  requested_lifetime_seconds integer not null,

  request_status text not null default 'received',
  correlation_id uuid not null,
  causation_id uuid,
  requested_by text not null,
  requested_at timestamptz not null default clock_timestamp(),
  evaluated_at timestamptz,
  terminal_reason text,

  request_hash text not null,
  request_metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),

  constraint commercial_secret_resolution_permit_request_policy_fkey
    foreign key(permit_policy_id)
    references public.commercial_secret_resolution_execution_permit_policies(id)
    on delete restrict,

  constraint commercial_secret_resolution_permit_request_handoff_request_fkey
    foreign key(handoff_request_id)
    references public.commercial_secret_reference_handoff_requests(id)
    on delete restrict,

  constraint commercial_secret_resolution_permit_request_handoff_decision_fkey
    foreign key(handoff_decision_id)
    references public.commercial_secret_reference_handoff_decisions(id)
    on delete restrict,

  constraint commercial_secret_resolution_permit_request_handoff_manifest_fkey
    foreign key(handoff_manifest_id)
    references public.commercial_secret_reference_handoff_manifests(id)
    on delete restrict,

  constraint commercial_secret_resolution_permit_request_authorization_request_fkey
    foreign key(authorization_request_id)
    references public.commercial_secret_reference_authorization_requests(id)
    on delete restrict,

  constraint commercial_secret_resolution_permit_request_authorization_decision_fkey
    foreign key(authorization_decision_id)
    references public.commercial_secret_reference_authorization_decisions(id)
    on delete restrict,

  constraint commercial_secret_resolution_permit_request_values_check
    check (
      request_key=lower(request_key)
      and request_key ~ '^[a-z][a-z0-9:_-]{7,159}$'
      and length(idempotency_key) between 8 and 240
      and requested_environment in ('development','test','staging','production')
      and requested_scope_type in ('platform','provider','credential_binding')
      and requested_scope_key=lower(requested_scope_key)
      and requested_namespace=lower(requested_namespace)
      and requested_capability=lower(requested_capability)
      and requested_operation='secret_resolution'
      and requested_lifetime_seconds between 1 and 3600
      and request_status in ('received','evaluated','approved','held','blocked','cancelled')
      and request_hash ~ '^[a-f0-9]{64}$'
      and jsonb_typeof(request_metadata)='object'
      and not (request_metadata ?| array[
        'secret','secret_value','password','private_key','access_token',
        'refresh_token','api_key','client_secret','plaintext','ciphertext',
        'url','uri','endpoint','connection_string','dsn','host','hostname'
      ])
    )
);

create index commercial_secret_resolution_execution_permit_requests_queue_idx
  on public.commercial_secret_resolution_execution_permit_requests
  (request_status,requested_at,id);

create table public.commercial_secret_resolution_execution_permit_idempotency (
  id uuid primary key default gen_random_uuid(),
  idempotency_key text not null unique,
  permit_request_id uuid not null unique,
  request_hash text not null,
  replay_count integer not null default 0,
  first_seen_at timestamptz not null default clock_timestamp(),
  last_seen_at timestamptz not null default clock_timestamp(),

  constraint commercial_secret_resolution_permit_idempotency_request_fkey
    foreign key(permit_request_id)
    references public.commercial_secret_resolution_execution_permit_requests(id)
    on delete restrict,

  constraint commercial_secret_resolution_permit_idempotency_values_check
    check (
      length(idempotency_key) between 8 and 240
      and request_hash ~ '^[a-f0-9]{64}$'
      and replay_count>=0
    )
);

-- =============================================================================
-- 3. PERMIT EVALUATIONS
-- =============================================================================

create table public.commercial_secret_resolution_execution_permit_evaluations (
  id uuid primary key default gen_random_uuid(),
  permit_request_id uuid not null,
  evaluation_order integer not null,
  evaluation_code text not null,
  evaluation_status text not null,
  passed boolean not null,
  evaluation_reason text,
  evaluation_hash text not null,
  evaluation_metadata jsonb not null default '{}'::jsonb,
  evaluated_at timestamptz not null default clock_timestamp(),

  constraint commercial_secret_resolution_permit_evaluation_request_fkey
    foreign key(permit_request_id)
    references public.commercial_secret_resolution_execution_permit_requests(id)
    on delete restrict,

  constraint commercial_secret_resolution_permit_evaluation_unique
    unique(permit_request_id,evaluation_order),

  constraint commercial_secret_resolution_permit_evaluation_values_check
    check (
      evaluation_order between 1 and 100
      and evaluation_code in (
        'HANDOFF_DECISION',
        'HANDOFF_MANIFEST_LINK',
        'HANDOFF_MANIFEST_STATUS',
        'AUTHORIZATION_CHAIN',
        'ENVIRONMENT',
        'SCOPE',
        'NAMESPACE',
        'CAPABILITY',
        'BACKEND_BINDING',
        'PERMIT_LIFETIME',
        'PASSIVE_POSTURE'
      )
      and evaluation_status in ('passed','failed','held')
      and passed=(evaluation_status='passed')
      and evaluation_hash ~ '^[a-f0-9]{64}$'
      and jsonb_typeof(evaluation_metadata)='object'
      and not (evaluation_metadata ?| array[
        'secret','secret_value','password','private_key','access_token',
        'refresh_token','api_key','client_secret','plaintext','ciphertext',
        'url','uri','endpoint','connection_string','dsn','host','hostname'
      ])
    )
);

-- =============================================================================
-- 4. PERMIT DECISIONS
-- =============================================================================

create table public.commercial_secret_resolution_execution_permit_decisions (
  id uuid primary key default gen_random_uuid(),
  permit_request_id uuid not null unique,

  decision_status text not null,
  decision_code text not null,
  approved boolean not null default false,

  handoff_manifest_id uuid,
  selected_backend_binding_id uuid,
  selected_backend_id uuid,
  selected_backend_version_id uuid,

  resolved_environment text,
  resolved_scope_type text,
  resolved_scope_key text,
  resolved_namespace text,
  resolved_capability text,
  resolved_operation text,

  granted_lifetime_seconds integer,
  not_before timestamptz,
  expires_at timestamptz,

  permit_execution_allowed boolean not null default false,
  dispatch_allowed boolean not null default false,
  endpoint_discovery_allowed boolean not null default false,
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

  constraint commercial_secret_resolution_permit_decision_request_fkey
    foreign key(permit_request_id)
    references public.commercial_secret_resolution_execution_permit_requests(id)
    on delete restrict,

  constraint commercial_secret_resolution_permit_decision_manifest_fkey
    foreign key(handoff_manifest_id)
    references public.commercial_secret_reference_handoff_manifests(id)
    on delete restrict,

  constraint commercial_secret_resolution_permit_decision_binding_fkey
    foreign key(selected_backend_binding_id)
    references public.commercial_secret_backend_bindings(id)
    on delete restrict,

  constraint commercial_secret_resolution_permit_decision_backend_fkey
    foreign key(selected_backend_id)
    references public.commercial_secret_backends(id)
    on delete restrict,

  constraint commercial_secret_resolution_permit_decision_version_fkey
    foreign key(selected_backend_version_id)
    references public.commercial_secret_backend_versions(id)
    on delete restrict,

  constraint commercial_secret_resolution_permit_decision_values_check
    check (
      decision_status in ('approved','held','blocked')
      and decision_code in (
        'PERMIT_METADATA_APPROVED',
        'POLICY_DISABLED',
        'HANDOFF_NOT_ACCEPTED',
        'HANDOFF_MANIFEST_LINK_MISMATCH',
        'HANDOFF_MANIFEST_NOT_HELD',
        'AUTHORIZATION_CHAIN_MISMATCH',
        'ENVIRONMENT_MISMATCH',
        'SCOPE_MISMATCH',
        'NAMESPACE_MISMATCH',
        'CAPABILITY_MISMATCH',
        'BACKEND_BINDING_MISMATCH',
        'PERMIT_LIFETIME_INVALID',
        'PASSIVE_POSTURE_VIOLATION'
      )
      and approved=(decision_status='approved')
      and (
        (approved and granted_lifetime_seconds is not null
          and not_before is not null and expires_at is not null
          and expires_at>not_before)
        or
        (not approved)
      )
      and decision_hash ~ '^[a-f0-9]{64}$'
      and jsonb_typeof(decision_metadata)='object'
      and not (decision_metadata ?| array[
        'secret','secret_value','password','private_key','access_token',
        'refresh_token','api_key','client_secret','plaintext','ciphertext',
        'url','uri','endpoint','connection_string','dsn','host','hostname'
      ])
    ),

  constraint commercial_secret_resolution_permit_decision_passive_check
    check (
      permit_execution_allowed=false
      and dispatch_allowed=false
      and endpoint_discovery_allowed=false
      and backend_contact_allowed=false
      and authentication_allowed=false
      and secret_lookup_allowed=false
      and secret_resolution_allowed=false
      and decryption_allowed=false
      and material_loading_allowed=false
      and delivery_allowed=false
      and network_access_allowed=false
    )
);

-- =============================================================================
-- 5. NON-EXECUTABLE PERMITS
-- =============================================================================

create table public.commercial_secret_resolution_execution_permits (
  id uuid primary key default gen_random_uuid(),
  permit_key text not null unique,
  permit_request_id uuid not null unique,
  permit_decision_id uuid not null unique,

  handoff_request_id uuid not null,
  handoff_decision_id uuid not null,
  handoff_manifest_id uuid not null,
  authorization_request_id uuid not null,
  authorization_decision_id uuid not null,

  selected_backend_binding_id uuid not null,
  selected_backend_id uuid not null,
  selected_backend_version_id uuid not null,

  environment text not null,
  scope_type text not null,
  scope_key text not null,
  namespace_code text not null,
  capability_code text not null,
  operation_code text not null,

  permit_status text not null default 'issued',
  not_before timestamptz not null,
  expires_at timestamptz not null,
  maximum_uses integer not null default 1,

  opaque_reference_contract boolean not null default true,
  metadata_only boolean not null default true,
  executable boolean not null default false,
  revocable boolean not null default true,
  bearer_credential boolean not null default false,
  transferable boolean not null default false,

  permit_execution_allowed boolean not null default false,
  dispatch_allowed boolean not null default false,
  endpoint_discovery_allowed boolean not null default false,
  backend_contact_allowed boolean not null default false,
  authentication_allowed boolean not null default false,
  secret_lookup_allowed boolean not null default false,
  secret_resolution_allowed boolean not null default false,
  decryption_allowed boolean not null default false,
  material_loading_allowed boolean not null default false,
  delivery_allowed boolean not null default false,
  network_access_allowed boolean not null default false,

  permit_hash text not null,
  permit_metadata jsonb not null default '{}'::jsonb,
  issued_by text not null,
  issued_at timestamptz not null default clock_timestamp(),

  constraint commercial_secret_resolution_execution_permit_request_fkey
    foreign key(permit_request_id)
    references public.commercial_secret_resolution_execution_permit_requests(id)
    on delete restrict,

  constraint commercial_secret_resolution_execution_permit_decision_fkey
    foreign key(permit_decision_id)
    references public.commercial_secret_resolution_execution_permit_decisions(id)
    on delete restrict,

  constraint commercial_secret_resolution_execution_permit_handoff_request_fkey
    foreign key(handoff_request_id)
    references public.commercial_secret_reference_handoff_requests(id)
    on delete restrict,

  constraint commercial_secret_resolution_execution_permit_handoff_decision_fkey
    foreign key(handoff_decision_id)
    references public.commercial_secret_reference_handoff_decisions(id)
    on delete restrict,

  constraint commercial_secret_resolution_execution_permit_handoff_manifest_fkey
    foreign key(handoff_manifest_id)
    references public.commercial_secret_reference_handoff_manifests(id)
    on delete restrict,

  constraint commercial_secret_resolution_execution_permit_authorization_request_fkey
    foreign key(authorization_request_id)
    references public.commercial_secret_reference_authorization_requests(id)
    on delete restrict,

  constraint commercial_secret_resolution_execution_permit_authorization_decision_fkey
    foreign key(authorization_decision_id)
    references public.commercial_secret_reference_authorization_decisions(id)
    on delete restrict,

  constraint commercial_secret_resolution_execution_permit_binding_fkey
    foreign key(selected_backend_binding_id)
    references public.commercial_secret_backend_bindings(id)
    on delete restrict,

  constraint commercial_secret_resolution_execution_permit_backend_fkey
    foreign key(selected_backend_id)
    references public.commercial_secret_backends(id)
    on delete restrict,

  constraint commercial_secret_resolution_execution_permit_version_fkey
    foreign key(selected_backend_version_id)
    references public.commercial_secret_backend_versions(id)
    on delete restrict,

  constraint commercial_secret_resolution_execution_permit_values_check
    check (
      permit_key=lower(permit_key)
      and permit_key ~ '^[a-z][a-z0-9:_-]{7,159}$'
      and environment in ('development','test','staging','production')
      and scope_type in ('platform','provider','credential_binding')
      and scope_key=lower(scope_key)
      and namespace_code=lower(namespace_code)
      and capability_code=lower(capability_code)
      and operation_code='secret_resolution'
      and permit_status in ('issued','expired','superseded')
      and expires_at>not_before
      and maximum_uses=1
      and opaque_reference_contract=true
      and metadata_only=true
      and executable=false
      and revocable=true
      and bearer_credential=false
      and transferable=false
      and permit_execution_allowed=false
      and dispatch_allowed=false
      and endpoint_discovery_allowed=false
      and backend_contact_allowed=false
      and authentication_allowed=false
      and secret_lookup_allowed=false
      and secret_resolution_allowed=false
      and decryption_allowed=false
      and material_loading_allowed=false
      and delivery_allowed=false
      and network_access_allowed=false
      and permit_hash ~ '^[a-f0-9]{64}$'
      and jsonb_typeof(permit_metadata)='object'
      and not (permit_metadata ?| array[
        'secret','secret_value','password','private_key','access_token',
        'refresh_token','api_key','client_secret','plaintext','ciphertext',
        'url','uri','endpoint','connection_string','dsn','host','hostname'
      ])
    )
);

comment on table public.commercial_secret_resolution_execution_permits is
'Immutable metadata-only eligibility permits. They are not bearer credentials and cannot execute secret resolution.';

-- =============================================================================
-- 6. APPEND-ONLY REVOCATIONS
-- =============================================================================

create table public.commercial_secret_resolution_execution_permit_revocations (
  id uuid primary key default gen_random_uuid(),
  execution_permit_id uuid not null,
  revocation_key text not null unique,
  revocation_code text not null,
  revocation_reason text not null,
  effective_at timestamptz not null default clock_timestamp(),
  revoked_by text not null,
  correlation_id uuid,
  causation_id uuid,
  revocation_hash text not null,
  revocation_metadata jsonb not null default '{}'::jsonb,
  recorded_at timestamptz not null default clock_timestamp(),

  constraint commercial_secret_resolution_permit_revocation_permit_fkey
    foreign key(execution_permit_id)
    references public.commercial_secret_resolution_execution_permits(id)
    on delete restrict,

  constraint commercial_secret_resolution_permit_revocation_unique
    unique(execution_permit_id),

  constraint commercial_secret_resolution_permit_revocation_values_check
    check (
      revocation_key=lower(revocation_key)
      and revocation_key ~ '^[a-z][a-z0-9:_-]{7,159}$'
      and revocation_code in (
        'ADMINISTRATIVE_REVOCATION',
        'POLICY_REVOCATION',
        'SECURITY_REVOCATION',
        'SUPERSEDED',
        'TEST_REVOCATION'
      )
      and length(btrim(revocation_reason)) between 3 and 1000
      and revocation_hash ~ '^[a-f0-9]{64}$'
      and jsonb_typeof(revocation_metadata)='object'
      and not (revocation_metadata ?| array[
        'secret','secret_value','password','private_key','access_token',
        'refresh_token','api_key','client_secret','plaintext','ciphertext',
        'url','uri','endpoint','connection_string','dsn','host','hostname'
      ])
    )
);

-- =============================================================================
-- 7. BLOCKED EXECUTION ATTEMPTS
-- =============================================================================

create table public.commercial_secret_resolution_execution_permit_attempts (
  id uuid primary key default gen_random_uuid(),
  permit_request_id uuid not null,
  permit_decision_id uuid,
  execution_permit_id uuid,
  attempt_type text not null,
  attempt_status text not null,
  block_code text not null,
  attempted_by text not null,
  correlation_id uuid,
  attempt_hash text not null,
  attempt_metadata jsonb not null default '{}'::jsonb,
  attempted_at timestamptz not null default clock_timestamp(),

  constraint commercial_secret_resolution_permit_attempt_request_fkey
    foreign key(permit_request_id)
    references public.commercial_secret_resolution_execution_permit_requests(id)
    on delete restrict,

  constraint commercial_secret_resolution_permit_attempt_decision_fkey
    foreign key(permit_decision_id)
    references public.commercial_secret_resolution_execution_permit_decisions(id)
    on delete restrict,

  constraint commercial_secret_resolution_permit_attempt_permit_fkey
    foreign key(execution_permit_id)
    references public.commercial_secret_resolution_execution_permits(id)
    on delete restrict,

  constraint commercial_secret_resolution_permit_attempt_values_check
    check (
      attempt_type in (
        'PERMIT_EXECUTION',
        'DISPATCH',
        'ENDPOINT_DISCOVERY',
        'BACKEND_CONTACT',
        'AUTHENTICATION',
        'SECRET_LOOKUP',
        'SECRET_RESOLUTION',
        'SECRET_DECRYPTION',
        'MATERIAL_LOADING',
        'DELIVERY',
        'NETWORK_ACCESS'
      )
      and attempt_status='blocked'
      and block_code='NON_EXECUTABLE_PERMIT_OPERATION_FORBIDDEN'
      and attempt_hash ~ '^[a-f0-9]{64}$'
      and jsonb_typeof(attempt_metadata)='object'
      and not (attempt_metadata ?| array[
        'secret','secret_value','password','private_key','access_token',
        'refresh_token','api_key','client_secret','plaintext','ciphertext',
        'url','uri','endpoint','connection_string','dsn','host','hostname'
      ])
    )
);

-- =============================================================================
-- 8. RECEIPTS AND EVENTS
-- =============================================================================

create table public.commercial_secret_resolution_execution_permit_receipts (
  id uuid primary key default gen_random_uuid(),
  receipt_type text not null,
  permit_request_id uuid,
  permit_decision_id uuid,
  execution_permit_id uuid,
  permit_revocation_id uuid,
  permit_attempt_id uuid,
  receipt_status text not null,
  receipt_code text not null,
  receipt_message text,
  recorded_by text not null,
  correlation_id uuid,
  receipt_hash text not null,
  receipt_metadata jsonb not null default '{}'::jsonb,
  recorded_at timestamptz not null default clock_timestamp(),

  constraint commercial_secret_resolution_permit_receipt_request_fkey
    foreign key(permit_request_id)
    references public.commercial_secret_resolution_execution_permit_requests(id)
    on delete restrict,

  constraint commercial_secret_resolution_permit_receipt_decision_fkey
    foreign key(permit_decision_id)
    references public.commercial_secret_resolution_execution_permit_decisions(id)
    on delete restrict,

  constraint commercial_secret_resolution_permit_receipt_permit_fkey
    foreign key(execution_permit_id)
    references public.commercial_secret_resolution_execution_permits(id)
    on delete restrict,

  constraint commercial_secret_resolution_permit_receipt_revocation_fkey
    foreign key(permit_revocation_id)
    references public.commercial_secret_resolution_execution_permit_revocations(id)
    on delete restrict,

  constraint commercial_secret_resolution_permit_receipt_attempt_fkey
    foreign key(permit_attempt_id)
    references public.commercial_secret_resolution_execution_permit_attempts(id)
    on delete restrict,

  constraint commercial_secret_resolution_permit_receipt_values_check
    check (
      receipt_type in (
        'REQUEST_ACCEPTED',
        'REQUEST_REPLAYED',
        'EVALUATION_COMPLETED',
        'DECISION_RECORDED',
        'PERMIT_ISSUED',
        'PERMIT_REVOKED',
        'EXECUTION_BLOCKED'
      )
      and receipt_status in (
        'accepted','replayed','passed','approved','held','blocked','issued','revoked','recorded'
      )
      and receipt_hash ~ '^[a-f0-9]{64}$'
      and jsonb_typeof(receipt_metadata)='object'
      and not (receipt_metadata ?| array[
        'secret','secret_value','password','private_key','access_token',
        'refresh_token','api_key','client_secret','plaintext','ciphertext',
        'url','uri','endpoint','connection_string','dsn','host','hostname'
      ])
    )
);

create table public.commercial_secret_resolution_execution_permit_events (
  id uuid primary key default gen_random_uuid(),
  event_type text not null,
  permit_policy_id uuid,
  permit_request_id uuid,
  permit_decision_id uuid,
  execution_permit_id uuid,
  permit_revocation_id uuid,
  permit_attempt_id uuid,
  event_status text not null,
  event_message text,
  event_source text not null,
  correlation_id uuid,
  causation_id uuid,
  event_hash text not null,
  event_metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp(),

  constraint commercial_secret_resolution_permit_event_policy_fkey
    foreign key(permit_policy_id)
    references public.commercial_secret_resolution_execution_permit_policies(id)
    on delete restrict,

  constraint commercial_secret_resolution_permit_event_request_fkey
    foreign key(permit_request_id)
    references public.commercial_secret_resolution_execution_permit_requests(id)
    on delete restrict,

  constraint commercial_secret_resolution_permit_event_decision_fkey
    foreign key(permit_decision_id)
    references public.commercial_secret_resolution_execution_permit_decisions(id)
    on delete restrict,

  constraint commercial_secret_resolution_permit_event_permit_fkey
    foreign key(execution_permit_id)
    references public.commercial_secret_resolution_execution_permits(id)
    on delete restrict,

  constraint commercial_secret_resolution_permit_event_revocation_fkey
    foreign key(permit_revocation_id)
    references public.commercial_secret_resolution_execution_permit_revocations(id)
    on delete restrict,

  constraint commercial_secret_resolution_permit_event_attempt_fkey
    foreign key(permit_attempt_id)
    references public.commercial_secret_resolution_execution_permit_attempts(id)
    on delete restrict,

  constraint commercial_secret_resolution_permit_event_values_check
    check (
      event_type ~ '^[A-Z][A-Z0-9_]{3,95}$'
      and event_status in (
        'draft','approved','received','evaluated','held','blocked','issued','revoked','recorded'
      )
      and event_hash ~ '^[a-f0-9]{64}$'
      and jsonb_typeof(event_metadata)='object'
      and not (event_metadata ?| array[
        'secret','secret_value','password','private_key','access_token',
        'refresh_token','api_key','client_secret','plaintext','ciphertext',
        'url','uri','endpoint','connection_string','dsn','host','hostname'
      ])
    )
);

-- =============================================================================
-- 9. PROTECTION TRIGGERS
-- =============================================================================

create function public.commercial_secret_resolution_execution_permit_set_updated_at()
returns trigger
language plpgsql
set search_path=public,pg_temp
as $$
begin
  new.updated_at=clock_timestamp();
  return new;
end
$$;

create function public.commercial_secret_resolution_execution_permit_immutable()
returns trigger
language plpgsql
set search_path=public,pg_temp
as $$
begin
  raise exception 'COMMERCIAL_SECRET_RESOLUTION_EXECUTION_PERMIT_IMMUTABLE';
end
$$;

create function public.commercial_secret_resolution_execution_permit_append_only()
returns trigger
language plpgsql
set search_path=public,pg_temp
as $$
begin
  raise exception 'COMMERCIAL_SECRET_RESOLUTION_EXECUTION_PERMIT_APPEND_ONLY';
end
$$;

create trigger commercial_secret_resolution_execution_permit_requests_updated_at
before update on public.commercial_secret_resolution_execution_permit_requests
for each row execute function public.commercial_secret_resolution_execution_permit_set_updated_at();

create trigger commercial_secret_resolution_execution_permit_policies_immutable
before update or delete on public.commercial_secret_resolution_execution_permit_policies
for each row execute function public.commercial_secret_resolution_execution_permit_immutable();

create trigger commercial_secret_resolution_execution_permit_evaluations_immutable
before update or delete on public.commercial_secret_resolution_execution_permit_evaluations
for each row execute function public.commercial_secret_resolution_execution_permit_immutable();

create trigger commercial_secret_resolution_execution_permit_decisions_immutable
before update or delete on public.commercial_secret_resolution_execution_permit_decisions
for each row execute function public.commercial_secret_resolution_execution_permit_immutable();

create trigger commercial_secret_resolution_execution_permits_immutable
before update or delete on public.commercial_secret_resolution_execution_permits
for each row execute function public.commercial_secret_resolution_execution_permit_immutable();

create trigger commercial_secret_resolution_execution_permit_revocations_append_only
before update or delete on public.commercial_secret_resolution_execution_permit_revocations
for each row execute function public.commercial_secret_resolution_execution_permit_append_only();

create trigger commercial_secret_resolution_execution_permit_attempts_append_only
before update or delete on public.commercial_secret_resolution_execution_permit_attempts
for each row execute function public.commercial_secret_resolution_execution_permit_append_only();

create trigger commercial_secret_resolution_execution_permit_receipts_append_only
before update or delete on public.commercial_secret_resolution_execution_permit_receipts
for each row execute function public.commercial_secret_resolution_execution_permit_append_only();

create trigger commercial_secret_resolution_execution_permit_events_append_only
before update or delete on public.commercial_secret_resolution_execution_permit_events
for each row execute function public.commercial_secret_resolution_execution_permit_append_only();

-- =============================================================================
-- 10. APPEND HELPERS
-- =============================================================================

create function public.append_commercial_secret_resolution_execution_permit_receipt(
  p_receipt_type text,
  p_permit_request_id uuid,
  p_permit_decision_id uuid,
  p_execution_permit_id uuid,
  p_permit_revocation_id uuid,
  p_permit_attempt_id uuid,
  p_receipt_status text,
  p_receipt_code text,
  p_receipt_message text,
  p_recorded_by text,
  p_correlation_id uuid default null,
  p_receipt_metadata jsonb default '{}'::jsonb
)
returns public.commercial_secret_resolution_execution_permit_receipts
language plpgsql
security definer
set search_path=public,extensions,pg_temp
as $$
declare
  v_hash text;
  v_row public.commercial_secret_resolution_execution_permit_receipts;
begin
  v_hash:=encode(extensions.digest(
    concat_ws('|',
      p_receipt_type,p_permit_request_id,p_permit_decision_id,
      p_execution_permit_id,p_permit_revocation_id,p_permit_attempt_id,
      p_receipt_status,p_receipt_code,p_receipt_message,p_recorded_by,
      p_correlation_id,coalesce(p_receipt_metadata,'{}'::jsonb)::text,
      clock_timestamp()::text
    ),'sha256'),'hex');

  insert into public.commercial_secret_resolution_execution_permit_receipts(
    receipt_type,permit_request_id,permit_decision_id,execution_permit_id,
    permit_revocation_id,permit_attempt_id,receipt_status,receipt_code,
    receipt_message,recorded_by,correlation_id,receipt_hash,receipt_metadata
  ) values (
    p_receipt_type,p_permit_request_id,p_permit_decision_id,p_execution_permit_id,
    p_permit_revocation_id,p_permit_attempt_id,p_receipt_status,p_receipt_code,
    p_receipt_message,p_recorded_by,p_correlation_id,v_hash,
    coalesce(p_receipt_metadata,'{}'::jsonb)
  ) returning * into v_row;

  return v_row;
end
$$;

create function public.append_commercial_secret_resolution_execution_permit_event(
  p_event_type text,
  p_permit_policy_id uuid,
  p_permit_request_id uuid,
  p_permit_decision_id uuid,
  p_execution_permit_id uuid,
  p_permit_revocation_id uuid,
  p_permit_attempt_id uuid,
  p_event_status text,
  p_event_message text,
  p_event_source text,
  p_correlation_id uuid default null,
  p_causation_id uuid default null,
  p_event_metadata jsonb default '{}'::jsonb
)
returns public.commercial_secret_resolution_execution_permit_events
language plpgsql
security definer
set search_path=public,extensions,pg_temp
as $$
declare
  v_hash text;
  v_row public.commercial_secret_resolution_execution_permit_events;
begin
  v_hash:=encode(extensions.digest(
    concat_ws('|',
      p_event_type,p_permit_policy_id,p_permit_request_id,p_permit_decision_id,
      p_execution_permit_id,p_permit_revocation_id,p_permit_attempt_id,
      p_event_status,p_event_message,p_event_source,p_correlation_id,
      p_causation_id,coalesce(p_event_metadata,'{}'::jsonb)::text,
      clock_timestamp()::text
    ),'sha256'),'hex');

  insert into public.commercial_secret_resolution_execution_permit_events(
    event_type,permit_policy_id,permit_request_id,permit_decision_id,
    execution_permit_id,permit_revocation_id,permit_attempt_id,event_status,
    event_message,event_source,correlation_id,causation_id,event_hash,event_metadata
  ) values (
    p_event_type,p_permit_policy_id,p_permit_request_id,p_permit_decision_id,
    p_execution_permit_id,p_permit_revocation_id,p_permit_attempt_id,p_event_status,
    p_event_message,p_event_source,p_correlation_id,p_causation_id,v_hash,
    coalesce(p_event_metadata,'{}'::jsonb)
  ) returning * into v_row;

  return v_row;
end
$$;

-- =============================================================================
-- 11. ENQUEUE PERMIT REQUEST
-- =============================================================================

create function public.enqueue_commercial_secret_resolution_execution_permit_request(
  p_request_key text,
  p_idempotency_key text,
  p_handoff_request_id uuid,
  p_handoff_decision_id uuid,
  p_handoff_manifest_id uuid,
  p_requested_environment text,
  p_requested_scope_type text,
  p_requested_scope_key text,
  p_requested_namespace text,
  p_requested_capability text,
  p_requested_lifetime_seconds integer,
  p_requested_by text,
  p_correlation_id uuid default gen_random_uuid(),
  p_causation_id uuid default null,
  p_request_metadata jsonb default '{}'::jsonb
)
returns public.commercial_secret_resolution_execution_permit_requests
language plpgsql
security definer
set search_path=public,extensions,pg_temp
as $$
declare
  v_policy public.commercial_secret_resolution_execution_permit_policies;
  v_handoff_request public.commercial_secret_reference_handoff_requests;
  v_handoff_decision public.commercial_secret_reference_handoff_decisions;
  v_handoff_manifest public.commercial_secret_reference_handoff_manifests;
  v_existing public.commercial_secret_resolution_execution_permit_idempotency;
  v_request public.commercial_secret_resolution_execution_permit_requests;
  v_hash text;
begin
  select * into strict v_policy
  from public.commercial_secret_resolution_execution_permit_policies
  where policy_code='commercial:secret_resolution_execution_permit:v1'
    and environment=lower(p_requested_environment)
    and policy_status='approved';

  if not v_policy.intake_enabled then
    raise exception 'COMMERCIAL_SECRET_RESOLUTION_EXECUTION_PERMIT_INTAKE_DISABLED';
  end if;

  if p_requested_lifetime_seconds<1
     or p_requested_lifetime_seconds>v_policy.maximum_permit_lifetime_seconds then
    raise exception 'COMMERCIAL_SECRET_RESOLUTION_EXECUTION_PERMIT_LIFETIME_INVALID';
  end if;

  select * into strict v_handoff_request
  from public.commercial_secret_reference_handoff_requests
  where id=p_handoff_request_id;

  select * into strict v_handoff_decision
  from public.commercial_secret_reference_handoff_decisions
  where id=p_handoff_decision_id;

  select * into strict v_handoff_manifest
  from public.commercial_secret_reference_handoff_manifests
  where id=p_handoff_manifest_id;

  v_hash:=encode(extensions.digest(
    concat_ws('|',
      lower(p_request_key),p_idempotency_key,p_handoff_request_id,
      p_handoff_decision_id,p_handoff_manifest_id,
      lower(p_requested_environment),lower(p_requested_scope_type),
      lower(p_requested_scope_key),lower(p_requested_namespace),
      lower(p_requested_capability),'secret_resolution',
      p_requested_lifetime_seconds,
      coalesce(p_request_metadata,'{}'::jsonb)::text
    ),'sha256'),'hex');

  select * into v_existing
  from public.commercial_secret_resolution_execution_permit_idempotency
  where idempotency_key=p_idempotency_key
  for update;

  if found then
    if v_existing.request_hash<>v_hash then
      raise exception 'COMMERCIAL_SECRET_RESOLUTION_EXECUTION_PERMIT_IDEMPOTENCY_CONFLICT';
    end if;

    update public.commercial_secret_resolution_execution_permit_idempotency
    set replay_count=replay_count+1,last_seen_at=clock_timestamp()
    where id=v_existing.id;

    select * into strict v_request
    from public.commercial_secret_resolution_execution_permit_requests
    where id=v_existing.permit_request_id;

    perform public.append_commercial_secret_resolution_execution_permit_receipt(
      'REQUEST_REPLAYED',v_request.id,null,null,null,null,
      'replayed','PERMIT_REQUEST_REPLAYED',
      'Idempotent execution-permit request replayed',
      p_requested_by,p_correlation_id,
      jsonb_build_object('request_hash',v_hash)
    );

    return v_request;
  end if;

  insert into public.commercial_secret_resolution_execution_permit_requests(
    request_key,idempotency_key,permit_policy_id,
    handoff_request_id,handoff_decision_id,handoff_manifest_id,
    authorization_request_id,authorization_decision_id,
    requested_environment,requested_scope_type,requested_scope_key,
    requested_namespace,requested_capability,requested_operation,
    requested_lifetime_seconds,request_status,correlation_id,causation_id,
    requested_by,request_hash,request_metadata
  ) values (
    lower(p_request_key),p_idempotency_key,v_policy.id,
    v_handoff_request.id,v_handoff_decision.id,v_handoff_manifest.id,
    v_handoff_manifest.authorization_request_id,
    v_handoff_manifest.authorization_decision_id,
    lower(p_requested_environment),lower(p_requested_scope_type),
    lower(p_requested_scope_key),lower(p_requested_namespace),
    lower(p_requested_capability),'secret_resolution',
    p_requested_lifetime_seconds,'received',p_correlation_id,p_causation_id,
    p_requested_by,v_hash,coalesce(p_request_metadata,'{}'::jsonb)
  ) returning * into v_request;

  insert into public.commercial_secret_resolution_execution_permit_idempotency(
    idempotency_key,permit_request_id,request_hash
  ) values (
    p_idempotency_key,v_request.id,v_hash
  );

  perform public.append_commercial_secret_resolution_execution_permit_receipt(
    'REQUEST_ACCEPTED',v_request.id,null,null,null,null,
    'accepted','PERMIT_REQUEST_ACCEPTED',
    'Non-executable execution-permit request accepted',
    p_requested_by,p_correlation_id,
    jsonb_build_object('request_hash',v_hash)
  );

  perform public.append_commercial_secret_resolution_execution_permit_event(
    'SECRET_RESOLUTION_EXECUTION_PERMIT_REQUESTED',
    v_policy.id,v_request.id,null,null,null,null,
    'received','Execution-permit request recorded','PERMIT_ENGINE',
    p_correlation_id,p_causation_id,
    jsonb_build_object(
      'requested_operation','secret_resolution',
      'requested_lifetime_seconds',p_requested_lifetime_seconds,
      'metadata_only',true,
      'executable',false
    )
  );

  return v_request;
end
$$;

-- =============================================================================
-- 12. EVALUATE PERMIT REQUEST
-- =============================================================================

create function public.evaluate_commercial_secret_resolution_execution_permit_request(
  p_permit_request_id uuid,
  p_decided_by text
)
returns public.commercial_secret_resolution_execution_permit_decisions
language plpgsql
security definer
set search_path=public,extensions,pg_temp
as $$
declare
  v_request public.commercial_secret_resolution_execution_permit_requests;
  v_policy public.commercial_secret_resolution_execution_permit_policies;
  v_handoff_request public.commercial_secret_reference_handoff_requests;
  v_handoff_decision public.commercial_secret_reference_handoff_decisions;
  v_manifest public.commercial_secret_reference_handoff_manifests;
  v_authorization_decision public.commercial_secret_reference_authorization_decisions;
  v_binding public.commercial_secret_backend_bindings;
  v_version public.commercial_secret_backend_versions;
  v_existing public.commercial_secret_resolution_execution_permit_decisions;
  v_decision public.commercial_secret_resolution_execution_permit_decisions;

  v_status text:='approved';
  v_code text:='PERMIT_METADATA_APPROVED';
  v_reason text:='Metadata-only and non-executable permit eligibility approved';
  v_order integer:=0;
  v_pass boolean;
  v_not_before timestamptz;
  v_expires_at timestamptz;
  v_hash text;
begin
  select * into strict v_request
  from public.commercial_secret_resolution_execution_permit_requests
  where id=p_permit_request_id
  for update;

  select * into v_existing
  from public.commercial_secret_resolution_execution_permit_decisions
  where permit_request_id=v_request.id;

  if found then
    return v_existing;
  end if;

  select * into strict v_policy
  from public.commercial_secret_resolution_execution_permit_policies
  where id=v_request.permit_policy_id;

  select * into strict v_handoff_request
  from public.commercial_secret_reference_handoff_requests
  where id=v_request.handoff_request_id;

  select * into strict v_handoff_decision
  from public.commercial_secret_reference_handoff_decisions
  where id=v_request.handoff_decision_id;

  select * into strict v_manifest
  from public.commercial_secret_reference_handoff_manifests
  where id=v_request.handoff_manifest_id;

  select * into strict v_authorization_decision
  from public.commercial_secret_reference_authorization_decisions
  where id=v_request.authorization_decision_id;

  select * into strict v_binding
  from public.commercial_secret_backend_bindings
  where id=v_manifest.selected_backend_binding_id;

  select * into strict v_version
  from public.commercial_secret_backend_versions
  where id=v_manifest.selected_backend_version_id;

  -- 1. Accepted handoff decision
  v_order:=v_order+1;
  v_pass:=v_handoff_decision.accepted
          and v_handoff_decision.decision_status='accepted'
          and v_handoff_decision.decision_code='HANDOFF_ACCEPTED';

  insert into public.commercial_secret_resolution_execution_permit_evaluations(
    permit_request_id,evaluation_order,evaluation_code,evaluation_status,
    passed,evaluation_reason,evaluation_hash,evaluation_metadata
  ) values (
    v_request.id,v_order,'HANDOFF_DECISION',
    case when v_pass then 'passed' else 'failed' end,
    v_pass,
    case when v_pass then 'Handoff decision is accepted'
         else 'Handoff decision is not accepted' end,
    encode(extensions.digest(
      concat_ws('|',v_request.id,v_order,'HANDOFF_DECISION',v_pass),
      'sha256'
    ),'hex'),
    jsonb_build_object('decision_code',v_handoff_decision.decision_code)
  );

  if not v_pass then
    v_status:='blocked';
    v_code:='HANDOFF_NOT_ACCEPTED';
    v_reason:='Permit requires an accepted handoff decision';
  end if;

  -- 2. Manifest linkage
  v_order:=v_order+1;
  v_pass:=v_manifest.handoff_request_id=v_handoff_request.id
          and v_manifest.handoff_decision_id=v_handoff_decision.id
          and v_request.handoff_manifest_id=v_manifest.id
          and v_request.authorization_request_id=v_manifest.authorization_request_id
          and v_request.authorization_decision_id=v_manifest.authorization_decision_id;

  insert into public.commercial_secret_resolution_execution_permit_evaluations(
    permit_request_id,evaluation_order,evaluation_code,evaluation_status,
    passed,evaluation_reason,evaluation_hash,evaluation_metadata
  ) values (
    v_request.id,v_order,'HANDOFF_MANIFEST_LINK',
    case when v_pass then 'passed' else 'failed' end,
    v_pass,
    case when v_pass then 'Manifest chain is linked'
         else 'Manifest chain linkage mismatch' end,
    encode(extensions.digest(
      concat_ws('|',v_request.id,v_order,'HANDOFF_MANIFEST_LINK',v_pass),
      'sha256'
    ),'hex'),
    '{}'::jsonb
  );

  if v_status='approved' and not v_pass then
    v_status:='blocked';
    v_code:='HANDOFF_MANIFEST_LINK_MISMATCH';
    v_reason:='Handoff manifest linkage is inconsistent';
  end if;

  -- 3. Manifest passive status
  v_order:=v_order+1;
  v_pass:=v_manifest.manifest_status='held'
          and v_manifest.opaque_reference_contract
          and v_manifest.metadata_only
          and not v_manifest.executable
          and not v_manifest.dispatch_allowed
          and not v_manifest.activation_allowed
          and not v_manifest.backend_contact_allowed
          and not v_manifest.secret_resolution_allowed
          and not v_manifest.network_access_allowed;

  insert into public.commercial_secret_resolution_execution_permit_evaluations(
    permit_request_id,evaluation_order,evaluation_code,evaluation_status,
    passed,evaluation_reason,evaluation_hash,evaluation_metadata
  ) values (
    v_request.id,v_order,'HANDOFF_MANIFEST_STATUS',
    case when v_pass then 'passed' else 'failed' end,
    v_pass,
    case when v_pass then 'Manifest is held and metadata-only'
         else 'Manifest is not in passive held state' end,
    encode(extensions.digest(
      concat_ws('|',v_request.id,v_order,'HANDOFF_MANIFEST_STATUS',v_pass),
      'sha256'
    ),'hex'),
    jsonb_build_object(
      'manifest_status',v_manifest.manifest_status,
      'metadata_only',v_manifest.metadata_only,
      'executable',v_manifest.executable
    )
  );

  if v_status='approved' and not v_pass then
    v_status:='blocked';
    v_code:='HANDOFF_MANIFEST_NOT_HELD';
    v_reason:='Permit requires a passive held manifest';
  end if;

  -- 4. Authorization chain
  v_order:=v_order+1;
  v_pass:=v_authorization_decision.authorized
          and v_authorization_decision.decision_status='authorized'
          and v_authorization_decision.decision_code='AUTHORIZED'
          and v_handoff_decision.authorization_decision_id=v_authorization_decision.id
          and v_manifest.authorization_decision_id=v_authorization_decision.id;

  insert into public.commercial_secret_resolution_execution_permit_evaluations(
    permit_request_id,evaluation_order,evaluation_code,evaluation_status,
    passed,evaluation_reason,evaluation_hash,evaluation_metadata
  ) values (
    v_request.id,v_order,'AUTHORIZATION_CHAIN',
    case when v_pass then 'passed' else 'failed' end,
    v_pass,
    case when v_pass then 'Authorization chain remains AUTHORIZED'
         else 'Authorization chain mismatch' end,
    encode(extensions.digest(
      concat_ws('|',v_request.id,v_order,'AUTHORIZATION_CHAIN',v_pass),
      'sha256'
    ),'hex'),
    jsonb_build_object('authorization_code',v_authorization_decision.decision_code)
  );

  if v_status='approved' and not v_pass then
    v_status:='blocked';
    v_code:='AUTHORIZATION_CHAIN_MISMATCH';
    v_reason:='Authorization chain is not valid';
  end if;

  -- 5. Environment
  v_order:=v_order+1;
  v_pass:=v_request.requested_environment=v_manifest.environment
          and v_request.requested_environment=v_policy.environment;

  insert into public.commercial_secret_resolution_execution_permit_evaluations(
    permit_request_id,evaluation_order,evaluation_code,evaluation_status,
    passed,evaluation_reason,evaluation_hash,evaluation_metadata
  ) values (
    v_request.id,v_order,'ENVIRONMENT',
    case when v_pass then 'passed' else 'failed' end,
    v_pass,
    case when v_pass then 'Environment is consistent'
         else 'Environment mismatch' end,
    encode(extensions.digest(
      concat_ws('|',v_request.id,v_order,'ENVIRONMENT',v_pass),
      'sha256'
    ),'hex'),
    '{}'::jsonb
  );

  if v_status='approved' and not v_pass then
    v_status:='blocked';
    v_code:='ENVIRONMENT_MISMATCH';
    v_reason:='Requested environment differs from manifest or policy';
  end if;

  -- 6. Scope
  v_order:=v_order+1;
  v_pass:=v_request.requested_scope_type=v_manifest.scope_type
          and v_request.requested_scope_key=v_manifest.scope_key;

  insert into public.commercial_secret_resolution_execution_permit_evaluations(
    permit_request_id,evaluation_order,evaluation_code,evaluation_status,
    passed,evaluation_reason,evaluation_hash,evaluation_metadata
  ) values (
    v_request.id,v_order,'SCOPE',
    case when v_pass then 'passed' else 'failed' end,
    v_pass,
    case when v_pass then 'Scope matches manifest'
         else 'Scope mismatch' end,
    encode(extensions.digest(
      concat_ws('|',v_request.id,v_order,'SCOPE',v_pass),
      'sha256'
    ),'hex'),
    '{}'::jsonb
  );

  if v_status='approved' and not v_pass then
    v_status:='blocked';
    v_code:='SCOPE_MISMATCH';
    v_reason:='Requested scope differs from handoff manifest';
  end if;

  -- 7. Namespace
  v_order:=v_order+1;
  v_pass:=v_request.requested_namespace=v_manifest.namespace_code;

  insert into public.commercial_secret_resolution_execution_permit_evaluations(
    permit_request_id,evaluation_order,evaluation_code,evaluation_status,
    passed,evaluation_reason,evaluation_hash,evaluation_metadata
  ) values (
    v_request.id,v_order,'NAMESPACE',
    case when v_pass then 'passed' else 'failed' end,
    v_pass,
    case when v_pass then 'Namespace matches manifest'
         else 'Namespace mismatch' end,
    encode(extensions.digest(
      concat_ws('|',v_request.id,v_order,'NAMESPACE',v_pass),
      'sha256'
    ),'hex'),
    '{}'::jsonb
  );

  if v_status='approved' and not v_pass then
    v_status:='blocked';
    v_code:='NAMESPACE_MISMATCH';
    v_reason:='Requested namespace differs from handoff manifest';
  end if;

  -- 8. Capability
  v_order:=v_order+1;
  v_pass:=v_request.requested_capability=v_manifest.capability_code;

  insert into public.commercial_secret_resolution_execution_permit_evaluations(
    permit_request_id,evaluation_order,evaluation_code,evaluation_status,
    passed,evaluation_reason,evaluation_hash,evaluation_metadata
  ) values (
    v_request.id,v_order,'CAPABILITY',
    case when v_pass then 'passed' else 'failed' end,
    v_pass,
    case when v_pass then 'Capability matches manifest'
         else 'Capability mismatch' end,
    encode(extensions.digest(
      concat_ws('|',v_request.id,v_order,'CAPABILITY',v_pass),
      'sha256'
    ),'hex'),
    '{}'::jsonb
  );

  if v_status='approved' and not v_pass then
    v_status:='blocked';
    v_code:='CAPABILITY_MISMATCH';
    v_reason:='Requested capability differs from handoff manifest';
  end if;

  -- 9. Backend binding
  v_order:=v_order+1;
  v_pass:=v_binding.id=v_manifest.selected_backend_binding_id
          and v_binding.secret_backend_id=v_manifest.selected_backend_id
          and v_binding.secret_backend_version_id=v_manifest.selected_backend_version_id
          and v_binding.binding_status='validated'
          and v_version.id=v_manifest.selected_backend_version_id
          and v_version.version_status='validated';

  insert into public.commercial_secret_resolution_execution_permit_evaluations(
    permit_request_id,evaluation_order,evaluation_code,evaluation_status,
    passed,evaluation_reason,evaluation_hash,evaluation_metadata
  ) values (
    v_request.id,v_order,'BACKEND_BINDING',
    case when v_pass then 'passed' else 'failed' end,
    v_pass,
    case when v_pass then 'Backend binding and version are validated'
         else 'Backend binding or version mismatch' end,
    encode(extensions.digest(
      concat_ws('|',v_request.id,v_order,'BACKEND_BINDING',v_pass),
      'sha256'
    ),'hex'),
    '{}'::jsonb
  );

  if v_status='approved' and not v_pass then
    v_status:='blocked';
    v_code:='BACKEND_BINDING_MISMATCH';
    v_reason:='Backend binding does not satisfy permit integrity';
  end if;

  -- 10. Permit lifetime
  v_order:=v_order+1;
  v_pass:=v_request.requested_lifetime_seconds between 1
          and v_policy.maximum_permit_lifetime_seconds;

  insert into public.commercial_secret_resolution_execution_permit_evaluations(
    permit_request_id,evaluation_order,evaluation_code,evaluation_status,
    passed,evaluation_reason,evaluation_hash,evaluation_metadata
  ) values (
    v_request.id,v_order,'PERMIT_LIFETIME',
    case when v_pass then 'passed' else 'failed' end,
    v_pass,
    case when v_pass then 'Permit lifetime is within policy'
         else 'Permit lifetime exceeds policy' end,
    encode(extensions.digest(
      concat_ws('|',v_request.id,v_order,'PERMIT_LIFETIME',v_pass),
      'sha256'
    ),'hex'),
    jsonb_build_object(
      'requested_lifetime_seconds',v_request.requested_lifetime_seconds,
      'maximum_lifetime_seconds',v_policy.maximum_permit_lifetime_seconds
    )
  );

  if v_status='approved' and not v_pass then
    v_status:='blocked';
    v_code:='PERMIT_LIFETIME_INVALID';
    v_reason:='Requested permit lifetime is invalid';
  end if;

  -- 11. Passive posture
  v_order:=v_order+1;
  v_pass:=not v_policy.automatic_dispatch_enabled
          and not v_policy.permit_execution_enabled
          and not v_policy.endpoint_discovery_enabled
          and not v_policy.backend_probe_enabled
          and not v_policy.backend_contact_enabled
          and not v_policy.backend_authentication_enabled
          and not v_policy.secret_lookup_enabled
          and not v_policy.secret_resolution_enabled
          and not v_policy.secret_decryption_enabled
          and not v_policy.credential_material_loading_enabled
          and not v_policy.credential_delivery_enabled
          and not v_policy.network_access_enabled
          and v_policy.opaque_references_only
          and v_policy.plaintext_storage_forbidden
          and v_policy.metadata_only
          and v_policy.executable_permits_forbidden;

  insert into public.commercial_secret_resolution_execution_permit_evaluations(
    permit_request_id,evaluation_order,evaluation_code,evaluation_status,
    passed,evaluation_reason,evaluation_hash,evaluation_metadata
  ) values (
    v_request.id,v_order,'PASSIVE_POSTURE',
    case when v_pass then 'passed' else 'failed' end,
    v_pass,
    case when v_pass then 'Non-executable permit posture is enforced'
         else 'Permit policy violates passive posture' end,
    encode(extensions.digest(
      concat_ws('|',v_request.id,v_order,'PASSIVE_POSTURE',v_pass),
      'sha256'
    ),'hex'),
    jsonb_build_object(
      'permit_execution_enabled',v_policy.permit_execution_enabled,
      'backend_contact_enabled',v_policy.backend_contact_enabled,
      'secret_resolution_enabled',v_policy.secret_resolution_enabled,
      'network_access_enabled',v_policy.network_access_enabled,
      'metadata_only',v_policy.metadata_only
    )
  );

  if v_status='approved' and not v_pass then
    v_status:='blocked';
    v_code:='PASSIVE_POSTURE_VIOLATION';
    v_reason:='Execution-permit policy is not passive';
  end if;

  if v_status='approved' then
    v_not_before:=clock_timestamp();
    v_expires_at:=v_not_before+
      make_interval(secs=>v_request.requested_lifetime_seconds);
  end if;

  v_hash:=encode(extensions.digest(
    concat_ws('|',
      v_request.id,v_status,v_code,v_manifest.id,
      v_manifest.selected_backend_binding_id,
      v_manifest.selected_backend_id,
      v_manifest.selected_backend_version_id,
      v_request.requested_environment,v_request.requested_scope_type,
      v_request.requested_scope_key,v_request.requested_namespace,
      v_request.requested_capability,v_request.requested_operation,
      v_request.requested_lifetime_seconds,v_not_before,v_expires_at,v_reason
    ),'sha256'),'hex');

  insert into public.commercial_secret_resolution_execution_permit_decisions(
    permit_request_id,decision_status,decision_code,approved,
    handoff_manifest_id,selected_backend_binding_id,selected_backend_id,
    selected_backend_version_id,resolved_environment,resolved_scope_type,
    resolved_scope_key,resolved_namespace,resolved_capability,resolved_operation,
    granted_lifetime_seconds,not_before,expires_at,
    decided_by,decision_reason,decision_hash,decision_metadata
  ) values (
    v_request.id,v_status,v_code,(v_status='approved'),
    v_manifest.id,v_manifest.selected_backend_binding_id,
    v_manifest.selected_backend_id,v_manifest.selected_backend_version_id,
    v_request.requested_environment,v_request.requested_scope_type,
    v_request.requested_scope_key,v_request.requested_namespace,
    v_request.requested_capability,v_request.requested_operation,
    case when v_status='approved' then v_request.requested_lifetime_seconds end,
    v_not_before,v_expires_at,
    p_decided_by,v_reason,v_hash,
    jsonb_build_object(
      'metadata_only',true,
      'executable',false,
      'revocable',true,
      'evaluation_count',v_order
    )
  ) returning * into v_decision;

  update public.commercial_secret_resolution_execution_permit_requests
  set request_status=v_status,
      evaluated_at=clock_timestamp(),
      terminal_reason=v_reason
  where id=v_request.id;

  perform public.append_commercial_secret_resolution_execution_permit_receipt(
    'EVALUATION_COMPLETED',v_request.id,v_decision.id,null,null,null,
    case when v_status='approved' then 'passed' else v_status end,
    v_code,v_reason,p_decided_by,v_request.correlation_id,
    jsonb_build_object('evaluation_count',v_order)
  );

  perform public.append_commercial_secret_resolution_execution_permit_receipt(
    'DECISION_RECORDED',v_request.id,v_decision.id,null,null,null,
    v_status,v_code,v_reason,p_decided_by,v_request.correlation_id,
    jsonb_build_object('approved',v_decision.approved)
  );

  perform public.append_commercial_secret_resolution_execution_permit_event(
    'SECRET_RESOLUTION_EXECUTION_PERMIT_DECIDED',
    v_policy.id,v_request.id,v_decision.id,null,null,null,
    v_status,v_reason,'PERMIT_ENGINE',
    v_request.correlation_id,v_request.causation_id,
    jsonb_build_object(
      'decision_code',v_code,
      'approved',v_decision.approved,
      'metadata_only',true,
      'executable',false
    )
  );

  return v_decision;
end
$$;

-- =============================================================================
-- 13. ISSUE NON-EXECUTABLE PERMIT
-- =============================================================================

create function public.issue_commercial_secret_resolution_execution_permit(
  p_permit_request_id uuid,
  p_issued_by text,
  p_permit_metadata jsonb default '{}'::jsonb
)
returns public.commercial_secret_resolution_execution_permits
language plpgsql
security definer
set search_path=public,extensions,pg_temp
as $$
declare
  v_request public.commercial_secret_resolution_execution_permit_requests;
  v_decision public.commercial_secret_resolution_execution_permit_decisions;
  v_handoff_manifest public.commercial_secret_reference_handoff_manifests;
  v_handoff_decision public.commercial_secret_reference_handoff_decisions;
  v_existing public.commercial_secret_resolution_execution_permits;
  v_permit public.commercial_secret_resolution_execution_permits;
  v_key text;
  v_hash text;
begin
  select * into strict v_request
  from public.commercial_secret_resolution_execution_permit_requests
  where id=p_permit_request_id;

  select * into strict v_decision
  from public.commercial_secret_resolution_execution_permit_decisions
  where permit_request_id=v_request.id;

  if not v_decision.approved
     or v_decision.decision_status<>'approved'
     or v_decision.decision_code<>'PERMIT_METADATA_APPROVED' then
    raise exception 'COMMERCIAL_SECRET_RESOLUTION_EXECUTION_PERMIT_REQUIRES_APPROVED_DECISION';
  end if;

  select * into strict v_handoff_manifest
  from public.commercial_secret_reference_handoff_manifests
  where id=v_request.handoff_manifest_id;

  select * into strict v_handoff_decision
  from public.commercial_secret_reference_handoff_decisions
  where id=v_request.handoff_decision_id;

  if v_handoff_manifest.manifest_status<>'held'
     or not v_handoff_manifest.metadata_only
     or v_handoff_manifest.executable
     or not v_handoff_decision.accepted then
    raise exception 'COMMERCIAL_SECRET_RESOLUTION_EXECUTION_PERMIT_HANDOFF_NO_LONGER_VALID';
  end if;

  select * into v_existing
  from public.commercial_secret_resolution_execution_permits
  where permit_request_id=v_request.id;

  if found then
    return v_existing;
  end if;

  v_key:='commercial:secret_resolution:permit:'||
    replace(v_request.id::text,'-','');

  v_hash:=encode(extensions.digest(
    concat_ws('|',
      v_key,v_request.id,v_decision.id,
      v_request.handoff_request_id,v_request.handoff_decision_id,
      v_request.handoff_manifest_id,v_request.authorization_request_id,
      v_request.authorization_decision_id,
      v_decision.selected_backend_binding_id,
      v_decision.selected_backend_id,
      v_decision.selected_backend_version_id,
      v_decision.resolved_environment,v_decision.resolved_scope_type,
      v_decision.resolved_scope_key,v_decision.resolved_namespace,
      v_decision.resolved_capability,v_decision.resolved_operation,
      v_decision.not_before,v_decision.expires_at,
      coalesce(p_permit_metadata,'{}'::jsonb)::text
    ),'sha256'),'hex');

  insert into public.commercial_secret_resolution_execution_permits(
    permit_key,permit_request_id,permit_decision_id,
    handoff_request_id,handoff_decision_id,handoff_manifest_id,
    authorization_request_id,authorization_decision_id,
    selected_backend_binding_id,selected_backend_id,selected_backend_version_id,
    environment,scope_type,scope_key,namespace_code,capability_code,
    operation_code,permit_status,not_before,expires_at,maximum_uses,
    permit_hash,permit_metadata,issued_by
  ) values (
    v_key,v_request.id,v_decision.id,
    v_request.handoff_request_id,v_request.handoff_decision_id,
    v_request.handoff_manifest_id,v_request.authorization_request_id,
    v_request.authorization_decision_id,
    v_decision.selected_backend_binding_id,v_decision.selected_backend_id,
    v_decision.selected_backend_version_id,
    v_decision.resolved_environment,v_decision.resolved_scope_type,
    v_decision.resolved_scope_key,v_decision.resolved_namespace,
    v_decision.resolved_capability,v_decision.resolved_operation,
    'issued',v_decision.not_before,v_decision.expires_at,1,
    v_hash,coalesce(p_permit_metadata,'{}'::jsonb),p_issued_by
  ) returning * into v_permit;

  perform public.append_commercial_secret_resolution_execution_permit_receipt(
    'PERMIT_ISSUED',v_request.id,v_decision.id,v_permit.id,null,null,
    'issued','NON_EXECUTABLE_PERMIT_ISSUED',
    'Metadata-only, non-executable and revocable permit issued',
    p_issued_by,v_request.correlation_id,
    jsonb_build_object(
      'permit_hash',v_permit.permit_hash,
      'expires_at',v_permit.expires_at,
      'executable',false
    )
  );

  perform public.append_commercial_secret_resolution_execution_permit_event(
    'SECRET_RESOLUTION_EXECUTION_PERMIT_ISSUED',
    v_request.permit_policy_id,v_request.id,v_decision.id,v_permit.id,null,null,
    'issued','Non-executable resolution permit issued','PERMIT_ENGINE',
    v_request.correlation_id,v_request.causation_id,
    jsonb_build_object(
      'metadata_only',true,
      'executable',false,
      'revocable',true,
      'bearer_credential',false
    )
  );

  return v_permit;
end
$$;

-- =============================================================================
-- 14. REVOKE PERMIT
-- =============================================================================

create function public.revoke_commercial_secret_resolution_execution_permit(
  p_execution_permit_id uuid,
  p_revocation_key text,
  p_revocation_code text,
  p_revocation_reason text,
  p_revoked_by text,
  p_correlation_id uuid default null,
  p_causation_id uuid default null,
  p_revocation_metadata jsonb default '{}'::jsonb
)
returns public.commercial_secret_resolution_execution_permit_revocations
language plpgsql
security definer
set search_path=public,extensions,pg_temp
as $$
declare
  v_permit public.commercial_secret_resolution_execution_permits;
  v_request public.commercial_secret_resolution_execution_permit_requests;
  v_existing public.commercial_secret_resolution_execution_permit_revocations;
  v_revocation public.commercial_secret_resolution_execution_permit_revocations;
  v_hash text;
begin
  select * into strict v_permit
  from public.commercial_secret_resolution_execution_permits
  where id=p_execution_permit_id;

  if not v_permit.revocable then
    raise exception 'COMMERCIAL_SECRET_RESOLUTION_EXECUTION_PERMIT_NOT_REVOCABLE';
  end if;

  select * into strict v_request
  from public.commercial_secret_resolution_execution_permit_requests
  where id=v_permit.permit_request_id;

  select * into v_existing
  from public.commercial_secret_resolution_execution_permit_revocations
  where execution_permit_id=v_permit.id;

  if found then
    if v_existing.revocation_key<>lower(p_revocation_key)
       or v_existing.revocation_code<>upper(p_revocation_code)
       or v_existing.revocation_reason<>p_revocation_reason then
      raise exception 'COMMERCIAL_SECRET_RESOLUTION_EXECUTION_PERMIT_REVOCATION_CONFLICT';
    end if;

    return v_existing;
  end if;

  v_hash:=encode(extensions.digest(
    concat_ws('|',
      v_permit.id,lower(p_revocation_key),upper(p_revocation_code),
      p_revocation_reason,p_revoked_by,p_correlation_id,p_causation_id,
      coalesce(p_revocation_metadata,'{}'::jsonb)::text,
      clock_timestamp()::text
    ),'sha256'),'hex');

  insert into public.commercial_secret_resolution_execution_permit_revocations(
    execution_permit_id,revocation_key,revocation_code,revocation_reason,
    revoked_by,correlation_id,causation_id,revocation_hash,revocation_metadata
  ) values (
    v_permit.id,lower(p_revocation_key),upper(p_revocation_code),
    p_revocation_reason,p_revoked_by,
    coalesce(p_correlation_id,v_request.correlation_id),
    p_causation_id,v_hash,coalesce(p_revocation_metadata,'{}'::jsonb)
  ) returning * into v_revocation;

  perform public.append_commercial_secret_resolution_execution_permit_receipt(
    'PERMIT_REVOKED',v_request.id,v_permit.permit_decision_id,v_permit.id,
    v_revocation.id,null,'revoked',v_revocation.revocation_code,
    v_revocation.revocation_reason,p_revoked_by,
    coalesce(p_correlation_id,v_request.correlation_id),
    jsonb_build_object('effective_at',v_revocation.effective_at)
  );

  perform public.append_commercial_secret_resolution_execution_permit_event(
    'SECRET_RESOLUTION_EXECUTION_PERMIT_REVOKED',
    v_request.permit_policy_id,v_request.id,v_permit.permit_decision_id,
    v_permit.id,v_revocation.id,null,'revoked',
    v_revocation.revocation_reason,'PERMIT_ENGINE',
    coalesce(p_correlation_id,v_request.correlation_id),
    p_causation_id,
    jsonb_build_object('revocation_code',v_revocation.revocation_code)
  );

  return v_revocation;
end
$$;

-- =============================================================================
-- 15. RECORD BLOCKED EXECUTION ATTEMPT
-- =============================================================================

create function public.record_blocked_secret_resolution_execution_permit_attempt(
  p_permit_request_id uuid,
  p_attempt_type text,
  p_attempted_by text,
  p_attempt_metadata jsonb default '{}'::jsonb
)
returns public.commercial_secret_resolution_execution_permit_attempts
language plpgsql
security definer
set search_path=public,extensions,pg_temp
as $$
declare
  v_request public.commercial_secret_resolution_execution_permit_requests;
  v_decision public.commercial_secret_resolution_execution_permit_decisions;
  v_permit public.commercial_secret_resolution_execution_permits;
  v_attempt public.commercial_secret_resolution_execution_permit_attempts;
  v_hash text;
begin
  select * into strict v_request
  from public.commercial_secret_resolution_execution_permit_requests
  where id=p_permit_request_id;

  select * into v_decision
  from public.commercial_secret_resolution_execution_permit_decisions
  where permit_request_id=v_request.id;

  select * into v_permit
  from public.commercial_secret_resolution_execution_permits
  where permit_request_id=v_request.id;

  v_hash:=encode(extensions.digest(
    concat_ws('|',
      v_request.id,v_decision.id,v_permit.id,upper(p_attempt_type),
      'blocked','NON_EXECUTABLE_PERMIT_OPERATION_FORBIDDEN',
      p_attempted_by,coalesce(p_attempt_metadata,'{}'::jsonb)::text,
      clock_timestamp()::text
    ),'sha256'),'hex');

  insert into public.commercial_secret_resolution_execution_permit_attempts(
    permit_request_id,permit_decision_id,execution_permit_id,
    attempt_type,attempt_status,block_code,attempted_by,correlation_id,
    attempt_hash,attempt_metadata
  ) values (
    v_request.id,v_decision.id,v_permit.id,
    upper(p_attempt_type),'blocked',
    'NON_EXECUTABLE_PERMIT_OPERATION_FORBIDDEN',
    p_attempted_by,v_request.correlation_id,
    v_hash,coalesce(p_attempt_metadata,'{}'::jsonb)
  ) returning * into v_attempt;

  perform public.append_commercial_secret_resolution_execution_permit_receipt(
    'EXECUTION_BLOCKED',v_request.id,v_decision.id,v_permit.id,null,
    v_attempt.id,'blocked','NON_EXECUTABLE_PERMIT_OPERATION_FORBIDDEN',
    'Execution is forbidden because permits are metadata-only',
    p_attempted_by,v_request.correlation_id,
    jsonb_build_object('attempt_type',v_attempt.attempt_type)
  );

  perform public.append_commercial_secret_resolution_execution_permit_event(
    'SECRET_RESOLUTION_EXECUTION_PERMIT_OPERATION_BLOCKED',
    v_request.permit_policy_id,v_request.id,v_decision.id,v_permit.id,null,
    v_attempt.id,'blocked',
    'Active operation blocked by non-executable permit contract',
    'PERMIT_ENGINE',v_request.correlation_id,v_request.causation_id,
    jsonb_build_object('attempt_type',v_attempt.attempt_type)
  );

  return v_attempt;
end
$$;

-- =============================================================================
-- 16. READ MODEL
-- =============================================================================

create view public.commercial_secret_resolution_execution_permit_read_model
with (security_invoker=true)
as
select
  r.id as permit_request_id,
  r.request_key,
  r.idempotency_key,
  r.request_status,

  r.handoff_request_id,
  r.handoff_decision_id,
  r.handoff_manifest_id,
  r.authorization_request_id,
  r.authorization_decision_id,

  r.requested_environment,
  r.requested_scope_type,
  r.requested_scope_key,
  r.requested_namespace,
  r.requested_capability,
  r.requested_operation,
  r.requested_lifetime_seconds,

  d.id as permit_decision_id,
  d.decision_status,
  d.decision_code,
  d.approved,
  d.selected_backend_binding_id,
  d.selected_backend_id,
  d.selected_backend_version_id,
  d.not_before as decision_not_before,
  d.expires_at as decision_expires_at,

  p.id as execution_permit_id,
  p.permit_key,
  p.permit_status as recorded_permit_status,
  p.not_before,
  p.expires_at,
  p.maximum_uses,
  p.opaque_reference_contract,
  p.metadata_only,
  p.executable,
  p.revocable,
  p.bearer_credential,
  p.transferable,
  p.permit_execution_allowed,
  p.dispatch_allowed,
  p.endpoint_discovery_allowed,
  p.backend_contact_allowed,
  p.authentication_allowed,
  p.secret_lookup_allowed,
  p.secret_resolution_allowed,
  p.decryption_allowed,
  p.material_loading_allowed,
  p.delivery_allowed,
  p.network_access_allowed,

  rv.id as permit_revocation_id,
  rv.revocation_code,
  rv.revocation_reason,
  rv.effective_at as revoked_at,

  case
    when p.id is null then 'not_issued'
    when rv.id is not null and rv.effective_at<=clock_timestamp() then 'revoked'
    when clock_timestamp()<p.not_before then 'not_yet_valid'
    when clock_timestamp()>=p.expires_at then 'expired'
    else 'eligible_metadata_only'
  end as effective_permit_status,

  (
    p.id is not null
    and rv.id is null
    and clock_timestamp()>=p.not_before
    and clock_timestamp()<p.expires_at
    and p.metadata_only
    and not p.executable
  ) as metadata_eligibility_current,

  false as execution_authorized,

  coalesce(ev.evaluation_count,0) as evaluation_count,
  coalesce(attempts.attempt_count,0) as attempt_count,
  coalesce(rc.receipt_count,0) as receipt_count,
  coalesce(events.event_count,0) as event_count,
  coalesce(i.replay_count,0) as replay_count,

  r.correlation_id,
  r.requested_at,
  r.evaluated_at,
  p.issued_at
from public.commercial_secret_resolution_execution_permit_requests r
left join public.commercial_secret_resolution_execution_permit_decisions d
  on d.permit_request_id=r.id
left join public.commercial_secret_resolution_execution_permits p
  on p.permit_request_id=r.id
left join public.commercial_secret_resolution_execution_permit_revocations rv
  on rv.execution_permit_id=p.id
left join public.commercial_secret_resolution_execution_permit_idempotency i
  on i.permit_request_id=r.id
left join lateral (
  select count(*)::bigint as evaluation_count
  from public.commercial_secret_resolution_execution_permit_evaluations x
  where x.permit_request_id=r.id
) ev on true
left join lateral (
  select count(*)::bigint as attempt_count
  from public.commercial_secret_resolution_execution_permit_attempts x
  where x.permit_request_id=r.id
) attempts on true
left join lateral (
  select count(*)::bigint as receipt_count
  from public.commercial_secret_resolution_execution_permit_receipts x
  where x.permit_request_id=r.id
) rc on true
left join lateral (
  select count(*)::bigint as event_count
  from public.commercial_secret_resolution_execution_permit_events x
  where x.permit_request_id=r.id
) events on true;

comment on view public.commercial_secret_resolution_execution_permit_read_model is
'Effective permit state including expiry and append-only revocation. execution_authorized is always false.';

-- =============================================================================
-- 17. FOUNDATION DATA
-- =============================================================================

insert into public.commercial_secret_resolution_execution_permit_policies(
  policy_code,environment,policy_status,policy_version,
  maximum_permit_lifetime_seconds,default_permit_lifetime_seconds,
  clock_skew_tolerance_seconds,created_by,approved_by,approved_at,
  policy_metadata
) values (
  'commercial:secret_resolution_execution_permit:v1',
  'production','approved',1,
  300,120,15,
  'MIGRATION_135','MIGRATION_135',clock_timestamp(),
  jsonb_build_object(
    'opaque_references_only',true,
    'plaintext_storage_forbidden',true,
    'metadata_only',true,
    'executable',false,
    'revocable',true,
    'bearer_credential',false,
    'transferable',false,
    'execution_authorized',false
  )
);

select public.append_commercial_secret_resolution_execution_permit_event(
  'SECRET_RESOLUTION_EXECUTION_PERMIT_INITIALIZED',
  p.id,null,null,null,null,null,
  'approved',
  'Secret-resolution execution-permit governance initialized in passive mode',
  'MIGRATION_135',
  gen_random_uuid(),null,
  jsonb_build_object(
    'permit_issuance_enabled',true,
    'revocation_enabled',true,
    'automatic_dispatch_enabled',false,
    'permit_execution_enabled',false,
    'endpoint_discovery_enabled',false,
    'backend_contact_enabled',false,
    'secret_lookup_enabled',false,
    'secret_resolution_enabled',false,
    'secret_decryption_enabled',false,
    'credential_material_loading_enabled',false,
    'credential_delivery_enabled',false,
    'network_access_enabled',false,
    'metadata_only',true,
    'executable',false
  )
)
from public.commercial_secret_resolution_execution_permit_policies p
where p.policy_code='commercial:secret_resolution_execution_permit:v1'
  and p.environment='production';

-- =============================================================================
-- 18. RLS AND PRIVILEGES
-- =============================================================================

alter table public.commercial_secret_resolution_execution_permit_policies enable row level security;
alter table public.commercial_secret_resolution_execution_permit_requests enable row level security;
alter table public.commercial_secret_resolution_execution_permit_idempotency enable row level security;
alter table public.commercial_secret_resolution_execution_permit_evaluations enable row level security;
alter table public.commercial_secret_resolution_execution_permit_decisions enable row level security;
alter table public.commercial_secret_resolution_execution_permits enable row level security;
alter table public.commercial_secret_resolution_execution_permit_revocations enable row level security;
alter table public.commercial_secret_resolution_execution_permit_attempts enable row level security;
alter table public.commercial_secret_resolution_execution_permit_receipts enable row level security;
alter table public.commercial_secret_resolution_execution_permit_events enable row level security;

revoke all on public.commercial_secret_resolution_execution_permit_policies from public,anon,authenticated;
revoke all on public.commercial_secret_resolution_execution_permit_requests from public,anon,authenticated;
revoke all on public.commercial_secret_resolution_execution_permit_idempotency from public,anon,authenticated;
revoke all on public.commercial_secret_resolution_execution_permit_evaluations from public,anon,authenticated;
revoke all on public.commercial_secret_resolution_execution_permit_decisions from public,anon,authenticated;
revoke all on public.commercial_secret_resolution_execution_permits from public,anon,authenticated;
revoke all on public.commercial_secret_resolution_execution_permit_revocations from public,anon,authenticated;
revoke all on public.commercial_secret_resolution_execution_permit_attempts from public,anon,authenticated;
revoke all on public.commercial_secret_resolution_execution_permit_receipts from public,anon,authenticated;
revoke all on public.commercial_secret_resolution_execution_permit_events from public,anon,authenticated;
revoke all on public.commercial_secret_resolution_execution_permit_read_model from public,anon,authenticated;

grant select on public.commercial_secret_resolution_execution_permit_policies to service_role;
grant select,insert,update on public.commercial_secret_resolution_execution_permit_requests to service_role;
grant select,insert,update on public.commercial_secret_resolution_execution_permit_idempotency to service_role;
grant select,insert on public.commercial_secret_resolution_execution_permit_evaluations to service_role;
grant select,insert on public.commercial_secret_resolution_execution_permit_decisions to service_role;
grant select,insert on public.commercial_secret_resolution_execution_permits to service_role;
grant select,insert on public.commercial_secret_resolution_execution_permit_revocations to service_role;
grant select,insert on public.commercial_secret_resolution_execution_permit_attempts to service_role;
grant select,insert on public.commercial_secret_resolution_execution_permit_receipts to service_role;
grant select,insert on public.commercial_secret_resolution_execution_permit_events to service_role;
grant select on public.commercial_secret_resolution_execution_permit_read_model to service_role;

revoke all on function public.append_commercial_secret_resolution_execution_permit_receipt(
  text,uuid,uuid,uuid,uuid,uuid,text,text,text,text,uuid,jsonb
) from public,anon,authenticated;
revoke all on function public.append_commercial_secret_resolution_execution_permit_event(
  text,uuid,uuid,uuid,uuid,uuid,uuid,text,text,text,uuid,uuid,jsonb
) from public,anon,authenticated;
revoke all on function public.enqueue_commercial_secret_resolution_execution_permit_request(
  text,text,uuid,uuid,uuid,text,text,text,text,text,integer,text,uuid,uuid,jsonb
) from public,anon,authenticated;
revoke all on function public.evaluate_commercial_secret_resolution_execution_permit_request(
  uuid,text
) from public,anon,authenticated;
revoke all on function public.issue_commercial_secret_resolution_execution_permit(
  uuid,text,jsonb
) from public,anon,authenticated;
revoke all on function public.revoke_commercial_secret_resolution_execution_permit(
  uuid,text,text,text,text,uuid,uuid,jsonb
) from public,anon,authenticated;
revoke all on function public.record_blocked_secret_resolution_execution_permit_attempt(
  uuid,text,text,jsonb
) from public,anon,authenticated;

grant execute on function public.append_commercial_secret_resolution_execution_permit_receipt(
  text,uuid,uuid,uuid,uuid,uuid,text,text,text,text,uuid,jsonb
) to service_role;
grant execute on function public.append_commercial_secret_resolution_execution_permit_event(
  text,uuid,uuid,uuid,uuid,uuid,uuid,text,text,text,uuid,uuid,jsonb
) to service_role;
grant execute on function public.enqueue_commercial_secret_resolution_execution_permit_request(
  text,text,uuid,uuid,uuid,text,text,text,text,text,integer,text,uuid,uuid,jsonb
) to service_role;
grant execute on function public.evaluate_commercial_secret_resolution_execution_permit_request(
  uuid,text
) to service_role;
grant execute on function public.issue_commercial_secret_resolution_execution_permit(
  uuid,text,jsonb
) to service_role;
grant execute on function public.revoke_commercial_secret_resolution_execution_permit(
  uuid,text,text,text,text,uuid,uuid,jsonb
) to service_role;
grant execute on function public.record_blocked_secret_resolution_execution_permit_attempt(
  uuid,text,text,jsonb
) to service_role;

-- =============================================================================
-- 19. FOUNDATION CERTIFICATION
-- =============================================================================

do $$
declare
  v_policy public.commercial_secret_resolution_execution_permit_policies;
  v_policy_count bigint;
  v_request_count bigint;
  v_idempotency_count bigint;
  v_evaluation_count bigint;
  v_decision_count bigint;
  v_permit_count bigint;
  v_revocation_count bigint;
  v_attempt_count bigint;
  v_receipt_count bigint;
  v_event_count bigint;
begin
  select * into strict v_policy
  from public.commercial_secret_resolution_execution_permit_policies
  where policy_code='commercial:secret_resolution_execution_permit:v1'
    and environment='production'
    and policy_status='approved';

  select count(*) into v_policy_count
  from public.commercial_secret_resolution_execution_permit_policies
  where policy_code='commercial:secret_resolution_execution_permit:v1'
    and environment='production';

  select count(*) into v_request_count
  from public.commercial_secret_resolution_execution_permit_requests;

  select count(*) into v_idempotency_count
  from public.commercial_secret_resolution_execution_permit_idempotency;

  select count(*) into v_evaluation_count
  from public.commercial_secret_resolution_execution_permit_evaluations;

  select count(*) into v_decision_count
  from public.commercial_secret_resolution_execution_permit_decisions;

  select count(*) into v_permit_count
  from public.commercial_secret_resolution_execution_permits;

  select count(*) into v_revocation_count
  from public.commercial_secret_resolution_execution_permit_revocations;

  select count(*) into v_attempt_count
  from public.commercial_secret_resolution_execution_permit_attempts;

  select count(*) into v_receipt_count
  from public.commercial_secret_resolution_execution_permit_receipts;

  select count(*) into v_event_count
  from public.commercial_secret_resolution_execution_permit_events;

  if v_policy_count<>1
     or v_request_count<>0
     or v_idempotency_count<>0
     or v_evaluation_count<>0
     or v_decision_count<>0
     or v_permit_count<>0
     or v_revocation_count<>0
     or v_attempt_count<>0
     or v_receipt_count<>0
     or v_event_count<>1 then
    raise exception
      'MIGRATION_135_COUNT_ASSERTION_FAILED policy=%, request=%, idempotency=%, evaluation=%, decision=%, permit=%, revocation=%, attempt=%, receipt=%, event=%',
      v_policy_count,v_request_count,v_idempotency_count,v_evaluation_count,
      v_decision_count,v_permit_count,v_revocation_count,v_attempt_count,
      v_receipt_count,v_event_count;
  end if;

  if not (
    v_policy.intake_enabled
    and v_policy.handoff_verification_enabled
    and v_policy.manifest_integrity_verification_enabled
    and v_policy.scope_integrity_verification_enabled
    and v_policy.capability_integrity_verification_enabled
    and v_policy.backend_binding_integrity_enabled
    and v_policy.expiry_enforcement_enabled
    and v_policy.revocation_enabled
    and v_policy.decision_recording_enabled
    and v_policy.permit_issuance_enabled
  ) then
    raise exception 'MIGRATION_135_CAPABILITY_MATRIX_FAILED';
  end if;

  if v_policy.automatic_dispatch_enabled
     or v_policy.permit_execution_enabled
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
    raise exception 'MIGRATION_135_PASSIVE_POSTURE_FAILED';
  end if;

  if not v_policy.opaque_references_only
     or not v_policy.plaintext_storage_forbidden
     or not v_policy.metadata_only
     or not v_policy.executable_permits_forbidden then
    raise exception 'MIGRATION_135_SECURITY_CONTRACT_FAILED';
  end if;

  raise notice
    'MIGRATION_135_CERTIFIED policy_count=%, request_count=%, idempotency_count=%, evaluation_count=%, decision_count=%, permit_count=%, revocation_count=%, attempt_count=%, receipt_count=%, event_count=%, intake_enabled=%, handoff_verification_enabled=%, manifest_integrity_verification_enabled=%, scope_integrity_verification_enabled=%, capability_integrity_verification_enabled=%, backend_binding_integrity_enabled=%, expiry_enforcement_enabled=%, revocation_enabled=%, decision_recording_enabled=%, permit_issuance_enabled=%, maximum_permit_lifetime_seconds=%, default_permit_lifetime_seconds=%, automatic_dispatch_enabled=%, permit_execution_enabled=%, endpoint_discovery_enabled=%, backend_probe_enabled=%, backend_contact_enabled=%, backend_authentication_enabled=%, secret_lookup_enabled=%, secret_resolution_enabled=%, secret_decryption_enabled=%, credential_material_loading_enabled=%, credential_delivery_enabled=%, network_access_enabled=%, opaque_references_only=%, plaintext_storage_forbidden=%, metadata_only=%, executable_permits_forbidden=%, execution_authorized=false',
    v_policy_count,v_request_count,v_idempotency_count,v_evaluation_count,
    v_decision_count,v_permit_count,v_revocation_count,v_attempt_count,
    v_receipt_count,v_event_count,
    v_policy.intake_enabled,v_policy.handoff_verification_enabled,
    v_policy.manifest_integrity_verification_enabled,
    v_policy.scope_integrity_verification_enabled,
    v_policy.capability_integrity_verification_enabled,
    v_policy.backend_binding_integrity_enabled,
    v_policy.expiry_enforcement_enabled,v_policy.revocation_enabled,
    v_policy.decision_recording_enabled,v_policy.permit_issuance_enabled,
    v_policy.maximum_permit_lifetime_seconds,
    v_policy.default_permit_lifetime_seconds,
    v_policy.automatic_dispatch_enabled,v_policy.permit_execution_enabled,
    v_policy.endpoint_discovery_enabled,v_policy.backend_probe_enabled,
    v_policy.backend_contact_enabled,v_policy.backend_authentication_enabled,
    v_policy.secret_lookup_enabled,v_policy.secret_resolution_enabled,
    v_policy.secret_decryption_enabled,
    v_policy.credential_material_loading_enabled,
    v_policy.credential_delivery_enabled,v_policy.network_access_enabled,
    v_policy.opaque_references_only,v_policy.plaintext_storage_forbidden,
    v_policy.metadata_only,v_policy.executable_permits_forbidden;
end
$$;

commit;
