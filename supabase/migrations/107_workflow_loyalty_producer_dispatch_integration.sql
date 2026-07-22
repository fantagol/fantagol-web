-- ============================================================================
-- FANTAGOL
-- Migration: 107_workflow_loyalty_producer_dispatch_integration.sql
-- Milestone: Commercial Platform — Workflow Loyalty Producer Dispatch
--
-- Purpose:
--   - Define the official Workflow Engine -> Loyalty Producer integration layer
--   - Register workflow completion bindings for the ten certified producers
--   - Persist an idempotent dispatch outbox before producer invocation
--   - Support claim, lease, retry, reconciliation and dead-letter recovery
--   - Route only certified workflow evidence into Migration 106
--
-- Architectural rules:
--   - Workflow handlers explicitly enqueue after authoritative certification
--   - No trigger is installed on prediction, match, round or league tables
--   - Workflow internals are not coupled to commercial tables
--   - Producer dispatch is backend/service_role only
--   - All bindings remain disabled and in test mode after installation
--   - Producers, policies, campaigns and reward source remain disabled
-- ============================================================================

begin;

-- ============================================================================
-- 0. DEPENDENCY ASSERTIONS
-- ============================================================================

do $$
begin
  if to_regclass('public.loyalty_event_producers') is null
     or to_regclass('public.loyalty_event_producer_receipts') is null then
    raise exception using
      errcode = 'P0001',
      message = 'MIGRATION_107_REQUIRES_MIGRATION_106';
  end if;

  if to_regclass('public.loyalty_reward_runtime_inbox') is null then
    raise exception using
      errcode = 'P0001',
      message = 'MIGRATION_107_REQUIRES_MIGRATION_105';
  end if;

  if to_regprocedure(
    'public.emit_certified_loyalty_event_internal(text,text,uuid,text,integer,jsonb,timestamp with time zone,uuid,uuid,uuid,uuid,uuid,uuid,jsonb,jsonb)'
  ) is null then
    raise exception using
      errcode = 'P0001',
      message = 'MIGRATION_107_REQUIRES_CERTIFIED_LOYALTY_EMITTER';
  end if;

  if to_regprocedure(
    'public.commercial_append_event_internal(text,text,uuid,uuid,uuid,uuid,jsonb)'
  ) is null then
    raise exception using
      errcode = 'P0001',
      message = 'MIGRATION_107_REQUIRES_COMMERCIAL_EVENT_STORE';
  end if;
end;
$$;

-- ============================================================================
-- 1. WORKFLOW BINDING REGISTRY
-- ============================================================================

create table if not exists public.workflow_loyalty_producer_bindings (
  id uuid primary key default gen_random_uuid(),

  binding_code text not null unique,
  workflow_code text not null,
  completion_step_code text not null,
  producer_code text not null,

  domain_event_code text not null,
  certification_reference_prefix text not null,

  enabled boolean not null default false,
  test_mode boolean not null default true,
  requires_completed_workflow boolean not null default true,
  requires_completed_step boolean not null default true,
  requires_certification_evidence boolean not null default true,

  dispatch_priority integer not null default 100,
  max_attempts integer not null default 8,
  lease_seconds integer not null default 120,

  configuration jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,

  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  version integer not null default 1,

  constraint workflow_loyalty_bindings_producer_code_fkey
    foreign key (producer_code)
    references public.loyalty_event_producers (producer_code)
    on update cascade
    on delete restrict,

  constraint workflow_loyalty_bindings_code_check
    check (binding_code ~ '^[A-Z][A-Z0-9_]{2,119}$'),

  constraint workflow_loyalty_bindings_workflow_code_check
    check (workflow_code ~ '^[a-z][a-z0-9._-]{2,149}$'),

  constraint workflow_loyalty_bindings_step_code_check
    check (completion_step_code ~ '^[a-z][a-z0-9._-]{2,149}$'),

  constraint workflow_loyalty_bindings_event_code_check
    check (domain_event_code ~ '^[A-Z][A-Z0-9_]{2,149}$'),

  constraint workflow_loyalty_bindings_reference_prefix_check
    check (
      certification_reference_prefix ~ '^[a-z][a-z0-9._-]{2,79}$'
    ),

  constraint workflow_loyalty_bindings_priority_check
    check (dispatch_priority between 1 and 10000),

  constraint workflow_loyalty_bindings_attempts_check
    check (max_attempts between 1 and 100),

  constraint workflow_loyalty_bindings_lease_check
    check (lease_seconds between 15 and 3600),

  constraint workflow_loyalty_bindings_configuration_check
    check (jsonb_typeof(configuration) = 'object'),

  constraint workflow_loyalty_bindings_metadata_check
    check (jsonb_typeof(metadata) = 'object'),

  constraint workflow_loyalty_bindings_version_check
    check (version > 0),

  constraint workflow_loyalty_bindings_workflow_producer_key
    unique (workflow_code, completion_step_code, producer_code)
);

comment on table public.workflow_loyalty_producer_bindings is
  'Backend registry mapping authoritative workflow completion steps to certified loyalty producers.';

-- ============================================================================
-- 2. WORKFLOW DISPATCH OUTBOX
-- ============================================================================

create table if not exists public.workflow_loyalty_dispatch_outbox (
  id uuid primary key default gen_random_uuid(),

  binding_id uuid not null,
  binding_code text not null,
  workflow_code text not null,
  workflow_instance_id uuid not null,
  workflow_step_id uuid null,
  workflow_execution_key text not null,

  producer_code text not null,
  producer_event_key text not null,
  domain_event_code text not null,

  user_id uuid not null,
  league_id uuid null,
  league_round_id uuid null,
  season_id uuid null,
  prediction_result_id uuid null,

  certification_reference text not null,
  certification_digest text not null,
  evidence_version integer not null default 1,
  evidence jsonb not null,

  payload jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,

  correlation_id uuid not null,
  causation_id uuid null,

  dispatch_status text not null default 'pending',
  priority integer not null default 100,
  attempt_count integer not null default 0,
  max_attempts integer not null default 8,

  available_at timestamptz not null default clock_timestamp(),
  lease_owner text null,
  lease_token uuid null,
  lease_acquired_at timestamptz null,
  lease_expires_at timestamptz null,

  last_attempt_at timestamptz null,
  dispatched_at timestamptz null,
  dead_lettered_at timestamptz null,

  producer_receipt_id uuid null,
  runtime_inbox_event_id uuid null,

  last_error_code text null,
  last_error_message text null,

  occurred_at timestamptz not null,
  enqueued_at timestamptz not null default clock_timestamp(),
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  version integer not null default 1,

  constraint workflow_loyalty_dispatch_binding_id_fkey
    foreign key (binding_id)
    references public.workflow_loyalty_producer_bindings (id)
    on delete restrict,

  constraint workflow_loyalty_dispatch_producer_code_fkey
    foreign key (producer_code)
    references public.loyalty_event_producers (producer_code)
    on update cascade
    on delete restrict,

  constraint workflow_loyalty_dispatch_user_id_fkey
    foreign key (user_id)
    references auth.users (id)
    on delete restrict,

  constraint workflow_loyalty_dispatch_producer_receipt_id_fkey
    foreign key (producer_receipt_id)
    references public.loyalty_event_producer_receipts (id)
    on delete restrict,

  constraint workflow_loyalty_dispatch_runtime_inbox_event_id_fkey
    foreign key (runtime_inbox_event_id)
    references public.loyalty_reward_runtime_inbox (id)
    on delete restrict,

  constraint workflow_loyalty_dispatch_execution_key_check
    check (length(trim(workflow_execution_key)) between 8 and 300),

  constraint workflow_loyalty_dispatch_event_key_check
    check (length(trim(producer_event_key)) between 8 and 300),

  constraint workflow_loyalty_dispatch_reference_check
    check (length(trim(certification_reference)) between 8 and 500),

  constraint workflow_loyalty_dispatch_digest_check
    check (length(trim(certification_digest)) between 8 and 500),

  constraint workflow_loyalty_dispatch_evidence_version_check
    check (evidence_version between 1 and 1000),

  constraint workflow_loyalty_dispatch_evidence_check
    check (
      jsonb_typeof(evidence) = 'object'
      and evidence <> '{}'::jsonb
    ),

  constraint workflow_loyalty_dispatch_payload_check
    check (jsonb_typeof(payload) = 'object'),

  constraint workflow_loyalty_dispatch_metadata_check
    check (jsonb_typeof(metadata) = 'object'),

  constraint workflow_loyalty_dispatch_status_check
    check (
      dispatch_status in (
        'pending',
        'retry_scheduled',
        'in_flight',
        'dispatched',
        'duplicate',
        'rejected',
        'dead_letter'
      )
    ),

  constraint workflow_loyalty_dispatch_priority_check
    check (priority between 1 and 10000),

  constraint workflow_loyalty_dispatch_attempt_count_check
    check (attempt_count >= 0),

  constraint workflow_loyalty_dispatch_max_attempts_check
    check (max_attempts between 1 and 100),

  constraint workflow_loyalty_dispatch_lease_check
    check (
      (
        dispatch_status = 'in_flight'
        and lease_owner is not null
        and lease_token is not null
        and lease_acquired_at is not null
        and lease_expires_at is not null
      )
      or dispatch_status <> 'in_flight'
    ),

  constraint workflow_loyalty_dispatch_terminal_check
    check (
      (
        dispatch_status in ('dispatched', 'duplicate')
        and producer_receipt_id is not null
        and runtime_inbox_event_id is not null
        and dispatched_at is not null
      )
      or dispatch_status not in ('dispatched', 'duplicate')
    ),

  constraint workflow_loyalty_dispatch_dead_letter_check
    check (
      (
        dispatch_status = 'dead_letter'
        and dead_lettered_at is not null
        and last_error_code is not null
      )
      or dispatch_status <> 'dead_letter'
    ),

  constraint workflow_loyalty_dispatch_version_check
    check (version > 0),

  constraint workflow_loyalty_dispatch_execution_binding_key
    unique (binding_code, workflow_execution_key),

  constraint workflow_loyalty_dispatch_producer_event_key_key
    unique (producer_event_key)
);

create index if not exists workflow_loyalty_dispatch_claim_idx
  on public.workflow_loyalty_dispatch_outbox (
    priority,
    available_at,
    enqueued_at
  )
  where dispatch_status in ('pending', 'retry_scheduled');

create index if not exists workflow_loyalty_dispatch_lease_idx
  on public.workflow_loyalty_dispatch_outbox (lease_expires_at)
  where dispatch_status = 'in_flight';

create index if not exists workflow_loyalty_dispatch_status_idx
  on public.workflow_loyalty_dispatch_outbox (
    dispatch_status,
    enqueued_at desc
  );

create index if not exists workflow_loyalty_dispatch_workflow_idx
  on public.workflow_loyalty_dispatch_outbox (
    workflow_code,
    workflow_instance_id,
    enqueued_at desc
  );

create index if not exists workflow_loyalty_dispatch_user_idx
  on public.workflow_loyalty_dispatch_outbox (
    user_id,
    enqueued_at desc
  );

create index if not exists workflow_loyalty_dispatch_correlation_idx
  on public.workflow_loyalty_dispatch_outbox (correlation_id);

comment on table public.workflow_loyalty_dispatch_outbox is
  'Idempotent backend outbox carrying certified workflow completions to loyalty producers.';

-- ============================================================================
-- 3. APPEND-ONLY DISPATCH ATTEMPTS
-- ============================================================================

create table if not exists public.workflow_loyalty_dispatch_attempts (
  id uuid primary key default gen_random_uuid(),

  outbox_event_id uuid not null,
  attempt_number integer not null,

  worker_id text not null,
  lease_token uuid not null,

  attempt_status text not null,
  producer_receipt_id uuid null,
  runtime_inbox_event_id uuid null,

  response_payload jsonb not null default '{}'::jsonb,

  error_code text null,
  error_message text null,

  started_at timestamptz not null default clock_timestamp(),
  completed_at timestamptz null,
  created_at timestamptz not null default clock_timestamp(),

  constraint workflow_loyalty_attempts_outbox_id_fkey
    foreign key (outbox_event_id)
    references public.workflow_loyalty_dispatch_outbox (id)
    on delete restrict,

  constraint workflow_loyalty_attempts_receipt_id_fkey
    foreign key (producer_receipt_id)
    references public.loyalty_event_producer_receipts (id)
    on delete restrict,

  constraint workflow_loyalty_attempts_runtime_inbox_id_fkey
    foreign key (runtime_inbox_event_id)
    references public.loyalty_reward_runtime_inbox (id)
    on delete restrict,

  constraint workflow_loyalty_attempts_number_check
    check (attempt_number > 0),

  constraint workflow_loyalty_attempts_worker_check
    check (length(trim(worker_id)) between 3 and 200),

  constraint workflow_loyalty_attempts_status_check
    check (
      attempt_status in (
        'started',
        'dispatched',
        'duplicate',
        'rejected',
        'retry_scheduled',
        'dead_letter',
        'lease_lost'
      )
    ),

  constraint workflow_loyalty_attempts_response_check
    check (jsonb_typeof(response_payload) = 'object'),

  constraint workflow_loyalty_attempts_error_code_check
    check (
      error_code is null
      or length(trim(error_code)) between 3 and 200
    ),

  constraint workflow_loyalty_attempts_error_message_check
    check (
      error_message is null
      or length(error_message) <= 4000
    ),

  constraint workflow_loyalty_attempts_unique_attempt
    unique (outbox_event_id, attempt_number)
);

create index if not exists workflow_loyalty_attempts_event_idx
  on public.workflow_loyalty_dispatch_attempts (
    outbox_event_id,
    attempt_number desc
  );

create index if not exists workflow_loyalty_attempts_status_idx
  on public.workflow_loyalty_dispatch_attempts (
    attempt_status,
    started_at desc
  );

comment on table public.workflow_loyalty_dispatch_attempts is
  'Append-only execution history for Workflow Engine to Loyalty Producer dispatch.';

-- ============================================================================
-- 4. UPDATED_AT AND IMMUTABILITY
-- ============================================================================

create or replace function public.set_workflow_loyalty_dispatch_updated_at()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.updated_at := clock_timestamp();
  new.version := old.version + 1;
  return new;
end;
$$;

drop trigger if exists workflow_loyalty_bindings_set_updated_at
  on public.workflow_loyalty_producer_bindings;

create trigger workflow_loyalty_bindings_set_updated_at
before update on public.workflow_loyalty_producer_bindings
for each row
execute function public.set_workflow_loyalty_dispatch_updated_at();

drop trigger if exists workflow_loyalty_outbox_set_updated_at
  on public.workflow_loyalty_dispatch_outbox;

create trigger workflow_loyalty_outbox_set_updated_at
before update on public.workflow_loyalty_dispatch_outbox
for each row
execute function public.set_workflow_loyalty_dispatch_updated_at();

create or replace function public.protect_workflow_loyalty_dispatch_attempts()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  raise exception using
    errcode = '55000',
    message = 'WORKFLOW_LOYALTY_DISPATCH_ATTEMPTS_APPEND_ONLY';
end;
$$;

drop trigger if exists workflow_loyalty_attempts_append_only
  on public.workflow_loyalty_dispatch_attempts;

create trigger workflow_loyalty_attempts_append_only
before update or delete on public.workflow_loyalty_dispatch_attempts
for each row
execute function public.protect_workflow_loyalty_dispatch_attempts();

-- ============================================================================
-- 5. RETRY BACKOFF
-- ============================================================================

create or replace function public.workflow_loyalty_dispatch_retry_delay_seconds(
  p_attempt_count integer
)
returns integer
language sql
immutable
strict
as $$
  select least(
    3600,
    greatest(30, (30 * power(2, greatest(p_attempt_count, 1) - 1))::integer)
  );
$$;

-- ============================================================================
-- 6. ENQUEUE FROM A COMPLETED WORKFLOW HANDLER
-- ============================================================================

create or replace function public.enqueue_workflow_loyalty_dispatch_internal(
  p_binding_code text,
  p_workflow_instance_id uuid,
  p_workflow_step_id uuid,
  p_workflow_execution_key text,
  p_user_id uuid,
  p_certification_reference text,
  p_certification_digest text,
  p_evidence_version integer,
  p_evidence jsonb,
  p_occurred_at timestamptz default clock_timestamp(),
  p_league_id uuid default null,
  p_league_round_id uuid default null,
  p_season_id uuid default null,
  p_prediction_result_id uuid default null,
  p_correlation_id uuid default null,
  p_causation_id uuid default null,
  p_payload jsonb default '{}'::jsonb,
  p_metadata jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_binding public.workflow_loyalty_producer_bindings;
  v_existing public.workflow_loyalty_dispatch_outbox;
  v_created public.workflow_loyalty_dispatch_outbox;
  v_execution_key text := nullif(trim(p_workflow_execution_key), '');
  v_reference text := nullif(trim(p_certification_reference), '');
  v_digest text := nullif(trim(p_certification_digest), '');
  v_correlation_id uuid := coalesce(p_correlation_id, gen_random_uuid());
  v_producer_event_key text;
  v_certified boolean;
  v_workflow_completed boolean;
  v_step_completed boolean;
begin
  select *
  into v_binding
  from public.workflow_loyalty_producer_bindings
  where binding_code = upper(trim(p_binding_code))
  for share;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'WORKFLOW_LOYALTY_BINDING_NOT_REGISTERED';
  end if;

  if not v_binding.enabled then
    raise exception using
      errcode = '55000',
      message = 'WORKFLOW_LOYALTY_BINDING_DISABLED';
  end if;

  if p_workflow_instance_id is null then
    raise exception using
      errcode = '22023',
      message = 'WORKFLOW_LOYALTY_WORKFLOW_INSTANCE_REQUIRED';
  end if;

  if v_binding.requires_completed_step
     and p_workflow_step_id is null then
    raise exception using
      errcode = '22023',
      message = 'WORKFLOW_LOYALTY_WORKFLOW_STEP_REQUIRED';
  end if;

  if v_execution_key is null
     or length(v_execution_key) < 8
     or length(v_execution_key) > 300 then
    raise exception using
      errcode = '22023',
      message = 'WORKFLOW_LOYALTY_EXECUTION_KEY_INVALID';
  end if;

  if p_user_id is null then
    raise exception using
      errcode = '22023',
      message = 'WORKFLOW_LOYALTY_USER_REQUIRED';
  end if;

  if v_reference is null
     or v_reference not like
       v_binding.certification_reference_prefix || ':%' then
    raise exception using
      errcode = '22023',
      message = 'WORKFLOW_LOYALTY_CERTIFICATION_REFERENCE_INVALID';
  end if;

  if v_digest is null or length(v_digest) < 8 then
    raise exception using
      errcode = '22023',
      message = 'WORKFLOW_LOYALTY_CERTIFICATION_DIGEST_INVALID';
  end if;

  if jsonb_typeof(coalesce(p_evidence, '{}'::jsonb)) <> 'object'
     or coalesce(p_evidence, '{}'::jsonb) = '{}'::jsonb then
    raise exception using
      errcode = '22023',
      message = 'WORKFLOW_LOYALTY_CERTIFICATION_EVIDENCE_REQUIRED';
  end if;

  v_certified :=
    coalesce((p_evidence ->> 'certified')::boolean, false);

  v_workflow_completed :=
    coalesce((p_evidence ->> 'workflow_completed')::boolean, false);

  v_step_completed :=
    coalesce((p_evidence ->> 'step_completed')::boolean, false);

  if v_binding.requires_certification_evidence and not v_certified then
    raise exception using
      errcode = '22023',
      message = 'WORKFLOW_LOYALTY_CERTIFIED_FLAG_REQUIRED';
  end if;

  if v_binding.requires_completed_workflow and not v_workflow_completed then
    raise exception using
      errcode = '22023',
      message = 'WORKFLOW_LOYALTY_COMPLETED_WORKFLOW_REQUIRED';
  end if;

  if v_binding.requires_completed_step and not v_step_completed then
    raise exception using
      errcode = '22023',
      message = 'WORKFLOW_LOYALTY_COMPLETED_STEP_REQUIRED';
  end if;

  if nullif(p_evidence ->> 'workflow_code', '') is null
     or p_evidence ->> 'workflow_code' <> v_binding.workflow_code then
    raise exception using
      errcode = '22023',
      message = 'WORKFLOW_LOYALTY_WORKFLOW_CODE_MISMATCH';
  end if;

  if nullif(p_evidence ->> 'completion_step_code', '') is null
     or p_evidence ->> 'completion_step_code'
       <> v_binding.completion_step_code then
    raise exception using
      errcode = '22023',
      message = 'WORKFLOW_LOYALTY_COMPLETION_STEP_CODE_MISMATCH';
  end if;

  if p_evidence ->> 'workflow_instance_id'
       <> p_workflow_instance_id::text then
    raise exception using
      errcode = '22023',
      message = 'WORKFLOW_LOYALTY_WORKFLOW_INSTANCE_EVIDENCE_MISMATCH';
  end if;

  if p_workflow_step_id is not null
     and p_evidence ->> 'workflow_step_id'
       <> p_workflow_step_id::text then
    raise exception using
      errcode = '22023',
      message = 'WORKFLOW_LOYALTY_WORKFLOW_STEP_EVIDENCE_MISMATCH';
  end if;

  if nullif(p_evidence ->> 'certified_at', '') is null then
    raise exception using
      errcode = '22023',
      message = 'WORKFLOW_LOYALTY_CERTIFIED_AT_REQUIRED';
  end if;

  if nullif(p_evidence ->> 'certification_digest', '') is null
     or p_evidence ->> 'certification_digest' <> v_digest then
    raise exception using
      errcode = '22023',
      message = 'WORKFLOW_LOYALTY_CERTIFICATION_DIGEST_MISMATCH';
  end if;

  if jsonb_typeof(coalesce(p_payload, '{}'::jsonb)) <> 'object'
     or jsonb_typeof(coalesce(p_metadata, '{}'::jsonb)) <> 'object' then
    raise exception using
      errcode = '22023',
      message = 'WORKFLOW_LOYALTY_JSON_OBJECT_REQUIRED';
  end if;

  v_producer_event_key :=
    'workflow:' || v_binding.binding_code
    || ':' || v_execution_key;

  perform pg_advisory_xact_lock(
    hashtextextended(
      'workflow-loyalty:' || v_binding.binding_code || ':' || v_execution_key,
      0
    )
  );

  select *
  into v_existing
  from public.workflow_loyalty_dispatch_outbox
  where binding_code = v_binding.binding_code
    and workflow_execution_key = v_execution_key;

  if found then
    if v_existing.workflow_instance_id is distinct from p_workflow_instance_id
       or v_existing.user_id is distinct from p_user_id
       or v_existing.certification_reference is distinct from v_reference
       or v_existing.certification_digest is distinct from v_digest then
      raise exception using
        errcode = '23505',
        message = 'WORKFLOW_LOYALTY_EXECUTION_KEY_CONFLICT';
    end if;

    return jsonb_build_object(
      'created', false,
      'already_exists', true,
      'outbox_event_id', v_existing.id,
      'dispatch_status', v_existing.dispatch_status,
      'producer_receipt_id', v_existing.producer_receipt_id,
      'runtime_inbox_event_id', v_existing.runtime_inbox_event_id,
      'server_time', clock_timestamp()
    );
  end if;

  insert into public.workflow_loyalty_dispatch_outbox (
    binding_id,
    binding_code,
    workflow_code,
    workflow_instance_id,
    workflow_step_id,
    workflow_execution_key,
    producer_code,
    producer_event_key,
    domain_event_code,
    user_id,
    league_id,
    league_round_id,
    season_id,
    prediction_result_id,
    certification_reference,
    certification_digest,
    evidence_version,
    evidence,
    payload,
    metadata,
    correlation_id,
    causation_id,
    dispatch_status,
    priority,
    attempt_count,
    max_attempts,
    available_at,
    occurred_at
  )
  values (
    v_binding.id,
    v_binding.binding_code,
    v_binding.workflow_code,
    p_workflow_instance_id,
    p_workflow_step_id,
    v_execution_key,
    v_binding.producer_code,
    v_producer_event_key,
    v_binding.domain_event_code,
    p_user_id,
    p_league_id,
    p_league_round_id,
    p_season_id,
    p_prediction_result_id,
    v_reference,
    v_digest,
    p_evidence_version,
    p_evidence,
    coalesce(p_payload, '{}'::jsonb),
    coalesce(p_metadata, '{}'::jsonb)
      || jsonb_build_object(
        'binding_version', v_binding.version,
        'workflow_dispatch_contract_version', '1.0',
        'frontend_origin_allowed', false
      ),
    v_correlation_id,
    p_causation_id,
    'pending',
    v_binding.dispatch_priority,
    0,
    v_binding.max_attempts,
    clock_timestamp(),
    coalesce(p_occurred_at, clock_timestamp())
  )
  returning * into v_created;

  perform public.commercial_append_event_internal(
    'WORKFLOW_LOYALTY_DISPATCH_ENQUEUED',
    'WORKFLOW_LOYALTY_DISPATCH',
    v_created.id,
    v_created.user_id,
    v_created.correlation_id,
    v_created.causation_id,
    jsonb_build_object(
      'outbox_event_id', v_created.id,
      'binding_code', v_created.binding_code,
      'workflow_code', v_created.workflow_code,
      'workflow_instance_id', v_created.workflow_instance_id,
      'producer_code', v_created.producer_code,
      'producer_event_key', v_created.producer_event_key
    )
  );

  return jsonb_build_object(
    'created', true,
    'already_exists', false,
    'outbox_event_id', v_created.id,
    'dispatch_status', v_created.dispatch_status,
    'producer_code', v_created.producer_code,
    'producer_event_key', v_created.producer_event_key,
    'server_time', clock_timestamp()
  );
exception
  when invalid_text_representation then
    raise exception using
      errcode = '22023',
      message = 'WORKFLOW_LOYALTY_EVIDENCE_TYPE_INVALID';
end;
$$;

-- ============================================================================
-- 7. CLAIM NEXT DISPATCH
-- ============================================================================

create or replace function public.claim_next_workflow_loyalty_dispatch_internal(
  p_worker_id text,
  p_lease_seconds integer default 120
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_worker_id text := nullif(trim(p_worker_id), '');
  v_lease_seconds integer := greatest(15, least(coalesce(p_lease_seconds, 120), 3600));
  v_event public.workflow_loyalty_dispatch_outbox;
  v_token uuid := gen_random_uuid();
begin
  if v_worker_id is null or length(v_worker_id) < 3 then
    raise exception using
      errcode = '22023',
      message = 'WORKFLOW_LOYALTY_WORKER_ID_INVALID';
  end if;

  select *
  into v_event
  from public.workflow_loyalty_dispatch_outbox
  where dispatch_status in ('pending', 'retry_scheduled')
    and available_at <= clock_timestamp()
  order by priority asc, available_at asc, enqueued_at asc
  for update skip locked
  limit 1;

  if not found then
    return jsonb_build_object(
      'claimed', false,
      'server_time', clock_timestamp()
    );
  end if;

  update public.workflow_loyalty_dispatch_outbox
  set
    dispatch_status = 'in_flight',
    attempt_count = attempt_count + 1,
    last_attempt_at = clock_timestamp(),
    lease_owner = v_worker_id,
    lease_token = v_token,
    lease_acquired_at = clock_timestamp(),
    lease_expires_at = clock_timestamp()
      + make_interval(secs => v_lease_seconds),
    last_error_code = null,
    last_error_message = null
  where id = v_event.id
  returning * into v_event;

  insert into public.workflow_loyalty_dispatch_attempts (
    outbox_event_id,
    attempt_number,
    worker_id,
    lease_token,
    attempt_status,
    response_payload
  )
  values (
    v_event.id,
    v_event.attempt_count,
    v_worker_id,
    v_token,
    'started',
    jsonb_build_object(
      'claimed_at', clock_timestamp(),
      'lease_expires_at', v_event.lease_expires_at
    )
  );

  return jsonb_build_object(
    'claimed', true,
    'outbox_event_id', v_event.id,
    'lease_token', v_token,
    'lease_expires_at', v_event.lease_expires_at,
    'attempt_number', v_event.attempt_count,
    'binding_code', v_event.binding_code,
    'producer_code', v_event.producer_code,
    'server_time', clock_timestamp()
  );
end;
$$;

-- ============================================================================
-- 8. PROCESS CLAIMED DISPATCH
-- ============================================================================

create or replace function public.process_workflow_loyalty_dispatch_internal(
  p_outbox_event_id uuid,
  p_worker_id text,
  p_lease_token uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_event public.workflow_loyalty_dispatch_outbox;
  v_result jsonb;
  v_receipt_id uuid;
  v_runtime_inbox_id uuid;
  v_accepted boolean;
  v_already_exists boolean;
  v_receipt_status text;
  v_error_code text;
  v_error_message text;
  v_delay integer;
  v_next_status text;
begin
  select *
  into v_event
  from public.workflow_loyalty_dispatch_outbox
  where id = p_outbox_event_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'WORKFLOW_LOYALTY_DISPATCH_NOT_FOUND';
  end if;

  if v_event.dispatch_status <> 'in_flight'
     or v_event.lease_owner is distinct from trim(p_worker_id)
     or v_event.lease_token is distinct from p_lease_token
     or v_event.lease_expires_at <= clock_timestamp() then

    insert into public.workflow_loyalty_dispatch_attempts (
      outbox_event_id,
      attempt_number,
      worker_id,
      lease_token,
      attempt_status,
      error_code,
      error_message,
      completed_at
    )
    values (
      v_event.id,
      greatest(v_event.attempt_count, 1),
      coalesce(nullif(trim(p_worker_id), ''), 'unknown-worker'),
      coalesce(p_lease_token, gen_random_uuid()),
      'lease_lost',
      'WORKFLOW_LOYALTY_LEASE_INVALID',
      'Dispatch lease is absent, mismatched or expired',
      clock_timestamp()
    )
    on conflict (outbox_event_id, attempt_number)
    do nothing;

    return jsonb_build_object(
      'processed', false,
      'error_code', 'WORKFLOW_LOYALTY_LEASE_INVALID',
      'server_time', clock_timestamp()
    );
  end if;

  begin
    v_result :=
      public.emit_certified_loyalty_event_internal(
        v_event.producer_code,
        v_event.producer_event_key,
        v_event.user_id,
        v_event.certification_reference,
        v_event.evidence_version,
        v_event.evidence,
        v_event.occurred_at,
        v_event.league_id,
        v_event.league_round_id,
        v_event.season_id,
        v_event.prediction_result_id,
        v_event.correlation_id,
        v_event.causation_id,
        v_event.payload
          || jsonb_build_object(
            'workflow_dispatch_outbox_id', v_event.id,
            'workflow_code', v_event.workflow_code,
            'workflow_instance_id', v_event.workflow_instance_id,
            'workflow_step_id', v_event.workflow_step_id,
            'domain_event_code', v_event.domain_event_code
          ),
        v_event.metadata
          || jsonb_build_object(
            'dispatch_attempt_number', v_event.attempt_count,
            'dispatch_worker_id', v_event.lease_owner
          )
      );

    v_accepted :=
      coalesce((v_result ->> 'accepted')::boolean, false);

    v_already_exists :=
      coalesce((v_result ->> 'already_exists')::boolean, false);

    v_receipt_id :=
      nullif(v_result ->> 'receipt_id', '')::uuid;

    v_runtime_inbox_id :=
      nullif(v_result ->> 'runtime_inbox_event_id', '')::uuid;

    v_receipt_status := nullif(v_result ->> 'receipt_status', '');

    if v_accepted
       and v_receipt_id is not null
       and v_runtime_inbox_id is not null then

      v_next_status := case
        when v_already_exists or v_receipt_status = 'duplicate'
          then 'duplicate'
        else 'dispatched'
      end;

      update public.workflow_loyalty_dispatch_outbox
      set
        dispatch_status = v_next_status,
        producer_receipt_id = v_receipt_id,
        runtime_inbox_event_id = v_runtime_inbox_id,
        dispatched_at = clock_timestamp(),
        lease_owner = null,
        lease_token = null,
        lease_acquired_at = null,
        lease_expires_at = null,
        last_error_code = null,
        last_error_message = null,
        metadata = metadata || jsonb_build_object(
          'producer_response', v_result
        )
      where id = v_event.id;

      update public.workflow_loyalty_dispatch_attempts
      set
        attempt_status = case
          when v_next_status = 'duplicate' then 'duplicate'
          else 'dispatched'
        end,
        producer_receipt_id = v_receipt_id,
        runtime_inbox_event_id = v_runtime_inbox_id,
        response_payload = v_result,
        completed_at = clock_timestamp()
      where outbox_event_id = v_event.id
        and attempt_number = v_event.attempt_count;

      perform public.commercial_append_event_internal(
        'WORKFLOW_LOYALTY_DISPATCH_COMPLETED',
        'WORKFLOW_LOYALTY_DISPATCH',
        v_event.id,
        v_event.user_id,
        v_event.correlation_id,
        v_event.causation_id,
        jsonb_build_object(
          'outbox_event_id', v_event.id,
          'dispatch_status', v_next_status,
          'producer_receipt_id', v_receipt_id,
          'runtime_inbox_event_id', v_runtime_inbox_id,
          'attempt_number', v_event.attempt_count
        )
      );

      return jsonb_build_object(
        'processed', true,
        'dispatch_status', v_next_status,
        'producer_receipt_id', v_receipt_id,
        'runtime_inbox_event_id', v_runtime_inbox_id,
        'server_time', clock_timestamp()
      );
    end if;

    v_error_code :=
      coalesce(
        v_result ->> 'rejection_code',
        'WORKFLOW_LOYALTY_PRODUCER_REJECTED'
      );

    v_error_message := left(v_result::text, 4000);

    update public.workflow_loyalty_dispatch_outbox
    set
      dispatch_status = 'rejected',
      lease_owner = null,
      lease_token = null,
      lease_acquired_at = null,
      lease_expires_at = null,
      last_error_code = v_error_code,
      last_error_message = v_error_message,
      metadata = metadata || jsonb_build_object(
        'producer_response', v_result
      )
    where id = v_event.id;

    update public.workflow_loyalty_dispatch_attempts
    set
      attempt_status = 'rejected',
      response_payload = v_result,
      error_code = v_error_code,
      error_message = v_error_message,
      completed_at = clock_timestamp()
    where outbox_event_id = v_event.id
      and attempt_number = v_event.attempt_count;

    perform public.commercial_append_event_internal(
      'WORKFLOW_LOYALTY_DISPATCH_REJECTED',
      'WORKFLOW_LOYALTY_DISPATCH',
      v_event.id,
      v_event.user_id,
      v_event.correlation_id,
      v_event.causation_id,
      jsonb_build_object(
        'outbox_event_id', v_event.id,
        'producer_code', v_event.producer_code,
        'error_code', v_error_code
      )
    );

    return jsonb_build_object(
      'processed', true,
      'dispatch_status', 'rejected',
      'error_code', v_error_code,
      'server_time', clock_timestamp()
    );

  exception
    when others then
      v_error_code := coalesce(sqlstate, 'P0001');
      v_error_message := left(sqlerrm, 4000);

      if v_event.attempt_count >= v_event.max_attempts then
        v_next_status := 'dead_letter';
      else
        v_next_status := 'retry_scheduled';
      end if;

      v_delay :=
        public.workflow_loyalty_dispatch_retry_delay_seconds(
          v_event.attempt_count
        );

      update public.workflow_loyalty_dispatch_outbox
      set
        dispatch_status = v_next_status,
        available_at = case
          when v_next_status = 'retry_scheduled'
            then clock_timestamp() + make_interval(secs => v_delay)
          else available_at
        end,
        dead_lettered_at = case
          when v_next_status = 'dead_letter'
            then clock_timestamp()
          else null
        end,
        lease_owner = null,
        lease_token = null,
        lease_acquired_at = null,
        lease_expires_at = null,
        last_error_code = v_error_code,
        last_error_message = v_error_message
      where id = v_event.id;

      update public.workflow_loyalty_dispatch_attempts
      set
        attempt_status = case
          when v_next_status = 'dead_letter'
            then 'dead_letter'
          else 'retry_scheduled'
        end,
        error_code = v_error_code,
        error_message = v_error_message,
        response_payload = jsonb_build_object(
          'retry_delay_seconds', v_delay
        ),
        completed_at = clock_timestamp()
      where outbox_event_id = v_event.id
        and attempt_number = v_event.attempt_count;

      perform public.commercial_append_event_internal(
        case
          when v_next_status = 'dead_letter'
            then 'WORKFLOW_LOYALTY_DISPATCH_DEAD_LETTERED'
          else 'WORKFLOW_LOYALTY_DISPATCH_RETRY_SCHEDULED'
        end,
        'WORKFLOW_LOYALTY_DISPATCH',
        v_event.id,
        v_event.user_id,
        v_event.correlation_id,
        v_event.causation_id,
        jsonb_build_object(
          'outbox_event_id', v_event.id,
          'attempt_number', v_event.attempt_count,
          'max_attempts', v_event.max_attempts,
          'error_code', v_error_code,
          'error_message', v_error_message,
          'retry_delay_seconds', v_delay
        )
      );

      return jsonb_build_object(
        'processed', false,
        'dispatch_status', v_next_status,
        'error_code', v_error_code,
        'error_message', v_error_message,
        'retry_delay_seconds', case
          when v_next_status = 'retry_scheduled' then v_delay
          else null
        end,
        'server_time', clock_timestamp()
      );
  end;
end;
$$;

-- ============================================================================
-- 9. BATCH DISPATCH
-- ============================================================================

create or replace function public.dispatch_workflow_loyalty_batch_internal(
  p_worker_id text,
  p_limit integer default 25,
  p_lease_seconds integer default 120
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_limit integer := greatest(1, least(coalesce(p_limit, 25), 500));
  v_index integer;
  v_claim jsonb;
  v_result jsonb;
  v_claimed integer := 0;
  v_dispatched integer := 0;
  v_duplicates integer := 0;
  v_rejected integer := 0;
  v_retried integer := 0;
  v_dead_lettered integer := 0;
begin
  for v_index in 1..v_limit loop
    v_claim :=
      public.claim_next_workflow_loyalty_dispatch_internal(
        p_worker_id,
        p_lease_seconds
      );

    exit when coalesce((v_claim ->> 'claimed')::boolean, false) is false;

    v_claimed := v_claimed + 1;

    v_result :=
      public.process_workflow_loyalty_dispatch_internal(
        (v_claim ->> 'outbox_event_id')::uuid,
        p_worker_id,
        (v_claim ->> 'lease_token')::uuid
      );

    case v_result ->> 'dispatch_status'
      when 'dispatched' then
        v_dispatched := v_dispatched + 1;
      when 'duplicate' then
        v_duplicates := v_duplicates + 1;
      when 'rejected' then
        v_rejected := v_rejected + 1;
      when 'retry_scheduled' then
        v_retried := v_retried + 1;
      when 'dead_letter' then
        v_dead_lettered := v_dead_lettered + 1;
      else
        null;
    end case;
  end loop;

  return jsonb_build_object(
    'worker_id', p_worker_id,
    'claimed_count', v_claimed,
    'dispatched_count', v_dispatched,
    'duplicate_count', v_duplicates,
    'rejected_count', v_rejected,
    'retry_scheduled_count', v_retried,
    'dead_letter_count', v_dead_lettered,
    'server_time', clock_timestamp()
  );
end;
$$;

-- ============================================================================
-- 10. LEASE RECONCILIATION
-- ============================================================================

create or replace function public.reconcile_expired_workflow_loyalty_leases_internal(
  p_limit integer default 500
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_limit integer := greatest(1, least(coalesce(p_limit, 500), 5000));
  v_event record;
  v_reconciled integer := 0;
  v_retry_scheduled integer := 0;
  v_dead_lettered integer := 0;
  v_next_status text;
  v_delay integer;
begin
  for v_event in
    select *
    from public.workflow_loyalty_dispatch_outbox
    where dispatch_status = 'in_flight'
      and lease_expires_at <= clock_timestamp()
    order by lease_expires_at asc
    for update skip locked
    limit v_limit
  loop
    if v_event.attempt_count >= v_event.max_attempts then
      v_next_status := 'dead_letter';
      v_dead_lettered := v_dead_lettered + 1;
    else
      v_next_status := 'retry_scheduled';
      v_retry_scheduled := v_retry_scheduled + 1;
    end if;

    v_delay :=
      public.workflow_loyalty_dispatch_retry_delay_seconds(
        v_event.attempt_count
      );

    update public.workflow_loyalty_dispatch_outbox
    set
      dispatch_status = v_next_status,
      available_at = case
        when v_next_status = 'retry_scheduled'
          then clock_timestamp() + make_interval(secs => v_delay)
        else available_at
      end,
      dead_lettered_at = case
        when v_next_status = 'dead_letter'
          then clock_timestamp()
        else null
      end,
      lease_owner = null,
      lease_token = null,
      lease_acquired_at = null,
      lease_expires_at = null,
      last_error_code = 'WORKFLOW_LOYALTY_LEASE_EXPIRED',
      last_error_message = 'Dispatch lease expired before completion'
    where id = v_event.id;

    update public.workflow_loyalty_dispatch_attempts
    set
      attempt_status = case
        when v_next_status = 'dead_letter'
          then 'dead_letter'
        else 'retry_scheduled'
      end,
      error_code = 'WORKFLOW_LOYALTY_LEASE_EXPIRED',
      error_message = 'Dispatch lease expired before completion',
      response_payload = jsonb_build_object(
        'retry_delay_seconds', v_delay,
        'reconciled', true
      ),
      completed_at = clock_timestamp()
    where outbox_event_id = v_event.id
      and attempt_number = v_event.attempt_count
      and attempt_status = 'started';

    v_reconciled := v_reconciled + 1;
  end loop;

  return jsonb_build_object(
    'reconciled_count', v_reconciled,
    'retry_scheduled_count', v_retry_scheduled,
    'dead_letter_count', v_dead_lettered,
    'server_time', clock_timestamp()
  );
end;
$$;

-- ============================================================================
-- 11. MANUAL DEAD-LETTER REQUEUE
-- ============================================================================

create or replace function public.requeue_workflow_loyalty_dead_letter_internal(
  p_outbox_event_id uuid,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_reason text := nullif(trim(p_reason), '');
  v_event public.workflow_loyalty_dispatch_outbox;
begin
  if v_reason is null or length(v_reason) < 8 then
    raise exception using
      errcode = '22023',
      message = 'WORKFLOW_LOYALTY_REQUEUE_REASON_REQUIRED';
  end if;

  update public.workflow_loyalty_dispatch_outbox
  set
    dispatch_status = 'pending',
    available_at = clock_timestamp(),
    attempt_count = 0,
    dead_lettered_at = null,
    lease_owner = null,
    lease_token = null,
    lease_acquired_at = null,
    lease_expires_at = null,
    last_error_code = null,
    last_error_message = null,
    metadata = metadata || jsonb_build_object(
      'last_manual_requeue_reason', v_reason,
      'last_manual_requeue_at', clock_timestamp()
    )
  where id = p_outbox_event_id
    and dispatch_status = 'dead_letter'
  returning * into v_event;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'WORKFLOW_LOYALTY_DEAD_LETTER_NOT_FOUND';
  end if;

  perform public.commercial_append_event_internal(
    'WORKFLOW_LOYALTY_DISPATCH_REQUEUED',
    'WORKFLOW_LOYALTY_DISPATCH',
    v_event.id,
    v_event.user_id,
    v_event.correlation_id,
    v_event.causation_id,
    jsonb_build_object(
      'outbox_event_id', v_event.id,
      'reason', v_reason
    )
  );

  return jsonb_build_object(
    'requeued', true,
    'outbox_event_id', v_event.id,
    'dispatch_status', v_event.dispatch_status,
    'server_time', clock_timestamp()
  );
end;
$$;

-- ============================================================================
-- 12. BINDING ADMINISTRATION
-- ============================================================================

create or replace function public.set_workflow_loyalty_binding_state_internal(
  p_binding_code text,
  p_enabled boolean,
  p_test_mode boolean,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_reason text := nullif(trim(p_reason), '');
  v_binding public.workflow_loyalty_producer_bindings;
begin
  if v_reason is null or length(v_reason) < 8 then
    raise exception using
      errcode = '22023',
      message = 'WORKFLOW_LOYALTY_BINDING_STATE_REASON_REQUIRED';
  end if;

  update public.workflow_loyalty_producer_bindings
  set
    enabled = coalesce(p_enabled, enabled),
    test_mode = coalesce(p_test_mode, test_mode),
    metadata = metadata || jsonb_build_object(
      'last_state_change_reason', v_reason,
      'last_state_change_at', clock_timestamp()
    )
  where binding_code = upper(trim(p_binding_code))
  returning * into v_binding;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'WORKFLOW_LOYALTY_BINDING_NOT_REGISTERED';
  end if;

  perform public.commercial_append_event_internal(
    'WORKFLOW_LOYALTY_BINDING_STATE_CHANGED',
    'WORKFLOW_LOYALTY_BINDING',
    v_binding.id,
    null,
    gen_random_uuid(),
    null,
    jsonb_build_object(
      'binding_code', v_binding.binding_code,
      'enabled', v_binding.enabled,
      'test_mode', v_binding.test_mode,
      'reason', v_reason
    )
  );

  return jsonb_build_object(
    'updated', true,
    'binding_code', v_binding.binding_code,
    'enabled', v_binding.enabled,
    'test_mode', v_binding.test_mode,
    'server_time', clock_timestamp()
  );
end;
$$;

-- ============================================================================
-- 13. READ MODELS
-- ============================================================================

create or replace view public.workflow_loyalty_binding_registry_v
with (security_invoker = true)
as
select
  b.binding_code,
  b.workflow_code,
  b.completion_step_code,
  b.producer_code,
  p.event_code as producer_event_code,
  b.domain_event_code,
  b.certification_reference_prefix,
  b.enabled,
  b.test_mode,
  p.enabled as producer_enabled,
  p.test_mode as producer_test_mode,
  b.dispatch_priority,
  b.max_attempts,
  b.lease_seconds,
  b.version,
  b.updated_at
from public.workflow_loyalty_producer_bindings b
join public.loyalty_event_producers p
  on p.producer_code = b.producer_code;

create or replace view public.workflow_loyalty_dispatch_status_v
with (security_invoker = true)
as
select
  o.id as outbox_event_id,
  o.binding_code,
  o.workflow_code,
  o.workflow_instance_id,
  o.workflow_step_id,
  o.workflow_execution_key,
  o.producer_code,
  o.producer_event_key,
  o.domain_event_code,
  o.user_id,
  o.league_id,
  o.league_round_id,
  o.season_id,
  o.prediction_result_id,
  o.dispatch_status,
  o.priority,
  o.attempt_count,
  o.max_attempts,
  o.available_at,
  o.lease_owner,
  o.lease_expires_at,
  o.producer_receipt_id,
  o.runtime_inbox_event_id,
  o.last_error_code,
  o.last_error_message,
  o.occurred_at,
  o.enqueued_at,
  o.dispatched_at,
  o.dead_lettered_at,
  o.correlation_id,
  o.causation_id,
  o.updated_at
from public.workflow_loyalty_dispatch_outbox o;

create or replace view public.workflow_loyalty_dispatch_health_v
with (security_invoker = true)
as
select
  count(*) filter (
    where dispatch_status = 'pending'
  )::integer as pending_count,

  count(*) filter (
    where dispatch_status = 'retry_scheduled'
  )::integer as retry_scheduled_count,

  count(*) filter (
    where dispatch_status = 'in_flight'
  )::integer as in_flight_count,

  count(*) filter (
    where dispatch_status = 'dispatched'
  )::integer as dispatched_count,

  count(*) filter (
    where dispatch_status = 'duplicate'
  )::integer as duplicate_count,

  count(*) filter (
    where dispatch_status = 'rejected'
  )::integer as rejected_count,

  count(*) filter (
    where dispatch_status = 'dead_letter'
  )::integer as dead_letter_count,

  min(available_at) filter (
    where dispatch_status in ('pending', 'retry_scheduled')
  ) as oldest_available_at,

  max(dispatched_at) as latest_dispatched_at,

  clock_timestamp() as server_time
from public.workflow_loyalty_dispatch_outbox;

comment on view public.workflow_loyalty_binding_registry_v is
  'Backend projection of Workflow Engine completion bindings to certified loyalty producers.';

comment on view public.workflow_loyalty_dispatch_status_v is
  'Backend operational projection of Workflow Engine loyalty dispatch events.';

comment on view public.workflow_loyalty_dispatch_health_v is
  'Backend health projection for Workflow Engine loyalty dispatch outbox.';

-- ============================================================================
-- 14. SEED TEN WORKFLOW BINDINGS, ALL DISABLED
-- ============================================================================

insert into public.workflow_loyalty_producer_bindings (
  binding_code,
  workflow_code,
  completion_step_code,
  producer_code,
  domain_event_code,
  certification_reference_prefix,
  enabled,
  test_mode,
  dispatch_priority,
  max_attempts,
  lease_seconds,
  configuration,
  metadata
)
values
  (
    'WF_LOYALTY_PREDICTION_EXACT',
    'match-result-certification',
    'certify-match-result',
    'PREDICTION_RESULT_EXACT',
    'CERTIFIED_EXACT_ACHIEVED',
    'prediction-result-certification',
    false,
    true,
    100,
    8,
    120,
    jsonb_build_object('achievement_code', 'EXACT'),
    jsonb_build_object('activation_phase', 'controlled-e2e')
  ),
  (
    'WF_LOYALTY_PREDICTION_GRAND_SLAM',
    'match-result-certification',
    'certify-match-result',
    'PREDICTION_RESULT_GRAND_SLAM',
    'CERTIFIED_GRAND_SLAM_ACHIEVED',
    'prediction-result-certification',
    false,
    true,
    100,
    8,
    120,
    jsonb_build_object('achievement_code', 'GRAND_SLAM'),
    jsonb_build_object('activation_phase', 'controlled-e2e')
  ),
  (
    'WF_LOYALTY_PREDICTION_CANTONATA',
    'match-result-certification',
    'certify-match-result',
    'PREDICTION_RESULT_CANTONATA',
    'CERTIFIED_CANTONATA_ACHIEVED',
    'prediction-result-certification',
    false,
    true,
    100,
    8,
    120,
    jsonb_build_object('achievement_code', 'CANTONATA'),
    jsonb_build_object('activation_phase', 'controlled-e2e')
  ),
  (
    'WF_LOYALTY_LEAGUE_FIRST_ROUND',
    'round-certification',
    'certify-round',
    'LEAGUE_FIRST_ROUND_CERTIFICATION',
    'LEAGUE_FIRST_ROUND_CERTIFIED',
    'round-certification',
    false,
    true,
    110,
    8,
    120,
    jsonb_build_object('required_round_number', 1),
    jsonb_build_object('activation_phase', 'controlled-e2e')
  ),
  (
    'WF_LOYALTY_LEAGUE_8_MEMBERS',
    'league-governance-certification',
    'certify-active-membership-threshold',
    'LEAGUE_REACHED_8_MEMBERS',
    'LEAGUE_REACHED_8_ACTIVE_MEMBERS',
    'league-membership-certification',
    false,
    true,
    120,
    8,
    120,
    jsonb_build_object('minimum_active_members', 8),
    jsonb_build_object('activation_phase', 'controlled-e2e')
  ),
  (
    'WF_LOYALTY_LEAGUE_SEASON_COMPLETE',
    'competition-season-certification',
    'certify-league-season',
    'LEAGUE_SEASON_CERTIFICATION',
    'LEAGUE_SEASON_CERTIFIED_COMPLETE',
    'season-certification',
    false,
    true,
    130,
    8,
    120,
    '{}'::jsonb,
    jsonb_build_object('activation_phase', 'controlled-e2e')
  ),
  (
    'WF_LOYALTY_PROFILE_AFTER_FIRST_ROUND',
    'profile-state-certification',
    'certify-profile-completion',
    'PROFILE_COMPLETION_AFTER_FIRST_ROUND',
    'PROFILE_COMPLETED_AFTER_FIRST_LEAGUE_ROUND',
    'profile-state-certification',
    false,
    true,
    140,
    8,
    120,
    jsonb_build_object('minimum_completed_league_rounds', 1),
    jsonb_build_object('activation_phase', 'controlled-e2e')
  ),
  (
    'WF_LOYALTY_PARTICIPATION_STREAK_5',
    'participation-certification',
    'certify-prediction-streak',
    'PREDICTION_COMPLETION_STREAK_5',
    'COMPLETE_PREDICTIONS_STREAK_5_CERTIFIED',
    'participation-certification',
    false,
    true,
    150,
    8,
    120,
    jsonb_build_object('required_streak', 5),
    jsonb_build_object('activation_phase', 'controlled-e2e')
  ),
  (
    'WF_LOYALTY_PARTICIPATION_STREAK_10',
    'participation-certification',
    'certify-prediction-streak',
    'PREDICTION_COMPLETION_STREAK_10',
    'COMPLETE_PREDICTIONS_STREAK_10_CERTIFIED',
    'participation-certification',
    false,
    true,
    150,
    8,
    120,
    jsonb_build_object('required_streak', 10),
    jsonb_build_object('activation_phase', 'controlled-e2e')
  ),
  (
    'WF_LOYALTY_PARTICIPATION_FULL_SEASON',
    'participation-certification',
    'certify-full-season-participation',
    'PREDICTION_COMPLETION_FULL_SEASON',
    'COMPLETE_PREDICTIONS_FULL_SEASON_CERTIFIED',
    'participation-certification',
    false,
    true,
    160,
    8,
    120,
    jsonb_build_object('scope', 'league_season'),
    jsonb_build_object('activation_phase', 'controlled-e2e')
  )
on conflict (binding_code)
do update
set
  workflow_code = excluded.workflow_code,
  completion_step_code = excluded.completion_step_code,
  producer_code = excluded.producer_code,
  domain_event_code = excluded.domain_event_code,
  certification_reference_prefix =
    excluded.certification_reference_prefix,
  enabled = false,
  test_mode = true,
  requires_completed_workflow = true,
  requires_completed_step = true,
  requires_certification_evidence = true,
  dispatch_priority = excluded.dispatch_priority,
  max_attempts = excluded.max_attempts,
  lease_seconds = excluded.lease_seconds,
  configuration = excluded.configuration,
  metadata = public.workflow_loyalty_producer_bindings.metadata
    || excluded.metadata;

-- ============================================================================
-- 15. RLS AND PRIVILEGES
-- ============================================================================

alter table public.workflow_loyalty_producer_bindings
  enable row level security;

alter table public.workflow_loyalty_dispatch_outbox
  enable row level security;

alter table public.workflow_loyalty_dispatch_attempts
  enable row level security;

-- No client policies.

revoke all on table public.workflow_loyalty_producer_bindings
  from public, anon, authenticated;

revoke all on table public.workflow_loyalty_dispatch_outbox
  from public, anon, authenticated;

revoke all on table public.workflow_loyalty_dispatch_attempts
  from public, anon, authenticated;

revoke all on table public.workflow_loyalty_binding_registry_v
  from public, anon, authenticated;

revoke all on table public.workflow_loyalty_dispatch_status_v
  from public, anon, authenticated;

revoke all on table public.workflow_loyalty_dispatch_health_v
  from public, anon, authenticated;

grant all on table public.workflow_loyalty_producer_bindings
  to service_role;

grant all on table public.workflow_loyalty_dispatch_outbox
  to service_role;

grant all on table public.workflow_loyalty_dispatch_attempts
  to service_role;

grant select on table public.workflow_loyalty_binding_registry_v
  to service_role;

grant select on table public.workflow_loyalty_dispatch_status_v
  to service_role;

grant select on table public.workflow_loyalty_dispatch_health_v
  to service_role;

revoke all on function public.enqueue_workflow_loyalty_dispatch_internal(
  text, uuid, uuid, text, uuid, text, text, integer, jsonb,
  timestamptz, uuid, uuid, uuid, uuid, uuid, uuid, jsonb, jsonb
) from public, anon, authenticated;

revoke all on function public.claim_next_workflow_loyalty_dispatch_internal(
  text, integer
) from public, anon, authenticated;

revoke all on function public.process_workflow_loyalty_dispatch_internal(
  uuid, text, uuid
) from public, anon, authenticated;

revoke all on function public.dispatch_workflow_loyalty_batch_internal(
  text, integer, integer
) from public, anon, authenticated;

revoke all on function public.reconcile_expired_workflow_loyalty_leases_internal(
  integer
) from public, anon, authenticated;

revoke all on function public.requeue_workflow_loyalty_dead_letter_internal(
  uuid, text
) from public, anon, authenticated;

revoke all on function public.set_workflow_loyalty_binding_state_internal(
  text, boolean, boolean, text
) from public, anon, authenticated;

grant execute on function public.enqueue_workflow_loyalty_dispatch_internal(
  text, uuid, uuid, text, uuid, text, text, integer, jsonb,
  timestamptz, uuid, uuid, uuid, uuid, uuid, uuid, jsonb, jsonb
) to service_role;

grant execute on function public.claim_next_workflow_loyalty_dispatch_internal(
  text, integer
) to service_role;

grant execute on function public.process_workflow_loyalty_dispatch_internal(
  uuid, text, uuid
) to service_role;

grant execute on function public.dispatch_workflow_loyalty_batch_internal(
  text, integer, integer
) to service_role;

grant execute on function public.reconcile_expired_workflow_loyalty_leases_internal(
  integer
) to service_role;

grant execute on function public.requeue_workflow_loyalty_dead_letter_internal(
  uuid, text
) to service_role;

grant execute on function public.set_workflow_loyalty_binding_state_internal(
  text, boolean, boolean, text
) to service_role;

-- ============================================================================
-- 16. FINAL ASSERTIONS
-- ============================================================================

do $$
declare
  v_binding_count integer;
  v_enabled_binding_count integer;
  v_enabled_producer_count integer;
  v_enabled_policy_count integer;
  v_enabled_campaign_count integer;
  v_enabled_source_count integer;
  v_outbox_count integer;
  v_attempt_count integer;
begin
  select count(*)
  into v_binding_count
  from public.workflow_loyalty_producer_bindings;

  if v_binding_count <> 10 then
    raise exception using
      errcode = 'P0001',
      message = 'WORKFLOW_LOYALTY_BINDINGS_EXPECTED_10';
  end if;

  select count(*)
  into v_enabled_binding_count
  from public.workflow_loyalty_producer_bindings
  where enabled = true;

  if v_enabled_binding_count <> 0 then
    raise exception using
      errcode = 'P0001',
      message = 'WORKFLOW_LOYALTY_BINDINGS_MUST_REMAIN_DISABLED';
  end if;

  select count(*)
  into v_enabled_producer_count
  from public.loyalty_event_producers
  where enabled = true;

  select count(*)
  into v_enabled_policy_count
  from public.loyalty_reward_policies
  where enabled = true;

  select count(*)
  into v_enabled_campaign_count
  from public.reward_campaigns
  where campaign_code like 'LOYALTY_%'
    and enabled = true;

  select count(*)
  into v_enabled_source_count
  from public.reward_sources
  where source_code = 'INTERNAL_ACHIEVEMENT'
    and enabled = true;

  if v_enabled_producer_count <> 0
     or v_enabled_policy_count <> 0
     or v_enabled_campaign_count <> 0
     or v_enabled_source_count <> 0 then
    raise exception using
      errcode = 'P0001',
      message = 'WORKFLOW_LOYALTY_MIGRATION_MUST_NOT_ACTIVATE_REWARDS';
  end if;

  select count(*)
  into v_outbox_count
  from public.workflow_loyalty_dispatch_outbox;

  select count(*)
  into v_attempt_count
  from public.workflow_loyalty_dispatch_attempts;

  if v_outbox_count <> 0 or v_attempt_count <> 0 then
    raise exception using
      errcode = 'P0001',
      message = 'WORKFLOW_LOYALTY_RUNTIME_MUST_START_EMPTY';
  end if;

  if to_regprocedure(
    'public.enqueue_workflow_loyalty_dispatch_internal(text,uuid,uuid,text,uuid,text,text,integer,jsonb,timestamp with time zone,uuid,uuid,uuid,uuid,uuid,uuid,jsonb,jsonb)'
  ) is null then
    raise exception using
      errcode = 'P0001',
      message = 'WORKFLOW_LOYALTY_ENQUEUE_FUNCTION_MISSING';
  end if;

  if to_regprocedure(
    'public.dispatch_workflow_loyalty_batch_internal(text,integer,integer)'
  ) is null then
    raise exception using
      errcode = 'P0001',
      message = 'WORKFLOW_LOYALTY_BATCH_DISPATCH_FUNCTION_MISSING';
  end if;

  raise notice 'WORKFLOW LOYALTY PRODUCER DISPATCH INTEGRATION CERTIFIED';
  raise notice '10 workflow completion bindings registered and disabled';
  raise notice 'Idempotent dispatch outbox and append-only attempts installed';
  raise notice 'Lease, retry, reconciliation and dead-letter recovery installed';
  raise notice 'Certified workflow evidence can route to Migration 106 producers';
  raise notice 'No game-table trigger or Workflow Engine table coupling introduced';
  raise notice 'No binding, producer, policy, campaign or reward source enabled';
  raise notice 'TypeScript workflow handler wiring and controlled E2E remain pending';
end;
$$;

commit;
