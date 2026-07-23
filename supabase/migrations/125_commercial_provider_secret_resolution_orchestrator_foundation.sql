-- =============================================================================
-- FANTAGOL
-- Migration: 125_commercial_provider_secret_resolution_orchestrator_foundation.sql
-- Milestone: Commercial Platform - Provider Secret Resolution Orchestrator
--
-- Purpose:
--   Introduce the passive orchestration control-plane that may plan and audit
--   future provider-secret resolution, without contacting any secret backend,
--   decrypting material, loading credentials, delivering credentials, or
--   performing network activity.
--
-- Safety posture:
--   - orchestration intake and policy evaluation are enabled;
--   - plans, steps, leases, blocked attempts, receipts and events are auditable;
--   - automatic dispatch is disabled;
--   - backend contact is disabled;
--   - secret resolution and decryption are disabled;
--   - credential material loading and delivery are disabled;
--   - network access is disabled.
-- =============================================================================

\set ON_ERROR_STOP on

begin;

create extension if not exists pgcrypto with schema extensions;

do $$
begin
  if to_regclass('public.commercial_provider_credential_access_requests') is null then
    raise exception
      'MIGRATION_125_DEPENDENCY_MISSING commercial_provider_credential_access_requests';
  end if;

  if to_regclass('public.commercial_provider_credential_bindings') is null then
    raise exception
      'MIGRATION_125_DEPENDENCY_MISSING commercial_provider_credential_bindings';
  end if;

  if to_regclass('public.commercial_provider_credential_policies') is null then
    raise exception
      'MIGRATION_125_DEPENDENCY_MISSING commercial_provider_credential_policies';
  end if;
end
$$;

-- =============================================================================
-- 1. ORCHESTRATOR POLICY
-- =============================================================================

create table public.commercial_secret_resolution_policies (
  id uuid primary key default gen_random_uuid(),
  policy_code text not null,
  environment text not null default 'production',
  policy_status text not null default 'draft',
  policy_version integer not null default 1,

  orchestration_intake_enabled boolean not null default true,
  policy_evaluation_enabled boolean not null default true,
  plan_generation_enabled boolean not null default true,
  step_planning_enabled boolean not null default true,
  lease_governance_enabled boolean not null default true,
  blocked_attempt_recording_enabled boolean not null default true,

  automatic_dispatch_enabled boolean not null default false,
  secret_backend_contact_enabled boolean not null default false,
  secret_resolution_enabled boolean not null default false,
  secret_decryption_enabled boolean not null default false,
  credential_material_loading_enabled boolean not null default false,
  credential_delivery_enabled boolean not null default false,
  network_access_enabled boolean not null default false,

  maximum_plan_attempts integer not null default 3,
  maximum_step_attempts integer not null default 3,
  maximum_lease_seconds integer not null default 60,
  default_backoff_seconds integer not null default 30,

  created_by text not null,
  approved_by text,
  approved_at timestamptz,
  policy_metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp(),

  constraint commercial_secret_resolution_policy_unique
    unique (policy_code, environment),

  constraint commercial_secret_resolution_policy_code_check
    check (
      policy_code = lower(policy_code)
      and policy_code ~ '^[a-z][a-z0-9:_-]{7,127}$'
      and environment in ('development','test','staging','production')
    ),

  constraint commercial_secret_resolution_policy_status_check
    check (policy_status in ('draft','approved','retired')),

  constraint commercial_secret_resolution_policy_limits_check
    check (
      policy_version > 0
      and maximum_plan_attempts between 1 and 20
      and maximum_step_attempts between 1 and 20
      and maximum_lease_seconds between 15 and 3600
      and default_backoff_seconds between 1 and 86400
    ),

  constraint commercial_secret_resolution_policy_json_check
    check (
      jsonb_typeof(policy_metadata) = 'object'
      and not (policy_metadata ?| array[
        'secret','secret_value','password','private_key','access_token',
        'refresh_token','api_key','client_secret','plaintext','ciphertext'
      ])
    ),

  constraint commercial_secret_resolution_policy_actor_check
    check (
      length(btrim(created_by)) between 1 and 160
      and (approved_by is null or length(btrim(approved_by)) between 1 and 160)
    ),

  constraint commercial_secret_resolution_policy_passive_check
    check (
      automatic_dispatch_enabled = false
      and secret_backend_contact_enabled = false
      and secret_resolution_enabled = false
      and secret_decryption_enabled = false
      and credential_material_loading_enabled = false
      and credential_delivery_enabled = false
      and network_access_enabled = false
    )
);

comment on table public.commercial_secret_resolution_policies is
'Immutable passive policy for provider-secret resolution orchestration. Migration 125 forbids dispatch, backend contact, resolution, decryption, material loading, delivery and network access.';

-- =============================================================================
-- 2. RESOLUTION PLANS
-- =============================================================================

create table public.commercial_secret_resolution_plans (
  id uuid primary key default gen_random_uuid(),
  plan_key text not null unique,
  idempotency_key text not null unique,

  access_request_id uuid not null,
  orchestrator_policy_id uuid not null,

  plan_status text not null default 'received',
  plan_version integer not null default 1,
  requested_operation text,
  requested_scopes text[] not null default '{}'::text[],
  requested_ttl_seconds integer not null,

  correlation_id uuid not null,
  causation_id uuid,
  requested_by text not null,
  evaluated_by text,
  planned_by text,

  requested_at timestamptz not null default clock_timestamp(),
  evaluated_at timestamptz,
  planned_at timestamptz,
  held_at timestamptz,
  terminal_reason text,

  plan_metadata jsonb not null default '{}'::jsonb,
  plan_hash text not null,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),

  constraint commercial_secret_resolution_plan_request_fkey
    foreign key (access_request_id)
    references public.commercial_provider_credential_access_requests(id)
    on delete restrict,

  constraint commercial_secret_resolution_plan_policy_fkey
    foreign key (orchestrator_policy_id)
    references public.commercial_secret_resolution_policies(id)
    on delete restrict,

  constraint commercial_secret_resolution_plan_key_check
    check (
      plan_key = lower(plan_key)
      and plan_key ~ '^[a-z][a-z0-9:_-]{7,159}$'
      and length(idempotency_key) between 8 and 240
    ),

  constraint commercial_secret_resolution_plan_status_check
    check (plan_status in ('received','evaluated','planned','held','cancelled')),

  constraint commercial_secret_resolution_plan_values_check
    check (
      plan_version > 0
      and cardinality(requested_scopes) <= 64
      and requested_ttl_seconds between 30 and 3600
      and plan_hash ~ '^[a-f0-9]{64}$'
    ),

  constraint commercial_secret_resolution_plan_json_check
    check (
      jsonb_typeof(plan_metadata) = 'object'
      and not (plan_metadata ?| array[
        'secret','secret_value','password','private_key','access_token',
        'refresh_token','api_key','client_secret','plaintext','ciphertext'
      ])
    ),

  constraint commercial_secret_resolution_plan_actor_check
    check (
      length(btrim(requested_by)) between 1 and 160
      and (evaluated_by is null or length(btrim(evaluated_by)) between 1 and 160)
      and (planned_by is null or length(btrim(planned_by)) between 1 and 160)
    )
);

create index commercial_secret_resolution_plans_queue_idx
  on public.commercial_secret_resolution_plans(plan_status, requested_at, id);

create index commercial_secret_resolution_plans_request_idx
  on public.commercial_secret_resolution_plans(access_request_id, created_at desc);

comment on table public.commercial_secret_resolution_plans is
'Passive orchestration plan linked to an approved credential access intent. Migration 125 can only evaluate, plan and hold.';

-- =============================================================================
-- 3. PLAN STEPS
-- =============================================================================

create table public.commercial_secret_resolution_steps (
  id uuid primary key default gen_random_uuid(),
  resolution_plan_id uuid not null,
  step_number integer not null,
  step_type text not null,
  step_status text not null default 'planned',

  requires_backend_contact boolean not null default false,
  requires_decryption boolean not null default false,
  requires_material_loading boolean not null default false,
  requires_delivery boolean not null default false,
  requires_network boolean not null default false,

  maximum_attempts integer not null default 1,
  planned_by text not null,
  planned_at timestamptz not null default clock_timestamp(),
  held_at timestamptz,
  terminal_reason text,
  step_metadata jsonb not null default '{}'::jsonb,

  constraint commercial_secret_resolution_step_plan_fkey
    foreign key (resolution_plan_id)
    references public.commercial_secret_resolution_plans(id)
    on delete restrict,

  constraint commercial_secret_resolution_step_unique
    unique (resolution_plan_id, step_number),

  constraint commercial_secret_resolution_step_type_check
    check (step_type in (
      'validate_request',
      'validate_binding',
      'validate_policy',
      'resolve_reference',
      'contact_backend',
      'decrypt_material',
      'load_material',
      'deliver_material'
    )),

  constraint commercial_secret_resolution_step_status_check
    check (step_status in ('planned','held','blocked','cancelled')),

  constraint commercial_secret_resolution_step_values_check
    check (step_number > 0 and maximum_attempts between 1 and 20),

  constraint commercial_secret_resolution_step_json_check
    check (
      jsonb_typeof(step_metadata) = 'object'
      and not (step_metadata ?| array[
        'secret','secret_value','password','private_key','access_token',
        'refresh_token','api_key','client_secret','plaintext','ciphertext'
      ])
    ),

  constraint commercial_secret_resolution_step_actor_check
    check (length(btrim(planned_by)) between 1 and 160),

  constraint commercial_secret_resolution_step_passive_check
    check (
      requires_backend_contact = false
      and requires_decryption = false
      and requires_material_loading = false
      and requires_delivery = false
      and requires_network = false
    )
);

comment on table public.commercial_secret_resolution_steps is
'Passive plan steps. Migration 125 permits validation steps only; all secret-handling capabilities remain false.';

-- =============================================================================
-- 4. IDEMPOTENCY RECORDS
-- =============================================================================

create table public.commercial_secret_resolution_idempotency (
  id uuid primary key default gen_random_uuid(),
  idempotency_key text not null unique,
  resolution_plan_id uuid not null unique,
  request_hash text not null,
  replay_count integer not null default 0,
  first_seen_at timestamptz not null default clock_timestamp(),
  last_seen_at timestamptz not null default clock_timestamp(),

  constraint commercial_secret_resolution_idem_plan_fkey
    foreign key (resolution_plan_id)
    references public.commercial_secret_resolution_plans(id)
    on delete restrict,

  constraint commercial_secret_resolution_idem_values_check
    check (
      length(idempotency_key) between 8 and 240
      and request_hash ~ '^[a-f0-9]{64}$'
      and replay_count >= 0
    )
);

comment on table public.commercial_secret_resolution_idempotency is
'Idempotency projection for passive secret-resolution plan intake.';

-- =============================================================================
-- 5. PASSIVE LEASES
-- =============================================================================

create table public.commercial_secret_resolution_leases (
  id uuid primary key default gen_random_uuid(),
  resolution_plan_id uuid not null,
  lease_status text not null default 'offered',
  lease_owner text,
  lease_token_hash text,
  offered_at timestamptz not null default clock_timestamp(),
  claimed_at timestamptz,
  expires_at timestamptz,
  released_at timestamptz,
  lease_metadata jsonb not null default '{}'::jsonb,

  constraint commercial_secret_resolution_lease_plan_fkey
    foreign key (resolution_plan_id)
    references public.commercial_secret_resolution_plans(id)
    on delete restrict,

  constraint commercial_secret_resolution_lease_status_check
    check (lease_status in ('offered','blocked','expired','released')),

  constraint commercial_secret_resolution_lease_hash_check
    check (
      lease_token_hash is null
      or lease_token_hash ~ '^[a-f0-9]{64}$'
    ),

  constraint commercial_secret_resolution_lease_json_check
    check (
      jsonb_typeof(lease_metadata) = 'object'
      and not (lease_metadata ?| array[
        'secret','secret_value','password','private_key','access_token',
        'refresh_token','api_key','client_secret','plaintext','ciphertext'
      ])
    ),

  constraint commercial_secret_resolution_lease_passive_check
    check (
      lease_status <> 'claimed'
      and lease_owner is null
      and lease_token_hash is null
      and claimed_at is null
      and expires_at is null
    )
);

create unique index commercial_secret_resolution_active_lease_idx
  on public.commercial_secret_resolution_leases(resolution_plan_id)
  where lease_status in ('offered','blocked');

comment on table public.commercial_secret_resolution_leases is
'Passive lease offers. Claiming is structurally unavailable in migration 125.';

-- =============================================================================
-- 6. BLOCKED ORCHESTRATION ATTEMPTS
-- =============================================================================

create table public.commercial_secret_resolution_attempts (
  id uuid primary key default gen_random_uuid(),
  resolution_plan_id uuid not null,
  resolution_step_id uuid,
  attempt_number integer not null,
  attempt_status text not null default 'blocked',

  dispatch_requested boolean not null default false,
  dispatch_performed boolean not null default false,
  backend_contact_requested boolean not null default false,
  backend_contact_performed boolean not null default false,
  resolution_requested boolean not null default false,
  resolution_performed boolean not null default false,
  decryption_requested boolean not null default false,
  decryption_performed boolean not null default false,
  material_loaded boolean not null default false,
  material_delivered boolean not null default false,
  network_attempted boolean not null default false,

  normalized_error_code text,
  retry_class text not null default 'never',
  recorded_by text not null,
  recorded_at timestamptz not null default clock_timestamp(),
  attempt_metadata jsonb not null default '{}'::jsonb,

  constraint commercial_secret_resolution_attempt_plan_fkey
    foreign key (resolution_plan_id)
    references public.commercial_secret_resolution_plans(id)
    on delete restrict,

  constraint commercial_secret_resolution_attempt_step_fkey
    foreign key (resolution_step_id)
    references public.commercial_secret_resolution_steps(id)
    on delete restrict,

  constraint commercial_secret_resolution_attempt_unique
    unique (resolution_plan_id, attempt_number),

  constraint commercial_secret_resolution_attempt_status_check
    check (attempt_status in ('blocked','abandoned')),

  constraint commercial_secret_resolution_attempt_values_check
    check (
      attempt_number > 0
      and retry_class in ('never','manual')
      and length(btrim(recorded_by)) between 1 and 160
    ),

  constraint commercial_secret_resolution_attempt_json_check
    check (
      jsonb_typeof(attempt_metadata) = 'object'
      and not (attempt_metadata ?| array[
        'secret','secret_value','password','private_key','access_token',
        'refresh_token','api_key','client_secret','plaintext','ciphertext'
      ])
    ),

  constraint commercial_secret_resolution_attempt_passive_check
    check (
      dispatch_requested = false
      and dispatch_performed = false
      and backend_contact_requested = false
      and backend_contact_performed = false
      and resolution_requested = false
      and resolution_performed = false
      and decryption_requested = false
      and decryption_performed = false
      and material_loaded = false
      and material_delivered = false
      and network_attempted = false
    )
);

comment on table public.commercial_secret_resolution_attempts is
'Blocked orchestration-attempt evidence. No execution or secret-material activity is permitted.';

-- =============================================================================
-- 7. APPEND-ONLY RECEIPTS
-- =============================================================================

create table public.commercial_secret_resolution_receipts (
  id uuid primary key default gen_random_uuid(),
  resolution_plan_id uuid not null,
  resolution_attempt_id uuid,
  receipt_type text not null,
  receipt_status text not null,
  normalized_payload jsonb not null default '{}'::jsonb,
  content_hash text not null,
  issued_by text not null,
  issued_at timestamptz not null default clock_timestamp(),
  correlation_id uuid not null,
  metadata jsonb not null default '{}'::jsonb,

  constraint commercial_secret_resolution_receipt_plan_fkey
    foreign key (resolution_plan_id)
    references public.commercial_secret_resolution_plans(id)
    on delete restrict,

  constraint commercial_secret_resolution_receipt_attempt_fkey
    foreign key (resolution_attempt_id)
    references public.commercial_secret_resolution_attempts(id)
    on delete restrict,

  constraint commercial_secret_resolution_receipt_type_check
    check (receipt_type in (
      'policy_decision',
      'plan_created',
      'plan_held',
      'lease_blocked',
      'execution_blocked'
    )),

  constraint commercial_secret_resolution_receipt_status_check
    check (receipt_status in ('accepted','held','blocked')),

  constraint commercial_secret_resolution_receipt_json_check
    check (
      jsonb_typeof(normalized_payload) = 'object'
      and jsonb_typeof(metadata) = 'object'
      and not (normalized_payload ?| array[
        'secret','secret_value','password','private_key','access_token',
        'refresh_token','api_key','client_secret','plaintext','ciphertext'
      ])
      and not (metadata ?| array[
        'secret','secret_value','password','private_key','access_token',
        'refresh_token','api_key','client_secret','plaintext','ciphertext'
      ])
      and content_hash ~ '^[a-f0-9]{64}$'
      and length(btrim(issued_by)) between 1 and 160
    )
);

create index commercial_secret_resolution_receipts_timeline_idx
  on public.commercial_secret_resolution_receipts
  (resolution_plan_id, issued_at, id);

comment on table public.commercial_secret_resolution_receipts is
'Append-only evidence produced by passive secret-resolution orchestration.';

-- =============================================================================
-- 8. APPEND-ONLY EVENTS
-- =============================================================================

create table public.commercial_secret_resolution_events (
  id uuid primary key default gen_random_uuid(),
  event_type text not null,
  orchestrator_policy_id uuid,
  resolution_plan_id uuid,
  resolution_step_id uuid,
  resolution_lease_id uuid,
  resolution_attempt_id uuid,
  resolution_receipt_id uuid,
  previous_status text,
  new_status text,
  reason text,
  actor text not null,
  correlation_id uuid not null,
  causation_id uuid,
  payload jsonb not null default '{}'::jsonb,
  occurred_at timestamptz not null default clock_timestamp(),

  constraint commercial_secret_resolution_event_policy_fkey
    foreign key (orchestrator_policy_id)
    references public.commercial_secret_resolution_policies(id)
    on delete restrict,

  constraint commercial_secret_resolution_event_plan_fkey
    foreign key (resolution_plan_id)
    references public.commercial_secret_resolution_plans(id)
    on delete restrict,

  constraint commercial_secret_resolution_event_step_fkey
    foreign key (resolution_step_id)
    references public.commercial_secret_resolution_steps(id)
    on delete restrict,

  constraint commercial_secret_resolution_event_lease_fkey
    foreign key (resolution_lease_id)
    references public.commercial_secret_resolution_leases(id)
    on delete restrict,

  constraint commercial_secret_resolution_event_attempt_fkey
    foreign key (resolution_attempt_id)
    references public.commercial_secret_resolution_attempts(id)
    on delete restrict,

  constraint commercial_secret_resolution_event_receipt_fkey
    foreign key (resolution_receipt_id)
    references public.commercial_secret_resolution_receipts(id)
    on delete restrict,

  constraint commercial_secret_resolution_event_type_check
    check (
      event_type = upper(event_type)
      and event_type ~ '^[A-Z][A-Z0-9_]{2,95}$'
    ),

  constraint commercial_secret_resolution_event_json_check
    check (
      length(btrim(actor)) between 1 and 160
      and jsonb_typeof(payload) = 'object'
      and not (payload ?| array[
        'secret','secret_value','password','private_key','access_token',
        'refresh_token','api_key','client_secret','plaintext','ciphertext'
      ])
    )
);

create index commercial_secret_resolution_events_timeline_idx
  on public.commercial_secret_resolution_events
  (
    coalesce(resolution_plan_id, '00000000-0000-0000-0000-000000000000'::uuid),
    occurred_at,
    id
  );

comment on table public.commercial_secret_resolution_events is
'Append-only orchestrator event stream.';

-- =============================================================================
-- 9. IMMUTABILITY AND TIMESTAMP GUARDS
-- =============================================================================

create or replace function public.protect_commercial_secret_resolution_policy()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  raise exception 'COMMERCIAL_SECRET_RESOLUTION_POLICY_IMMUTABLE';
end
$$;

create or replace function public.protect_commercial_secret_resolution_receipt()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  raise exception 'COMMERCIAL_SECRET_RESOLUTION_RECEIPT_APPEND_ONLY';
end
$$;

create or replace function public.protect_commercial_secret_resolution_event()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  raise exception 'COMMERCIAL_SECRET_RESOLUTION_EVENT_APPEND_ONLY';
end
$$;

create or replace function public.set_commercial_secret_resolution_updated_at()
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

create trigger commercial_secret_resolution_policy_protect
before update or delete on public.commercial_secret_resolution_policies
for each row execute function public.protect_commercial_secret_resolution_policy();

create trigger commercial_secret_resolution_receipt_protect
before update or delete on public.commercial_secret_resolution_receipts
for each row execute function public.protect_commercial_secret_resolution_receipt();

create trigger commercial_secret_resolution_event_protect
before update or delete on public.commercial_secret_resolution_events
for each row execute function public.protect_commercial_secret_resolution_event();

create trigger commercial_secret_resolution_plan_updated_at
before update on public.commercial_secret_resolution_plans
for each row execute function public.set_commercial_secret_resolution_updated_at();

-- =============================================================================
-- 10. EVENT APPEND
-- =============================================================================

create or replace function public.append_commercial_secret_resolution_event(
  p_event_type text,
  p_actor text,
  p_correlation_id uuid,
  p_orchestrator_policy_id uuid default null,
  p_resolution_plan_id uuid default null,
  p_resolution_step_id uuid default null,
  p_resolution_lease_id uuid default null,
  p_resolution_attempt_id uuid default null,
  p_resolution_receipt_id uuid default null,
  p_previous_status text default null,
  p_new_status text default null,
  p_reason text default null,
  p_causation_id uuid default null,
  p_payload jsonb default '{}'::jsonb
)
returns public.commercial_secret_resolution_events
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_result public.commercial_secret_resolution_events;
begin
  insert into public.commercial_secret_resolution_events (
    event_type, orchestrator_policy_id, resolution_plan_id,
    resolution_step_id, resolution_lease_id, resolution_attempt_id,
    resolution_receipt_id, previous_status, new_status, reason, actor,
    correlation_id, causation_id, payload
  ) values (
    upper(btrim(p_event_type)), p_orchestrator_policy_id, p_resolution_plan_id,
    p_resolution_step_id, p_resolution_lease_id, p_resolution_attempt_id,
    p_resolution_receipt_id, p_previous_status, p_new_status, p_reason,
    btrim(p_actor), p_correlation_id, p_causation_id, coalesce(p_payload, '{}'::jsonb)
  )
  returning * into v_result;

  return v_result;
end
$$;

-- =============================================================================
-- 11. RECEIPT APPEND
-- =============================================================================

create or replace function public.append_commercial_secret_resolution_receipt(
  p_resolution_plan_id uuid,
  p_resolution_attempt_id uuid,
  p_receipt_type text,
  p_receipt_status text,
  p_normalized_payload jsonb,
  p_issued_by text,
  p_correlation_id uuid,
  p_metadata jsonb default '{}'::jsonb
)
returns public.commercial_secret_resolution_receipts
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_hash text;
  v_result public.commercial_secret_resolution_receipts;
begin
  v_hash := encode(
    extensions.digest(
      jsonb_build_object(
        'resolution_plan_id', p_resolution_plan_id,
        'resolution_attempt_id', p_resolution_attempt_id,
        'receipt_type', lower(btrim(p_receipt_type)),
        'receipt_status', lower(btrim(p_receipt_status)),
        'normalized_payload', coalesce(p_normalized_payload, '{}'::jsonb),
        'correlation_id', p_correlation_id
      )::text,
      'sha256'
    ),
    'hex'
  );

  insert into public.commercial_secret_resolution_receipts (
    resolution_plan_id, resolution_attempt_id, receipt_type, receipt_status,
    normalized_payload, content_hash, issued_by, correlation_id, metadata
  ) values (
    p_resolution_plan_id, p_resolution_attempt_id, lower(btrim(p_receipt_type)),
    lower(btrim(p_receipt_status)), coalesce(p_normalized_payload, '{}'::jsonb),
    v_hash, btrim(p_issued_by), p_correlation_id, coalesce(p_metadata, '{}'::jsonb)
  )
  returning * into v_result;

  return v_result;
end
$$;

-- =============================================================================
-- 12. PLAN INTAKE WITH IDEMPOTENCY
-- =============================================================================

create or replace function public.enqueue_commercial_secret_resolution_plan(
  p_plan_key text,
  p_idempotency_key text,
  p_access_request_id uuid,
  p_requested_by text,
  p_correlation_id uuid,
  p_causation_id uuid default null,
  p_plan_metadata jsonb default '{}'::jsonb
)
returns public.commercial_secret_resolution_plans
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_request public.commercial_provider_credential_access_requests;
  v_policy public.commercial_secret_resolution_policies;
  v_existing public.commercial_secret_resolution_plans;
  v_payload jsonb;
  v_hash text;
  v_result public.commercial_secret_resolution_plans;
begin
  select * into strict v_request
  from public.commercial_provider_credential_access_requests
  where id = p_access_request_id;

  select * into strict v_policy
  from public.commercial_secret_resolution_policies
  where environment = 'production'
    and policy_status = 'approved'
  order by policy_version desc
  limit 1;

  if v_policy.orchestration_intake_enabled is not true then
    raise exception 'COMMERCIAL_SECRET_RESOLUTION_INTAKE_DISABLED';
  end if;

  if v_request.request_status <> 'held' then
    raise exception
      'COMMERCIAL_SECRET_RESOLUTION_ACCESS_REQUEST_NOT_HELD status=%',
      v_request.request_status;
  end if;

  v_payload := jsonb_build_object(
    'access_request_id', p_access_request_id,
    'requested_operation', v_request.requested_operation,
    'requested_scopes', v_request.requested_scopes,
    'requested_ttl_seconds', v_request.requested_ttl_seconds,
    'plan_metadata', coalesce(p_plan_metadata, '{}'::jsonb)
  );

  v_hash := encode(extensions.digest(v_payload::text, 'sha256'), 'hex');

  select * into v_existing
  from public.commercial_secret_resolution_plans
  where idempotency_key = btrim(p_idempotency_key);

  if found then
    if v_existing.plan_hash <> v_hash then
      raise exception 'COMMERCIAL_SECRET_RESOLUTION_IDEMPOTENCY_CONFLICT';
    end if;

    update public.commercial_secret_resolution_idempotency
    set replay_count = replay_count + 1,
        last_seen_at = clock_timestamp()
    where resolution_plan_id = v_existing.id;

    return v_existing;
  end if;

  insert into public.commercial_secret_resolution_plans (
    plan_key, idempotency_key, access_request_id, orchestrator_policy_id,
    plan_status, requested_operation, requested_scopes, requested_ttl_seconds,
    correlation_id, causation_id, requested_by, plan_metadata, plan_hash
  ) values (
    lower(btrim(p_plan_key)), btrim(p_idempotency_key), v_request.id, v_policy.id,
    'received', v_request.requested_operation, v_request.requested_scopes,
    v_request.requested_ttl_seconds, p_correlation_id, p_causation_id,
    btrim(p_requested_by), coalesce(p_plan_metadata, '{}'::jsonb), v_hash
  )
  returning * into v_result;

  insert into public.commercial_secret_resolution_idempotency (
    idempotency_key, resolution_plan_id, request_hash
  ) values (
    btrim(p_idempotency_key), v_result.id, v_hash
  );

  perform public.append_commercial_secret_resolution_event(
    'SECRET_RESOLUTION_PLAN_RECEIVED', p_requested_by, p_correlation_id,
    v_policy.id, v_result.id, null, null, null, null, null, 'received',
    'Passive secret-resolution plan registered', p_causation_id,
    jsonb_build_object('plan_hash', v_hash, 'access_request_id', v_request.id)
  );

  return v_result;
end
$$;

-- =============================================================================
-- 13. POLICY EVALUATION AND PASSIVE PLAN GENERATION
-- =============================================================================

create or replace function public.evaluate_commercial_secret_resolution_plan(
  p_resolution_plan_id uuid,
  p_evaluated_by text
)
returns public.commercial_secret_resolution_plans
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_plan public.commercial_secret_resolution_plans;
  v_policy public.commercial_secret_resolution_policies;
  v_receipt public.commercial_secret_resolution_receipts;
begin
  select * into strict v_plan
  from public.commercial_secret_resolution_plans
  where id = p_resolution_plan_id
  for update;

  if v_plan.plan_status <> 'received' then
    return v_plan;
  end if;

  select * into strict v_policy
  from public.commercial_secret_resolution_policies
  where id = v_plan.orchestrator_policy_id;

  if v_policy.policy_evaluation_enabled is not true then
    raise exception 'COMMERCIAL_SECRET_RESOLUTION_EVALUATION_DISABLED';
  end if;

  update public.commercial_secret_resolution_plans
  set plan_status = 'evaluated',
      evaluated_by = btrim(p_evaluated_by),
      evaluated_at = clock_timestamp()
  where id = v_plan.id
  returning * into v_plan;

  v_receipt := public.append_commercial_secret_resolution_receipt(
    v_plan.id, null, 'policy_decision', 'accepted',
    jsonb_build_object(
      'policy_id', v_policy.id,
      'automatic_dispatch_enabled', v_policy.automatic_dispatch_enabled,
      'secret_backend_contact_enabled', v_policy.secret_backend_contact_enabled,
      'secret_resolution_enabled', v_policy.secret_resolution_enabled,
      'secret_decryption_enabled', v_policy.secret_decryption_enabled,
      'credential_material_loading_enabled', v_policy.credential_material_loading_enabled,
      'credential_delivery_enabled', v_policy.credential_delivery_enabled,
      'network_access_enabled', v_policy.network_access_enabled
    ),
    p_evaluated_by, v_plan.correlation_id
  );

  perform public.append_commercial_secret_resolution_event(
    'SECRET_RESOLUTION_PLAN_EVALUATED', p_evaluated_by, v_plan.correlation_id,
    v_policy.id, v_plan.id, null, null, null, v_receipt.id,
    'received', 'evaluated', 'Passive policy evaluation completed',
    v_plan.causation_id, '{}'::jsonb
  );

  return v_plan;
end
$$;

create or replace function public.build_commercial_secret_resolution_plan(
  p_resolution_plan_id uuid,
  p_planned_by text
)
returns public.commercial_secret_resolution_plans
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_plan public.commercial_secret_resolution_plans;
  v_policy public.commercial_secret_resolution_policies;
  v_step public.commercial_secret_resolution_steps;
  v_receipt public.commercial_secret_resolution_receipts;
begin
  select * into strict v_plan
  from public.commercial_secret_resolution_plans
  where id = p_resolution_plan_id
  for update;

  if v_plan.plan_status <> 'evaluated' then
    return v_plan;
  end if;

  select * into strict v_policy
  from public.commercial_secret_resolution_policies
  where id = v_plan.orchestrator_policy_id;

  if v_policy.plan_generation_enabled is not true
     or v_policy.step_planning_enabled is not true then
    raise exception 'COMMERCIAL_SECRET_RESOLUTION_PLAN_GENERATION_DISABLED';
  end if;

  insert into public.commercial_secret_resolution_steps (
    resolution_plan_id, step_number, step_type, step_status,
    maximum_attempts, planned_by, step_metadata
  ) values
    (
      v_plan.id, 1, 'validate_request', 'planned',
      v_policy.maximum_step_attempts, btrim(p_planned_by),
      jsonb_build_object('passive', true)
    ),
    (
      v_plan.id, 2, 'validate_binding', 'planned',
      v_policy.maximum_step_attempts, btrim(p_planned_by),
      jsonb_build_object('passive', true)
    ),
    (
      v_plan.id, 3, 'validate_policy', 'planned',
      v_policy.maximum_step_attempts, btrim(p_planned_by),
      jsonb_build_object('passive', true)
    );

  update public.commercial_secret_resolution_plans
  set plan_status = 'planned',
      planned_by = btrim(p_planned_by),
      planned_at = clock_timestamp()
  where id = v_plan.id
  returning * into v_plan;

  v_receipt := public.append_commercial_secret_resolution_receipt(
    v_plan.id, null, 'plan_created', 'accepted',
    jsonb_build_object('planned_step_count', 3, 'passive', true),
    p_planned_by, v_plan.correlation_id
  );

  perform public.append_commercial_secret_resolution_event(
    'SECRET_RESOLUTION_PLAN_BUILT', p_planned_by, v_plan.correlation_id,
    v_policy.id, v_plan.id, null, null, null, v_receipt.id,
    'evaluated', 'planned', 'Passive validation plan generated',
    v_plan.causation_id, jsonb_build_object('step_count', 3)
  );

  return v_plan;
end
$$;

-- =============================================================================
-- 14. PASSIVE LEASE OFFER AND HELD STATE
-- =============================================================================

create or replace function public.offer_commercial_secret_resolution_lease(
  p_resolution_plan_id uuid,
  p_offered_by text
)
returns public.commercial_secret_resolution_leases
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_plan public.commercial_secret_resolution_plans;
  v_policy public.commercial_secret_resolution_policies;
  v_lease public.commercial_secret_resolution_leases;
  v_receipt public.commercial_secret_resolution_receipts;
begin
  select * into strict v_plan
  from public.commercial_secret_resolution_plans
  where id = p_resolution_plan_id
  for update;

  select * into strict v_policy
  from public.commercial_secret_resolution_policies
  where id = v_plan.orchestrator_policy_id;

  if v_policy.lease_governance_enabled is not true then
    raise exception 'COMMERCIAL_SECRET_RESOLUTION_LEASE_GOVERNANCE_DISABLED';
  end if;

  if v_plan.plan_status not in ('planned','held') then
    raise exception
      'COMMERCIAL_SECRET_RESOLUTION_PLAN_NOT_LEASEABLE status=%',
      v_plan.plan_status;
  end if;

  select * into v_lease
  from public.commercial_secret_resolution_leases
  where resolution_plan_id = v_plan.id
    and lease_status in ('offered','blocked');

  if found then
    return v_lease;
  end if;

  insert into public.commercial_secret_resolution_leases (
    resolution_plan_id, lease_status, lease_metadata
  ) values (
    v_plan.id, 'offered',
    jsonb_build_object('offered_by', btrim(p_offered_by), 'claiming_enabled', false)
  )
  returning * into v_lease;

  update public.commercial_secret_resolution_plans
  set plan_status = 'held',
      held_at = clock_timestamp(),
      terminal_reason = 'AUTOMATIC_DISPATCH_DISABLED'
  where id = v_plan.id
  returning * into v_plan;

  v_receipt := public.append_commercial_secret_resolution_receipt(
    v_plan.id, null, 'plan_held', 'held',
    jsonb_build_object(
      'automatic_dispatch_enabled', false,
      'secret_resolution_enabled', false,
      'network_access_enabled', false
    ),
    p_offered_by, v_plan.correlation_id
  );

  perform public.append_commercial_secret_resolution_event(
    'SECRET_RESOLUTION_PLAN_HELD', p_offered_by, v_plan.correlation_id,
    v_policy.id, v_plan.id, null, v_lease.id, null, v_receipt.id,
    'planned', 'held', 'Passive foundation prohibits dispatch',
    v_plan.causation_id, '{}'::jsonb
  );

  return v_lease;
end
$$;

-- =============================================================================
-- 15. BLOCKED ATTEMPT RECORDING
-- =============================================================================

create or replace function public.record_blocked_secret_resolution_attempt(
  p_resolution_plan_id uuid,
  p_resolution_step_id uuid,
  p_recorded_by text,
  p_reason text
)
returns public.commercial_secret_resolution_attempts
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_plan public.commercial_secret_resolution_plans;
  v_policy public.commercial_secret_resolution_policies;
  v_attempt_number integer;
  v_attempt public.commercial_secret_resolution_attempts;
  v_receipt public.commercial_secret_resolution_receipts;
begin
  select * into strict v_plan
  from public.commercial_secret_resolution_plans
  where id = p_resolution_plan_id;

  select * into strict v_policy
  from public.commercial_secret_resolution_policies
  where id = v_plan.orchestrator_policy_id;

  if v_policy.blocked_attempt_recording_enabled is not true then
    raise exception 'COMMERCIAL_SECRET_RESOLUTION_ATTEMPT_RECORDING_DISABLED';
  end if;

  if p_resolution_step_id is not null
     and not exists (
       select 1
       from public.commercial_secret_resolution_steps s
       where s.id = p_resolution_step_id
         and s.resolution_plan_id = v_plan.id
     ) then
    raise exception 'COMMERCIAL_SECRET_RESOLUTION_STEP_PLAN_MISMATCH';
  end if;

  select coalesce(max(attempt_number), 0) + 1
  into v_attempt_number
  from public.commercial_secret_resolution_attempts
  where resolution_plan_id = v_plan.id;

  insert into public.commercial_secret_resolution_attempts (
    resolution_plan_id, resolution_step_id, attempt_number, attempt_status,
    normalized_error_code, retry_class, recorded_by, attempt_metadata
  ) values (
    v_plan.id, p_resolution_step_id, v_attempt_number, 'blocked',
    'SECRET_RESOLUTION_EXECUTION_DISABLED', 'never', btrim(p_recorded_by),
    jsonb_build_object('reason', p_reason, 'passive', true)
  )
  returning * into v_attempt;

  v_receipt := public.append_commercial_secret_resolution_receipt(
    v_plan.id, v_attempt.id, 'execution_blocked', 'blocked',
    jsonb_build_object(
      'reason', p_reason,
      'dispatch_performed', false,
      'backend_contact_performed', false,
      'resolution_performed', false,
      'decryption_performed', false,
      'material_loaded', false,
      'material_delivered', false,
      'network_attempted', false
    ),
    p_recorded_by, v_plan.correlation_id
  );

  perform public.append_commercial_secret_resolution_event(
    'SECRET_RESOLUTION_EXECUTION_BLOCKED', p_recorded_by, v_plan.correlation_id,
    v_policy.id, v_plan.id, p_resolution_step_id, null, v_attempt.id, v_receipt.id,
    null, 'blocked', p_reason, v_plan.causation_id,
    jsonb_build_object('attempt_number', v_attempt.attempt_number)
  );

  return v_attempt;
end
$$;

-- =============================================================================
-- 16. READ MODEL
-- =============================================================================

create or replace view public.commercial_secret_resolution_plan_read_model as
select
  p.id as resolution_plan_id,
  p.plan_key,
  p.idempotency_key,
  p.access_request_id,
  p.orchestrator_policy_id,
  op.policy_code,
  op.environment,
  op.policy_status,
  p.plan_status,
  p.plan_version,
  p.requested_operation,
  p.requested_scopes,
  p.requested_ttl_seconds,
  p.correlation_id,
  p.causation_id,
  p.requested_by,
  p.evaluated_by,
  p.planned_by,
  p.requested_at,
  p.evaluated_at,
  p.planned_at,
  p.held_at,
  p.terminal_reason,
  p.plan_hash,
  coalesce(s.step_count, 0) as step_count,
  coalesce(a.attempt_count, 0) as attempt_count,
  coalesce(r.receipt_count, 0) as receipt_count,
  coalesce(e.event_count, 0) as event_count,
  op.automatic_dispatch_enabled,
  op.secret_backend_contact_enabled,
  op.secret_resolution_enabled,
  op.secret_decryption_enabled,
  op.credential_material_loading_enabled,
  op.credential_delivery_enabled,
  op.network_access_enabled
from public.commercial_secret_resolution_plans p
join public.commercial_secret_resolution_policies op
  on op.id = p.orchestrator_policy_id
left join lateral (
  select count(*)::bigint as step_count
  from public.commercial_secret_resolution_steps x
  where x.resolution_plan_id = p.id
) s on true
left join lateral (
  select count(*)::bigint as attempt_count
  from public.commercial_secret_resolution_attempts x
  where x.resolution_plan_id = p.id
) a on true
left join lateral (
  select count(*)::bigint as receipt_count
  from public.commercial_secret_resolution_receipts x
  where x.resolution_plan_id = p.id
) r on true
left join lateral (
  select count(*)::bigint as event_count
  from public.commercial_secret_resolution_events x
  where x.resolution_plan_id = p.id
) e on true;

comment on view public.commercial_secret_resolution_plan_read_model is
'Operational read model for passive provider-secret resolution orchestration.';

-- =============================================================================
-- 17. FOUNDATION POLICY AND INITIAL EVENT
-- =============================================================================

insert into public.commercial_secret_resolution_policies (
  policy_code,
  environment,
  policy_status,
  policy_version,
  created_by,
  approved_by,
  approved_at,
  policy_metadata
) values (
  'commercial:provider_secret_resolution:v1',
  'production',
  'approved',
  1,
  'MIGRATION_125',
  'MIGRATION_125',
  clock_timestamp(),
  jsonb_build_object(
    'foundation', true,
    'mode', 'passive_hold',
    'secret_material_storage', 'forbidden'
  )
);

select public.append_commercial_secret_resolution_event(
  'SECRET_RESOLUTION_ORCHESTRATOR_INITIALIZED',
  'MIGRATION_125',
  gen_random_uuid(),
  (
    select id
    from public.commercial_secret_resolution_policies
    where policy_code = 'commercial:provider_secret_resolution:v1'
      and environment = 'production'
  ),
  null, null, null, null, null, null, 'approved',
  'Provider secret-resolution orchestrator initialized in passive hold mode',
  null,
  jsonb_build_object(
    'automatic_dispatch_enabled', false,
    'secret_backend_contact_enabled', false,
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

alter table public.commercial_secret_resolution_policies enable row level security;
alter table public.commercial_secret_resolution_plans enable row level security;
alter table public.commercial_secret_resolution_steps enable row level security;
alter table public.commercial_secret_resolution_idempotency enable row level security;
alter table public.commercial_secret_resolution_leases enable row level security;
alter table public.commercial_secret_resolution_attempts enable row level security;
alter table public.commercial_secret_resolution_receipts enable row level security;
alter table public.commercial_secret_resolution_events enable row level security;

revoke all on table public.commercial_secret_resolution_policies from public, anon, authenticated;
revoke all on table public.commercial_secret_resolution_plans from public, anon, authenticated;
revoke all on table public.commercial_secret_resolution_steps from public, anon, authenticated;
revoke all on table public.commercial_secret_resolution_idempotency from public, anon, authenticated;
revoke all on table public.commercial_secret_resolution_leases from public, anon, authenticated;
revoke all on table public.commercial_secret_resolution_attempts from public, anon, authenticated;
revoke all on table public.commercial_secret_resolution_receipts from public, anon, authenticated;
revoke all on table public.commercial_secret_resolution_events from public, anon, authenticated;
revoke all on table public.commercial_secret_resolution_plan_read_model from public, anon, authenticated;

grant select, insert, update, delete on table public.commercial_secret_resolution_policies to service_role;
grant select, insert, update, delete on table public.commercial_secret_resolution_plans to service_role;
grant select, insert, update, delete on table public.commercial_secret_resolution_steps to service_role;
grant select, insert, update, delete on table public.commercial_secret_resolution_idempotency to service_role;
grant select, insert, update, delete on table public.commercial_secret_resolution_leases to service_role;
grant select, insert, update, delete on table public.commercial_secret_resolution_attempts to service_role;
grant select, insert, update, delete on table public.commercial_secret_resolution_receipts to service_role;
grant select, insert, update, delete on table public.commercial_secret_resolution_events to service_role;
grant select on table public.commercial_secret_resolution_plan_read_model to service_role;

revoke all on function public.protect_commercial_secret_resolution_policy() from public, anon, authenticated;
revoke all on function public.protect_commercial_secret_resolution_receipt() from public, anon, authenticated;
revoke all on function public.protect_commercial_secret_resolution_event() from public, anon, authenticated;
revoke all on function public.set_commercial_secret_resolution_updated_at() from public, anon, authenticated;
revoke all on function public.append_commercial_secret_resolution_event(
  text,text,uuid,uuid,uuid,uuid,uuid,uuid,uuid,text,text,text,uuid,jsonb
) from public, anon, authenticated;
revoke all on function public.append_commercial_secret_resolution_receipt(
  uuid,uuid,text,text,jsonb,text,uuid,jsonb
) from public, anon, authenticated;
revoke all on function public.enqueue_commercial_secret_resolution_plan(
  text,text,uuid,text,uuid,uuid,jsonb
) from public, anon, authenticated;
revoke all on function public.evaluate_commercial_secret_resolution_plan(uuid,text)
  from public, anon, authenticated;
revoke all on function public.build_commercial_secret_resolution_plan(uuid,text)
  from public, anon, authenticated;
revoke all on function public.offer_commercial_secret_resolution_lease(uuid,text)
  from public, anon, authenticated;
revoke all on function public.record_blocked_secret_resolution_attempt(uuid,uuid,text,text)
  from public, anon, authenticated;

grant execute on function public.append_commercial_secret_resolution_event(
  text,text,uuid,uuid,uuid,uuid,uuid,uuid,uuid,text,text,text,uuid,jsonb
) to service_role;
grant execute on function public.append_commercial_secret_resolution_receipt(
  uuid,uuid,text,text,jsonb,text,uuid,jsonb
) to service_role;
grant execute on function public.enqueue_commercial_secret_resolution_plan(
  text,text,uuid,text,uuid,uuid,jsonb
) to service_role;
grant execute on function public.evaluate_commercial_secret_resolution_plan(uuid,text)
  to service_role;
grant execute on function public.build_commercial_secret_resolution_plan(uuid,text)
  to service_role;
grant execute on function public.offer_commercial_secret_resolution_lease(uuid,text)
  to service_role;
grant execute on function public.record_blocked_secret_resolution_attempt(uuid,uuid,text,text)
  to service_role;

-- =============================================================================
-- 19. FOUNDATION CERTIFICATION
-- =============================================================================

do $$
declare
  v_policy public.commercial_secret_resolution_policies;
  v_policy_count bigint;
  v_plan_count bigint;
  v_step_count bigint;
  v_idempotency_count bigint;
  v_lease_count bigint;
  v_attempt_count bigint;
  v_receipt_count bigint;
  v_event_count bigint;
begin
  select * into strict v_policy
  from public.commercial_secret_resolution_policies
  where policy_code = 'commercial:provider_secret_resolution:v1'
    and environment = 'production';

  select count(*) into v_policy_count
  from public.commercial_secret_resolution_policies;

  select count(*) into v_plan_count
  from public.commercial_secret_resolution_plans;

  select count(*) into v_step_count
  from public.commercial_secret_resolution_steps;

  select count(*) into v_idempotency_count
  from public.commercial_secret_resolution_idempotency;

  select count(*) into v_lease_count
  from public.commercial_secret_resolution_leases;

  select count(*) into v_attempt_count
  from public.commercial_secret_resolution_attempts;

  select count(*) into v_receipt_count
  from public.commercial_secret_resolution_receipts;

  select count(*) into v_event_count
  from public.commercial_secret_resolution_events;

  if v_policy_count <> 1
     or v_plan_count <> 0
     or v_step_count <> 0
     or v_idempotency_count <> 0
     or v_lease_count <> 0
     or v_attempt_count <> 0
     or v_receipt_count <> 0
     or v_event_count <> 1 then
    raise exception
      'MIGRATION_125_COUNT_ASSERTION_FAILED policy=%, plan=%, step=%, idempotency=%, lease=%, attempt=%, receipt=%, event=%',
      v_policy_count, v_plan_count, v_step_count, v_idempotency_count,
      v_lease_count, v_attempt_count, v_receipt_count, v_event_count;
  end if;

  if v_policy.policy_status <> 'approved'
     or v_policy.orchestration_intake_enabled is not true
     or v_policy.policy_evaluation_enabled is not true
     or v_policy.plan_generation_enabled is not true
     or v_policy.step_planning_enabled is not true
     or v_policy.lease_governance_enabled is not true
     or v_policy.blocked_attempt_recording_enabled is not true then
    raise exception 'MIGRATION_125_PASSIVE_CAPABILITY_ASSERTION_FAILED';
  end if;

  if v_policy.automatic_dispatch_enabled
     or v_policy.secret_backend_contact_enabled
     or v_policy.secret_resolution_enabled
     or v_policy.secret_decryption_enabled
     or v_policy.credential_material_loading_enabled
     or v_policy.credential_delivery_enabled
     or v_policy.network_access_enabled then
    raise exception 'MIGRATION_125_SAFETY_POSTURE_ASSERTION_FAILED';
  end if;

  if to_regprocedure(
    'public.record_blocked_secret_resolution_attempt(uuid,uuid,text,text)'
  ) is null then
    raise exception 'MIGRATION_125_CANONICAL_FUNCTION_ASSERTION_FAILED';
  end if;

  raise notice
    'MIGRATION_125_CERTIFIED policy_count=%, plan_count=%, step_count=%, idempotency_count=%, lease_count=%, attempt_count=%, receipt_count=%, event_count=%, orchestration_intake_enabled=%, policy_evaluation_enabled=%, plan_generation_enabled=%, step_planning_enabled=%, lease_governance_enabled=%, blocked_attempt_recording_enabled=%, automatic_dispatch_enabled=%, secret_backend_contact_enabled=%, secret_resolution_enabled=%, secret_decryption_enabled=%, credential_material_loading_enabled=%, credential_delivery_enabled=%, network_access_enabled=%, plaintext_storage_forbidden=true',
    v_policy_count, v_plan_count, v_step_count, v_idempotency_count,
    v_lease_count, v_attempt_count, v_receipt_count, v_event_count,
    v_policy.orchestration_intake_enabled,
    v_policy.policy_evaluation_enabled,
    v_policy.plan_generation_enabled,
    v_policy.step_planning_enabled,
    v_policy.lease_governance_enabled,
    v_policy.blocked_attempt_recording_enabled,
    v_policy.automatic_dispatch_enabled,
    v_policy.secret_backend_contact_enabled,
    v_policy.secret_resolution_enabled,
    v_policy.secret_decryption_enabled,
    v_policy.credential_material_loading_enabled,
    v_policy.credential_delivery_enabled,
    v_policy.network_access_enabled;
end
$$;

commit;
