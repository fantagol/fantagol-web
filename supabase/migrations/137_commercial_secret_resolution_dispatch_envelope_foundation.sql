-- =============================================================================
-- FANTAGOL
-- Migration: 137_commercial_secret_resolution_dispatch_envelope_foundation.sql
-- Milestone: Commercial Secret Resolution Dispatch Envelope Foundation
--
-- Purpose:
--   Establish the passive governance boundary that may package a currently
--   eligible metadata-only execution permit into an immutable dispatch envelope.
--
-- IMPORTANT:
--   An envelope created by this foundation is:
--     - metadata-only;
--     - opaque-reference-only;
--     - held and non-dispatchable;
--     - non-executable;
--     - non-transferable;
--     - incapable of contacting a backend or accessing secret material.
--
-- This migration DOES NOT:
--   - enqueue or dispatch runtime work;
--   - discover endpoints;
--   - probe or contact backends;
--   - authenticate;
--   - look up, resolve, decrypt or load secrets;
--   - deliver credential material;
--   - perform network access;
--   - mutate purchases, checkout, wallets, ledger or runtime outbox.
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
  if to_regclass('public.commercial_secret_resolution_execution_permit_policies') is null
     or to_regclass('public.commercial_secret_resolution_execution_permit_requests') is null
     or to_regclass('public.commercial_secret_resolution_execution_permit_decisions') is null
     or to_regclass('public.commercial_secret_resolution_execution_permits') is null
     or to_regclass('public.commercial_secret_resolution_execution_permit_revocations') is null
     or to_regclass('public.commercial_secret_resolution_execution_permit_read_model') is null
     or to_regclass('public.commercial_secret_backend_bindings') is null
     or to_regclass('public.commercial_secret_backends') is null
     or to_regclass('public.commercial_secret_backend_versions') is null then
    raise exception 'MIGRATION_137_REQUIRES_MIGRATIONS_127_TO_136';
  end if;
end
$$;

-- =============================================================================
-- 1. DISPATCH ENVELOPE POLICY
-- =============================================================================

create table public.commercial_secret_resolution_dispatch_envelope_policies (
  id uuid primary key default gen_random_uuid(),
  policy_code text not null,
  environment text not null default 'production',
  policy_status text not null default 'draft',
  policy_version integer not null default 1,

  intake_enabled boolean not null default true,
  permit_verification_enabled boolean not null default true,
  permit_expiry_enforcement_enabled boolean not null default true,
  permit_revocation_enforcement_enabled boolean not null default true,
  scope_integrity_verification_enabled boolean not null default true,
  backend_binding_integrity_enabled boolean not null default true,
  decision_recording_enabled boolean not null default true,
  envelope_issuance_enabled boolean not null default true,
  envelope_cancellation_enabled boolean not null default true,

  maximum_envelope_lifetime_seconds integer not null default 120,
  default_envelope_lifetime_seconds integer not null default 60,

  automatic_dispatch_enabled boolean not null default false,
  dispatch_enabled boolean not null default false,
  queue_publication_enabled boolean not null default false,
  worker_claim_enabled boolean not null default false,
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
  executable_envelopes_forbidden boolean not null default true,

  default_decision text not null default 'held',
  created_by text not null,
  approved_by text,
  approved_at timestamptz,
  policy_metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp(),

  unique(policy_code,environment),

  check (
    policy_code=lower(policy_code)
    and policy_code ~ '^[a-z][a-z0-9:_-]{7,159}$'
    and environment in ('development','test','staging','production')
    and policy_status in ('draft','approved','retired')
    and policy_version>0
    and maximum_envelope_lifetime_seconds between 1 and 600
    and default_envelope_lifetime_seconds between 1 and maximum_envelope_lifetime_seconds
    and default_decision in ('held','blocked')
    and opaque_references_only
    and plaintext_storage_forbidden
    and metadata_only
    and executable_envelopes_forbidden
    and jsonb_typeof(policy_metadata)='object'
    and not (policy_metadata ?| array[
      'secret','secret_value','password','private_key','access_token',
      'refresh_token','api_key','client_secret','plaintext','ciphertext',
      'url','uri','endpoint','connection_string','dsn','host','hostname'
    ])
  ),

  check (
    automatic_dispatch_enabled=false
    and dispatch_enabled=false
    and queue_publication_enabled=false
    and worker_claim_enabled=false
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

comment on table public.commercial_secret_resolution_dispatch_envelope_policies is
'Passive policy governing immutable non-dispatchable secret-resolution envelopes.';

-- =============================================================================
-- 2. REQUESTS AND IDEMPOTENCY
-- =============================================================================

create table public.commercial_secret_resolution_dispatch_envelope_requests (
  id uuid primary key default gen_random_uuid(),
  request_key text not null unique,
  idempotency_key text not null unique,
  envelope_policy_id uuid not null
    references public.commercial_secret_resolution_dispatch_envelope_policies(id) on delete restrict,

  execution_permit_id uuid not null
    references public.commercial_secret_resolution_execution_permits(id) on delete restrict,
  permit_request_id uuid not null
    references public.commercial_secret_resolution_execution_permit_requests(id) on delete restrict,
  permit_decision_id uuid not null
    references public.commercial_secret_resolution_execution_permit_decisions(id) on delete restrict,

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
    and requested_lifetime_seconds between 1 and 600
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

create index commercial_secret_resolution_dispatch_envelope_requests_queue_idx
  on public.commercial_secret_resolution_dispatch_envelope_requests
  (request_status,requested_at,id);

create table public.commercial_secret_resolution_dispatch_envelope_idempotency (
  id uuid primary key default gen_random_uuid(),
  idempotency_key text not null unique,
  envelope_request_id uuid not null unique
    references public.commercial_secret_resolution_dispatch_envelope_requests(id) on delete restrict,
  request_hash text not null,
  replay_count integer not null default 0,
  first_seen_at timestamptz not null default clock_timestamp(),
  last_seen_at timestamptz not null default clock_timestamp(),
  check (length(idempotency_key) between 8 and 240 and request_hash ~ '^[a-f0-9]{64}$' and replay_count>=0)
);

-- =============================================================================
-- 3. EVALUATIONS AND DECISIONS
-- =============================================================================

create table public.commercial_secret_resolution_dispatch_envelope_evaluations (
  id uuid primary key default gen_random_uuid(),
  envelope_request_id uuid not null
    references public.commercial_secret_resolution_dispatch_envelope_requests(id) on delete restrict,
  evaluation_order integer not null,
  evaluation_code text not null,
  evaluation_status text not null,
  passed boolean not null,
  evaluation_reason text,
  evaluation_hash text not null,
  evaluation_metadata jsonb not null default '{}'::jsonb,
  evaluated_at timestamptz not null default clock_timestamp(),
  unique(envelope_request_id,evaluation_order),
  check (
    evaluation_order between 1 and 100
    and evaluation_code in (
      'PERMIT_DECISION','PERMIT_LINK','PERMIT_STATUS','PERMIT_WINDOW',
      'PERMIT_REVOCATION','ENVIRONMENT','SCOPE','NAMESPACE',
      'CAPABILITY','BACKEND_BINDING','PASSIVE_POSTURE'
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

create table public.commercial_secret_resolution_dispatch_envelope_decisions (
  id uuid primary key default gen_random_uuid(),
  envelope_request_id uuid not null unique
    references public.commercial_secret_resolution_dispatch_envelope_requests(id) on delete restrict,

  decision_status text not null,
  decision_code text not null,
  approved boolean not null default false,

  execution_permit_id uuid
    references public.commercial_secret_resolution_execution_permits(id) on delete restrict,
  selected_backend_binding_id uuid
    references public.commercial_secret_backend_bindings(id) on delete restrict,
  selected_backend_id uuid
    references public.commercial_secret_backends(id) on delete restrict,
  selected_backend_version_id uuid
    references public.commercial_secret_backend_versions(id) on delete restrict,

  resolved_environment text,
  resolved_scope_type text,
  resolved_scope_key text,
  resolved_namespace text,
  resolved_capability text,
  resolved_operation text,

  granted_lifetime_seconds integer,
  not_before timestamptz,
  expires_at timestamptz,

  dispatch_allowed boolean not null default false,
  queue_publication_allowed boolean not null default false,
  worker_claim_allowed boolean not null default false,
  permit_execution_allowed boolean not null default false,
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

  check (
    decision_status in ('approved','held','blocked')
    and decision_code in (
      'ENVELOPE_METADATA_APPROVED','POLICY_DISABLED','PERMIT_NOT_APPROVED',
      'PERMIT_LINK_MISMATCH','PERMIT_NOT_ISSUED','PERMIT_NOT_YET_VALID',
      'PERMIT_EXPIRED','PERMIT_REVOKED','ENVIRONMENT_MISMATCH','SCOPE_MISMATCH',
      'NAMESPACE_MISMATCH','CAPABILITY_MISMATCH','BACKEND_BINDING_MISMATCH',
      'ENVELOPE_LIFETIME_INVALID','PASSIVE_POSTURE_VIOLATION'
    )
    and approved=(decision_status='approved')
    and (
      (approved and execution_permit_id is not null and granted_lifetime_seconds is not null
       and not_before is not null and expires_at is not null and expires_at>not_before)
      or not approved
    )
    and decision_hash ~ '^[a-f0-9]{64}$'
    and jsonb_typeof(decision_metadata)='object'
    and not (decision_metadata ?| array[
      'secret','secret_value','password','private_key','access_token',
      'refresh_token','api_key','client_secret','plaintext','ciphertext',
      'url','uri','endpoint','connection_string','dsn','host','hostname'
    ])
  ),

  check (
    dispatch_allowed=false
    and queue_publication_allowed=false
    and worker_claim_allowed=false
    and permit_execution_allowed=false
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
-- 4. NON-DISPATCHABLE ENVELOPES
-- =============================================================================

create table public.commercial_secret_resolution_dispatch_envelopes (
  id uuid primary key default gen_random_uuid(),
  envelope_key text not null unique,
  envelope_request_id uuid not null unique
    references public.commercial_secret_resolution_dispatch_envelope_requests(id) on delete restrict,
  envelope_decision_id uuid not null unique
    references public.commercial_secret_resolution_dispatch_envelope_decisions(id) on delete restrict,

  execution_permit_id uuid not null
    references public.commercial_secret_resolution_execution_permits(id) on delete restrict,
  permit_request_id uuid not null
    references public.commercial_secret_resolution_execution_permit_requests(id) on delete restrict,
  permit_decision_id uuid not null
    references public.commercial_secret_resolution_execution_permit_decisions(id) on delete restrict,

  selected_backend_binding_id uuid not null
    references public.commercial_secret_backend_bindings(id) on delete restrict,
  selected_backend_id uuid not null
    references public.commercial_secret_backends(id) on delete restrict,
  selected_backend_version_id uuid not null
    references public.commercial_secret_backend_versions(id) on delete restrict,

  environment text not null,
  scope_type text not null,
  scope_key text not null,
  namespace_code text not null,
  capability_code text not null,
  operation_code text not null,

  envelope_status text not null default 'held',
  not_before timestamptz not null,
  expires_at timestamptz not null,

  opaque_reference_contract boolean not null default true,
  metadata_only boolean not null default true,
  executable boolean not null default false,
  dispatchable boolean not null default false,
  transferable boolean not null default false,
  queue_publishable boolean not null default false,
  worker_claimable boolean not null default false,

  dispatch_allowed boolean not null default false,
  queue_publication_allowed boolean not null default false,
  worker_claim_allowed boolean not null default false,
  permit_execution_allowed boolean not null default false,
  endpoint_discovery_allowed boolean not null default false,
  backend_contact_allowed boolean not null default false,
  authentication_allowed boolean not null default false,
  secret_lookup_allowed boolean not null default false,
  secret_resolution_allowed boolean not null default false,
  decryption_allowed boolean not null default false,
  material_loading_allowed boolean not null default false,
  delivery_allowed boolean not null default false,
  network_access_allowed boolean not null default false,

  envelope_hash text not null,
  envelope_metadata jsonb not null default '{}'::jsonb,
  issued_by text not null,
  issued_at timestamptz not null default clock_timestamp(),

  check (
    envelope_key=lower(envelope_key)
    and envelope_key ~ '^[a-z][a-z0-9:_-]{7,159}$'
    and environment in ('development','test','staging','production')
    and scope_type in ('platform','provider','credential_binding')
    and scope_key=lower(scope_key)
    and namespace_code=lower(namespace_code)
    and capability_code=lower(capability_code)
    and operation_code='secret_resolution'
    and envelope_status in ('held','expired','cancelled','superseded')
    and expires_at>not_before
    and opaque_reference_contract
    and metadata_only
    and executable=false
    and dispatchable=false
    and transferable=false
    and queue_publishable=false
    and worker_claimable=false
    and dispatch_allowed=false
    and queue_publication_allowed=false
    and worker_claim_allowed=false
    and permit_execution_allowed=false
    and endpoint_discovery_allowed=false
    and backend_contact_allowed=false
    and authentication_allowed=false
    and secret_lookup_allowed=false
    and secret_resolution_allowed=false
    and decryption_allowed=false
    and material_loading_allowed=false
    and delivery_allowed=false
    and network_access_allowed=false
    and envelope_hash ~ '^[a-f0-9]{64}$'
    and jsonb_typeof(envelope_metadata)='object'
    and not (envelope_metadata ?| array[
      'secret','secret_value','password','private_key','access_token',
      'refresh_token','api_key','client_secret','plaintext','ciphertext',
      'url','uri','endpoint','connection_string','dsn','host','hostname'
    ])
  )
);

comment on table public.commercial_secret_resolution_dispatch_envelopes is
'Immutable held metadata envelopes. They cannot be queued, claimed, dispatched or executed.';

-- =============================================================================
-- 5. CANCELLATIONS, BLOCKED ATTEMPTS, RECEIPTS, EVENTS
-- =============================================================================

create table public.commercial_secret_resolution_dispatch_envelope_cancellations (
  id uuid primary key default gen_random_uuid(),
  dispatch_envelope_id uuid not null
    references public.commercial_secret_resolution_dispatch_envelopes(id) on delete restrict,
  cancellation_key text not null unique,
  cancellation_code text not null,
  cancellation_reason text not null,
  cancelled_by text not null,
  correlation_id uuid not null,
  causation_id uuid,
  cancellation_metadata jsonb not null default '{}'::jsonb,
  cancelled_at timestamptz not null default clock_timestamp(),
  unique(dispatch_envelope_id),
  check (
    cancellation_key=lower(cancellation_key)
    and cancellation_key ~ '^[a-z][a-z0-9:_-]{7,159}$'
    and cancellation_code ~ '^[A-Z][A-Z0-9_]{2,79}$'
    and jsonb_typeof(cancellation_metadata)='object'
    and not (cancellation_metadata ?| array[
      'secret','secret_value','password','private_key','access_token',
      'refresh_token','api_key','client_secret','plaintext','ciphertext',
      'url','uri','endpoint','connection_string','dsn','host','hostname'
    ])
  )
);

create table public.commercial_secret_resolution_dispatch_envelope_attempts (
  id uuid primary key default gen_random_uuid(),
  envelope_request_id uuid not null
    references public.commercial_secret_resolution_dispatch_envelope_requests(id) on delete restrict,
  envelope_decision_id uuid
    references public.commercial_secret_resolution_dispatch_envelope_decisions(id) on delete restrict,
  dispatch_envelope_id uuid
    references public.commercial_secret_resolution_dispatch_envelopes(id) on delete restrict,
  attempt_type text not null,
  attempt_status text not null default 'blocked',
  block_code text not null,
  block_reason text not null,
  attempted_by text not null,
  attempt_metadata jsonb not null default '{}'::jsonb,
  attempted_at timestamptz not null default clock_timestamp(),
  check (
    attempt_type in ('QUEUE_PUBLICATION','WORKER_CLAIM','DISPATCH','SECRET_RESOLUTION','BACKEND_CONTACT')
    and attempt_status='blocked'
    and block_code='NON_DISPATCHABLE_ENVELOPE_OPERATION_FORBIDDEN'
    and jsonb_typeof(attempt_metadata)='object'
    and not (attempt_metadata ?| array[
      'secret','secret_value','password','private_key','access_token',
      'refresh_token','api_key','client_secret','plaintext','ciphertext',
      'url','uri','endpoint','connection_string','dsn','host','hostname'
    ])
  )
);

create table public.commercial_secret_resolution_dispatch_envelope_receipts (
  id uuid primary key default gen_random_uuid(),
  envelope_request_id uuid not null
    references public.commercial_secret_resolution_dispatch_envelope_requests(id) on delete restrict,
  envelope_decision_id uuid
    references public.commercial_secret_resolution_dispatch_envelope_decisions(id) on delete restrict,
  dispatch_envelope_id uuid
    references public.commercial_secret_resolution_dispatch_envelopes(id) on delete restrict,
  receipt_type text not null,
  receipt_status text not null,
  receipt_code text not null,
  receipt_message text not null,
  receipt_hash text not null,
  receipt_metadata jsonb not null default '{}'::jsonb,
  recorded_by text not null,
  recorded_at timestamptz not null default clock_timestamp(),
  check (
    receipt_type in ('REQUEST_RECEIVED','REQUEST_REPLAYED','EVALUATION_COMPLETED',
                     'DECISION_RECORDED','ENVELOPE_ISSUED','ENVELOPE_CANCELLED',
                     'OPERATION_BLOCKED')
    and receipt_status in ('accepted','approved','held','blocked','cancelled')
    and receipt_hash ~ '^[a-f0-9]{64}$'
    and jsonb_typeof(receipt_metadata)='object'
    and not (receipt_metadata ?| array[
      'secret','secret_value','password','private_key','access_token',
      'refresh_token','api_key','client_secret','plaintext','ciphertext',
      'url','uri','endpoint','connection_string','dsn','host','hostname'
    ])
  )
);

create table public.commercial_secret_resolution_dispatch_envelope_events (
  id uuid primary key default gen_random_uuid(),
  event_type text not null,
  envelope_policy_id uuid
    references public.commercial_secret_resolution_dispatch_envelope_policies(id) on delete restrict,
  envelope_request_id uuid
    references public.commercial_secret_resolution_dispatch_envelope_requests(id) on delete restrict,
  envelope_decision_id uuid
    references public.commercial_secret_resolution_dispatch_envelope_decisions(id) on delete restrict,
  dispatch_envelope_id uuid
    references public.commercial_secret_resolution_dispatch_envelopes(id) on delete restrict,
  envelope_attempt_id uuid
    references public.commercial_secret_resolution_dispatch_envelope_attempts(id) on delete restrict,
  cancellation_id uuid
    references public.commercial_secret_resolution_dispatch_envelope_cancellations(id) on delete restrict,
  event_status text not null,
  event_message text not null,
  event_source text not null,
  correlation_id uuid not null,
  causation_id uuid,
  event_hash text not null,
  event_metadata jsonb not null default '{}'::jsonb,
  occurred_at timestamptz not null default clock_timestamp(),
  check (
    event_type in (
      'SECRET_RESOLUTION_DISPATCH_ENVELOPE_INITIALIZED',
      'DISPATCH_ENVELOPE_REQUESTED','DISPATCH_ENVELOPE_REPLAYED',
      'DISPATCH_ENVELOPE_DECIDED','DISPATCH_ENVELOPE_ISSUED',
      'DISPATCH_ENVELOPE_CANCELLED','DISPATCH_ENVELOPE_OPERATION_BLOCKED'
    )
    and event_status in ('approved','accepted','held','blocked','cancelled')
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
-- 6. GENERIC GUARDS
-- =============================================================================

create or replace function public.commercial_secret_resolution_dispatch_envelope_touch_updated_at()
returns trigger language plpgsql set search_path=public,pg_temp as $$
begin
  new.updated_at:=clock_timestamp();
  return new;
end
$$;

create or replace function public.commercial_secret_resolution_dispatch_envelope_immutable_guard()
returns trigger language plpgsql set search_path=public,pg_temp as $$
begin
  raise exception 'COMMERCIAL_SECRET_RESOLUTION_DISPATCH_ENVELOPE_IMMUTABLE';
end
$$;

create or replace function public.commercial_secret_resolution_dispatch_envelope_append_only_guard()
returns trigger language plpgsql set search_path=public,pg_temp as $$
begin
  raise exception 'COMMERCIAL_SECRET_RESOLUTION_DISPATCH_ENVELOPE_APPEND_ONLY';
end
$$;

create trigger commercial_secret_resolution_dispatch_envelope_requests_updated_at
before update on public.commercial_secret_resolution_dispatch_envelope_requests
for each row execute function public.commercial_secret_resolution_dispatch_envelope_touch_updated_at();

create trigger commercial_secret_resolution_dispatch_envelope_policies_immutable
before update or delete on public.commercial_secret_resolution_dispatch_envelope_policies
for each row execute function public.commercial_secret_resolution_dispatch_envelope_immutable_guard();

create trigger commercial_secret_resolution_dispatch_envelope_evaluations_immutable
before update or delete on public.commercial_secret_resolution_dispatch_envelope_evaluations
for each row execute function public.commercial_secret_resolution_dispatch_envelope_immutable_guard();

create trigger commercial_secret_resolution_dispatch_envelope_decisions_immutable
before update or delete on public.commercial_secret_resolution_dispatch_envelope_decisions
for each row execute function public.commercial_secret_resolution_dispatch_envelope_immutable_guard();

create trigger commercial_secret_resolution_dispatch_envelopes_immutable
before update or delete on public.commercial_secret_resolution_dispatch_envelopes
for each row execute function public.commercial_secret_resolution_dispatch_envelope_immutable_guard();

create trigger commercial_secret_resolution_dispatch_envelope_cancellations_append_only
before update or delete on public.commercial_secret_resolution_dispatch_envelope_cancellations
for each row execute function public.commercial_secret_resolution_dispatch_envelope_append_only_guard();

create trigger commercial_secret_resolution_dispatch_envelope_attempts_append_only
before update or delete on public.commercial_secret_resolution_dispatch_envelope_attempts
for each row execute function public.commercial_secret_resolution_dispatch_envelope_append_only_guard();

create trigger commercial_secret_resolution_dispatch_envelope_receipts_append_only
before update or delete on public.commercial_secret_resolution_dispatch_envelope_receipts
for each row execute function public.commercial_secret_resolution_dispatch_envelope_append_only_guard();

create trigger commercial_secret_resolution_dispatch_envelope_events_append_only
before update or delete on public.commercial_secret_resolution_dispatch_envelope_events
for each row execute function public.commercial_secret_resolution_dispatch_envelope_append_only_guard();

-- =============================================================================
-- 7. APPEND HELPERS
-- =============================================================================

create or replace function public.append_commercial_secret_resolution_dispatch_envelope_receipt(
  p_request_id uuid,
  p_decision_id uuid,
  p_envelope_id uuid,
  p_receipt_type text,
  p_receipt_status text,
  p_receipt_code text,
  p_receipt_message text,
  p_recorded_by text,
  p_metadata jsonb default '{}'::jsonb
)
returns public.commercial_secret_resolution_dispatch_envelope_receipts
language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare
  v_row public.commercial_secret_resolution_dispatch_envelope_receipts;
  v_hash text;
begin
  v_hash:=encode(digest(concat_ws('|',p_request_id,p_decision_id,p_envelope_id,p_receipt_type,
    p_receipt_status,p_receipt_code,p_receipt_message,p_recorded_by,coalesce(p_metadata,'{}'::jsonb)::text),'sha256'),'hex');

  insert into public.commercial_secret_resolution_dispatch_envelope_receipts(
    envelope_request_id,envelope_decision_id,dispatch_envelope_id,
    receipt_type,receipt_status,receipt_code,receipt_message,receipt_hash,
    receipt_metadata,recorded_by
  ) values (
    p_request_id,p_decision_id,p_envelope_id,p_receipt_type,p_receipt_status,
    p_receipt_code,p_receipt_message,v_hash,coalesce(p_metadata,'{}'::jsonb),p_recorded_by
  ) returning * into v_row;

  return v_row;
end
$$;

create or replace function public.append_commercial_secret_resolution_dispatch_envelope_event(
  p_event_type text,
  p_policy_id uuid,
  p_request_id uuid,
  p_decision_id uuid,
  p_envelope_id uuid,
  p_attempt_id uuid,
  p_cancellation_id uuid,
  p_event_status text,
  p_event_message text,
  p_event_source text,
  p_correlation_id uuid,
  p_causation_id uuid default null,
  p_metadata jsonb default '{}'::jsonb
)
returns public.commercial_secret_resolution_dispatch_envelope_events
language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare
  v_row public.commercial_secret_resolution_dispatch_envelope_events;
  v_hash text;
begin
  v_hash:=encode(digest(concat_ws('|',p_event_type,p_policy_id,p_request_id,p_decision_id,
    p_envelope_id,p_attempt_id,p_cancellation_id,p_event_status,p_event_message,p_event_source,
    p_correlation_id,p_causation_id,coalesce(p_metadata,'{}'::jsonb)::text),'sha256'),'hex');

  insert into public.commercial_secret_resolution_dispatch_envelope_events(
    event_type,envelope_policy_id,envelope_request_id,envelope_decision_id,
    dispatch_envelope_id,envelope_attempt_id,cancellation_id,event_status,
    event_message,event_source,correlation_id,causation_id,event_hash,event_metadata
  ) values (
    p_event_type,p_policy_id,p_request_id,p_decision_id,p_envelope_id,p_attempt_id,
    p_cancellation_id,p_event_status,p_event_message,p_event_source,p_correlation_id,
    p_causation_id,v_hash,coalesce(p_metadata,'{}'::jsonb)
  ) returning * into v_row;

  return v_row;
end
$$;

-- =============================================================================
-- 8. REQUEST, EVALUATION, ISSUE, CANCEL, BLOCK
-- =============================================================================

create or replace function public.enqueue_commercial_secret_resolution_dispatch_envelope_request(
  p_request_key text,
  p_idempotency_key text,
  p_execution_permit_id uuid,
  p_environment text,
  p_scope_type text,
  p_scope_key text,
  p_namespace text,
  p_capability text,
  p_lifetime_seconds integer,
  p_requested_by text,
  p_correlation_id uuid,
  p_causation_id uuid default null,
  p_metadata jsonb default '{}'::jsonb
)
returns public.commercial_secret_resolution_dispatch_envelope_requests
language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare
  v_policy public.commercial_secret_resolution_dispatch_envelope_policies;
  v_permit public.commercial_secret_resolution_execution_permits;
  v_hash text;
  v_existing public.commercial_secret_resolution_dispatch_envelope_requests;
  v_row public.commercial_secret_resolution_dispatch_envelope_requests;
begin
  select * into strict v_policy
  from public.commercial_secret_resolution_dispatch_envelope_policies
  where policy_code='commercial:secret_resolution_dispatch_envelope:v1'
    and environment=p_environment and policy_status='approved';

  select * into strict v_permit
  from public.commercial_secret_resolution_execution_permits
  where id=p_execution_permit_id;

  v_hash:=encode(digest(concat_ws('|',lower(p_request_key),p_execution_permit_id,
    lower(p_environment),lower(p_scope_type),lower(p_scope_key),lower(p_namespace),
    lower(p_capability),p_lifetime_seconds,coalesce(p_metadata,'{}'::jsonb)::text),'sha256'),'hex');

  select r.* into v_existing
  from public.commercial_secret_resolution_dispatch_envelope_idempotency i
  join public.commercial_secret_resolution_dispatch_envelope_requests r
    on r.id=i.envelope_request_id
  where i.idempotency_key=p_idempotency_key;

  if found then
    if v_existing.request_hash<>v_hash then
      raise exception 'COMMERCIAL_SECRET_RESOLUTION_DISPATCH_ENVELOPE_IDEMPOTENCY_CONFLICT';
    end if;

    update public.commercial_secret_resolution_dispatch_envelope_idempotency
    set replay_count=replay_count+1,last_seen_at=clock_timestamp()
    where idempotency_key=p_idempotency_key;

    perform public.append_commercial_secret_resolution_dispatch_envelope_receipt(
      v_existing.id,null,null,'REQUEST_REPLAYED','accepted','REQUEST_REPLAYED',
      'Dispatch-envelope request replay accepted',p_requested_by,p_metadata);

    perform public.append_commercial_secret_resolution_dispatch_envelope_event(
      'DISPATCH_ENVELOPE_REPLAYED',v_existing.envelope_policy_id,v_existing.id,null,null,null,null,
      'accepted','Dispatch-envelope request replay accepted',p_requested_by,p_correlation_id,p_causation_id,p_metadata);

    return v_existing;
  end if;

  insert into public.commercial_secret_resolution_dispatch_envelope_requests(
    request_key,idempotency_key,envelope_policy_id,execution_permit_id,
    permit_request_id,permit_decision_id,requested_environment,requested_scope_type,
    requested_scope_key,requested_namespace,requested_capability,requested_operation,
    requested_lifetime_seconds,correlation_id,causation_id,requested_by,request_hash,request_metadata
  ) values (
    lower(p_request_key),p_idempotency_key,v_policy.id,v_permit.id,
    v_permit.permit_request_id,v_permit.permit_decision_id,lower(p_environment),
    lower(p_scope_type),lower(p_scope_key),lower(p_namespace),lower(p_capability),
    'secret_resolution',p_lifetime_seconds,p_correlation_id,p_causation_id,
    p_requested_by,v_hash,coalesce(p_metadata,'{}'::jsonb)
  ) returning * into v_row;

  insert into public.commercial_secret_resolution_dispatch_envelope_idempotency(
    idempotency_key,envelope_request_id,request_hash
  ) values (p_idempotency_key,v_row.id,v_hash);

  perform public.append_commercial_secret_resolution_dispatch_envelope_receipt(
    v_row.id,null,null,'REQUEST_RECEIVED','accepted','REQUEST_RECEIVED',
    'Dispatch-envelope request received',p_requested_by,p_metadata);

  perform public.append_commercial_secret_resolution_dispatch_envelope_event(
    'DISPATCH_ENVELOPE_REQUESTED',v_policy.id,v_row.id,null,null,null,null,
    'accepted','Dispatch-envelope request received',p_requested_by,p_correlation_id,p_causation_id,p_metadata);

  return v_row;
end
$$;

create or replace function public.evaluate_commercial_secret_resolution_dispatch_envelope_request(
  p_request_id uuid,
  p_decided_by text
)
returns public.commercial_secret_resolution_dispatch_envelope_decisions
language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare
  v_request public.commercial_secret_resolution_dispatch_envelope_requests;
  v_policy public.commercial_secret_resolution_dispatch_envelope_policies;
  v_permit public.commercial_secret_resolution_execution_permits;
  v_permit_decision public.commercial_secret_resolution_execution_permit_decisions;
  v_permit_read public.commercial_secret_resolution_execution_permit_read_model;
  v_codes text[]:=array[
    'PERMIT_DECISION','PERMIT_LINK','PERMIT_STATUS','PERMIT_WINDOW',
    'PERMIT_REVOCATION','ENVIRONMENT','SCOPE','NAMESPACE',
    'CAPABILITY','BACKEND_BINDING','PASSIVE_POSTURE'
  ];
  v_pass boolean[]:=array[]::boolean[];
  v_reasons text[]:=array[]::text[];
  v_i integer;
  v_approved boolean;
  v_code text;
  v_status text;
  v_reason text;
  v_lifetime integer;
  v_not_before timestamptz;
  v_expires_at timestamptz;
  v_hash text;
  v_row public.commercial_secret_resolution_dispatch_envelope_decisions;
begin
  select * into strict v_request
  from public.commercial_secret_resolution_dispatch_envelope_requests where id=p_request_id;

  select * into strict v_policy
  from public.commercial_secret_resolution_dispatch_envelope_policies where id=v_request.envelope_policy_id;

  select * into strict v_permit
  from public.commercial_secret_resolution_execution_permits where id=v_request.execution_permit_id;

  select * into strict v_permit_decision
  from public.commercial_secret_resolution_execution_permit_decisions where id=v_request.permit_decision_id;

  select * into strict v_permit_read
  from public.commercial_secret_resolution_execution_permit_read_model
  where execution_permit_id=v_permit.id;

  v_pass:=array[
    v_permit_decision.approved and v_permit_decision.decision_code='PERMIT_METADATA_APPROVED',
    v_permit.permit_request_id=v_request.permit_request_id and v_permit.permit_decision_id=v_request.permit_decision_id,
    v_permit.permit_status='issued',
    clock_timestamp()>=v_permit.not_before and clock_timestamp()<v_permit.expires_at,
    v_permit_read.effective_permit_status<>'revoked',
    v_permit.environment=v_request.requested_environment,
    v_permit.scope_type=v_request.requested_scope_type and v_permit.scope_key=v_request.requested_scope_key,
    v_permit.namespace_code=v_request.requested_namespace,
    v_permit.capability_code=v_request.requested_capability,
    v_permit.selected_backend_binding_id is not null and v_permit.selected_backend_id is not null
      and v_permit.selected_backend_version_id is not null,
    v_permit.metadata_only and not v_permit.executable and not v_permit.dispatch_allowed
      and not v_permit.backend_contact_allowed and not v_permit.secret_resolution_allowed
      and not v_policy.dispatch_enabled and not v_policy.queue_publication_enabled
      and not v_policy.worker_claim_enabled and not v_policy.network_access_enabled
  ];

  v_reasons:=array[
    'Permit decision must be metadata-approved',
    'Permit request and decision links must match',
    'Permit must be issued',
    'Permit must be currently valid',
    'Permit must not be revoked',
    'Environment must match',
    'Scope must match',
    'Namespace must match',
    'Capability must match',
    'Backend binding chain must be present',
    'Permit and policy must remain passive'
  ];

  delete from public.commercial_secret_resolution_dispatch_envelope_evaluations
  where envelope_request_id=p_request_id;

  for v_i in 1..array_length(v_codes,1) loop
    insert into public.commercial_secret_resolution_dispatch_envelope_evaluations(
      envelope_request_id,evaluation_order,evaluation_code,evaluation_status,passed,
      evaluation_reason,evaluation_hash,evaluation_metadata
    ) values (
      p_request_id,v_i,v_codes[v_i],case when v_pass[v_i] then 'passed' else 'failed' end,
      v_pass[v_i],v_reasons[v_i],
      encode(digest(concat_ws('|',p_request_id,v_i,v_codes[v_i],v_pass[v_i],v_reasons[v_i]),'sha256'),'hex'),
      jsonb_build_object('metadata_only',true,'executable',false)
    );
  end loop;

  v_approved:=v_policy.intake_enabled and v_policy.permit_verification_enabled
    and v_policy.envelope_issuance_enabled
    and not exists (
      select 1 from public.commercial_secret_resolution_dispatch_envelope_evaluations
      where envelope_request_id=p_request_id and not passed
    );

  if v_approved then
    v_status:='approved';
    v_code:='ENVELOPE_METADATA_APPROVED';
    v_reason:='Metadata-only dispatch envelope approved and held';
    v_lifetime:=least(v_request.requested_lifetime_seconds,v_policy.maximum_envelope_lifetime_seconds,
                      greatest(1,extract(epoch from (v_permit.expires_at-clock_timestamp()))::integer));
    v_not_before:=greatest(clock_timestamp(),v_permit.not_before);
    v_expires_at:=least(v_not_before+make_interval(secs=>v_lifetime),v_permit.expires_at);
  else
    v_status:='blocked';
    select case evaluation_code
      when 'PERMIT_DECISION' then 'PERMIT_NOT_APPROVED'
      when 'PERMIT_LINK' then 'PERMIT_LINK_MISMATCH'
      when 'PERMIT_STATUS' then 'PERMIT_NOT_ISSUED'
      when 'PERMIT_WINDOW' then case when clock_timestamp()<v_permit.not_before then 'PERMIT_NOT_YET_VALID' else 'PERMIT_EXPIRED' end
      when 'PERMIT_REVOCATION' then 'PERMIT_REVOKED'
      when 'ENVIRONMENT' then 'ENVIRONMENT_MISMATCH'
      when 'SCOPE' then 'SCOPE_MISMATCH'
      when 'NAMESPACE' then 'NAMESPACE_MISMATCH'
      when 'CAPABILITY' then 'CAPABILITY_MISMATCH'
      when 'BACKEND_BINDING' then 'BACKEND_BINDING_MISMATCH'
      else 'PASSIVE_POSTURE_VIOLATION'
    end into v_code
    from public.commercial_secret_resolution_dispatch_envelope_evaluations
    where envelope_request_id=p_request_id and not passed
    order by evaluation_order limit 1;
    v_reason:='Dispatch-envelope request blocked by policy evaluation';
  end if;

  v_hash:=encode(digest(concat_ws('|',p_request_id,v_status,v_code,v_permit.id,
    v_permit.selected_backend_binding_id,v_permit.selected_backend_id,
    v_permit.selected_backend_version_id,v_lifetime,v_not_before,v_expires_at),'sha256'),'hex');

  insert into public.commercial_secret_resolution_dispatch_envelope_decisions(
    envelope_request_id,decision_status,decision_code,approved,execution_permit_id,
    selected_backend_binding_id,selected_backend_id,selected_backend_version_id,
    resolved_environment,resolved_scope_type,resolved_scope_key,resolved_namespace,
    resolved_capability,resolved_operation,granted_lifetime_seconds,not_before,expires_at,
    decided_by,decision_reason,decision_hash,decision_metadata
  ) values (
    p_request_id,v_status,v_code,v_approved,v_permit.id,v_permit.selected_backend_binding_id,
    v_permit.selected_backend_id,v_permit.selected_backend_version_id,v_permit.environment,
    v_permit.scope_type,v_permit.scope_key,v_permit.namespace_code,v_permit.capability_code,
    v_permit.operation_code,v_lifetime,v_not_before,v_expires_at,p_decided_by,v_reason,v_hash,
    jsonb_build_object('metadata_only',true,'executable',false,'dispatch_allowed',false)
  ) returning * into v_row;

  update public.commercial_secret_resolution_dispatch_envelope_requests
  set request_status=case when v_approved then 'approved' else 'blocked' end,
      evaluated_at=clock_timestamp(),terminal_reason=v_reason
  where id=p_request_id;

  perform public.append_commercial_secret_resolution_dispatch_envelope_receipt(
    p_request_id,v_row.id,null,'EVALUATION_COMPLETED',
    case when v_approved then 'approved' else 'blocked' end,
    v_code,v_reason,p_decided_by,'{"metadata_only":true}'::jsonb);

  perform public.append_commercial_secret_resolution_dispatch_envelope_receipt(
    p_request_id,v_row.id,null,'DECISION_RECORDED',
    case when v_approved then 'approved' else 'blocked' end,
    v_code,v_reason,p_decided_by,'{"dispatch_allowed":false}'::jsonb);

  perform public.append_commercial_secret_resolution_dispatch_envelope_event(
    'DISPATCH_ENVELOPE_DECIDED',v_policy.id,p_request_id,v_row.id,null,null,null,
    case when v_approved then 'approved' else 'blocked' end,v_reason,p_decided_by,
    v_request.correlation_id,v_request.causation_id,'{"metadata_only":true}'::jsonb);

  return v_row;
end
$$;

create or replace function public.issue_commercial_secret_resolution_dispatch_envelope(
  p_request_id uuid,
  p_issued_by text,
  p_metadata jsonb default '{}'::jsonb
)
returns public.commercial_secret_resolution_dispatch_envelopes
language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare
  v_request public.commercial_secret_resolution_dispatch_envelope_requests;
  v_decision public.commercial_secret_resolution_dispatch_envelope_decisions;
  v_permit public.commercial_secret_resolution_execution_permits;
  v_row public.commercial_secret_resolution_dispatch_envelopes;
  v_hash text;
begin
  select * into strict v_request
  from public.commercial_secret_resolution_dispatch_envelope_requests where id=p_request_id;
  select * into strict v_decision
  from public.commercial_secret_resolution_dispatch_envelope_decisions where envelope_request_id=p_request_id;
  select * into strict v_permit
  from public.commercial_secret_resolution_execution_permits where id=v_decision.execution_permit_id;

  if not v_decision.approved or v_decision.decision_code<>'ENVELOPE_METADATA_APPROVED' then
    raise exception 'COMMERCIAL_SECRET_RESOLUTION_DISPATCH_ENVELOPE_NOT_APPROVED';
  end if;

  v_hash:=encode(digest(concat_ws('|',p_request_id,v_decision.id,v_permit.id,
    v_decision.not_before,v_decision.expires_at,coalesce(p_metadata,'{}'::jsonb)::text),'sha256'),'hex');

  insert into public.commercial_secret_resolution_dispatch_envelopes(
    envelope_key,envelope_request_id,envelope_decision_id,execution_permit_id,
    permit_request_id,permit_decision_id,selected_backend_binding_id,
    selected_backend_id,selected_backend_version_id,environment,scope_type,scope_key,
    namespace_code,capability_code,operation_code,envelope_status,not_before,expires_at,
    envelope_hash,envelope_metadata,issued_by
  ) values (
    'dispatch-envelope:'||replace(p_request_id::text,'-',''),p_request_id,v_decision.id,
    v_permit.id,v_permit.permit_request_id,v_permit.permit_decision_id,
    v_permit.selected_backend_binding_id,v_permit.selected_backend_id,
    v_permit.selected_backend_version_id,v_permit.environment,v_permit.scope_type,
    v_permit.scope_key,v_permit.namespace_code,v_permit.capability_code,v_permit.operation_code,
    'held',v_decision.not_before,v_decision.expires_at,v_hash,coalesce(p_metadata,'{}'::jsonb),p_issued_by
  ) returning * into v_row;

  update public.commercial_secret_resolution_dispatch_envelope_requests
  set request_status='held' where id=p_request_id;

  perform public.append_commercial_secret_resolution_dispatch_envelope_receipt(
    p_request_id,v_decision.id,v_row.id,'ENVELOPE_ISSUED','held',
    'ENVELOPE_HELD_NON_DISPATCHABLE','Dispatch envelope issued in held non-dispatchable state',
    p_issued_by,p_metadata);

  perform public.append_commercial_secret_resolution_dispatch_envelope_event(
    'DISPATCH_ENVELOPE_ISSUED',v_request.envelope_policy_id,p_request_id,v_decision.id,
    v_row.id,null,null,'held','Dispatch envelope issued in held non-dispatchable state',
    p_issued_by,v_request.correlation_id,v_request.causation_id,p_metadata);

  return v_row;
end
$$;

create or replace function public.cancel_commercial_secret_resolution_dispatch_envelope(
  p_envelope_id uuid,
  p_cancellation_key text,
  p_cancellation_code text,
  p_cancellation_reason text,
  p_cancelled_by text,
  p_correlation_id uuid,
  p_causation_id uuid default null,
  p_metadata jsonb default '{}'::jsonb
)
returns public.commercial_secret_resolution_dispatch_envelope_cancellations
language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare
  v_envelope public.commercial_secret_resolution_dispatch_envelopes;
  v_request public.commercial_secret_resolution_dispatch_envelope_requests;
  v_row public.commercial_secret_resolution_dispatch_envelope_cancellations;
begin
  select * into strict v_envelope
  from public.commercial_secret_resolution_dispatch_envelopes where id=p_envelope_id;
  select * into strict v_request
  from public.commercial_secret_resolution_dispatch_envelope_requests where id=v_envelope.envelope_request_id;

  insert into public.commercial_secret_resolution_dispatch_envelope_cancellations(
    dispatch_envelope_id,cancellation_key,cancellation_code,cancellation_reason,
    cancelled_by,correlation_id,causation_id,cancellation_metadata
  ) values (
    p_envelope_id,lower(p_cancellation_key),upper(p_cancellation_code),p_cancellation_reason,
    p_cancelled_by,p_correlation_id,p_causation_id,coalesce(p_metadata,'{}'::jsonb)
  ) returning * into v_row;

  update public.commercial_secret_resolution_dispatch_envelope_requests
  set request_status='cancelled',terminal_reason=p_cancellation_reason
  where id=v_envelope.envelope_request_id;

  perform public.append_commercial_secret_resolution_dispatch_envelope_receipt(
    v_envelope.envelope_request_id,v_envelope.envelope_decision_id,p_envelope_id,
    'ENVELOPE_CANCELLED','cancelled',upper(p_cancellation_code),p_cancellation_reason,
    p_cancelled_by,p_metadata);

  perform public.append_commercial_secret_resolution_dispatch_envelope_event(
    'DISPATCH_ENVELOPE_CANCELLED',v_request.envelope_policy_id,v_envelope.envelope_request_id,
    v_envelope.envelope_decision_id,p_envelope_id,null,v_row.id,'cancelled',
    p_cancellation_reason,p_cancelled_by,p_correlation_id,p_causation_id,p_metadata);

  return v_row;
end
$$;

create or replace function public.record_blocked_secret_resolution_dispatch_envelope_attempt(
  p_request_id uuid,
  p_attempt_type text,
  p_attempted_by text,
  p_metadata jsonb default '{}'::jsonb
)
returns public.commercial_secret_resolution_dispatch_envelope_attempts
language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare
  v_request public.commercial_secret_resolution_dispatch_envelope_requests;
  v_decision_id uuid;
  v_envelope_id uuid;
  v_row public.commercial_secret_resolution_dispatch_envelope_attempts;
begin
  select * into strict v_request
  from public.commercial_secret_resolution_dispatch_envelope_requests where id=p_request_id;
  select id into v_decision_id
  from public.commercial_secret_resolution_dispatch_envelope_decisions where envelope_request_id=p_request_id;
  select id into v_envelope_id
  from public.commercial_secret_resolution_dispatch_envelopes where envelope_request_id=p_request_id;

  insert into public.commercial_secret_resolution_dispatch_envelope_attempts(
    envelope_request_id,envelope_decision_id,dispatch_envelope_id,attempt_type,
    block_code,block_reason,attempted_by,attempt_metadata
  ) values (
    p_request_id,v_decision_id,v_envelope_id,upper(p_attempt_type),
    'NON_DISPATCHABLE_ENVELOPE_OPERATION_FORBIDDEN',
    'Dispatch envelope is metadata-only and cannot queue, claim, dispatch or execute',
    p_attempted_by,coalesce(p_metadata,'{}'::jsonb)
  ) returning * into v_row;

  perform public.append_commercial_secret_resolution_dispatch_envelope_receipt(
    p_request_id,v_decision_id,v_envelope_id,'OPERATION_BLOCKED','blocked',
    'NON_DISPATCHABLE_ENVELOPE_OPERATION_FORBIDDEN',
    'Dispatch-envelope operation blocked',p_attempted_by,p_metadata);

  perform public.append_commercial_secret_resolution_dispatch_envelope_event(
    'DISPATCH_ENVELOPE_OPERATION_BLOCKED',v_request.envelope_policy_id,p_request_id,
    v_decision_id,v_envelope_id,v_row.id,null,'blocked','Dispatch-envelope operation blocked',
    p_attempted_by,v_request.correlation_id,v_request.causation_id,p_metadata);

  return v_row;
end
$$;

-- =============================================================================
-- 9. READ MODEL
-- =============================================================================

create view public.commercial_secret_resolution_dispatch_envelope_read_model
with (security_invoker=true)
as
select
  r.id as envelope_request_id,
  r.request_key,
  r.request_status,
  r.execution_permit_id,
  d.id as envelope_decision_id,
  d.decision_status,
  d.decision_code,
  d.approved,
  e.id as dispatch_envelope_id,
  e.envelope_status as recorded_envelope_status,
  e.not_before,
  e.expires_at,
  c.id as cancellation_id,
  c.cancellation_code,
  case
    when e.id is null then 'not_issued'
    when c.id is not null then 'cancelled'
    when clock_timestamp()<e.not_before then 'not_yet_valid'
    when clock_timestamp()>=e.expires_at then 'expired'
    else 'held_metadata_only'
  end as effective_envelope_status,
  (
    e.id is not null
    and c.id is null
    and clock_timestamp()>=e.not_before
    and clock_timestamp()<e.expires_at
    and e.metadata_only
    and not e.executable
    and not e.dispatchable
  ) as metadata_envelope_current,
  false as dispatch_authorized,
  false as execution_authorized,
  coalesce(e.metadata_only,true) as metadata_only,
  coalesce(e.executable,false) as executable,
  coalesce(e.dispatchable,false) as dispatchable,
  coalesce(e.queue_publishable,false) as queue_publishable,
  coalesce(e.worker_claimable,false) as worker_claimable,
  (select count(*) from public.commercial_secret_resolution_dispatch_envelope_evaluations x
   where x.envelope_request_id=r.id) as evaluation_count,
  (select count(*) from public.commercial_secret_resolution_dispatch_envelope_attempts x
   where x.envelope_request_id=r.id) as attempt_count,
  (select count(*) from public.commercial_secret_resolution_dispatch_envelope_receipts x
   where x.envelope_request_id=r.id) as receipt_count,
  (select count(*) from public.commercial_secret_resolution_dispatch_envelope_events x
   where x.envelope_request_id=r.id) as event_count,
  coalesce(i.replay_count,0) as replay_count
from public.commercial_secret_resolution_dispatch_envelope_requests r
left join public.commercial_secret_resolution_dispatch_envelope_decisions d
  on d.envelope_request_id=r.id
left join public.commercial_secret_resolution_dispatch_envelopes e
  on e.envelope_request_id=r.id
left join public.commercial_secret_resolution_dispatch_envelope_cancellations c
  on c.dispatch_envelope_id=e.id
left join public.commercial_secret_resolution_dispatch_envelope_idempotency i
  on i.envelope_request_id=r.id;

comment on view public.commercial_secret_resolution_dispatch_envelope_read_model is
'Effective passive envelope state. dispatch_authorized and execution_authorized are always false.';

-- =============================================================================
-- 10. INITIAL POLICY AND INITIALIZATION EVENT
-- =============================================================================

insert into public.commercial_secret_resolution_dispatch_envelope_policies(
  policy_code,environment,policy_status,policy_version,created_by,approved_by,approved_at,
  policy_metadata
) values (
  'commercial:secret_resolution_dispatch_envelope:v1',
  'production','approved',1,'MIGRATION_137','MIGRATION_137',clock_timestamp(),
  jsonb_build_object(
    'foundation','MIGRATION_137',
    'metadata_only',true,
    'dispatchable',false,
    'executable',false,
    'opaque_references_only',true
  )
);

select public.append_commercial_secret_resolution_dispatch_envelope_event(
  'SECRET_RESOLUTION_DISPATCH_ENVELOPE_INITIALIZED',
  id,null,null,null,null,null,'approved',
  'Secret-resolution dispatch-envelope governance initialized in passive mode',
  'MIGRATION_137',gen_random_uuid(),null,
  jsonb_build_object(
    'automatic_dispatch_enabled',false,
    'dispatch_enabled',false,
    'queue_publication_enabled',false,
    'worker_claim_enabled',false,
    'permit_execution_enabled',false,
    'backend_contact_enabled',false,
    'secret_resolution_enabled',false,
    'network_access_enabled',false,
    'metadata_only',true,
    'dispatchable',false,
    'executable',false
  )
)
from public.commercial_secret_resolution_dispatch_envelope_policies
where policy_code='commercial:secret_resolution_dispatch_envelope:v1'
  and environment='production';

-- =============================================================================
-- 11. SECURITY
-- =============================================================================

alter table public.commercial_secret_resolution_dispatch_envelope_policies enable row level security;
alter table public.commercial_secret_resolution_dispatch_envelope_requests enable row level security;
alter table public.commercial_secret_resolution_dispatch_envelope_idempotency enable row level security;
alter table public.commercial_secret_resolution_dispatch_envelope_evaluations enable row level security;
alter table public.commercial_secret_resolution_dispatch_envelope_decisions enable row level security;
alter table public.commercial_secret_resolution_dispatch_envelopes enable row level security;
alter table public.commercial_secret_resolution_dispatch_envelope_cancellations enable row level security;
alter table public.commercial_secret_resolution_dispatch_envelope_attempts enable row level security;
alter table public.commercial_secret_resolution_dispatch_envelope_receipts enable row level security;
alter table public.commercial_secret_resolution_dispatch_envelope_events enable row level security;

revoke all on public.commercial_secret_resolution_dispatch_envelope_policies from public,anon,authenticated;
revoke all on public.commercial_secret_resolution_dispatch_envelope_requests from public,anon,authenticated;
revoke all on public.commercial_secret_resolution_dispatch_envelope_idempotency from public,anon,authenticated;
revoke all on public.commercial_secret_resolution_dispatch_envelope_evaluations from public,anon,authenticated;
revoke all on public.commercial_secret_resolution_dispatch_envelope_decisions from public,anon,authenticated;
revoke all on public.commercial_secret_resolution_dispatch_envelopes from public,anon,authenticated;
revoke all on public.commercial_secret_resolution_dispatch_envelope_cancellations from public,anon,authenticated;
revoke all on public.commercial_secret_resolution_dispatch_envelope_attempts from public,anon,authenticated;
revoke all on public.commercial_secret_resolution_dispatch_envelope_receipts from public,anon,authenticated;
revoke all on public.commercial_secret_resolution_dispatch_envelope_events from public,anon,authenticated;
revoke all on public.commercial_secret_resolution_dispatch_envelope_read_model from public,anon,authenticated;

grant select,insert,update,delete on public.commercial_secret_resolution_dispatch_envelope_policies to service_role;
grant select,insert,update,delete on public.commercial_secret_resolution_dispatch_envelope_requests to service_role;
grant select,insert,update,delete on public.commercial_secret_resolution_dispatch_envelope_idempotency to service_role;
grant select,insert,update,delete on public.commercial_secret_resolution_dispatch_envelope_evaluations to service_role;
grant select,insert,update,delete on public.commercial_secret_resolution_dispatch_envelope_decisions to service_role;
grant select,insert,update,delete on public.commercial_secret_resolution_dispatch_envelopes to service_role;
grant select,insert,update,delete on public.commercial_secret_resolution_dispatch_envelope_cancellations to service_role;
grant select,insert,update,delete on public.commercial_secret_resolution_dispatch_envelope_attempts to service_role;
grant select,insert,update,delete on public.commercial_secret_resolution_dispatch_envelope_receipts to service_role;
grant select,insert,update,delete on public.commercial_secret_resolution_dispatch_envelope_events to service_role;
grant select on public.commercial_secret_resolution_dispatch_envelope_read_model to service_role;

revoke all on function public.append_commercial_secret_resolution_dispatch_envelope_receipt(
  uuid,uuid,uuid,text,text,text,text,text,jsonb
) from public,anon,authenticated;
revoke all on function public.append_commercial_secret_resolution_dispatch_envelope_event(
  text,uuid,uuid,uuid,uuid,uuid,uuid,text,text,text,uuid,uuid,jsonb
) from public,anon,authenticated;
revoke all on function public.enqueue_commercial_secret_resolution_dispatch_envelope_request(
  text,text,uuid,text,text,text,text,text,integer,text,uuid,uuid,jsonb
) from public,anon,authenticated;
revoke all on function public.evaluate_commercial_secret_resolution_dispatch_envelope_request(uuid,text)
  from public,anon,authenticated;
revoke all on function public.issue_commercial_secret_resolution_dispatch_envelope(uuid,text,jsonb)
  from public,anon,authenticated;
revoke all on function public.cancel_commercial_secret_resolution_dispatch_envelope(
  uuid,text,text,text,text,uuid,uuid,jsonb
) from public,anon,authenticated;
revoke all on function public.record_blocked_secret_resolution_dispatch_envelope_attempt(
  uuid,text,text,jsonb
) from public,anon,authenticated;

grant execute on function public.append_commercial_secret_resolution_dispatch_envelope_receipt(
  uuid,uuid,uuid,text,text,text,text,text,jsonb
) to service_role;
grant execute on function public.append_commercial_secret_resolution_dispatch_envelope_event(
  text,uuid,uuid,uuid,uuid,uuid,uuid,text,text,text,uuid,uuid,jsonb
) to service_role;
grant execute on function public.enqueue_commercial_secret_resolution_dispatch_envelope_request(
  text,text,uuid,text,text,text,text,text,integer,text,uuid,uuid,jsonb
) to service_role;
grant execute on function public.evaluate_commercial_secret_resolution_dispatch_envelope_request(uuid,text)
  to service_role;
grant execute on function public.issue_commercial_secret_resolution_dispatch_envelope(uuid,text,jsonb)
  to service_role;
grant execute on function public.cancel_commercial_secret_resolution_dispatch_envelope(
  uuid,text,text,text,text,uuid,uuid,jsonb
) to service_role;
grant execute on function public.record_blocked_secret_resolution_dispatch_envelope_attempt(
  uuid,text,text,jsonb
) to service_role;

-- =============================================================================
-- 12. FOUNDATION CERTIFICATION
-- =============================================================================

do $$
declare
  v_policy public.commercial_secret_resolution_dispatch_envelope_policies;
  v_policy_count bigint;
  v_request_count bigint;
  v_idempotency_count bigint;
  v_evaluation_count bigint;
  v_decision_count bigint;
  v_envelope_count bigint;
  v_cancellation_count bigint;
  v_attempt_count bigint;
  v_receipt_count bigint;
  v_event_count bigint;
begin
  select * into strict v_policy
  from public.commercial_secret_resolution_dispatch_envelope_policies
  where policy_code='commercial:secret_resolution_dispatch_envelope:v1'
    and environment='production' and policy_status='approved';

  select count(*) into v_policy_count from public.commercial_secret_resolution_dispatch_envelope_policies;
  select count(*) into v_request_count from public.commercial_secret_resolution_dispatch_envelope_requests;
  select count(*) into v_idempotency_count from public.commercial_secret_resolution_dispatch_envelope_idempotency;
  select count(*) into v_evaluation_count from public.commercial_secret_resolution_dispatch_envelope_evaluations;
  select count(*) into v_decision_count from public.commercial_secret_resolution_dispatch_envelope_decisions;
  select count(*) into v_envelope_count from public.commercial_secret_resolution_dispatch_envelopes;
  select count(*) into v_cancellation_count from public.commercial_secret_resolution_dispatch_envelope_cancellations;
  select count(*) into v_attempt_count from public.commercial_secret_resolution_dispatch_envelope_attempts;
  select count(*) into v_receipt_count from public.commercial_secret_resolution_dispatch_envelope_receipts;
  select count(*) into v_event_count from public.commercial_secret_resolution_dispatch_envelope_events;

  if v_policy_count<>1 or v_request_count<>0 or v_idempotency_count<>0
     or v_evaluation_count<>0 or v_decision_count<>0 or v_envelope_count<>0
     or v_cancellation_count<>0 or v_attempt_count<>0 or v_receipt_count<>0
     or v_event_count<>1 then
    raise exception
      'MIGRATION_137_FOUNDATION_COUNT_ASSERTION_FAILED policy=%, request=%, idempotency=%, evaluation=%, decision=%, envelope=%, cancellation=%, attempt=%, receipt=%, event=%',
      v_policy_count,v_request_count,v_idempotency_count,v_evaluation_count,v_decision_count,
      v_envelope_count,v_cancellation_count,v_attempt_count,v_receipt_count,v_event_count;
  end if;

  if not (
    v_policy.intake_enabled
    and v_policy.permit_verification_enabled
    and v_policy.permit_expiry_enforcement_enabled
    and v_policy.permit_revocation_enforcement_enabled
    and v_policy.scope_integrity_verification_enabled
    and v_policy.backend_binding_integrity_enabled
    and v_policy.decision_recording_enabled
    and v_policy.envelope_issuance_enabled
    and v_policy.envelope_cancellation_enabled
  ) then
    raise exception 'MIGRATION_137_REQUIRED_CAPABILITY_ASSERTION_FAILED';
  end if;

  if v_policy.automatic_dispatch_enabled or v_policy.dispatch_enabled
     or v_policy.queue_publication_enabled or v_policy.worker_claim_enabled
     or v_policy.permit_execution_enabled or v_policy.endpoint_discovery_enabled
     or v_policy.backend_probe_enabled or v_policy.backend_contact_enabled
     or v_policy.backend_authentication_enabled or v_policy.secret_lookup_enabled
     or v_policy.secret_resolution_enabled or v_policy.secret_decryption_enabled
     or v_policy.credential_material_loading_enabled or v_policy.credential_delivery_enabled
     or v_policy.network_access_enabled then
    raise exception 'MIGRATION_137_PASSIVE_POSTURE_ASSERTION_FAILED';
  end if;

  if not v_policy.opaque_references_only or not v_policy.plaintext_storage_forbidden
     or not v_policy.metadata_only or not v_policy.executable_envelopes_forbidden then
    raise exception 'MIGRATION_137_SECURITY_ASSERTION_FAILED';
  end if;

  raise notice
    'MIGRATION_137_CERTIFIED policy_count=%, request_count=%, idempotency_count=%, evaluation_count=%, decision_count=%, envelope_count=%, cancellation_count=%, attempt_count=%, receipt_count=%, event_count=%, intake_enabled=%, permit_verification_enabled=%, permit_expiry_enforcement_enabled=%, permit_revocation_enforcement_enabled=%, scope_integrity_verification_enabled=%, backend_binding_integrity_enabled=%, decision_recording_enabled=%, envelope_issuance_enabled=%, envelope_cancellation_enabled=%, maximum_envelope_lifetime_seconds=%, default_envelope_lifetime_seconds=%, automatic_dispatch_enabled=%, dispatch_enabled=%, queue_publication_enabled=%, worker_claim_enabled=%, permit_execution_enabled=%, endpoint_discovery_enabled=%, backend_probe_enabled=%, backend_contact_enabled=%, backend_authentication_enabled=%, secret_lookup_enabled=%, secret_resolution_enabled=%, secret_decryption_enabled=%, credential_material_loading_enabled=%, credential_delivery_enabled=%, network_access_enabled=%, opaque_references_only=%, plaintext_storage_forbidden=%, metadata_only=%, executable_envelopes_forbidden=%, dispatch_authorized=false, execution_authorized=false',
    v_policy_count,v_request_count,v_idempotency_count,v_evaluation_count,v_decision_count,
    v_envelope_count,v_cancellation_count,v_attempt_count,v_receipt_count,v_event_count,
    v_policy.intake_enabled,v_policy.permit_verification_enabled,
    v_policy.permit_expiry_enforcement_enabled,v_policy.permit_revocation_enforcement_enabled,
    v_policy.scope_integrity_verification_enabled,v_policy.backend_binding_integrity_enabled,
    v_policy.decision_recording_enabled,v_policy.envelope_issuance_enabled,
    v_policy.envelope_cancellation_enabled,v_policy.maximum_envelope_lifetime_seconds,
    v_policy.default_envelope_lifetime_seconds,v_policy.automatic_dispatch_enabled,
    v_policy.dispatch_enabled,v_policy.queue_publication_enabled,v_policy.worker_claim_enabled,
    v_policy.permit_execution_enabled,v_policy.endpoint_discovery_enabled,
    v_policy.backend_probe_enabled,v_policy.backend_contact_enabled,
    v_policy.backend_authentication_enabled,v_policy.secret_lookup_enabled,
    v_policy.secret_resolution_enabled,v_policy.secret_decryption_enabled,
    v_policy.credential_material_loading_enabled,v_policy.credential_delivery_enabled,
    v_policy.network_access_enabled,v_policy.opaque_references_only,
    v_policy.plaintext_storage_forbidden,v_policy.metadata_only,
    v_policy.executable_envelopes_forbidden;
end
$$;

commit;
