-- =============================================================================
-- FANTAGOL
-- Migration: 122_commercial_provider_credential_vault_governance_foundation.sql
-- Milestone: Commercial Platform - Provider Credential Vault Governance
--
-- Purpose:
--   Introduce provider-credential governance without storing or resolving real
--   credential material.
--
-- Foundation safety posture:
--   - only external secret references and non-reversible fingerprints are stored;
--   - plaintext secrets are structurally forbidden;
--   - credential versions are immutable after approval;
--   - provider / adapter bindings are governed and auditable;
--   - access requests can be evaluated only into a passive held state;
--   - decryption, secret retrieval and credential delivery remain disabled;
--   - no provider network call can be initiated by this migration.
-- =============================================================================

\set ON_ERROR_STOP on

begin;

create extension if not exists pgcrypto with schema extensions;

do $$
begin
  if to_regclass('public.commercial_providers') is null
     or to_regclass('public.commercial_provider_adapter_bindings') is null
     or to_regclass('public.commercial_provider_execution_commands') is null then
    raise exception 'MIGRATION_122_REQUIRES_MIGRATIONS_110_117_120';
  end if;
end
$$;

-- =============================================================================
-- 1. CREDENTIAL GOVERNANCE POLICIES
-- =============================================================================

create table public.commercial_provider_credential_policies (
  id uuid primary key default gen_random_uuid(),
  policy_code text not null,
  version_number integer not null,
  policy_status text not null default 'draft',
  environment text not null default 'test',

  profile_registration_enabled boolean not null default true,
  version_registration_enabled boolean not null default true,
  binding_governance_enabled boolean not null default true,
  access_request_enabled boolean not null default true,
  policy_evaluation_enabled boolean not null default true,
  rotation_governance_enabled boolean not null default true,

  secret_resolution_enabled boolean not null default false,
  secret_decryption_enabled boolean not null default false,
  credential_delivery_enabled boolean not null default false,
  automatic_rotation_enabled boolean not null default false,
  network_access_enabled boolean not null default false,

  maximum_active_versions integer not null default 2,
  maximum_access_ttl_seconds integer not null default 300,
  rotation_warning_days integer not null default 30,
  rotation_required_days integer not null default 90,

  configuration jsonb not null default '{}'::jsonb,
  content_hash text not null,
  created_by text not null,
  approved_by text,
  approved_at timestamptz,
  retired_at timestamptz,
  created_at timestamptz not null default clock_timestamp(),

  constraint comm_provider_credential_policies_unique
    unique (policy_code, version_number, environment),

  constraint comm_provider_credential_policies_code_check
    check (
      policy_code = upper(policy_code)
      and policy_code ~ '^[A-Z][A-Z0-9_]{2,95}$'
    ),

  constraint comm_provider_credential_policies_version_check
    check (version_number > 0),

  constraint comm_provider_credential_policies_status_check
    check (policy_status in ('draft','approved','retired')),

  constraint comm_provider_credential_policies_environment_check
    check (environment in ('test','production')),

  constraint comm_provider_credential_policies_limits_check
    check (
      maximum_active_versions between 1 and 10
      and maximum_access_ttl_seconds between 30 and 3600
      and rotation_warning_days between 1 and 365
      and rotation_required_days between rotation_warning_days and 730
    ),

  constraint comm_provider_credential_policies_json_check
    check (
      jsonb_typeof(configuration) = 'object'
      and not (configuration ?| array[
        'secret',
        'secret_value',
        'password',
        'private_key',
        'access_token',
        'refresh_token',
        'api_key',
        'client_secret'
      ])
    ),

  constraint comm_provider_credential_policies_hash_check
    check (content_hash ~ '^[a-f0-9]{64}$'),

  constraint comm_provider_credential_policies_actor_check
    check (length(btrim(created_by)) between 1 and 160),

  constraint comm_provider_credential_policies_approval_check
    check (
      (policy_status = 'draft' and approved_at is null and approved_by is null)
      or
      (policy_status <> 'draft' and approved_at is not null and approved_by is not null)
    ),

  constraint comm_provider_credential_policies_foundation_hold_check
    check (
      secret_resolution_enabled = false
      and secret_decryption_enabled = false
      and credential_delivery_enabled = false
      and automatic_rotation_enabled = false
      and network_access_enabled = false
    )
);

create unique index comm_provider_credential_policies_one_approved_idx
  on public.commercial_provider_credential_policies(policy_code, environment)
  where policy_status = 'approved';

comment on table public.commercial_provider_credential_policies is
'Versioned credential-vault governance. Migration 122 structurally disables secret resolution, decryption, delivery, automatic rotation and network access.';

-- =============================================================================
-- 2. CREDENTIAL PROFILES
-- =============================================================================

create table public.commercial_provider_credential_profiles (
  id uuid primary key default gen_random_uuid(),
  credential_key text not null unique,
  display_name text not null,
  credential_type text not null,
  environment text not null default 'test',
  profile_status text not null default 'draft',

  owner_scope text not null default 'provider',
  provider_id uuid,
  adapter_binding_id uuid,

  required_scopes text[] not null default '{}'::text[],
  permitted_operations text[] not null default '{}'::text[],
  metadata jsonb not null default '{}'::jsonb,

  created_by text not null,
  approved_by text,
  approved_at timestamptz,
  retired_at timestamptz,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),

  constraint comm_provider_credential_profiles_provider_fkey
    foreign key (provider_id)
    references public.commercial_providers(id)
    on delete restrict,

  constraint comm_provider_credential_profiles_binding_fkey
    foreign key (adapter_binding_id)
    references public.commercial_provider_adapter_bindings(id)
    on delete restrict,

  constraint comm_provider_credential_profiles_key_check
    check (
      credential_key = lower(credential_key)
      and credential_key ~ '^[a-z][a-z0-9:_-]{7,159}$'
    ),

  constraint comm_provider_credential_profiles_name_check
    check (length(btrim(display_name)) between 3 and 160),

  constraint comm_provider_credential_profiles_type_check
    check (credential_type in (
      'api_key',
      'bearer_token',
      'basic_auth',
      'oauth_client',
      'signing_key',
      'webhook_secret',
      'certificate_reference',
      'generic_reference'
    )),

  constraint comm_provider_credential_profiles_environment_check
    check (environment in ('test','production')),

  constraint comm_provider_credential_profiles_status_check
    check (profile_status in ('draft','approved','suspended','retired')),

  constraint comm_provider_credential_profiles_owner_scope_check
    check (owner_scope in ('platform','provider','adapter_binding')),

  constraint comm_provider_credential_profiles_owner_consistency_check
    check (
      (owner_scope = 'platform' and provider_id is null and adapter_binding_id is null)
      or
      (owner_scope = 'provider' and provider_id is not null and adapter_binding_id is null)
      or
      (owner_scope = 'adapter_binding' and provider_id is not null and adapter_binding_id is not null)
    ),

  constraint comm_provider_credential_profiles_scopes_check
    check (
      cardinality(required_scopes) <= 64
      and cardinality(permitted_operations) <= 64
    ),

  constraint comm_provider_credential_profiles_json_check
    check (
      jsonb_typeof(metadata) = 'object'
      and not (metadata ?| array[
        'secret',
        'secret_value',
        'password',
        'private_key',
        'access_token',
        'refresh_token',
        'api_key',
        'client_secret'
      ])
    ),

  constraint comm_provider_credential_profiles_actor_check
    check (length(btrim(created_by)) between 1 and 160),

  constraint comm_provider_credential_profiles_approval_check
    check (
      (profile_status = 'draft' and approved_at is null and approved_by is null)
      or
      (profile_status <> 'draft' and approved_at is not null and approved_by is not null)
    )
);

create index comm_provider_credential_profiles_provider_idx
  on public.commercial_provider_credential_profiles(provider_id, profile_status);

create index comm_provider_credential_profiles_binding_idx
  on public.commercial_provider_credential_profiles(adapter_binding_id, profile_status);

comment on table public.commercial_provider_credential_profiles is
'Credential identities and scope declarations. No secret material is stored.';

-- =============================================================================
-- 3. IMMUTABLE CREDENTIAL VERSIONS
-- =============================================================================

create table public.commercial_provider_credential_versions (
  id uuid primary key default gen_random_uuid(),
  credential_profile_id uuid not null,
  version_number integer not null,
  version_status text not null default 'draft',

  secret_backend text not null,
  secret_reference text not null,
  secret_reference_hash text not null,
  material_fingerprint text not null,

  valid_from timestamptz not null default clock_timestamp(),
  expires_at timestamptz,
  rotation_due_at timestamptz,
  superseded_by_version_id uuid,

  access_scope text[] not null default '{}'::text[],
  reference_metadata jsonb not null default '{}'::jsonb,
  content_hash text not null,

  created_by text not null,
  approved_by text,
  approved_at timestamptz,
  revoked_by text,
  revoked_at timestamptz,
  revocation_reason text,
  created_at timestamptz not null default clock_timestamp(),

  constraint comm_provider_credential_versions_profile_fkey
    foreign key (credential_profile_id)
    references public.commercial_provider_credential_profiles(id)
    on delete restrict,

  constraint comm_provider_credential_versions_superseded_fkey
    foreign key (superseded_by_version_id)
    references public.commercial_provider_credential_versions(id)
    on delete restrict,

  constraint comm_provider_credential_versions_unique
    unique (credential_profile_id, version_number),

  constraint comm_provider_credential_versions_number_check
    check (version_number > 0),

  constraint comm_provider_credential_versions_status_check
    check (version_status in ('draft','approved','active','superseded','revoked','expired')),

  constraint comm_provider_credential_versions_backend_check
    check (secret_backend in (
      'supabase_vault',
      'aws_secrets_manager',
      'gcp_secret_manager',
      'azure_key_vault',
      'hashicorp_vault',
      'external_reference'
    )),

  constraint comm_provider_credential_versions_reference_check
    check (
      length(btrim(secret_reference)) between 8 and 500
      and secret_reference !~ E'[\\r\\n]'
      and secret_reference !~* '(password|private[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret)='
    ),

  constraint comm_provider_credential_versions_reference_hash_check
    check (
      secret_reference_hash ~ '^[a-f0-9]{64}$'
      and material_fingerprint ~ '^[a-f0-9]{64}$'
      and content_hash ~ '^[a-f0-9]{64}$'
    ),

  constraint comm_provider_credential_versions_validity_check
    check (
      expires_at is null or expires_at > valid_from
    ),

  constraint comm_provider_credential_versions_rotation_check
    check (
      rotation_due_at is null or rotation_due_at > valid_from
    ),

  constraint comm_provider_credential_versions_scope_check
    check (cardinality(access_scope) <= 64),

  constraint comm_provider_credential_versions_json_check
    check (
      jsonb_typeof(reference_metadata) = 'object'
      and not (reference_metadata ?| array[
        'secret',
        'secret_value',
        'password',
        'private_key',
        'access_token',
        'refresh_token',
        'api_key',
        'client_secret',
        'plaintext',
        'ciphertext'
      ])
    ),

  constraint comm_provider_credential_versions_actor_check
    check (length(btrim(created_by)) between 1 and 160),

  constraint comm_provider_credential_versions_approval_check
    check (
      (version_status = 'draft' and approved_at is null and approved_by is null)
      or
      (version_status <> 'draft' and approved_at is not null and approved_by is not null)
    ),

  constraint comm_provider_credential_versions_revocation_check
    check (
      (version_status = 'revoked' and revoked_at is not null and revoked_by is not null)
      or
      (version_status <> 'revoked')
    )
);

create unique index comm_provider_credential_versions_one_active_idx
  on public.commercial_provider_credential_versions(credential_profile_id)
  where version_status = 'active';

create index comm_provider_credential_versions_rotation_idx
  on public.commercial_provider_credential_versions
  (version_status, rotation_due_at, expires_at);

comment on table public.commercial_provider_credential_versions is
'Immutable references to externally stored credential material. The table never stores plaintext or encrypted secret material.';

-- =============================================================================
-- 4. CREDENTIAL BINDINGS
-- =============================================================================

create table public.commercial_provider_credential_bindings (
  id uuid primary key default gen_random_uuid(),
  credential_profile_id uuid not null,
  credential_version_id uuid not null,
  provider_id uuid not null,
  adapter_binding_id uuid,
  credential_policy_id uuid not null,

  binding_key text not null unique,
  binding_status text not null default 'draft',
  readiness_status text not null default 'pending',

  required_scopes text[] not null default '{}'::text[],
  permitted_operations text[] not null default '{}'::text[],
  readiness_report jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,

  created_by text not null,
  validated_by text,
  validated_at timestamptz,
  suspended_at timestamptz,
  retired_at timestamptz,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),

  constraint comm_provider_credential_bindings_profile_fkey
    foreign key (credential_profile_id)
    references public.commercial_provider_credential_profiles(id)
    on delete restrict,

  constraint comm_provider_credential_bindings_version_fkey
    foreign key (credential_version_id)
    references public.commercial_provider_credential_versions(id)
    on delete restrict,

  constraint comm_provider_credential_bindings_provider_fkey
    foreign key (provider_id)
    references public.commercial_providers(id)
    on delete restrict,

  constraint comm_provider_credential_bindings_adapter_fkey
    foreign key (adapter_binding_id)
    references public.commercial_provider_adapter_bindings(id)
    on delete restrict,

  constraint comm_provider_credential_bindings_policy_fkey
    foreign key (credential_policy_id)
    references public.commercial_provider_credential_policies(id)
    on delete restrict,

  constraint comm_provider_credential_bindings_key_check
    check (
      binding_key = lower(binding_key)
      and binding_key ~ '^[a-z][a-z0-9:_-]{7,159}$'
    ),

  constraint comm_provider_credential_bindings_status_check
    check (binding_status in ('draft','validated','suspended','retired')),

  constraint comm_provider_credential_bindings_readiness_check
    check (readiness_status in ('pending','ready','held','blocked')),

  constraint comm_provider_credential_bindings_scope_check
    check (
      cardinality(required_scopes) <= 64
      and cardinality(permitted_operations) <= 64
    ),

  constraint comm_provider_credential_bindings_json_check
    check (
      jsonb_typeof(readiness_report) = 'object'
      and jsonb_typeof(metadata) = 'object'
      and not (readiness_report ?| array[
        'secret',
        'secret_value',
        'password',
        'private_key',
        'access_token',
        'refresh_token',
        'api_key',
        'client_secret'
      ])
      and not (metadata ?| array[
        'secret',
        'secret_value',
        'password',
        'private_key',
        'access_token',
        'refresh_token',
        'api_key',
        'client_secret'
      ])
    ),

  constraint comm_provider_credential_bindings_actor_check
    check (length(btrim(created_by)) between 1 and 160)
);

create unique index comm_provider_credential_bindings_active_unique_idx
  on public.commercial_provider_credential_bindings(
    credential_profile_id,
    provider_id,
    coalesce(adapter_binding_id, '00000000-0000-0000-0000-000000000000'::uuid)
  )
  where binding_status in ('draft','validated');

comment on table public.commercial_provider_credential_bindings is
'Governed association between credential references, providers and optional adapter bindings.';

-- =============================================================================
-- 5. ACCESS REQUESTS
-- =============================================================================

create table public.commercial_provider_credential_access_requests (
  id uuid primary key default gen_random_uuid(),
  request_key text not null unique,
  idempotency_key text not null unique,

  credential_binding_id uuid not null,
  execution_command_id uuid,
  credential_policy_id uuid not null,

  request_status text not null default 'received',
  requested_scopes text[] not null default '{}'::text[],
  requested_operation text,
  requested_ttl_seconds integer not null default 300,

  correlation_id uuid not null default gen_random_uuid(),
  causation_id uuid,
  requested_by text not null,
  requested_at timestamptz not null default clock_timestamp(),
  evaluated_at timestamptz,
  held_at timestamptz,
  completed_at timestamptz,

  terminal_reason text,
  request_metadata jsonb not null default '{}'::jsonb,
  request_hash text not null,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),

  constraint comm_provider_credential_requests_binding_fkey
    foreign key (credential_binding_id)
    references public.commercial_provider_credential_bindings(id)
    on delete restrict,

  constraint comm_provider_credential_requests_command_fkey
    foreign key (execution_command_id)
    references public.commercial_provider_execution_commands(id)
    on delete restrict,

  constraint comm_provider_credential_requests_policy_fkey
    foreign key (credential_policy_id)
    references public.commercial_provider_credential_policies(id)
    on delete restrict,

  constraint comm_provider_credential_requests_key_check
    check (
      request_key = lower(request_key)
      and request_key ~ '^[a-z][a-z0-9:_-]{7,159}$'
      and length(idempotency_key) between 8 and 240
    ),

  constraint comm_provider_credential_requests_status_check
    check (request_status in (
      'received',
      'evaluated',
      'held',
      'approved',
      'resolving',
      'resolved',
      'delivered',
      'failed',
      'cancelled'
    )),

  constraint comm_provider_credential_requests_scope_check
    check (cardinality(requested_scopes) <= 64),

  constraint comm_provider_credential_requests_ttl_check
    check (requested_ttl_seconds between 30 and 3600),

  constraint comm_provider_credential_requests_json_check
    check (
      jsonb_typeof(request_metadata) = 'object'
      and not (request_metadata ?| array[
        'secret',
        'secret_value',
        'password',
        'private_key',
        'access_token',
        'refresh_token',
        'api_key',
        'client_secret',
        'plaintext',
        'ciphertext'
      ])
      and request_hash ~ '^[a-f0-9]{64}$'
    ),

  constraint comm_provider_credential_requests_actor_check
    check (length(btrim(requested_by)) between 1 and 160),

  constraint comm_provider_credential_requests_foundation_hold_check
    check (request_status in ('received','evaluated','held','cancelled'))
);

create index comm_provider_credential_requests_queue_idx
  on public.commercial_provider_credential_access_requests
  (request_status, requested_at, id);

create index comm_provider_credential_requests_binding_idx
  on public.commercial_provider_credential_access_requests
  (credential_binding_id, requested_at desc);

comment on table public.commercial_provider_credential_access_requests is
'Credential access intent. Migration 122 permits evaluation and hold only; approval, resolution and delivery are structurally blocked.';

-- =============================================================================
-- 6. RESOLUTION ATTEMPTS
-- =============================================================================

create table public.commercial_provider_credential_resolution_attempts (
  id uuid primary key default gen_random_uuid(),
  access_request_id uuid not null,
  attempt_number integer not null,
  attempt_status text not null default 'planned',

  backend_contact_requested boolean not null default false,
  backend_contact_performed boolean not null default false,
  decryption_requested boolean not null default false,
  decryption_performed boolean not null default false,
  credential_material_loaded boolean not null default false,
  credential_material_delivered boolean not null default false,

  normalized_error_code text,
  retry_class text,
  started_at timestamptz,
  finished_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp(),

  constraint comm_provider_credential_resolution_request_fkey
    foreign key (access_request_id)
    references public.commercial_provider_credential_access_requests(id)
    on delete restrict,

  constraint comm_provider_credential_resolution_unique
    unique (access_request_id, attempt_number),

  constraint comm_provider_credential_resolution_number_check
    check (attempt_number > 0),

  constraint comm_provider_credential_resolution_status_check
    check (attempt_status in ('planned','blocked','started','resolved','failed','abandoned')),

  constraint comm_provider_credential_resolution_retry_check
    check (
      retry_class is null
      or retry_class in ('never','immediate','backoff','manual')
    ),

  constraint comm_provider_credential_resolution_json_check
    check (
      jsonb_typeof(metadata) = 'object'
      and not (metadata ?| array[
        'secret',
        'secret_value',
        'password',
        'private_key',
        'access_token',
        'refresh_token',
        'api_key',
        'client_secret',
        'plaintext',
        'ciphertext'
      ])
    ),

  constraint comm_provider_credential_resolution_foundation_hold_check
    check (
      attempt_status in ('planned','blocked','abandoned')
      and backend_contact_requested = false
      and backend_contact_performed = false
      and decryption_requested = false
      and decryption_performed = false
      and credential_material_loaded = false
      and credential_material_delivered = false
      and started_at is null
    )
);

comment on table public.commercial_provider_credential_resolution_attempts is
'Passive credential-resolution audit records. Migration 122 cannot contact a secret backend, decrypt, load or deliver credential material.';

-- =============================================================================
-- 7. APPEND-ONLY DECISION RECEIPTS
-- =============================================================================

create table public.commercial_provider_credential_receipts (
  id uuid primary key default gen_random_uuid(),
  access_request_id uuid not null,
  resolution_attempt_id uuid,
  receipt_type text not null,
  receipt_status text not null,

  normalized_payload jsonb not null default '{}'::jsonb,
  content_hash text not null,
  issued_by text not null,
  issued_at timestamptz not null default clock_timestamp(),
  correlation_id uuid not null,
  metadata jsonb not null default '{}'::jsonb,

  constraint comm_provider_credential_receipts_request_fkey
    foreign key (access_request_id)
    references public.commercial_provider_credential_access_requests(id)
    on delete restrict,

  constraint comm_provider_credential_receipts_attempt_fkey
    foreign key (resolution_attempt_id)
    references public.commercial_provider_credential_resolution_attempts(id)
    on delete restrict,

  constraint comm_provider_credential_receipts_type_check
    check (receipt_type in (
      'policy_decision',
      'scope_decision',
      'rotation_decision',
      'resolution_blocked',
      'resolution_result',
      'delivery_receipt'
    )),

  constraint comm_provider_credential_receipts_status_check
    check (receipt_status in ('accepted','held','blocked','resolved','delivered','failed')),

  constraint comm_provider_credential_receipts_json_check
    check (
      jsonb_typeof(normalized_payload) = 'object'
      and jsonb_typeof(metadata) = 'object'
      and not (normalized_payload ?| array[
        'secret',
        'secret_value',
        'password',
        'private_key',
        'access_token',
        'refresh_token',
        'api_key',
        'client_secret',
        'plaintext',
        'ciphertext'
      ])
      and not (metadata ?| array[
        'secret',
        'secret_value',
        'password',
        'private_key',
        'access_token',
        'refresh_token',
        'api_key',
        'client_secret',
        'plaintext',
        'ciphertext'
      ])
    ),

  constraint comm_provider_credential_receipts_hash_check
    check (content_hash ~ '^[a-f0-9]{64}$'),

  constraint comm_provider_credential_receipts_actor_check
    check (length(btrim(issued_by)) between 1 and 160),

  constraint comm_provider_credential_receipts_foundation_hold_check
    check (
      receipt_type not in ('resolution_result','delivery_receipt')
      and receipt_status in ('accepted','held','blocked')
    )
);

create index comm_provider_credential_receipts_timeline_idx
  on public.commercial_provider_credential_receipts
  (access_request_id, issued_at, id);

comment on table public.commercial_provider_credential_receipts is
'Append-only credential governance evidence. Resolution and delivery receipts are disabled in migration 122.';

-- =============================================================================
-- 8. APPEND-ONLY EVENTS
-- =============================================================================

create table public.commercial_provider_credential_events (
  id uuid primary key default gen_random_uuid(),
  event_type text not null,

  credential_policy_id uuid,
  credential_profile_id uuid,
  credential_version_id uuid,
  credential_binding_id uuid,
  access_request_id uuid,
  resolution_attempt_id uuid,
  receipt_id uuid,

  previous_status text,
  new_status text,
  reason text,
  actor text not null,
  correlation_id uuid not null,
  causation_id uuid,
  payload jsonb not null default '{}'::jsonb,
  occurred_at timestamptz not null default clock_timestamp(),

  constraint comm_provider_credential_events_policy_fkey
    foreign key (credential_policy_id)
    references public.commercial_provider_credential_policies(id)
    on delete restrict,

  constraint comm_provider_credential_events_profile_fkey
    foreign key (credential_profile_id)
    references public.commercial_provider_credential_profiles(id)
    on delete restrict,

  constraint comm_provider_credential_events_version_fkey
    foreign key (credential_version_id)
    references public.commercial_provider_credential_versions(id)
    on delete restrict,

  constraint comm_provider_credential_events_binding_fkey
    foreign key (credential_binding_id)
    references public.commercial_provider_credential_bindings(id)
    on delete restrict,

  constraint comm_provider_credential_events_request_fkey
    foreign key (access_request_id)
    references public.commercial_provider_credential_access_requests(id)
    on delete restrict,

  constraint comm_provider_credential_events_attempt_fkey
    foreign key (resolution_attempt_id)
    references public.commercial_provider_credential_resolution_attempts(id)
    on delete restrict,

  constraint comm_provider_credential_events_receipt_fkey
    foreign key (receipt_id)
    references public.commercial_provider_credential_receipts(id)
    on delete restrict,

  constraint comm_provider_credential_events_type_check
    check (
      event_type = upper(event_type)
      and event_type ~ '^[A-Z][A-Z0-9_]{2,95}$'
    ),

  constraint comm_provider_credential_events_actor_check
    check (length(btrim(actor)) between 1 and 160),

  constraint comm_provider_credential_events_payload_check
    check (
      jsonb_typeof(payload) = 'object'
      and not (payload ?| array[
        'secret',
        'secret_value',
        'password',
        'private_key',
        'access_token',
        'refresh_token',
        'api_key',
        'client_secret',
        'plaintext',
        'ciphertext'
      ])
    )
);

create index comm_provider_credential_events_timeline_idx
  on public.commercial_provider_credential_events
  (
    coalesce(access_request_id, '00000000-0000-0000-0000-000000000000'::uuid),
    occurred_at,
    id
  );

comment on table public.commercial_provider_credential_events is
'Append-only credential governance timeline. Payloads cannot contain recognized secret-material keys.';

-- =============================================================================
-- 9. PROTECTION AND UPDATED-AT FUNCTIONS
-- =============================================================================

create or replace function public.protect_commercial_provider_credential_policy_internal()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if old.policy_status in ('approved','retired') then
    raise exception using
      errcode = '55000',
      message = 'COMMERCIAL_PROVIDER_CREDENTIAL_POLICY_IMMUTABLE';
  end if;

  return new;
end
$$;

create or replace function public.protect_commercial_provider_credential_profile_internal()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if old.profile_status in ('approved','retired') then
    raise exception using
      errcode = '55000',
      message = 'COMMERCIAL_PROVIDER_CREDENTIAL_PROFILE_IMMUTABLE';
  end if;

  return new;
end
$$;

create or replace function public.protect_commercial_provider_credential_version_internal()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if old.version_status in ('approved','active','superseded','revoked','expired') then
    raise exception using
      errcode = '55000',
      message = 'COMMERCIAL_PROVIDER_CREDENTIAL_VERSION_IMMUTABLE';
  end if;

  return new;
end
$$;

create or replace function public.protect_commercial_provider_credential_receipt_internal()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  raise exception using
    errcode = '55000',
    message = 'COMMERCIAL_PROVIDER_CREDENTIAL_RECEIPT_APPEND_ONLY';
end
$$;

create or replace function public.protect_commercial_provider_credential_event_internal()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  raise exception using
    errcode = '55000',
    message = 'COMMERCIAL_PROVIDER_CREDENTIAL_EVENT_APPEND_ONLY';
end
$$;

create or replace function public.set_commercial_provider_credential_updated_at_internal()
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

create trigger commercial_provider_credential_policies_protect
before update or delete on public.commercial_provider_credential_policies
for each row execute function public.protect_commercial_provider_credential_policy_internal();

create trigger commercial_provider_credential_profiles_protect
before update or delete on public.commercial_provider_credential_profiles
for each row execute function public.protect_commercial_provider_credential_profile_internal();

create trigger commercial_provider_credential_versions_protect
before update or delete on public.commercial_provider_credential_versions
for each row execute function public.protect_commercial_provider_credential_version_internal();

create trigger commercial_provider_credential_receipts_protect
before update or delete on public.commercial_provider_credential_receipts
for each row execute function public.protect_commercial_provider_credential_receipt_internal();

create trigger commercial_provider_credential_events_protect
before update or delete on public.commercial_provider_credential_events
for each row execute function public.protect_commercial_provider_credential_event_internal();

create trigger commercial_provider_credential_profiles_set_updated_at
before update on public.commercial_provider_credential_profiles
for each row execute function public.set_commercial_provider_credential_updated_at_internal();

create trigger commercial_provider_credential_bindings_set_updated_at
before update on public.commercial_provider_credential_bindings
for each row execute function public.set_commercial_provider_credential_updated_at_internal();

create trigger commercial_provider_credential_requests_set_updated_at
before update on public.commercial_provider_credential_access_requests
for each row execute function public.set_commercial_provider_credential_updated_at_internal();

-- =============================================================================
-- 10. EVENT APPEND
-- =============================================================================

create or replace function public.append_commercial_provider_credential_event_internal(
  p_event_type text,
  p_actor text,
  p_correlation_id uuid,
  p_credential_policy_id uuid default null,
  p_credential_profile_id uuid default null,
  p_credential_version_id uuid default null,
  p_credential_binding_id uuid default null,
  p_access_request_id uuid default null,
  p_resolution_attempt_id uuid default null,
  p_receipt_id uuid default null,
  p_previous_status text default null,
  p_new_status text default null,
  p_reason text default null,
  p_causation_id uuid default null,
  p_payload jsonb default '{}'::jsonb
)
returns public.commercial_provider_credential_events
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_result public.commercial_provider_credential_events;
begin
  insert into public.commercial_provider_credential_events (
    event_type,
    credential_policy_id,
    credential_profile_id,
    credential_version_id,
    credential_binding_id,
    access_request_id,
    resolution_attempt_id,
    receipt_id,
    previous_status,
    new_status,
    reason,
    actor,
    correlation_id,
    causation_id,
    payload
  ) values (
    upper(btrim(p_event_type)),
    p_credential_policy_id,
    p_credential_profile_id,
    p_credential_version_id,
    p_credential_binding_id,
    p_access_request_id,
    p_resolution_attempt_id,
    p_receipt_id,
    p_previous_status,
    p_new_status,
    p_reason,
    btrim(p_actor),
    p_correlation_id,
    p_causation_id,
    coalesce(p_payload, '{}'::jsonb)
  )
  returning * into v_result;

  return v_result;
end
$$;

-- =============================================================================
-- 11. PROFILE REGISTRATION
-- =============================================================================

create or replace function public.register_commercial_provider_credential_profile_internal(
  p_credential_key text,
  p_display_name text,
  p_credential_type text,
  p_environment text,
  p_owner_scope text,
  p_provider_id uuid,
  p_adapter_binding_id uuid,
  p_required_scopes text[],
  p_permitted_operations text[],
  p_created_by text,
  p_metadata jsonb default '{}'::jsonb
)
returns public.commercial_provider_credential_profiles
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_result public.commercial_provider_credential_profiles;
begin
  insert into public.commercial_provider_credential_profiles (
    credential_key,
    display_name,
    credential_type,
    environment,
    profile_status,
    owner_scope,
    provider_id,
    adapter_binding_id,
    required_scopes,
    permitted_operations,
    metadata,
    created_by
  ) values (
    lower(btrim(p_credential_key)),
    btrim(p_display_name),
    lower(btrim(p_credential_type)),
    lower(btrim(p_environment)),
    'draft',
    lower(btrim(p_owner_scope)),
    p_provider_id,
    p_adapter_binding_id,
    coalesce(p_required_scopes, '{}'::text[]),
    coalesce(p_permitted_operations, '{}'::text[]),
    coalesce(p_metadata, '{}'::jsonb),
    btrim(p_created_by)
  )
  returning * into v_result;

  perform public.append_commercial_provider_credential_event_internal(
    'CREDENTIAL_PROFILE_REGISTERED',
    p_created_by,
    gen_random_uuid(),
    null,
    v_result.id,
    null,
    null,
    null,
    null,
    null,
    null,
    'draft',
    'Credential profile registered without secret material',
    null,
    jsonb_build_object(
      'credential_key', v_result.credential_key,
      'credential_type', v_result.credential_type,
      'owner_scope', v_result.owner_scope
    )
  );

  return v_result;
end
$$;

-- =============================================================================
-- 12. VERSION REGISTRATION
-- =============================================================================

create or replace function public.create_commercial_provider_credential_version_internal(
  p_credential_profile_id uuid,
  p_secret_backend text,
  p_secret_reference text,
  p_material_fingerprint text,
  p_valid_from timestamptz,
  p_expires_at timestamptz,
  p_rotation_due_at timestamptz,
  p_access_scope text[],
  p_created_by text,
  p_reference_metadata jsonb default '{}'::jsonb
)
returns public.commercial_provider_credential_versions
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_profile public.commercial_provider_credential_profiles;
  v_next_version integer;
  v_reference_hash text;
  v_content_hash text;
  v_snapshot jsonb;
  v_result public.commercial_provider_credential_versions;
begin
  select *
  into strict v_profile
  from public.commercial_provider_credential_profiles
  where id = p_credential_profile_id;

  if v_profile.profile_status not in ('draft','approved') then
    raise exception 'COMMERCIAL_PROVIDER_CREDENTIAL_PROFILE_NOT_VERSIONABLE';
  end if;

  select coalesce(max(version_number), 0) + 1
  into v_next_version
  from public.commercial_provider_credential_versions
  where credential_profile_id = p_credential_profile_id;

  v_reference_hash :=
    encode(
      extensions.digest(btrim(p_secret_reference), 'sha256'),
      'hex'
    );

  v_snapshot := jsonb_build_object(
    'credential_profile_id', p_credential_profile_id,
    'version_number', v_next_version,
    'secret_backend', lower(btrim(p_secret_backend)),
    'secret_reference_hash', v_reference_hash,
    'material_fingerprint', lower(btrim(p_material_fingerprint)),
    'valid_from', coalesce(p_valid_from, clock_timestamp()),
    'expires_at', p_expires_at,
    'rotation_due_at', p_rotation_due_at,
    'access_scope', coalesce(p_access_scope, '{}'::text[]),
    'reference_metadata', coalesce(p_reference_metadata, '{}'::jsonb)
  );

  v_content_hash :=
    encode(
      extensions.digest(v_snapshot::text, 'sha256'),
      'hex'
    );

  insert into public.commercial_provider_credential_versions (
    credential_profile_id,
    version_number,
    version_status,
    secret_backend,
    secret_reference,
    secret_reference_hash,
    material_fingerprint,
    valid_from,
    expires_at,
    rotation_due_at,
    access_scope,
    reference_metadata,
    content_hash,
    created_by
  ) values (
    p_credential_profile_id,
    v_next_version,
    'draft',
    lower(btrim(p_secret_backend)),
    btrim(p_secret_reference),
    v_reference_hash,
    lower(btrim(p_material_fingerprint)),
    coalesce(p_valid_from, clock_timestamp()),
    p_expires_at,
    p_rotation_due_at,
    coalesce(p_access_scope, '{}'::text[]),
    coalesce(p_reference_metadata, '{}'::jsonb),
    v_content_hash,
    btrim(p_created_by)
  )
  returning * into v_result;

  perform public.append_commercial_provider_credential_event_internal(
    'CREDENTIAL_VERSION_REGISTERED',
    p_created_by,
    gen_random_uuid(),
    null,
    v_result.credential_profile_id,
    v_result.id,
    null,
    null,
    null,
    null,
    null,
    'draft',
    'External credential reference version registered',
    null,
    jsonb_build_object(
      'version_number', v_result.version_number,
      'secret_backend', v_result.secret_backend,
      'secret_reference_hash', v_result.secret_reference_hash,
      'material_fingerprint', v_result.material_fingerprint
    )
  );

  return v_result;
end
$$;

-- =============================================================================
-- 13. PROFILE AND VERSION APPROVAL
-- =============================================================================

create or replace function public.approve_commercial_provider_credential_profile_internal(
  p_credential_profile_id uuid,
  p_approved_by text
)
returns public.commercial_provider_credential_profiles
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_result public.commercial_provider_credential_profiles;
begin
  update public.commercial_provider_credential_profiles
  set
    profile_status = 'approved',
    approved_by = btrim(p_approved_by),
    approved_at = clock_timestamp()
  where id = p_credential_profile_id
    and profile_status = 'draft'
  returning * into v_result;

  if v_result.id is null then
    raise exception 'COMMERCIAL_PROVIDER_CREDENTIAL_PROFILE_NOT_APPROVABLE';
  end if;

  perform public.append_commercial_provider_credential_event_internal(
    'CREDENTIAL_PROFILE_APPROVED',
    p_approved_by,
    gen_random_uuid(),
    null,
    v_result.id,
    null,
    null,
    null,
    null,
    null,
    'draft',
    'approved',
    'Credential profile governance approved',
    null,
    jsonb_build_object('credential_key', v_result.credential_key)
  );

  return v_result;
end
$$;

create or replace function public.approve_commercial_provider_credential_version_internal(
  p_credential_version_id uuid,
  p_approved_by text
)
returns public.commercial_provider_credential_versions
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_result public.commercial_provider_credential_versions;
begin
  update public.commercial_provider_credential_versions
  set
    version_status = 'approved',
    approved_by = btrim(p_approved_by),
    approved_at = clock_timestamp()
  where id = p_credential_version_id
    and version_status = 'draft'
  returning * into v_result;

  if v_result.id is null then
    raise exception 'COMMERCIAL_PROVIDER_CREDENTIAL_VERSION_NOT_APPROVABLE';
  end if;

  perform public.append_commercial_provider_credential_event_internal(
    'CREDENTIAL_VERSION_APPROVED',
    p_approved_by,
    gen_random_uuid(),
    null,
    v_result.credential_profile_id,
    v_result.id,
    null,
    null,
    null,
    null,
    'draft',
    'approved',
    'Credential reference version approved',
    null,
    jsonb_build_object(
      'version_number', v_result.version_number,
      'secret_reference_hash', v_result.secret_reference_hash,
      'material_fingerprint', v_result.material_fingerprint
    )
  );

  return v_result;
end
$$;

-- =============================================================================
-- 14. BINDING CREATION AND PASSIVE VALIDATION
-- =============================================================================

create or replace function public.create_commercial_provider_credential_binding_internal(
  p_credential_profile_id uuid,
  p_credential_version_id uuid,
  p_provider_id uuid,
  p_adapter_binding_id uuid,
  p_credential_policy_id uuid,
  p_binding_key text,
  p_required_scopes text[],
  p_permitted_operations text[],
  p_created_by text,
  p_metadata jsonb default '{}'::jsonb
)
returns public.commercial_provider_credential_bindings
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_profile public.commercial_provider_credential_profiles;
  v_version public.commercial_provider_credential_versions;
  v_policy public.commercial_provider_credential_policies;
  v_result public.commercial_provider_credential_bindings;
begin
  select * into strict v_profile
  from public.commercial_provider_credential_profiles
  where id = p_credential_profile_id;

  select * into strict v_version
  from public.commercial_provider_credential_versions
  where id = p_credential_version_id;

  select * into strict v_policy
  from public.commercial_provider_credential_policies
  where id = p_credential_policy_id;

  if v_profile.profile_status <> 'approved'
     or v_version.version_status <> 'approved'
     or v_version.credential_profile_id <> v_profile.id
     or v_policy.policy_status <> 'approved'
     or v_policy.binding_governance_enabled is not true then
    raise exception 'COMMERCIAL_PROVIDER_CREDENTIAL_BINDING_PREREQUISITES_FAILED';
  end if;

  if v_profile.provider_id is not null
     and v_profile.provider_id <> p_provider_id then
    raise exception 'COMMERCIAL_PROVIDER_CREDENTIAL_BINDING_PROVIDER_MISMATCH';
  end if;

  if v_profile.adapter_binding_id is not null
     and v_profile.adapter_binding_id is distinct from p_adapter_binding_id then
    raise exception 'COMMERCIAL_PROVIDER_CREDENTIAL_BINDING_ADAPTER_MISMATCH';
  end if;

  insert into public.commercial_provider_credential_bindings (
    credential_profile_id,
    credential_version_id,
    provider_id,
    adapter_binding_id,
    credential_policy_id,
    binding_key,
    binding_status,
    readiness_status,
    required_scopes,
    permitted_operations,
    readiness_report,
    metadata,
    created_by
  ) values (
    v_profile.id,
    v_version.id,
    p_provider_id,
    p_adapter_binding_id,
    v_policy.id,
    lower(btrim(p_binding_key)),
    'draft',
    'pending',
    coalesce(p_required_scopes, '{}'::text[]),
    coalesce(p_permitted_operations, '{}'::text[]),
    '{}'::jsonb,
    coalesce(p_metadata, '{}'::jsonb),
    btrim(p_created_by)
  )
  returning * into v_result;

  perform public.append_commercial_provider_credential_event_internal(
    'CREDENTIAL_BINDING_CREATED',
    p_created_by,
    gen_random_uuid(),
    v_result.credential_policy_id,
    v_result.credential_profile_id,
    v_result.credential_version_id,
    v_result.id,
    null,
    null,
    null,
    null,
    'draft',
    'Credential binding registered for passive validation',
    null,
    jsonb_build_object(
      'binding_key', v_result.binding_key,
      'provider_id', v_result.provider_id,
      'adapter_binding_id', v_result.adapter_binding_id
    )
  );

  return v_result;
end
$$;

create or replace function public.evaluate_commercial_provider_credential_binding_internal(
  p_credential_binding_id uuid,
  p_evaluated_by text
)
returns public.commercial_provider_credential_bindings
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_binding public.commercial_provider_credential_bindings;
  v_profile public.commercial_provider_credential_profiles;
  v_version public.commercial_provider_credential_versions;
  v_policy public.commercial_provider_credential_policies;
begin
  select * into strict v_binding
  from public.commercial_provider_credential_bindings
  where id = p_credential_binding_id
  for update;

  select * into strict v_profile
  from public.commercial_provider_credential_profiles
  where id = v_binding.credential_profile_id;

  select * into strict v_version
  from public.commercial_provider_credential_versions
  where id = v_binding.credential_version_id;

  select * into strict v_policy
  from public.commercial_provider_credential_policies
  where id = v_binding.credential_policy_id;

  if v_binding.binding_status <> 'draft'
     or v_profile.profile_status <> 'approved'
     or v_version.version_status <> 'approved'
     or v_policy.policy_status <> 'approved' then
    raise exception 'COMMERCIAL_PROVIDER_CREDENTIAL_BINDING_NOT_VALIDATABLE';
  end if;

  update public.commercial_provider_credential_bindings
  set
    binding_status = 'validated',
    readiness_status = 'ready',
    validated_by = btrim(p_evaluated_by),
    validated_at = clock_timestamp(),
    readiness_report = jsonb_build_object(
      'profile_approved', true,
      'version_approved', true,
      'policy_approved', true,
      'reference_hash_present', true,
      'material_fingerprint_present', true,
      'secret_resolution_enabled', false,
      'secret_decryption_enabled', false,
      'credential_delivery_enabled', false,
      'network_access_enabled', false,
      'validated_without_secret_access', true
    )
  where id = v_binding.id
  returning * into v_binding;

  perform public.append_commercial_provider_credential_event_internal(
    'CREDENTIAL_BINDING_VALIDATED',
    p_evaluated_by,
    gen_random_uuid(),
    v_binding.credential_policy_id,
    v_binding.credential_profile_id,
    v_binding.credential_version_id,
    v_binding.id,
    null,
    null,
    null,
    'draft',
    'validated',
    'Binding validated without resolving credential material',
    null,
    v_binding.readiness_report
  );

  return v_binding;
end
$$;

-- =============================================================================
-- 15. ACCESS REQUEST INTAKE
-- =============================================================================

create or replace function public.request_commercial_provider_credential_access_internal(
  p_request_key text,
  p_idempotency_key text,
  p_credential_binding_id uuid,
  p_execution_command_id uuid,
  p_requested_scopes text[],
  p_requested_operation text,
  p_requested_ttl_seconds integer,
  p_requested_by text,
  p_correlation_id uuid default gen_random_uuid(),
  p_causation_id uuid default null,
  p_request_metadata jsonb default '{}'::jsonb
)
returns public.commercial_provider_credential_access_requests
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_binding public.commercial_provider_credential_bindings;
  v_policy public.commercial_provider_credential_policies;
  v_existing public.commercial_provider_credential_access_requests;
  v_payload jsonb;
  v_request_hash text;
  v_result public.commercial_provider_credential_access_requests;
begin
  select * into strict v_binding
  from public.commercial_provider_credential_bindings
  where id = p_credential_binding_id;

  select * into strict v_policy
  from public.commercial_provider_credential_policies
  where id = v_binding.credential_policy_id;

  if v_binding.binding_status <> 'validated'
     or v_binding.readiness_status <> 'ready'
     or v_policy.policy_status <> 'approved'
     or v_policy.access_request_enabled is not true then
    raise exception 'COMMERCIAL_PROVIDER_CREDENTIAL_ACCESS_REQUEST_DISABLED';
  end if;

  if p_requested_ttl_seconds > v_policy.maximum_access_ttl_seconds then
    raise exception 'COMMERCIAL_PROVIDER_CREDENTIAL_ACCESS_TTL_EXCEEDED';
  end if;

  v_payload := jsonb_build_object(
    'credential_binding_id', p_credential_binding_id,
    'execution_command_id', p_execution_command_id,
    'requested_scopes', coalesce(p_requested_scopes, '{}'::text[]),
    'requested_operation', p_requested_operation,
    'requested_ttl_seconds', p_requested_ttl_seconds,
    'request_metadata', coalesce(p_request_metadata, '{}'::jsonb)
  );

  v_request_hash :=
    encode(
      extensions.digest(v_payload::text, 'sha256'),
      'hex'
    );

  select *
  into v_existing
  from public.commercial_provider_credential_access_requests
  where idempotency_key = btrim(p_idempotency_key);

  if found then
    if v_existing.request_hash <> v_request_hash then
      raise exception 'COMMERCIAL_PROVIDER_CREDENTIAL_ACCESS_IDEMPOTENCY_CONFLICT';
    end if;

    return v_existing;
  end if;

  insert into public.commercial_provider_credential_access_requests (
    request_key,
    idempotency_key,
    credential_binding_id,
    execution_command_id,
    credential_policy_id,
    request_status,
    requested_scopes,
    requested_operation,
    requested_ttl_seconds,
    correlation_id,
    causation_id,
    requested_by,
    request_metadata,
    request_hash
  ) values (
    lower(btrim(p_request_key)),
    btrim(p_idempotency_key),
    v_binding.id,
    p_execution_command_id,
    v_policy.id,
    'received',
    coalesce(p_requested_scopes, '{}'::text[]),
    lower(btrim(p_requested_operation)),
    p_requested_ttl_seconds,
    p_correlation_id,
    p_causation_id,
    btrim(p_requested_by),
    coalesce(p_request_metadata, '{}'::jsonb),
    v_request_hash
  )
  returning * into v_result;

  perform public.append_commercial_provider_credential_event_internal(
    'CREDENTIAL_ACCESS_REQUESTED',
    p_requested_by,
    v_result.correlation_id,
    v_result.credential_policy_id,
    v_binding.credential_profile_id,
    v_binding.credential_version_id,
    v_binding.id,
    v_result.id,
    null,
    null,
    null,
    'received',
    'Credential access intent registered',
    p_causation_id,
    jsonb_build_object(
      'requested_scopes', v_result.requested_scopes,
      'requested_operation', v_result.requested_operation,
      'requested_ttl_seconds', v_result.requested_ttl_seconds,
      'request_hash', v_result.request_hash
    )
  );

  return v_result;
end
$$;

-- =============================================================================
-- 16. PASSIVE ACCESS EVALUATION
-- =============================================================================

create or replace function public.evaluate_commercial_provider_credential_access_internal(
  p_access_request_id uuid,
  p_evaluated_by text
)
returns public.commercial_provider_credential_access_requests
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_request public.commercial_provider_credential_access_requests;
  v_binding public.commercial_provider_credential_bindings;
  v_policy public.commercial_provider_credential_policies;
  v_receipt public.commercial_provider_credential_receipts;
  v_payload jsonb;
begin
  select * into strict v_request
  from public.commercial_provider_credential_access_requests
  where id = p_access_request_id
  for update;

  if v_request.request_status <> 'received' then
    return v_request;
  end if;

  select * into strict v_binding
  from public.commercial_provider_credential_bindings
  where id = v_request.credential_binding_id;

  select * into strict v_policy
  from public.commercial_provider_credential_policies
  where id = v_request.credential_policy_id;

  v_payload := jsonb_build_object(
    'binding_status', v_binding.binding_status,
    'binding_readiness_status', v_binding.readiness_status,
    'policy_status', v_policy.policy_status,
    'requested_scopes', v_request.requested_scopes,
    'requested_operation', v_request.requested_operation,
    'secret_resolution_enabled', v_policy.secret_resolution_enabled,
    'secret_decryption_enabled', v_policy.secret_decryption_enabled,
    'credential_delivery_enabled', v_policy.credential_delivery_enabled,
    'network_access_enabled', v_policy.network_access_enabled,
    'decision', 'hold',
    'reason', 'FOUNDATION_CREDENTIAL_RESOLUTION_DISABLED'
  );

  insert into public.commercial_provider_credential_receipts (
    access_request_id,
    receipt_type,
    receipt_status,
    normalized_payload,
    content_hash,
    issued_by,
    correlation_id,
    metadata
  ) values (
    v_request.id,
    'policy_decision',
    'held',
    v_payload,
    encode(extensions.digest(v_payload::text, 'sha256'), 'hex'),
    btrim(p_evaluated_by),
    v_request.correlation_id,
    jsonb_build_object('foundation', 'MIGRATION_122')
  )
  returning * into v_receipt;

  update public.commercial_provider_credential_access_requests
  set
    request_status = 'held',
    evaluated_at = clock_timestamp(),
    held_at = clock_timestamp(),
    terminal_reason = 'FOUNDATION_CREDENTIAL_RESOLUTION_DISABLED'
  where id = v_request.id
  returning * into v_request;

  perform public.append_commercial_provider_credential_event_internal(
    'CREDENTIAL_ACCESS_HELD',
    p_evaluated_by,
    v_request.correlation_id,
    v_request.credential_policy_id,
    v_binding.credential_profile_id,
    v_binding.credential_version_id,
    v_binding.id,
    v_request.id,
    null,
    v_receipt.id,
    'received',
    'held',
    'FOUNDATION_CREDENTIAL_RESOLUTION_DISABLED',
    v_request.causation_id,
    v_payload
  );

  return v_request;
end
$$;

-- =============================================================================
-- 17. BLOCKED RESOLUTION ATTEMPT
-- =============================================================================

create or replace function public.record_blocked_commercial_provider_credential_resolution_internal(
  p_access_request_id uuid,
  p_recorded_by text,
  p_reason text default 'FOUNDATION_CREDENTIAL_RESOLUTION_DISABLED'
)
returns public.commercial_provider_credential_resolution_attempts
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_request public.commercial_provider_credential_access_requests;
  v_binding public.commercial_provider_credential_bindings;
  v_attempt_number integer;
  v_attempt public.commercial_provider_credential_resolution_attempts;
  v_receipt public.commercial_provider_credential_receipts;
  v_payload jsonb;
begin
  select * into strict v_request
  from public.commercial_provider_credential_access_requests
  where id = p_access_request_id;

  if v_request.request_status <> 'held' then
    raise exception 'COMMERCIAL_PROVIDER_CREDENTIAL_RESOLUTION_NOT_RECORDABLE';
  end if;

  select * into strict v_binding
  from public.commercial_provider_credential_bindings
  where id = v_request.credential_binding_id;

  select coalesce(max(attempt_number), 0) + 1
  into v_attempt_number
  from public.commercial_provider_credential_resolution_attempts
  where access_request_id = v_request.id;

  insert into public.commercial_provider_credential_resolution_attempts (
    access_request_id,
    attempt_number,
    attempt_status,
    backend_contact_requested,
    backend_contact_performed,
    decryption_requested,
    decryption_performed,
    credential_material_loaded,
    credential_material_delivered,
    normalized_error_code,
    retry_class,
    metadata
  ) values (
    v_request.id,
    v_attempt_number,
    'blocked',
    false,
    false,
    false,
    false,
    false,
    false,
    'COMMERCIAL_PROVIDER_CREDENTIAL_RESOLUTION_DISABLED',
    'manual',
    jsonb_build_object(
      'reason', p_reason,
      'recorded_by', btrim(p_recorded_by)
    )
  )
  returning * into v_attempt;

  v_payload := jsonb_build_object(
    'attempt_number', v_attempt.attempt_number,
    'reason', p_reason,
    'backend_contact_requested', false,
    'backend_contact_performed', false,
    'decryption_requested', false,
    'decryption_performed', false,
    'credential_material_loaded', false,
    'credential_material_delivered', false
  );

  insert into public.commercial_provider_credential_receipts (
    access_request_id,
    resolution_attempt_id,
    receipt_type,
    receipt_status,
    normalized_payload,
    content_hash,
    issued_by,
    correlation_id,
    metadata
  ) values (
    v_request.id,
    v_attempt.id,
    'resolution_blocked',
    'blocked',
    v_payload,
    encode(extensions.digest(v_payload::text, 'sha256'), 'hex'),
    btrim(p_recorded_by),
    v_request.correlation_id,
    jsonb_build_object('foundation', 'MIGRATION_122')
  )
  returning * into v_receipt;

  perform public.append_commercial_provider_credential_event_internal(
    'CREDENTIAL_RESOLUTION_BLOCKED',
    p_recorded_by,
    v_request.correlation_id,
    v_request.credential_policy_id,
    v_binding.credential_profile_id,
    v_binding.credential_version_id,
    v_binding.id,
    v_request.id,
    v_attempt.id,
    v_receipt.id,
    null,
    'blocked',
    p_reason,
    v_request.causation_id,
    v_payload
  );

  return v_attempt;
end
$$;

-- =============================================================================
-- 18. READ MODEL
-- =============================================================================

create or replace function public.get_commercial_provider_credential_access_internal(
  p_access_request_id uuid
)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'access_request', to_jsonb(r),
    'binding', (
      select to_jsonb(b)
      from public.commercial_provider_credential_bindings b
      where b.id = r.credential_binding_id
    ),
    'profile', (
      select to_jsonb(p)
      from public.commercial_provider_credential_profiles p
      join public.commercial_provider_credential_bindings b
        on b.credential_profile_id = p.id
      where b.id = r.credential_binding_id
    ),
    'version', (
      select jsonb_build_object(
        'id', v.id,
        'credential_profile_id', v.credential_profile_id,
        'version_number', v.version_number,
        'version_status', v.version_status,
        'secret_backend', v.secret_backend,
        'secret_reference_hash', v.secret_reference_hash,
        'material_fingerprint', v.material_fingerprint,
        'valid_from', v.valid_from,
        'expires_at', v.expires_at,
        'rotation_due_at', v.rotation_due_at,
        'access_scope', v.access_scope,
        'content_hash', v.content_hash
      )
      from public.commercial_provider_credential_versions v
      join public.commercial_provider_credential_bindings b
        on b.credential_version_id = v.id
      where b.id = r.credential_binding_id
    ),
    'attempts', coalesce((
      select jsonb_agg(to_jsonb(a) order by a.attempt_number, a.id)
      from public.commercial_provider_credential_resolution_attempts a
      where a.access_request_id = r.id
    ), '[]'::jsonb),
    'receipts', coalesce((
      select jsonb_agg(to_jsonb(rc) order by rc.issued_at, rc.id)
      from public.commercial_provider_credential_receipts rc
      where rc.access_request_id = r.id
    ), '[]'::jsonb),
    'events', coalesce((
      select jsonb_agg(to_jsonb(e) order by e.occurred_at, e.id)
      from public.commercial_provider_credential_events e
      where e.access_request_id = r.id
    ), '[]'::jsonb)
  )
  from public.commercial_provider_credential_access_requests r
  where r.id = p_access_request_id
$$;

-- =============================================================================
-- 19. DEFAULT PASSIVE POLICY
-- =============================================================================

with policy_snapshot as (
  select jsonb_build_object(
    'policy_code', 'DEFAULT_PROVIDER_CREDENTIAL_VAULT',
    'version_number', 1,
    'environment', 'test',
    'profile_registration_enabled', true,
    'version_registration_enabled', true,
    'binding_governance_enabled', true,
    'access_request_enabled', true,
    'policy_evaluation_enabled', true,
    'rotation_governance_enabled', true,
    'secret_resolution_enabled', false,
    'secret_decryption_enabled', false,
    'credential_delivery_enabled', false,
    'automatic_rotation_enabled', false,
    'network_access_enabled', false,
    'maximum_active_versions', 2,
    'maximum_access_ttl_seconds', 300,
    'rotation_warning_days', 30,
    'rotation_required_days', 90
  ) as payload
)
insert into public.commercial_provider_credential_policies (
  policy_code,
  version_number,
  policy_status,
  environment,
  profile_registration_enabled,
  version_registration_enabled,
  binding_governance_enabled,
  access_request_enabled,
  policy_evaluation_enabled,
  rotation_governance_enabled,
  secret_resolution_enabled,
  secret_decryption_enabled,
  credential_delivery_enabled,
  automatic_rotation_enabled,
  network_access_enabled,
  maximum_active_versions,
  maximum_access_ttl_seconds,
  rotation_warning_days,
  rotation_required_days,
  configuration,
  content_hash,
  created_by
)
select
  'DEFAULT_PROVIDER_CREDENTIAL_VAULT',
  1,
  'draft',
  'test',
  true,
  true,
  true,
  true,
  true,
  true,
  false,
  false,
  false,
  false,
  false,
  2,
  300,
  30,
  90,
  jsonb_build_object(
    'foundation', 'MIGRATION_122',
    'secret_material_storage', 'forbidden',
    'resolution_mode', 'passive_hold'
  ),
  encode(extensions.digest(payload::text, 'sha256'), 'hex'),
  'MIGRATION_122'
from policy_snapshot;

select public.append_commercial_provider_credential_event_internal(
  'CREDENTIAL_VAULT_GOVERNANCE_INITIALIZED',
  'MIGRATION_122',
  gen_random_uuid(),
  (
    select id
    from public.commercial_provider_credential_policies
    where policy_code = 'DEFAULT_PROVIDER_CREDENTIAL_VAULT'
      and version_number = 1
      and environment = 'test'
  ),
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  'draft',
  'Credential-vault governance initialized in passive hold mode',
  null,
  jsonb_build_object(
    'secret_resolution_enabled', false,
    'secret_decryption_enabled', false,
    'credential_delivery_enabled', false,
    'automatic_rotation_enabled', false,
    'network_access_enabled', false,
    'secret_material_storage', 'forbidden'
  )
);

-- =============================================================================
-- 20. RLS AND PRIVILEGES
-- =============================================================================

alter table public.commercial_provider_credential_policies enable row level security;
alter table public.commercial_provider_credential_profiles enable row level security;
alter table public.commercial_provider_credential_versions enable row level security;
alter table public.commercial_provider_credential_bindings enable row level security;
alter table public.commercial_provider_credential_access_requests enable row level security;
alter table public.commercial_provider_credential_resolution_attempts enable row level security;
alter table public.commercial_provider_credential_receipts enable row level security;
alter table public.commercial_provider_credential_events enable row level security;

revoke all on table public.commercial_provider_credential_policies from public, anon, authenticated;
revoke all on table public.commercial_provider_credential_profiles from public, anon, authenticated;
revoke all on table public.commercial_provider_credential_versions from public, anon, authenticated;
revoke all on table public.commercial_provider_credential_bindings from public, anon, authenticated;
revoke all on table public.commercial_provider_credential_access_requests from public, anon, authenticated;
revoke all on table public.commercial_provider_credential_resolution_attempts from public, anon, authenticated;
revoke all on table public.commercial_provider_credential_receipts from public, anon, authenticated;
revoke all on table public.commercial_provider_credential_events from public, anon, authenticated;

grant select, insert, update on table public.commercial_provider_credential_policies to service_role;
grant select, insert, update on table public.commercial_provider_credential_profiles to service_role;
grant select, insert on table public.commercial_provider_credential_versions to service_role;
grant select, insert, update on table public.commercial_provider_credential_bindings to service_role;
grant select, insert, update on table public.commercial_provider_credential_access_requests to service_role;
grant select, insert on table public.commercial_provider_credential_resolution_attempts to service_role;
grant select, insert on table public.commercial_provider_credential_receipts to service_role;
grant select, insert on table public.commercial_provider_credential_events to service_role;

revoke all on function public.append_commercial_provider_credential_event_internal(
  text,text,uuid,uuid,uuid,uuid,uuid,uuid,uuid,uuid,text,text,text,uuid,jsonb
) from public, anon, authenticated;

revoke all on function public.register_commercial_provider_credential_profile_internal(
  text,text,text,text,text,uuid,uuid,text[],text[],text,jsonb
) from public, anon, authenticated;

revoke all on function public.create_commercial_provider_credential_version_internal(
  uuid,text,text,text,timestamptz,timestamptz,timestamptz,text[],text,jsonb
) from public, anon, authenticated;

revoke all on function public.approve_commercial_provider_credential_profile_internal(
  uuid,text
) from public, anon, authenticated;

revoke all on function public.approve_commercial_provider_credential_version_internal(
  uuid,text
) from public, anon, authenticated;

revoke all on function public.create_commercial_provider_credential_binding_internal(
  uuid,uuid,uuid,uuid,uuid,text,text[],text[],text,jsonb
) from public, anon, authenticated;

revoke all on function public.evaluate_commercial_provider_credential_binding_internal(
  uuid,text
) from public, anon, authenticated;

revoke all on function public.request_commercial_provider_credential_access_internal(
  text,text,uuid,uuid,text[],text,integer,text,uuid,uuid,jsonb
) from public, anon, authenticated;

revoke all on function public.evaluate_commercial_provider_credential_access_internal(
  uuid,text
) from public, anon, authenticated;

revoke all on function public.record_blocked_commercial_provider_credential_resolution_internal(
  uuid,text,text
) from public, anon, authenticated;

revoke all on function public.get_commercial_provider_credential_access_internal(
  uuid
) from public, anon, authenticated;

grant execute on function public.append_commercial_provider_credential_event_internal(
  text,text,uuid,uuid,uuid,uuid,uuid,uuid,uuid,uuid,text,text,text,uuid,jsonb
) to service_role;

grant execute on function public.register_commercial_provider_credential_profile_internal(
  text,text,text,text,text,uuid,uuid,text[],text[],text,jsonb
) to service_role;

grant execute on function public.create_commercial_provider_credential_version_internal(
  uuid,text,text,text,timestamptz,timestamptz,timestamptz,text[],text,jsonb
) to service_role;

grant execute on function public.approve_commercial_provider_credential_profile_internal(
  uuid,text
) to service_role;

grant execute on function public.approve_commercial_provider_credential_version_internal(
  uuid,text
) to service_role;

grant execute on function public.create_commercial_provider_credential_binding_internal(
  uuid,uuid,uuid,uuid,uuid,text,text[],text[],text,jsonb
) to service_role;

grant execute on function public.evaluate_commercial_provider_credential_binding_internal(
  uuid,text
) to service_role;

grant execute on function public.request_commercial_provider_credential_access_internal(
  text,text,uuid,uuid,text[],text,integer,text,uuid,uuid,jsonb
) to service_role;

grant execute on function public.evaluate_commercial_provider_credential_access_internal(
  uuid,text
) to service_role;

grant execute on function public.record_blocked_commercial_provider_credential_resolution_internal(
  uuid,text,text
) to service_role;

grant execute on function public.get_commercial_provider_credential_access_internal(
  uuid
) to service_role;

-- =============================================================================
-- 21. FOUNDATION CERTIFICATION
-- =============================================================================

do $$
declare
  v_policy_count bigint;
  v_profile_count bigint;
  v_version_count bigint;
  v_binding_count bigint;
  v_request_count bigint;
  v_attempt_count bigint;
  v_receipt_count bigint;
  v_event_count bigint;
  v_policy public.commercial_provider_credential_policies;
begin
  select count(*) into v_policy_count
  from public.commercial_provider_credential_policies;

  select count(*) into v_profile_count
  from public.commercial_provider_credential_profiles;

  select count(*) into v_version_count
  from public.commercial_provider_credential_versions;

  select count(*) into v_binding_count
  from public.commercial_provider_credential_bindings;

  select count(*) into v_request_count
  from public.commercial_provider_credential_access_requests;

  select count(*) into v_attempt_count
  from public.commercial_provider_credential_resolution_attempts;

  select count(*) into v_receipt_count
  from public.commercial_provider_credential_receipts;

  select count(*) into v_event_count
  from public.commercial_provider_credential_events;

  select *
  into strict v_policy
  from public.commercial_provider_credential_policies
  where policy_code = 'DEFAULT_PROVIDER_CREDENTIAL_VAULT'
    and version_number = 1
    and environment = 'test';

  if v_policy_count <> 1
     or v_profile_count <> 0
     or v_version_count <> 0
     or v_binding_count <> 0
     or v_request_count <> 0
     or v_attempt_count <> 0
     or v_receipt_count <> 0
     or v_event_count <> 1 then
    raise exception
      'MIGRATION_122_FOUNDATION_COUNT_ASSERTION_FAILED policy=%, profile=%, version=%, binding=%, request=%, attempt=%, receipt=%, event=%',
      v_policy_count,
      v_profile_count,
      v_version_count,
      v_binding_count,
      v_request_count,
      v_attempt_count,
      v_receipt_count,
      v_event_count;
  end if;

  if v_policy.secret_resolution_enabled
     or v_policy.secret_decryption_enabled
     or v_policy.credential_delivery_enabled
     or v_policy.automatic_rotation_enabled
     or v_policy.network_access_enabled then
    raise exception 'MIGRATION_122_UNSAFE_DEFAULT_POLICY';
  end if;

  raise notice
    'MIGRATION_122_CERTIFIED policy_count=1, profile_count=0, version_count=0, binding_count=0, access_request_count=0, resolution_attempt_count=0, receipt_count=0, event_count=1, profile_registration_enabled=true, version_registration_enabled=true, binding_governance_enabled=true, access_request_enabled=true, policy_evaluation_enabled=true, rotation_governance_enabled=true, secret_resolution_enabled=false, secret_decryption_enabled=false, credential_delivery_enabled=false, automatic_rotation_enabled=false, network_access_enabled=false, plaintext_storage_forbidden=true';
end
$$;

commit;
