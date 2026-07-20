-- ============================================================================
-- FANTAGOL
-- Migration 082: Platform Runtime Dispatcher Engine
-- Phase 8.3.3
--
-- Purpose
--   Connect the durable reconciliation action queue to certified runtime
--   workers through worker registration, batch dispatch, execution attempts,
--   retry/backoff, expired-claim reclaim, immutable execution receipts and a
--   durable dead-letter channel.
--
-- Safety
--   PostgreSQL remains the authoritative control plane. This migration never
--   starts or stops an external process. Workers execute actions outside the
--   database and report observations/results through guarded RPC contracts.
-- ============================================================================

begin;

-- --------------------------------------------------------------------------
-- 1. Evolve the action aggregate for dispatcher lifecycle
-- --------------------------------------------------------------------------

alter table public.platform_orchestrator_actions
  add column if not exists available_at timestamptz not null default now(),
  add column if not exists started_at timestamptz,
  add column if not exists max_attempts integer not null default 5,
  add column if not exists execution_fingerprint text,
  add column if not exists last_attempt_id uuid,
  add column if not exists dead_lettered_at timestamptz;

alter table public.platform_orchestrator_actions
  drop constraint if exists platform_orchestrator_actions_status_ck;

alter table public.platform_orchestrator_actions
  add constraint platform_orchestrator_actions_status_ck
  check (action_status in (
    'pending','claimed','running','retry_wait',
    'succeeded','failed','cancelled','expired','dead_letter'
  ));

alter table public.platform_orchestrator_actions
  drop constraint if exists platform_orchestrator_actions_claim_ck;

alter table public.platform_orchestrator_actions
  add constraint platform_orchestrator_actions_claim_ck
  check (
    action_status not in ('claimed','running')
    or (
      claimed_by is not null and claim_token is not null
      and claimed_at is not null and claim_expires_at is not null
    )
  );

alter table public.platform_orchestrator_actions
  drop constraint if exists platform_orchestrator_actions_completion_ck;

alter table public.platform_orchestrator_actions
  add constraint platform_orchestrator_actions_completion_ck
  check (
    (action_status in ('succeeded','failed','cancelled','expired','dead_letter') and completed_at is not null)
    or
    (action_status in ('pending','claimed','running','retry_wait') and completed_at is null)
  );

alter table public.platform_orchestrator_actions
  add constraint platform_orchestrator_actions_max_attempts_ck
  check (max_attempts between 1 and 20);

alter table public.platform_orchestrator_actions
  add constraint platform_orchestrator_actions_available_at_ck
  check (available_at is not null);

alter table public.platform_orchestrator_actions
  add constraint platform_orchestrator_actions_started_ck
  check (action_status <> 'running' or started_at is not null);

alter table public.platform_orchestrator_actions
  add constraint platform_orchestrator_actions_dead_letter_ck
  check (action_status <> 'dead_letter' or dead_lettered_at is not null);

create index if not exists platform_orchestrator_actions_available_idx
  on public.platform_orchestrator_actions
  (action_status, available_at, priority, created_at);

create unique index if not exists platform_orchestrator_actions_execution_fingerprint_uq
  on public.platform_orchestrator_actions (execution_fingerprint)
  where execution_fingerprint is not null;

comment on column public.platform_orchestrator_actions.available_at is
  'Earliest timestamp at which a pending or retry_wait action can be dispatched.';
comment on column public.platform_orchestrator_actions.execution_fingerprint is
  'Stable worker execution fingerprint preventing duplicate execution starts.';

-- --------------------------------------------------------------------------
-- 2. Runtime worker registry
-- --------------------------------------------------------------------------

create table if not exists public.platform_runtime_workers (
  worker_id text primary key,
  worker_version text not null,
  runtime_host text not null,
  process_id integer,
  worker_status text not null default 'online',
  capabilities jsonb not null default '[]'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  started_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  lease_expires_at timestamptz not null,
  running_action_count integer not null default 0,
  completed_action_count bigint not null default 0,
  failed_action_count bigint not null default 0,
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint platform_runtime_workers_status_ck
    check (worker_status in ('online','draining','offline','failed')),
  constraint platform_runtime_workers_capabilities_ck
    check (jsonb_typeof(capabilities) = 'array'),
  constraint platform_runtime_workers_metadata_ck
    check (jsonb_typeof(metadata) = 'object'),
  constraint platform_runtime_workers_counts_ck
    check (
      running_action_count >= 0
      and completed_action_count >= 0
      and failed_action_count >= 0
    ),
  constraint platform_runtime_workers_process_ck
    check (process_id is null or process_id > 0),
  constraint platform_runtime_workers_lease_ck
    check (lease_expires_at >= last_seen_at)
);

create index if not exists platform_runtime_workers_status_idx
  on public.platform_runtime_workers (worker_status, lease_expires_at);

comment on table public.platform_runtime_workers is
  'Certified runtime worker registry and heartbeat/lease state for dispatcher coordination.';

-- --------------------------------------------------------------------------
-- 3. Dispatch batches
-- --------------------------------------------------------------------------

create table if not exists public.platform_dispatch_batches (
  dispatch_batch_id uuid primary key default gen_random_uuid(),
  worker_id text not null,
  batch_status text not null default 'open',
  requested_limit integer not null,
  dispatched_action_count integer not null default 0,
  correlation_id uuid not null default gen_random_uuid(),
  opened_at timestamptz not null default now(),
  closed_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,

  constraint platform_dispatch_batches_worker_fk
    foreign key (worker_id)
    references public.platform_runtime_workers(worker_id)
    on update cascade on delete restrict,
  constraint platform_dispatch_batches_status_ck
    check (batch_status in ('open','closed','empty','failed')),
  constraint platform_dispatch_batches_limit_ck
    check (requested_limit between 1 and 50),
  constraint platform_dispatch_batches_count_ck
    check (dispatched_action_count between 0 and requested_limit),
  constraint platform_dispatch_batches_metadata_ck
    check (jsonb_typeof(metadata) = 'object'),
  constraint platform_dispatch_batches_completion_ck
    check (
      (batch_status = 'open' and closed_at is null)
      or (batch_status <> 'open' and closed_at is not null)
    )
);

create index if not exists platform_dispatch_batches_worker_idx
  on public.platform_dispatch_batches (worker_id, opened_at desc);

comment on table public.platform_dispatch_batches is
  'Atomic worker dispatch batches grouping actions claimed in one dispatcher poll.';

-- --------------------------------------------------------------------------
-- 4. Append-only execution attempts
-- --------------------------------------------------------------------------

create table if not exists public.platform_action_execution_attempts (
  attempt_id uuid primary key default gen_random_uuid(),
  action_id uuid not null,
  dispatch_batch_id uuid not null,
  worker_id text not null,
  attempt_number integer not null,
  attempt_status text not null default 'claimed',
  claim_token uuid not null,
  execution_fingerprint text not null unique,
  worker_version text not null,
  runtime_host text not null,
  process_id integer,
  claimed_at timestamptz not null,
  started_at timestamptz,
  completed_at timestamptz,
  duration_ms bigint,
  execution_result jsonb,
  error_message text,
  retryable boolean,
  next_retry_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,

  constraint platform_action_attempts_action_fk
    foreign key (action_id)
    references public.platform_orchestrator_actions(action_id)
    on delete restrict,
  constraint platform_action_attempts_batch_fk
    foreign key (dispatch_batch_id)
    references public.platform_dispatch_batches(dispatch_batch_id)
    on delete restrict,
  constraint platform_action_attempts_worker_fk
    foreign key (worker_id)
    references public.platform_runtime_workers(worker_id)
    on update cascade on delete restrict,
  constraint platform_action_attempts_action_number_uq
    unique (action_id, attempt_number),
  constraint platform_action_attempts_status_ck
    check (attempt_status in (
      'claimed','running','succeeded','retry_scheduled',
      'failed','cancelled','expired','dead_lettered'
    )),
  constraint platform_action_attempts_number_ck
    check (attempt_number > 0),
  constraint platform_action_attempts_process_ck
    check (process_id is null or process_id > 0),
  constraint platform_action_attempts_duration_ck
    check (duration_ms is null or duration_ms >= 0),
  constraint platform_action_attempts_result_ck
    check (execution_result is null or jsonb_typeof(execution_result) = 'object'),
  constraint platform_action_attempts_metadata_ck
    check (jsonb_typeof(metadata) = 'object'),
  constraint platform_action_attempts_started_ck
    check (attempt_status <> 'running' or started_at is not null),
  constraint platform_action_attempts_completion_ck
    check (
      (attempt_status in ('claimed','running') and completed_at is null)
      or (attempt_status not in ('claimed','running') and completed_at is not null)
    )
);

create index if not exists platform_action_attempts_action_idx
  on public.platform_action_execution_attempts (action_id, attempt_number desc);
create index if not exists platform_action_attempts_worker_idx
  on public.platform_action_execution_attempts (worker_id, claimed_at desc);

comment on table public.platform_action_execution_attempts is
  'Append-only execution-attempt journal for every dispatcher claim and outcome.';

-- --------------------------------------------------------------------------
-- 5. Immutable certified execution receipts
-- --------------------------------------------------------------------------

create table if not exists public.platform_action_execution_receipts (
  receipt_id uuid primary key default gen_random_uuid(),
  action_id uuid not null,
  attempt_id uuid not null unique,
  worker_id text not null,
  receipt_status text not null,
  execution_fingerprint text not null unique,
  action_type text not null,
  engine_code text not null,
  target_generation bigint not null,
  observed_status text,
  observed_generation bigint,
  worker_version text not null,
  runtime_host text not null,
  process_id integer,
  claimed_at timestamptz not null,
  started_at timestamptz,
  completed_at timestamptz not null,
  duration_ms bigint not null,
  result jsonb not null default '{}'::jsonb,
  error_message text,
  correlation_id uuid not null,
  causation_id uuid,
  receipt_hash text not null unique,
  created_at timestamptz not null default now(),

  constraint platform_action_receipts_action_fk
    foreign key (action_id)
    references public.platform_orchestrator_actions(action_id)
    on delete restrict,
  constraint platform_action_receipts_attempt_fk
    foreign key (attempt_id)
    references public.platform_action_execution_attempts(attempt_id)
    on delete restrict,
  constraint platform_action_receipts_worker_fk
    foreign key (worker_id)
    references public.platform_runtime_workers(worker_id)
    on update cascade on delete restrict,
  constraint platform_action_receipts_engine_fk
    foreign key (engine_code)
    references public.platform_engine_registry(engine_code)
    on update cascade on delete restrict,
  constraint platform_action_receipts_status_ck
    check (receipt_status in ('succeeded','failed','cancelled','expired','dead_lettered')),
  constraint platform_action_receipts_action_type_ck
    check (action_type in (
      'start','stop','enter_maintenance','exit_maintenance','disable',
      'recover','refresh_observation'
    )),
  constraint platform_action_receipts_generation_ck
    check (target_generation > 0 and (observed_generation is null or observed_generation >= 0)),
  constraint platform_action_receipts_duration_ck
    check (duration_ms >= 0),
  constraint platform_action_receipts_result_ck
    check (jsonb_typeof(result) = 'object'),
  constraint platform_action_receipts_process_ck
    check (process_id is null or process_id > 0)
);

create index if not exists platform_action_receipts_engine_idx
  on public.platform_action_execution_receipts (engine_code, completed_at desc);

comment on table public.platform_action_execution_receipts is
  'Immutable certified receipt for each terminal runtime execution attempt.';

-- --------------------------------------------------------------------------
-- 6. Durable dead-letter channel
-- --------------------------------------------------------------------------

create table if not exists public.platform_orchestrator_dead_letters (
  dead_letter_id uuid primary key default gen_random_uuid(),
  action_id uuid not null unique,
  final_attempt_id uuid,
  engine_code text not null,
  action_type text not null,
  failure_code text not null,
  failure_message text,
  attempt_count integer not null,
  action_snapshot jsonb not null,
  final_result jsonb,
  correlation_id uuid not null,
  dead_lettered_at timestamptz not null default now(),
  resolution_status text not null default 'unresolved',
  resolved_at timestamptz,
  resolution_note text,
  metadata jsonb not null default '{}'::jsonb,

  constraint platform_dead_letters_action_fk
    foreign key (action_id)
    references public.platform_orchestrator_actions(action_id)
    on delete restrict,
  constraint platform_dead_letters_attempt_fk
    foreign key (final_attempt_id)
    references public.platform_action_execution_attempts(attempt_id)
    on delete restrict,
  constraint platform_dead_letters_engine_fk
    foreign key (engine_code)
    references public.platform_engine_registry(engine_code)
    on update cascade on delete restrict,
  constraint platform_dead_letters_type_ck
    check (action_type in (
      'start','stop','enter_maintenance','exit_maintenance','disable',
      'recover','refresh_observation'
    )),
  constraint platform_dead_letters_attempt_ck
    check (attempt_count > 0),
  constraint platform_dead_letters_snapshot_ck
    check (jsonb_typeof(action_snapshot) = 'object'),
  constraint platform_dead_letters_result_ck
    check (final_result is null or jsonb_typeof(final_result) = 'object'),
  constraint platform_dead_letters_metadata_ck
    check (jsonb_typeof(metadata) = 'object'),
  constraint platform_dead_letters_resolution_ck
    check (resolution_status in ('unresolved','acknowledged','resolved')),
  constraint platform_dead_letters_resolution_time_ck
    check (resolution_status <> 'resolved' or resolved_at is not null)
);

create index if not exists platform_dead_letters_status_idx
  on public.platform_orchestrator_dead_letters (resolution_status, dead_lettered_at desc);

comment on table public.platform_orchestrator_dead_letters is
  'Durable terminal failure channel preserving the complete failed action snapshot.';

-- --------------------------------------------------------------------------
-- 7. Generic updated_at and immutability triggers
-- --------------------------------------------------------------------------

drop trigger if exists trg_platform_runtime_workers_updated_at on public.platform_runtime_workers;
create trigger trg_platform_runtime_workers_updated_at
before update on public.platform_runtime_workers
for each row execute function public.set_platform_governance_updated_at();

create or replace function public.protect_platform_dispatch_append_only()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $function$
begin
  raise exception 'PLATFORM_DISPATCH_APPEND_ONLY_VIOLATION: %.%', tg_table_name, tg_op;
end;
$function$;

drop trigger if exists trg_protect_platform_action_execution_receipts on public.platform_action_execution_receipts;
create trigger trg_protect_platform_action_execution_receipts
before update or delete on public.platform_action_execution_receipts
for each row execute function public.protect_platform_dispatch_append_only();

drop trigger if exists trg_protect_platform_orchestrator_dead_letters_delete on public.platform_orchestrator_dead_letters;
create trigger trg_protect_platform_orchestrator_dead_letters_delete
before delete on public.platform_orchestrator_dead_letters
for each row execute function public.protect_platform_dispatch_append_only();

-- --------------------------------------------------------------------------
-- 8. Backoff helper
-- --------------------------------------------------------------------------

create or replace function public.calculate_platform_dispatch_retry_at(
  p_attempt_number integer,
  p_now timestamptz default now()
)
returns timestamptz
language plpgsql
immutable
security definer
set search_path = public, pg_temp
as $function$
begin
  if p_attempt_number < 1 then
    raise exception 'PLATFORM_DISPATCH_INVALID_ATTEMPT_NUMBER: %', p_attempt_number;
  end if;

  return p_now + case
    when p_attempt_number = 1 then interval '30 seconds'
    when p_attempt_number = 2 then interval '2 minutes'
    when p_attempt_number = 3 then interval '5 minutes'
    when p_attempt_number = 4 then interval '15 minutes'
    else interval '30 minutes'
  end;
end;
$function$;

-- --------------------------------------------------------------------------
-- 9. Worker registration and heartbeat
-- --------------------------------------------------------------------------

create or replace function public.register_platform_runtime_worker_rpc(
  p_worker_id text,
  p_worker_version text,
  p_runtime_host text,
  p_process_id integer default null,
  p_capabilities jsonb default '[]'::jsonb,
  p_metadata jsonb default '{}'::jsonb,
  p_lease_seconds integer default 180
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $function$
declare
  v_worker public.platform_runtime_workers%rowtype;
begin
  if nullif(btrim(p_worker_id),'') is null then raise exception 'PLATFORM_RUNTIME_WORKER_ID_REQUIRED'; end if;
  if nullif(btrim(p_worker_version),'') is null then raise exception 'PLATFORM_RUNTIME_WORKER_VERSION_REQUIRED'; end if;
  if nullif(btrim(p_runtime_host),'') is null then raise exception 'PLATFORM_RUNTIME_HOST_REQUIRED'; end if;
  if p_process_id is not null and p_process_id <= 0 then raise exception 'PLATFORM_RUNTIME_INVALID_PROCESS_ID'; end if;
  if p_capabilities is null or jsonb_typeof(p_capabilities) <> 'array' then raise exception 'PLATFORM_RUNTIME_CAPABILITIES_MUST_BE_ARRAY'; end if;
  if p_metadata is null or jsonb_typeof(p_metadata) <> 'object' then raise exception 'PLATFORM_RUNTIME_METADATA_MUST_BE_OBJECT'; end if;
  if p_lease_seconds < 30 or p_lease_seconds > 900 then raise exception 'PLATFORM_RUNTIME_INVALID_WORKER_LEASE_SECONDS: %', p_lease_seconds; end if;

  insert into public.platform_runtime_workers (
    worker_id,worker_version,runtime_host,process_id,worker_status,
    capabilities,metadata,started_at,last_seen_at,lease_expires_at
  ) values (
    btrim(p_worker_id),btrim(p_worker_version),btrim(p_runtime_host),p_process_id,'online',
    p_capabilities,p_metadata,now(),now(),now() + make_interval(secs => p_lease_seconds)
  )
  on conflict (worker_id) do update
  set worker_version = excluded.worker_version,
      runtime_host = excluded.runtime_host,
      process_id = excluded.process_id,
      worker_status = 'online',
      capabilities = excluded.capabilities,
      metadata = public.platform_runtime_workers.metadata || excluded.metadata,
      last_seen_at = now(),
      lease_expires_at = now() + make_interval(secs => p_lease_seconds),
      last_error = null
  returning * into v_worker;

  return jsonb_build_object(
    'contract_version','platform-runtime-worker-v1',
    'registered',true,
    'worker',to_jsonb(v_worker)
  );
end;
$function$;

create or replace function public.heartbeat_platform_runtime_worker_rpc(
  p_worker_id text,
  p_status text default 'online',
  p_metadata jsonb default '{}'::jsonb,
  p_lease_seconds integer default 180
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $function$
declare
  v_worker public.platform_runtime_workers%rowtype;
begin
  if p_status not in ('online','draining','offline','failed') then
    raise exception 'PLATFORM_RUNTIME_INVALID_WORKER_STATUS: %', p_status;
  end if;
  if p_metadata is null or jsonb_typeof(p_metadata) <> 'object' then raise exception 'PLATFORM_RUNTIME_METADATA_MUST_BE_OBJECT'; end if;
  if p_lease_seconds < 30 or p_lease_seconds > 900 then raise exception 'PLATFORM_RUNTIME_INVALID_WORKER_LEASE_SECONDS: %', p_lease_seconds; end if;

  update public.platform_runtime_workers
  set worker_status = p_status,
      last_seen_at = now(),
      lease_expires_at = now() + make_interval(secs => p_lease_seconds),
      metadata = metadata || p_metadata
  where worker_id = p_worker_id
  returning * into v_worker;

  if not found then raise exception 'PLATFORM_RUNTIME_WORKER_NOT_FOUND: %', p_worker_id; end if;

  return jsonb_build_object(
    'contract_version','platform-runtime-worker-heartbeat-v1',
    'heartbeat_recorded',true,
    'worker',to_jsonb(v_worker)
  );
end;
$function$;

-- --------------------------------------------------------------------------
-- 10. Reclaim expired actions and workers
-- --------------------------------------------------------------------------

create or replace function public.reclaim_platform_dispatch_leases_rpc(
  p_now timestamptz default now()
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $function$
declare
  v_action record;
  v_requeued integer := 0;
  v_dead_lettered integer := 0;
  v_workers_offline integer := 0;
  v_next_retry timestamptz;
begin
  update public.platform_runtime_workers
  set worker_status = 'offline',
      last_error = coalesce(last_error,'worker lease expired')
  where worker_status in ('online','draining')
    and lease_expires_at <= p_now;
  get diagnostics v_workers_offline = row_count;

  for v_action in
    select *
    from public.platform_orchestrator_actions
    where action_status in ('claimed','running')
      and claim_expires_at <= p_now
    for update skip locked
  loop
    update public.platform_action_execution_attempts
    set attempt_status = case
          when v_action.attempt_count >= v_action.max_attempts then 'dead_lettered'
          else 'expired'
        end,
        completed_at = p_now,
        duration_ms = greatest(0,(extract(epoch from (p_now - claimed_at))*1000)::bigint),
        error_message = coalesce(error_message,'execution claim lease expired'),
        retryable = (v_action.attempt_count < v_action.max_attempts),
        next_retry_at = case
          when v_action.attempt_count < v_action.max_attempts
            then public.calculate_platform_dispatch_retry_at(v_action.attempt_count,p_now)
          else null
        end
    where attempt_id = v_action.last_attempt_id
      and attempt_status in ('claimed','running');

    if v_action.attempt_count >= v_action.max_attempts then
      update public.platform_orchestrator_actions
      set action_status = 'dead_letter',
          last_error = 'execution claim lease expired; maximum attempts reached',
          completed_at = p_now,
          dead_lettered_at = p_now
      where action_id = v_action.action_id;

      insert into public.platform_orchestrator_dead_letters (
        action_id,final_attempt_id,engine_code,action_type,failure_code,
        failure_message,attempt_count,action_snapshot,final_result,correlation_id,metadata
      ) values (
        v_action.action_id,v_action.last_attempt_id,v_action.engine_code,v_action.action_type,
        'claim_expired_max_attempts','execution claim lease expired',v_action.attempt_count,
        to_jsonb(v_action),v_action.execution_result,v_action.correlation_id,
        jsonb_build_object('source','reclaim_platform_dispatch_leases_rpc')
      ) on conflict (action_id) do nothing;
      v_dead_lettered := v_dead_lettered + 1;
    else
      v_next_retry := public.calculate_platform_dispatch_retry_at(v_action.attempt_count,p_now);
      update public.platform_orchestrator_actions
      set action_status = 'retry_wait',
          available_at = v_next_retry,
          claimed_by = null,claim_token = null,claimed_at = null,claim_expires_at = null,
          started_at = null,
          last_error = 'execution claim lease expired'
      where action_id = v_action.action_id;
      v_requeued := v_requeued + 1;
    end if;

    update public.platform_runtime_workers
    set running_action_count = greatest(0,running_action_count - 1),
        failed_action_count = failed_action_count + 1,
        last_error = 'execution claim lease expired'
    where worker_id = v_action.claimed_by;
  end loop;

  update public.platform_orchestrator_actions
  set action_status = 'pending'
  where action_status = 'retry_wait' and available_at <= p_now;

  return jsonb_build_object(
    'contract_version','platform-dispatch-reclaim-v1',
    'workers_marked_offline',v_workers_offline,
    'actions_requeued',v_requeued,
    'actions_dead_lettered',v_dead_lettered,
    'evaluated_at',p_now
  );
end;
$function$;

-- --------------------------------------------------------------------------
-- 11. Atomic batch dispatch
-- --------------------------------------------------------------------------

create or replace function public.dispatch_platform_orchestrator_actions_rpc(
  p_worker_id text,
  p_limit integer default 5,
  p_claim_seconds integer default 120,
  p_correlation_id uuid default gen_random_uuid()
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $function$
declare
  v_worker public.platform_runtime_workers%rowtype;
  v_batch public.platform_dispatch_batches%rowtype;
  v_action public.platform_orchestrator_actions%rowtype;
  v_attempt public.platform_action_execution_attempts%rowtype;
  v_token uuid;
  v_fingerprint text;
  v_actions jsonb := '[]'::jsonb;
  v_count integer := 0;
begin
  if p_limit < 1 or p_limit > 50 then raise exception 'PLATFORM_DISPATCH_INVALID_BATCH_LIMIT: %', p_limit; end if;
  if p_claim_seconds < 15 or p_claim_seconds > 900 then raise exception 'PLATFORM_DISPATCH_INVALID_CLAIM_SECONDS: %', p_claim_seconds; end if;

  perform public.reclaim_platform_dispatch_leases_rpc(now());

  select * into v_worker
  from public.platform_runtime_workers
  where worker_id = p_worker_id
  for update;

  if not found then raise exception 'PLATFORM_RUNTIME_WORKER_NOT_FOUND: %', p_worker_id; end if;
  if v_worker.worker_status <> 'online' then raise exception 'PLATFORM_RUNTIME_WORKER_NOT_DISPATCHABLE: %', v_worker.worker_status; end if;
  if v_worker.lease_expires_at <= now() then raise exception 'PLATFORM_RUNTIME_WORKER_LEASE_EXPIRED'; end if;

  insert into public.platform_dispatch_batches (
    worker_id,batch_status,requested_limit,correlation_id,metadata
  ) values (
    p_worker_id,'open',p_limit,p_correlation_id,
    jsonb_build_object('claim_seconds',p_claim_seconds,'worker_version',v_worker.worker_version)
  ) returning * into v_batch;

  for v_action in
    select *
    from public.platform_orchestrator_actions
    where action_status in ('pending','retry_wait')
      and available_at <= now()
      and completed_at is null
    order by priority asc, available_at asc, created_at asc
    for update skip locked
    limit p_limit
  loop
    v_token := gen_random_uuid();
    v_fingerprint := encode(extensions.digest(
      convert_to(format('%s|%s|%s|%s',v_action.action_id,v_action.attempt_count + 1,p_worker_id,v_token),'UTF8'),
      'sha256'
    ),'hex');

    update public.platform_orchestrator_actions
    set action_status = 'claimed',
        claimed_by = p_worker_id,
        claim_token = v_token,
        claimed_at = now(),
        claim_expires_at = now() + make_interval(secs => p_claim_seconds),
        attempt_count = attempt_count + 1,
        execution_fingerprint = v_fingerprint,
        started_at = null,
        completed_at = null,
        dead_lettered_at = null
    where action_id = v_action.action_id
    returning * into v_action;

    insert into public.platform_action_execution_attempts (
      action_id,dispatch_batch_id,worker_id,attempt_number,attempt_status,
      claim_token,execution_fingerprint,worker_version,runtime_host,process_id,
      claimed_at,metadata
    ) values (
      v_action.action_id,v_batch.dispatch_batch_id,p_worker_id,v_action.attempt_count,'claimed',
      v_token,v_fingerprint,v_worker.worker_version,v_worker.runtime_host,v_worker.process_id,
      v_action.claimed_at,jsonb_build_object('action_priority',v_action.priority)
    ) returning * into v_attempt;

    update public.platform_orchestrator_actions
    set last_attempt_id = v_attempt.attempt_id
    where action_id = v_action.action_id;

    v_actions := v_actions || jsonb_build_array(jsonb_build_object(
      'action_id',v_action.action_id,
      'attempt_id',v_attempt.attempt_id,
      'claim_token',v_token,
      'execution_fingerprint',v_fingerprint,
      'action_type',v_action.action_type,
      'engine_code',v_action.engine_code,
      'target_generation',v_action.target_generation,
      'payload',v_action.payload,
      'claim_expires_at',v_action.claim_expires_at
    ));
    v_count := v_count + 1;
  end loop;

  update public.platform_dispatch_batches
  set batch_status = case when v_count = 0 then 'empty' else 'closed' end,
      dispatched_action_count = v_count,
      closed_at = now()
  where dispatch_batch_id = v_batch.dispatch_batch_id
  returning * into v_batch;

  if v_count > 0 then
    update public.platform_runtime_workers
    set running_action_count = running_action_count + v_count,
        last_seen_at = now()
    where worker_id = p_worker_id;
  end if;

  return jsonb_build_object(
    'contract_version','platform-runtime-dispatch-batch-v1',
    'dispatch_batch_id',v_batch.dispatch_batch_id,
    'worker_id',p_worker_id,
    'dispatched_action_count',v_count,
    'actions',v_actions
  );
end;
$function$;

-- --------------------------------------------------------------------------
-- 12. Execution start acknowledgement
-- --------------------------------------------------------------------------

create or replace function public.start_platform_orchestrator_action_rpc(
  p_action_id uuid,
  p_claim_token uuid,
  p_execution_fingerprint text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $function$
declare
  v_action public.platform_orchestrator_actions%rowtype;
  v_attempt public.platform_action_execution_attempts%rowtype;
begin
  select * into v_action from public.platform_orchestrator_actions
  where action_id = p_action_id for update;
  if not found then raise exception 'PLATFORM_ORCHESTRATOR_ACTION_NOT_FOUND: %', p_action_id; end if;
  if v_action.action_status <> 'claimed' then raise exception 'PLATFORM_ORCHESTRATOR_ACTION_NOT_CLAIMED: %', v_action.action_status; end if;
  if v_action.claim_token <> p_claim_token then raise exception 'PLATFORM_ORCHESTRATOR_CLAIM_TOKEN_MISMATCH'; end if;
  if v_action.execution_fingerprint <> p_execution_fingerprint then raise exception 'PLATFORM_DISPATCH_EXECUTION_FINGERPRINT_MISMATCH'; end if;
  if v_action.claim_expires_at <= now() then raise exception 'PLATFORM_ORCHESTRATOR_CLAIM_EXPIRED'; end if;

  update public.platform_orchestrator_actions
  set action_status = 'running', started_at = now()
  where action_id = p_action_id
  returning * into v_action;

  update public.platform_action_execution_attempts
  set attempt_status = 'running', started_at = v_action.started_at
  where attempt_id = v_action.last_attempt_id
  returning * into v_attempt;

  return jsonb_build_object(
    'contract_version','platform-runtime-execution-start-v1',
    'started',true,'action',to_jsonb(v_action),'attempt',to_jsonb(v_attempt)
  );
end;
$function$;

-- --------------------------------------------------------------------------
-- 13. Certified completion, retry and state reconciliation
-- --------------------------------------------------------------------------

create or replace function public.complete_platform_runtime_execution_rpc(
  p_action_id uuid,
  p_claim_token uuid,
  p_execution_fingerprint text,
  p_outcome text,
  p_result jsonb default '{}'::jsonb,
  p_error text default null,
  p_retryable boolean default false,
  p_observed_status text default null,
  p_observed_generation bigint default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $function$
declare
  v_action public.platform_orchestrator_actions%rowtype;
  v_attempt public.platform_action_execution_attempts%rowtype;
  v_worker public.platform_runtime_workers%rowtype;
  v_terminal_status text;
  v_attempt_status text;
  v_next_retry timestamptz;
  v_completed_at timestamptz := now();
  v_duration_ms bigint;
  v_receipt_hash text;
  v_receipt public.platform_action_execution_receipts%rowtype;
  v_reconcile jsonb;
begin
  if p_outcome not in ('succeeded','failed','cancelled') then raise exception 'PLATFORM_DISPATCH_INVALID_EXECUTION_OUTCOME: %', p_outcome; end if;
  if p_result is null or jsonb_typeof(p_result) <> 'object' then raise exception 'PLATFORM_DISPATCH_RESULT_MUST_BE_OBJECT'; end if;

  select * into v_action from public.platform_orchestrator_actions
  where action_id = p_action_id for update;
  if not found then raise exception 'PLATFORM_ORCHESTRATOR_ACTION_NOT_FOUND: %', p_action_id; end if;
  if v_action.action_status not in ('claimed','running') then raise exception 'PLATFORM_DISPATCH_ACTION_NOT_EXECUTING: %', v_action.action_status; end if;
  if v_action.claim_token <> p_claim_token then raise exception 'PLATFORM_ORCHESTRATOR_CLAIM_TOKEN_MISMATCH'; end if;
  if v_action.execution_fingerprint <> p_execution_fingerprint then raise exception 'PLATFORM_DISPATCH_EXECUTION_FINGERPRINT_MISMATCH'; end if;
  if v_action.claim_expires_at <= v_completed_at then raise exception 'PLATFORM_ORCHESTRATOR_CLAIM_EXPIRED'; end if;

  select * into v_attempt from public.platform_action_execution_attempts
  where attempt_id = v_action.last_attempt_id for update;
  if not found then raise exception 'PLATFORM_DISPATCH_ATTEMPT_NOT_FOUND'; end if;

  select * into v_worker from public.platform_runtime_workers
  where worker_id = v_action.claimed_by for update;
  if not found then raise exception 'PLATFORM_RUNTIME_WORKER_NOT_FOUND: %', v_action.claimed_by; end if;

  v_duration_ms := greatest(0,(extract(epoch from (v_completed_at - coalesce(v_attempt.started_at,v_attempt.claimed_at)))*1000)::bigint);

  if p_outcome = 'failed' and p_retryable and v_action.attempt_count < v_action.max_attempts then
    v_terminal_status := 'retry_wait';
    v_attempt_status := 'retry_scheduled';
    v_next_retry := public.calculate_platform_dispatch_retry_at(v_action.attempt_count,v_completed_at);
  elsif p_outcome = 'failed' and v_action.attempt_count >= v_action.max_attempts then
    v_terminal_status := 'dead_letter';
    v_attempt_status := 'dead_lettered';
  else
    v_terminal_status := p_outcome;
    v_attempt_status := p_outcome;
  end if;

  update public.platform_action_execution_attempts
  set attempt_status = v_attempt_status,
      completed_at = v_completed_at,
      duration_ms = v_duration_ms,
      execution_result = p_result,
      error_message = p_error,
      retryable = p_retryable,
      next_retry_at = v_next_retry
  where attempt_id = v_attempt.attempt_id
  returning * into v_attempt;

  v_receipt_hash := encode(extensions.digest(convert_to(
    concat_ws('|',v_action.action_id,v_attempt.attempt_id,p_execution_fingerprint,p_outcome,
      v_completed_at::text,coalesce(p_error,''),p_result::text),'UTF8'),'sha256'),'hex');

  insert into public.platform_action_execution_receipts (
    action_id,attempt_id,worker_id,receipt_status,execution_fingerprint,
    action_type,engine_code,target_generation,observed_status,observed_generation,
    worker_version,runtime_host,process_id,claimed_at,started_at,completed_at,
    duration_ms,result,error_message,correlation_id,causation_id,receipt_hash
  ) values (
    v_action.action_id,v_attempt.attempt_id,v_worker.worker_id,
    case when v_attempt_status = 'retry_scheduled' then 'failed' else v_attempt_status end,
    p_execution_fingerprint,v_action.action_type,v_action.engine_code,v_action.target_generation,
    p_observed_status,p_observed_generation,v_worker.worker_version,v_worker.runtime_host,
    v_worker.process_id,v_attempt.claimed_at,v_attempt.started_at,v_completed_at,
    v_duration_ms,p_result,p_error,v_action.correlation_id,v_action.causation_id,v_receipt_hash
  ) returning * into v_receipt;

  if v_terminal_status = 'retry_wait' then
    update public.platform_orchestrator_actions
    set action_status = 'retry_wait',available_at = v_next_retry,
        claimed_by = null,claim_token = null,claimed_at = null,claim_expires_at = null,
        started_at = null,last_error = p_error,execution_result = p_result
    where action_id = v_action.action_id
    returning * into v_action;
  elsif v_terminal_status = 'dead_letter' then
    update public.platform_orchestrator_actions
    set action_status = 'dead_letter',last_error = p_error,execution_result = p_result,
        completed_at = v_completed_at,dead_lettered_at = v_completed_at
    where action_id = v_action.action_id
    returning * into v_action;

    insert into public.platform_orchestrator_dead_letters (
      action_id,final_attempt_id,engine_code,action_type,failure_code,
      failure_message,attempt_count,action_snapshot,final_result,correlation_id,metadata
    ) values (
      v_action.action_id,v_attempt.attempt_id,v_action.engine_code,v_action.action_type,
      'maximum_attempts_reached',p_error,v_action.attempt_count,to_jsonb(v_action),p_result,
      v_action.correlation_id,jsonb_build_object('receipt_id',v_receipt.receipt_id)
    ) on conflict (action_id) do nothing;
  else
    update public.platform_orchestrator_actions
    set action_status = v_terminal_status,last_error = p_error,execution_result = p_result,
        completed_at = v_completed_at
    where action_id = v_action.action_id
    returning * into v_action;
  end if;

  update public.platform_runtime_workers
  set running_action_count = greatest(0,running_action_count - 1),
      completed_action_count = completed_action_count + case when p_outcome = 'succeeded' then 1 else 0 end,
      failed_action_count = failed_action_count + case when p_outcome = 'failed' then 1 else 0 end,
      last_seen_at = v_completed_at,
      last_error = case when p_outcome = 'failed' then p_error else null end
  where worker_id = v_worker.worker_id;

  if p_outcome = 'succeeded' and p_observed_status is not null and p_observed_generation is not null then
    v_reconcile := public.reconcile_platform_engine_runtime_state_rpc(
      v_action.engine_code,p_observed_status,p_observed_generation,
      'runtime_dispatch_execution_succeeded',
      jsonb_build_object(
        'action_id',v_action.action_id,
        'attempt_id',v_attempt.attempt_id,
        'receipt_id',v_receipt.receipt_id,
        'execution_result',p_result
      ),v_action.correlation_id,v_action.action_id
    );
  end if;

  return jsonb_build_object(
    'contract_version','platform-runtime-execution-completion-v1',
    'completed',true,
    'action_status',v_action.action_status,
    'retry_at',v_next_retry,
    'receipt',to_jsonb(v_receipt),
    'runtime_reconciliation',v_reconcile
  );
end;
$function$;

-- --------------------------------------------------------------------------
-- 14. Read models and dispatcher health
-- --------------------------------------------------------------------------

create or replace function public.get_platform_runtime_workers_rpc(
  p_status text default null,
  p_limit integer default 100
)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $function$
  select coalesce(jsonb_agg(to_jsonb(w) order by w.last_seen_at desc),'[]'::jsonb)
  from (
    select * from public.platform_runtime_workers
    where p_status is null or worker_status = p_status
    order by last_seen_at desc
    limit greatest(1,least(coalesce(p_limit,100),500))
  ) w;
$function$;

create or replace function public.get_platform_dispatch_receipts_rpc(
  p_action_id uuid default null,
  p_engine_code text default null,
  p_limit integer default 100
)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $function$
  select coalesce(jsonb_agg(to_jsonb(r) order by r.completed_at desc),'[]'::jsonb)
  from (
    select * from public.platform_action_execution_receipts
    where (p_action_id is null or action_id = p_action_id)
      and (p_engine_code is null or engine_code = p_engine_code)
    order by completed_at desc
    limit greatest(1,least(coalesce(p_limit,100),500))
  ) r;
$function$;

create or replace function public.get_platform_dispatch_dead_letters_rpc(
  p_resolution_status text default null,
  p_limit integer default 100
)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $function$
  select coalesce(jsonb_agg(to_jsonb(d) order by d.dead_lettered_at desc),'[]'::jsonb)
  from (
    select * from public.platform_orchestrator_dead_letters
    where p_resolution_status is null or resolution_status = p_resolution_status
    order by dead_lettered_at desc
    limit greatest(1,least(coalesce(p_limit,100),500))
  ) d;
$function$;

create or replace function public.get_platform_dispatcher_health_rpc()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $function$
  select jsonb_build_object(
    'contract_version','platform-runtime-dispatcher-health-v1',
    'generated_at',now(),
    'workers',jsonb_build_object(
      'total',(select count(*) from public.platform_runtime_workers),
      'online',(select count(*) from public.platform_runtime_workers where worker_status = 'online' and lease_expires_at > now()),
      'stale',(select count(*) from public.platform_runtime_workers where lease_expires_at <= now())
    ),
    'queue',jsonb_build_object(
      'pending',(select count(*) from public.platform_orchestrator_actions where action_status = 'pending'),
      'claimed',(select count(*) from public.platform_orchestrator_actions where action_status = 'claimed'),
      'running',(select count(*) from public.platform_orchestrator_actions where action_status = 'running'),
      'retry_wait',(select count(*) from public.platform_orchestrator_actions where action_status = 'retry_wait'),
      'dead_letter',(select count(*) from public.platform_orchestrator_actions where action_status = 'dead_letter')
    ),
    'receipts',jsonb_build_object(
      'total',(select count(*) from public.platform_action_execution_receipts),
      'succeeded',(select count(*) from public.platform_action_execution_receipts where receipt_status = 'succeeded'),
      'failed',(select count(*) from public.platform_action_execution_receipts where receipt_status = 'failed')
    ),
    'dead_letters',(select count(*) from public.platform_orchestrator_dead_letters where resolution_status <> 'resolved')
  );
$function$;

-- --------------------------------------------------------------------------
-- 15. RLS, table grants and function grants
-- --------------------------------------------------------------------------

alter table public.platform_runtime_workers enable row level security;
alter table public.platform_dispatch_batches enable row level security;
alter table public.platform_action_execution_attempts enable row level security;
alter table public.platform_action_execution_receipts enable row level security;
alter table public.platform_orchestrator_dead_letters enable row level security;

revoke all on table public.platform_runtime_workers from anon, authenticated;
revoke all on table public.platform_dispatch_batches from anon, authenticated;
revoke all on table public.platform_action_execution_attempts from anon, authenticated;
revoke all on table public.platform_action_execution_receipts from anon, authenticated;
revoke all on table public.platform_orchestrator_dead_letters from anon, authenticated;

grant select,insert,update on table public.platform_runtime_workers to service_role;
grant select,insert,update on table public.platform_dispatch_batches to service_role;
grant select,insert,update on table public.platform_action_execution_attempts to service_role;
grant select,insert on table public.platform_action_execution_receipts to service_role;
grant select,insert,update on table public.platform_orchestrator_dead_letters to service_role;

drop policy if exists platform_runtime_workers_service_all on public.platform_runtime_workers;
create policy platform_runtime_workers_service_all on public.platform_runtime_workers
for all to service_role using (true) with check (true);

drop policy if exists platform_dispatch_batches_service_all on public.platform_dispatch_batches;
create policy platform_dispatch_batches_service_all on public.platform_dispatch_batches
for all to service_role using (true) with check (true);

drop policy if exists platform_action_attempts_service_all on public.platform_action_execution_attempts;
create policy platform_action_attempts_service_all on public.platform_action_execution_attempts
for all to service_role using (true) with check (true);

drop policy if exists platform_action_receipts_service_all on public.platform_action_execution_receipts;
create policy platform_action_receipts_service_all on public.platform_action_execution_receipts
for all to service_role using (true) with check (true);

drop policy if exists platform_dead_letters_service_all on public.platform_orchestrator_dead_letters;
create policy platform_dead_letters_service_all on public.platform_orchestrator_dead_letters
for all to service_role using (true) with check (true);

-- Retire the direct 081 single-action claim/completion path. The functions remain
-- for historical schema compatibility but no runtime role may bypass receipts.
revoke all on function public.claim_platform_orchestrator_action_rpc(text,integer) from public, anon, authenticated, service_role;
revoke all on function public.complete_platform_orchestrator_action_rpc(uuid,uuid,text,jsonb,text) from public, anon, authenticated, service_role;

revoke all on function public.protect_platform_dispatch_append_only() from public, anon, authenticated;
revoke all on function public.calculate_platform_dispatch_retry_at(integer,timestamptz) from public, anon;
revoke all on function public.register_platform_runtime_worker_rpc(text,text,text,integer,jsonb,jsonb,integer) from public, anon, authenticated;
revoke all on function public.heartbeat_platform_runtime_worker_rpc(text,text,jsonb,integer) from public, anon, authenticated;
revoke all on function public.reclaim_platform_dispatch_leases_rpc(timestamptz) from public, anon, authenticated;
revoke all on function public.dispatch_platform_orchestrator_actions_rpc(text,integer,integer,uuid) from public, anon, authenticated;
revoke all on function public.start_platform_orchestrator_action_rpc(uuid,uuid,text) from public, anon, authenticated;
revoke all on function public.complete_platform_runtime_execution_rpc(uuid,uuid,text,text,jsonb,text,boolean,text,bigint) from public, anon, authenticated;
revoke all on function public.get_platform_runtime_workers_rpc(text,integer) from public, anon;
revoke all on function public.get_platform_dispatch_receipts_rpc(uuid,text,integer) from public, anon;
revoke all on function public.get_platform_dispatch_dead_letters_rpc(text,integer) from public, anon;
revoke all on function public.get_platform_dispatcher_health_rpc() from public, anon;

grant execute on function public.calculate_platform_dispatch_retry_at(integer,timestamptz) to authenticated, service_role;
grant execute on function public.register_platform_runtime_worker_rpc(text,text,text,integer,jsonb,jsonb,integer) to service_role;
grant execute on function public.heartbeat_platform_runtime_worker_rpc(text,text,jsonb,integer) to service_role;
grant execute on function public.reclaim_platform_dispatch_leases_rpc(timestamptz) to service_role;
grant execute on function public.dispatch_platform_orchestrator_actions_rpc(text,integer,integer,uuid) to service_role;
grant execute on function public.start_platform_orchestrator_action_rpc(uuid,uuid,text) to service_role;
grant execute on function public.complete_platform_runtime_execution_rpc(uuid,uuid,text,text,jsonb,text,boolean,text,bigint) to service_role;
grant execute on function public.get_platform_runtime_workers_rpc(text,integer) to authenticated, service_role;
grant execute on function public.get_platform_dispatch_receipts_rpc(uuid,text,integer) to authenticated, service_role;
grant execute on function public.get_platform_dispatch_dead_letters_rpc(text,integer) to authenticated, service_role;
grant execute on function public.get_platform_dispatcher_health_rpc() to authenticated, service_role;

-- --------------------------------------------------------------------------
-- 16. Governance contracts, policies and feature metadata
-- --------------------------------------------------------------------------

insert into public.platform_runtime_policies (
  policy_key,policy_name,description,policy_type,policy_value,
  validation_contract,owner_engine_code,enforcement_level,enabled,metadata
)
values
  ('runtime.dispatcher.worker_lease','Runtime dispatcher worker lease','Maximum interval between worker heartbeats.','duration','"PT3M"'::jsonb,'{"format":"ISO-8601-duration"}'::jsonb,'platform_orchestrator_engine','critical',true,'{"migration":82}'::jsonb),
  ('runtime.dispatcher.max_attempts','Runtime dispatcher maximum attempts','Maximum execution attempts before dead-lettering.','integer','5'::jsonb,'{"minimum":1,"maximum":20}'::jsonb,'platform_orchestrator_engine','critical',true,'{"migration":82}'::jsonb),
  ('runtime.dispatcher.retry_backoff','Runtime dispatcher retry backoff','Deterministic retry schedule for failed or expired attempts.','array','["PT30S","PT2M","PT5M","PT15M","PT30M"]'::jsonb,'{"format":"ISO-8601-duration-array"}'::jsonb,'platform_orchestrator_engine','required',true,'{"migration":82}'::jsonb)
on conflict (policy_key) do update
set policy_value = excluded.policy_value,
    validation_contract = excluded.validation_contract,
    owner_engine_code = excluded.owner_engine_code,
    enforcement_level = excluded.enforcement_level,
    enabled = excluded.enabled,
    metadata = public.platform_runtime_policies.metadata || excluded.metadata;

update public.platform_feature_flags
set description = 'Expose persistent state, reconciliation planning, certified runtime dispatch, receipts, retries and dead letters.',
    metadata = metadata || jsonb_build_object(
      'contract','platform-orchestrator-v1.2',
      'dispatcher_migration',82,
      'execution_contract','platform-runtime-dispatch-v1'
    )
where feature_key = 'runtime.platform_orchestrator';

update public.platform_engine_registry
set engine_version = '1.2.0',
    certification_version = '1.2.0',
    is_certified = true,
    runtime_enabled = true,
    certified_at = now(),
    metadata = metadata || jsonb_build_object(
      'phase','8.3.3',
      'contract','platform-orchestrator-v1.2',
      'dispatcher_migration',82,
      'execution_mode','certified-runtime-dispatch'
    )
where engine_code = 'platform_orchestrator_engine';

create or replace function public.get_platform_governance_snapshot_rpc()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $function$
  select jsonb_build_object(
    'contract_version','platform-governance-v1.3',
    'generated_at',now(),
    'configuration',public.get_platform_configuration_rpc(),
    'engines',public.get_platform_engine_registry_rpc(false),
    'dependencies',public.get_platform_engine_dependencies_rpc(null,false),
    'dependency_validation',public.validate_platform_dependency_graph_rpc(null),
    'runtime_states',public.get_platform_engine_runtime_states_rpc(null),
    'orchestrator_cycles',public.get_platform_orchestrator_cycles_rpc(50),
    'orchestrator_actions',public.get_platform_orchestrator_actions_rpc(null,null,null,100),
    'dispatcher_health',public.get_platform_dispatcher_health_rpc(),
    'runtime_workers',public.get_platform_runtime_workers_rpc(null,100),
    'execution_receipts',public.get_platform_dispatch_receipts_rpc(null,null,100),
    'dead_letters',public.get_platform_dispatch_dead_letters_rpc(null,100),
    'feature_flags',public.get_platform_feature_flags_rpc(null,false),
    'runtime_policies',public.get_platform_runtime_policies_rpc(null,false),
    'capabilities',public.get_platform_capabilities_rpc(null,false)
  );
$function$;

revoke all on function public.get_platform_governance_snapshot_rpc() from public, anon;
grant execute on function public.get_platform_governance_snapshot_rpc() to authenticated, service_role;

update public.platform_configuration
set schema_version = greatest(schema_version,82),
    metadata = metadata || jsonb_build_object(
      'phase','8.3.3',
      'governance_contract','platform-governance-v1.3',
      'platform_orchestrator_contract','platform-orchestrator-v1.2',
      'platform_runtime_dispatcher_migration',82
    ),
    updated_at = now()
where configuration_key = 'primary';

-- --------------------------------------------------------------------------
-- 17. Migration assertions (non-destructive, no synthetic queue actions)
-- --------------------------------------------------------------------------

do $assertions$
declare
  v_missing integer;
  v_snapshot jsonb;
  v_health jsonb;
  v_retry timestamptz;
begin
  select count(*) into v_missing
  from (values
    ('platform_runtime_workers'),
    ('platform_dispatch_batches'),
    ('platform_action_execution_attempts'),
    ('platform_action_execution_receipts'),
    ('platform_orchestrator_dead_letters')
  ) as required_table(name)
  where to_regclass('public.' || name) is null;

  if v_missing <> 0 then
    raise exception 'PLATFORM_RUNTIME_DISPATCHER_ASSERTION_FAILED: missing tables %', v_missing;
  end if;

  select count(*) into v_missing
  from (values
    ('register_platform_runtime_worker_rpc'),
    ('heartbeat_platform_runtime_worker_rpc'),
    ('reclaim_platform_dispatch_leases_rpc'),
    ('dispatch_platform_orchestrator_actions_rpc'),
    ('start_platform_orchestrator_action_rpc'),
    ('complete_platform_runtime_execution_rpc'),
    ('get_platform_dispatcher_health_rpc')
  ) as required_function(name)
  where not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = required_function.name
  );

  if v_missing <> 0 then
    raise exception 'PLATFORM_RUNTIME_DISPATCHER_ASSERTION_FAILED: missing functions %', v_missing;
  end if;

  v_retry := public.calculate_platform_dispatch_retry_at(1,'2026-01-01 00:00:00+00'::timestamptz);
  if v_retry <> '2026-01-01 00:00:30+00'::timestamptz then
    raise exception 'PLATFORM_RUNTIME_DISPATCHER_ASSERTION_FAILED: retry contract invalid %', v_retry;
  end if;

  v_health := public.get_platform_dispatcher_health_rpc();
  if (v_health ->> 'contract_version') <> 'platform-runtime-dispatcher-health-v1'
     or not (v_health ? 'workers') or not (v_health ? 'queue')
     or not (v_health ? 'receipts') or not (v_health ? 'dead_letters') then
    raise exception 'PLATFORM_RUNTIME_DISPATCHER_ASSERTION_FAILED: health contract invalid';
  end if;

  v_snapshot := public.get_platform_governance_snapshot_rpc();
  if (v_snapshot ->> 'contract_version') <> 'platform-governance-v1.3'
     or not (v_snapshot ? 'dispatcher_health')
     or not (v_snapshot ? 'runtime_workers')
     or not (v_snapshot ? 'execution_receipts')
     or not (v_snapshot ? 'dead_letters') then
    raise exception 'PLATFORM_RUNTIME_DISPATCHER_ASSERTION_FAILED: governance snapshot invalid';
  end if;

  if not exists (
    select 1 from public.platform_engine_registry
    where engine_code = 'platform_orchestrator_engine'
      and engine_version = '1.2.0'
      and certification_version = '1.2.0'
      and runtime_enabled and is_certified
  ) then
    raise exception 'PLATFORM_RUNTIME_DISPATCHER_ASSERTION_FAILED: orchestrator certification invalid';
  end if;
end;
$assertions$;

commit;
