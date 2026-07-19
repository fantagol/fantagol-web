-- ============================================================================
-- FANTAGOL
-- Migration 063 — Workflow Observability Foundation
-- Milestone 7.3.1
--
-- Purpose
--   Introduce the authoritative operational read model for Workflow Engine
--   observability without changing the execution semantics of migration 062.
--
-- Scope
--   - workflow registry
--   - append-only workflow timeline
--   - workflow/step status projection
--   - correlation and causation lookup
--   - duration, retry, waiting and failure metrics
--   - service-role command/query RPCs
--
-- Security
--   Operational data is private. No authenticated/anon access is granted.
--   Writes and reads are reserved to service_role.
-- ============================================================================

begin;

create extension if not exists pgcrypto with schema extensions;

-- --------------------------------------------------------------------------
-- 1. Shared updated_at trigger
-- --------------------------------------------------------------------------

create or replace function public.set_workflow_observability_updated_at()
returns trigger
language plpgsql
security invoker
set search_path = public, pg_catalog
as $$
begin
  new.updated_at := clock_timestamp();
  return new;
end;
$$;

comment on function public.set_workflow_observability_updated_at()
is 'Maintains updated_at on mutable Workflow Observability projections.';

-- --------------------------------------------------------------------------
-- 2. Workflow registry — one row per persisted workflow instance
-- --------------------------------------------------------------------------

create table if not exists public.live_runtime_workflow_registry (
  id uuid primary key default extensions.gen_random_uuid(),

  -- Stable identity from the Workflow Engine. Kept without a hard FK so the
  -- observability layer remains deployable independently from table renames.
  workflow_instance_id uuid not null,
  workflow_key text not null,
  workflow_version integer not null default 1,
  workflow_name text,

  -- Operational identity and trace chain.
  idempotency_key text,
  correlation_id uuid,
  causation_id uuid,
  parent_workflow_instance_id uuid,

  -- Domain context.
  aggregate_type text,
  aggregate_id uuid,
  league_id uuid,
  league_round_id uuid,
  match_id uuid,

  -- Current projection.
  status text not null default 'created',
  current_step_key text,
  current_step_index integer,
  total_steps integer,
  completed_steps integer not null default 0,
  failed_steps integer not null default 0,
  retry_count integer not null default 0,
  failure_count integer not null default 0,

  -- Runtime timestamps.
  created_at timestamptz not null default clock_timestamp(),
  started_at timestamptz,
  waiting_since timestamptz,
  last_transition_at timestamptz not null default clock_timestamp(),
  last_heartbeat_at timestamptz,
  completed_at timestamptz,
  failed_at timestamptz,
  cancelled_at timestamptz,
  updated_at timestamptz not null default clock_timestamp(),

  -- Last known failure and extensible runtime context.
  last_error_code text,
  last_error_message text,
  last_error_details jsonb,
  input_payload jsonb not null default '{}'::jsonb,
  output_payload jsonb,
  metadata jsonb not null default '{}'::jsonb,

  constraint live_runtime_workflow_registry_instance_uq
    unique (workflow_instance_id),

  constraint live_runtime_workflow_registry_identity_ck
    check (length(btrim(workflow_key)) > 0 and workflow_version > 0),

  constraint live_runtime_workflow_registry_status_ck
    check (status in (
      'created',
      'queued',
      'running',
      'waiting',
      'retry_scheduled',
      'completed',
      'failed',
      'cancelled',
      'dead'
    )),

  constraint live_runtime_workflow_registry_step_counts_ck
    check (
      completed_steps >= 0
      and failed_steps >= 0
      and retry_count >= 0
      and failure_count >= 0
      and (total_steps is null or total_steps >= 0)
      and (current_step_index is null or current_step_index >= 0)
      and (total_steps is null or completed_steps <= total_steps)
    ),

  constraint live_runtime_workflow_registry_terminal_time_ck
    check (
      (status <> 'completed' or completed_at is not null)
      and (status not in ('failed', 'dead') or failed_at is not null)
      and (status <> 'cancelled' or cancelled_at is not null)
    )
);

comment on table public.live_runtime_workflow_registry
is 'Authoritative operational projection of every Workflow Engine instance.';

comment on column public.live_runtime_workflow_registry.workflow_instance_id
is 'Persistent Workflow Engine instance identifier created by migration 062/runtime orchestration.';

comment on column public.live_runtime_workflow_registry.correlation_id
is 'Trace identifier shared by operations belonging to the same business execution chain.';

comment on column public.live_runtime_workflow_registry.causation_id
is 'Identifier of the event, job or workflow that directly caused this workflow.';

create index if not exists live_runtime_workflow_registry_status_idx
  on public.live_runtime_workflow_registry (status, last_transition_at desc);

create index if not exists live_runtime_workflow_registry_workflow_idx
  on public.live_runtime_workflow_registry (workflow_key, created_at desc);

create index if not exists live_runtime_workflow_registry_correlation_idx
  on public.live_runtime_workflow_registry (correlation_id, created_at asc)
  where correlation_id is not null;

create index if not exists live_runtime_workflow_registry_causation_idx
  on public.live_runtime_workflow_registry (causation_id, created_at asc)
  where causation_id is not null;

create index if not exists live_runtime_workflow_registry_parent_idx
  on public.live_runtime_workflow_registry (parent_workflow_instance_id, created_at asc)
  where parent_workflow_instance_id is not null;

create index if not exists live_runtime_workflow_registry_aggregate_idx
  on public.live_runtime_workflow_registry (aggregate_type, aggregate_id, created_at desc)
  where aggregate_type is not null and aggregate_id is not null;

create index if not exists live_runtime_workflow_registry_league_round_idx
  on public.live_runtime_workflow_registry (league_round_id, created_at desc)
  where league_round_id is not null;

create index if not exists live_runtime_workflow_registry_match_idx
  on public.live_runtime_workflow_registry (match_id, created_at desc)
  where match_id is not null;

create index if not exists live_runtime_workflow_registry_attention_idx
  on public.live_runtime_workflow_registry (last_transition_at asc)
  where status in ('waiting', 'retry_scheduled', 'failed', 'dead');

-- --------------------------------------------------------------------------
-- 3. Append-only timeline
-- --------------------------------------------------------------------------

create table if not exists public.live_runtime_workflow_timeline (
  id bigint generated always as identity primary key,
  event_id uuid not null default extensions.gen_random_uuid(),
  workflow_instance_id uuid not null,

  sequence_no bigint not null,
  event_type text not null,
  workflow_status text,

  step_instance_id uuid,
  step_key text,
  step_index integer,
  step_status text,
  attempt_no integer,
  job_id uuid,

  correlation_id uuid,
  causation_id uuid,

  occurred_at timestamptz not null default clock_timestamp(),
  scheduled_at timestamptz,
  started_at timestamptz,
  finished_at timestamptz,

  error_code text,
  error_message text,
  error_details jsonb,
  payload jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,

  constraint live_runtime_workflow_timeline_event_uq unique (event_id),
  constraint live_runtime_workflow_timeline_sequence_uq
    unique (workflow_instance_id, sequence_no),

  constraint live_runtime_workflow_timeline_event_type_ck
    check (event_type in (
      'workflow_created',
      'workflow_queued',
      'workflow_started',
      'workflow_waiting',
      'workflow_retry_scheduled',
      'workflow_resumed',
      'workflow_completed',
      'workflow_failed',
      'workflow_cancelled',
      'workflow_dead',
      'step_created',
      'step_queued',
      'step_started',
      'step_waiting',
      'step_retry_scheduled',
      'step_completed',
      'step_failed',
      'step_skipped',
      'job_linked',
      'heartbeat',
      'diagnostic_note'
    )),

  constraint live_runtime_workflow_timeline_workflow_status_ck
    check (
      workflow_status is null
      or workflow_status in (
        'created', 'queued', 'running', 'waiting', 'retry_scheduled',
        'completed', 'failed', 'cancelled', 'dead'
      )
    ),

  constraint live_runtime_workflow_timeline_step_status_ck
    check (
      step_status is null
      or step_status in (
        'created', 'queued', 'running', 'waiting', 'retry_scheduled',
        'completed', 'failed', 'skipped', 'cancelled', 'dead'
      )
    ),

  constraint live_runtime_workflow_timeline_numeric_ck
    check (
      sequence_no > 0
      and (step_index is null or step_index >= 0)
      and (attempt_no is null or attempt_no > 0)
    )
);

comment on table public.live_runtime_workflow_timeline
is 'Append-only event timeline for workflows, steps, retries, failures, jobs and heartbeats.';

create index if not exists live_runtime_workflow_timeline_workflow_idx
  on public.live_runtime_workflow_timeline (workflow_instance_id, sequence_no asc);

create index if not exists live_runtime_workflow_timeline_occurred_idx
  on public.live_runtime_workflow_timeline (occurred_at desc);

create index if not exists live_runtime_workflow_timeline_step_idx
  on public.live_runtime_workflow_timeline (step_instance_id, occurred_at asc)
  where step_instance_id is not null;

create index if not exists live_runtime_workflow_timeline_job_idx
  on public.live_runtime_workflow_timeline (job_id, occurred_at asc)
  where job_id is not null;

create index if not exists live_runtime_workflow_timeline_correlation_idx
  on public.live_runtime_workflow_timeline (correlation_id, occurred_at asc)
  where correlation_id is not null;

create index if not exists live_runtime_workflow_timeline_failures_idx
  on public.live_runtime_workflow_timeline (occurred_at desc)
  where event_type in ('workflow_failed', 'workflow_dead', 'step_failed');

-- --------------------------------------------------------------------------
-- 4. Current step projection
-- --------------------------------------------------------------------------

create table if not exists public.live_runtime_workflow_step_registry (
  id uuid primary key default extensions.gen_random_uuid(),
  workflow_instance_id uuid not null,
  step_instance_id uuid not null,
  step_key text not null,
  step_name text,
  step_index integer not null,

  status text not null default 'created',
  attempt_count integer not null default 0,
  retry_count integer not null default 0,
  job_id uuid,

  created_at timestamptz not null default clock_timestamp(),
  queued_at timestamptz,
  started_at timestamptz,
  waiting_since timestamptz,
  last_transition_at timestamptz not null default clock_timestamp(),
  completed_at timestamptz,
  failed_at timestamptz,
  updated_at timestamptz not null default clock_timestamp(),

  last_error_code text,
  last_error_message text,
  last_error_details jsonb,
  input_payload jsonb not null default '{}'::jsonb,
  output_payload jsonb,
  metadata jsonb not null default '{}'::jsonb,

  constraint live_runtime_workflow_step_registry_instance_uq
    unique (step_instance_id),
  constraint live_runtime_workflow_step_registry_position_uq
    unique (workflow_instance_id, step_index),

  constraint live_runtime_workflow_step_registry_identity_ck
    check (length(btrim(step_key)) > 0 and step_index >= 0),

  constraint live_runtime_workflow_step_registry_status_ck
    check (status in (
      'created', 'queued', 'running', 'waiting', 'retry_scheduled',
      'completed', 'failed', 'skipped', 'cancelled', 'dead'
    )),

  constraint live_runtime_workflow_step_registry_counts_ck
    check (attempt_count >= 0 and retry_count >= 0),

  constraint live_runtime_workflow_step_registry_terminal_time_ck
    check (
      (status not in ('completed', 'skipped') or completed_at is not null)
      and (status not in ('failed', 'dead') or failed_at is not null)
    )
);

comment on table public.live_runtime_workflow_step_registry
is 'Current operational projection of every persisted workflow step.';

create index if not exists live_runtime_workflow_step_registry_workflow_idx
  on public.live_runtime_workflow_step_registry (workflow_instance_id, step_index asc);

create index if not exists live_runtime_workflow_step_registry_status_idx
  on public.live_runtime_workflow_step_registry (status, last_transition_at asc);

create index if not exists live_runtime_workflow_step_registry_job_idx
  on public.live_runtime_workflow_step_registry (job_id)
  where job_id is not null;

-- --------------------------------------------------------------------------
-- 5. Projection triggers and append-only protection
-- --------------------------------------------------------------------------

drop trigger if exists trg_live_runtime_workflow_registry_updated_at
  on public.live_runtime_workflow_registry;
create trigger trg_live_runtime_workflow_registry_updated_at
before update on public.live_runtime_workflow_registry
for each row execute function public.set_workflow_observability_updated_at();

drop trigger if exists trg_live_runtime_workflow_step_registry_updated_at
  on public.live_runtime_workflow_step_registry;
create trigger trg_live_runtime_workflow_step_registry_updated_at
before update on public.live_runtime_workflow_step_registry
for each row execute function public.set_workflow_observability_updated_at();

create or replace function public.protect_live_runtime_workflow_timeline()
returns trigger
language plpgsql
security invoker
set search_path = public, pg_catalog
as $$
begin
  raise exception using
    errcode = '55000',
    message = 'live_runtime_workflow_timeline is append-only';
end;
$$;

drop trigger if exists trg_protect_live_runtime_workflow_timeline
  on public.live_runtime_workflow_timeline;
create trigger trg_protect_live_runtime_workflow_timeline
before update or delete on public.live_runtime_workflow_timeline
for each row execute function public.protect_live_runtime_workflow_timeline();

-- --------------------------------------------------------------------------
-- 6. Atomic event ingestion / projection RPC
-- --------------------------------------------------------------------------

create or replace function public.record_live_runtime_workflow_event_rpc(
  p_workflow_instance_id uuid,
  p_workflow_key text,
  p_event_type text,
  p_workflow_status text default null,
  p_workflow_version integer default 1,
  p_workflow_name text default null,
  p_idempotency_key text default null,
  p_correlation_id uuid default null,
  p_causation_id uuid default null,
  p_parent_workflow_instance_id uuid default null,
  p_aggregate_type text default null,
  p_aggregate_id uuid default null,
  p_league_id uuid default null,
  p_league_round_id uuid default null,
  p_match_id uuid default null,
  p_step_instance_id uuid default null,
  p_step_key text default null,
  p_step_name text default null,
  p_step_index integer default null,
  p_step_status text default null,
  p_attempt_no integer default null,
  p_job_id uuid default null,
  p_occurred_at timestamptz default clock_timestamp(),
  p_scheduled_at timestamptz default null,
  p_error_code text default null,
  p_error_message text default null,
  p_error_details jsonb default null,
  p_input_payload jsonb default '{}'::jsonb,
  p_output_payload jsonb default null,
  p_payload jsonb default '{}'::jsonb,
  p_metadata jsonb default '{}'::jsonb
)
returns table (
  workflow_registry_id uuid,
  timeline_event_id uuid,
  sequence_no bigint
)
language plpgsql
security definer
set search_path = public, extensions, pg_catalog
as $$
declare
  v_now timestamptz := coalesce(p_occurred_at, clock_timestamp());
  v_registry public.live_runtime_workflow_registry%rowtype;
  v_sequence bigint;
  v_timeline_event_id uuid;
  v_workflow_status text;
  v_step_status text;
begin
  if p_workflow_instance_id is null then
    raise exception using errcode = '22004', message = 'workflow_instance_id is required';
  end if;

  if p_workflow_key is null or length(btrim(p_workflow_key)) = 0 then
    raise exception using errcode = '22023', message = 'workflow_key is required';
  end if;

  if p_event_type is null or length(btrim(p_event_type)) = 0 then
    raise exception using errcode = '22023', message = 'event_type is required';
  end if;

  v_workflow_status := coalesce(
    p_workflow_status,
    case p_event_type
      when 'workflow_created' then 'created'
      when 'workflow_queued' then 'queued'
      when 'workflow_started' then 'running'
      when 'workflow_waiting' then 'waiting'
      when 'workflow_retry_scheduled' then 'retry_scheduled'
      when 'workflow_resumed' then 'running'
      when 'workflow_completed' then 'completed'
      when 'workflow_failed' then 'failed'
      when 'workflow_cancelled' then 'cancelled'
      when 'workflow_dead' then 'dead'
      else null
    end
  );

  v_step_status := coalesce(
    p_step_status,
    case p_event_type
      when 'step_created' then 'created'
      when 'step_queued' then 'queued'
      when 'step_started' then 'running'
      when 'step_waiting' then 'waiting'
      when 'step_retry_scheduled' then 'retry_scheduled'
      when 'step_completed' then 'completed'
      when 'step_failed' then 'failed'
      when 'step_skipped' then 'skipped'
      else null
    end
  );

  insert into public.live_runtime_workflow_registry (
    workflow_instance_id,
    workflow_key,
    workflow_version,
    workflow_name,
    idempotency_key,
    correlation_id,
    causation_id,
    parent_workflow_instance_id,
    aggregate_type,
    aggregate_id,
    league_id,
    league_round_id,
    match_id,
    status,
    current_step_key,
    current_step_index,
    total_steps,
    completed_steps,
    failed_steps,
    retry_count,
    failure_count,
    created_at,
    started_at,
    waiting_since,
    last_transition_at,
    last_heartbeat_at,
    completed_at,
    failed_at,
    cancelled_at,
    last_error_code,
    last_error_message,
    last_error_details,
    input_payload,
    output_payload,
    metadata
  )
  values (
    p_workflow_instance_id,
    btrim(p_workflow_key),
    coalesce(p_workflow_version, 1),
    p_workflow_name,
    p_idempotency_key,
    p_correlation_id,
    p_causation_id,
    p_parent_workflow_instance_id,
    p_aggregate_type,
    p_aggregate_id,
    p_league_id,
    p_league_round_id,
    p_match_id,
    coalesce(v_workflow_status, 'created'),
    p_step_key,
    p_step_index,
    nullif((p_metadata ->> 'total_steps')::integer, 0),
    case when p_event_type = 'step_completed' then 1 else 0 end,
    case when p_event_type = 'step_failed' then 1 else 0 end,
    case when p_event_type in ('workflow_retry_scheduled', 'step_retry_scheduled') then 1 else 0 end,
    case when p_event_type in ('workflow_failed', 'workflow_dead', 'step_failed') then 1 else 0 end,
    v_now,
    case when p_event_type = 'workflow_started' then v_now else null end,
    case when p_event_type in ('workflow_waiting', 'workflow_retry_scheduled') then v_now else null end,
    v_now,
    case when p_event_type = 'heartbeat' then v_now else null end,
    case when p_event_type = 'workflow_completed' then v_now else null end,
    case when p_event_type in ('workflow_failed', 'workflow_dead') then v_now else null end,
    case when p_event_type = 'workflow_cancelled' then v_now else null end,
    p_error_code,
    p_error_message,
    p_error_details,
    coalesce(p_input_payload, '{}'::jsonb),
    p_output_payload,
    coalesce(p_metadata, '{}'::jsonb)
  )
  on conflict (workflow_instance_id) do update
  set
    workflow_key = excluded.workflow_key,
    workflow_version = excluded.workflow_version,
    workflow_name = coalesce(excluded.workflow_name, live_runtime_workflow_registry.workflow_name),
    idempotency_key = coalesce(excluded.idempotency_key, live_runtime_workflow_registry.idempotency_key),
    correlation_id = coalesce(excluded.correlation_id, live_runtime_workflow_registry.correlation_id),
    causation_id = coalesce(excluded.causation_id, live_runtime_workflow_registry.causation_id),
    parent_workflow_instance_id = coalesce(excluded.parent_workflow_instance_id, live_runtime_workflow_registry.parent_workflow_instance_id),
    aggregate_type = coalesce(excluded.aggregate_type, live_runtime_workflow_registry.aggregate_type),
    aggregate_id = coalesce(excluded.aggregate_id, live_runtime_workflow_registry.aggregate_id),
    league_id = coalesce(excluded.league_id, live_runtime_workflow_registry.league_id),
    league_round_id = coalesce(excluded.league_round_id, live_runtime_workflow_registry.league_round_id),
    match_id = coalesce(excluded.match_id, live_runtime_workflow_registry.match_id),
    status = coalesce(v_workflow_status, live_runtime_workflow_registry.status),
    current_step_key = coalesce(p_step_key, live_runtime_workflow_registry.current_step_key),
    current_step_index = coalesce(p_step_index, live_runtime_workflow_registry.current_step_index),
    total_steps = coalesce(nullif((coalesce(p_metadata, '{}'::jsonb) ->> 'total_steps')::integer, 0), live_runtime_workflow_registry.total_steps),
    completed_steps = live_runtime_workflow_registry.completed_steps
      + case when p_event_type = 'step_completed' then 1 else 0 end,
    failed_steps = live_runtime_workflow_registry.failed_steps
      + case when p_event_type = 'step_failed' then 1 else 0 end,
    retry_count = live_runtime_workflow_registry.retry_count
      + case when p_event_type in ('workflow_retry_scheduled', 'step_retry_scheduled') then 1 else 0 end,
    failure_count = live_runtime_workflow_registry.failure_count
      + case when p_event_type in ('workflow_failed', 'workflow_dead', 'step_failed') then 1 else 0 end,
    started_at = coalesce(
      live_runtime_workflow_registry.started_at,
      case when p_event_type in ('workflow_started', 'step_started') then v_now else null end
    ),
    waiting_since = case
      when p_event_type in ('workflow_waiting', 'workflow_retry_scheduled') then v_now
      when p_event_type in ('workflow_resumed', 'workflow_completed', 'workflow_failed', 'workflow_cancelled', 'workflow_dead') then null
      else live_runtime_workflow_registry.waiting_since
    end,
    last_transition_at = v_now,
    last_heartbeat_at = case
      when p_event_type = 'heartbeat' then v_now
      else live_runtime_workflow_registry.last_heartbeat_at
    end,
    completed_at = case
      when p_event_type = 'workflow_completed' then v_now
      else live_runtime_workflow_registry.completed_at
    end,
    failed_at = case
      when p_event_type in ('workflow_failed', 'workflow_dead') then v_now
      else live_runtime_workflow_registry.failed_at
    end,
    cancelled_at = case
      when p_event_type = 'workflow_cancelled' then v_now
      else live_runtime_workflow_registry.cancelled_at
    end,
    last_error_code = case
      when p_error_code is not null then p_error_code
      when p_event_type in ('workflow_resumed', 'workflow_completed') then null
      else live_runtime_workflow_registry.last_error_code
    end,
    last_error_message = case
      when p_error_message is not null then p_error_message
      when p_event_type in ('workflow_resumed', 'workflow_completed') then null
      else live_runtime_workflow_registry.last_error_message
    end,
    last_error_details = case
      when p_error_details is not null then p_error_details
      when p_event_type in ('workflow_resumed', 'workflow_completed') then null
      else live_runtime_workflow_registry.last_error_details
    end,
    input_payload = case
      when p_input_payload is not null and p_input_payload <> '{}'::jsonb then p_input_payload
      else live_runtime_workflow_registry.input_payload
    end,
    output_payload = coalesce(p_output_payload, live_runtime_workflow_registry.output_payload),
    metadata = live_runtime_workflow_registry.metadata || coalesce(p_metadata, '{}'::jsonb)
  returning * into v_registry;

  if p_step_instance_id is not null then
    if p_step_key is null or p_step_index is null then
      raise exception using
        errcode = '22023',
        message = 'step_key and step_index are required when step_instance_id is provided';
    end if;

    insert into public.live_runtime_workflow_step_registry (
      workflow_instance_id,
      step_instance_id,
      step_key,
      step_name,
      step_index,
      status,
      attempt_count,
      retry_count,
      job_id,
      created_at,
      queued_at,
      started_at,
      waiting_since,
      last_transition_at,
      completed_at,
      failed_at,
      last_error_code,
      last_error_message,
      last_error_details,
      input_payload,
      output_payload,
      metadata
    )
    values (
      p_workflow_instance_id,
      p_step_instance_id,
      btrim(p_step_key),
      p_step_name,
      p_step_index,
      coalesce(v_step_status, 'created'),
      coalesce(p_attempt_no, 0),
      case when p_event_type = 'step_retry_scheduled' then 1 else 0 end,
      p_job_id,
      v_now,
      case when p_event_type = 'step_queued' then v_now else null end,
      case when p_event_type = 'step_started' then v_now else null end,
      case when p_event_type in ('step_waiting', 'step_retry_scheduled') then v_now else null end,
      v_now,
      case when p_event_type in ('step_completed', 'step_skipped') then v_now else null end,
      case when p_event_type in ('step_failed') then v_now else null end,
      p_error_code,
      p_error_message,
      p_error_details,
      coalesce(p_input_payload, '{}'::jsonb),
      p_output_payload,
      coalesce(p_metadata, '{}'::jsonb)
    )
    on conflict (step_instance_id) do update
    set
      step_key = excluded.step_key,
      step_name = coalesce(excluded.step_name, live_runtime_workflow_step_registry.step_name),
      step_index = excluded.step_index,
      status = coalesce(v_step_status, live_runtime_workflow_step_registry.status),
      attempt_count = greatest(
        live_runtime_workflow_step_registry.attempt_count,
        coalesce(p_attempt_no, live_runtime_workflow_step_registry.attempt_count)
      ),
      retry_count = live_runtime_workflow_step_registry.retry_count
        + case when p_event_type = 'step_retry_scheduled' then 1 else 0 end,
      job_id = coalesce(p_job_id, live_runtime_workflow_step_registry.job_id),
      queued_at = coalesce(
        live_runtime_workflow_step_registry.queued_at,
        case when p_event_type = 'step_queued' then v_now else null end
      ),
      started_at = coalesce(
        live_runtime_workflow_step_registry.started_at,
        case when p_event_type = 'step_started' then v_now else null end
      ),
      waiting_since = case
        when p_event_type in ('step_waiting', 'step_retry_scheduled') then v_now
        when p_event_type in ('step_started', 'step_completed', 'step_failed', 'step_skipped') then null
        else live_runtime_workflow_step_registry.waiting_since
      end,
      last_transition_at = v_now,
      completed_at = case
        when p_event_type in ('step_completed', 'step_skipped') then v_now
        else live_runtime_workflow_step_registry.completed_at
      end,
      failed_at = case
        when p_event_type = 'step_failed' then v_now
        else live_runtime_workflow_step_registry.failed_at
      end,
      last_error_code = case
        when p_error_code is not null then p_error_code
        when p_event_type = 'step_completed' then null
        else live_runtime_workflow_step_registry.last_error_code
      end,
      last_error_message = case
        when p_error_message is not null then p_error_message
        when p_event_type = 'step_completed' then null
        else live_runtime_workflow_step_registry.last_error_message
      end,
      last_error_details = case
        when p_error_details is not null then p_error_details
        when p_event_type = 'step_completed' then null
        else live_runtime_workflow_step_registry.last_error_details
      end,
      input_payload = case
        when p_input_payload is not null and p_input_payload <> '{}'::jsonb then p_input_payload
        else live_runtime_workflow_step_registry.input_payload
      end,
      output_payload = coalesce(p_output_payload, live_runtime_workflow_step_registry.output_payload),
      metadata = live_runtime_workflow_step_registry.metadata || coalesce(p_metadata, '{}'::jsonb);
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_workflow_instance_id::text, 0));

  select coalesce(max(t.sequence_no), 0) + 1
  into v_sequence
  from public.live_runtime_workflow_timeline t
  where t.workflow_instance_id = p_workflow_instance_id;

  insert into public.live_runtime_workflow_timeline (
    workflow_instance_id,
    sequence_no,
    event_type,
    workflow_status,
    step_instance_id,
    step_key,
    step_index,
    step_status,
    attempt_no,
    job_id,
    correlation_id,
    causation_id,
    occurred_at,
    scheduled_at,
    started_at,
    finished_at,
    error_code,
    error_message,
    error_details,
    payload,
    metadata
  )
  values (
    p_workflow_instance_id,
    v_sequence,
    p_event_type,
    v_workflow_status,
    p_step_instance_id,
    p_step_key,
    p_step_index,
    v_step_status,
    p_attempt_no,
    p_job_id,
    coalesce(p_correlation_id, v_registry.correlation_id),
    coalesce(p_causation_id, v_registry.causation_id),
    v_now,
    p_scheduled_at,
    case when p_event_type in ('workflow_started', 'step_started') then v_now else null end,
    case when p_event_type in (
      'workflow_completed', 'workflow_failed', 'workflow_cancelled', 'workflow_dead',
      'step_completed', 'step_failed', 'step_skipped'
    ) then v_now else null end,
    p_error_code,
    p_error_message,
    p_error_details,
    coalesce(p_payload, '{}'::jsonb),
    coalesce(p_metadata, '{}'::jsonb)
  )
  returning event_id into v_timeline_event_id;

  return query
  select v_registry.id, v_timeline_event_id, v_sequence;
end;
$$;

comment on function public.record_live_runtime_workflow_event_rpc(
  uuid, text, text, text, integer, text, text, uuid, uuid, uuid,
  text, uuid, uuid, uuid, uuid, uuid, text, text, integer, text,
  integer, uuid, timestamptz, timestamptz, text, text, jsonb,
  jsonb, jsonb, jsonb, jsonb
)
is 'Atomically appends one workflow event and updates workflow/step operational projections.';

-- --------------------------------------------------------------------------
-- 7. Read models
-- --------------------------------------------------------------------------

create or replace view public.live_runtime_workflow_status_v as
select
  r.id,
  r.workflow_instance_id,
  r.workflow_key,
  r.workflow_version,
  r.workflow_name,
  r.status,
  r.current_step_key,
  r.current_step_index,
  r.total_steps,
  r.completed_steps,
  r.failed_steps,
  r.retry_count,
  r.failure_count,
  r.correlation_id,
  r.causation_id,
  r.parent_workflow_instance_id,
  r.aggregate_type,
  r.aggregate_id,
  r.league_id,
  r.league_round_id,
  r.match_id,
  r.created_at,
  r.started_at,
  r.waiting_since,
  r.last_transition_at,
  r.last_heartbeat_at,
  r.completed_at,
  r.failed_at,
  r.cancelled_at,
  case
    when r.started_at is null then null
    else extract(epoch from (coalesce(r.completed_at, r.failed_at, r.cancelled_at, clock_timestamp()) - r.started_at))::bigint
  end as duration_seconds,
  case
    when r.waiting_since is null then null
    else extract(epoch from (clock_timestamp() - r.waiting_since))::bigint
  end as waiting_seconds,
  extract(epoch from (clock_timestamp() - r.last_transition_at))::bigint as idle_seconds,
  r.last_error_code,
  r.last_error_message,
  r.last_error_details,
  r.metadata,
  r.updated_at
from public.live_runtime_workflow_registry r;

comment on view public.live_runtime_workflow_status_v
is 'Current workflow status with calculated duration, waiting and idle metrics.';

create or replace view public.live_runtime_workflow_step_status_v as
select
  s.id,
  s.workflow_instance_id,
  r.workflow_key,
  r.correlation_id,
  s.step_instance_id,
  s.step_key,
  s.step_name,
  s.step_index,
  s.status,
  s.attempt_count,
  s.retry_count,
  s.job_id,
  s.created_at,
  s.queued_at,
  s.started_at,
  s.waiting_since,
  s.last_transition_at,
  s.completed_at,
  s.failed_at,
  case
    when s.started_at is null then null
    else extract(epoch from (coalesce(s.completed_at, s.failed_at, clock_timestamp()) - s.started_at))::bigint
  end as duration_seconds,
  case
    when s.waiting_since is null then null
    else extract(epoch from (clock_timestamp() - s.waiting_since))::bigint
  end as waiting_seconds,
  s.last_error_code,
  s.last_error_message,
  s.last_error_details,
  s.metadata,
  s.updated_at
from public.live_runtime_workflow_step_registry s
join public.live_runtime_workflow_registry r
  on r.workflow_instance_id = s.workflow_instance_id;

comment on view public.live_runtime_workflow_step_status_v
is 'Current workflow step status with duration and waiting metrics.';

create or replace view public.live_runtime_workflow_runtime_metrics_v as
select
  date_trunc('hour', r.created_at) as metric_hour,
  r.workflow_key,
  count(*) as workflow_count,
  count(*) filter (where r.status = 'completed') as completed_count,
  count(*) filter (where r.status = 'failed') as failed_count,
  count(*) filter (where r.status = 'dead') as dead_count,
  count(*) filter (where r.status in ('waiting', 'retry_scheduled')) as waiting_count,
  sum(r.retry_count)::bigint as retry_count,
  avg(
    extract(epoch from (r.completed_at - r.started_at))
  ) filter (
    where r.completed_at is not null and r.started_at is not null
  ) as average_completed_duration_seconds,
  percentile_cont(0.95) within group (
    order by extract(epoch from (r.completed_at - r.started_at))
  ) filter (
    where r.completed_at is not null and r.started_at is not null
  ) as p95_completed_duration_seconds
from public.live_runtime_workflow_registry r
group by date_trunc('hour', r.created_at), r.workflow_key;

comment on view public.live_runtime_workflow_runtime_metrics_v
is 'Hourly workflow throughput, failures, retries and completion latency metrics.';

create or replace view public.live_runtime_workflow_attention_v as
select
  s.*,
  case
    when s.status = 'dead' then 100
    when s.status = 'failed' then 90
    when s.status = 'retry_scheduled' then 70
    when s.status = 'waiting' then 60
    else 0
  end as attention_priority
from public.live_runtime_workflow_status_v s
where s.status in ('waiting', 'retry_scheduled', 'failed', 'dead');

comment on view public.live_runtime_workflow_attention_v
is 'Workflows requiring operational attention, ordered by severity and age.';

-- --------------------------------------------------------------------------
-- 8. Query RPCs
-- --------------------------------------------------------------------------

create or replace function public.get_live_runtime_workflow_observability_rpc(
  p_workflow_instance_id uuid
)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_catalog
as $$
  select jsonb_build_object(
    'workflow', to_jsonb(w),
    'steps', coalesce((
      select jsonb_agg(to_jsonb(s) order by s.step_index)
      from public.live_runtime_workflow_step_status_v s
      where s.workflow_instance_id = p_workflow_instance_id
    ), '[]'::jsonb),
    'timeline', coalesce((
      select jsonb_agg(to_jsonb(t) order by t.sequence_no)
      from public.live_runtime_workflow_timeline t
      where t.workflow_instance_id = p_workflow_instance_id
    ), '[]'::jsonb)
  )
  from public.live_runtime_workflow_status_v w
  where w.workflow_instance_id = p_workflow_instance_id;
$$;

comment on function public.get_live_runtime_workflow_observability_rpc(uuid)
is 'Returns workflow status, ordered step projection and complete timeline as one JSON document.';

create or replace function public.get_live_runtime_workflow_correlation_rpc(
  p_correlation_id uuid
)
returns table (
  workflow_instance_id uuid,
  workflow_key text,
  status text,
  causation_id uuid,
  parent_workflow_instance_id uuid,
  created_at timestamptz,
  last_transition_at timestamptz,
  completed_at timestamptz,
  failed_at timestamptz
)
language sql
stable
security definer
set search_path = public, pg_catalog
as $$
  select
    r.workflow_instance_id,
    r.workflow_key,
    r.status,
    r.causation_id,
    r.parent_workflow_instance_id,
    r.created_at,
    r.last_transition_at,
    r.completed_at,
    r.failed_at
  from public.live_runtime_workflow_registry r
  where r.correlation_id = p_correlation_id
  order by r.created_at asc, r.workflow_instance_id;
$$;

comment on function public.get_live_runtime_workflow_correlation_rpc(uuid)
is 'Returns every workflow in a correlation chain in chronological order.';

-- --------------------------------------------------------------------------
-- 9. Security
-- --------------------------------------------------------------------------

alter table public.live_runtime_workflow_registry enable row level security;
alter table public.live_runtime_workflow_timeline enable row level security;
alter table public.live_runtime_workflow_step_registry enable row level security;

revoke all on table public.live_runtime_workflow_registry from public, anon, authenticated;
revoke all on table public.live_runtime_workflow_timeline from public, anon, authenticated;
revoke all on table public.live_runtime_workflow_step_registry from public, anon, authenticated;

revoke all on public.live_runtime_workflow_status_v from public, anon, authenticated;
revoke all on public.live_runtime_workflow_step_status_v from public, anon, authenticated;
revoke all on public.live_runtime_workflow_runtime_metrics_v from public, anon, authenticated;
revoke all on public.live_runtime_workflow_attention_v from public, anon, authenticated;

revoke all on function public.record_live_runtime_workflow_event_rpc(
  uuid, text, text, text, integer, text, text, uuid, uuid, uuid,
  text, uuid, uuid, uuid, uuid, uuid, text, text, integer, text,
  integer, uuid, timestamptz, timestamptz, text, text, jsonb,
  jsonb, jsonb, jsonb, jsonb
) from public, anon, authenticated;
revoke all on function public.get_live_runtime_workflow_observability_rpc(uuid)
  from public, anon, authenticated;
revoke all on function public.get_live_runtime_workflow_correlation_rpc(uuid)
  from public, anon, authenticated;

-- Explicit service role privileges. Supabase service_role normally bypasses
-- RLS; explicit grants make the operational contract self-documenting.
grant select, insert, update, delete on table public.live_runtime_workflow_registry to service_role;
grant select, insert on table public.live_runtime_workflow_timeline to service_role;
grant select, insert, update, delete on table public.live_runtime_workflow_step_registry to service_role;
grant usage, select on sequence public.live_runtime_workflow_timeline_id_seq to service_role;

grant select on public.live_runtime_workflow_status_v to service_role;
grant select on public.live_runtime_workflow_step_status_v to service_role;
grant select on public.live_runtime_workflow_runtime_metrics_v to service_role;
grant select on public.live_runtime_workflow_attention_v to service_role;

grant execute on function public.record_live_runtime_workflow_event_rpc(
  uuid, text, text, text, integer, text, text, uuid, uuid, uuid,
  text, uuid, uuid, uuid, uuid, uuid, text, text, integer, text,
  integer, uuid, timestamptz, timestamptz, text, text, jsonb,
  jsonb, jsonb, jsonb, jsonb
) to service_role;
grant execute on function public.get_live_runtime_workflow_observability_rpc(uuid)
  to service_role;
grant execute on function public.get_live_runtime_workflow_correlation_rpc(uuid)
  to service_role;

-- --------------------------------------------------------------------------
-- 10. Migration verification
-- --------------------------------------------------------------------------

do $$
declare
  v_missing text[];
begin
  select array_agg(expected.object_name order by expected.object_name)
  into v_missing
  from (
    values
      ('live_runtime_workflow_registry'),
      ('live_runtime_workflow_timeline'),
      ('live_runtime_workflow_step_registry'),
      ('live_runtime_workflow_status_v'),
      ('live_runtime_workflow_step_status_v'),
      ('live_runtime_workflow_runtime_metrics_v'),
      ('live_runtime_workflow_attention_v')
  ) as expected(object_name)
  where to_regclass('public.' || expected.object_name) is null;

  if v_missing is not null then
    raise exception 'Workflow Observability migration incomplete. Missing objects: %', v_missing;
  end if;
end;
$$;

commit;
