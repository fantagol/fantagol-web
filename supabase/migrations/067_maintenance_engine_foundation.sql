-- ============================================================================
-- FANTAGOL
-- Migration 067
-- Maintenance Engine Foundation
--
-- Milestone 7.4.1
--
-- Scope:
--   - maintenance policy registry
--   - auditable maintenance runs
--   - maintenance task ledger
--   - command outbox for runtime workers
--   - idempotent request, claim, heartbeat, completion and failure RPCs
--   - operational inspector views
--
-- Safety:
--   - no automatic destructive operation is enabled by this migration
--   - no existing workflow, recovery, publication or runtime row is deleted
--   - runtime mutation RPCs are service_role only
-- ============================================================================

begin;

create extension if not exists pgcrypto;

-- --------------------------------------------------------------------------
-- Shared updated_at trigger
-- --------------------------------------------------------------------------

create or replace function public.set_maintenance_updated_at()
returns trigger
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
begin
  new.updated_at := clock_timestamp();
  return new;
end;
$$;

comment on function public.set_maintenance_updated_at()
is 'Maintains updated_at for Maintenance Engine mutable records.';

-- --------------------------------------------------------------------------
-- Maintenance policy registry
-- --------------------------------------------------------------------------

create table if not exists public.maintenance_policies (
  id uuid primary key default gen_random_uuid(),
  policy_key text not null,
  policy_version integer not null default 1,
  display_name text not null,
  description text,
  operation_type text not null,
  target_scope text not null,
  schedule_expression text,
  retention_interval interval,
  batch_size integer not null default 100,
  max_attempts integer not null default 3,
  timeout_interval interval not null default interval '15 minutes',
  dry_run_default boolean not null default true,
  destructive boolean not null default false,
  enabled boolean not null default false,
  policy_config jsonb not null default '{}'::jsonb,
  created_by uuid,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  retired_at timestamptz,
  constraint maintenance_policies_policy_key_not_blank
    check (btrim(policy_key) <> ''),
  constraint maintenance_policies_display_name_not_blank
    check (btrim(display_name) <> ''),
  constraint maintenance_policies_operation_type_not_blank
    check (btrim(operation_type) <> ''),
  constraint maintenance_policies_target_scope_not_blank
    check (btrim(target_scope) <> ''),
  constraint maintenance_policies_version_positive
    check (policy_version > 0),
  constraint maintenance_policies_batch_size_positive
    check (batch_size > 0),
  constraint maintenance_policies_max_attempts_positive
    check (max_attempts > 0),
  constraint maintenance_policies_timeout_positive
    check (timeout_interval > interval '0 seconds'),
  constraint maintenance_policies_config_object
    check (jsonb_typeof(policy_config) = 'object'),
  constraint maintenance_policies_destructive_safety
    check (
      destructive = false
      or dry_run_default = true
      or enabled = false
    ),
  constraint maintenance_policies_unique_version
    unique (policy_key, policy_version)
);

create unique index if not exists maintenance_policies_one_active_version_uidx
  on public.maintenance_policies (policy_key)
  where retired_at is null;

create index if not exists maintenance_policies_enabled_idx
  on public.maintenance_policies (enabled, operation_type, target_scope)
  where retired_at is null;

drop trigger if exists trg_maintenance_policies_updated_at
  on public.maintenance_policies;

create trigger trg_maintenance_policies_updated_at
before update on public.maintenance_policies
for each row
execute function public.set_maintenance_updated_at();

comment on table public.maintenance_policies
is 'Versioned policy registry for scheduled and operator-requested maintenance operations. Policies are disabled by default.';

-- --------------------------------------------------------------------------
-- Maintenance run ledger
-- --------------------------------------------------------------------------

create table if not exists public.maintenance_runs (
  id uuid primary key default gen_random_uuid(),
  policy_id uuid references public.maintenance_policies(id) on delete restrict,
  policy_key text not null,
  operation_type text not null,
  target_scope text not null,
  trigger_type text not null default 'manual',
  requested_by uuid,
  requested_at timestamptz not null default clock_timestamp(),
  scheduled_for timestamptz not null default clock_timestamp(),
  started_at timestamptz,
  heartbeat_at timestamptz,
  completed_at timestamptz,
  status text not null default 'requested',
  dry_run boolean not null default true,
  idempotency_key text not null,
  correlation_id uuid not null default gen_random_uuid(),
  causation_id uuid,
  worker_id text,
  lease_token uuid,
  lease_expires_at timestamptz,
  attempt_count integer not null default 0,
  max_attempts integer not null default 3,
  timeout_interval interval not null default interval '15 minutes',
  request_payload jsonb not null default '{}'::jsonb,
  result_payload jsonb,
  error_code text,
  error_message text,
  error_details jsonb,
  metrics jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  constraint maintenance_runs_policy_key_not_blank
    check (btrim(policy_key) <> ''),
  constraint maintenance_runs_operation_type_not_blank
    check (btrim(operation_type) <> ''),
  constraint maintenance_runs_target_scope_not_blank
    check (btrim(target_scope) <> ''),
  constraint maintenance_runs_trigger_type
    check (trigger_type in ('manual', 'scheduled', 'reconciliation', 'system')),
  constraint maintenance_runs_status
    check (
      status in (
        'requested',
        'queued',
        'running',
        'succeeded',
        'failed',
        'cancelled',
        'expired'
      )
    ),
  constraint maintenance_runs_idempotency_not_blank
    check (btrim(idempotency_key) <> ''),
  constraint maintenance_runs_attempt_count_nonnegative
    check (attempt_count >= 0),
  constraint maintenance_runs_max_attempts_positive
    check (max_attempts > 0),
  constraint maintenance_runs_attempt_limit
    check (attempt_count <= max_attempts),
  constraint maintenance_runs_timeout_positive
    check (timeout_interval > interval '0 seconds'),
  constraint maintenance_runs_request_object
    check (jsonb_typeof(request_payload) = 'object'),
  constraint maintenance_runs_result_object
    check (result_payload is null or jsonb_typeof(result_payload) = 'object'),
  constraint maintenance_runs_error_details_object
    check (error_details is null or jsonb_typeof(error_details) = 'object'),
  constraint maintenance_runs_metrics_object
    check (jsonb_typeof(metrics) = 'object'),
  constraint maintenance_runs_started_consistency
    check (
      status not in ('running', 'succeeded', 'failed', 'cancelled', 'expired')
      or started_at is not null
    ),
  constraint maintenance_runs_completed_consistency
    check (
      status not in ('succeeded', 'failed', 'cancelled', 'expired')
      or completed_at is not null
    ),
  constraint maintenance_runs_lease_consistency
    check (
      (lease_token is null and lease_expires_at is null)
      or
      (lease_token is not null and lease_expires_at is not null)
    )
);

create unique index if not exists maintenance_runs_idempotency_uidx
  on public.maintenance_runs (idempotency_key);

create index if not exists maintenance_runs_dispatch_idx
  on public.maintenance_runs (status, scheduled_for, requested_at)
  where status in ('requested', 'queued');

create index if not exists maintenance_runs_running_lease_idx
  on public.maintenance_runs (lease_expires_at, heartbeat_at)
  where status = 'running';

create index if not exists maintenance_runs_policy_history_idx
  on public.maintenance_runs (policy_key, requested_at desc);

create index if not exists maintenance_runs_correlation_idx
  on public.maintenance_runs (correlation_id, requested_at desc);

drop trigger if exists trg_maintenance_runs_updated_at
  on public.maintenance_runs;

create trigger trg_maintenance_runs_updated_at
before update on public.maintenance_runs
for each row
execute function public.set_maintenance_updated_at();

comment on table public.maintenance_runs
is 'Auditable execution ledger for Maintenance Engine operations, including idempotency, lease ownership, results and errors.';

-- --------------------------------------------------------------------------
-- Maintenance task ledger
-- --------------------------------------------------------------------------

create table if not exists public.maintenance_tasks (
  id uuid primary key default gen_random_uuid(),
  maintenance_run_id uuid not null
    references public.maintenance_runs(id) on delete cascade,
  task_key text not null,
  task_order integer not null default 0,
  task_type text not null,
  target_ref text,
  status text not null default 'pending',
  attempt_count integer not null default 0,
  max_attempts integer not null default 3,
  scheduled_for timestamptz not null default clock_timestamp(),
  started_at timestamptz,
  heartbeat_at timestamptz,
  completed_at timestamptz,
  worker_id text,
  lease_token uuid,
  lease_expires_at timestamptz,
  input_payload jsonb not null default '{}'::jsonb,
  output_payload jsonb,
  error_code text,
  error_message text,
  error_details jsonb,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  constraint maintenance_tasks_task_key_not_blank
    check (btrim(task_key) <> ''),
  constraint maintenance_tasks_task_type_not_blank
    check (btrim(task_type) <> ''),
  constraint maintenance_tasks_task_order_nonnegative
    check (task_order >= 0),
  constraint maintenance_tasks_status
    check (
      status in (
        'pending',
        'queued',
        'running',
        'succeeded',
        'failed',
        'skipped',
        'cancelled',
        'expired'
      )
    ),
  constraint maintenance_tasks_attempt_count_nonnegative
    check (attempt_count >= 0),
  constraint maintenance_tasks_max_attempts_positive
    check (max_attempts > 0),
  constraint maintenance_tasks_attempt_limit
    check (attempt_count <= max_attempts),
  constraint maintenance_tasks_input_object
    check (jsonb_typeof(input_payload) = 'object'),
  constraint maintenance_tasks_output_object
    check (output_payload is null or jsonb_typeof(output_payload) = 'object'),
  constraint maintenance_tasks_error_details_object
    check (error_details is null or jsonb_typeof(error_details) = 'object'),
  constraint maintenance_tasks_lease_consistency
    check (
      (lease_token is null and lease_expires_at is null)
      or
      (lease_token is not null and lease_expires_at is not null)
    ),
  constraint maintenance_tasks_unique_key
    unique (maintenance_run_id, task_key)
);

create index if not exists maintenance_tasks_dispatch_idx
  on public.maintenance_tasks (status, scheduled_for, task_order)
  where status in ('pending', 'queued');

create index if not exists maintenance_tasks_run_idx
  on public.maintenance_tasks (maintenance_run_id, task_order, created_at);

create index if not exists maintenance_tasks_running_lease_idx
  on public.maintenance_tasks (lease_expires_at, heartbeat_at)
  where status = 'running';

drop trigger if exists trg_maintenance_tasks_updated_at
  on public.maintenance_tasks;

create trigger trg_maintenance_tasks_updated_at
before update on public.maintenance_tasks
for each row
execute function public.set_maintenance_updated_at();

comment on table public.maintenance_tasks
is 'Ordered task ledger belonging to a maintenance run. It is prepared for later housekeeping and reconciliation task types.';

-- --------------------------------------------------------------------------
-- Maintenance command outbox
-- --------------------------------------------------------------------------

create table if not exists public.maintenance_command_outbox (
  id uuid primary key default gen_random_uuid(),
  maintenance_run_id uuid not null
    references public.maintenance_runs(id) on delete cascade,
  command_type text not null,
  command_payload jsonb not null default '{}'::jsonb,
  status text not null default 'pending',
  available_at timestamptz not null default clock_timestamp(),
  claimed_at timestamptz,
  completed_at timestamptz,
  worker_id text,
  lease_token uuid,
  lease_expires_at timestamptz,
  attempt_count integer not null default 0,
  max_attempts integer not null default 3,
  last_error_code text,
  last_error_message text,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  constraint maintenance_command_outbox_type_not_blank
    check (btrim(command_type) <> ''),
  constraint maintenance_command_outbox_payload_object
    check (jsonb_typeof(command_payload) = 'object'),
  constraint maintenance_command_outbox_status
    check (status in ('pending', 'claimed', 'completed', 'failed', 'cancelled')),
  constraint maintenance_command_outbox_attempt_nonnegative
    check (attempt_count >= 0),
  constraint maintenance_command_outbox_max_attempts_positive
    check (max_attempts > 0),
  constraint maintenance_command_outbox_attempt_limit
    check (attempt_count <= max_attempts),
  constraint maintenance_command_outbox_lease_consistency
    check (
      (lease_token is null and lease_expires_at is null)
      or
      (lease_token is not null and lease_expires_at is not null)
    ),
  constraint maintenance_command_outbox_run_command_unique
    unique (maintenance_run_id, command_type)
);

create index if not exists maintenance_command_outbox_dispatch_idx
  on public.maintenance_command_outbox (status, available_at, created_at)
  where status = 'pending';

create index if not exists maintenance_command_outbox_claimed_lease_idx
  on public.maintenance_command_outbox (lease_expires_at)
  where status = 'claimed';

drop trigger if exists trg_maintenance_command_outbox_updated_at
  on public.maintenance_command_outbox;

create trigger trg_maintenance_command_outbox_updated_at
before update on public.maintenance_command_outbox
for each row
execute function public.set_maintenance_updated_at();

comment on table public.maintenance_command_outbox
is 'Transactional command outbox used to hand maintenance runs to a runtime worker without coupling policy creation to execution.';

-- --------------------------------------------------------------------------
-- Policy registration RPC
-- --------------------------------------------------------------------------

create or replace function public.register_maintenance_policy_rpc(
  p_policy_key text,
  p_display_name text,
  p_operation_type text,
  p_target_scope text,
  p_description text default null,
  p_schedule_expression text default null,
  p_retention_interval interval default null,
  p_batch_size integer default 100,
  p_max_attempts integer default 3,
  p_timeout_interval interval default interval '15 minutes',
  p_dry_run_default boolean default true,
  p_destructive boolean default false,
  p_enabled boolean default false,
  p_policy_config jsonb default '{}'::jsonb,
  p_created_by uuid default null
)
returns public.maintenance_policies
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_policy public.maintenance_policies;
  v_next_version integer;
begin
  if p_policy_key is null or btrim(p_policy_key) = '' then
    raise exception using
      errcode = '22023',
      message = 'policy_key is required';
  end if;

  if p_display_name is null or btrim(p_display_name) = '' then
    raise exception using
      errcode = '22023',
      message = 'display_name is required';
  end if;

  if p_operation_type is null or btrim(p_operation_type) = '' then
    raise exception using
      errcode = '22023',
      message = 'operation_type is required';
  end if;

  if p_target_scope is null or btrim(p_target_scope) = '' then
    raise exception using
      errcode = '22023',
      message = 'target_scope is required';
  end if;

  if p_policy_config is null or jsonb_typeof(p_policy_config) <> 'object' then
    raise exception using
      errcode = '22023',
      message = 'policy_config must be a JSON object';
  end if;

  if p_destructive and p_enabled and not p_dry_run_default then
    raise exception using
      errcode = '22023',
      message = 'a destructive policy cannot be registered enabled with dry_run_default=false';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('maintenance-policy:' || btrim(p_policy_key), 0)
  );

  update public.maintenance_policies
     set retired_at = clock_timestamp(),
         enabled = false
   where policy_key = btrim(p_policy_key)
     and retired_at is null;

  select coalesce(max(policy_version), 0) + 1
    into v_next_version
    from public.maintenance_policies
   where policy_key = btrim(p_policy_key);

  insert into public.maintenance_policies (
    policy_key,
    policy_version,
    display_name,
    description,
    operation_type,
    target_scope,
    schedule_expression,
    retention_interval,
    batch_size,
    max_attempts,
    timeout_interval,
    dry_run_default,
    destructive,
    enabled,
    policy_config,
    created_by
  )
  values (
    btrim(p_policy_key),
    v_next_version,
    btrim(p_display_name),
    nullif(btrim(coalesce(p_description, '')), ''),
    btrim(p_operation_type),
    btrim(p_target_scope),
    nullif(btrim(coalesce(p_schedule_expression, '')), ''),
    p_retention_interval,
    p_batch_size,
    p_max_attempts,
    p_timeout_interval,
    p_dry_run_default,
    p_destructive,
    p_enabled,
    p_policy_config,
    p_created_by
  )
  returning * into v_policy;

  return v_policy;
end;
$$;

comment on function public.register_maintenance_policy_rpc(
  text, text, text, text, text, text, interval, integer, integer,
  interval, boolean, boolean, boolean, jsonb, uuid
)
is 'Registers a new immutable policy version and retires the prior active version. Destructive policies are safety-gated.';

-- --------------------------------------------------------------------------
-- Maintenance run request RPC
-- --------------------------------------------------------------------------

create or replace function public.request_maintenance_run_rpc(
  p_policy_key text,
  p_idempotency_key text,
  p_trigger_type text default 'manual',
  p_requested_by uuid default null,
  p_scheduled_for timestamptz default clock_timestamp(),
  p_dry_run boolean default null,
  p_request_payload jsonb default '{}'::jsonb,
  p_correlation_id uuid default null,
  p_causation_id uuid default null
)
returns public.maintenance_runs
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_policy public.maintenance_policies;
  v_run public.maintenance_runs;
  v_effective_dry_run boolean;
begin
  if p_policy_key is null or btrim(p_policy_key) = '' then
    raise exception using errcode = '22023', message = 'policy_key is required';
  end if;

  if p_idempotency_key is null or btrim(p_idempotency_key) = '' then
    raise exception using errcode = '22023', message = 'idempotency_key is required';
  end if;

  if p_trigger_type not in ('manual', 'scheduled', 'reconciliation', 'system') then
    raise exception using errcode = '22023', message = 'unsupported trigger_type';
  end if;

  if p_request_payload is null or jsonb_typeof(p_request_payload) <> 'object' then
    raise exception using errcode = '22023', message = 'request_payload must be a JSON object';
  end if;

  select *
    into v_run
    from public.maintenance_runs
   where idempotency_key = btrim(p_idempotency_key);

  if found then
    return v_run;
  end if;

  select *
    into v_policy
    from public.maintenance_policies
   where policy_key = btrim(p_policy_key)
     and retired_at is null;

  if not found then
    raise exception using errcode = 'P0002', message = 'active maintenance policy not found';
  end if;

  if not v_policy.enabled then
    raise exception using errcode = '55000', message = 'maintenance policy is disabled';
  end if;

  v_effective_dry_run := coalesce(p_dry_run, v_policy.dry_run_default);

  if v_policy.destructive and not v_effective_dry_run then
    raise exception using
      errcode = '55000',
      message = 'destructive execution is not enabled by the Maintenance Engine foundation';
  end if;

  begin
    insert into public.maintenance_runs (
      policy_id,
      policy_key,
      operation_type,
      target_scope,
      trigger_type,
      requested_by,
      scheduled_for,
      status,
      dry_run,
      idempotency_key,
      correlation_id,
      causation_id,
      max_attempts,
      timeout_interval,
      request_payload
    )
    values (
      v_policy.id,
      v_policy.policy_key,
      v_policy.operation_type,
      v_policy.target_scope,
      p_trigger_type,
      p_requested_by,
      coalesce(p_scheduled_for, clock_timestamp()),
      'queued',
      v_effective_dry_run,
      btrim(p_idempotency_key),
      coalesce(p_correlation_id, gen_random_uuid()),
      p_causation_id,
      v_policy.max_attempts,
      v_policy.timeout_interval,
      p_request_payload
    )
    returning * into v_run;

    insert into public.maintenance_command_outbox (
      maintenance_run_id,
      command_type,
      command_payload,
      status,
      available_at,
      max_attempts
    )
    values (
      v_run.id,
      'execute_maintenance_run',
      jsonb_build_object(
        'maintenance_run_id', v_run.id,
        'policy_key', v_run.policy_key,
        'operation_type', v_run.operation_type,
        'target_scope', v_run.target_scope,
        'dry_run', v_run.dry_run,
        'correlation_id', v_run.correlation_id
      ),
      'pending',
      v_run.scheduled_for,
      v_run.max_attempts
    );
  exception
    when unique_violation then
      select *
        into v_run
        from public.maintenance_runs
       where idempotency_key = btrim(p_idempotency_key);

      if not found then
        raise;
      end if;
  end;

  return v_run;
end;
$$;

comment on function public.request_maintenance_run_rpc(
  text, text, text, uuid, timestamptz, boolean, jsonb, uuid, uuid
)
is 'Creates an idempotent queued maintenance run and its transactional execution command.';

-- --------------------------------------------------------------------------
-- Command claim RPC
-- --------------------------------------------------------------------------

create or replace function public.claim_maintenance_command_rpc(
  p_worker_id text,
  p_lease_interval interval default interval '2 minutes'
)
returns public.maintenance_command_outbox
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_command public.maintenance_command_outbox;
  v_token uuid := gen_random_uuid();
begin
  if p_worker_id is null or btrim(p_worker_id) = '' then
    raise exception using errcode = '22023', message = 'worker_id is required';
  end if;

  if p_lease_interval is null or p_lease_interval <= interval '0 seconds' then
    raise exception using errcode = '22023', message = 'lease_interval must be positive';
  end if;

  with candidate as (
    select id
      from public.maintenance_command_outbox
     where status = 'pending'
       and available_at <= clock_timestamp()
       and attempt_count < max_attempts
     order by available_at, created_at
     for update skip locked
     limit 1
  )
  update public.maintenance_command_outbox o
     set status = 'claimed',
         claimed_at = clock_timestamp(),
         worker_id = btrim(p_worker_id),
         lease_token = v_token,
         lease_expires_at = clock_timestamp() + p_lease_interval,
         attempt_count = o.attempt_count + 1
    from candidate
   where o.id = candidate.id
  returning o.* into v_command;

  if not found then
    return null;
  end if;

  update public.maintenance_runs
     set status = 'running',
         started_at = coalesce(started_at, clock_timestamp()),
         heartbeat_at = clock_timestamp(),
         worker_id = btrim(p_worker_id),
         lease_token = v_token,
         lease_expires_at = clock_timestamp() + p_lease_interval,
         attempt_count = attempt_count + 1
   where id = v_command.maintenance_run_id
     and status in ('queued', 'running')
     and attempt_count < max_attempts;

  return v_command;
end;
$$;

comment on function public.claim_maintenance_command_rpc(text, interval)
is 'Atomically claims one available maintenance command using SKIP LOCKED and assigns a lease token shared with its run.';

-- --------------------------------------------------------------------------
-- Run heartbeat RPC
-- --------------------------------------------------------------------------

create or replace function public.heartbeat_maintenance_run_rpc(
  p_maintenance_run_id uuid,
  p_lease_token uuid,
  p_lease_interval interval default interval '2 minutes',
  p_metrics jsonb default '{}'::jsonb
)
returns public.maintenance_runs
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_run public.maintenance_runs;
begin
  if p_metrics is null or jsonb_typeof(p_metrics) <> 'object' then
    raise exception using errcode = '22023', message = 'metrics must be a JSON object';
  end if;

  update public.maintenance_runs
     set heartbeat_at = clock_timestamp(),
         lease_expires_at = clock_timestamp() + p_lease_interval,
         metrics = metrics || p_metrics
   where id = p_maintenance_run_id
     and status = 'running'
     and lease_token = p_lease_token
     and lease_expires_at > clock_timestamp()
  returning * into v_run;

  if not found then
    raise exception using errcode = '55000', message = 'active maintenance run lease not found';
  end if;

  update public.maintenance_command_outbox
     set lease_expires_at = clock_timestamp() + p_lease_interval
   where maintenance_run_id = p_maintenance_run_id
     and status = 'claimed'
     and lease_token = p_lease_token;

  return v_run;
end;
$$;

comment on function public.heartbeat_maintenance_run_rpc(uuid, uuid, interval, jsonb)
is 'Renews a running maintenance lease and merges operational metrics.';

-- --------------------------------------------------------------------------
-- Run completion RPC
-- --------------------------------------------------------------------------

create or replace function public.complete_maintenance_run_rpc(
  p_maintenance_run_id uuid,
  p_lease_token uuid,
  p_result_payload jsonb default '{}'::jsonb,
  p_metrics jsonb default '{}'::jsonb
)
returns public.maintenance_runs
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_run public.maintenance_runs;
begin
  if p_result_payload is null or jsonb_typeof(p_result_payload) <> 'object' then
    raise exception using errcode = '22023', message = 'result_payload must be a JSON object';
  end if;

  if p_metrics is null or jsonb_typeof(p_metrics) <> 'object' then
    raise exception using errcode = '22023', message = 'metrics must be a JSON object';
  end if;

  update public.maintenance_runs
     set status = 'succeeded',
         completed_at = clock_timestamp(),
         heartbeat_at = clock_timestamp(),
         result_payload = p_result_payload,
         metrics = metrics || p_metrics,
         error_code = null,
         error_message = null,
         error_details = null,
         lease_token = null,
         lease_expires_at = null
   where id = p_maintenance_run_id
     and status = 'running'
     and lease_token = p_lease_token
  returning * into v_run;

  if not found then
    raise exception using errcode = '55000', message = 'running maintenance run lease not found';
  end if;

  update public.maintenance_command_outbox
     set status = 'completed',
         completed_at = clock_timestamp(),
         lease_token = null,
         lease_expires_at = null
   where maintenance_run_id = p_maintenance_run_id
     and status = 'claimed'
     and lease_token = p_lease_token;

  return v_run;
end;
$$;

comment on function public.complete_maintenance_run_rpc(uuid, uuid, jsonb, jsonb)
is 'Completes a leased maintenance run and its command atomically.';

-- --------------------------------------------------------------------------
-- Run failure RPC
-- --------------------------------------------------------------------------

create or replace function public.fail_maintenance_run_rpc(
  p_maintenance_run_id uuid,
  p_lease_token uuid,
  p_error_code text,
  p_error_message text,
  p_error_details jsonb default '{}'::jsonb,
  p_retry_delay interval default interval '1 minute'
)
returns public.maintenance_runs
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_run public.maintenance_runs;
  v_retry boolean;
begin
  if p_error_code is null or btrim(p_error_code) = '' then
    raise exception using errcode = '22023', message = 'error_code is required';
  end if;

  if p_error_message is null or btrim(p_error_message) = '' then
    raise exception using errcode = '22023', message = 'error_message is required';
  end if;

  if p_error_details is null or jsonb_typeof(p_error_details) <> 'object' then
    raise exception using errcode = '22023', message = 'error_details must be a JSON object';
  end if;

  select (attempt_count < max_attempts)
    into v_retry
    from public.maintenance_runs
   where id = p_maintenance_run_id
     and status = 'running'
     and lease_token = p_lease_token
   for update;

  if not found then
    raise exception using errcode = '55000', message = 'running maintenance run lease not found';
  end if;

  if v_retry then
    update public.maintenance_runs
       set status = 'queued',
           scheduled_for = clock_timestamp() + greatest(
             coalesce(p_retry_delay, interval '1 minute'),
             interval '0 seconds'
           ),
           heartbeat_at = clock_timestamp(),
           worker_id = null,
           lease_token = null,
           lease_expires_at = null,
           error_code = btrim(p_error_code),
           error_message = btrim(p_error_message),
           error_details = p_error_details
     where id = p_maintenance_run_id
    returning * into v_run;

    update public.maintenance_command_outbox
       set status = 'pending',
           available_at = v_run.scheduled_for,
           claimed_at = null,
           worker_id = null,
           lease_token = null,
           lease_expires_at = null,
           last_error_code = btrim(p_error_code),
           last_error_message = btrim(p_error_message)
     where maintenance_run_id = p_maintenance_run_id
       and status = 'claimed'
       and lease_token = p_lease_token;
  else
    update public.maintenance_runs
       set status = 'failed',
           completed_at = clock_timestamp(),
           heartbeat_at = clock_timestamp(),
           error_code = btrim(p_error_code),
           error_message = btrim(p_error_message),
           error_details = p_error_details,
           lease_token = null,
           lease_expires_at = null
     where id = p_maintenance_run_id
    returning * into v_run;

    update public.maintenance_command_outbox
       set status = 'failed',
           completed_at = clock_timestamp(),
           lease_token = null,
           lease_expires_at = null,
           last_error_code = btrim(p_error_code),
           last_error_message = btrim(p_error_message)
     where maintenance_run_id = p_maintenance_run_id
       and status = 'claimed'
       and lease_token = p_lease_token;
  end if;

  return v_run;
end;
$$;

comment on function public.fail_maintenance_run_rpc(uuid, uuid, text, text, jsonb, interval)
is 'Records a leased run failure and either requeues it with delay or terminally fails it after the attempt limit.';

-- --------------------------------------------------------------------------
-- Expired lease recovery RPC
-- --------------------------------------------------------------------------

create or replace function public.requeue_expired_maintenance_leases_rpc(
  p_limit integer default 100,
  p_retry_delay interval default interval '1 minute'
)
returns table (
  maintenance_run_id uuid,
  previous_worker_id text,
  new_status text,
  scheduled_for timestamptz
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if p_limit is null or p_limit <= 0 then
    raise exception using errcode = '22023', message = 'limit must be positive';
  end if;

  return query
  with expired as (
    select r.id, r.worker_id, r.attempt_count, r.max_attempts
      from public.maintenance_runs r
     where r.status = 'running'
       and r.lease_expires_at <= clock_timestamp()
     order by r.lease_expires_at
     for update skip locked
     limit p_limit
  ),
  updated_runs as (
    update public.maintenance_runs r
       set status = case
                      when e.attempt_count < e.max_attempts then 'queued'
                      else 'expired'
                    end,
           scheduled_for = case
                             when e.attempt_count < e.max_attempts
                               then clock_timestamp() + greatest(
                                 coalesce(p_retry_delay, interval '1 minute'),
                                 interval '0 seconds'
                               )
                             else r.scheduled_for
                           end,
           completed_at = case
                            when e.attempt_count < e.max_attempts then null
                            else clock_timestamp()
                          end,
           error_code = 'MAINTENANCE_LEASE_EXPIRED',
           error_message = 'Maintenance worker lease expired before completion',
           worker_id = null,
           lease_token = null,
           lease_expires_at = null
      from expired e
     where r.id = e.id
    returning r.id, e.worker_id as previous_worker_id, r.status, r.scheduled_for
  ),
  updated_commands as (
    update public.maintenance_command_outbox o
       set status = case
                      when r.status = 'queued' then 'pending'
                      else 'failed'
                    end,
           available_at = r.scheduled_for,
           claimed_at = null,
           completed_at = case when r.status = 'expired' then clock_timestamp() else null end,
           worker_id = null,
           lease_token = null,
           lease_expires_at = null,
           last_error_code = 'MAINTENANCE_LEASE_EXPIRED',
           last_error_message = 'Maintenance worker lease expired before completion'
      from updated_runs r
     where o.maintenance_run_id = r.id
       and o.status = 'claimed'
    returning o.id
  )
  select
    r.id,
    r.previous_worker_id,
    r.status,
    r.scheduled_for
  from updated_runs r;
end;
$$;

comment on function public.requeue_expired_maintenance_leases_rpc(integer, interval)
is 'Requeues expired maintenance leases while attempts remain and terminally expires exhausted runs.';

-- --------------------------------------------------------------------------
-- Inspector views
-- --------------------------------------------------------------------------

create or replace view public.maintenance_run_status_v1
with (security_invoker = true)
as
select
  r.id as maintenance_run_id,
  r.policy_key,
  r.operation_type,
  r.target_scope,
  r.trigger_type,
  r.status,
  r.dry_run,
  r.requested_at,
  r.scheduled_for,
  r.started_at,
  r.heartbeat_at,
  r.completed_at,
  r.worker_id,
  r.attempt_count,
  r.max_attempts,
  r.lease_expires_at,
  r.correlation_id,
  r.causation_id,
  r.error_code,
  r.error_message,
  count(t.id) as task_count,
  count(t.id) filter (where t.status = 'succeeded') as succeeded_task_count,
  count(t.id) filter (where t.status = 'failed') as failed_task_count,
  count(t.id) filter (
    where t.status in ('pending', 'queued', 'running')
  ) as active_task_count
from public.maintenance_runs r
left join public.maintenance_tasks t
  on t.maintenance_run_id = r.id
group by r.id;

comment on view public.maintenance_run_status_v1
is 'Operational status projection for maintenance runs and their task counters.';

create or replace view public.maintenance_attention_v1
with (security_invoker = true)
as
select
  s.*,
  case
    when s.status = 'running'
     and s.lease_expires_at <= clock_timestamp()
      then 'expired_lease'
    when s.status = 'failed'
      then 'terminal_failure'
    when s.status in ('requested', 'queued')
     and s.scheduled_for < clock_timestamp() - interval '5 minutes'
      then 'dispatch_delay'
    when s.failed_task_count > 0
      then 'task_failure'
    else 'attention'
  end as attention_reason
from public.maintenance_run_status_v1 s
where
  s.status in ('failed', 'expired')
  or (
    s.status = 'running'
    and s.lease_expires_at <= clock_timestamp()
  )
  or (
    s.status in ('requested', 'queued')
    and s.scheduled_for < clock_timestamp() - interval '5 minutes'
  )
  or s.failed_task_count > 0;

comment on view public.maintenance_attention_v1
is 'Maintenance runs requiring operator or automated attention.';

-- --------------------------------------------------------------------------
-- Row level security
-- --------------------------------------------------------------------------

alter table public.maintenance_policies enable row level security;
alter table public.maintenance_runs enable row level security;
alter table public.maintenance_tasks enable row level security;
alter table public.maintenance_command_outbox enable row level security;

drop policy if exists maintenance_policies_service_role_all
  on public.maintenance_policies;
create policy maintenance_policies_service_role_all
  on public.maintenance_policies
  for all
  to service_role
  using (true)
  with check (true);

drop policy if exists maintenance_runs_service_role_all
  on public.maintenance_runs;
create policy maintenance_runs_service_role_all
  on public.maintenance_runs
  for all
  to service_role
  using (true)
  with check (true);

drop policy if exists maintenance_tasks_service_role_all
  on public.maintenance_tasks;
create policy maintenance_tasks_service_role_all
  on public.maintenance_tasks
  for all
  to service_role
  using (true)
  with check (true);

drop policy if exists maintenance_command_outbox_service_role_all
  on public.maintenance_command_outbox;
create policy maintenance_command_outbox_service_role_all
  on public.maintenance_command_outbox
  for all
  to service_role
  using (true)
  with check (true);

-- --------------------------------------------------------------------------
-- Privileges
-- --------------------------------------------------------------------------

revoke all on table public.maintenance_policies from public, anon, authenticated;
revoke all on table public.maintenance_runs from public, anon, authenticated;
revoke all on table public.maintenance_tasks from public, anon, authenticated;
revoke all on table public.maintenance_command_outbox from public, anon, authenticated;

grant select, insert, update, delete
  on table public.maintenance_policies
  to service_role;

grant select, insert, update, delete
  on table public.maintenance_runs
  to service_role;

grant select, insert, update, delete
  on table public.maintenance_tasks
  to service_role;

grant select, insert, update, delete
  on table public.maintenance_command_outbox
  to service_role;

revoke all on function public.register_maintenance_policy_rpc(
  text, text, text, text, text, text, interval, integer, integer,
  interval, boolean, boolean, boolean, jsonb, uuid
) from public, anon, authenticated;

revoke all on function public.request_maintenance_run_rpc(
  text, text, text, uuid, timestamptz, boolean, jsonb, uuid, uuid
) from public, anon, authenticated;

revoke all on function public.claim_maintenance_command_rpc(text, interval)
  from public, anon, authenticated;

revoke all on function public.heartbeat_maintenance_run_rpc(
  uuid, uuid, interval, jsonb
) from public, anon, authenticated;

revoke all on function public.complete_maintenance_run_rpc(
  uuid, uuid, jsonb, jsonb
) from public, anon, authenticated;

revoke all on function public.fail_maintenance_run_rpc(
  uuid, uuid, text, text, jsonb, interval
) from public, anon, authenticated;

revoke all on function public.requeue_expired_maintenance_leases_rpc(
  integer, interval
) from public, anon, authenticated;

grant execute on function public.register_maintenance_policy_rpc(
  text, text, text, text, text, text, interval, integer, integer,
  interval, boolean, boolean, boolean, jsonb, uuid
) to service_role;

grant execute on function public.request_maintenance_run_rpc(
  text, text, text, uuid, timestamptz, boolean, jsonb, uuid, uuid
) to service_role;

grant execute on function public.claim_maintenance_command_rpc(text, interval)
  to service_role;

grant execute on function public.heartbeat_maintenance_run_rpc(
  uuid, uuid, interval, jsonb
) to service_role;

grant execute on function public.complete_maintenance_run_rpc(
  uuid, uuid, jsonb, jsonb
) to service_role;

grant execute on function public.fail_maintenance_run_rpc(
  uuid, uuid, text, text, jsonb, interval
) to service_role;

grant execute on function public.requeue_expired_maintenance_leases_rpc(
  integer, interval
) to service_role;

revoke all on table public.maintenance_run_status_v1
  from public, anon, authenticated;

revoke all on table public.maintenance_attention_v1
  from public, anon, authenticated;

grant select on table public.maintenance_run_status_v1
  to service_role;

grant select on table public.maintenance_attention_v1
  to service_role;

-- --------------------------------------------------------------------------
-- Foundation seed policies
--
-- All policies remain disabled. Destructive policies remain dry-run only.
-- --------------------------------------------------------------------------

insert into public.maintenance_policies (
  policy_key,
  policy_version,
  display_name,
  description,
  operation_type,
  target_scope,
  batch_size,
  max_attempts,
  timeout_interval,
  dry_run_default,
  destructive,
  enabled,
  policy_config
)
values
  (
    'runtime_consistency_scan',
    1,
    'Runtime consistency scan',
    'Read-only consistency scan across runtime operational ledgers.',
    'consistency_scan',
    'runtime',
    250,
    3,
    interval '15 minutes',
    true,
    false,
    false,
    jsonb_build_object(
      'foundation_only', true,
      'execution_handler_required', true
    )
  ),
  (
    'workflow_retention_preview',
    1,
    'Workflow retention preview',
    'Dry-run preview for future workflow retention and archive operations.',
    'retention_preview',
    'workflow',
    250,
    3,
    interval '15 minutes',
    true,
    true,
    false,
    jsonb_build_object(
      'foundation_only', true,
      'destructive_execution_enabled', false,
      'execution_handler_required', true
    )
  )
on conflict (policy_key, policy_version) do nothing;

commit;
