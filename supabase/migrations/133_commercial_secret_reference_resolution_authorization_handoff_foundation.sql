-- =============================================================================
-- FANTAGOL
-- Migration: 133_commercial_secret_reference_resolution_authorization_handoff_foundation.sql
-- Milestone: Commercial Secret Reference Resolution Authorization Handoff
--
-- Purpose:
--   Establish the passive, immutable handoff boundary between a certified
--   AUTHORIZED decision from migrations 131-132 and a future operational
--   secret-reference resolver.
--
-- This migration DOES NOT:
--   - discover or contact endpoints;
--   - authenticate to a backend;
--   - look up, resolve, decrypt or load a secret;
--   - transport credential material;
--   - dispatch network work;
--   - activate a provider integration;
--   - mutate purchases, checkout, wallet, ledger or runtime outbox state.
--
-- The handoff contains opaque identifiers and certified routing metadata only.
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
  if to_regclass('public.commercial_secret_reference_authorization_requests') is null
     or to_regclass('public.commercial_secret_reference_authorization_decisions') is null
     or to_regclass('public.commercial_secret_reference_authorization_read_model') is null
     or to_regclass('public.commercial_secret_reference_gateway_requests') is null
     or to_regclass('public.commercial_secret_reference_gateway_decisions') is null
     or to_regclass('public.commercial_secret_reference_route_manifests') is null
     or to_regclass('public.commercial_secret_backend_bindings') is null
     or to_regclass('public.commercial_secret_backends') is null
     or to_regclass('public.commercial_secret_backend_versions') is null then
    raise exception 'MIGRATION_133_REQUIRES_MIGRATIONS_127_TO_132';
  end if;
end
$$;

-- =============================================================================
-- 1. HANDOFF POLICY
-- =============================================================================

create table public.commercial_secret_reference_handoff_policies (
  id uuid primary key default gen_random_uuid(),
  policy_code text not null,
  environment text not null default 'production',
  policy_status text not null default 'draft',
  policy_version integer not null default 1,

  intake_enabled boolean not null default true,
  authorization_verification_enabled boolean not null default true,
  route_integrity_verification_enabled boolean not null default true,
  scope_integrity_verification_enabled boolean not null default true,
  capability_integrity_verification_enabled boolean not null default true,
  backend_binding_integrity_enabled boolean not null default true,
  manifest_generation_enabled boolean not null default true,
  decision_recording_enabled boolean not null default true,

  automatic_dispatch_enabled boolean not null default false,
  activation_enabled boolean not null default false,
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

  default_decision text not null default 'held',
  created_by text not null,
  approved_by text,
  approved_at timestamptz,
  policy_metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp(),

  constraint commercial_secret_reference_handoff_policy_unique
    unique(policy_code,environment),

  constraint commercial_secret_reference_handoff_policy_values_check
    check (
      policy_code=lower(policy_code)
      and policy_code ~ '^[a-z][a-z0-9:_-]{7,159}$'
      and environment in ('development','test','staging','production')
      and policy_status in ('draft','approved','retired')
      and policy_version>0
      and default_decision in ('held','blocked')
      and jsonb_typeof(policy_metadata)='object'
      and not (policy_metadata ?| array[
        'secret','secret_value','password','private_key','access_token',
        'refresh_token','api_key','client_secret','plaintext','ciphertext',
        'url','uri','endpoint','connection_string','dsn','host','hostname'
      ])
    ),

  constraint commercial_secret_reference_handoff_policy_passive_check
    check (
      automatic_dispatch_enabled=false
      and activation_enabled=false
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

comment on table public.commercial_secret_reference_handoff_policies is
'Immutable passive policy governing authorization-to-resolution handoff metadata.';

-- =============================================================================
-- 2. HANDOFF REQUESTS AND IDEMPOTENCY
-- =============================================================================

create table public.commercial_secret_reference_handoff_requests (
  id uuid primary key default gen_random_uuid(),
  request_key text not null unique,
  idempotency_key text not null unique,
  handoff_policy_id uuid not null,

  authorization_request_id uuid not null,
  authorization_decision_id uuid not null,
  gateway_request_id uuid not null,
  gateway_decision_id uuid not null,

  requested_environment text not null,
  requested_scope_type text not null,
  requested_scope_key text not null,
  requested_namespace text not null,
  requested_capability text not null,

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

  constraint commercial_secret_reference_handoff_request_policy_fkey
    foreign key(handoff_policy_id)
    references public.commercial_secret_reference_handoff_policies(id)
    on delete restrict,

  constraint commercial_secret_reference_handoff_request_authorization_request_fkey
    foreign key(authorization_request_id)
    references public.commercial_secret_reference_authorization_requests(id)
    on delete restrict,

  constraint commercial_secret_reference_handoff_request_authorization_decision_fkey
    foreign key(authorization_decision_id)
    references public.commercial_secret_reference_authorization_decisions(id)
    on delete restrict,

  constraint commercial_secret_reference_handoff_request_gateway_request_fkey
    foreign key(gateway_request_id)
    references public.commercial_secret_reference_gateway_requests(id)
    on delete restrict,

  constraint commercial_secret_reference_handoff_request_gateway_decision_fkey
    foreign key(gateway_decision_id)
    references public.commercial_secret_reference_gateway_decisions(id)
    on delete restrict,

  constraint commercial_secret_reference_handoff_request_values_check
    check (
      request_key=lower(request_key)
      and request_key ~ '^[a-z][a-z0-9:_-]{7,159}$'
      and length(idempotency_key) between 8 and 240
      and requested_environment in ('development','test','staging','production')
      and requested_scope_type in ('platform','provider','credential_binding')
      and requested_scope_key=lower(requested_scope_key)
      and requested_namespace=lower(requested_namespace)
      and requested_capability=lower(requested_capability)
      and request_status in ('received','evaluated','accepted','held','blocked','cancelled')
      and request_hash ~ '^[a-f0-9]{64}$'
      and jsonb_typeof(request_metadata)='object'
      and not (request_metadata ?| array[
        'secret','secret_value','password','private_key','access_token',
        'refresh_token','api_key','client_secret','plaintext','ciphertext',
        'url','uri','endpoint','connection_string','dsn','host','hostname'
      ])
    )
);

create index commercial_secret_reference_handoff_requests_queue_idx
  on public.commercial_secret_reference_handoff_requests
  (request_status,requested_at,id);

create table public.commercial_secret_reference_handoff_idempotency (
  id uuid primary key default gen_random_uuid(),
  idempotency_key text not null unique,
  handoff_request_id uuid not null unique,
  request_hash text not null,
  replay_count integer not null default 0,
  first_seen_at timestamptz not null default clock_timestamp(),
  last_seen_at timestamptz not null default clock_timestamp(),

  constraint commercial_secret_reference_handoff_idempotency_request_fkey
    foreign key(handoff_request_id)
    references public.commercial_secret_reference_handoff_requests(id)
    on delete restrict,

  constraint commercial_secret_reference_handoff_idempotency_values_check
    check (
      length(idempotency_key) between 8 and 240
      and request_hash ~ '^[a-f0-9]{64}$'
      and replay_count>=0
    )
);

-- =============================================================================
-- 3. EVALUATIONS
-- =============================================================================

create table public.commercial_secret_reference_handoff_evaluations (
  id uuid primary key default gen_random_uuid(),
  handoff_request_id uuid not null,
  evaluation_order integer not null,
  evaluation_code text not null,
  evaluation_status text not null,
  passed boolean not null,
  evaluation_reason text,
  evaluation_hash text not null,
  evaluation_metadata jsonb not null default '{}'::jsonb,
  evaluated_at timestamptz not null default clock_timestamp(),

  constraint commercial_secret_reference_handoff_evaluation_request_fkey
    foreign key(handoff_request_id)
    references public.commercial_secret_reference_handoff_requests(id)
    on delete restrict,

  constraint commercial_secret_reference_handoff_evaluation_unique
    unique(handoff_request_id,evaluation_order),

  constraint commercial_secret_reference_handoff_evaluation_values_check
    check (
      evaluation_order between 1 and 100
      and evaluation_code in (
        'AUTHORIZATION_DECISION','AUTHORIZATION_REQUEST_LINK',
        'GATEWAY_CHAIN','ENVIRONMENT','SCOPE','NAMESPACE',
        'CAPABILITY','BACKEND_BINDING','BACKEND_VERSION',
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
-- 4. HANDOFF DECISIONS
-- =============================================================================

create table public.commercial_secret_reference_handoff_decisions (
  id uuid primary key default gen_random_uuid(),
  handoff_request_id uuid not null unique,

  decision_status text not null,
  decision_code text not null,
  accepted boolean not null default false,

  authorization_decision_id uuid,
  selected_backend_binding_id uuid,
  selected_backend_id uuid,
  selected_backend_version_id uuid,

  resolved_environment text,
  resolved_scope_type text,
  resolved_scope_key text,
  resolved_namespace text,
  resolved_capability text,

  dispatch_allowed boolean not null default false,
  activation_allowed boolean not null default false,
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

  constraint commercial_secret_reference_handoff_decision_request_fkey
    foreign key(handoff_request_id)
    references public.commercial_secret_reference_handoff_requests(id)
    on delete restrict,

  constraint commercial_secret_reference_handoff_decision_authorization_fkey
    foreign key(authorization_decision_id)
    references public.commercial_secret_reference_authorization_decisions(id)
    on delete restrict,

  constraint commercial_secret_reference_handoff_decision_binding_fkey
    foreign key(selected_backend_binding_id)
    references public.commercial_secret_backend_bindings(id)
    on delete restrict,

  constraint commercial_secret_reference_handoff_decision_backend_fkey
    foreign key(selected_backend_id)
    references public.commercial_secret_backends(id)
    on delete restrict,

  constraint commercial_secret_reference_handoff_decision_version_fkey
    foreign key(selected_backend_version_id)
    references public.commercial_secret_backend_versions(id)
    on delete restrict,

  constraint commercial_secret_reference_handoff_decision_values_check
    check (
      decision_status in ('accepted','held','blocked')
      and decision_code in (
        'HANDOFF_ACCEPTED',
        'POLICY_DISABLED',
        'AUTHORIZATION_NOT_AUTHORIZED',
        'AUTHORIZATION_LINK_MISMATCH',
        'GATEWAY_CHAIN_MISMATCH',
        'ENVIRONMENT_MISMATCH',
        'SCOPE_MISMATCH',
        'NAMESPACE_MISMATCH',
        'CAPABILITY_MISMATCH',
        'BACKEND_BINDING_MISMATCH',
        'BACKEND_VERSION_INACTIVE',
        'PASSIVE_POSTURE_VIOLATION'
      )
      and accepted=(decision_status='accepted')
      and decision_hash ~ '^[a-f0-9]{64}$'
      and jsonb_typeof(decision_metadata)='object'
      and not (decision_metadata ?| array[
        'secret','secret_value','password','private_key','access_token',
        'refresh_token','api_key','client_secret','plaintext','ciphertext',
        'url','uri','endpoint','connection_string','dsn','host','hostname'
      ])
    ),

  constraint commercial_secret_reference_handoff_decision_passive_check
    check (
      dispatch_allowed=false
      and activation_allowed=false
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
-- 5. PASSIVE HANDOFF MANIFESTS
-- =============================================================================

create table public.commercial_secret_reference_handoff_manifests (
  id uuid primary key default gen_random_uuid(),
  manifest_key text not null unique,
  handoff_request_id uuid not null unique,
  handoff_decision_id uuid not null unique,
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

  manifest_status text not null default 'held',
  opaque_reference_contract boolean not null default true,
  metadata_only boolean not null default true,
  executable boolean not null default false,
  dispatch_allowed boolean not null default false,
  activation_allowed boolean not null default false,
  backend_contact_allowed boolean not null default false,
  secret_resolution_allowed boolean not null default false,
  network_access_allowed boolean not null default false,

  manifest_hash text not null,
  manifest_metadata jsonb not null default '{}'::jsonb,
  created_by text not null,
  created_at timestamptz not null default clock_timestamp(),

  constraint commercial_secret_reference_handoff_manifest_request_fkey
    foreign key(handoff_request_id)
    references public.commercial_secret_reference_handoff_requests(id)
    on delete restrict,

  constraint commercial_secret_reference_handoff_manifest_decision_fkey
    foreign key(handoff_decision_id)
    references public.commercial_secret_reference_handoff_decisions(id)
    on delete restrict,

  constraint commercial_secret_reference_handoff_manifest_authorization_request_fkey
    foreign key(authorization_request_id)
    references public.commercial_secret_reference_authorization_requests(id)
    on delete restrict,

  constraint commercial_secret_reference_handoff_manifest_authorization_decision_fkey
    foreign key(authorization_decision_id)
    references public.commercial_secret_reference_authorization_decisions(id)
    on delete restrict,

  constraint commercial_secret_reference_handoff_manifest_binding_fkey
    foreign key(selected_backend_binding_id)
    references public.commercial_secret_backend_bindings(id)
    on delete restrict,

  constraint commercial_secret_reference_handoff_manifest_backend_fkey
    foreign key(selected_backend_id)
    references public.commercial_secret_backends(id)
    on delete restrict,

  constraint commercial_secret_reference_handoff_manifest_version_fkey
    foreign key(selected_backend_version_id)
    references public.commercial_secret_backend_versions(id)
    on delete restrict,

  constraint commercial_secret_reference_handoff_manifest_values_check
    check (
      manifest_key=lower(manifest_key)
      and manifest_key ~ '^[a-z][a-z0-9:_-]{7,159}$'
      and environment in ('development','test','staging','production')
      and scope_type in ('platform','provider','credential_binding')
      and scope_key=lower(scope_key)
      and namespace_code=lower(namespace_code)
      and capability_code=lower(capability_code)
      and manifest_status in ('held','cancelled','superseded')
      and opaque_reference_contract=true
      and metadata_only=true
      and executable=false
      and dispatch_allowed=false
      and activation_allowed=false
      and backend_contact_allowed=false
      and secret_resolution_allowed=false
      and network_access_allowed=false
      and manifest_hash ~ '^[a-f0-9]{64}$'
      and jsonb_typeof(manifest_metadata)='object'
      and not (manifest_metadata ?| array[
        'secret','secret_value','password','private_key','access_token',
        'refresh_token','api_key','client_secret','plaintext','ciphertext',
        'url','uri','endpoint','connection_string','dsn','host','hostname'
      ])
    )
);

-- =============================================================================
-- 6. BLOCKED ATTEMPTS, RECEIPTS AND EVENTS
-- =============================================================================

create table public.commercial_secret_reference_handoff_attempts (
  id uuid primary key default gen_random_uuid(),
  handoff_request_id uuid not null,
  handoff_decision_id uuid,
  handoff_manifest_id uuid,
  attempt_type text not null,
  attempt_status text not null,
  block_code text not null,
  attempted_by text not null,
  correlation_id uuid,
  attempt_hash text not null,
  attempt_metadata jsonb not null default '{}'::jsonb,
  attempted_at timestamptz not null default clock_timestamp(),

  constraint commercial_secret_reference_handoff_attempt_request_fkey
    foreign key(handoff_request_id)
    references public.commercial_secret_reference_handoff_requests(id)
    on delete restrict,

  constraint commercial_secret_reference_handoff_attempt_decision_fkey
    foreign key(handoff_decision_id)
    references public.commercial_secret_reference_handoff_decisions(id)
    on delete restrict,

  constraint commercial_secret_reference_handoff_attempt_manifest_fkey
    foreign key(handoff_manifest_id)
    references public.commercial_secret_reference_handoff_manifests(id)
    on delete restrict,

  constraint commercial_secret_reference_handoff_attempt_values_check
    check (
      attempt_type in (
        'DISPATCH','ACTIVATION','ENDPOINT_DISCOVERY','BACKEND_CONTACT',
        'AUTHENTICATION','SECRET_LOOKUP','SECRET_RESOLUTION',
        'SECRET_DECRYPTION','MATERIAL_LOADING','DELIVERY','NETWORK_ACCESS'
      )
      and attempt_status='blocked'
      and block_code='PASSIVE_HANDOFF_EXECUTION_FORBIDDEN'
      and attempt_hash ~ '^[a-f0-9]{64}$'
      and jsonb_typeof(attempt_metadata)='object'
      and not (attempt_metadata ?| array[
        'secret','secret_value','password','private_key','access_token',
        'refresh_token','api_key','client_secret','plaintext','ciphertext',
        'url','uri','endpoint','connection_string','dsn','host','hostname'
      ])
    )
);

create table public.commercial_secret_reference_handoff_receipts (
  id uuid primary key default gen_random_uuid(),
  receipt_type text not null,
  handoff_request_id uuid,
  handoff_decision_id uuid,
  handoff_manifest_id uuid,
  handoff_attempt_id uuid,
  receipt_status text not null,
  receipt_code text not null,
  receipt_message text,
  recorded_by text not null,
  correlation_id uuid,
  receipt_hash text not null,
  receipt_metadata jsonb not null default '{}'::jsonb,
  recorded_at timestamptz not null default clock_timestamp(),

  constraint commercial_secret_reference_handoff_receipt_request_fkey
    foreign key(handoff_request_id)
    references public.commercial_secret_reference_handoff_requests(id)
    on delete restrict,

  constraint commercial_secret_reference_handoff_receipt_decision_fkey
    foreign key(handoff_decision_id)
    references public.commercial_secret_reference_handoff_decisions(id)
    on delete restrict,

  constraint commercial_secret_reference_handoff_receipt_manifest_fkey
    foreign key(handoff_manifest_id)
    references public.commercial_secret_reference_handoff_manifests(id)
    on delete restrict,

  constraint commercial_secret_reference_handoff_receipt_attempt_fkey
    foreign key(handoff_attempt_id)
    references public.commercial_secret_reference_handoff_attempts(id)
    on delete restrict,

  constraint commercial_secret_reference_handoff_receipt_values_check
    check (
      receipt_type in (
        'REQUEST_ACCEPTED','REQUEST_REPLAYED','EVALUATION_COMPLETED',
        'DECISION_RECORDED','MANIFEST_CREATED','EXECUTION_BLOCKED'
      )
      and receipt_status in ('accepted','replayed','passed','held','blocked','recorded')
      and receipt_hash ~ '^[a-f0-9]{64}$'
      and jsonb_typeof(receipt_metadata)='object'
      and not (receipt_metadata ?| array[
        'secret','secret_value','password','private_key','access_token',
        'refresh_token','api_key','client_secret','plaintext','ciphertext',
        'url','uri','endpoint','connection_string','dsn','host','hostname'
      ])
    )
);

create table public.commercial_secret_reference_handoff_events (
  id uuid primary key default gen_random_uuid(),
  event_type text not null,
  handoff_policy_id uuid,
  handoff_request_id uuid,
  handoff_decision_id uuid,
  handoff_manifest_id uuid,
  handoff_attempt_id uuid,
  event_status text not null,
  event_message text,
  event_source text not null,
  correlation_id uuid,
  causation_id uuid,
  event_hash text not null,
  event_metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp(),

  constraint commercial_secret_reference_handoff_event_policy_fkey
    foreign key(handoff_policy_id)
    references public.commercial_secret_reference_handoff_policies(id)
    on delete restrict,

  constraint commercial_secret_reference_handoff_event_request_fkey
    foreign key(handoff_request_id)
    references public.commercial_secret_reference_handoff_requests(id)
    on delete restrict,

  constraint commercial_secret_reference_handoff_event_decision_fkey
    foreign key(handoff_decision_id)
    references public.commercial_secret_reference_handoff_decisions(id)
    on delete restrict,

  constraint commercial_secret_reference_handoff_event_manifest_fkey
    foreign key(handoff_manifest_id)
    references public.commercial_secret_reference_handoff_manifests(id)
    on delete restrict,

  constraint commercial_secret_reference_handoff_event_attempt_fkey
    foreign key(handoff_attempt_id)
    references public.commercial_secret_reference_handoff_attempts(id)
    on delete restrict,

  constraint commercial_secret_reference_handoff_event_values_check
    check (
      event_type ~ '^[A-Z][A-Z0-9_]{3,95}$'
      and event_status in ('draft','approved','received','evaluated','accepted','held','blocked','recorded')
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
-- 7. GENERIC PROTECTION
-- =============================================================================

create function public.commercial_secret_reference_handoff_set_updated_at()
returns trigger
language plpgsql
set search_path=public,pg_temp
as $$
begin
  new.updated_at=clock_timestamp();
  return new;
end
$$;

create function public.commercial_secret_reference_handoff_immutable()
returns trigger
language plpgsql
set search_path=public,pg_temp
as $$
begin
  raise exception 'COMMERCIAL_SECRET_REFERENCE_HANDOFF_IMMUTABLE';
end
$$;

create function public.commercial_secret_reference_handoff_append_only()
returns trigger
language plpgsql
set search_path=public,pg_temp
as $$
begin
  raise exception 'COMMERCIAL_SECRET_REFERENCE_HANDOFF_APPEND_ONLY';
end
$$;

create trigger commercial_secret_reference_handoff_requests_updated_at
before update on public.commercial_secret_reference_handoff_requests
for each row execute function public.commercial_secret_reference_handoff_set_updated_at();

create trigger commercial_secret_reference_handoff_policies_immutable
before update or delete on public.commercial_secret_reference_handoff_policies
for each row execute function public.commercial_secret_reference_handoff_immutable();

create trigger commercial_secret_reference_handoff_evaluations_immutable
before update or delete on public.commercial_secret_reference_handoff_evaluations
for each row execute function public.commercial_secret_reference_handoff_immutable();

create trigger commercial_secret_reference_handoff_decisions_immutable
before update or delete on public.commercial_secret_reference_handoff_decisions
for each row execute function public.commercial_secret_reference_handoff_immutable();

create trigger commercial_secret_reference_handoff_manifests_immutable
before update or delete on public.commercial_secret_reference_handoff_manifests
for each row execute function public.commercial_secret_reference_handoff_immutable();

create trigger commercial_secret_reference_handoff_attempts_append_only
before update or delete on public.commercial_secret_reference_handoff_attempts
for each row execute function public.commercial_secret_reference_handoff_append_only();

create trigger commercial_secret_reference_handoff_receipts_append_only
before update or delete on public.commercial_secret_reference_handoff_receipts
for each row execute function public.commercial_secret_reference_handoff_append_only();

create trigger commercial_secret_reference_handoff_events_append_only
before update or delete on public.commercial_secret_reference_handoff_events
for each row execute function public.commercial_secret_reference_handoff_append_only();

-- =============================================================================
-- 8. APPEND HELPERS
-- =============================================================================

create function public.append_commercial_secret_reference_handoff_receipt(
  p_receipt_type text,
  p_handoff_request_id uuid,
  p_handoff_decision_id uuid,
  p_handoff_manifest_id uuid,
  p_handoff_attempt_id uuid,
  p_receipt_status text,
  p_receipt_code text,
  p_receipt_message text,
  p_recorded_by text,
  p_correlation_id uuid default null,
  p_receipt_metadata jsonb default '{}'::jsonb
)
returns public.commercial_secret_reference_handoff_receipts
language plpgsql
security definer
set search_path=public,extensions,pg_temp
as $$
declare
  v_hash text;
  v_row public.commercial_secret_reference_handoff_receipts;
begin
  v_hash:=encode(extensions.digest(
    concat_ws('|',p_receipt_type,p_handoff_request_id,p_handoff_decision_id,
      p_handoff_manifest_id,p_handoff_attempt_id,p_receipt_status,p_receipt_code,
      p_receipt_message,p_recorded_by,p_correlation_id,
      coalesce(p_receipt_metadata,'{}'::jsonb)::text,clock_timestamp()::text
    ),'sha256'),'hex');

  insert into public.commercial_secret_reference_handoff_receipts(
    receipt_type,handoff_request_id,handoff_decision_id,handoff_manifest_id,
    handoff_attempt_id,receipt_status,receipt_code,receipt_message,recorded_by,
    correlation_id,receipt_hash,receipt_metadata
  ) values (
    p_receipt_type,p_handoff_request_id,p_handoff_decision_id,p_handoff_manifest_id,
    p_handoff_attempt_id,p_receipt_status,p_receipt_code,p_receipt_message,p_recorded_by,
    p_correlation_id,v_hash,coalesce(p_receipt_metadata,'{}'::jsonb)
  ) returning * into v_row;

  return v_row;
end
$$;

create function public.append_commercial_secret_reference_handoff_event(
  p_event_type text,
  p_handoff_policy_id uuid,
  p_handoff_request_id uuid,
  p_handoff_decision_id uuid,
  p_handoff_manifest_id uuid,
  p_handoff_attempt_id uuid,
  p_event_status text,
  p_event_message text,
  p_event_source text,
  p_correlation_id uuid default null,
  p_causation_id uuid default null,
  p_event_metadata jsonb default '{}'::jsonb
)
returns public.commercial_secret_reference_handoff_events
language plpgsql
security definer
set search_path=public,extensions,pg_temp
as $$
declare
  v_hash text;
  v_row public.commercial_secret_reference_handoff_events;
begin
  v_hash:=encode(extensions.digest(
    concat_ws('|',p_event_type,p_handoff_policy_id,p_handoff_request_id,
      p_handoff_decision_id,p_handoff_manifest_id,p_handoff_attempt_id,
      p_event_status,p_event_message,p_event_source,p_correlation_id,p_causation_id,
      coalesce(p_event_metadata,'{}'::jsonb)::text,clock_timestamp()::text
    ),'sha256'),'hex');

  insert into public.commercial_secret_reference_handoff_events(
    event_type,handoff_policy_id,handoff_request_id,handoff_decision_id,
    handoff_manifest_id,handoff_attempt_id,event_status,event_message,event_source,
    correlation_id,causation_id,event_hash,event_metadata
  ) values (
    p_event_type,p_handoff_policy_id,p_handoff_request_id,p_handoff_decision_id,
    p_handoff_manifest_id,p_handoff_attempt_id,p_event_status,p_event_message,p_event_source,
    p_correlation_id,p_causation_id,v_hash,coalesce(p_event_metadata,'{}'::jsonb)
  ) returning * into v_row;

  return v_row;
end
$$;

-- =============================================================================
-- 9. ENQUEUE
-- =============================================================================

create function public.enqueue_commercial_secret_reference_handoff_request(
  p_request_key text,
  p_idempotency_key text,
  p_authorization_request_id uuid,
  p_authorization_decision_id uuid,
  p_requested_environment text,
  p_requested_scope_type text,
  p_requested_scope_key text,
  p_requested_namespace text,
  p_requested_capability text,
  p_requested_by text,
  p_correlation_id uuid default gen_random_uuid(),
  p_causation_id uuid default null,
  p_request_metadata jsonb default '{}'::jsonb
)
returns public.commercial_secret_reference_handoff_requests
language plpgsql
security definer
set search_path=public,extensions,pg_temp
as $$
declare
  v_policy public.commercial_secret_reference_handoff_policies;
  v_authorization_request public.commercial_secret_reference_authorization_requests;
  v_authorization_decision public.commercial_secret_reference_authorization_decisions;
  v_existing public.commercial_secret_reference_handoff_idempotency;
  v_request public.commercial_secret_reference_handoff_requests;
  v_hash text;
begin
  select * into strict v_policy
  from public.commercial_secret_reference_handoff_policies
  where policy_code='commercial:secret_reference_resolution_handoff:v1'
    and environment=p_requested_environment
    and policy_status='approved';

  if not v_policy.intake_enabled then
    raise exception 'COMMERCIAL_SECRET_REFERENCE_HANDOFF_INTAKE_DISABLED';
  end if;

  select * into strict v_authorization_request
  from public.commercial_secret_reference_authorization_requests
  where id=p_authorization_request_id;

  select * into strict v_authorization_decision
  from public.commercial_secret_reference_authorization_decisions
  where id=p_authorization_decision_id;

  v_hash:=encode(extensions.digest(
    concat_ws('|',lower(p_request_key),p_idempotency_key,p_authorization_request_id,
      p_authorization_decision_id,lower(p_requested_environment),
      lower(p_requested_scope_type),lower(p_requested_scope_key),
      lower(p_requested_namespace),lower(p_requested_capability),
      coalesce(p_request_metadata,'{}'::jsonb)::text
    ),'sha256'),'hex');

  select * into v_existing
  from public.commercial_secret_reference_handoff_idempotency
  where idempotency_key=p_idempotency_key
  for update;

  if found then
    if v_existing.request_hash<>v_hash then
      raise exception 'COMMERCIAL_SECRET_REFERENCE_HANDOFF_IDEMPOTENCY_CONFLICT';
    end if;

    update public.commercial_secret_reference_handoff_idempotency
    set replay_count=replay_count+1,last_seen_at=clock_timestamp()
    where id=v_existing.id;

    select * into strict v_request
    from public.commercial_secret_reference_handoff_requests
    where id=v_existing.handoff_request_id;

    perform public.append_commercial_secret_reference_handoff_receipt(
      'REQUEST_REPLAYED',v_request.id,null,null,null,'replayed',
      'HANDOFF_REQUEST_REPLAYED','Idempotent handoff request replayed',
      p_requested_by,p_correlation_id,jsonb_build_object('request_hash',v_hash)
    );

    return v_request;
  end if;

  insert into public.commercial_secret_reference_handoff_requests(
    request_key,idempotency_key,handoff_policy_id,
    authorization_request_id,authorization_decision_id,
    gateway_request_id,gateway_decision_id,
    requested_environment,requested_scope_type,requested_scope_key,
    requested_namespace,requested_capability,request_status,
    correlation_id,causation_id,requested_by,request_hash,request_metadata
  ) values (
    lower(p_request_key),p_idempotency_key,v_policy.id,
    v_authorization_request.id,v_authorization_decision.id,
    v_authorization_request.gateway_request_id,
    v_authorization_request.gateway_decision_id,
    lower(p_requested_environment),lower(p_requested_scope_type),
    lower(p_requested_scope_key),lower(p_requested_namespace),
    lower(p_requested_capability),'received',
    p_correlation_id,p_causation_id,p_requested_by,v_hash,
    coalesce(p_request_metadata,'{}'::jsonb)
  ) returning * into v_request;

  insert into public.commercial_secret_reference_handoff_idempotency(
    idempotency_key,handoff_request_id,request_hash
  ) values (p_idempotency_key,v_request.id,v_hash);

  perform public.append_commercial_secret_reference_handoff_receipt(
    'REQUEST_ACCEPTED',v_request.id,null,null,null,'accepted',
    'HANDOFF_REQUEST_ACCEPTED','Passive authorization handoff request accepted',
    p_requested_by,p_correlation_id,jsonb_build_object('request_hash',v_hash)
  );

  perform public.append_commercial_secret_reference_handoff_event(
    'SECRET_REFERENCE_HANDOFF_REQUESTED',v_policy.id,v_request.id,null,null,null,
    'received','Authorization handoff request recorded','HANDOFF_ENGINE',
    p_correlation_id,p_causation_id,
    jsonb_build_object('authorization_decision_id',p_authorization_decision_id)
  );

  return v_request;
end
$$;

-- =============================================================================
-- 10. EVALUATE HANDOFF
-- =============================================================================

create function public.evaluate_commercial_secret_reference_handoff_request(
  p_handoff_request_id uuid,
  p_decided_by text
)
returns public.commercial_secret_reference_handoff_decisions
language plpgsql
security definer
set search_path=public,extensions,pg_temp
as $$
declare
  v_request public.commercial_secret_reference_handoff_requests;
  v_policy public.commercial_secret_reference_handoff_policies;
  v_auth_request public.commercial_secret_reference_authorization_requests;
  v_auth_decision public.commercial_secret_reference_authorization_decisions;
  v_gateway_decision public.commercial_secret_reference_gateway_decisions;
  v_binding public.commercial_secret_backend_bindings;
  v_backend public.commercial_secret_backends;
  v_version public.commercial_secret_backend_versions;
  v_existing public.commercial_secret_reference_handoff_decisions;
  v_decision public.commercial_secret_reference_handoff_decisions;
  v_status text:='accepted';
  v_code text:='HANDOFF_ACCEPTED';
  v_reason text:='Authorized opaque-reference metadata accepted for passive handoff';
  v_order integer:=0;
  v_pass boolean;
  v_hash text;
begin
  select * into strict v_request
  from public.commercial_secret_reference_handoff_requests
  where id=p_handoff_request_id
  for update;

  select * into v_existing
  from public.commercial_secret_reference_handoff_decisions
  where handoff_request_id=v_request.id;

  if found then
    return v_existing;
  end if;

  select * into strict v_policy
  from public.commercial_secret_reference_handoff_policies
  where id=v_request.handoff_policy_id;

  select * into strict v_auth_request
  from public.commercial_secret_reference_authorization_requests
  where id=v_request.authorization_request_id;

  select * into strict v_auth_decision
  from public.commercial_secret_reference_authorization_decisions
  where id=v_request.authorization_decision_id;

  select * into strict v_gateway_decision
  from public.commercial_secret_reference_gateway_decisions
  where id=v_request.gateway_decision_id;

  -- 1. Authorization decision
  v_order:=v_order+1;
  v_pass:=v_auth_decision.authorized
          and v_auth_decision.decision_status='authorized'
          and v_auth_decision.decision_code='AUTHORIZED';

  insert into public.commercial_secret_reference_handoff_evaluations(
    handoff_request_id,evaluation_order,evaluation_code,evaluation_status,
    passed,evaluation_reason,evaluation_hash,evaluation_metadata
  ) values (
    v_request.id,v_order,'AUTHORIZATION_DECISION',
    case when v_pass then 'passed' else 'failed' end,
    v_pass,
    case when v_pass then 'Authorization decision is AUTHORIZED'
         else 'Authorization decision is not AUTHORIZED' end,
    encode(extensions.digest(concat_ws('|',v_request.id,v_order,'AUTHORIZATION_DECISION',v_pass),'sha256'),'hex'),
    jsonb_build_object('decision_code',v_auth_decision.decision_code)
  );

  if not v_pass then
    v_status:='blocked'; v_code:='AUTHORIZATION_NOT_AUTHORIZED';
    v_reason:='Authorization decision does not permit handoff';
  end if;

  -- 2. Authorization request link
  v_order:=v_order+1;
  v_pass:=v_auth_decision.authorization_request_id=v_auth_request.id
          and v_auth_request.id=v_request.authorization_request_id;

  insert into public.commercial_secret_reference_handoff_evaluations(
    handoff_request_id,evaluation_order,evaluation_code,evaluation_status,
    passed,evaluation_reason,evaluation_hash,evaluation_metadata
  ) values (
    v_request.id,v_order,'AUTHORIZATION_REQUEST_LINK',
    case when v_pass then 'passed' else 'failed' end,v_pass,
    case when v_pass then 'Authorization request and decision are linked'
         else 'Authorization request and decision link mismatch' end,
    encode(extensions.digest(concat_ws('|',v_request.id,v_order,'AUTHORIZATION_REQUEST_LINK',v_pass),'sha256'),'hex'),
    '{}'::jsonb
  );

  if v_status='accepted' and not v_pass then
    v_status:='blocked'; v_code:='AUTHORIZATION_LINK_MISMATCH';
    v_reason:='Authorization request and decision are inconsistent';
  end if;

  -- 3. Gateway chain
  v_order:=v_order+1;
  v_pass:=v_auth_request.gateway_request_id=v_request.gateway_request_id
          and v_auth_request.gateway_decision_id=v_request.gateway_decision_id
          and v_gateway_decision.gateway_request_id=v_request.gateway_request_id
          and v_gateway_decision.decision_status='accepted'
          and v_gateway_decision.decision_code='ROUTE_METADATA_ACCEPTED';

  insert into public.commercial_secret_reference_handoff_evaluations(
    handoff_request_id,evaluation_order,evaluation_code,evaluation_status,
    passed,evaluation_reason,evaluation_hash,evaluation_metadata
  ) values (
    v_request.id,v_order,'GATEWAY_CHAIN',
    case when v_pass then 'passed' else 'failed' end,v_pass,
    case when v_pass then 'Gateway chain is accepted and linked'
         else 'Gateway chain is not accepted or linked' end,
    encode(extensions.digest(concat_ws('|',v_request.id,v_order,'GATEWAY_CHAIN',v_pass),'sha256'),'hex'),
    jsonb_build_object('gateway_decision_code',v_gateway_decision.decision_code)
  );

  if v_status='accepted' and not v_pass then
    v_status:='blocked'; v_code:='GATEWAY_CHAIN_MISMATCH';
    v_reason:='Gateway chain does not match authorization';
  end if;

  -- Resolve selected backend chain for subsequent checks.
  if v_auth_decision.selected_backend_binding_id is not null then
    select * into strict v_binding
    from public.commercial_secret_backend_bindings
    where id=v_auth_decision.selected_backend_binding_id;

    select * into strict v_backend
    from public.commercial_secret_backends
    where id=v_auth_decision.selected_backend_id;

    select * into strict v_version
    from public.commercial_secret_backend_versions
    where id=v_auth_decision.selected_backend_version_id;
  end if;

  -- 4. Environment
  v_order:=v_order+1;
  v_pass:=v_request.requested_environment=v_auth_request.requested_environment
          and v_request.requested_environment=v_policy.environment;

  insert into public.commercial_secret_reference_handoff_evaluations(
    handoff_request_id,evaluation_order,evaluation_code,evaluation_status,
    passed,evaluation_reason,evaluation_hash,evaluation_metadata
  ) values (
    v_request.id,v_order,'ENVIRONMENT',
    case when v_pass then 'passed' else 'failed' end,v_pass,
    case when v_pass then 'Environment is consistent'
         else 'Environment mismatch' end,
    encode(extensions.digest(concat_ws('|',v_request.id,v_order,'ENVIRONMENT',v_pass),'sha256'),'hex'),
    '{}'::jsonb
  );

  if v_status='accepted' and not v_pass then
    v_status:='blocked'; v_code:='ENVIRONMENT_MISMATCH';
    v_reason:='Requested environment differs from authorization policy';
  end if;

  -- 5. Scope
  v_order:=v_order+1;
  v_pass:=v_request.requested_scope_type=v_auth_decision.resolved_scope_type
          and v_request.requested_scope_key=v_auth_decision.resolved_scope_key;

  insert into public.commercial_secret_reference_handoff_evaluations(
    handoff_request_id,evaluation_order,evaluation_code,evaluation_status,
    passed,evaluation_reason,evaluation_hash,evaluation_metadata
  ) values (
    v_request.id,v_order,'SCOPE',
    case when v_pass then 'passed' else 'failed' end,v_pass,
    case when v_pass then 'Scope matches authorization'
         else 'Scope mismatch' end,
    encode(extensions.digest(concat_ws('|',v_request.id,v_order,'SCOPE',v_pass),'sha256'),'hex'),
    '{}'::jsonb
  );

  if v_status='accepted' and not v_pass then
    v_status:='blocked'; v_code:='SCOPE_MISMATCH';
    v_reason:='Requested scope differs from authorization';
  end if;

  -- 6. Namespace
  v_order:=v_order+1;
  v_pass:=v_request.requested_namespace=v_auth_decision.resolved_namespace;

  insert into public.commercial_secret_reference_handoff_evaluations(
    handoff_request_id,evaluation_order,evaluation_code,evaluation_status,
    passed,evaluation_reason,evaluation_hash,evaluation_metadata
  ) values (
    v_request.id,v_order,'NAMESPACE',
    case when v_pass then 'passed' else 'failed' end,v_pass,
    case when v_pass then 'Namespace matches authorization'
         else 'Namespace mismatch' end,
    encode(extensions.digest(concat_ws('|',v_request.id,v_order,'NAMESPACE',v_pass),'sha256'),'hex'),
    '{}'::jsonb
  );

  if v_status='accepted' and not v_pass then
    v_status:='blocked'; v_code:='NAMESPACE_MISMATCH';
    v_reason:='Requested namespace differs from authorization';
  end if;

  -- 7. Capability
  v_order:=v_order+1;
  v_pass:=v_request.requested_capability=v_auth_decision.resolved_capability;

  insert into public.commercial_secret_reference_handoff_evaluations(
    handoff_request_id,evaluation_order,evaluation_code,evaluation_status,
    passed,evaluation_reason,evaluation_hash,evaluation_metadata
  ) values (
    v_request.id,v_order,'CAPABILITY',
    case when v_pass then 'passed' else 'failed' end,v_pass,
    case when v_pass then 'Capability matches authorization'
         else 'Capability mismatch' end,
    encode(extensions.digest(concat_ws('|',v_request.id,v_order,'CAPABILITY',v_pass),'sha256'),'hex'),
    '{}'::jsonb
  );

  if v_status='accepted' and not v_pass then
    v_status:='blocked'; v_code:='CAPABILITY_MISMATCH';
    v_reason:='Requested capability differs from authorization';
  end if;

  -- 8. Backend binding
  v_order:=v_order+1;
  v_pass:=v_binding.id is not null
          and v_binding.id=v_auth_decision.selected_backend_binding_id
          and v_binding.secret_backend_id=v_auth_decision.selected_backend_id
          and v_binding.secret_backend_version_id=v_auth_decision.selected_backend_version_id
          and v_binding.binding_status='validated';

  insert into public.commercial_secret_reference_handoff_evaluations(
    handoff_request_id,evaluation_order,evaluation_code,evaluation_status,
    passed,evaluation_reason,evaluation_hash,evaluation_metadata
  ) values (
    v_request.id,v_order,'BACKEND_BINDING',
    case when v_pass then 'passed' else 'failed' end,v_pass,
    case when v_pass then 'Validated backend binding matches authorization'
         else 'Backend binding mismatch or not validated' end,
    encode(extensions.digest(concat_ws('|',v_request.id,v_order,'BACKEND_BINDING',v_pass),'sha256'),'hex'),
    '{}'::jsonb
  );

  if v_status='accepted' and not v_pass then
    v_status:='blocked'; v_code:='BACKEND_BINDING_MISMATCH';
    v_reason:='Backend binding does not satisfy handoff integrity';
  end if;

  -- 9. Backend version
  v_order:=v_order+1;
  v_pass:=v_version.id is not null
          and v_version.id=v_auth_decision.selected_backend_version_id
          and v_version.version_status='validated';

  insert into public.commercial_secret_reference_handoff_evaluations(
    handoff_request_id,evaluation_order,evaluation_code,evaluation_status,
    passed,evaluation_reason,evaluation_hash,evaluation_metadata
  ) values (
    v_request.id,v_order,'BACKEND_VERSION',
    case when v_pass then 'passed' else 'failed' end,v_pass,
    case when v_pass then 'Backend version contract is validated'
         else 'Backend version contract is not validated' end,
    encode(extensions.digest(concat_ws('|',v_request.id,v_order,'BACKEND_VERSION',v_pass),'sha256'),'hex'),
    '{}'::jsonb
  );

  if v_status='accepted' and not v_pass then
    v_status:='blocked'; v_code:='BACKEND_VERSION_INACTIVE';
    v_reason:='Backend version contract is not active';
  end if;

  -- 10. Passive posture
  v_order:=v_order+1;
  v_pass:=not v_policy.automatic_dispatch_enabled
          and not v_policy.activation_enabled
          and not v_policy.endpoint_discovery_enabled
          and not v_policy.backend_probe_enabled
          and not v_policy.backend_contact_enabled
          and not v_policy.backend_authentication_enabled
          and not v_policy.secret_lookup_enabled
          and not v_policy.secret_resolution_enabled
          and not v_policy.secret_decryption_enabled
          and not v_policy.credential_material_loading_enabled
          and not v_policy.credential_delivery_enabled
          and not v_policy.network_access_enabled;

  insert into public.commercial_secret_reference_handoff_evaluations(
    handoff_request_id,evaluation_order,evaluation_code,evaluation_status,
    passed,evaluation_reason,evaluation_hash,evaluation_metadata
  ) values (
    v_request.id,v_order,'PASSIVE_POSTURE',
    case when v_pass then 'passed' else 'failed' end,v_pass,
    case when v_pass then 'Passive handoff posture is enforced'
         else 'Passive handoff posture violation' end,
    encode(extensions.digest(concat_ws('|',v_request.id,v_order,'PASSIVE_POSTURE',v_pass),'sha256'),'hex'),
    jsonb_build_object(
      'automatic_dispatch_enabled',v_policy.automatic_dispatch_enabled,
      'activation_enabled',v_policy.activation_enabled,
      'backend_contact_enabled',v_policy.backend_contact_enabled,
      'secret_resolution_enabled',v_policy.secret_resolution_enabled,
      'network_access_enabled',v_policy.network_access_enabled
    )
  );

  if v_status='accepted' and not v_pass then
    v_status:='blocked'; v_code:='PASSIVE_POSTURE_VIOLATION';
    v_reason:='Handoff policy permits active execution';
  end if;

  v_hash:=encode(extensions.digest(
    concat_ws('|',v_request.id,v_status,v_code,v_auth_decision.id,
      v_auth_decision.selected_backend_binding_id,
      v_auth_decision.selected_backend_id,
      v_auth_decision.selected_backend_version_id,
      v_request.requested_environment,v_request.requested_scope_type,
      v_request.requested_scope_key,v_request.requested_namespace,
      v_request.requested_capability,v_reason
    ),'sha256'),'hex');

  insert into public.commercial_secret_reference_handoff_decisions(
    handoff_request_id,decision_status,decision_code,accepted,
    authorization_decision_id,selected_backend_binding_id,
    selected_backend_id,selected_backend_version_id,
    resolved_environment,resolved_scope_type,resolved_scope_key,
    resolved_namespace,resolved_capability,
    decided_by,decision_reason,decision_hash,decision_metadata
  ) values (
    v_request.id,v_status,v_code,(v_status='accepted'),
    v_auth_decision.id,v_auth_decision.selected_backend_binding_id,
    v_auth_decision.selected_backend_id,v_auth_decision.selected_backend_version_id,
    v_request.requested_environment,v_request.requested_scope_type,
    v_request.requested_scope_key,v_request.requested_namespace,
    v_request.requested_capability,
    p_decided_by,v_reason,v_hash,
    jsonb_build_object('passive_handoff_only',true,'evaluation_count',v_order)
  ) returning * into v_decision;

  update public.commercial_secret_reference_handoff_requests
  set request_status=v_status,evaluated_at=clock_timestamp(),terminal_reason=v_reason
  where id=v_request.id;

  perform public.append_commercial_secret_reference_handoff_receipt(
    'EVALUATION_COMPLETED',v_request.id,v_decision.id,null,null,
    case when v_status='accepted' then 'passed' else v_status end,
    v_code,v_reason,p_decided_by,v_request.correlation_id,
    jsonb_build_object('evaluation_count',v_order)
  );

  perform public.append_commercial_secret_reference_handoff_receipt(
    'DECISION_RECORDED',v_request.id,v_decision.id,null,null,
    v_status,v_code,v_reason,p_decided_by,v_request.correlation_id,
    jsonb_build_object('accepted',v_decision.accepted)
  );

  perform public.append_commercial_secret_reference_handoff_event(
    'SECRET_REFERENCE_HANDOFF_DECIDED',v_policy.id,v_request.id,v_decision.id,
    null,null,v_status,v_reason,'HANDOFF_ENGINE',
    v_request.correlation_id,v_request.causation_id,
    jsonb_build_object('decision_code',v_code,'accepted',v_decision.accepted)
  );

  return v_decision;
end
$$;

-- =============================================================================
-- 11. BUILD PASSIVE MANIFEST
-- =============================================================================

create function public.build_commercial_secret_reference_handoff_manifest(
  p_handoff_request_id uuid,
  p_created_by text,
  p_manifest_metadata jsonb default '{}'::jsonb
)
returns public.commercial_secret_reference_handoff_manifests
language plpgsql
security definer
set search_path=public,extensions,pg_temp
as $$
declare
  v_request public.commercial_secret_reference_handoff_requests;
  v_decision public.commercial_secret_reference_handoff_decisions;
  v_existing public.commercial_secret_reference_handoff_manifests;
  v_manifest public.commercial_secret_reference_handoff_manifests;
  v_key text;
  v_hash text;
begin
  select * into strict v_request
  from public.commercial_secret_reference_handoff_requests
  where id=p_handoff_request_id;

  select * into strict v_decision
  from public.commercial_secret_reference_handoff_decisions
  where handoff_request_id=v_request.id;

  if not v_decision.accepted
     or v_decision.decision_status<>'accepted'
     or v_decision.decision_code<>'HANDOFF_ACCEPTED' then
    raise exception 'COMMERCIAL_SECRET_REFERENCE_HANDOFF_MANIFEST_REQUIRES_ACCEPTED_DECISION';
  end if;

  select * into v_existing
  from public.commercial_secret_reference_handoff_manifests
  where handoff_request_id=v_request.id;

  if found then
    return v_existing;
  end if;

  v_key:='commercial:secret_reference:handoff:'||
    replace(v_request.id::text,'-','');

  v_hash:=encode(extensions.digest(
    concat_ws('|',v_key,v_request.id,v_decision.id,
      v_request.authorization_request_id,v_request.authorization_decision_id,
      v_decision.selected_backend_binding_id,v_decision.selected_backend_id,
      v_decision.selected_backend_version_id,v_decision.resolved_environment,
      v_decision.resolved_scope_type,v_decision.resolved_scope_key,
      v_decision.resolved_namespace,v_decision.resolved_capability,
      coalesce(p_manifest_metadata,'{}'::jsonb)::text
    ),'sha256'),'hex');

  insert into public.commercial_secret_reference_handoff_manifests(
    manifest_key,handoff_request_id,handoff_decision_id,
    authorization_request_id,authorization_decision_id,
    selected_backend_binding_id,selected_backend_id,selected_backend_version_id,
    environment,scope_type,scope_key,namespace_code,capability_code,
    manifest_status,manifest_hash,manifest_metadata,created_by
  ) values (
    v_key,v_request.id,v_decision.id,
    v_request.authorization_request_id,v_request.authorization_decision_id,
    v_decision.selected_backend_binding_id,v_decision.selected_backend_id,
    v_decision.selected_backend_version_id,
    v_decision.resolved_environment,v_decision.resolved_scope_type,
    v_decision.resolved_scope_key,v_decision.resolved_namespace,
    v_decision.resolved_capability,
    'held',v_hash,coalesce(p_manifest_metadata,'{}'::jsonb),p_created_by
  ) returning * into v_manifest;

  perform public.append_commercial_secret_reference_handoff_receipt(
    'MANIFEST_CREATED',v_request.id,v_decision.id,v_manifest.id,null,
    'held','PASSIVE_HANDOFF_MANIFEST_CREATED',
    'Opaque-reference handoff manifest created and held',
    p_created_by,v_request.correlation_id,
    jsonb_build_object('manifest_hash',v_manifest.manifest_hash)
  );

  perform public.append_commercial_secret_reference_handoff_event(
    'SECRET_REFERENCE_HANDOFF_MANIFEST_CREATED',
    v_request.handoff_policy_id,v_request.id,v_decision.id,v_manifest.id,null,
    'held','Passive handoff manifest created','HANDOFF_ENGINE',
    v_request.correlation_id,v_request.causation_id,
    jsonb_build_object('metadata_only',true,'executable',false)
  );

  return v_manifest;
end
$$;

-- =============================================================================
-- 12. RECORD BLOCKED EXECUTION ATTEMPT
-- =============================================================================

create function public.record_blocked_secret_reference_handoff_attempt(
  p_handoff_request_id uuid,
  p_attempt_type text,
  p_attempted_by text,
  p_attempt_metadata jsonb default '{}'::jsonb
)
returns public.commercial_secret_reference_handoff_attempts
language plpgsql
security definer
set search_path=public,extensions,pg_temp
as $$
declare
  v_request public.commercial_secret_reference_handoff_requests;
  v_decision public.commercial_secret_reference_handoff_decisions;
  v_manifest public.commercial_secret_reference_handoff_manifests;
  v_attempt public.commercial_secret_reference_handoff_attempts;
  v_hash text;
begin
  select * into strict v_request
  from public.commercial_secret_reference_handoff_requests
  where id=p_handoff_request_id;

  select * into v_decision
  from public.commercial_secret_reference_handoff_decisions
  where handoff_request_id=v_request.id;

  select * into v_manifest
  from public.commercial_secret_reference_handoff_manifests
  where handoff_request_id=v_request.id;

  v_hash:=encode(extensions.digest(
    concat_ws('|',v_request.id,v_decision.id,v_manifest.id,upper(p_attempt_type),
      'blocked','PASSIVE_HANDOFF_EXECUTION_FORBIDDEN',p_attempted_by,
      coalesce(p_attempt_metadata,'{}'::jsonb)::text,clock_timestamp()::text
    ),'sha256'),'hex');

  insert into public.commercial_secret_reference_handoff_attempts(
    handoff_request_id,handoff_decision_id,handoff_manifest_id,
    attempt_type,attempt_status,block_code,attempted_by,correlation_id,
    attempt_hash,attempt_metadata
  ) values (
    v_request.id,v_decision.id,v_manifest.id,upper(p_attempt_type),'blocked',
    'PASSIVE_HANDOFF_EXECUTION_FORBIDDEN',p_attempted_by,
    v_request.correlation_id,v_hash,coalesce(p_attempt_metadata,'{}'::jsonb)
  ) returning * into v_attempt;

  perform public.append_commercial_secret_reference_handoff_receipt(
    'EXECUTION_BLOCKED',v_request.id,v_decision.id,v_manifest.id,v_attempt.id,
    'blocked','PASSIVE_HANDOFF_EXECUTION_FORBIDDEN',
    'Active execution is forbidden by passive handoff posture',
    p_attempted_by,v_request.correlation_id,
    jsonb_build_object('attempt_type',v_attempt.attempt_type)
  );

  perform public.append_commercial_secret_reference_handoff_event(
    'SECRET_REFERENCE_HANDOFF_EXECUTION_BLOCKED',
    v_request.handoff_policy_id,v_request.id,v_decision.id,v_manifest.id,v_attempt.id,
    'blocked','Active handoff execution attempt blocked','HANDOFF_ENGINE',
    v_request.correlation_id,v_request.causation_id,
    jsonb_build_object('attempt_type',v_attempt.attempt_type)
  );

  return v_attempt;
end
$$;

-- =============================================================================
-- 13. READ MODEL
-- =============================================================================

create view public.commercial_secret_reference_handoff_read_model
with (security_invoker=true)
as
select
  r.id as handoff_request_id,
  r.request_key,
  r.idempotency_key,
  r.request_status,
  r.authorization_request_id,
  r.authorization_decision_id,
  r.gateway_request_id,
  r.gateway_decision_id,
  r.requested_environment,
  r.requested_scope_type,
  r.requested_scope_key,
  r.requested_namespace,
  r.requested_capability,

  d.id as handoff_decision_id,
  d.decision_status,
  d.decision_code,
  d.accepted,
  d.selected_backend_binding_id,
  d.selected_backend_id,
  d.selected_backend_version_id,

  m.id as handoff_manifest_id,
  m.manifest_key,
  m.manifest_status,
  m.opaque_reference_contract,
  m.metadata_only,
  m.executable,
  m.dispatch_allowed,
  m.activation_allowed,
  m.backend_contact_allowed,
  m.secret_resolution_allowed,
  m.network_access_allowed,

  coalesce(ev.evaluation_count,0) as evaluation_count,
  coalesce(attempts.attempt_count,0) as attempt_count,
  coalesce(rc.receipt_count,0) as receipt_count,
  coalesce(events.event_count,0) as event_count,
  coalesce(i.replay_count,0) as replay_count,

  r.correlation_id,
  r.requested_at,
  r.evaluated_at,
  m.created_at as manifest_created_at
from public.commercial_secret_reference_handoff_requests r
left join public.commercial_secret_reference_handoff_decisions d
  on d.handoff_request_id=r.id
left join public.commercial_secret_reference_handoff_manifests m
  on m.handoff_request_id=r.id
left join public.commercial_secret_reference_handoff_idempotency i
  on i.handoff_request_id=r.id
left join lateral (
  select count(*)::bigint as evaluation_count
  from public.commercial_secret_reference_handoff_evaluations x
  where x.handoff_request_id=r.id
) ev on true
left join lateral (
  select count(*)::bigint as attempt_count
  from public.commercial_secret_reference_handoff_attempts x
  where x.handoff_request_id=r.id
) attempts on true
left join lateral (
  select count(*)::bigint as receipt_count
  from public.commercial_secret_reference_handoff_receipts x
  where x.handoff_request_id=r.id
) rc on true
left join lateral (
  select count(*)::bigint as event_count
  from public.commercial_secret_reference_handoff_events x
  where x.handoff_request_id=r.id
) events on true;

comment on view public.commercial_secret_reference_handoff_read_model is
'Passive authorization-to-resolution handoff read model. No secret material or endpoint data is exposed.';

-- =============================================================================
-- 14. FOUNDATION DATA
-- =============================================================================

insert into public.commercial_secret_reference_handoff_policies(
  policy_code,environment,policy_status,policy_version,
  created_by,approved_by,approved_at,policy_metadata
) values (
  'commercial:secret_reference_resolution_handoff:v1',
  'production','approved',1,
  'MIGRATION_133','MIGRATION_133',clock_timestamp(),
  jsonb_build_object(
    'opaque_references_only',true,
    'metadata_only',true,
    'passive_handoff_only',true,
    'activation_forbidden',true
  )
);

select public.append_commercial_secret_reference_handoff_event(
  'SECRET_REFERENCE_HANDOFF_INITIALIZED',
  p.id,null,null,null,null,'approved',
  'Secret-reference resolution authorization handoff initialized in passive mode',
  'MIGRATION_133',gen_random_uuid(),null,
  jsonb_build_object(
    'automatic_dispatch_enabled',false,
    'activation_enabled',false,
    'endpoint_discovery_enabled',false,
    'backend_contact_enabled',false,
    'secret_lookup_enabled',false,
    'secret_resolution_enabled',false,
    'secret_decryption_enabled',false,
    'credential_material_loading_enabled',false,
    'credential_delivery_enabled',false,
    'network_access_enabled',false
  )
)
from public.commercial_secret_reference_handoff_policies p
where p.policy_code='commercial:secret_reference_resolution_handoff:v1'
  and p.environment='production';

-- =============================================================================
-- 15. RLS AND PRIVILEGES
-- =============================================================================

alter table public.commercial_secret_reference_handoff_policies enable row level security;
alter table public.commercial_secret_reference_handoff_requests enable row level security;
alter table public.commercial_secret_reference_handoff_idempotency enable row level security;
alter table public.commercial_secret_reference_handoff_evaluations enable row level security;
alter table public.commercial_secret_reference_handoff_decisions enable row level security;
alter table public.commercial_secret_reference_handoff_manifests enable row level security;
alter table public.commercial_secret_reference_handoff_attempts enable row level security;
alter table public.commercial_secret_reference_handoff_receipts enable row level security;
alter table public.commercial_secret_reference_handoff_events enable row level security;

revoke all on public.commercial_secret_reference_handoff_policies from public,anon,authenticated;
revoke all on public.commercial_secret_reference_handoff_requests from public,anon,authenticated;
revoke all on public.commercial_secret_reference_handoff_idempotency from public,anon,authenticated;
revoke all on public.commercial_secret_reference_handoff_evaluations from public,anon,authenticated;
revoke all on public.commercial_secret_reference_handoff_decisions from public,anon,authenticated;
revoke all on public.commercial_secret_reference_handoff_manifests from public,anon,authenticated;
revoke all on public.commercial_secret_reference_handoff_attempts from public,anon,authenticated;
revoke all on public.commercial_secret_reference_handoff_receipts from public,anon,authenticated;
revoke all on public.commercial_secret_reference_handoff_events from public,anon,authenticated;
revoke all on public.commercial_secret_reference_handoff_read_model from public,anon,authenticated;

grant select on public.commercial_secret_reference_handoff_policies to service_role;
grant select,insert,update on public.commercial_secret_reference_handoff_requests to service_role;
grant select,insert,update on public.commercial_secret_reference_handoff_idempotency to service_role;
grant select,insert on public.commercial_secret_reference_handoff_evaluations to service_role;
grant select,insert on public.commercial_secret_reference_handoff_decisions to service_role;
grant select,insert on public.commercial_secret_reference_handoff_manifests to service_role;
grant select,insert on public.commercial_secret_reference_handoff_attempts to service_role;
grant select,insert on public.commercial_secret_reference_handoff_receipts to service_role;
grant select,insert on public.commercial_secret_reference_handoff_events to service_role;
grant select on public.commercial_secret_reference_handoff_read_model to service_role;

revoke all on function public.append_commercial_secret_reference_handoff_receipt(
  text,uuid,uuid,uuid,uuid,text,text,text,text,uuid,jsonb
) from public,anon,authenticated;
revoke all on function public.append_commercial_secret_reference_handoff_event(
  text,uuid,uuid,uuid,uuid,uuid,text,text,text,uuid,uuid,jsonb
) from public,anon,authenticated;
revoke all on function public.enqueue_commercial_secret_reference_handoff_request(
  text,text,uuid,uuid,text,text,text,text,text,text,uuid,uuid,jsonb
) from public,anon,authenticated;
revoke all on function public.evaluate_commercial_secret_reference_handoff_request(
  uuid,text
) from public,anon,authenticated;
revoke all on function public.build_commercial_secret_reference_handoff_manifest(
  uuid,text,jsonb
) from public,anon,authenticated;
revoke all on function public.record_blocked_secret_reference_handoff_attempt(
  uuid,text,text,jsonb
) from public,anon,authenticated;

grant execute on function public.append_commercial_secret_reference_handoff_receipt(
  text,uuid,uuid,uuid,uuid,text,text,text,text,uuid,jsonb
) to service_role;
grant execute on function public.append_commercial_secret_reference_handoff_event(
  text,uuid,uuid,uuid,uuid,uuid,text,text,text,uuid,uuid,jsonb
) to service_role;
grant execute on function public.enqueue_commercial_secret_reference_handoff_request(
  text,text,uuid,uuid,text,text,text,text,text,text,uuid,uuid,jsonb
) to service_role;
grant execute on function public.evaluate_commercial_secret_reference_handoff_request(
  uuid,text
) to service_role;
grant execute on function public.build_commercial_secret_reference_handoff_manifest(
  uuid,text,jsonb
) to service_role;
grant execute on function public.record_blocked_secret_reference_handoff_attempt(
  uuid,text,text,jsonb
) to service_role;

-- =============================================================================
-- 16. FOUNDATION CERTIFICATION
-- =============================================================================

do $$
declare
  v_policy public.commercial_secret_reference_handoff_policies;
  v_policy_count bigint;
  v_request_count bigint;
  v_idempotency_count bigint;
  v_evaluation_count bigint;
  v_decision_count bigint;
  v_manifest_count bigint;
  v_attempt_count bigint;
  v_receipt_count bigint;
  v_event_count bigint;
begin
  select * into strict v_policy
  from public.commercial_secret_reference_handoff_policies
  where policy_code='commercial:secret_reference_resolution_handoff:v1'
    and environment='production'
    and policy_status='approved';

  select count(*) into v_policy_count
  from public.commercial_secret_reference_handoff_policies
  where policy_code='commercial:secret_reference_resolution_handoff:v1'
    and environment='production';

  select count(*) into v_request_count
  from public.commercial_secret_reference_handoff_requests;

  select count(*) into v_idempotency_count
  from public.commercial_secret_reference_handoff_idempotency;

  select count(*) into v_evaluation_count
  from public.commercial_secret_reference_handoff_evaluations;

  select count(*) into v_decision_count
  from public.commercial_secret_reference_handoff_decisions;

  select count(*) into v_manifest_count
  from public.commercial_secret_reference_handoff_manifests;

  select count(*) into v_attempt_count
  from public.commercial_secret_reference_handoff_attempts;

  select count(*) into v_receipt_count
  from public.commercial_secret_reference_handoff_receipts;

  select count(*) into v_event_count
  from public.commercial_secret_reference_handoff_events;

  if v_policy_count<>1
     or v_request_count<>0
     or v_idempotency_count<>0
     or v_evaluation_count<>0
     or v_decision_count<>0
     or v_manifest_count<>0
     or v_attempt_count<>0
     or v_receipt_count<>0
     or v_event_count<>1 then
    raise exception
      'MIGRATION_133_COUNT_ASSERTION_FAILED policy=%, request=%, idempotency=%, evaluation=%, decision=%, manifest=%, attempt=%, receipt=%, event=%',
      v_policy_count,v_request_count,v_idempotency_count,v_evaluation_count,
      v_decision_count,v_manifest_count,v_attempt_count,v_receipt_count,v_event_count;
  end if;

  if not (
    v_policy.intake_enabled
    and v_policy.authorization_verification_enabled
    and v_policy.route_integrity_verification_enabled
    and v_policy.scope_integrity_verification_enabled
    and v_policy.capability_integrity_verification_enabled
    and v_policy.backend_binding_integrity_enabled
    and v_policy.manifest_generation_enabled
    and v_policy.decision_recording_enabled
  ) then
    raise exception 'MIGRATION_133_CAPABILITY_MATRIX_FAILED';
  end if;

  if v_policy.automatic_dispatch_enabled
     or v_policy.activation_enabled
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
    raise exception 'MIGRATION_133_PASSIVE_POSTURE_FAILED';
  end if;

  raise notice
    'MIGRATION_133_CERTIFIED policy_count=%, request_count=%, idempotency_count=%, evaluation_count=%, decision_count=%, manifest_count=%, attempt_count=%, receipt_count=%, event_count=%, intake_enabled=%, authorization_verification_enabled=%, route_integrity_verification_enabled=%, scope_integrity_verification_enabled=%, capability_integrity_verification_enabled=%, backend_binding_integrity_enabled=%, manifest_generation_enabled=%, decision_recording_enabled=%, automatic_dispatch_enabled=%, activation_enabled=%, endpoint_discovery_enabled=%, backend_probe_enabled=%, backend_contact_enabled=%, backend_authentication_enabled=%, secret_lookup_enabled=%, secret_resolution_enabled=%, secret_decryption_enabled=%, credential_material_loading_enabled=%, credential_delivery_enabled=%, network_access_enabled=%, opaque_references_only=true, metadata_only=true, executable=false',
    v_policy_count,v_request_count,v_idempotency_count,v_evaluation_count,
    v_decision_count,v_manifest_count,v_attempt_count,v_receipt_count,v_event_count,
    v_policy.intake_enabled,v_policy.authorization_verification_enabled,
    v_policy.route_integrity_verification_enabled,
    v_policy.scope_integrity_verification_enabled,
    v_policy.capability_integrity_verification_enabled,
    v_policy.backend_binding_integrity_enabled,v_policy.manifest_generation_enabled,
    v_policy.decision_recording_enabled,v_policy.automatic_dispatch_enabled,
    v_policy.activation_enabled,v_policy.endpoint_discovery_enabled,
    v_policy.backend_probe_enabled,v_policy.backend_contact_enabled,
    v_policy.backend_authentication_enabled,v_policy.secret_lookup_enabled,
    v_policy.secret_resolution_enabled,v_policy.secret_decryption_enabled,
    v_policy.credential_material_loading_enabled,
    v_policy.credential_delivery_enabled,v_policy.network_access_enabled;
end
$$;

commit;
