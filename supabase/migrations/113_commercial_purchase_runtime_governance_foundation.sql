-- =============================================================================
-- FANTAGOL
-- Migration: 113_commercial_purchase_runtime_governance_foundation.sql
-- Milestone: Commercial Platform - Purchase Runtime Governance Foundation
--
-- Purpose:
--   - Extend the provider-independent Purchase Engine created by migration 102
--   - Add explicit runtime policy, authorization, execution-attempt, state,
--     outbox and append-only lifecycle governance
--   - Preserve all existing purchase, ledger, wallet and refund contracts
--
-- Safety guarantees:
--   - No purchase is created, confirmed, cancelled, failed or refunded
--   - No provider checkout is created
--   - No payment event is registered or processed
--   - No Premium Pass is credited or debited
--   - No commercial wallet or ledger row is mutated
--   - All runtime execution remains disabled by default
-- =============================================================================

begin;

-- =============================================================================
-- 0. DEPENDENCY AND CONTRACT ASSERTIONS
-- =============================================================================

do $$
begin
  if to_regclass('public.commercial_purchases') is null
     or to_regclass('public.payment_providers') is null
     or to_regclass('public.payment_provider_events') is null
     or to_regclass('public.commercial_products') is null
     or to_regclass('public.commercial_wallets') is null
     or to_regclass('public.commercial_ledger') is null
     or to_regclass('public.premium_pass_definitions') is null
     or to_regclass('public.commercial_product_pass_components') is null then
    raise exception using
      errcode = 'P0001',
      message = 'MIGRATION_113_REQUIRES_PURCHASE_AND_PREMIUM_PASS_FOUNDATIONS';
  end if;

  if not exists (
    select 1
    from information_schema.routines
    where routine_schema = 'public'
      and routine_name = 'confirm_commercial_purchase_internal'
  ) or not exists (
    select 1
    from information_schema.routines
    where routine_schema = 'public'
      and routine_name = 'refund_commercial_purchase_internal'
  ) then
    raise exception 'MIGRATION_113_PURCHASE_ENGINE_RPC_CONTRACT_NOT_FOUND';
  end if;
end;
$$;

-- =============================================================================
-- 1. PURCHASE RUNTIME POLICIES
-- =============================================================================

create table public.commercial_purchase_runtime_policies (
  id uuid primary key default gen_random_uuid(),
  policy_code text not null,
  version_number integer not null,
  policy_status text not null default 'draft',
  environment text not null default 'test',
  automatic_execution_enabled boolean not null default false,
  automatic_confirmation_enabled boolean not null default false,
  automatic_refund_enabled boolean not null default false,
  require_verified_provider_event boolean not null default true,
  max_authorization_attempts integer not null default 3,
  max_execution_attempts integer not null default 5,
  authorization_ttl_seconds integer not null default 900,
  execution_lease_seconds integer not null default 120,
  retry_backoff_seconds integer[] not null default array[30,120,600],
  configuration jsonb not null default '{}'::jsonb,
  policy_hash text not null,
  created_by text not null,
  approved_by text null,
  approved_at timestamptz null,
  retired_at timestamptz null,
  created_at timestamptz not null default clock_timestamp(),

  constraint commercial_purchase_runtime_policies_code_version_key
    unique (policy_code, version_number),
  constraint commercial_purchase_runtime_policies_code_check
    check (
      policy_code = upper(policy_code)
      and policy_code ~ '^[A-Z][A-Z0-9_]{2,63}$'
    ),
  constraint commercial_purchase_runtime_policies_status_check
    check (policy_status in ('draft','approved','retired')),
  constraint commercial_purchase_runtime_policies_environment_check
    check (environment in ('test','production')),
  constraint commercial_purchase_runtime_policies_limits_check
    check (
      max_authorization_attempts between 1 and 20
      and max_execution_attempts between 1 and 50
      and authorization_ttl_seconds between 60 and 86400
      and execution_lease_seconds between 15 and 3600
    ),
  constraint commercial_purchase_runtime_policies_configuration_object_check
    check (jsonb_typeof(configuration) = 'object'),
  constraint commercial_purchase_runtime_policies_hash_check
    check (policy_hash ~ '^[a-f0-9]{32}$'),
  constraint commercial_purchase_runtime_policies_approval_check
    check (
      (policy_status = 'draft' and approved_by is null and approved_at is null)
      or
      (policy_status in ('approved','retired') and approved_by is not null and approved_at is not null)
    ),
  constraint commercial_purchase_runtime_policies_production_safety_check
    check (
      environment <> 'production'
      or (
        policy_status = 'approved'
        and automatic_execution_enabled = false
        and automatic_confirmation_enabled = false
        and automatic_refund_enabled = false
      )
    )
);

create index commercial_purchase_runtime_policies_status_idx
  on public.commercial_purchase_runtime_policies (
    policy_code,
    environment,
    policy_status,
    version_number desc
  );

comment on table public.commercial_purchase_runtime_policies is
  'Immutable versioned governance for purchase-runtime orchestration. Foundation policies keep all automatic financial execution disabled.';

-- =============================================================================
-- 2. PURCHASE AUTHORIZATION RECORDS
-- =============================================================================

create table public.commercial_purchase_authorizations (
  id uuid primary key default gen_random_uuid(),
  purchase_id uuid not null,
  policy_id uuid not null,
  authorization_key text not null,
  authorization_status text not null default 'requested',
  requested_action text not null,
  requested_by text not null,
  decision_by text null,
  decision_reason text null,
  requested_at timestamptz not null default clock_timestamp(),
  expires_at timestamptz not null,
  decided_at timestamptz null,
  correlation_id uuid not null,
  metadata jsonb not null default '{}'::jsonb,

  constraint commercial_purchase_authorizations_purchase_fkey
    foreign key (purchase_id)
    references public.commercial_purchases (id)
    on delete restrict,
  constraint commercial_purchase_authorizations_policy_fkey
    foreign key (policy_id)
    references public.commercial_purchase_runtime_policies (id)
    on delete restrict,
  constraint commercial_purchase_authorizations_key_unique
    unique (authorization_key),
  constraint commercial_purchase_authorizations_key_check
    check (length(trim(authorization_key)) between 8 and 200),
  constraint commercial_purchase_authorizations_status_check
    check (authorization_status in ('requested','approved','rejected','expired','cancelled')),
  constraint commercial_purchase_authorizations_action_check
    check (requested_action in ('attach_checkout','confirm_payment','close_purchase','refund_purchase')),
  constraint commercial_purchase_authorizations_expiry_check
    check (expires_at > requested_at),
  constraint commercial_purchase_authorizations_decision_check
    check (
      (authorization_status = 'requested' and decision_by is null and decided_at is null)
      or
      (authorization_status <> 'requested' and decision_by is not null and decided_at is not null)
    ),
  constraint commercial_purchase_authorizations_metadata_object_check
    check (jsonb_typeof(metadata) = 'object')
);

create index commercial_purchase_authorizations_purchase_idx
  on public.commercial_purchase_authorizations (
    purchase_id,
    authorization_status,
    requested_at desc
  );

create unique index commercial_purchase_authorizations_open_action_uidx
  on public.commercial_purchase_authorizations (purchase_id, requested_action)
  where authorization_status in ('requested','approved');

comment on table public.commercial_purchase_authorizations is
  'Explicit authorization envelope for sensitive purchase-runtime actions. It does not execute the authorized action.';

-- =============================================================================
-- 3. PURCHASE EXECUTION ATTEMPTS
-- =============================================================================

create table public.commercial_purchase_execution_attempts (
  id uuid primary key default gen_random_uuid(),
  purchase_id uuid not null,
  authorization_id uuid null,
  provider_id uuid not null,
  attempt_number integer not null,
  execution_action text not null,
  execution_status text not null default 'planned',
  idempotency_key text not null,
  worker_code text null,
  lease_token uuid null,
  leased_at timestamptz null,
  lease_expires_at timestamptz null,
  started_at timestamptz null,
  completed_at timestamptz null,
  next_retry_at timestamptz null,
  error_code text null,
  error_message text null,
  correlation_id uuid not null,
  causation_id uuid null,
  request_snapshot jsonb not null default '{}'::jsonb,
  response_snapshot jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp(),

  constraint commercial_purchase_execution_attempts_purchase_fkey
    foreign key (purchase_id)
    references public.commercial_purchases (id)
    on delete restrict,
  constraint commercial_purchase_execution_attempts_authorization_fkey
    foreign key (authorization_id)
    references public.commercial_purchase_authorizations (id)
    on delete restrict,
  constraint commercial_purchase_execution_attempts_provider_fkey
    foreign key (provider_id)
    references public.payment_providers (id)
    on delete restrict,
  constraint commercial_purchase_execution_attempts_number_key
    unique (purchase_id, execution_action, attempt_number),
  constraint commercial_purchase_execution_attempts_idempotency_key
    unique (idempotency_key),
  constraint commercial_purchase_execution_attempts_number_check
    check (attempt_number > 0),
  constraint commercial_purchase_execution_attempts_action_check
    check (execution_action in ('attach_checkout','confirm_payment','close_purchase','refund_purchase')),
  constraint commercial_purchase_execution_attempts_status_check
    check (execution_status in ('planned','leased','running','succeeded','failed','retry_scheduled','cancelled')),
  constraint commercial_purchase_execution_attempts_idempotency_check
    check (length(trim(idempotency_key)) between 8 and 240),
  constraint commercial_purchase_execution_attempts_lease_check
    check (
      (execution_status not in ('leased','running'))
      or (
        lease_token is not null
        and leased_at is not null
        and lease_expires_at is not null
        and lease_expires_at > leased_at
      )
    ),
  constraint commercial_purchase_execution_attempts_completion_check
    check (
      (execution_status not in ('succeeded','failed','cancelled'))
      or completed_at is not null
    ),
  constraint commercial_purchase_execution_attempts_failure_check
    check (
      execution_status <> 'failed'
      or error_code is not null
    ),
  constraint commercial_purchase_execution_attempts_json_check
    check (
      jsonb_typeof(request_snapshot) = 'object'
      and jsonb_typeof(response_snapshot) = 'object'
      and jsonb_typeof(metadata) = 'object'
    )
);

create index commercial_purchase_execution_attempts_dispatch_idx
  on public.commercial_purchase_execution_attempts (
    execution_status,
    next_retry_at,
    created_at
  );

create index commercial_purchase_execution_attempts_purchase_idx
  on public.commercial_purchase_execution_attempts (
    purchase_id,
    execution_action,
    attempt_number desc
  );

comment on table public.commercial_purchase_execution_attempts is
  'Auditable purchase-runtime execution attempts. Foundation migration creates no attempts and invokes no provider.';

-- =============================================================================
-- 4. PURCHASE RUNTIME STATE PROJECTION
-- =============================================================================

create table public.commercial_purchase_runtime_states (
  purchase_id uuid primary key,
  policy_id uuid not null,
  runtime_state text not null default 'dormant',
  readiness_status text not null default 'not_evaluated',
  current_action text null,
  active_authorization_id uuid null,
  last_attempt_id uuid null,
  next_action_at timestamptz null,
  attention_required boolean not null default false,
  automatic_execution_allowed boolean not null default false,
  state_reason text not null,
  state_version bigint not null default 1,
  evaluated_at timestamptz null,
  updated_at timestamptz not null default clock_timestamp(),
  metadata jsonb not null default '{}'::jsonb,

  constraint commercial_purchase_runtime_states_purchase_fkey
    foreign key (purchase_id)
    references public.commercial_purchases (id)
    on delete restrict,
  constraint commercial_purchase_runtime_states_policy_fkey
    foreign key (policy_id)
    references public.commercial_purchase_runtime_policies (id)
    on delete restrict,
  constraint commercial_purchase_runtime_states_authorization_fkey
    foreign key (active_authorization_id)
    references public.commercial_purchase_authorizations (id)
    on delete restrict,
  constraint commercial_purchase_runtime_states_attempt_fkey
    foreign key (last_attempt_id)
    references public.commercial_purchase_execution_attempts (id)
    on delete restrict,
  constraint commercial_purchase_runtime_states_state_check
    check (runtime_state in ('dormant','blocked','ready','authorized','executing','waiting_retry','completed','failed','cancelled','refunded')),
  constraint commercial_purchase_runtime_states_readiness_check
    check (readiness_status in ('not_evaluated','ready','blocked','attention_required')),
  constraint commercial_purchase_runtime_states_action_check
    check (
      current_action is null
      or current_action in ('attach_checkout','confirm_payment','close_purchase','refund_purchase')
    ),
  constraint commercial_purchase_runtime_states_version_check
    check (state_version > 0),
  constraint commercial_purchase_runtime_states_metadata_object_check
    check (jsonb_typeof(metadata) = 'object'),
  constraint commercial_purchase_runtime_states_auto_execution_check
    check (automatic_execution_allowed = false)
);

create index commercial_purchase_runtime_states_operational_idx
  on public.commercial_purchase_runtime_states (
    runtime_state,
    readiness_status,
    attention_required,
    next_action_at
  );

comment on table public.commercial_purchase_runtime_states is
  'Current governed projection for each purchase. Automatic execution is structurally disabled in the foundation.';

-- =============================================================================
-- 5. PURCHASE RUNTIME OUTBOX
-- =============================================================================

create table public.commercial_purchase_runtime_outbox (
  id uuid primary key default gen_random_uuid(),
  purchase_id uuid not null,
  authorization_id uuid null,
  requested_action text not null,
  dispatch_status text not null default 'held',
  idempotency_key text not null,
  available_at timestamptz not null default clock_timestamp(),
  dispatched_at timestamptz null,
  completed_at timestamptz null,
  correlation_id uuid not null,
  payload jsonb not null default '{}'::jsonb,
  error_code text null,
  error_message text null,
  created_at timestamptz not null default clock_timestamp(),

  constraint commercial_purchase_runtime_outbox_purchase_fkey
    foreign key (purchase_id)
    references public.commercial_purchases (id)
    on delete restrict,
  constraint commercial_purchase_runtime_outbox_authorization_fkey
    foreign key (authorization_id)
    references public.commercial_purchase_authorizations (id)
    on delete restrict,
  constraint commercial_purchase_runtime_outbox_idempotency_key
    unique (idempotency_key),
  constraint commercial_purchase_runtime_outbox_action_check
    check (requested_action in ('attach_checkout','confirm_payment','close_purchase','refund_purchase')),
  constraint commercial_purchase_runtime_outbox_status_check
    check (dispatch_status in ('held','pending','claimed','completed','failed','cancelled')),
  constraint commercial_purchase_runtime_outbox_idempotency_check
    check (length(trim(idempotency_key)) between 8 and 240),
  constraint commercial_purchase_runtime_outbox_payload_object_check
    check (jsonb_typeof(payload) = 'object'),
  constraint commercial_purchase_runtime_outbox_completion_check
    check (dispatch_status <> 'completed' or completed_at is not null),
  constraint commercial_purchase_runtime_outbox_failure_check
    check (dispatch_status <> 'failed' or error_code is not null),
  constraint commercial_purchase_runtime_outbox_foundation_hold_check
    check (dispatch_status <> 'pending')
);

create index commercial_purchase_runtime_outbox_dispatch_idx
  on public.commercial_purchase_runtime_outbox (
    dispatch_status,
    available_at,
    created_at
  );

comment on table public.commercial_purchase_runtime_outbox is
  'Governed dispatch intent registry. Foundation constraint prevents pending dispatch and therefore prevents runtime execution.';

-- =============================================================================
-- 6. APPEND-ONLY PURCHASE RUNTIME EVENTS
-- =============================================================================

create table public.commercial_purchase_runtime_events (
  id uuid primary key default gen_random_uuid(),
  purchase_id uuid null,
  policy_id uuid null,
  authorization_id uuid null,
  attempt_id uuid null,
  event_type text not null,
  previous_state text null,
  next_state text null,
  actor text not null,
  reason text null,
  correlation_id uuid not null,
  causation_id uuid null,
  payload jsonb not null default '{}'::jsonb,
  occurred_at timestamptz not null default clock_timestamp(),

  constraint commercial_purchase_runtime_events_purchase_fkey
    foreign key (purchase_id)
    references public.commercial_purchases (id)
    on delete restrict,
  constraint commercial_purchase_runtime_events_policy_fkey
    foreign key (policy_id)
    references public.commercial_purchase_runtime_policies (id)
    on delete restrict,
  constraint commercial_purchase_runtime_events_authorization_fkey
    foreign key (authorization_id)
    references public.commercial_purchase_authorizations (id)
    on delete restrict,
  constraint commercial_purchase_runtime_events_attempt_fkey
    foreign key (attempt_id)
    references public.commercial_purchase_execution_attempts (id)
    on delete restrict,
  constraint commercial_purchase_runtime_events_type_check
    check (event_type ~ '^[A-Z][A-Z0-9_]{2,95}$'),
  constraint commercial_purchase_runtime_events_payload_object_check
    check (jsonb_typeof(payload) = 'object')
);

create index commercial_purchase_runtime_events_purchase_idx
  on public.commercial_purchase_runtime_events (
    purchase_id,
    occurred_at,
    id
  );

create index commercial_purchase_runtime_events_correlation_idx
  on public.commercial_purchase_runtime_events (
    correlation_id,
    occurred_at,
    id
  );

comment on table public.commercial_purchase_runtime_events is
  'Append-only lifecycle and audit timeline for governed purchase runtime.';

-- =============================================================================
-- 7. IMMUTABILITY AND UPDATED_AT GUARDS
-- =============================================================================

create or replace function public.protect_commercial_purchase_runtime_policy_internal()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'COMMERCIAL_PURCHASE_RUNTIME_POLICY_DELETE_FORBIDDEN';
  end if;

  if old.policy_status <> 'draft' then
    raise exception 'COMMERCIAL_PURCHASE_RUNTIME_POLICY_IMMUTABLE';
  end if;

  if new.id is distinct from old.id
     or new.policy_code is distinct from old.policy_code
     or new.version_number is distinct from old.version_number
     or new.created_by is distinct from old.created_by
     or new.created_at is distinct from old.created_at then
    raise exception 'COMMERCIAL_PURCHASE_RUNTIME_POLICY_IDENTITY_IMMUTABLE';
  end if;

  return new;
end;
$$;

create trigger commercial_purchase_runtime_policies_guard
before update or delete on public.commercial_purchase_runtime_policies
for each row execute function public.protect_commercial_purchase_runtime_policy_internal();

create or replace function public.protect_commercial_purchase_runtime_event_internal()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  raise exception 'COMMERCIAL_PURCHASE_RUNTIME_EVENT_APPEND_ONLY';
end;
$$;

create trigger commercial_purchase_runtime_events_append_only_guard
before update or delete on public.commercial_purchase_runtime_events
for each row execute function public.protect_commercial_purchase_runtime_event_internal();

create or replace function public.set_commercial_purchase_runtime_state_updated_at_internal()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.updated_at := clock_timestamp();
  new.state_version := old.state_version + 1;
  return new;
end;
$$;

create trigger commercial_purchase_runtime_states_set_updated_at
before update on public.commercial_purchase_runtime_states
for each row execute function public.set_commercial_purchase_runtime_state_updated_at_internal();

-- =============================================================================
-- 8. INTERNAL EVENT APPEND FUNCTION
-- =============================================================================

create or replace function public.append_commercial_purchase_runtime_event_internal(
  p_event_type text,
  p_actor text,
  p_correlation_id uuid,
  p_purchase_id uuid default null,
  p_policy_id uuid default null,
  p_authorization_id uuid default null,
  p_attempt_id uuid default null,
  p_previous_state text default null,
  p_next_state text default null,
  p_reason text default null,
  p_causation_id uuid default null,
  p_payload jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid;
begin
  if nullif(trim(p_event_type), '') is null
     or nullif(trim(p_actor), '') is null
     or p_correlation_id is null then
    raise exception 'COMMERCIAL_PURCHASE_RUNTIME_EVENT_ARGUMENT_INVALID';
  end if;

  insert into public.commercial_purchase_runtime_events (
    purchase_id,
    policy_id,
    authorization_id,
    attempt_id,
    event_type,
    previous_state,
    next_state,
    actor,
    reason,
    correlation_id,
    causation_id,
    payload
  )
  values (
    p_purchase_id,
    p_policy_id,
    p_authorization_id,
    p_attempt_id,
    upper(trim(p_event_type)),
    p_previous_state,
    p_next_state,
    trim(p_actor),
    p_reason,
    p_correlation_id,
    p_causation_id,
    coalesce(p_payload, '{}'::jsonb)
  )
  returning id into v_id;

  return v_id;
end;
$$;

-- =============================================================================
-- 9. READINESS EVALUATION
-- =============================================================================

create or replace function public.evaluate_commercial_purchase_runtime_readiness_internal(
  p_purchase_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_purchase public.commercial_purchases;
  v_policy public.commercial_purchase_runtime_policies;
  v_component_count integer;
  v_blockers text[] := array[]::text[];
  v_runtime_state text;
  v_readiness_status text;
  v_reason text;
  v_state public.commercial_purchase_runtime_states;
begin
  select * into v_purchase
  from public.commercial_purchases
  where id = p_purchase_id;

  if not found then
    return jsonb_build_object(
      'evaluated', false,
      'error_code', 'COMMERCIAL_PURCHASE_NOT_FOUND',
      'purchase_id', p_purchase_id
    );
  end if;

  select * into v_policy
  from public.commercial_purchase_runtime_policies
  where policy_code = 'DEFAULT_ONE_TIME_PURCHASE'
    and environment = 'test'
  order by version_number desc
  limit 1;

  if not found then
    raise exception 'COMMERCIAL_PURCHASE_RUNTIME_POLICY_NOT_FOUND';
  end if;

  select count(*) into v_component_count
  from public.commercial_product_pass_components c
  where c.product_id = v_purchase.product_id
    and c.component_status = 'certified';

  if v_component_count <> 1 then
    v_blockers := array_append(v_blockers, 'PRODUCT_PASS_COMPONENT_NOT_CERTIFIED');
  end if;

  if v_policy.policy_status <> 'approved' then
    v_blockers := array_append(v_blockers, 'RUNTIME_POLICY_NOT_APPROVED');
  end if;

  if not exists (
    select 1
    from public.payment_providers p
    where p.id = v_purchase.provider_id
      and p.enabled = true
  ) then
    v_blockers := array_append(v_blockers, 'PAYMENT_PROVIDER_NOT_ENABLED');
  end if;

  if v_purchase.purchase_status in ('confirmed','cancelled','failed','refunded') then
    v_runtime_state := case v_purchase.purchase_status
      when 'confirmed' then 'completed'
      when 'cancelled' then 'cancelled'
      when 'failed' then 'failed'
      when 'refunded' then 'refunded'
    end;
    v_readiness_status := 'blocked';
    v_reason := 'PURCHASE_ALREADY_TERMINAL';
  elsif cardinality(v_blockers) = 0 then
    v_runtime_state := 'ready';
    v_readiness_status := 'ready';
    v_reason := 'PURCHASE_RUNTIME_READY_MANUAL_EXECUTION_ONLY';
  else
    v_runtime_state := 'blocked';
    v_readiness_status := 'blocked';
    v_reason := array_to_string(v_blockers, ',');
  end if;

  insert into public.commercial_purchase_runtime_states (
    purchase_id,
    policy_id,
    runtime_state,
    readiness_status,
    current_action,
    attention_required,
    automatic_execution_allowed,
    state_reason,
    evaluated_at,
    metadata
  )
  values (
    v_purchase.id,
    v_policy.id,
    v_runtime_state,
    v_readiness_status,
    case
      when v_purchase.purchase_status = 'pending' then 'attach_checkout'
      when v_purchase.purchase_status = 'provider_created' then 'confirm_payment'
      when v_purchase.purchase_status = 'confirmed' then null
      else null
    end,
    false,
    false,
    v_reason,
    clock_timestamp(),
    jsonb_build_object('blockers', to_jsonb(v_blockers))
  )
  on conflict (purchase_id) do update
  set
    policy_id = excluded.policy_id,
    runtime_state = excluded.runtime_state,
    readiness_status = excluded.readiness_status,
    current_action = excluded.current_action,
    attention_required = excluded.attention_required,
    automatic_execution_allowed = false,
    state_reason = excluded.state_reason,
    evaluated_at = excluded.evaluated_at,
    metadata = excluded.metadata
  returning * into v_state;

  perform public.append_commercial_purchase_runtime_event_internal(
    'PURCHASE_RUNTIME_READINESS_EVALUATED',
    'purchase_runtime_engine',
    v_purchase.correlation_id,
    v_purchase.id,
    v_policy.id,
    null,
    null,
    null,
    v_state.runtime_state,
    v_reason,
    null,
    jsonb_build_object(
      'readiness_status', v_state.readiness_status,
      'automatic_execution_allowed', false,
      'blockers', to_jsonb(v_blockers)
    )
  );

  return jsonb_build_object(
    'evaluated', true,
    'purchase_id', v_purchase.id,
    'runtime_state', v_state.runtime_state,
    'readiness_status', v_state.readiness_status,
    'automatic_execution_allowed', false,
    'blockers', to_jsonb(v_blockers),
    'state_reason', v_state.state_reason
  );
end;
$$;

-- =============================================================================
-- 10. AUTHORIZATION REQUEST AND DECISION FUNCTIONS
-- =============================================================================

create or replace function public.request_commercial_purchase_authorization_internal(
  p_purchase_id uuid,
  p_requested_action text,
  p_authorization_key text,
  p_requested_by text,
  p_metadata jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_purchase public.commercial_purchases;
  v_policy public.commercial_purchase_runtime_policies;
  v_existing public.commercial_purchase_authorizations;
  v_authorization public.commercial_purchase_authorizations;
  v_action text := lower(trim(p_requested_action));
  v_key text := trim(p_authorization_key);
begin
  select * into v_purchase
  from public.commercial_purchases
  where id = p_purchase_id;

  if not found then
    return jsonb_build_object('requested', false, 'error_code', 'COMMERCIAL_PURCHASE_NOT_FOUND');
  end if;

  select * into v_existing
  from public.commercial_purchase_authorizations
  where authorization_key = v_key;

  if found then
    if v_existing.purchase_id <> p_purchase_id
       or v_existing.requested_action <> v_action then
      raise exception 'COMMERCIAL_PURCHASE_AUTHORIZATION_IDEMPOTENCY_CONFLICT';
    end if;

    return jsonb_build_object(
      'requested', false,
      'reused_existing_authorization', true,
      'authorization_id', v_existing.id,
      'authorization_status', v_existing.authorization_status
    );
  end if;

  select * into v_policy
  from public.commercial_purchase_runtime_policies
  where policy_code = 'DEFAULT_ONE_TIME_PURCHASE'
    and environment = 'test'
  order by version_number desc
  limit 1;

  if v_policy.policy_status <> 'approved' then
    return jsonb_build_object(
      'requested', false,
      'error_code', 'COMMERCIAL_PURCHASE_RUNTIME_POLICY_NOT_APPROVED'
    );
  end if;

  insert into public.commercial_purchase_authorizations (
    purchase_id,
    policy_id,
    authorization_key,
    authorization_status,
    requested_action,
    requested_by,
    expires_at,
    correlation_id,
    metadata
  ) values (
    v_purchase.id,
    v_policy.id,
    v_key,
    'requested',
    v_action,
    trim(p_requested_by),
    clock_timestamp() + make_interval(secs => v_policy.authorization_ttl_seconds),
    v_purchase.correlation_id,
    coalesce(p_metadata, '{}'::jsonb)
  ) returning * into v_authorization;

  perform public.append_commercial_purchase_runtime_event_internal(
    'PURCHASE_AUTHORIZATION_REQUESTED',
    p_requested_by,
    v_purchase.correlation_id,
    v_purchase.id,
    v_policy.id,
    v_authorization.id,
    null,
    null,
    'requested',
    null,
    null,
    jsonb_build_object('requested_action', v_action)
  );

  return jsonb_build_object(
    'requested', true,
    'authorization_id', v_authorization.id,
    'authorization_status', v_authorization.authorization_status,
    'expires_at', v_authorization.expires_at
  );
end;
$$;

create or replace function public.decide_commercial_purchase_authorization_internal(
  p_authorization_id uuid,
  p_decision text,
  p_decision_by text,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_authorization public.commercial_purchase_authorizations;
  v_decision text := lower(trim(p_decision));
begin
  if v_decision not in ('approved','rejected','cancelled') then
    raise exception 'COMMERCIAL_PURCHASE_AUTHORIZATION_DECISION_INVALID';
  end if;

  select * into v_authorization
  from public.commercial_purchase_authorizations
  where id = p_authorization_id
  for update;

  if not found then
    return jsonb_build_object('decided', false, 'error_code', 'COMMERCIAL_PURCHASE_AUTHORIZATION_NOT_FOUND');
  end if;

  if v_authorization.authorization_status <> 'requested' then
    return jsonb_build_object(
      'decided', false,
      'error_code', 'COMMERCIAL_PURCHASE_AUTHORIZATION_ALREADY_DECIDED',
      'authorization_status', v_authorization.authorization_status
    );
  end if;

  if v_authorization.expires_at <= clock_timestamp() then
    v_decision := 'expired';
  end if;

  update public.commercial_purchase_authorizations
  set
    authorization_status = v_decision,
    decision_by = trim(p_decision_by),
    decision_reason = p_reason,
    decided_at = clock_timestamp()
  where id = v_authorization.id
  returning * into v_authorization;

  perform public.append_commercial_purchase_runtime_event_internal(
    'PURCHASE_AUTHORIZATION_' || upper(v_decision),
    p_decision_by,
    v_authorization.correlation_id,
    v_authorization.purchase_id,
    v_authorization.policy_id,
    v_authorization.id,
    null,
    'requested',
    v_decision,
    p_reason,
    null,
    jsonb_build_object('requested_action', v_authorization.requested_action)
  );

  return jsonb_build_object(
    'decided', true,
    'authorization_id', v_authorization.id,
    'authorization_status', v_authorization.authorization_status,
    'automatic_execution_scheduled', false
  );
end;
$$;

-- =============================================================================
-- 11. READ MODELS
-- =============================================================================

create or replace function public.get_commercial_purchase_runtime_internal(
  p_purchase_id uuid
)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'purchase', to_jsonb(p),
    'runtime_state', to_jsonb(s),
    'authorizations', coalesce((
      select jsonb_agg(to_jsonb(a) order by a.requested_at, a.id)
      from public.commercial_purchase_authorizations a
      where a.purchase_id = p.id
    ), '[]'::jsonb),
    'attempts', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.created_at, x.id)
      from public.commercial_purchase_execution_attempts x
      where x.purchase_id = p.id
    ), '[]'::jsonb),
    'outbox', coalesce((
      select jsonb_agg(to_jsonb(o) order by o.created_at, o.id)
      from public.commercial_purchase_runtime_outbox o
      where o.purchase_id = p.id
    ), '[]'::jsonb)
  )
  from public.commercial_purchases p
  left join public.commercial_purchase_runtime_states s
    on s.purchase_id = p.id
  where p.id = p_purchase_id;
$$;

create or replace function public.get_commercial_purchase_runtime_timeline_internal(
  p_purchase_id uuid
)
returns setof public.commercial_purchase_runtime_events
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select e.*
  from public.commercial_purchase_runtime_events e
  where e.purchase_id = p_purchase_id
  order by e.occurred_at, e.id;
$$;

-- =============================================================================
-- 12. FOUNDATION POLICY SEED
-- =============================================================================

insert into public.commercial_purchase_runtime_policies (
  policy_code,
  version_number,
  policy_status,
  environment,
  automatic_execution_enabled,
  automatic_confirmation_enabled,
  automatic_refund_enabled,
  require_verified_provider_event,
  max_authorization_attempts,
  max_execution_attempts,
  authorization_ttl_seconds,
  execution_lease_seconds,
  retry_backoff_seconds,
  configuration,
  policy_hash,
  created_by
)
values (
  'DEFAULT_ONE_TIME_PURCHASE',
  1,
  'draft',
  'test',
  false,
  false,
  false,
  true,
  3,
  5,
  900,
  120,
  array[30,120,600],
  jsonb_build_object(
    'foundation_seed', true,
    'manual_authorization_required', true,
    'provider_calls_enabled', false,
    'ledger_mutation_enabled', false,
    'wallet_mutation_enabled', false
  ),
  md5(
    'DEFAULT_ONE_TIME_PURCHASE|1|test|manual|no-provider|no-ledger|no-wallet'
  ),
  'MIGRATION_113'
);

select public.append_commercial_purchase_runtime_event_internal(
  'PURCHASE_RUNTIME_POLICY_REGISTERED',
  'MIGRATION_113',
  gen_random_uuid(),
  null,
  (
    select id
    from public.commercial_purchase_runtime_policies
    where policy_code = 'DEFAULT_ONE_TIME_PURCHASE'
      and version_number = 1
  ),
  null,
  null,
  null,
  'draft',
  'Purchase runtime governance foundation initialized',
  null,
  jsonb_build_object(
    'automatic_execution_enabled', false,
    'provider_calls_enabled', false,
    'financial_mutation_enabled', false
  )
);

-- =============================================================================
-- 13. ROW LEVEL SECURITY
-- =============================================================================

alter table public.commercial_purchase_runtime_policies enable row level security;
alter table public.commercial_purchase_authorizations enable row level security;
alter table public.commercial_purchase_execution_attempts enable row level security;
alter table public.commercial_purchase_runtime_states enable row level security;
alter table public.commercial_purchase_runtime_outbox enable row level security;
alter table public.commercial_purchase_runtime_events enable row level security;

-- No client policies are created. All tables remain backend-only.

-- =============================================================================
-- 14. PRIVILEGES
-- =============================================================================

revoke all on table public.commercial_purchase_runtime_policies from public, anon, authenticated;
revoke all on table public.commercial_purchase_authorizations from public, anon, authenticated;
revoke all on table public.commercial_purchase_execution_attempts from public, anon, authenticated;
revoke all on table public.commercial_purchase_runtime_states from public, anon, authenticated;
revoke all on table public.commercial_purchase_runtime_outbox from public, anon, authenticated;
revoke all on table public.commercial_purchase_runtime_events from public, anon, authenticated;

grant select, insert, update on table public.commercial_purchase_runtime_policies to service_role;
grant select, insert, update on table public.commercial_purchase_authorizations to service_role;
grant select, insert, update on table public.commercial_purchase_execution_attempts to service_role;
grant select, insert, update on table public.commercial_purchase_runtime_states to service_role;
grant select, insert, update on table public.commercial_purchase_runtime_outbox to service_role;
grant select, insert on table public.commercial_purchase_runtime_events to service_role;

revoke all on function public.protect_commercial_purchase_runtime_policy_internal() from public, anon, authenticated;
revoke all on function public.protect_commercial_purchase_runtime_event_internal() from public, anon, authenticated;
revoke all on function public.set_commercial_purchase_runtime_state_updated_at_internal() from public, anon, authenticated;
revoke all on function public.append_commercial_purchase_runtime_event_internal(text,text,uuid,uuid,uuid,uuid,uuid,text,text,text,uuid,jsonb) from public, anon, authenticated;
revoke all on function public.evaluate_commercial_purchase_runtime_readiness_internal(uuid) from public, anon, authenticated;
revoke all on function public.request_commercial_purchase_authorization_internal(uuid,text,text,text,jsonb) from public, anon, authenticated;
revoke all on function public.decide_commercial_purchase_authorization_internal(uuid,text,text,text) from public, anon, authenticated;
revoke all on function public.get_commercial_purchase_runtime_internal(uuid) from public, anon, authenticated;
revoke all on function public.get_commercial_purchase_runtime_timeline_internal(uuid) from public, anon, authenticated;

grant execute on function public.append_commercial_purchase_runtime_event_internal(text,text,uuid,uuid,uuid,uuid,uuid,text,text,text,uuid,jsonb) to service_role;
grant execute on function public.evaluate_commercial_purchase_runtime_readiness_internal(uuid) to service_role;
grant execute on function public.request_commercial_purchase_authorization_internal(uuid,text,text,text,jsonb) to service_role;
grant execute on function public.decide_commercial_purchase_authorization_internal(uuid,text,text,text) to service_role;
grant execute on function public.get_commercial_purchase_runtime_internal(uuid) to service_role;
grant execute on function public.get_commercial_purchase_runtime_timeline_internal(uuid) to service_role;

-- =============================================================================
-- 15. CERTIFICATION ASSERTIONS
-- =============================================================================

do $$
declare
  v_policy_count integer;
  v_runtime_count integer;
  v_authorization_count integer;
  v_attempt_count integer;
  v_outbox_count integer;
  v_event_count integer;
begin
  select count(*) into v_policy_count
  from public.commercial_purchase_runtime_policies;

  select count(*) into v_runtime_count
  from public.commercial_purchase_runtime_states;

  select count(*) into v_authorization_count
  from public.commercial_purchase_authorizations;

  select count(*) into v_attempt_count
  from public.commercial_purchase_execution_attempts;

  select count(*) into v_outbox_count
  from public.commercial_purchase_runtime_outbox;

  select count(*) into v_event_count
  from public.commercial_purchase_runtime_events;

  if v_policy_count <> 1 then
    raise exception 'MIGRATION_113_POLICY_COUNT_ASSERTION_FAILED';
  end if;

  if exists (
    select 1
    from public.commercial_purchase_runtime_policies
    where automatic_execution_enabled
       or automatic_confirmation_enabled
       or automatic_refund_enabled
       or policy_status <> 'draft'
  ) then
    raise exception 'MIGRATION_113_AUTOMATIC_EXECUTION_SAFETY_ASSERTION_FAILED';
  end if;

  if v_runtime_count <> 0
     or v_authorization_count <> 0
     or v_attempt_count <> 0
     or v_outbox_count <> 0 then
    raise exception 'MIGRATION_113_PASSIVE_FOUNDATION_ASSERTION_FAILED';
  end if;

  if v_event_count <> 1 then
    raise exception 'MIGRATION_113_INITIAL_EVENT_ASSERTION_FAILED';
  end if;

  if exists (
    select 1
    from public.commercial_purchase_runtime_outbox
    where dispatch_status = 'pending'
  ) then
    raise exception 'MIGRATION_113_PENDING_DISPATCH_ASSERTION_FAILED';
  end if;

  raise notice
    'MIGRATION_113_CERTIFIED policy_count=%, runtime_count=%, authorization_count=%, attempt_count=%, outbox_count=%, event_count=%',
    v_policy_count,
    v_runtime_count,
    v_authorization_count,
    v_attempt_count,
    v_outbox_count,
    v_event_count;
end;
$$;

commit;
