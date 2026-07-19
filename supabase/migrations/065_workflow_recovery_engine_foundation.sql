-- ============================================================================
-- FANTAGOL
-- Migration 065 - Workflow Recovery Engine Foundation
-- Milestone 7.3.3
--
-- Purpose
--   Introduce an idempotent, auditable and worker-safe command foundation for
--   workflow retry, resume, replay, cancellation and dead-state management.
--
-- Architectural boundary
--   This migration does not execute domain handlers directly. It persists and
--   governs recovery commands, exposes a claimable outbox, records attempts,
--   and projects recovery transitions into Workflow Observability.
-- ============================================================================

begin;

-- --------------------------------------------------------------------------
-- 1. Recovery policies
-- --------------------------------------------------------------------------

create table if not exists public.live_runtime_recovery_policies (
  id uuid primary key default extensions.gen_random_uuid(),
  policy_key text not null,
  policy_version integer not null default 1,
  display_name text not null,
  is_active boolean not null default true,

  max_attempts integer not null default 3,
  initial_delay_seconds integer not null default 30,
  backoff_multiplier numeric(8,4) not null default 2.0,
  max_delay_seconds integer not null default 3600,
  lease_seconds integer not null default 300,

  allowed_actions text[] not null default array[
    'retry', 'resume', 'replay', 'cancel', 'mark_dead'
  ]::text[],

  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),

  constraint live_runtime_recovery_policies_key_uq
    unique (policy_key, policy_version),

  constraint live_runtime_recovery_policies_identity_ck
    check (
      length(btrim(policy_key)) > 0
      and length(btrim(display_name)) > 0
      and policy_version > 0
    ),

  constraint live_runtime_recovery_policies_limits_ck
    check (
      max_attempts > 0
      and initial_delay_seconds >= 0
      and backoff_multiplier >= 1
      and max_delay_seconds >= initial_delay_seconds
      and lease_seconds between 30 and 86400
    ),

  constraint live_runtime_recovery_policies_actions_ck
    check (
      allowed_actions <@ array[
        'retry', 'resume', 'replay', 'cancel', 'mark_dead'
      ]::text[]
      and cardinality(allowed_actions) > 0
    )
);

comment on table public.live_runtime_recovery_policies
is 'Versioned retry, lease and action policies used by Workflow Recovery commands.';

drop trigger if exists trg_live_runtime_recovery_policies_updated_at
  on public.live_runtime_recovery_policies;

create trigger trg_live_runtime_recovery_policies_updated_at
before update on public.live_runtime_recovery_policies
for each row execute function public.set_workflow_observability_updated_at();

insert into public.live_runtime_recovery_policies (
  policy_key,
  policy_version,
  display_name,
  max_attempts,
  initial_delay_seconds,
  backoff_multiplier,
  max_delay_seconds,
  lease_seconds,
  allowed_actions,
  metadata
)
values (
  'default',
  1,
  'Default Workflow Recovery Policy',
  3,
  30,
  2.0,
  3600,
  300,
  array['retry', 'resume', 'replay', 'cancel', 'mark_dead']::text[],
  jsonb_build_object(
    'engine_version', 'workflow-recovery-v1',
    'description', 'Default policy for controlled workflow recovery'
  )
)
on conflict (policy_key, policy_version) do nothing;

-- --------------------------------------------------------------------------
-- 2. Recovery requests
-- --------------------------------------------------------------------------

create table if not exists public.live_runtime_recovery_requests (
  id uuid primary key default extensions.gen_random_uuid(),

  workflow_instance_id uuid not null,
  workflow_key text not null,
  recovery_action text not null,
  status text not null default 'requested',

  idempotency_key text not null,
  correlation_id uuid,
  causation_id uuid,
  source_workflow_status text not null,
  source_step_instance_id uuid,
  source_step_key text,
  source_job_id uuid,

  policy_key text not null default 'default',
  policy_version integer not null default 1,
  max_attempts integer not null,
  attempt_count integer not null default 0,

  requested_by text not null,
  request_reason text,
  requested_at timestamptz not null default clock_timestamp(),
  scheduled_at timestamptz not null default clock_timestamp(),

  claimed_at timestamptz,
  claimed_by text,
  lease_expires_at timestamptz,

  started_at timestamptz,
  completed_at timestamptz,
  failed_at timestamptz,
  cancelled_at timestamptz,

  replay_workflow_instance_id uuid,
  last_error_code text,
  last_error_message text,
  last_error_details jsonb,

  command_payload jsonb not null default '{}'::jsonb,
  result_payload jsonb,
  metadata jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default clock_timestamp(),

  constraint live_runtime_recovery_requests_idempotency_uq
    unique (idempotency_key),

  constraint live_runtime_recovery_requests_action_ck
    check (recovery_action in (
      'retry', 'resume', 'replay', 'cancel', 'mark_dead'
    )),

  constraint live_runtime_recovery_requests_status_ck
    check (status in (
      'requested',
      'scheduled',
      'claimed',
      'running',
      'completed',
      'failed',
      'cancelled',
      'dead'
    )),

  constraint live_runtime_recovery_requests_identity_ck
    check (
      length(btrim(workflow_key)) > 0
      and length(btrim(idempotency_key)) > 0
      and length(btrim(requested_by)) > 0
      and length(btrim(policy_key)) > 0
      and policy_version > 0
    ),

  constraint live_runtime_recovery_requests_attempts_ck
    check (
      max_attempts > 0
      and attempt_count >= 0
      and attempt_count <= max_attempts
    ),

  constraint live_runtime_recovery_requests_terminal_ck
    check (
      (status <> 'completed' or completed_at is not null)
      and (status not in ('failed', 'dead') or failed_at is not null)
      and (status <> 'cancelled' or cancelled_at is not null)
    ),

  constraint live_runtime_recovery_requests_lease_ck
    check (
      (claimed_at is null and claimed_by is null and lease_expires_at is null)
      or
      (claimed_at is not null and claimed_by is not null and lease_expires_at is not null)
    )
);

comment on table public.live_runtime_recovery_requests
is 'Authoritative idempotent command registry for workflow recovery operations.';

create index if not exists live_runtime_recovery_requests_workflow_idx
  on public.live_runtime_recovery_requests (
    workflow_instance_id,
    requested_at desc
  );

create index if not exists live_runtime_recovery_requests_queue_idx
  on public.live_runtime_recovery_requests (
    status,
    scheduled_at,
    requested_at
  )
  where status in ('requested', 'scheduled');

create index if not exists live_runtime_recovery_requests_lease_idx
  on public.live_runtime_recovery_requests (
    lease_expires_at
  )
  where status in ('claimed', 'running');

create index if not exists live_runtime_recovery_requests_correlation_idx
  on public.live_runtime_recovery_requests (
    correlation_id,
    requested_at
  )
  where correlation_id is not null;

drop trigger if exists trg_live_runtime_recovery_requests_updated_at
  on public.live_runtime_recovery_requests;

create trigger trg_live_runtime_recovery_requests_updated_at
before update on public.live_runtime_recovery_requests
for each row execute function public.set_workflow_observability_updated_at();

-- --------------------------------------------------------------------------
-- 3. Recovery attempts
-- --------------------------------------------------------------------------

create table if not exists public.live_runtime_recovery_attempts (
  id uuid primary key default extensions.gen_random_uuid(),
  recovery_request_id uuid not null
    references public.live_runtime_recovery_requests(id)
    on delete cascade,

  attempt_no integer not null,
  status text not null default 'started',
  worker_id text not null,
  lease_token uuid not null default extensions.gen_random_uuid(),

  started_at timestamptz not null default clock_timestamp(),
  finished_at timestamptz,
  next_retry_at timestamptz,

  error_code text,
  error_message text,
  error_details jsonb,
  result_payload jsonb,
  metadata jsonb not null default '{}'::jsonb,

  constraint live_runtime_recovery_attempts_request_no_uq
    unique (recovery_request_id, attempt_no),

  constraint live_runtime_recovery_attempts_status_ck
    check (status in (
      'started', 'completed', 'failed', 'retry_scheduled', 'cancelled'
    )),

  constraint live_runtime_recovery_attempts_identity_ck
    check (attempt_no > 0 and length(btrim(worker_id)) > 0),

  constraint live_runtime_recovery_attempts_finished_ck
    check (
      (status = 'started' and finished_at is null)
      or
      (status <> 'started' and finished_at is not null)
    )
);

comment on table public.live_runtime_recovery_attempts
is 'Immutable attempt history for every claimed Workflow Recovery command.';

create index if not exists live_runtime_recovery_attempts_request_idx
  on public.live_runtime_recovery_attempts (
    recovery_request_id,
    attempt_no desc
  );

-- --------------------------------------------------------------------------
-- 4. Recovery outbox
-- --------------------------------------------------------------------------

create table if not exists public.live_runtime_recovery_outbox (
  id uuid primary key default extensions.gen_random_uuid(),
  recovery_request_id uuid not null
    references public.live_runtime_recovery_requests(id)
    on delete cascade,

  command_type text not null,
  command_key text not null,
  status text not null default 'pending',

  available_at timestamptz not null default clock_timestamp(),
  claimed_at timestamptz,
  claimed_by text,
  lease_expires_at timestamptz,

  delivered_at timestamptz,
  failed_at timestamptz,
  delivery_attempts integer not null default 0,

  payload jsonb not null,
  last_error_code text,
  last_error_message text,
  last_error_details jsonb,

  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),

  constraint live_runtime_recovery_outbox_command_key_uq
    unique (command_key),

  constraint live_runtime_recovery_outbox_type_ck
    check (command_type in (
      'retry_workflow',
      'resume_workflow',
      'replay_workflow',
      'cancel_workflow',
      'mark_workflow_dead'
    )),

  constraint live_runtime_recovery_outbox_status_ck
    check (status in (
      'pending', 'claimed', 'delivered', 'failed', 'cancelled'
    )),

  constraint live_runtime_recovery_outbox_attempts_ck
    check (delivery_attempts >= 0),

  constraint live_runtime_recovery_outbox_lease_ck
    check (
      (claimed_at is null and claimed_by is null and lease_expires_at is null)
      or
      (claimed_at is not null and claimed_by is not null and lease_expires_at is not null)
    )
);

comment on table public.live_runtime_recovery_outbox
is 'Claimable command outbox consumed by the runtime recovery worker.';

create index if not exists live_runtime_recovery_outbox_pending_idx
  on public.live_runtime_recovery_outbox (
    available_at,
    created_at
  )
  where status = 'pending';

create index if not exists live_runtime_recovery_outbox_lease_idx
  on public.live_runtime_recovery_outbox (
    lease_expires_at
  )
  where status = 'claimed';

drop trigger if exists trg_live_runtime_recovery_outbox_updated_at
  on public.live_runtime_recovery_outbox;

create trigger trg_live_runtime_recovery_outbox_updated_at
before update on public.live_runtime_recovery_outbox
for each row execute function public.set_workflow_observability_updated_at();

-- --------------------------------------------------------------------------
-- 5. Recovery eligibility and status read models
-- --------------------------------------------------------------------------

create or replace view public.live_runtime_workflow_recovery_eligibility_v as
select
  w.workflow_instance_id,
  w.workflow_key,
  w.status as workflow_status,
  w.health_state,
  w.diagnostic_priority,
  w.correlation_id,
  w.current_step_key,
  w.current_step_index,
  w.last_error_code,
  w.last_error_message,
  w.last_transition_at,

  (w.status in ('failed', 'dead', 'retry_scheduled', 'waiting'))
    as can_retry,

  (w.status in ('failed', 'dead', 'retry_scheduled', 'waiting', 'cancelled'))
    as can_resume,

  (w.status in ('completed', 'failed', 'dead', 'cancelled'))
    as can_replay,

  (w.status in ('created', 'queued', 'running', 'waiting', 'retry_scheduled'))
    as can_cancel,

  (w.status in ('failed', 'retry_scheduled', 'waiting'))
    as can_mark_dead,

  exists (
    select 1
    from public.live_runtime_recovery_requests r
    where r.workflow_instance_id = w.workflow_instance_id
      and r.status in ('requested', 'scheduled', 'claimed', 'running')
  ) as has_active_recovery,

  (
    select max(r.requested_at)
    from public.live_runtime_recovery_requests r
    where r.workflow_instance_id = w.workflow_instance_id
  ) as last_recovery_requested_at,

  (
    select count(*)::integer
    from public.live_runtime_recovery_requests r
    where r.workflow_instance_id = w.workflow_instance_id
  ) as recovery_request_count

from public.live_runtime_workflow_diagnostics_v w;

comment on view public.live_runtime_workflow_recovery_eligibility_v
is 'Recovery eligibility projection derived from current workflow status and active recovery commands.';

create or replace view public.live_runtime_recovery_status_v as
select
  r.*,
  w.health_state as workflow_health_state,
  w.diagnostic_priority as workflow_diagnostic_priority,
  w.current_step_key,
  w.current_step_index,
  o.id as outbox_id,
  o.status as outbox_status,
  o.available_at as outbox_available_at,
  o.delivery_attempts as outbox_delivery_attempts,
  case
    when r.status in ('failed', 'dead') then 'error'
    when r.status in ('claimed', 'running') and r.lease_expires_at < clock_timestamp()
      then 'warning'
    when r.status in ('requested', 'scheduled', 'claimed', 'running')
      then 'active'
    when r.status = 'completed' then 'healthy'
    else 'neutral'
  end as recovery_health_state,
  (
    r.status in ('claimed', 'running')
    and r.lease_expires_at < clock_timestamp()
  ) as lease_expired
from public.live_runtime_recovery_requests r
left join public.live_runtime_workflow_diagnostics_v w
  on w.workflow_instance_id = r.workflow_instance_id
left join public.live_runtime_recovery_outbox o
  on o.recovery_request_id = r.id;

comment on view public.live_runtime_recovery_status_v
is 'Operational projection of recovery requests, outbox delivery and worker lease health.';

create or replace view public.live_runtime_recovery_attention_v as
select *
from public.live_runtime_recovery_status_v
where status in ('failed', 'dead')
   or lease_expired
   or (
     status in ('requested', 'scheduled')
     and scheduled_at <= clock_timestamp() - interval '15 minutes'
   )
order by
  case
    when status = 'dead' then 100
    when status = 'failed' then 90
    when lease_expired then 80
    else 60
  end desc,
  requested_at asc;

comment on view public.live_runtime_recovery_attention_v
is 'Recovery commands requiring operator attention.';

-- --------------------------------------------------------------------------
-- 6. Request Recovery RPC
-- --------------------------------------------------------------------------

create or replace function public.request_live_runtime_workflow_recovery_rpc(
  p_workflow_instance_id uuid,
  p_recovery_action text,
  p_idempotency_key text,
  p_requested_by text,
  p_request_reason text default null,
  p_policy_key text default 'default',
  p_policy_version integer default 1,
  p_scheduled_at timestamptz default clock_timestamp(),
  p_source_step_instance_id uuid default null,
  p_source_job_id uuid default null,
  p_command_payload jsonb default '{}'::jsonb,
  p_metadata jsonb default '{}'::jsonb
)
returns public.live_runtime_recovery_status_v
language plpgsql
security definer
set search_path = public, extensions, pg_catalog
as $$
declare
  v_workflow public.live_runtime_workflow_registry%rowtype;
  v_policy public.live_runtime_recovery_policies%rowtype;
  v_request public.live_runtime_recovery_requests%rowtype;
  v_source_step public.live_runtime_workflow_step_registry%rowtype;
  v_command_type text;
  v_allowed boolean := false;
  v_result public.live_runtime_recovery_status_v%rowtype;
begin
  if p_workflow_instance_id is null then
    raise exception using errcode = '22004',
      message = 'workflow_instance_id is required';
  end if;

  if p_recovery_action not in (
    'retry', 'resume', 'replay', 'cancel', 'mark_dead'
  ) then
    raise exception using errcode = '22023',
      message = 'unsupported recovery_action';
  end if;

  if p_idempotency_key is null or length(btrim(p_idempotency_key)) = 0 then
    raise exception using errcode = '22023',
      message = 'idempotency_key is required';
  end if;

  if p_requested_by is null or length(btrim(p_requested_by)) = 0 then
    raise exception using errcode = '22023',
      message = 'requested_by is required';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(p_workflow_instance_id::text, 6503)
  );

  select *
  into v_workflow
  from public.live_runtime_workflow_registry
  where workflow_instance_id = p_workflow_instance_id
  for update;

  if not found then
    raise exception using errcode = 'P0002',
      message = 'workflow instance not found';
  end if;

  select *
  into v_policy
  from public.live_runtime_recovery_policies
  where policy_key = p_policy_key
    and policy_version = p_policy_version
    and is_active;

  if not found then
    raise exception using errcode = 'P0002',
      message = 'active recovery policy not found';
  end if;

  if not (p_recovery_action = any(v_policy.allowed_actions)) then
    raise exception using errcode = '42501',
      message = 'recovery action is not allowed by selected policy';
  end if;

  v_allowed := case p_recovery_action
    when 'retry' then v_workflow.status in (
      'failed', 'dead', 'retry_scheduled', 'waiting'
    )
    when 'resume' then v_workflow.status in (
      'failed', 'dead', 'retry_scheduled', 'waiting', 'cancelled'
    )
    when 'replay' then v_workflow.status in (
      'completed', 'failed', 'dead', 'cancelled'
    )
    when 'cancel' then v_workflow.status in (
      'created', 'queued', 'running', 'waiting', 'retry_scheduled'
    )
    when 'mark_dead' then v_workflow.status in (
      'failed', 'retry_scheduled', 'waiting'
    )
    else false
  end;

  if not v_allowed then
    raise exception using errcode = '55000',
      message = format(
        'recovery action %s is not allowed from workflow status %s',
        p_recovery_action,
        v_workflow.status
      );
  end if;

  if exists (
    select 1
    from public.live_runtime_recovery_requests r
    where r.workflow_instance_id = p_workflow_instance_id
      and r.status in ('requested', 'scheduled', 'claimed', 'running')
      and r.idempotency_key <> btrim(p_idempotency_key)
  ) then
    raise exception using errcode = '55000',
      message = 'workflow already has an active recovery request';
  end if;

  if p_source_step_instance_id is not null then
    select *
    into v_source_step
    from public.live_runtime_workflow_step_registry
    where workflow_instance_id = p_workflow_instance_id
      and step_instance_id = p_source_step_instance_id;

    if not found then
      raise exception using errcode = 'P0002',
        message = 'source step does not belong to workflow';
    end if;
  end if;

  v_command_type := case p_recovery_action
    when 'retry' then 'retry_workflow'
    when 'resume' then 'resume_workflow'
    when 'replay' then 'replay_workflow'
    when 'cancel' then 'cancel_workflow'
    when 'mark_dead' then 'mark_workflow_dead'
  end;

  insert into public.live_runtime_recovery_requests (
    workflow_instance_id,
    workflow_key,
    recovery_action,
    status,
    idempotency_key,
    correlation_id,
    source_workflow_status,
    source_step_instance_id,
    source_step_key,
    source_job_id,
    policy_key,
    policy_version,
    max_attempts,
    requested_by,
    request_reason,
    scheduled_at,
    command_payload,
    metadata
  )
  values (
    v_workflow.workflow_instance_id,
    v_workflow.workflow_key,
    p_recovery_action,
    case
      when coalesce(p_scheduled_at, clock_timestamp()) > clock_timestamp()
        then 'scheduled'
      else 'requested'
    end,
    btrim(p_idempotency_key),
    coalesce(v_workflow.correlation_id, extensions.gen_random_uuid()),
    v_workflow.status,
    p_source_step_instance_id,
    v_source_step.step_key,
    coalesce(p_source_job_id, v_source_step.job_id),
    v_policy.policy_key,
    v_policy.policy_version,
    v_policy.max_attempts,
    btrim(p_requested_by),
    p_request_reason,
    coalesce(p_scheduled_at, clock_timestamp()),
    coalesce(p_command_payload, '{}'::jsonb),
    coalesce(p_metadata, '{}'::jsonb)
      || jsonb_build_object(
        'engine_version', 'workflow-recovery-v1',
        'policy_lease_seconds', v_policy.lease_seconds
      )
  )
  on conflict (idempotency_key) do update
  set idempotency_key = excluded.idempotency_key
  returning *
  into v_request;

  insert into public.live_runtime_recovery_outbox (
    recovery_request_id,
    command_type,
    command_key,
    status,
    available_at,
    payload
  )
  values (
    v_request.id,
    v_command_type,
    'workflow-recovery:' || v_request.idempotency_key,
    'pending',
    v_request.scheduled_at,
    jsonb_build_object(
      'recovery_request_id', v_request.id,
      'workflow_instance_id', v_request.workflow_instance_id,
      'workflow_key', v_request.workflow_key,
      'recovery_action', v_request.recovery_action,
      'source_workflow_status', v_request.source_workflow_status,
      'source_step_instance_id', v_request.source_step_instance_id,
      'source_job_id', v_request.source_job_id,
      'correlation_id', v_request.correlation_id,
      'policy_key', v_request.policy_key,
      'policy_version', v_request.policy_version,
      'command_payload', v_request.command_payload,
      'metadata', v_request.metadata
    )
  )
  on conflict (command_key) do nothing;

  perform public.record_live_runtime_workflow_event_rpc(
    p_workflow_instance_id => v_workflow.workflow_instance_id,
    p_workflow_key => v_workflow.workflow_key,
    p_event_type => 'workflow_recovery_requested',
    p_correlation_id => v_request.correlation_id,
    p_causation_id => v_request.id,
    p_step_instance_id => v_request.source_step_instance_id,
    p_step_key => v_request.source_step_key,
    p_step_index => v_source_step.step_index,
    p_job_id => v_request.source_job_id,
    p_scheduled_at => v_request.scheduled_at,
    p_payload => jsonb_build_object(
      'recovery_request_id', v_request.id,
      'recovery_action', v_request.recovery_action,
      'idempotency_key', v_request.idempotency_key,
      'requested_by', v_request.requested_by,
      'request_reason', v_request.request_reason
    ),
    p_metadata => jsonb_build_object(
      'recovery_request_id', v_request.id,
      'recovery_action', v_request.recovery_action,
      'recovery_status', v_request.status
    )
  );

  select s.*
  into v_result
  from public.live_runtime_recovery_status_v s
  where s.id = v_request.id;

  return v_result;
end;
$$;

comment on function public.request_live_runtime_workflow_recovery_rpc(
  uuid, text, text, text, text, text, integer, timestamptz,
  uuid, uuid, jsonb, jsonb
)
is 'Creates one idempotent workflow recovery request and its worker command outbox item.';

-- --------------------------------------------------------------------------
-- 7. Claim Recovery Command RPC
-- --------------------------------------------------------------------------

create or replace function public.claim_live_runtime_recovery_command_rpc(
  p_worker_id text,
  p_lease_seconds integer default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_catalog
as $$
declare
  v_outbox public.live_runtime_recovery_outbox%rowtype;
  v_request public.live_runtime_recovery_requests%rowtype;
  v_policy public.live_runtime_recovery_policies%rowtype;
  v_lease_seconds integer;
  v_attempt public.live_runtime_recovery_attempts%rowtype;
  v_now timestamptz := clock_timestamp();
begin
  if p_worker_id is null or length(btrim(p_worker_id)) = 0 then
    raise exception using errcode = '22023',
      message = 'worker_id is required';
  end if;

  select o.*
  into v_outbox
  from public.live_runtime_recovery_outbox o
  where (
      o.status = 'pending'
      or (
        o.status = 'claimed'
        and o.lease_expires_at < v_now
      )
    )
    and o.available_at <= v_now
  order by o.available_at, o.created_at, o.id
  for update skip locked
  limit 1;

  if not found then
    return null;
  end if;

  select *
  into v_request
  from public.live_runtime_recovery_requests
  where id = v_outbox.recovery_request_id
  for update;

  if v_request.status in ('completed', 'cancelled', 'dead') then
    update public.live_runtime_recovery_outbox
    set status = 'cancelled',
        claimed_at = null,
        claimed_by = null,
        lease_expires_at = null
    where id = v_outbox.id;

    return null;
  end if;

  if v_request.attempt_count >= v_request.max_attempts then
    update public.live_runtime_recovery_requests
    set status = 'dead',
        failed_at = coalesce(failed_at, v_now),
        last_error_code = 'RECOVERY_MAX_ATTEMPTS_EXCEEDED',
        last_error_message = 'Recovery request exceeded maximum attempts',
        claimed_at = null,
        claimed_by = null,
        lease_expires_at = null
    where id = v_request.id;

    update public.live_runtime_recovery_outbox
    set status = 'failed',
        failed_at = v_now,
        claimed_at = null,
        claimed_by = null,
        lease_expires_at = null,
        last_error_code = 'RECOVERY_MAX_ATTEMPTS_EXCEEDED',
        last_error_message = 'Recovery request exceeded maximum attempts'
    where id = v_outbox.id;

    return null;
  end if;

  select *
  into v_policy
  from public.live_runtime_recovery_policies
  where policy_key = v_request.policy_key
    and policy_version = v_request.policy_version;

  v_lease_seconds := greatest(
    30,
    least(
      coalesce(p_lease_seconds, v_policy.lease_seconds, 300),
      86400
    )
  );

  update public.live_runtime_recovery_requests
  set status = 'running',
      attempt_count = attempt_count + 1,
      claimed_at = v_now,
      claimed_by = btrim(p_worker_id),
      lease_expires_at = v_now + make_interval(secs => v_lease_seconds),
      started_at = coalesce(started_at, v_now)
  where id = v_request.id
  returning *
  into v_request;

  update public.live_runtime_recovery_outbox
  set status = 'claimed',
      claimed_at = v_now,
      claimed_by = btrim(p_worker_id),
      lease_expires_at = v_now + make_interval(secs => v_lease_seconds),
      delivery_attempts = delivery_attempts + 1
  where id = v_outbox.id
  returning *
  into v_outbox;

  insert into public.live_runtime_recovery_attempts (
    recovery_request_id,
    attempt_no,
    status,
    worker_id,
    started_at,
    metadata
  )
  values (
    v_request.id,
    v_request.attempt_count,
    'started',
    btrim(p_worker_id),
    v_now,
    jsonb_build_object(
      'outbox_id', v_outbox.id,
      'lease_expires_at', v_request.lease_expires_at
    )
  )
  returning *
  into v_attempt;

  perform public.record_live_runtime_workflow_event_rpc(
    p_workflow_instance_id => v_request.workflow_instance_id,
    p_workflow_key => v_request.workflow_key,
    p_event_type => 'workflow_recovery_started',
    p_correlation_id => v_request.correlation_id,
    p_causation_id => v_request.id,
    p_payload => jsonb_build_object(
      'recovery_request_id', v_request.id,
      'recovery_action', v_request.recovery_action,
      'attempt_no', v_request.attempt_count,
      'worker_id', p_worker_id
    ),
    p_metadata => jsonb_build_object(
      'recovery_request_id', v_request.id,
      'recovery_action', v_request.recovery_action,
      'recovery_status', 'running'
    )
  );

  return jsonb_build_object(
    'request', to_jsonb(v_request),
    'outbox', to_jsonb(v_outbox),
    'attempt', to_jsonb(v_attempt)
  );
end;
$$;

comment on function public.claim_live_runtime_recovery_command_rpc(text, integer)
is 'Atomically claims the next available recovery command using SKIP LOCKED and a worker lease.';

-- --------------------------------------------------------------------------
-- 8. Complete Recovery Command RPC
-- --------------------------------------------------------------------------

create or replace function public.complete_live_runtime_recovery_command_rpc(
  p_recovery_request_id uuid,
  p_worker_id text,
  p_succeeded boolean,
  p_result_payload jsonb default '{}'::jsonb,
  p_error_code text default null,
  p_error_message text default null,
  p_error_details jsonb default null,
  p_replay_workflow_instance_id uuid default null
)
returns public.live_runtime_recovery_status_v
language plpgsql
security definer
set search_path = public, extensions, pg_catalog
as $$
declare
  v_request public.live_runtime_recovery_requests%rowtype;
  v_policy public.live_runtime_recovery_policies%rowtype;
  v_attempt public.live_runtime_recovery_attempts%rowtype;
  v_outbox public.live_runtime_recovery_outbox%rowtype;
  v_now timestamptz := clock_timestamp();
  v_delay_seconds integer;
  v_next_retry timestamptz;
  v_terminal boolean;
  v_event_type text;
  v_result public.live_runtime_recovery_status_v%rowtype;
begin
  select *
  into v_request
  from public.live_runtime_recovery_requests
  where id = p_recovery_request_id
  for update;

  if not found then
    raise exception using errcode = 'P0002',
      message = 'recovery request not found';
  end if;

  if v_request.status <> 'running' then
    raise exception using errcode = '55000',
      message = 'recovery request is not running';
  end if;

  if v_request.claimed_by is distinct from btrim(p_worker_id) then
    raise exception using errcode = '42501',
      message = 'recovery request is claimed by another worker';
  end if;

  if v_request.lease_expires_at < v_now then
    raise exception using errcode = '55000',
      message = 'recovery request lease has expired';
  end if;

  select *
  into v_attempt
  from public.live_runtime_recovery_attempts
  where recovery_request_id = v_request.id
    and attempt_no = v_request.attempt_count
  for update;

  select *
  into v_outbox
  from public.live_runtime_recovery_outbox
  where recovery_request_id = v_request.id
  for update;

  select *
  into v_policy
  from public.live_runtime_recovery_policies
  where policy_key = v_request.policy_key
    and policy_version = v_request.policy_version;

  if p_succeeded then
    update public.live_runtime_recovery_attempts
    set status = 'completed',
        finished_at = v_now,
        result_payload = coalesce(p_result_payload, '{}'::jsonb)
    where id = v_attempt.id;

    update public.live_runtime_recovery_requests
    set status = 'completed',
        completed_at = v_now,
        replay_workflow_instance_id = coalesce(
          p_replay_workflow_instance_id,
          replay_workflow_instance_id
        ),
        result_payload = coalesce(p_result_payload, '{}'::jsonb),
        claimed_at = null,
        claimed_by = null,
        lease_expires_at = null,
        last_error_code = null,
        last_error_message = null,
        last_error_details = null
    where id = v_request.id
    returning *
    into v_request;

    update public.live_runtime_recovery_outbox
    set status = 'delivered',
        delivered_at = v_now,
        claimed_at = null,
        claimed_by = null,
        lease_expires_at = null,
        last_error_code = null,
        last_error_message = null,
        last_error_details = null
    where id = v_outbox.id;

    v_event_type := case v_request.recovery_action
      when 'retry' then 'workflow_retry_scheduled'
      when 'resume' then 'workflow_resumed'
      when 'replay' then 'workflow_replayed'
      when 'cancel' then 'workflow_cancelled'
      when 'mark_dead' then 'workflow_dead'
    end;

    perform public.record_live_runtime_workflow_event_rpc(
      p_workflow_instance_id => v_request.workflow_instance_id,
      p_workflow_key => v_request.workflow_key,
      p_event_type => v_event_type,
      p_correlation_id => v_request.correlation_id,
      p_causation_id => v_request.id,
      p_error_code => case
        when v_request.recovery_action = 'mark_dead'
          then coalesce(p_error_code, 'WORKFLOW_MARKED_DEAD')
        else null
      end,
      p_error_message => case
        when v_request.recovery_action = 'mark_dead'
          then coalesce(p_error_message, v_request.request_reason)
        else null
      end,
      p_output_payload => coalesce(p_result_payload, '{}'::jsonb),
      p_payload => jsonb_build_object(
        'recovery_request_id', v_request.id,
        'recovery_action', v_request.recovery_action,
        'attempt_no', v_request.attempt_count,
        'replay_workflow_instance_id', p_replay_workflow_instance_id
      ),
      p_metadata => jsonb_build_object(
        'recovery_request_id', v_request.id,
        'recovery_action', v_request.recovery_action,
        'recovery_status', 'completed'
      )
    );
  else
    v_terminal := v_request.attempt_count >= v_request.max_attempts;

    if not v_terminal then
      v_delay_seconds := least(
        v_policy.max_delay_seconds,
        floor(
          v_policy.initial_delay_seconds
          * power(
              v_policy.backoff_multiplier,
              greatest(v_request.attempt_count - 1, 0)
            )
        )::integer
      );

      v_next_retry := v_now + make_interval(secs => v_delay_seconds);

      update public.live_runtime_recovery_attempts
      set status = 'retry_scheduled',
          finished_at = v_now,
          next_retry_at = v_next_retry,
          error_code = p_error_code,
          error_message = p_error_message,
          error_details = p_error_details
      where id = v_attempt.id;

      update public.live_runtime_recovery_requests
      set status = 'scheduled',
          scheduled_at = v_next_retry,
          failed_at = null,
          claimed_at = null,
          claimed_by = null,
          lease_expires_at = null,
          last_error_code = p_error_code,
          last_error_message = p_error_message,
          last_error_details = p_error_details
      where id = v_request.id
      returning *
      into v_request;

      update public.live_runtime_recovery_outbox
      set status = 'pending',
          available_at = v_next_retry,
          claimed_at = null,
          claimed_by = null,
          lease_expires_at = null,
          last_error_code = p_error_code,
          last_error_message = p_error_message,
          last_error_details = p_error_details
      where id = v_outbox.id;

      perform public.record_live_runtime_workflow_event_rpc(
        p_workflow_instance_id => v_request.workflow_instance_id,
        p_workflow_key => v_request.workflow_key,
        p_event_type => 'workflow_recovery_retry_scheduled',
        p_correlation_id => v_request.correlation_id,
        p_causation_id => v_request.id,
        p_scheduled_at => v_next_retry,
        p_error_code => p_error_code,
        p_error_message => p_error_message,
        p_error_details => p_error_details,
        p_payload => jsonb_build_object(
          'recovery_request_id', v_request.id,
          'recovery_action', v_request.recovery_action,
          'attempt_no', v_request.attempt_count,
          'next_retry_at', v_next_retry
        ),
        p_metadata => jsonb_build_object(
          'recovery_request_id', v_request.id,
          'recovery_action', v_request.recovery_action,
          'recovery_status', 'scheduled'
        )
      );
    else
      update public.live_runtime_recovery_attempts
      set status = 'failed',
          finished_at = v_now,
          error_code = p_error_code,
          error_message = p_error_message,
          error_details = p_error_details
      where id = v_attempt.id;

      update public.live_runtime_recovery_requests
      set status = 'dead',
          failed_at = v_now,
          claimed_at = null,
          claimed_by = null,
          lease_expires_at = null,
          last_error_code = coalesce(
            p_error_code,
            'RECOVERY_MAX_ATTEMPTS_EXCEEDED'
          ),
          last_error_message = coalesce(
            p_error_message,
            'Workflow recovery exhausted all attempts'
          ),
          last_error_details = p_error_details
      where id = v_request.id
      returning *
      into v_request;

      update public.live_runtime_recovery_outbox
      set status = 'failed',
          failed_at = v_now,
          claimed_at = null,
          claimed_by = null,
          lease_expires_at = null,
          last_error_code = v_request.last_error_code,
          last_error_message = v_request.last_error_message,
          last_error_details = v_request.last_error_details
      where id = v_outbox.id;

      perform public.record_live_runtime_workflow_event_rpc(
        p_workflow_instance_id => v_request.workflow_instance_id,
        p_workflow_key => v_request.workflow_key,
        p_event_type => 'workflow_dead',
        p_correlation_id => v_request.correlation_id,
        p_causation_id => v_request.id,
        p_error_code => v_request.last_error_code,
        p_error_message => v_request.last_error_message,
        p_error_details => v_request.last_error_details,
        p_payload => jsonb_build_object(
          'recovery_request_id', v_request.id,
          'recovery_action', v_request.recovery_action,
          'attempt_no', v_request.attempt_count,
          'max_attempts', v_request.max_attempts
        ),
        p_metadata => jsonb_build_object(
          'recovery_request_id', v_request.id,
          'recovery_action', v_request.recovery_action,
          'recovery_status', 'dead'
        )
      );
    end if;
  end if;

  select s.*
  into v_result
  from public.live_runtime_recovery_status_v s
  where s.id = v_request.id;

  return v_result;
end;
$$;

comment on function public.complete_live_runtime_recovery_command_rpc(
  uuid, text, boolean, jsonb, text, text, jsonb, uuid
)
is 'Completes one claimed recovery attempt, schedules policy backoff, or marks recovery dead.';

-- --------------------------------------------------------------------------
-- 9. Cancel Recovery Request RPC
-- --------------------------------------------------------------------------

create or replace function public.cancel_live_runtime_recovery_request_rpc(
  p_recovery_request_id uuid,
  p_cancelled_by text,
  p_reason text default null
)
returns public.live_runtime_recovery_status_v
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_request public.live_runtime_recovery_requests%rowtype;
  v_now timestamptz := clock_timestamp();
  v_result public.live_runtime_recovery_status_v%rowtype;
begin
  if p_cancelled_by is null or length(btrim(p_cancelled_by)) = 0 then
    raise exception using errcode = '22023',
      message = 'cancelled_by is required';
  end if;

  select *
  into v_request
  from public.live_runtime_recovery_requests
  where id = p_recovery_request_id
  for update;

  if not found then
    raise exception using errcode = 'P0002',
      message = 'recovery request not found';
  end if;

  if v_request.status in ('completed', 'failed', 'cancelled', 'dead') then
    raise exception using errcode = '55000',
      message = 'terminal recovery request cannot be cancelled';
  end if;

  update public.live_runtime_recovery_requests
  set status = 'cancelled',
      cancelled_at = v_now,
      claimed_at = null,
      claimed_by = null,
      lease_expires_at = null,
      metadata = metadata || jsonb_build_object(
        'cancelled_by', btrim(p_cancelled_by),
        'cancellation_reason', p_reason
      )
  where id = v_request.id
  returning *
  into v_request;

  update public.live_runtime_recovery_outbox
  set status = 'cancelled',
      claimed_at = null,
      claimed_by = null,
      lease_expires_at = null
  where recovery_request_id = v_request.id
    and status not in ('delivered', 'failed');

  update public.live_runtime_recovery_attempts
  set status = 'cancelled',
      finished_at = v_now,
      metadata = metadata || jsonb_build_object(
        'cancelled_by', btrim(p_cancelled_by),
        'cancellation_reason', p_reason
      )
  where recovery_request_id = v_request.id
    and status = 'started';

  perform public.record_live_runtime_workflow_event_rpc(
    p_workflow_instance_id => v_request.workflow_instance_id,
    p_workflow_key => v_request.workflow_key,
    p_event_type => 'workflow_recovery_cancelled',
    p_correlation_id => v_request.correlation_id,
    p_causation_id => v_request.id,
    p_payload => jsonb_build_object(
      'recovery_request_id', v_request.id,
      'recovery_action', v_request.recovery_action,
      'cancelled_by', p_cancelled_by,
      'reason', p_reason
    ),
    p_metadata => jsonb_build_object(
      'recovery_request_id', v_request.id,
      'recovery_action', v_request.recovery_action,
      'recovery_status', 'cancelled'
    )
  );

  select s.*
  into v_result
  from public.live_runtime_recovery_status_v s
  where s.id = v_request.id;

  return v_result;
end;
$$;

comment on function public.cancel_live_runtime_recovery_request_rpc(uuid, text, text)
is 'Cancels one non-terminal recovery request and its undelivered command.';

-- --------------------------------------------------------------------------
-- 10. Recovery Inspector RPC
-- --------------------------------------------------------------------------

create or replace function public.inspect_live_runtime_recovery_rpc(
  p_recovery_request_id uuid
)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_catalog
as $$
  select jsonb_build_object(
    'recovery', to_jsonb(r),
    'workflow', public.inspect_live_runtime_workflow_rpc(
      r.workflow_instance_id
    ),
    'attempts', coalesce((
      select jsonb_agg(to_jsonb(a) order by a.attempt_no)
      from public.live_runtime_recovery_attempts a
      where a.recovery_request_id = r.id
    ), '[]'::jsonb),
    'outbox', (
      select to_jsonb(o)
      from public.live_runtime_recovery_outbox o
      where o.recovery_request_id = r.id
    )
  )
  from public.live_runtime_recovery_status_v r
  where r.id = p_recovery_request_id;
$$;

comment on function public.inspect_live_runtime_recovery_rpc(uuid)
is 'Returns the complete Recovery Inspector document with workflow, attempts and outbox state.';

create or replace function public.list_live_runtime_recovery_commands_rpc(
  p_status text default null,
  p_workflow_instance_id uuid default null,
  p_action text default null,
  p_attention_only boolean default false,
  p_limit integer default 100,
  p_offset integer default 0
)
returns setof public.live_runtime_recovery_status_v
language plpgsql
stable
security definer
set search_path = public, pg_catalog
as $$
declare
  v_limit integer := greatest(1, least(coalesce(p_limit, 100), 500));
  v_offset integer := greatest(0, coalesce(p_offset, 0));
begin
  return query
  select r.*
  from public.live_runtime_recovery_status_v r
  where (p_status is null or r.status = p_status)
    and (
      p_workflow_instance_id is null
      or r.workflow_instance_id = p_workflow_instance_id
    )
    and (p_action is null or r.recovery_action = p_action)
    and (
      not p_attention_only
      or r.status in ('failed', 'dead')
      or r.lease_expired
    )
  order by r.requested_at desc, r.id
  limit v_limit
  offset v_offset;
end;
$$;

comment on function public.list_live_runtime_recovery_commands_rpc(
  text, uuid, text, boolean, integer, integer
)
is 'Filtered and paginated Recovery command listing for operational tooling.';

-- --------------------------------------------------------------------------
-- 11. Security
-- --------------------------------------------------------------------------

alter table public.live_runtime_recovery_policies enable row level security;
alter table public.live_runtime_recovery_requests enable row level security;
alter table public.live_runtime_recovery_attempts enable row level security;
alter table public.live_runtime_recovery_outbox enable row level security;

revoke all on public.live_runtime_recovery_policies
  from public, anon, authenticated;
revoke all on public.live_runtime_recovery_requests
  from public, anon, authenticated;
revoke all on public.live_runtime_recovery_attempts
  from public, anon, authenticated;
revoke all on public.live_runtime_recovery_outbox
  from public, anon, authenticated;

revoke all on public.live_runtime_workflow_recovery_eligibility_v
  from public, anon, authenticated;
revoke all on public.live_runtime_recovery_status_v
  from public, anon, authenticated;
revoke all on public.live_runtime_recovery_attention_v
  from public, anon, authenticated;

revoke all on function public.request_live_runtime_workflow_recovery_rpc(
  uuid, text, text, text, text, text, integer, timestamptz,
  uuid, uuid, jsonb, jsonb
) from public, anon, authenticated;

revoke all on function public.claim_live_runtime_recovery_command_rpc(
  text, integer
) from public, anon, authenticated;

revoke all on function public.complete_live_runtime_recovery_command_rpc(
  uuid, text, boolean, jsonb, text, text, jsonb, uuid
) from public, anon, authenticated;

revoke all on function public.cancel_live_runtime_recovery_request_rpc(
  uuid, text, text
) from public, anon, authenticated;

revoke all on function public.inspect_live_runtime_recovery_rpc(uuid)
  from public, anon, authenticated;

revoke all on function public.list_live_runtime_recovery_commands_rpc(
  text, uuid, text, boolean, integer, integer
) from public, anon, authenticated;

grant select on public.live_runtime_recovery_policies to service_role;
grant select, insert, update on public.live_runtime_recovery_requests
  to service_role;
grant select, insert, update on public.live_runtime_recovery_attempts
  to service_role;
grant select, insert, update on public.live_runtime_recovery_outbox
  to service_role;

grant select on public.live_runtime_workflow_recovery_eligibility_v
  to service_role;
grant select on public.live_runtime_recovery_status_v
  to service_role;
grant select on public.live_runtime_recovery_attention_v
  to service_role;

grant execute on function public.request_live_runtime_workflow_recovery_rpc(
  uuid, text, text, text, text, text, integer, timestamptz,
  uuid, uuid, jsonb, jsonb
) to service_role;

grant execute on function public.claim_live_runtime_recovery_command_rpc(
  text, integer
) to service_role;

grant execute on function public.complete_live_runtime_recovery_command_rpc(
  uuid, text, boolean, jsonb, text, text, jsonb, uuid
) to service_role;

grant execute on function public.cancel_live_runtime_recovery_request_rpc(
  uuid, text, text
) to service_role;

grant execute on function public.inspect_live_runtime_recovery_rpc(uuid)
  to service_role;

grant execute on function public.list_live_runtime_recovery_commands_rpc(
  text, uuid, text, boolean, integer, integer
) to service_role;

-- --------------------------------------------------------------------------
-- 12. Migration verification
-- --------------------------------------------------------------------------

do $$
declare
  v_missing text[];
begin
  select array_agg(x.object_name order by x.object_name)
  into v_missing
  from (
    values
      ('live_runtime_recovery_policies'),
      ('live_runtime_recovery_requests'),
      ('live_runtime_recovery_attempts'),
      ('live_runtime_recovery_outbox'),
      ('live_runtime_workflow_recovery_eligibility_v'),
      ('live_runtime_recovery_status_v'),
      ('live_runtime_recovery_attention_v')
  ) as x(object_name)
  where to_regclass('public.' || x.object_name) is null;

  if v_missing is not null then
    raise exception
      'Workflow Recovery migration incomplete. Missing objects: %',
      v_missing;
  end if;

  if to_regprocedure(
    'public.request_live_runtime_workflow_recovery_rpc(uuid,text,text,text,text,text,integer,timestamp with time zone,uuid,uuid,jsonb,jsonb)'
  ) is null then
    raise exception 'Missing request_live_runtime_workflow_recovery_rpc';
  end if;

  if to_regprocedure(
    'public.claim_live_runtime_recovery_command_rpc(text,integer)'
  ) is null then
    raise exception 'Missing claim_live_runtime_recovery_command_rpc';
  end if;

  if to_regprocedure(
    'public.complete_live_runtime_recovery_command_rpc(uuid,text,boolean,jsonb,text,text,jsonb,uuid)'
  ) is null then
    raise exception 'Missing complete_live_runtime_recovery_command_rpc';
  end if;

  if to_regprocedure(
    'public.cancel_live_runtime_recovery_request_rpc(uuid,text,text)'
  ) is null then
    raise exception 'Missing cancel_live_runtime_recovery_request_rpc';
  end if;

  if to_regprocedure(
    'public.inspect_live_runtime_recovery_rpc(uuid)'
  ) is null then
    raise exception 'Missing inspect_live_runtime_recovery_rpc';
  end if;
end;
$$;

commit;
