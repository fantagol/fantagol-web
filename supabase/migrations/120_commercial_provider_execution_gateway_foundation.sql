-- =============================================================================
-- FANTAGOL
-- Migration: 120_commercial_provider_execution_gateway_foundation.sql
-- Milestone: Commercial Platform - Provider Execution Gateway Foundation
--
-- Purpose:
--   Introduce the provider-independent execution gateway located between the
--   checkout orchestrator and approved provider-adapter bindings.
--
-- Foundation safety posture:
--   - command intake is allowed;
--   - policy evaluation, idempotency and passive lease governance are allowed;
--   - real adapter execution is disabled;
--   - network access is disabled;
--   - credential resolution is disabled;
--   - automatic dispatch is disabled;
--   - callbacks, purchases, wallets and ledger entries are not mutated.
-- =============================================================================

\set ON_ERROR_STOP on

begin;

create extension if not exists pgcrypto with schema extensions;

do $$
begin
  if to_regclass('public.commercial_providers') is null
     or to_regclass('public.commercial_provider_adapter_bindings') is null
     or to_regclass('public.commercial_provider_adapter_operations') is null
     or to_regclass('public.commercial_checkout_sessions') is null
     or to_regclass('public.commercial_checkout_provider_requests') is null then
    raise exception 'MIGRATION_120_REQUIRES_MIGRATIONS_110_115_117';
  end if;
end
$$;

-- =============================================================================
-- 1. EXECUTION GATEWAY POLICIES
-- =============================================================================

create table public.commercial_provider_execution_policies (
  id uuid primary key default gen_random_uuid(),
  policy_code text not null,
  version_number integer not null,
  policy_status text not null default 'draft',
  environment text not null default 'test',

  command_intake_enabled boolean not null default true,
  policy_evaluation_enabled boolean not null default true,
  idempotency_enforcement_enabled boolean not null default true,
  lease_governance_enabled boolean not null default true,
  rate_limit_governance_enabled boolean not null default true,

  automatic_dispatch_enabled boolean not null default false,
  adapter_execution_enabled boolean not null default false,
  network_access_enabled boolean not null default false,
  credential_resolution_enabled boolean not null default false,

  maximum_attempts integer not null default 3,
  lease_duration_seconds integer not null default 60,
  command_timeout_ms integer not null default 15000,
  rate_limit_window_seconds integer not null default 60,
  rate_limit_max_commands integer not null default 30,

  configuration jsonb not null default '{}'::jsonb,
  content_hash text not null,
  created_by text not null,
  approved_by text,
  approved_at timestamptz,
  retired_at timestamptz,
  created_at timestamptz not null default clock_timestamp(),

  constraint comm_provider_exec_policies_unique
    unique (policy_code, version_number, environment),

  constraint comm_provider_exec_policies_code_check
    check (
      policy_code = upper(policy_code)
      and policy_code ~ '^[A-Z][A-Z0-9_]{2,95}$'
    ),

  constraint comm_provider_exec_policies_version_check
    check (version_number > 0),

  constraint comm_provider_exec_policies_status_check
    check (policy_status in ('draft','approved','retired')),

  constraint comm_provider_exec_policies_environment_check
    check (environment in ('test','production')),

  constraint comm_provider_exec_policies_limits_check
    check (
      maximum_attempts between 1 and 20
      and lease_duration_seconds between 5 and 3600
      and command_timeout_ms between 1000 and 120000
      and rate_limit_window_seconds between 1 and 86400
      and rate_limit_max_commands between 1 and 100000
    ),

  constraint comm_provider_exec_policies_json_check
    check (jsonb_typeof(configuration) = 'object'),

  constraint comm_provider_exec_policies_hash_check
    check (content_hash ~ '^[a-f0-9]{64}$'),

  constraint comm_provider_exec_policies_actor_check
    check (length(btrim(created_by)) between 1 and 160),

  constraint comm_provider_exec_policies_approval_check
    check (
      (policy_status = 'draft' and approved_at is null and approved_by is null)
      or
      (policy_status <> 'draft' and approved_at is not null and approved_by is not null)
    ),

  constraint comm_provider_exec_policies_foundation_hold_check
    check (
      automatic_dispatch_enabled = false
      and adapter_execution_enabled = false
      and network_access_enabled = false
      and credential_resolution_enabled = false
    )
);

create unique index comm_provider_exec_policies_one_approved_idx
  on public.commercial_provider_execution_policies(policy_code, environment)
  where policy_status = 'approved';

comment on table public.commercial_provider_execution_policies is
'Versioned governance for provider execution commands. Migration 120 structurally disables adapter execution, network access, credential resolution and automatic dispatch.';

-- =============================================================================
-- 2. CANONICAL EXECUTION COMMANDS
-- =============================================================================

create table public.commercial_provider_execution_commands (
  id uuid primary key default gen_random_uuid(),
  command_key text not null unique,
  idempotency_key text not null unique,

  provider_id uuid not null,
  adapter_binding_id uuid not null,
  adapter_operation_id uuid not null,
  execution_policy_id uuid not null,

  checkout_session_id uuid,
  checkout_provider_request_id uuid,

  command_type text not null,
  command_status text not null default 'received',
  environment text not null default 'test',
  priority smallint not null default 100,

  request_envelope jsonb not null,
  request_hash text not null,

  correlation_id uuid not null default gen_random_uuid(),
  causation_id uuid,
  requested_by text not null,
  requested_at timestamptz not null default clock_timestamp(),
  eligible_at timestamptz not null default clock_timestamp(),

  evaluated_at timestamptz,
  held_at timestamptz,
  completed_at timestamptz,
  cancelled_at timestamptz,

  terminal_reason text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),

  constraint comm_provider_exec_commands_provider_fkey
    foreign key (provider_id)
    references public.commercial_providers(id)
    on delete restrict,

  constraint comm_provider_exec_commands_binding_fkey
    foreign key (adapter_binding_id)
    references public.commercial_provider_adapter_bindings(id)
    on delete restrict,

  constraint comm_provider_exec_commands_operation_fkey
    foreign key (adapter_operation_id)
    references public.commercial_provider_adapter_operations(id)
    on delete restrict,

  constraint comm_provider_exec_commands_policy_fkey
    foreign key (execution_policy_id)
    references public.commercial_provider_execution_policies(id)
    on delete restrict,

  constraint comm_provider_exec_commands_session_fkey
    foreign key (checkout_session_id)
    references public.commercial_checkout_sessions(id)
    on delete restrict,

  constraint comm_provider_exec_commands_request_fkey
    foreign key (checkout_provider_request_id)
    references public.commercial_checkout_provider_requests(id)
    on delete restrict,

  constraint comm_provider_exec_commands_key_check
    check (
      command_key = lower(command_key)
      and command_key ~ '^[a-z][a-z0-9:_-]{7,159}$'
      and length(idempotency_key) between 8 and 240
    ),

  constraint comm_provider_exec_commands_type_check
    check (command_type in (
      'create_checkout',
      'retrieve_checkout',
      'cancel_checkout',
      'verify_callback',
      'normalize_callback',
      'reconcile_checkout',
      'generic'
    )),

  constraint comm_provider_exec_commands_status_check
    check (command_status in (
      'received',
      'evaluated',
      'held',
      'lease_ready',
      'claimed',
      'dispatching',
      'succeeded',
      'failed',
      'cancelled'
    )),

  constraint comm_provider_exec_commands_environment_check
    check (environment in ('test','production')),

  constraint comm_provider_exec_commands_priority_check
    check (priority between 1 and 1000),

  constraint comm_provider_exec_commands_payload_check
    check (
      jsonb_typeof(request_envelope) = 'object'
      and jsonb_typeof(metadata) = 'object'
      and request_hash ~ '^[a-f0-9]{64}$'
    ),

  constraint comm_provider_exec_commands_actor_check
    check (length(btrim(requested_by)) between 1 and 160),

  constraint comm_provider_exec_commands_terminal_check
    check (
      (command_status in ('succeeded','failed','cancelled') and completed_at is not null)
      or
      (command_status not in ('succeeded','failed','cancelled'))
    ),

  constraint comm_provider_exec_commands_foundation_hold_check
    check (command_status in ('received','evaluated','held','cancelled'))
);

create index comm_provider_exec_commands_queue_idx
  on public.commercial_provider_execution_commands
  (command_status, priority, eligible_at, requested_at);

create index comm_provider_exec_commands_provider_idx
  on public.commercial_provider_execution_commands
  (provider_id, requested_at desc);

create index comm_provider_exec_commands_correlation_idx
  on public.commercial_provider_execution_commands
  (correlation_id, requested_at, id);

comment on table public.commercial_provider_execution_commands is
'Canonical provider execution command intake. Migration 120 permits evaluation and hold only; claim and dispatch states are structurally blocked.';

-- =============================================================================
-- 3. IDEMPOTENCY REGISTRY
-- =============================================================================

create table public.commercial_provider_execution_idempotency (
  id uuid primary key default gen_random_uuid(),
  idempotency_key text not null unique,
  command_id uuid not null unique,
  request_hash text not null,
  registry_status text not null default 'reserved',
  first_seen_at timestamptz not null default clock_timestamp(),
  last_seen_at timestamptz not null default clock_timestamp(),
  duplicate_count bigint not null default 0,
  metadata jsonb not null default '{}'::jsonb,

  constraint comm_provider_exec_idempotency_command_fkey
    foreign key (command_id)
    references public.commercial_provider_execution_commands(id)
    on delete restrict,

  constraint comm_provider_exec_idempotency_key_check
    check (length(idempotency_key) between 8 and 240),

  constraint comm_provider_exec_idempotency_hash_check
    check (request_hash ~ '^[a-f0-9]{64}$'),

  constraint comm_provider_exec_idempotency_status_check
    check (registry_status in ('reserved','completed','conflicted','retired')),

  constraint comm_provider_exec_idempotency_count_check
    check (duplicate_count >= 0),

  constraint comm_provider_exec_idempotency_json_check
    check (jsonb_typeof(metadata) = 'object')
);

comment on table public.commercial_provider_execution_idempotency is
'Canonical idempotency ownership for provider execution commands.';

-- =============================================================================
-- 4. PASSIVE RATE-LIMIT WINDOWS
-- =============================================================================

create table public.commercial_provider_execution_rate_windows (
  id uuid primary key default gen_random_uuid(),
  provider_id uuid not null,
  execution_policy_id uuid not null,
  window_started_at timestamptz not null,
  window_ends_at timestamptz not null,
  observed_command_count integer not null default 0,
  allowed_command_count integer not null,
  window_status text not null default 'open',
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),

  constraint comm_provider_exec_rate_provider_fkey
    foreign key (provider_id)
    references public.commercial_providers(id)
    on delete restrict,

  constraint comm_provider_exec_rate_policy_fkey
    foreign key (execution_policy_id)
    references public.commercial_provider_execution_policies(id)
    on delete restrict,

  constraint comm_provider_exec_rate_unique
    unique (provider_id, execution_policy_id, window_started_at),

  constraint comm_provider_exec_rate_time_check
    check (window_ends_at > window_started_at),

  constraint comm_provider_exec_rate_count_check
    check (
      observed_command_count >= 0
      and allowed_command_count > 0
    ),

  constraint comm_provider_exec_rate_status_check
    check (window_status in ('open','limited','closed')),

  constraint comm_provider_exec_rate_json_check
    check (jsonb_typeof(metadata) = 'object')
);

create index comm_provider_exec_rate_lookup_idx
  on public.commercial_provider_execution_rate_windows
  (provider_id, window_ends_at desc);

comment on table public.commercial_provider_execution_rate_windows is
'Passive provider command rate accounting. It does not initiate or authorize dispatch.';

-- =============================================================================
-- 5. LEASE GOVERNANCE
-- =============================================================================

create table public.commercial_provider_execution_leases (
  id uuid primary key default gen_random_uuid(),
  command_id uuid not null,
  lease_token uuid not null default gen_random_uuid(),
  lease_status text not null default 'offered',
  worker_key text,
  offered_at timestamptz not null default clock_timestamp(),
  claimed_at timestamptz,
  expires_at timestamptz not null,
  released_at timestamptz,
  release_reason text,
  metadata jsonb not null default '{}'::jsonb,

  constraint comm_provider_exec_leases_command_fkey
    foreign key (command_id)
    references public.commercial_provider_execution_commands(id)
    on delete restrict,

  constraint comm_provider_exec_leases_token_unique
    unique (lease_token),

  constraint comm_provider_exec_leases_status_check
    check (lease_status in ('offered','claimed','released','expired','revoked')),

  constraint comm_provider_exec_leases_time_check
    check (expires_at > offered_at),

  constraint comm_provider_exec_leases_claim_check
    check (
      (lease_status = 'claimed' and claimed_at is not null and worker_key is not null)
      or
      (lease_status <> 'claimed')
    ),

  constraint comm_provider_exec_leases_json_check
    check (jsonb_typeof(metadata) = 'object'),

  constraint comm_provider_exec_leases_foundation_hold_check
    check (lease_status in ('offered','released','expired','revoked'))
);

create unique index comm_provider_exec_one_open_lease_idx
  on public.commercial_provider_execution_leases(command_id)
  where lease_status in ('offered','claimed');

comment on table public.commercial_provider_execution_leases is
'Lease governance boundary. Migration 120 may record passive offers but structurally forbids claimed leases.';

-- =============================================================================
-- 6. DISPATCH ATTEMPTS
-- =============================================================================

create table public.commercial_provider_execution_attempts (
  id uuid primary key default gen_random_uuid(),
  command_id uuid not null,
  lease_id uuid,
  attempt_number integer not null,
  attempt_status text not null default 'planned',

  adapter_execution_requested boolean not null default false,
  credentials_resolved boolean not null default false,
  network_requested boolean not null default false,
  network_performed boolean not null default false,

  started_at timestamptz,
  finished_at timestamptz,
  normalized_error_code text,
  retry_class text,
  response_envelope jsonb,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp(),

  constraint comm_provider_exec_attempts_command_fkey
    foreign key (command_id)
    references public.commercial_provider_execution_commands(id)
    on delete restrict,

  constraint comm_provider_exec_attempts_lease_fkey
    foreign key (lease_id)
    references public.commercial_provider_execution_leases(id)
    on delete restrict,

  constraint comm_provider_exec_attempts_unique
    unique (command_id, attempt_number),

  constraint comm_provider_exec_attempts_number_check
    check (attempt_number > 0),

  constraint comm_provider_exec_attempts_status_check
    check (attempt_status in (
      'planned','blocked','started','succeeded','failed','abandoned'
    )),

  constraint comm_provider_exec_attempts_retry_check
    check (
      retry_class is null
      or retry_class in ('never','immediate','backoff','manual')
    ),

  constraint comm_provider_exec_attempts_json_check
    check (
      response_envelope is null
      or jsonb_typeof(response_envelope) = 'object'
    ),

  constraint comm_provider_exec_attempts_metadata_check
    check (jsonb_typeof(metadata) = 'object'),

  constraint comm_provider_exec_attempts_foundation_hold_check
    check (
      attempt_status in ('planned','blocked','abandoned')
      and adapter_execution_requested = false
      and credentials_resolved = false
      and network_requested = false
      and network_performed = false
      and started_at is null
    )
);

comment on table public.commercial_provider_execution_attempts is
'Dispatch-attempt audit boundary. Migration 120 can only plan or block attempts and cannot execute adapters or perform network access.';

-- =============================================================================
-- 7. APPEND-ONLY EXECUTION RECEIPTS
-- =============================================================================

create table public.commercial_provider_execution_receipts (
  id uuid primary key default gen_random_uuid(),
  command_id uuid not null,
  attempt_id uuid,
  receipt_type text not null,
  receipt_status text not null,
  provider_reference text,
  normalized_payload jsonb not null default '{}'::jsonb,
  content_hash text not null,
  issued_by text not null,
  issued_at timestamptz not null default clock_timestamp(),
  correlation_id uuid not null,
  metadata jsonb not null default '{}'::jsonb,

  constraint comm_provider_exec_receipts_command_fkey
    foreign key (command_id)
    references public.commercial_provider_execution_commands(id)
    on delete restrict,

  constraint comm_provider_exec_receipts_attempt_fkey
    foreign key (attempt_id)
    references public.commercial_provider_execution_attempts(id)
    on delete restrict,

  constraint comm_provider_exec_receipts_type_check
    check (receipt_type in (
      'policy_decision',
      'idempotency_decision',
      'rate_limit_decision',
      'lease_decision',
      'dispatch_blocked',
      'dispatch_result'
    )),

  constraint comm_provider_exec_receipts_status_check
    check (receipt_status in ('accepted','held','blocked','succeeded','failed')),

  constraint comm_provider_exec_receipts_json_check
    check (
      jsonb_typeof(normalized_payload) = 'object'
      and jsonb_typeof(metadata) = 'object'
    ),

  constraint comm_provider_exec_receipts_hash_check
    check (content_hash ~ '^[a-f0-9]{64}$'),

  constraint comm_provider_exec_receipts_actor_check
    check (length(btrim(issued_by)) between 1 and 160),

  constraint comm_provider_exec_receipts_foundation_hold_check
    check (
      receipt_type <> 'dispatch_result'
      and receipt_status in ('accepted','held','blocked')
    )
);

create index comm_provider_exec_receipts_timeline_idx
  on public.commercial_provider_execution_receipts
  (command_id, issued_at, id);

comment on table public.commercial_provider_execution_receipts is
'Append-only normalized execution evidence. Migration 120 does not allow provider dispatch-result receipts.';

-- =============================================================================
-- 8. APPEND-ONLY GATEWAY EVENTS
-- =============================================================================

create table public.commercial_provider_execution_events (
  id uuid primary key default gen_random_uuid(),
  event_type text not null,
  command_id uuid,
  policy_id uuid,
  provider_id uuid,
  binding_id uuid,
  operation_id uuid,
  lease_id uuid,
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

  constraint comm_provider_exec_events_command_fkey
    foreign key (command_id)
    references public.commercial_provider_execution_commands(id)
    on delete restrict,

  constraint comm_provider_exec_events_policy_fkey
    foreign key (policy_id)
    references public.commercial_provider_execution_policies(id)
    on delete restrict,

  constraint comm_provider_exec_events_provider_fkey
    foreign key (provider_id)
    references public.commercial_providers(id)
    on delete restrict,

  constraint comm_provider_exec_events_binding_fkey
    foreign key (binding_id)
    references public.commercial_provider_adapter_bindings(id)
    on delete restrict,

  constraint comm_provider_exec_events_operation_fkey
    foreign key (operation_id)
    references public.commercial_provider_adapter_operations(id)
    on delete restrict,

  constraint comm_provider_exec_events_lease_fkey
    foreign key (lease_id)
    references public.commercial_provider_execution_leases(id)
    on delete restrict,

  constraint comm_provider_exec_events_attempt_fkey
    foreign key (attempt_id)
    references public.commercial_provider_execution_attempts(id)
    on delete restrict,

  constraint comm_provider_exec_events_receipt_fkey
    foreign key (receipt_id)
    references public.commercial_provider_execution_receipts(id)
    on delete restrict,

  constraint comm_provider_exec_events_type_check
    check (
      event_type = upper(event_type)
      and event_type ~ '^[A-Z][A-Z0-9_]{2,95}$'
    ),

  constraint comm_provider_exec_events_actor_check
    check (length(btrim(actor)) between 1 and 160),

  constraint comm_provider_exec_events_payload_check
    check (jsonb_typeof(payload) = 'object')
);

create index comm_provider_exec_events_timeline_idx
  on public.commercial_provider_execution_events
  (coalesce(command_id, '00000000-0000-0000-0000-000000000000'::uuid), occurred_at, id);

comment on table public.commercial_provider_execution_events is
'Append-only provider execution gateway timeline.';

-- =============================================================================
-- 9. PROTECTION / UPDATED-AT TRIGGERS
-- =============================================================================

create or replace function public.protect_commercial_provider_execution_policy_internal()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if old.policy_status in ('approved','retired') then
    raise exception using
      errcode = '55000',
      message = 'COMMERCIAL_PROVIDER_EXECUTION_POLICY_IMMUTABLE';
  end if;

  return new;
end
$$;

create or replace function public.protect_commercial_provider_execution_event_internal()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  raise exception using
    errcode = '55000',
    message = 'COMMERCIAL_PROVIDER_EXECUTION_EVENT_APPEND_ONLY';
end
$$;

create or replace function public.protect_commercial_provider_execution_receipt_internal()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  raise exception using
    errcode = '55000',
    message = 'COMMERCIAL_PROVIDER_EXECUTION_RECEIPT_APPEND_ONLY';
end
$$;

create or replace function public.set_commercial_provider_execution_updated_at_internal()
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

create trigger commercial_provider_execution_policies_protect
before update or delete on public.commercial_provider_execution_policies
for each row execute function public.protect_commercial_provider_execution_policy_internal();

create trigger commercial_provider_execution_events_protect
before update or delete on public.commercial_provider_execution_events
for each row execute function public.protect_commercial_provider_execution_event_internal();

create trigger commercial_provider_execution_receipts_protect
before update or delete on public.commercial_provider_execution_receipts
for each row execute function public.protect_commercial_provider_execution_receipt_internal();

create trigger commercial_provider_execution_commands_set_updated_at
before update on public.commercial_provider_execution_commands
for each row execute function public.set_commercial_provider_execution_updated_at_internal();

create trigger commercial_provider_execution_rate_windows_set_updated_at
before update on public.commercial_provider_execution_rate_windows
for each row execute function public.set_commercial_provider_execution_updated_at_internal();

-- =============================================================================
-- 10. INTERNAL EVENT APPEND
-- =============================================================================

create or replace function public.append_commercial_provider_execution_event_internal(
  p_event_type text,
  p_actor text,
  p_correlation_id uuid,
  p_command_id uuid default null,
  p_policy_id uuid default null,
  p_provider_id uuid default null,
  p_binding_id uuid default null,
  p_operation_id uuid default null,
  p_lease_id uuid default null,
  p_attempt_id uuid default null,
  p_receipt_id uuid default null,
  p_previous_status text default null,
  p_new_status text default null,
  p_reason text default null,
  p_causation_id uuid default null,
  p_payload jsonb default '{}'::jsonb
)
returns public.commercial_provider_execution_events
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_result public.commercial_provider_execution_events;
begin
  insert into public.commercial_provider_execution_events (
    event_type,
    command_id,
    policy_id,
    provider_id,
    binding_id,
    operation_id,
    lease_id,
    attempt_id,
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
    p_command_id,
    p_policy_id,
    p_provider_id,
    p_binding_id,
    p_operation_id,
    p_lease_id,
    p_attempt_id,
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
-- 11. COMMAND INTAKE WITH IDEMPOTENCY
-- =============================================================================

create or replace function public.enqueue_commercial_provider_execution_command_internal(
  p_command_key text,
  p_idempotency_key text,
  p_provider_id uuid,
  p_adapter_binding_id uuid,
  p_adapter_operation_id uuid,
  p_execution_policy_id uuid,
  p_command_type text,
  p_request_envelope jsonb,
  p_requested_by text,
  p_checkout_session_id uuid default null,
  p_checkout_provider_request_id uuid default null,
  p_priority smallint default 100,
  p_correlation_id uuid default gen_random_uuid(),
  p_causation_id uuid default null,
  p_metadata jsonb default '{}'::jsonb
)
returns public.commercial_provider_execution_commands
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_policy public.commercial_provider_execution_policies;
  v_binding public.commercial_provider_adapter_bindings;
  v_operation public.commercial_provider_adapter_operations;
  v_existing public.commercial_provider_execution_commands;
  v_result public.commercial_provider_execution_commands;
  v_request_hash text;
begin
  select * into strict v_policy
  from public.commercial_provider_execution_policies
  where id = p_execution_policy_id;

  if v_policy.policy_status <> 'approved'
     or v_policy.command_intake_enabled is not true then
    raise exception 'COMMERCIAL_PROVIDER_EXECUTION_COMMAND_INTAKE_DISABLED';
  end if;

  select * into strict v_binding
  from public.commercial_provider_adapter_bindings
  where id = p_adapter_binding_id;

  if v_binding.provider_id <> p_provider_id
     or v_binding.binding_status not in ('validated','activation_requested')
     or v_binding.readiness_status <> 'ready' then
    raise exception 'COMMERCIAL_PROVIDER_EXECUTION_BINDING_NOT_READY';
  end if;

  select * into strict v_operation
  from public.commercial_provider_adapter_operations
  where id = p_adapter_operation_id;

  if v_operation.adapter_version_id <> v_binding.adapter_version_id
     or v_operation.operation_status <> 'certified' then
    raise exception 'COMMERCIAL_PROVIDER_EXECUTION_OPERATION_NOT_CERTIFIED';
  end if;

  v_request_hash :=
    encode(
      extensions.digest(coalesce(p_request_envelope, '{}'::jsonb)::text, 'sha256'),
      'hex'
    );

  select *
  into v_existing
  from public.commercial_provider_execution_commands
  where idempotency_key = btrim(p_idempotency_key);

  if found then
    update public.commercial_provider_execution_idempotency
    set
      last_seen_at = clock_timestamp(),
      duplicate_count = duplicate_count + 1,
      registry_status =
        case
          when request_hash = v_request_hash then registry_status
          else 'conflicted'
        end
    where command_id = v_existing.id;

    if v_existing.request_hash <> v_request_hash then
      raise exception 'COMMERCIAL_PROVIDER_EXECUTION_IDEMPOTENCY_CONFLICT';
    end if;

    return v_existing;
  end if;

  insert into public.commercial_provider_execution_commands (
    command_key,
    idempotency_key,
    provider_id,
    adapter_binding_id,
    adapter_operation_id,
    execution_policy_id,
    checkout_session_id,
    checkout_provider_request_id,
    command_type,
    command_status,
    environment,
    priority,
    request_envelope,
    request_hash,
    correlation_id,
    causation_id,
    requested_by,
    metadata
  ) values (
    lower(btrim(p_command_key)),
    btrim(p_idempotency_key),
    p_provider_id,
    p_adapter_binding_id,
    p_adapter_operation_id,
    p_execution_policy_id,
    p_checkout_session_id,
    p_checkout_provider_request_id,
    lower(btrim(p_command_type)),
    'received',
    v_policy.environment,
    p_priority,
    coalesce(p_request_envelope, '{}'::jsonb),
    v_request_hash,
    p_correlation_id,
    p_causation_id,
    btrim(p_requested_by),
    coalesce(p_metadata, '{}'::jsonb)
  )
  returning * into v_result;

  insert into public.commercial_provider_execution_idempotency (
    idempotency_key,
    command_id,
    request_hash,
    registry_status,
    metadata
  ) values (
    v_result.idempotency_key,
    v_result.id,
    v_result.request_hash,
    'reserved',
    jsonb_build_object('source', 'execution_gateway')
  );

  perform public.append_commercial_provider_execution_event_internal(
    'EXECUTION_COMMAND_RECEIVED',
    p_requested_by,
    v_result.correlation_id,
    v_result.id,
    v_result.execution_policy_id,
    v_result.provider_id,
    v_result.adapter_binding_id,
    v_result.adapter_operation_id,
    null,
    null,
    null,
    null,
    'received',
    'Canonical provider execution command accepted',
    p_causation_id,
    jsonb_build_object(
      'command_key', v_result.command_key,
      'command_type', v_result.command_type,
      'request_hash', v_result.request_hash
    )
  );

  return v_result;
end
$$;

-- =============================================================================
-- 12. PASSIVE POLICY EVALUATION
-- =============================================================================

create or replace function public.evaluate_commercial_provider_execution_command_internal(
  p_command_id uuid,
  p_evaluated_by text
)
returns public.commercial_provider_execution_commands
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_command public.commercial_provider_execution_commands;
  v_policy public.commercial_provider_execution_policies;
  v_binding public.commercial_provider_adapter_bindings;
  v_receipt public.commercial_provider_execution_receipts;
  v_payload jsonb;
  v_hash text;
begin
  select * into strict v_command
  from public.commercial_provider_execution_commands
  where id = p_command_id
  for update;

  if v_command.command_status <> 'received' then
    return v_command;
  end if;

  select * into strict v_policy
  from public.commercial_provider_execution_policies
  where id = v_command.execution_policy_id;

  select * into strict v_binding
  from public.commercial_provider_adapter_bindings
  where id = v_command.adapter_binding_id;

  v_payload := jsonb_build_object(
    'policy_status', v_policy.policy_status,
    'binding_status', v_binding.binding_status,
    'binding_readiness_status', v_binding.readiness_status,
    'automatic_dispatch_enabled', v_policy.automatic_dispatch_enabled,
    'adapter_execution_enabled', v_policy.adapter_execution_enabled,
    'network_access_enabled', v_policy.network_access_enabled,
    'credential_resolution_enabled', v_policy.credential_resolution_enabled,
    'decision', 'hold',
    'reason', 'FOUNDATION_EXECUTION_DISABLED'
  );

  v_hash := encode(extensions.digest(v_payload::text, 'sha256'), 'hex');

  insert into public.commercial_provider_execution_receipts (
    command_id,
    receipt_type,
    receipt_status,
    normalized_payload,
    content_hash,
    issued_by,
    correlation_id,
    metadata
  ) values (
    v_command.id,
    'policy_decision',
    'held',
    v_payload,
    v_hash,
    btrim(p_evaluated_by),
    v_command.correlation_id,
    jsonb_build_object('foundation', 'MIGRATION_120')
  )
  returning * into v_receipt;

  update public.commercial_provider_execution_commands
  set
    command_status = 'held',
    evaluated_at = clock_timestamp(),
    held_at = clock_timestamp(),
    terminal_reason = 'FOUNDATION_EXECUTION_DISABLED'
  where id = v_command.id
  returning * into v_command;

  perform public.append_commercial_provider_execution_event_internal(
    'EXECUTION_COMMAND_HELD',
    p_evaluated_by,
    v_command.correlation_id,
    v_command.id,
    v_command.execution_policy_id,
    v_command.provider_id,
    v_command.adapter_binding_id,
    v_command.adapter_operation_id,
    null,
    null,
    v_receipt.id,
    'received',
    'held',
    'FOUNDATION_EXECUTION_DISABLED',
    v_command.causation_id,
    v_payload
  );

  return v_command;
end
$$;

-- =============================================================================
-- 13. PASSIVE LEASE OFFER
-- =============================================================================

create or replace function public.offer_commercial_provider_execution_lease_internal(
  p_command_id uuid,
  p_offered_by text
)
returns public.commercial_provider_execution_leases
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_command public.commercial_provider_execution_commands;
  v_policy public.commercial_provider_execution_policies;
  v_result public.commercial_provider_execution_leases;
begin
  select * into strict v_command
  from public.commercial_provider_execution_commands
  where id = p_command_id
  for update;

  select * into strict v_policy
  from public.commercial_provider_execution_policies
  where id = v_command.execution_policy_id;

  if v_command.command_status <> 'held'
     or v_policy.lease_governance_enabled is not true then
    raise exception 'COMMERCIAL_PROVIDER_EXECUTION_LEASE_NOT_OFFERABLE';
  end if;

  insert into public.commercial_provider_execution_leases (
    command_id,
    lease_status,
    offered_at,
    expires_at,
    metadata
  ) values (
    v_command.id,
    'offered',
    clock_timestamp(),
    clock_timestamp() + make_interval(secs => v_policy.lease_duration_seconds),
    jsonb_build_object(
      'offered_by', btrim(p_offered_by),
      'claim_enabled', false
    )
  )
  returning * into v_result;

  perform public.append_commercial_provider_execution_event_internal(
    'EXECUTION_LEASE_OFFERED',
    p_offered_by,
    v_command.correlation_id,
    v_command.id,
    v_command.execution_policy_id,
    v_command.provider_id,
    v_command.adapter_binding_id,
    v_command.adapter_operation_id,
    v_result.id,
    null,
    null,
    null,
    'offered',
    'Passive lease recorded; claim remains disabled',
    v_command.causation_id,
    jsonb_build_object(
      'lease_token', v_result.lease_token,
      'expires_at', v_result.expires_at,
      'claim_enabled', false
    )
  );

  return v_result;
end
$$;

-- =============================================================================
-- 14. PASSIVE BLOCKED ATTEMPT
-- =============================================================================

create or replace function public.record_blocked_commercial_provider_execution_attempt_internal(
  p_command_id uuid,
  p_lease_id uuid,
  p_recorded_by text,
  p_reason text default 'FOUNDATION_EXECUTION_DISABLED'
)
returns public.commercial_provider_execution_attempts
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_command public.commercial_provider_execution_commands;
  v_next_attempt integer;
  v_attempt public.commercial_provider_execution_attempts;
  v_receipt public.commercial_provider_execution_receipts;
  v_payload jsonb;
begin
  select * into strict v_command
  from public.commercial_provider_execution_commands
  where id = p_command_id;

  if v_command.command_status <> 'held' then
    raise exception 'COMMERCIAL_PROVIDER_EXECUTION_ATTEMPT_NOT_RECORDABLE';
  end if;

  select coalesce(max(attempt_number), 0) + 1
  into v_next_attempt
  from public.commercial_provider_execution_attempts
  where command_id = p_command_id;

  insert into public.commercial_provider_execution_attempts (
    command_id,
    lease_id,
    attempt_number,
    attempt_status,
    adapter_execution_requested,
    credentials_resolved,
    network_requested,
    network_performed,
    normalized_error_code,
    retry_class,
    metadata
  ) values (
    p_command_id,
    p_lease_id,
    v_next_attempt,
    'blocked',
    false,
    false,
    false,
    false,
    'COMMERCIAL_PROVIDER_EXECUTION_DISABLED',
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
    'adapter_execution_requested', false,
    'credentials_resolved', false,
    'network_requested', false,
    'network_performed', false
  );

  insert into public.commercial_provider_execution_receipts (
    command_id,
    attempt_id,
    receipt_type,
    receipt_status,
    normalized_payload,
    content_hash,
    issued_by,
    correlation_id,
    metadata
  ) values (
    v_command.id,
    v_attempt.id,
    'dispatch_blocked',
    'blocked',
    v_payload,
    encode(extensions.digest(v_payload::text, 'sha256'), 'hex'),
    btrim(p_recorded_by),
    v_command.correlation_id,
    jsonb_build_object('foundation', 'MIGRATION_120')
  )
  returning * into v_receipt;

  perform public.append_commercial_provider_execution_event_internal(
    'EXECUTION_ATTEMPT_BLOCKED',
    p_recorded_by,
    v_command.correlation_id,
    v_command.id,
    v_command.execution_policy_id,
    v_command.provider_id,
    v_command.adapter_binding_id,
    v_command.adapter_operation_id,
    p_lease_id,
    v_attempt.id,
    v_receipt.id,
    null,
    'blocked',
    p_reason,
    v_command.causation_id,
    v_payload
  );

  return v_attempt;
end
$$;

-- =============================================================================
-- 15. READ MODEL
-- =============================================================================

create or replace function public.get_commercial_provider_execution_command_internal(
  p_command_id uuid
)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'command', to_jsonb(c),
    'idempotency', (
      select to_jsonb(i)
      from public.commercial_provider_execution_idempotency i
      where i.command_id = c.id
    ),
    'leases', coalesce((
      select jsonb_agg(to_jsonb(l) order by l.offered_at, l.id)
      from public.commercial_provider_execution_leases l
      where l.command_id = c.id
    ), '[]'::jsonb),
    'attempts', coalesce((
      select jsonb_agg(to_jsonb(a) order by a.attempt_number, a.id)
      from public.commercial_provider_execution_attempts a
      where a.command_id = c.id
    ), '[]'::jsonb),
    'receipts', coalesce((
      select jsonb_agg(to_jsonb(r) order by r.issued_at, r.id)
      from public.commercial_provider_execution_receipts r
      where r.command_id = c.id
    ), '[]'::jsonb),
    'events', coalesce((
      select jsonb_agg(to_jsonb(e) order by e.occurred_at, e.id)
      from public.commercial_provider_execution_events e
      where e.command_id = c.id
    ), '[]'::jsonb)
  )
  from public.commercial_provider_execution_commands c
  where c.id = p_command_id
$$;

-- =============================================================================
-- 16. DEFAULT PASSIVE POLICY AND FOUNDATION EVENT
-- =============================================================================

with policy_snapshot as (
  select jsonb_build_object(
    'policy_code', 'DEFAULT_PROVIDER_EXECUTION_GATEWAY',
    'version_number', 1,
    'environment', 'test',
    'command_intake_enabled', true,
    'policy_evaluation_enabled', true,
    'idempotency_enforcement_enabled', true,
    'lease_governance_enabled', true,
    'rate_limit_governance_enabled', true,
    'automatic_dispatch_enabled', false,
    'adapter_execution_enabled', false,
    'network_access_enabled', false,
    'credential_resolution_enabled', false,
    'maximum_attempts', 3,
    'lease_duration_seconds', 60,
    'command_timeout_ms', 15000,
    'rate_limit_window_seconds', 60,
    'rate_limit_max_commands', 30
  ) as payload
)
insert into public.commercial_provider_execution_policies (
  policy_code,
  version_number,
  policy_status,
  environment,
  command_intake_enabled,
  policy_evaluation_enabled,
  idempotency_enforcement_enabled,
  lease_governance_enabled,
  rate_limit_governance_enabled,
  automatic_dispatch_enabled,
  adapter_execution_enabled,
  network_access_enabled,
  credential_resolution_enabled,
  maximum_attempts,
  lease_duration_seconds,
  command_timeout_ms,
  rate_limit_window_seconds,
  rate_limit_max_commands,
  configuration,
  content_hash,
  created_by
)
select
  'DEFAULT_PROVIDER_EXECUTION_GATEWAY',
  1,
  'draft',
  'test',
  true,
  true,
  true,
  true,
  true,
  false,
  false,
  false,
  false,
  3,
  60,
  15000,
  60,
  30,
  jsonb_build_object(
    'foundation', 'MIGRATION_120',
    'dispatch_mode', 'passive_hold'
  ),
  encode(extensions.digest(payload::text, 'sha256'), 'hex'),
  'MIGRATION_120'
from policy_snapshot;

select public.append_commercial_provider_execution_event_internal(
  'EXECUTION_GATEWAY_FOUNDATION_INITIALIZED',
  'MIGRATION_120',
  gen_random_uuid(),
  null,
  (
    select id
    from public.commercial_provider_execution_policies
    where policy_code = 'DEFAULT_PROVIDER_EXECUTION_GATEWAY'
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
  'Provider execution gateway initialized in passive hold mode',
  null,
  jsonb_build_object(
    'automatic_dispatch_enabled', false,
    'adapter_execution_enabled', false,
    'network_access_enabled', false,
    'credential_resolution_enabled', false
  )
);

-- =============================================================================
-- 17. RLS / PRIVILEGES
-- =============================================================================

alter table public.commercial_provider_execution_policies enable row level security;
alter table public.commercial_provider_execution_commands enable row level security;
alter table public.commercial_provider_execution_idempotency enable row level security;
alter table public.commercial_provider_execution_rate_windows enable row level security;
alter table public.commercial_provider_execution_leases enable row level security;
alter table public.commercial_provider_execution_attempts enable row level security;
alter table public.commercial_provider_execution_receipts enable row level security;
alter table public.commercial_provider_execution_events enable row level security;

revoke all on table public.commercial_provider_execution_policies from public, anon, authenticated;
revoke all on table public.commercial_provider_execution_commands from public, anon, authenticated;
revoke all on table public.commercial_provider_execution_idempotency from public, anon, authenticated;
revoke all on table public.commercial_provider_execution_rate_windows from public, anon, authenticated;
revoke all on table public.commercial_provider_execution_leases from public, anon, authenticated;
revoke all on table public.commercial_provider_execution_attempts from public, anon, authenticated;
revoke all on table public.commercial_provider_execution_receipts from public, anon, authenticated;
revoke all on table public.commercial_provider_execution_events from public, anon, authenticated;

grant select, insert, update on table public.commercial_provider_execution_policies to service_role;
grant select, insert, update on table public.commercial_provider_execution_commands to service_role;
grant select, insert, update on table public.commercial_provider_execution_idempotency to service_role;
grant select, insert, update on table public.commercial_provider_execution_rate_windows to service_role;
grant select, insert, update on table public.commercial_provider_execution_leases to service_role;
grant select, insert on table public.commercial_provider_execution_attempts to service_role;
grant select, insert on table public.commercial_provider_execution_receipts to service_role;
grant select, insert on table public.commercial_provider_execution_events to service_role;

revoke all on function public.append_commercial_provider_execution_event_internal(
  text,text,uuid,uuid,uuid,uuid,uuid,uuid,uuid,uuid,uuid,text,text,text,uuid,jsonb
) from public, anon, authenticated;

revoke all on function public.enqueue_commercial_provider_execution_command_internal(
  text,text,uuid,uuid,uuid,uuid,text,jsonb,text,uuid,uuid,smallint,uuid,uuid,jsonb
) from public, anon, authenticated;

revoke all on function public.evaluate_commercial_provider_execution_command_internal(
  uuid,text
) from public, anon, authenticated;

revoke all on function public.offer_commercial_provider_execution_lease_internal(
  uuid,text
) from public, anon, authenticated;

revoke all on function public.record_blocked_commercial_provider_execution_attempt_internal(
  uuid,uuid,text,text
) from public, anon, authenticated;

revoke all on function public.get_commercial_provider_execution_command_internal(
  uuid
) from public, anon, authenticated;

grant execute on function public.append_commercial_provider_execution_event_internal(
  text,text,uuid,uuid,uuid,uuid,uuid,uuid,uuid,uuid,uuid,text,text,text,uuid,jsonb
) to service_role;

grant execute on function public.enqueue_commercial_provider_execution_command_internal(
  text,text,uuid,uuid,uuid,uuid,text,jsonb,text,uuid,uuid,smallint,uuid,uuid,jsonb
) to service_role;

grant execute on function public.evaluate_commercial_provider_execution_command_internal(
  uuid,text
) to service_role;

grant execute on function public.offer_commercial_provider_execution_lease_internal(
  uuid,text
) to service_role;

grant execute on function public.record_blocked_commercial_provider_execution_attempt_internal(
  uuid,uuid,text,text
) to service_role;

grant execute on function public.get_commercial_provider_execution_command_internal(
  uuid
) to service_role;

-- =============================================================================
-- 18. CERTIFICATION ASSERTIONS
-- =============================================================================

do $$
declare
  v_policy_count bigint;
  v_command_count bigint;
  v_idempotency_count bigint;
  v_rate_count bigint;
  v_lease_count bigint;
  v_attempt_count bigint;
  v_receipt_count bigint;
  v_event_count bigint;
  v_policy public.commercial_provider_execution_policies;
begin
  select count(*) into v_policy_count
  from public.commercial_provider_execution_policies;

  select count(*) into v_command_count
  from public.commercial_provider_execution_commands;

  select count(*) into v_idempotency_count
  from public.commercial_provider_execution_idempotency;

  select count(*) into v_rate_count
  from public.commercial_provider_execution_rate_windows;

  select count(*) into v_lease_count
  from public.commercial_provider_execution_leases;

  select count(*) into v_attempt_count
  from public.commercial_provider_execution_attempts;

  select count(*) into v_receipt_count
  from public.commercial_provider_execution_receipts;

  select count(*) into v_event_count
  from public.commercial_provider_execution_events;

  select *
  into strict v_policy
  from public.commercial_provider_execution_policies
  where policy_code = 'DEFAULT_PROVIDER_EXECUTION_GATEWAY'
    and version_number = 1
    and environment = 'test';

  if v_policy_count <> 1
     or v_command_count <> 0
     or v_idempotency_count <> 0
     or v_rate_count <> 0
     or v_lease_count <> 0
     or v_attempt_count <> 0
     or v_receipt_count <> 0
     or v_event_count <> 1 then
    raise exception
      'MIGRATION_120_FOUNDATION_COUNT_ASSERTION_FAILED policy=%, command=%, idempotency=%, rate=%, lease=%, attempt=%, receipt=%, event=%',
      v_policy_count,
      v_command_count,
      v_idempotency_count,
      v_rate_count,
      v_lease_count,
      v_attempt_count,
      v_receipt_count,
      v_event_count;
  end if;

  if v_policy.automatic_dispatch_enabled
     or v_policy.adapter_execution_enabled
     or v_policy.network_access_enabled
     or v_policy.credential_resolution_enabled then
    raise exception 'MIGRATION_120_UNSAFE_DEFAULT_POLICY';
  end if;

  raise notice
    'MIGRATION_120_CERTIFIED policy_count=1, command_count=0, idempotency_count=0, rate_window_count=0, lease_count=0, attempt_count=0, receipt_count=0, event_count=1, command_intake_enabled=true, policy_evaluation_enabled=true, idempotency_enforcement_enabled=true, lease_governance_enabled=true, rate_limit_governance_enabled=true, automatic_dispatch_enabled=false, adapter_execution_enabled=false, network_access_enabled=false, credential_resolution_enabled=false';
end
$$;

commit;
