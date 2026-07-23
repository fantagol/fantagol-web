-- ============================================================================
-- FANTAGOL
-- Migration: 115_commercial_provider_checkout_orchestration_foundation.sql
-- Purpose:
--   Passive governance foundation for provider checkout sessions, outbound
--   requests, inbound callbacks and reconciliation observations.
--
-- Safety:
--   - Does not call any external provider
--   - Does not confirm or refund purchases
--   - Does not mutate commercial ledgers or wallets
--   - Does not enqueue dispatchable work
--   - All operational records start in non-dispatchable states
-- ============================================================================

begin;

do $$
begin
  if to_regclass('public.commercial_purchases') is null then
    raise exception 'MIGRATION_115_MISSING_COMMERCIAL_PURCHASES';
  end if;

  if to_regclass('public.commercial_providers') is null then
    raise exception 'MIGRATION_115_MISSING_COMMERCIAL_PROVIDERS';
  end if;

  if to_regclass('public.commercial_purchase_authorizations') is null then
    raise exception 'MIGRATION_115_MISSING_PURCHASE_AUTHORIZATIONS';
  end if;

  if to_regclass('public.commercial_purchase_execution_attempts') is null then
    raise exception 'MIGRATION_115_MISSING_PURCHASE_EXECUTION_ATTEMPTS';
  end if;

  if to_regclass('public.payment_provider_events') is null then
    raise exception 'MIGRATION_115_MISSING_PAYMENT_PROVIDER_EVENTS';
  end if;
end
$$;

create table public.commercial_checkout_orchestration_policies (
  id uuid primary key default gen_random_uuid(),
  policy_code text not null,
  version integer not null,
  policy_status text not null default 'draft',
  environment text not null default 'test',
  session_ttl_seconds integer not null default 1800,
  callback_tolerance_seconds integer not null default 300,
  reconciliation_interval_seconds integer not null default 900,
  provider_calls_enabled boolean not null default false,
  callback_processing_enabled boolean not null default false,
  automatic_reconciliation_enabled boolean not null default false,
  automatic_purchase_confirmation_enabled boolean not null default false,
  automatic_refund_enabled boolean not null default false,
  configuration jsonb not null default '{}'::jsonb,
  content_hash text not null,
  approved_at timestamptz,
  approved_by text,
  created_at timestamptz not null default now(),
  created_by text not null default 'MIGRATION_115',

  constraint commercial_checkout_orchestration_policies_key
    unique (policy_code, version),
  constraint commercial_checkout_orchestration_policies_code_check
    check (
      policy_code = upper(policy_code)
      and policy_code ~ '^[A-Z][A-Z0-9_]{1,95}$'
    ),
  constraint commercial_checkout_orchestration_policies_version_check
    check (version > 0),
  constraint commercial_checkout_orchestration_policies_status_check
    check (policy_status in ('draft','approved','retired')),
  constraint commercial_checkout_orchestration_policies_environment_check
    check (environment in ('test','production')),
  constraint commercial_checkout_orchestration_policies_limits_check
    check (
      session_ttl_seconds between 60 and 86400
      and callback_tolerance_seconds between 0 and 86400
      and reconciliation_interval_seconds between 60 and 86400
    ),
  constraint commercial_checkout_orchestration_policies_configuration_check
    check (jsonb_typeof(configuration) = 'object'),
  constraint commercial_checkout_orchestration_policies_hash_check
    check (length(btrim(content_hash)) >= 32),
  constraint commercial_checkout_orchestration_policies_approval_check
    check (
      (policy_status = 'approved' and approved_at is not null and approved_by is not null)
      or
      (policy_status <> 'approved')
    ),
  constraint commercial_checkout_orchestration_policies_foundation_safety_check
    check (
      provider_calls_enabled = false
      and callback_processing_enabled = false
      and automatic_reconciliation_enabled = false
      and automatic_purchase_confirmation_enabled = false
      and automatic_refund_enabled = false
    )
);

create index commercial_checkout_orchestration_policies_status_idx
  on public.commercial_checkout_orchestration_policies
  (policy_status, environment, version desc);

comment on table public.commercial_checkout_orchestration_policies is
'Versioned passive checkout orchestration policy. Migration 115 forbids provider calls and automatic economic mutation.';

create table public.commercial_checkout_sessions (
  id uuid primary key default gen_random_uuid(),
  purchase_id uuid not null,
  provider_id uuid not null,
  policy_id uuid not null,
  authorization_id uuid,
  session_key text not null,
  provider_session_reference text,
  session_status text not null default 'draft',
  environment text not null default 'test',
  amount_minor bigint not null,
  currency text not null,
  expires_at timestamptz not null,
  return_url text,
  cancel_url text,
  checkout_url text,
  provider_payload jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  opened_at timestamptz,
  completed_at timestamptz,
  failed_at timestamptz,
  failure_code text,
  failure_message text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint commercial_checkout_sessions_purchase_fkey
    foreign key (purchase_id)
    references public.commercial_purchases(id)
    on delete cascade,
  constraint commercial_checkout_sessions_provider_fkey
    foreign key (provider_id)
    references public.commercial_providers(id),
  constraint commercial_checkout_sessions_policy_fkey
    foreign key (policy_id)
    references public.commercial_checkout_orchestration_policies(id),
  constraint commercial_checkout_sessions_authorization_fkey
    foreign key (authorization_id)
    references public.commercial_purchase_authorizations(id),
  constraint commercial_checkout_sessions_session_key_unique
    unique (session_key),
  constraint commercial_checkout_sessions_key_check
    check (length(btrim(session_key)) >= 16),
  constraint commercial_checkout_sessions_status_check
    check (session_status in (
      'draft','authorized','request_recorded','provider_pending',
      'opened','completed','expired','cancelled','failed'
    )),
  constraint commercial_checkout_sessions_environment_check
    check (environment in ('test','production')),
  constraint commercial_checkout_sessions_amount_check
    check (amount_minor >= 0),
  constraint commercial_checkout_sessions_currency_check
    check (
      currency = upper(currency)
      and currency ~ '^[A-Z]{3}$'
    ),
  constraint commercial_checkout_sessions_expiry_check
    check (expires_at > created_at),
  constraint commercial_checkout_sessions_json_check
    check (
      jsonb_typeof(provider_payload) = 'object'
      and jsonb_typeof(metadata) = 'object'
    ),
  constraint commercial_checkout_sessions_completion_check
    check (
      (session_status = 'completed' and completed_at is not null)
      or session_status <> 'completed'
    ),
  constraint commercial_checkout_sessions_failure_check
    check (
      (session_status = 'failed' and failed_at is not null and failure_code is not null)
      or session_status <> 'failed'
    ),
  constraint commercial_checkout_sessions_foundation_hold_check
    check (session_status not in ('provider_pending','opened','completed'))
);

create index commercial_checkout_sessions_purchase_idx
  on public.commercial_checkout_sessions (purchase_id, created_at desc);

create index commercial_checkout_sessions_status_idx
  on public.commercial_checkout_sessions (session_status, expires_at);

comment on table public.commercial_checkout_sessions is
'Canonical checkout session state. Foundation rows cannot enter externally active or completed states.';

create table public.commercial_checkout_provider_requests (
  id uuid primary key default gen_random_uuid(),
  checkout_session_id uuid not null,
  purchase_id uuid not null,
  provider_id uuid not null,
  execution_attempt_id uuid,
  request_kind text not null,
  idempotency_key text not null,
  request_status text not null default 'recorded',
  request_payload jsonb not null default '{}'::jsonb,
  response_payload jsonb not null default '{}'::jsonb,
  provider_request_reference text,
  http_status integer,
  recorded_at timestamptz not null default now(),
  dispatched_at timestamptz,
  completed_at timestamptz,
  failure_code text,
  failure_message text,

  constraint commercial_checkout_provider_requests_session_fkey
    foreign key (checkout_session_id)
    references public.commercial_checkout_sessions(id)
    on delete cascade,
  constraint commercial_checkout_provider_requests_purchase_fkey
    foreign key (purchase_id)
    references public.commercial_purchases(id)
    on delete cascade,
  constraint commercial_checkout_provider_requests_provider_fkey
    foreign key (provider_id)
    references public.commercial_providers(id),
  constraint commercial_checkout_provider_requests_attempt_fkey
    foreign key (execution_attempt_id)
    references public.commercial_purchase_execution_attempts(id),
  constraint commercial_checkout_provider_requests_idempotency_unique
    unique (idempotency_key),
  constraint commercial_checkout_provider_requests_kind_check
    check (request_kind in (
      'create_checkout','retrieve_checkout','cancel_checkout',
      'retrieve_payment','retrieve_refund'
    )),
  constraint commercial_checkout_provider_requests_status_check
    check (request_status in ('recorded','held','dispatched','succeeded','failed')),
  constraint commercial_checkout_provider_requests_idempotency_check
    check (length(btrim(idempotency_key)) >= 16),
  constraint commercial_checkout_provider_requests_json_check
    check (
      jsonb_typeof(request_payload) = 'object'
      and jsonb_typeof(response_payload) = 'object'
    ),
  constraint commercial_checkout_provider_requests_http_check
    check (http_status is null or http_status between 100 and 599),
  constraint commercial_checkout_provider_requests_foundation_hold_check
    check (request_status in ('recorded','held'))
);

create index commercial_checkout_provider_requests_session_idx
  on public.commercial_checkout_provider_requests
  (checkout_session_id, recorded_at desc);

comment on table public.commercial_checkout_provider_requests is
'Passive record of intended provider requests. No row is dispatchable in migration 115.';

create table public.commercial_checkout_callbacks (
  id uuid primary key default gen_random_uuid(),
  provider_id uuid not null,
  checkout_session_id uuid,
  purchase_id uuid,
  payment_provider_event_id uuid,
  provider_event_id text not null,
  callback_type text not null,
  callback_status text not null default 'received',
  signature_status text not null default 'not_evaluated',
  event_occurred_at timestamptz,
  received_at timestamptz not null default now(),
  processed_at timestamptz,
  payload jsonb not null default '{}'::jsonb,
  headers jsonb not null default '{}'::jsonb,
  failure_code text,
  failure_message text,

  constraint commercial_checkout_callbacks_provider_fkey
    foreign key (provider_id)
    references public.commercial_providers(id),
  constraint commercial_checkout_callbacks_session_fkey
    foreign key (checkout_session_id)
    references public.commercial_checkout_sessions(id)
    on delete set null,
  constraint commercial_checkout_callbacks_purchase_fkey
    foreign key (purchase_id)
    references public.commercial_purchases(id)
    on delete set null,
  constraint commercial_checkout_callbacks_payment_event_fkey
    foreign key (payment_provider_event_id)
    references public.payment_provider_events(id)
    on delete set null,
  constraint commercial_checkout_callbacks_provider_event_unique
    unique (provider_id, provider_event_id),
  constraint commercial_checkout_callbacks_event_id_check
    check (length(btrim(provider_event_id)) > 0),
  constraint commercial_checkout_callbacks_type_check
    check (callback_type in (
      'checkout_opened','checkout_completed','checkout_expired',
      'payment_succeeded','payment_failed','refund_succeeded',
      'refund_failed','unknown'
    )),
  constraint commercial_checkout_callbacks_status_check
    check (callback_status in ('received','held','verified','rejected','processed','failed')),
  constraint commercial_checkout_callbacks_signature_check
    check (signature_status in ('not_evaluated','valid','invalid','unavailable')),
  constraint commercial_checkout_callbacks_json_check
    check (
      jsonb_typeof(payload) = 'object'
      and jsonb_typeof(headers) = 'object'
    ),
  constraint commercial_checkout_callbacks_foundation_hold_check
    check (callback_status in ('received','held'))
);

create index commercial_checkout_callbacks_lookup_idx
  on public.commercial_checkout_callbacks
  (provider_id, received_at desc);

comment on table public.commercial_checkout_callbacks is
'Normalized passive callback registry. Receipt does not imply verification, processing or purchase confirmation.';

create table public.commercial_checkout_reconciliation_observations (
  id uuid primary key default gen_random_uuid(),
  purchase_id uuid not null,
  provider_id uuid not null,
  checkout_session_id uuid,
  callback_id uuid,
  observation_key text not null,
  observation_status text not null default 'observed',
  local_purchase_status text,
  local_session_status text,
  provider_payment_status text,
  provider_refund_status text,
  consistency_status text not null default 'not_evaluated',
  recommended_action text not null default 'none',
  observed_at timestamptz not null default now(),
  evidence jsonb not null default '{}'::jsonb,
  notes text,

  constraint commercial_checkout_reconciliation_purchase_fkey
    foreign key (purchase_id)
    references public.commercial_purchases(id)
    on delete cascade,
  constraint commercial_checkout_reconciliation_provider_fkey
    foreign key (provider_id)
    references public.commercial_providers(id),
  constraint commercial_checkout_reconciliation_session_fkey
    foreign key (checkout_session_id)
    references public.commercial_checkout_sessions(id)
    on delete set null,
  constraint commercial_checkout_reconciliation_callback_fkey
    foreign key (callback_id)
    references public.commercial_checkout_callbacks(id)
    on delete set null,
  constraint commercial_checkout_reconciliation_key_unique
    unique (observation_key),
  constraint commercial_checkout_reconciliation_key_check
    check (length(btrim(observation_key)) >= 16),
  constraint commercial_checkout_reconciliation_status_check
    check (observation_status in ('observed','reviewed','resolved','ignored')),
  constraint commercial_checkout_reconciliation_consistency_check
    check (consistency_status in (
      'not_evaluated','consistent','local_ahead','provider_ahead',
      'amount_mismatch','currency_mismatch','status_mismatch','unknown'
    )),
  constraint commercial_checkout_reconciliation_action_check
    check (recommended_action in (
      'none','manual_review','retrieve_provider_state',
      'request_confirmation_authorization','request_refund_authorization'
    )),
  constraint commercial_checkout_reconciliation_evidence_check
    check (jsonb_typeof(evidence) = 'object'),
  constraint commercial_checkout_reconciliation_foundation_hold_check
    check (
      observation_status in ('observed','reviewed')
      and recommended_action in ('none','manual_review')
    )
);

create index commercial_checkout_reconciliation_purchase_idx
  on public.commercial_checkout_reconciliation_observations
  (purchase_id, observed_at desc);

comment on table public.commercial_checkout_reconciliation_observations is
'Passive reconciliation evidence. It cannot automatically confirm or refund a purchase.';

create table public.commercial_checkout_orchestration_events (
  id uuid primary key default gen_random_uuid(),
  event_type text not null,
  checkout_session_id uuid,
  purchase_id uuid,
  provider_id uuid,
  provider_request_id uuid,
  callback_id uuid,
  reconciliation_observation_id uuid,
  previous_state text,
  next_state text,
  actor text not null,
  reason text,
  correlation_id uuid not null default gen_random_uuid(),
  causation_id uuid,
  payload jsonb not null default '{}'::jsonb,
  occurred_at timestamptz not null default now(),

  constraint commercial_checkout_orchestration_events_session_fkey
    foreign key (checkout_session_id)
    references public.commercial_checkout_sessions(id)
    on delete set null,
  constraint commercial_checkout_orchestration_events_purchase_fkey
    foreign key (purchase_id)
    references public.commercial_purchases(id)
    on delete set null,
  constraint commercial_checkout_orchestration_events_provider_fkey
    foreign key (provider_id)
    references public.commercial_providers(id),
  constraint commercial_checkout_orchestration_events_request_fkey
    foreign key (provider_request_id)
    references public.commercial_checkout_provider_requests(id)
    on delete set null,
  constraint commercial_checkout_orchestration_events_callback_fkey
    foreign key (callback_id)
    references public.commercial_checkout_callbacks(id)
    on delete set null,
  constraint commercial_checkout_orchestration_events_reconciliation_fkey
    foreign key (reconciliation_observation_id)
    references public.commercial_checkout_reconciliation_observations(id)
    on delete set null,
  constraint commercial_checkout_orchestration_events_type_check
    check (
      event_type = upper(event_type)
      and event_type ~ '^[A-Z][A-Z0-9_]{2,127}$'
    ),
  constraint commercial_checkout_orchestration_events_actor_check
    check (length(btrim(actor)) > 0),
  constraint commercial_checkout_orchestration_events_payload_check
    check (jsonb_typeof(payload) = 'object')
);

create index commercial_checkout_orchestration_events_timeline_idx
  on public.commercial_checkout_orchestration_events
  (purchase_id, occurred_at, id);

comment on table public.commercial_checkout_orchestration_events is
'Append-only checkout orchestration timeline.';

create or replace function public.protect_commercial_checkout_policy_internal()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if old.policy_status = 'approved' then
    raise exception 'COMMERCIAL_CHECKOUT_POLICY_IMMUTABLE_AFTER_APPROVAL';
  end if;
  return new;
end
$$;

create trigger commercial_checkout_orchestration_policies_guard
before update or delete on public.commercial_checkout_orchestration_policies
for each row execute function public.protect_commercial_checkout_policy_internal();

create or replace function public.protect_commercial_checkout_event_internal()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  raise exception 'COMMERCIAL_CHECKOUT_EVENT_APPEND_ONLY';
end
$$;

create trigger commercial_checkout_orchestration_events_append_only_guard
before update or delete on public.commercial_checkout_orchestration_events
for each row execute function public.protect_commercial_checkout_event_internal();

create or replace function public.set_commercial_checkout_updated_at_internal()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  new.updated_at := now();
  return new;
end
$$;

create trigger commercial_checkout_sessions_set_updated_at
before update on public.commercial_checkout_sessions
for each row execute function public.set_commercial_checkout_updated_at_internal();

create or replace function public.append_commercial_checkout_event_internal(
  p_event_type text,
  p_actor text,
  p_checkout_session_id uuid default null,
  p_purchase_id uuid default null,
  p_provider_id uuid default null,
  p_provider_request_id uuid default null,
  p_callback_id uuid default null,
  p_reconciliation_observation_id uuid default null,
  p_previous_state text default null,
  p_next_state text default null,
  p_reason text default null,
  p_correlation_id uuid default null,
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
  insert into public.commercial_checkout_orchestration_events (
    event_type,
    actor,
    checkout_session_id,
    purchase_id,
    provider_id,
    provider_request_id,
    callback_id,
    reconciliation_observation_id,
    previous_state,
    next_state,
    reason,
    correlation_id,
    causation_id,
    payload
  ) values (
    upper(btrim(p_event_type)),
    p_actor,
    p_checkout_session_id,
    p_purchase_id,
    p_provider_id,
    p_provider_request_id,
    p_callback_id,
    p_reconciliation_observation_id,
    p_previous_state,
    p_next_state,
    p_reason,
    coalesce(p_correlation_id, gen_random_uuid()),
    p_causation_id,
    coalesce(p_payload, '{}'::jsonb)
  )
  returning id into v_id;

  return v_id;
end
$$;

create or replace function public.create_commercial_checkout_session_internal(
  p_purchase_id uuid,
  p_provider_id uuid,
  p_policy_id uuid,
  p_authorization_id uuid,
  p_session_key text,
  p_amount_minor bigint,
  p_currency text,
  p_expires_at timestamptz,
  p_return_url text default null,
  p_cancel_url text default null,
  p_actor text default 'service_role',
  p_metadata jsonb default '{}'::jsonb
)
returns public.commercial_checkout_sessions
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_policy public.commercial_checkout_orchestration_policies;
  v_result public.commercial_checkout_sessions;
begin
  select *
  into v_policy
  from public.commercial_checkout_orchestration_policies
  where id = p_policy_id;

  if not found then
    raise exception 'COMMERCIAL_CHECKOUT_POLICY_NOT_FOUND';
  end if;

  if v_policy.policy_status <> 'approved' then
    raise exception 'COMMERCIAL_CHECKOUT_POLICY_NOT_APPROVED';
  end if;

  insert into public.commercial_checkout_sessions (
    purchase_id,
    provider_id,
    policy_id,
    authorization_id,
    session_key,
    session_status,
    environment,
    amount_minor,
    currency,
    expires_at,
    return_url,
    cancel_url,
    metadata
  ) values (
    p_purchase_id,
    p_provider_id,
    p_policy_id,
    p_authorization_id,
    p_session_key,
    'authorized',
    v_policy.environment,
    p_amount_minor,
    upper(p_currency),
    p_expires_at,
    p_return_url,
    p_cancel_url,
    coalesce(p_metadata, '{}'::jsonb)
  )
  returning * into v_result;

  perform public.append_commercial_checkout_event_internal(
    'CHECKOUT_SESSION_CREATED',
    p_actor,
    v_result.id,
    p_purchase_id,
    p_provider_id,
    null,
    null,
    null,
    null,
    v_result.session_status,
    'Authorized passive checkout session created',
    null,
    null,
    jsonb_build_object('session_key', v_result.session_key)
  );

  return v_result;
end
$$;

create or replace function public.record_commercial_checkout_provider_request_internal(
  p_checkout_session_id uuid,
  p_request_kind text,
  p_idempotency_key text,
  p_execution_attempt_id uuid default null,
  p_actor text default 'service_role',
  p_request_payload jsonb default '{}'::jsonb
)
returns public.commercial_checkout_provider_requests
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_session public.commercial_checkout_sessions;
  v_result public.commercial_checkout_provider_requests;
begin
  select *
  into v_session
  from public.commercial_checkout_sessions
  where id = p_checkout_session_id;

  if not found then
    raise exception 'COMMERCIAL_CHECKOUT_SESSION_NOT_FOUND';
  end if;

  insert into public.commercial_checkout_provider_requests (
    checkout_session_id,
    purchase_id,
    provider_id,
    execution_attempt_id,
    request_kind,
    idempotency_key,
    request_status,
    request_payload
  ) values (
    v_session.id,
    v_session.purchase_id,
    v_session.provider_id,
    p_execution_attempt_id,
    p_request_kind,
    p_idempotency_key,
    'recorded',
    coalesce(p_request_payload, '{}'::jsonb)
  )
  returning * into v_result;

  perform public.append_commercial_checkout_event_internal(
    'PROVIDER_REQUEST_RECORDED',
    p_actor,
    v_session.id,
    v_session.purchase_id,
    v_session.provider_id,
    v_result.id,
    null,
    null,
    v_session.session_status,
    v_session.session_status,
    'Provider request recorded but not dispatched',
    null,
    null,
    jsonb_build_object(
      'request_kind', v_result.request_kind,
      'request_status', v_result.request_status
    )
  );

  return v_result;
end
$$;

create or replace function public.record_commercial_checkout_callback_internal(
  p_provider_id uuid,
  p_provider_event_id text,
  p_callback_type text,
  p_checkout_session_id uuid default null,
  p_purchase_id uuid default null,
  p_payment_provider_event_id uuid default null,
  p_actor text default 'service_role',
  p_payload jsonb default '{}'::jsonb,
  p_headers jsonb default '{}'::jsonb
)
returns public.commercial_checkout_callbacks
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_result public.commercial_checkout_callbacks;
begin
  insert into public.commercial_checkout_callbacks (
    provider_id,
    checkout_session_id,
    purchase_id,
    payment_provider_event_id,
    provider_event_id,
    callback_type,
    callback_status,
    signature_status,
    payload,
    headers
  ) values (
    p_provider_id,
    p_checkout_session_id,
    p_purchase_id,
    p_payment_provider_event_id,
    p_provider_event_id,
    p_callback_type,
    'received',
    'not_evaluated',
    coalesce(p_payload, '{}'::jsonb),
    coalesce(p_headers, '{}'::jsonb)
  )
  returning * into v_result;

  perform public.append_commercial_checkout_event_internal(
    'CALLBACK_RECEIVED',
    p_actor,
    p_checkout_session_id,
    p_purchase_id,
    p_provider_id,
    null,
    v_result.id,
    null,
    null,
    'received',
    'Callback recorded without verification or processing',
    null,
    null,
    jsonb_build_object(
      'provider_event_id', v_result.provider_event_id,
      'callback_type', v_result.callback_type
    )
  );

  return v_result;
end
$$;

create or replace function public.record_commercial_checkout_reconciliation_internal(
  p_purchase_id uuid,
  p_provider_id uuid,
  p_observation_key text,
  p_checkout_session_id uuid default null,
  p_callback_id uuid default null,
  p_local_purchase_status text default null,
  p_local_session_status text default null,
  p_provider_payment_status text default null,
  p_provider_refund_status text default null,
  p_consistency_status text default 'not_evaluated',
  p_recommended_action text default 'none',
  p_actor text default 'service_role',
  p_evidence jsonb default '{}'::jsonb,
  p_notes text default null
)
returns public.commercial_checkout_reconciliation_observations
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_result public.commercial_checkout_reconciliation_observations;
begin
  insert into public.commercial_checkout_reconciliation_observations (
    purchase_id,
    provider_id,
    checkout_session_id,
    callback_id,
    observation_key,
    observation_status,
    local_purchase_status,
    local_session_status,
    provider_payment_status,
    provider_refund_status,
    consistency_status,
    recommended_action,
    evidence,
    notes
  ) values (
    p_purchase_id,
    p_provider_id,
    p_checkout_session_id,
    p_callback_id,
    p_observation_key,
    'observed',
    p_local_purchase_status,
    p_local_session_status,
    p_provider_payment_status,
    p_provider_refund_status,
    p_consistency_status,
    p_recommended_action,
    coalesce(p_evidence, '{}'::jsonb),
    p_notes
  )
  returning * into v_result;

  perform public.append_commercial_checkout_event_internal(
    'RECONCILIATION_OBSERVED',
    p_actor,
    p_checkout_session_id,
    p_purchase_id,
    p_provider_id,
    null,
    p_callback_id,
    v_result.id,
    null,
    v_result.consistency_status,
    'Passive reconciliation observation recorded',
    null,
    null,
    jsonb_build_object(
      'recommended_action', v_result.recommended_action
    )
  );

  return v_result;
end
$$;

create or replace function public.get_commercial_checkout_orchestration_internal(
  p_purchase_id uuid
)
returns jsonb
language sql
security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'purchase_id', p_purchase_id,
    'sessions', coalesce((
      select jsonb_agg(to_jsonb(s) order by s.created_at, s.id)
      from public.commercial_checkout_sessions s
      where s.purchase_id = p_purchase_id
    ), '[]'::jsonb),
    'provider_requests', coalesce((
      select jsonb_agg(to_jsonb(r) order by r.recorded_at, r.id)
      from public.commercial_checkout_provider_requests r
      where r.purchase_id = p_purchase_id
    ), '[]'::jsonb),
    'callbacks', coalesce((
      select jsonb_agg(to_jsonb(c) order by c.received_at, c.id)
      from public.commercial_checkout_callbacks c
      where c.purchase_id = p_purchase_id
    ), '[]'::jsonb),
    'reconciliation_observations', coalesce((
      select jsonb_agg(to_jsonb(o) order by o.observed_at, o.id)
      from public.commercial_checkout_reconciliation_observations o
      where o.purchase_id = p_purchase_id
    ), '[]'::jsonb)
  );
$$;

insert into public.commercial_checkout_orchestration_policies (
  policy_code,
  version,
  policy_status,
  environment,
  session_ttl_seconds,
  callback_tolerance_seconds,
  reconciliation_interval_seconds,
  provider_calls_enabled,
  callback_processing_enabled,
  automatic_reconciliation_enabled,
  automatic_purchase_confirmation_enabled,
  automatic_refund_enabled,
  configuration,
  content_hash,
  created_by
) values (
  'DEFAULT_PROVIDER_CHECKOUT',
  1,
  'draft',
  'test',
  1800,
  300,
  900,
  false,
  false,
  false,
  false,
  false,
  jsonb_build_object(
    'checkout_mode', 'passive',
    'provider_dispatch', 'disabled',
    'callback_processing', 'disabled',
    'economic_mutation', 'forbidden'
  ),
  encode(
    digest(
      'DEFAULT_PROVIDER_CHECKOUT|1|test|passive|provider_dispatch_disabled',
      'sha256'
    ),
    'hex'
  ),
  'MIGRATION_115'
);

select public.append_commercial_checkout_event_internal(
  'CHECKOUT_ORCHESTRATION_POLICY_REGISTERED',
  'MIGRATION_115',
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  'draft',
  'Passive provider checkout orchestration foundation initialized',
  null,
  null,
  jsonb_build_object(
    'policy_code', 'DEFAULT_PROVIDER_CHECKOUT',
    'provider_calls_enabled', false,
    'callback_processing_enabled', false
  )
);

alter table public.commercial_checkout_orchestration_policies enable row level security;
alter table public.commercial_checkout_sessions enable row level security;
alter table public.commercial_checkout_provider_requests enable row level security;
alter table public.commercial_checkout_callbacks enable row level security;
alter table public.commercial_checkout_reconciliation_observations enable row level security;
alter table public.commercial_checkout_orchestration_events enable row level security;

revoke all on table public.commercial_checkout_orchestration_policies from public, anon, authenticated;
revoke all on table public.commercial_checkout_sessions from public, anon, authenticated;
revoke all on table public.commercial_checkout_provider_requests from public, anon, authenticated;
revoke all on table public.commercial_checkout_callbacks from public, anon, authenticated;
revoke all on table public.commercial_checkout_reconciliation_observations from public, anon, authenticated;
revoke all on table public.commercial_checkout_orchestration_events from public, anon, authenticated;

grant select, insert, update on table public.commercial_checkout_orchestration_policies to service_role;
grant select, insert, update on table public.commercial_checkout_sessions to service_role;
grant select, insert, update on table public.commercial_checkout_provider_requests to service_role;
grant select, insert, update on table public.commercial_checkout_callbacks to service_role;
grant select, insert, update on table public.commercial_checkout_reconciliation_observations to service_role;
grant select, insert on table public.commercial_checkout_orchestration_events to service_role;

revoke all on function public.protect_commercial_checkout_policy_internal() from public, anon, authenticated;
revoke all on function public.protect_commercial_checkout_event_internal() from public, anon, authenticated;
revoke all on function public.set_commercial_checkout_updated_at_internal() from public, anon, authenticated;
revoke all on function public.append_commercial_checkout_event_internal(text,text,uuid,uuid,uuid,uuid,uuid,uuid,text,text,text,uuid,uuid,jsonb) from public, anon, authenticated;
revoke all on function public.create_commercial_checkout_session_internal(uuid,uuid,uuid,uuid,text,bigint,text,timestamptz,text,text,text,jsonb) from public, anon, authenticated;
revoke all on function public.record_commercial_checkout_provider_request_internal(uuid,text,text,uuid,text,jsonb) from public, anon, authenticated;
revoke all on function public.record_commercial_checkout_callback_internal(uuid,text,text,uuid,uuid,uuid,text,jsonb,jsonb) from public, anon, authenticated;
revoke all on function public.record_commercial_checkout_reconciliation_internal(uuid,uuid,text,uuid,uuid,text,text,text,text,text,text,text,jsonb,text) from public, anon, authenticated;
revoke all on function public.get_commercial_checkout_orchestration_internal(uuid) from public, anon, authenticated;

grant execute on function public.append_commercial_checkout_event_internal(text,text,uuid,uuid,uuid,uuid,uuid,uuid,text,text,text,uuid,uuid,jsonb) to service_role;
grant execute on function public.create_commercial_checkout_session_internal(uuid,uuid,uuid,uuid,text,bigint,text,timestamptz,text,text,text,jsonb) to service_role;
grant execute on function public.record_commercial_checkout_provider_request_internal(uuid,text,text,uuid,text,jsonb) to service_role;
grant execute on function public.record_commercial_checkout_callback_internal(uuid,text,text,uuid,uuid,uuid,text,jsonb,jsonb) to service_role;
grant execute on function public.record_commercial_checkout_reconciliation_internal(uuid,uuid,text,uuid,uuid,text,text,text,text,text,text,text,jsonb,text) to service_role;
grant execute on function public.get_commercial_checkout_orchestration_internal(uuid) to service_role;

do $$
declare
  v_policy_count bigint;
  v_session_count bigint;
  v_request_count bigint;
  v_callback_count bigint;
  v_reconciliation_count bigint;
  v_event_count bigint;
begin
  select count(*) into v_policy_count
  from public.commercial_checkout_orchestration_policies;

  select count(*) into v_session_count
  from public.commercial_checkout_sessions;

  select count(*) into v_request_count
  from public.commercial_checkout_provider_requests;

  select count(*) into v_callback_count
  from public.commercial_checkout_callbacks;

  select count(*) into v_reconciliation_count
  from public.commercial_checkout_reconciliation_observations;

  select count(*) into v_event_count
  from public.commercial_checkout_orchestration_events;

  if v_policy_count <> 1 then
    raise exception 'MIGRATION_115_POLICY_ASSERTION_FAILED count=%', v_policy_count;
  end if;

  if v_session_count <> 0
     or v_request_count <> 0
     or v_callback_count <> 0
     or v_reconciliation_count <> 0 then
    raise exception
      'MIGRATION_115_PASSIVE_STATE_ASSERTION_FAILED sessions=%, requests=%, callbacks=%, reconciliations=%',
      v_session_count,
      v_request_count,
      v_callback_count,
      v_reconciliation_count;
  end if;

  if v_event_count <> 1 then
    raise exception 'MIGRATION_115_EVENT_ASSERTION_FAILED count=%', v_event_count;
  end if;

  if exists (
    select 1
    from public.commercial_checkout_orchestration_policies
    where provider_calls_enabled
       or callback_processing_enabled
       or automatic_reconciliation_enabled
       or automatic_purchase_confirmation_enabled
       or automatic_refund_enabled
  ) then
    raise exception 'MIGRATION_115_SAFETY_ASSERTION_FAILED';
  end if;

  raise notice
    'MIGRATION_115_CERTIFIED policy_count=%, session_count=%, request_count=%, callback_count=%, reconciliation_count=%, event_count=%',
    v_policy_count,
    v_session_count,
    v_request_count,
    v_callback_count,
    v_reconciliation_count,
    v_event_count;
end
$$;

commit;
