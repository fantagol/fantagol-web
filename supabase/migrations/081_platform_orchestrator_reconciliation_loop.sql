-- ============================================================================
-- FANTAGOL
-- Migration 081: Platform Orchestrator Reconciliation Loop
-- Phase 8.3.2
--
-- Purpose
--   Add the durable planning loop that compares desired and observed engine
--   state, serializes reconciliation cycles through a lease, emits immutable
--   action plans, and exposes service-only claim/completion commands.
--
-- Safety
--   This migration never starts, stops, restarts, or disables an external
--   process. It plans and tracks runtime actions; execution remains delegated
--   to the certified worker/runtime layer.
-- ============================================================================

begin;

-- --------------------------------------------------------------------------
-- 1. Reconciliation cycles
-- --------------------------------------------------------------------------

create table if not exists public.platform_orchestrator_cycles (
  cycle_id uuid primary key default gen_random_uuid(),
  cycle_sequence bigint generated always as identity unique,
  cycle_status text not null default 'running',
  trigger_type text not null default 'scheduled',
  requested_by text not null,
  dry_run boolean not null default false,
  correlation_id uuid not null default gen_random_uuid(),
  lease_owner text not null,
  lease_token uuid not null,
  lease_expires_at timestamptz not null,
  engine_count integer not null default 0,
  actionable_engine_count integer not null default 0,
  planned_action_count integer not null default 0,
  blocked_engine_count integer not null default 0,
  error_count integer not null default 0,
  summary jsonb not null default '{}'::jsonb,
  started_at timestamptz not null default now(),
  completed_at timestamptz,
  created_at timestamptz not null default now(),

  constraint platform_orchestrator_cycles_status_ck
    check (cycle_status in ('running','completed','completed_with_blocks','failed','abandoned')),
  constraint platform_orchestrator_cycles_trigger_ck
    check (trigger_type in ('scheduled','manual','startup','recovery','maintenance','test')),
  constraint platform_orchestrator_cycles_counts_ck
    check (
      engine_count >= 0 and actionable_engine_count >= 0 and
      planned_action_count >= 0 and blocked_engine_count >= 0 and error_count >= 0
    ),
  constraint platform_orchestrator_cycles_summary_ck
    check (jsonb_typeof(summary) = 'object'),
  constraint platform_orchestrator_cycles_completion_ck
    check (
      (cycle_status = 'running' and completed_at is null) or
      (cycle_status <> 'running' and completed_at is not null)
    )
);

create index if not exists platform_orchestrator_cycles_timeline_idx
  on public.platform_orchestrator_cycles (started_at desc);

create index if not exists platform_orchestrator_cycles_status_idx
  on public.platform_orchestrator_cycles (cycle_status, started_at desc);

comment on table public.platform_orchestrator_cycles is
  'Durable executions of the Platform Orchestrator desired/observed reconciliation planner.';

-- --------------------------------------------------------------------------
-- 2. Singleton reconciliation lease
-- --------------------------------------------------------------------------

create table if not exists public.platform_orchestrator_leases (
  lease_key text primary key,
  lease_owner text,
  lease_token uuid,
  acquired_at timestamptz,
  expires_at timestamptz,
  heartbeat_at timestamptz,
  generation bigint not null default 0,
  metadata jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),

  constraint platform_orchestrator_leases_key_ck
    check (lease_key = 'reconciliation_loop'),
  constraint platform_orchestrator_leases_generation_ck
    check (generation >= 0),
  constraint platform_orchestrator_leases_metadata_ck
    check (jsonb_typeof(metadata) = 'object'),
  constraint platform_orchestrator_leases_shape_ck
    check (
      (lease_owner is null and lease_token is null and acquired_at is null and expires_at is null)
      or
      (lease_owner is not null and lease_token is not null and acquired_at is not null and expires_at is not null)
    )
);

insert into public.platform_orchestrator_leases (lease_key)
values ('reconciliation_loop')
on conflict (lease_key) do nothing;

comment on table public.platform_orchestrator_leases is
  'Singleton lease preventing overlapping Platform Orchestrator reconciliation planners.';

-- --------------------------------------------------------------------------
-- 3. Immutable reconciliation action plans
-- --------------------------------------------------------------------------

create table if not exists public.platform_orchestrator_actions (
  action_id uuid primary key default gen_random_uuid(),
  cycle_id uuid not null,
  engine_code text not null,
  action_sequence integer not null,
  action_type text not null,
  action_status text not null default 'pending',
  priority integer not null default 100,
  desired_status text not null,
  observed_status text not null,
  target_generation bigint not null,
  readiness_status text not null,
  blocking_reasons jsonb not null default '[]'::jsonb,
  payload jsonb not null default '{}'::jsonb,
  idempotency_key text not null unique,
  correlation_id uuid not null,
  causation_id uuid,
  claimed_by text,
  claim_token uuid,
  claimed_at timestamptz,
  claim_expires_at timestamptz,
  attempt_count integer not null default 0,
  last_error text,
  execution_result jsonb,
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint platform_orchestrator_actions_cycle_fk
    foreign key (cycle_id)
    references public.platform_orchestrator_cycles(cycle_id)
    on delete cascade,
  constraint platform_orchestrator_actions_engine_fk
    foreign key (engine_code)
    references public.platform_engine_registry(engine_code)
    on update cascade
    on delete restrict,
  constraint platform_orchestrator_actions_cycle_sequence_uq
    unique (cycle_id, action_sequence),
  constraint platform_orchestrator_actions_cycle_engine_uq
    unique (cycle_id, engine_code),
  constraint platform_orchestrator_actions_type_ck
    check (action_type in (
      'start','stop','enter_maintenance','exit_maintenance','disable',
      'recover','refresh_observation'
    )),
  constraint platform_orchestrator_actions_status_ck
    check (action_status in ('pending','claimed','succeeded','failed','cancelled','expired')),
  constraint platform_orchestrator_actions_priority_ck
    check (priority between 1 and 1000),
  constraint platform_orchestrator_actions_generation_ck
    check (target_generation > 0),
  constraint platform_orchestrator_actions_attempt_ck
    check (attempt_count >= 0),
  constraint platform_orchestrator_actions_blockers_ck
    check (jsonb_typeof(blocking_reasons) = 'array'),
  constraint platform_orchestrator_actions_payload_ck
    check (jsonb_typeof(payload) = 'object'),
  constraint platform_orchestrator_actions_result_ck
    check (execution_result is null or jsonb_typeof(execution_result) = 'object'),
  constraint platform_orchestrator_actions_claim_ck
    check (
      (action_status <> 'claimed') or
      (claimed_by is not null and claim_token is not null and claimed_at is not null and claim_expires_at is not null)
    ),
  constraint platform_orchestrator_actions_completion_ck
    check (
      (action_status in ('succeeded','failed','cancelled','expired') and completed_at is not null)
      or
      (action_status in ('pending','claimed') and completed_at is null)
    )
);

create index if not exists platform_orchestrator_actions_dispatch_idx
  on public.platform_orchestrator_actions (action_status, priority, created_at);

create index if not exists platform_orchestrator_actions_engine_idx
  on public.platform_orchestrator_actions (engine_code, created_at desc);

comment on table public.platform_orchestrator_actions is
  'Durable execution plans emitted by reconciliation cycles and completed by the runtime worker.';

-- --------------------------------------------------------------------------
-- 4. Timestamps and immutability boundaries
-- --------------------------------------------------------------------------

drop trigger if exists trg_platform_orchestrator_leases_updated_at
  on public.platform_orchestrator_leases;
create trigger trg_platform_orchestrator_leases_updated_at
before update on public.platform_orchestrator_leases
for each row execute function public.set_platform_governance_updated_at();

drop trigger if exists trg_platform_orchestrator_actions_updated_at
  on public.platform_orchestrator_actions;
create trigger trg_platform_orchestrator_actions_updated_at
before update on public.platform_orchestrator_actions
for each row execute function public.set_platform_governance_updated_at();

create or replace function public.protect_platform_orchestrator_cycle_identity()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $function$
begin
  if new.cycle_id <> old.cycle_id
     or new.cycle_sequence <> old.cycle_sequence
     or new.correlation_id <> old.correlation_id
     or new.started_at <> old.started_at
     or new.created_at <> old.created_at then
    raise exception 'PLATFORM_ORCHESTRATOR_CYCLE_IDENTITY_IMMUTABLE';
  end if;
  return new;
end;
$function$;

drop trigger if exists trg_protect_platform_orchestrator_cycle_identity
  on public.platform_orchestrator_cycles;
create trigger trg_protect_platform_orchestrator_cycle_identity
before update on public.platform_orchestrator_cycles
for each row execute function public.protect_platform_orchestrator_cycle_identity();

create or replace function public.protect_platform_orchestrator_action_identity()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $function$
begin
  if new.action_id <> old.action_id
     or new.cycle_id <> old.cycle_id
     or new.engine_code <> old.engine_code
     or new.action_sequence <> old.action_sequence
     or new.action_type <> old.action_type
     or new.desired_status <> old.desired_status
     or new.observed_status <> old.observed_status
     or new.target_generation <> old.target_generation
     or new.idempotency_key <> old.idempotency_key
     or new.correlation_id <> old.correlation_id
     or new.created_at <> old.created_at then
    raise exception 'PLATFORM_ORCHESTRATOR_ACTION_IDENTITY_IMMUTABLE';
  end if;
  return new;
end;
$function$;

drop trigger if exists trg_protect_platform_orchestrator_action_identity
  on public.platform_orchestrator_actions;
create trigger trg_protect_platform_orchestrator_action_identity
before update on public.platform_orchestrator_actions
for each row execute function public.protect_platform_orchestrator_action_identity();

-- --------------------------------------------------------------------------
-- 5. Deterministic action classifier
-- --------------------------------------------------------------------------

create or replace function public.classify_platform_reconciliation_action_rpc(
  p_engine_code text,
  p_now timestamptz default now()
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $function$
declare
  v_state public.platform_engine_runtime_states%rowtype;
  v_readiness jsonb;
  v_action_type text;
  v_priority integer;
  v_reason text;
  v_stale boolean := false;
  v_stale_after interval := interval '10 minutes';
begin
  select * into v_state
  from public.platform_engine_runtime_states
  where engine_code = p_engine_code;

  if not found then
    raise exception 'PLATFORM_ORCHESTRATOR_ENGINE_STATE_NOT_FOUND: %', p_engine_code;
  end if;

  v_readiness := public.evaluate_platform_engine_readiness_rpc(p_engine_code);
  v_stale := v_state.desired_status = 'running'
    and v_state.last_heartbeat_at is not null
    and v_state.last_heartbeat_at < p_now - v_stale_after;

  if v_state.desired_status = 'disabled' and v_state.observed_status <> 'disabled' then
    v_action_type := 'disable'; v_priority := 10; v_reason := 'desired_disabled';
  elsif v_state.desired_status = 'stopped' and v_state.observed_status <> 'stopped' then
    v_action_type := 'stop'; v_priority := 20; v_reason := 'desired_stopped';
  elsif v_state.desired_status = 'maintenance' and v_state.observed_status <> 'maintenance' then
    v_action_type := 'enter_maintenance'; v_priority := 30; v_reason := 'desired_maintenance';
  elsif v_state.desired_status = 'running'
        and v_state.observed_status = 'maintenance' then
    v_action_type := 'exit_maintenance'; v_priority := 40; v_reason := 'desired_running_from_maintenance';
  elsif v_state.desired_status = 'running'
        and v_state.observed_status in ('failed','degraded','recovering') then
    v_action_type := 'recover'; v_priority := 50; v_reason := 'runtime_unhealthy';
  elsif v_state.desired_status = 'running'
        and v_state.observed_status in ('unknown','stopped','stopping') then
    v_action_type := 'start'; v_priority := 60; v_reason := 'desired_running';
  elsif v_state.generation <> v_state.observed_generation then
    v_action_type := 'refresh_observation'; v_priority := 70; v_reason := 'generation_not_reconciled';
  elsif v_stale then
    v_action_type := 'refresh_observation'; v_priority := 80; v_reason := 'heartbeat_stale';
  else
    v_action_type := null; v_priority := null; v_reason := 'converged';
  end if;

  return jsonb_build_object(
    'contract_version','platform-reconciliation-classifier-v1',
    'engine_code',p_engine_code,
    'action_required',v_action_type is not null,
    'action_type',v_action_type,
    'priority',v_priority,
    'reason',v_reason,
    'desired_status',v_state.desired_status,
    'observed_status',v_state.observed_status,
    'generation',v_state.generation,
    'observed_generation',v_state.observed_generation,
    'readiness_status',v_state.readiness_status,
    'heartbeat_stale',v_stale,
    'readiness',v_readiness,
    'evaluated_at',p_now
  );
end;
$function$;

-- --------------------------------------------------------------------------
-- 6. Run one serialized reconciliation planning cycle
-- --------------------------------------------------------------------------

create or replace function public.run_platform_orchestrator_cycle_rpc(
  p_lease_owner text,
  p_trigger_type text default 'scheduled',
  p_lease_seconds integer default 120,
  p_dry_run boolean default false,
  p_correlation_id uuid default gen_random_uuid()
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $function$
declare
  v_now timestamptz := now();
  v_token uuid := gen_random_uuid();
  v_lease public.platform_orchestrator_leases%rowtype;
  v_cycle public.platform_orchestrator_cycles%rowtype;
  v_state record;
  v_classification jsonb;
  v_action_type text;
  v_action_count integer := 0;
  v_blocked_count integer := 0;
  v_engine_count integer := 0;
  v_action_sequence integer := 0;
  v_status text;
  v_actions jsonb := '[]'::jsonb;
begin
  if nullif(btrim(p_lease_owner),'') is null then
    raise exception 'PLATFORM_ORCHESTRATOR_LEASE_OWNER_REQUIRED';
  end if;
  if p_trigger_type not in ('scheduled','manual','startup','recovery','maintenance','test') then
    raise exception 'PLATFORM_ORCHESTRATOR_INVALID_TRIGGER_TYPE: %', p_trigger_type;
  end if;
  if p_lease_seconds < 15 or p_lease_seconds > 900 then
    raise exception 'PLATFORM_ORCHESTRATOR_INVALID_LEASE_SECONDS: %', p_lease_seconds;
  end if;

  select * into v_lease
  from public.platform_orchestrator_leases
  where lease_key = 'reconciliation_loop'
  for update;

  if v_lease.lease_owner is not null
     and v_lease.expires_at > v_now
     and v_lease.lease_owner <> p_lease_owner then
    return jsonb_build_object(
      'contract_version','platform-orchestrator-cycle-v1',
      'acquired',false,
      'reason','lease_held',
      'lease_owner',v_lease.lease_owner,
      'lease_expires_at',v_lease.expires_at
    );
  end if;

  update public.platform_orchestrator_leases
  set lease_owner = p_lease_owner,
      lease_token = v_token,
      acquired_at = v_now,
      expires_at = v_now + make_interval(secs => p_lease_seconds),
      heartbeat_at = v_now,
      generation = generation + 1,
      metadata = metadata || jsonb_build_object('trigger_type',p_trigger_type,'dry_run',p_dry_run)
  where lease_key = 'reconciliation_loop'
  returning * into v_lease;

  insert into public.platform_orchestrator_cycles (
    cycle_status,trigger_type,requested_by,dry_run,correlation_id,
    lease_owner,lease_token,lease_expires_at
  ) values (
    'running',p_trigger_type,p_lease_owner,p_dry_run,p_correlation_id,
    p_lease_owner,v_token,v_lease.expires_at
  ) returning * into v_cycle;

  for v_state in
    select s.*, r.installation_order
    from public.platform_engine_runtime_states s
    join public.platform_engine_registry r using (engine_code)
    order by r.installation_order
  loop
    v_engine_count := v_engine_count + 1;
    v_classification := public.classify_platform_reconciliation_action_rpc(v_state.engine_code,v_now);
    v_action_type := v_classification ->> 'action_type';

    if coalesce((v_classification ->> 'action_required')::boolean,false) then
      v_action_count := v_action_count + 1;
      v_action_sequence := v_action_sequence + 1;

      if jsonb_array_length(v_classification -> 'readiness' -> 'blockers') > 0
         and v_action_type in ('start','exit_maintenance') then
        v_blocked_count := v_blocked_count + 1;
      end if;

      if not p_dry_run then
        insert into public.platform_orchestrator_actions (
          cycle_id,engine_code,action_sequence,action_type,action_status,priority,
          desired_status,observed_status,target_generation,readiness_status,
          blocking_reasons,payload,idempotency_key,correlation_id
        ) values (
          v_cycle.cycle_id,
          v_state.engine_code,
          v_action_sequence,
          v_action_type,
          'pending',
          (v_classification ->> 'priority')::integer,
          v_state.desired_status,
          v_state.observed_status,
          v_state.generation,
          v_state.readiness_status,
          coalesce(v_classification -> 'readiness' -> 'blockers','[]'::jsonb),
          jsonb_build_object(
            'classifier',v_classification,
            'platform_contract','platform-orchestrator-v1.1'
          ),
          format('orchestrator:%s:%s:%s:%s',v_state.engine_code,v_state.generation,v_action_type,v_cycle.cycle_id),
          p_correlation_id
        );
      end if;

      v_actions := v_actions || jsonb_build_array(jsonb_build_object(
        'engine_code',v_state.engine_code,
        'action_type',v_action_type,
        'priority',(v_classification ->> 'priority')::integer,
        'reason',v_classification ->> 'reason',
        'persisted',not p_dry_run
      ));
    end if;
  end loop;

  v_status := case when v_blocked_count > 0 then 'completed_with_blocks' else 'completed' end;

  update public.platform_orchestrator_cycles
  set cycle_status = v_status,
      engine_count = v_engine_count,
      actionable_engine_count = v_action_count,
      planned_action_count = case when p_dry_run then 0 else v_action_count end,
      blocked_engine_count = v_blocked_count,
      summary = jsonb_build_object(
        'contract_version','platform-orchestrator-cycle-v1',
        'actions',v_actions,
        'dry_run',p_dry_run
      ),
      completed_at = now()
  where cycle_id = v_cycle.cycle_id
  returning * into v_cycle;

  update public.platform_orchestrator_leases
  set lease_owner = null,
      lease_token = null,
      acquired_at = null,
      expires_at = null,
      heartbeat_at = now(),
      metadata = metadata || jsonb_build_object('last_cycle_id',v_cycle.cycle_id,'last_cycle_status',v_status)
  where lease_key = 'reconciliation_loop'
    and lease_token = v_token;

  return jsonb_build_object(
    'contract_version','platform-orchestrator-cycle-v1',
    'acquired',true,
    'cycle_id',v_cycle.cycle_id,
    'cycle_sequence',v_cycle.cycle_sequence,
    'cycle_status',v_cycle.cycle_status,
    'engine_count',v_engine_count,
    'actionable_engine_count',v_action_count,
    'planned_action_count',case when p_dry_run then 0 else v_action_count end,
    'blocked_engine_count',v_blocked_count,
    'dry_run',p_dry_run,
    'actions',v_actions
  );
exception when others then
  if v_cycle.cycle_id is not null then
    update public.platform_orchestrator_cycles
    set cycle_status = 'failed',
        error_count = error_count + 1,
        summary = summary || jsonb_build_object('error',sqlerrm),
        completed_at = now()
    where cycle_id = v_cycle.cycle_id;
  end if;

  update public.platform_orchestrator_leases
  set lease_owner = null, lease_token = null, acquired_at = null, expires_at = null,
      heartbeat_at = now(), metadata = metadata || jsonb_build_object('last_error',sqlerrm)
  where lease_key = 'reconciliation_loop'
    and lease_token = v_token;
  raise;
end;
$function$;

-- --------------------------------------------------------------------------
-- 7. Runtime worker claim and completion commands
-- --------------------------------------------------------------------------

create or replace function public.claim_platform_orchestrator_action_rpc(
  p_worker_id text,
  p_claim_seconds integer default 120
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $function$
declare
  v_action public.platform_orchestrator_actions%rowtype;
  v_token uuid := gen_random_uuid();
begin
  if nullif(btrim(p_worker_id),'') is null then
    raise exception 'PLATFORM_ORCHESTRATOR_WORKER_ID_REQUIRED';
  end if;
  if p_claim_seconds < 15 or p_claim_seconds > 900 then
    raise exception 'PLATFORM_ORCHESTRATOR_INVALID_CLAIM_SECONDS: %', p_claim_seconds;
  end if;

  update public.platform_orchestrator_actions
  set action_status = 'expired',
      completed_at = now(),
      last_error = coalesce(last_error,'claim expired before completion')
  where action_status = 'claimed'
    and claim_expires_at <= now();

  select * into v_action
  from public.platform_orchestrator_actions
  where action_status = 'pending'
  order by priority asc, created_at asc
  for update skip locked
  limit 1;

  if not found then
    return jsonb_build_object(
      'contract_version','platform-orchestrator-action-claim-v1',
      'claimed',false,
      'reason','no_pending_action'
    );
  end if;

  update public.platform_orchestrator_actions
  set action_status = 'claimed',
      claimed_by = p_worker_id,
      claim_token = v_token,
      claimed_at = now(),
      claim_expires_at = now() + make_interval(secs => p_claim_seconds),
      attempt_count = attempt_count + 1
  where action_id = v_action.action_id
  returning * into v_action;

  return jsonb_build_object(
    'contract_version','platform-orchestrator-action-claim-v1',
    'claimed',true,
    'claim_token',v_token,
    'action',to_jsonb(v_action)
  );
end;
$function$;

create or replace function public.complete_platform_orchestrator_action_rpc(
  p_action_id uuid,
  p_claim_token uuid,
  p_outcome text,
  p_result jsonb default '{}'::jsonb,
  p_error text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $function$
declare
  v_action public.platform_orchestrator_actions%rowtype;
begin
  if p_outcome not in ('succeeded','failed','cancelled') then
    raise exception 'PLATFORM_ORCHESTRATOR_INVALID_ACTION_OUTCOME: %', p_outcome;
  end if;
  if p_result is null or jsonb_typeof(p_result) <> 'object' then
    raise exception 'PLATFORM_ORCHESTRATOR_RESULT_MUST_BE_OBJECT';
  end if;

  select * into v_action
  from public.platform_orchestrator_actions
  where action_id = p_action_id
  for update;

  if not found then
    raise exception 'PLATFORM_ORCHESTRATOR_ACTION_NOT_FOUND: %', p_action_id;
  end if;
  if v_action.action_status <> 'claimed' then
    raise exception 'PLATFORM_ORCHESTRATOR_ACTION_NOT_CLAIMED: %', v_action.action_status;
  end if;
  if v_action.claim_token <> p_claim_token then
    raise exception 'PLATFORM_ORCHESTRATOR_CLAIM_TOKEN_MISMATCH';
  end if;
  if v_action.claim_expires_at <= now() then
    raise exception 'PLATFORM_ORCHESTRATOR_CLAIM_EXPIRED';
  end if;

  update public.platform_orchestrator_actions
  set action_status = p_outcome,
      execution_result = p_result,
      last_error = p_error,
      completed_at = now()
  where action_id = p_action_id
  returning * into v_action;

  return jsonb_build_object(
    'contract_version','platform-orchestrator-action-completion-v1',
    'completed',true,
    'action',to_jsonb(v_action)
  );
end;
$function$;

-- --------------------------------------------------------------------------
-- 8. Read models
-- --------------------------------------------------------------------------

create or replace function public.get_platform_orchestrator_cycles_rpc(
  p_limit integer default 50
)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $function$
  select coalesce(jsonb_agg(to_jsonb(c) order by c.started_at desc),'[]'::jsonb)
  from (
    select * from public.platform_orchestrator_cycles
    order by started_at desc
    limit greatest(1,least(coalesce(p_limit,50),200))
  ) c;
$function$;

create or replace function public.get_platform_orchestrator_actions_rpc(
  p_cycle_id uuid default null,
  p_engine_code text default null,
  p_status text default null,
  p_limit integer default 100
)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $function$
  select coalesce(jsonb_agg(to_jsonb(a) order by a.created_at desc),'[]'::jsonb)
  from (
    select *
    from public.platform_orchestrator_actions
    where (p_cycle_id is null or cycle_id = p_cycle_id)
      and (p_engine_code is null or engine_code = p_engine_code)
      and (p_status is null or action_status = p_status)
    order by created_at desc
    limit greatest(1,least(coalesce(p_limit,100),500))
  ) a;
$function$;

-- --------------------------------------------------------------------------
-- 9. Security
-- --------------------------------------------------------------------------

alter table public.platform_orchestrator_cycles enable row level security;
alter table public.platform_orchestrator_leases enable row level security;
alter table public.platform_orchestrator_actions enable row level security;

revoke all on table public.platform_orchestrator_cycles from anon, authenticated;
revoke all on table public.platform_orchestrator_leases from anon, authenticated;
revoke all on table public.platform_orchestrator_actions from anon, authenticated;

grant select, insert, update on table public.platform_orchestrator_cycles to service_role;
grant select, insert, update on table public.platform_orchestrator_leases to service_role;
grant select, insert, update on table public.platform_orchestrator_actions to service_role;

drop policy if exists platform_orchestrator_cycles_service_all on public.platform_orchestrator_cycles;
create policy platform_orchestrator_cycles_service_all
  on public.platform_orchestrator_cycles for all to service_role using (true) with check (true);

drop policy if exists platform_orchestrator_leases_service_all on public.platform_orchestrator_leases;
create policy platform_orchestrator_leases_service_all
  on public.platform_orchestrator_leases for all to service_role using (true) with check (true);

drop policy if exists platform_orchestrator_actions_service_all on public.platform_orchestrator_actions;
create policy platform_orchestrator_actions_service_all
  on public.platform_orchestrator_actions for all to service_role using (true) with check (true);

revoke all on function public.protect_platform_orchestrator_cycle_identity() from public, anon, authenticated;
revoke all on function public.protect_platform_orchestrator_action_identity() from public, anon, authenticated;
revoke all on function public.classify_platform_reconciliation_action_rpc(text,timestamptz) from public, anon;
revoke all on function public.run_platform_orchestrator_cycle_rpc(text,text,integer,boolean,uuid) from public, anon, authenticated;
revoke all on function public.claim_platform_orchestrator_action_rpc(text,integer) from public, anon, authenticated;
revoke all on function public.complete_platform_orchestrator_action_rpc(uuid,uuid,text,jsonb,text) from public, anon, authenticated;
revoke all on function public.get_platform_orchestrator_cycles_rpc(integer) from public, anon;
revoke all on function public.get_platform_orchestrator_actions_rpc(uuid,text,text,integer) from public, anon;

grant execute on function public.classify_platform_reconciliation_action_rpc(text,timestamptz) to authenticated, service_role;
grant execute on function public.get_platform_orchestrator_cycles_rpc(integer) to authenticated, service_role;
grant execute on function public.get_platform_orchestrator_actions_rpc(uuid,text,text,integer) to authenticated, service_role;
grant execute on function public.run_platform_orchestrator_cycle_rpc(text,text,integer,boolean,uuid) to service_role;
grant execute on function public.claim_platform_orchestrator_action_rpc(text,integer) to service_role;
grant execute on function public.complete_platform_orchestrator_action_rpc(uuid,uuid,text,jsonb,text) to service_role;

-- --------------------------------------------------------------------------
-- 10. Policies, feature metadata and governance snapshot v1.2
-- --------------------------------------------------------------------------

insert into public.platform_runtime_policies (
  policy_key,policy_name,description,policy_type,policy_value,
  validation_contract,owner_engine_code,enforcement_level,enabled,metadata
)
values
  ('runtime.orchestrator.reconciliation_interval','Orchestrator reconciliation interval','Target cadence for the runtime reconciliation scheduler.','duration','"PT1M"'::jsonb,'{"format":"ISO-8601-duration"}'::jsonb,'platform_orchestrator_engine','required',true,'{"migration":81}'::jsonb),
  ('runtime.orchestrator.reconciliation_lease','Orchestrator reconciliation lease','Maximum lease duration for one planning cycle.','duration','"PT2M"'::jsonb,'{"format":"ISO-8601-duration"}'::jsonb,'platform_orchestrator_engine','critical',true,'{"migration":81}'::jsonb),
  ('runtime.orchestrator.action_claim_lease','Orchestrator action claim lease','Maximum worker lease for one action attempt.','duration','"PT2M"'::jsonb,'{"format":"ISO-8601-duration"}'::jsonb,'platform_orchestrator_engine','critical',true,'{"migration":81}'::jsonb)
on conflict (policy_key) do update
set policy_value = excluded.policy_value,
    owner_engine_code = excluded.owner_engine_code,
    enforcement_level = excluded.enforcement_level,
    enabled = excluded.enabled,
    metadata = public.platform_runtime_policies.metadata || excluded.metadata;

update public.platform_feature_flags
set description = 'Expose persistent state, serialized reconciliation planning and durable runtime action dispatch.',
    metadata = metadata || jsonb_build_object(
      'contract','platform-orchestrator-v1.1',
      'reconciliation_loop_migration',81
    )
where feature_key = 'runtime.platform_orchestrator';

update public.platform_engine_registry
set engine_version = '1.1.0',
    certification_version = '1.1.0',
    metadata = metadata || jsonb_build_object(
      'phase','8.3.2',
      'contract','platform-orchestrator-v1.1',
      'reconciliation_loop_migration',81,
      'execution_mode','durable-plan-and-dispatch'
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
    'contract_version','platform-governance-v1.2',
    'generated_at',now(),
    'configuration',public.get_platform_configuration_rpc(),
    'engines',public.get_platform_engine_registry_rpc(false),
    'dependencies',public.get_platform_engine_dependencies_rpc(null,false),
    'dependency_validation',public.validate_platform_dependency_graph_rpc(null),
    'runtime_states',public.get_platform_engine_runtime_states_rpc(null),
    'orchestrator_cycles',public.get_platform_orchestrator_cycles_rpc(20),
    'orchestrator_actions',public.get_platform_orchestrator_actions_rpc(null,null,null,100),
    'feature_flags',public.get_platform_feature_flags_rpc(null,false),
    'runtime_policies',public.get_platform_runtime_policies_rpc(null,false),
    'capabilities',public.get_platform_capabilities_rpc(null,false)
  );
$function$;

revoke all on function public.get_platform_governance_snapshot_rpc() from public, anon;
grant execute on function public.get_platform_governance_snapshot_rpc() to authenticated, service_role;

-- --------------------------------------------------------------------------
-- 11. Metadata progression and assertions
-- --------------------------------------------------------------------------

update public.platform_configuration
set schema_version = greatest(schema_version,81),
    metadata = metadata || jsonb_build_object(
      'phase','8.3.2',
      'platform_orchestrator_reconciliation_migration',81,
      'platform_orchestrator_contract','platform-orchestrator-v1.1',
      'governance_contract','platform-governance-v1.2'
    )
where configuration_key = 'primary';

do $assertions$
declare
  v_cycle jsonb;
  v_cycle_count integer;
  v_action_count integer;
  v_lease_count integer;
  v_snapshot jsonb;
  v_classifier jsonb;
begin
  select count(*) into v_lease_count
  from public.platform_orchestrator_leases
  where lease_key = 'reconciliation_loop';

  if v_lease_count <> 1 then
    raise exception 'PLATFORM_ORCHESTRATOR_RECONCILIATION_ASSERTION_FAILED: singleton lease missing';
  end if;

  v_classifier := public.classify_platform_reconciliation_action_rpc('platform_orchestrator_engine',now());
  if (v_classifier ->> 'contract_version') <> 'platform-reconciliation-classifier-v1'
     or (v_classifier ->> 'engine_code') <> 'platform_orchestrator_engine' then
    raise exception 'PLATFORM_ORCHESTRATOR_RECONCILIATION_ASSERTION_FAILED: classifier contract invalid: %', v_classifier;
  end if;

  v_cycle := public.run_platform_orchestrator_cycle_rpc(
    'migration-081-assertion','test',120,true,gen_random_uuid()
  );

  if not coalesce((v_cycle ->> 'acquired')::boolean,false)
     or (v_cycle ->> 'cycle_status') not in ('completed','completed_with_blocks')
     or (v_cycle ->> 'engine_count')::integer <> 11
     or (v_cycle ->> 'planned_action_count')::integer <> 0
     or not coalesce((v_cycle ->> 'dry_run')::boolean,false) then
    raise exception 'PLATFORM_ORCHESTRATOR_RECONCILIATION_ASSERTION_FAILED: baseline dry-run cycle invalid: %', v_cycle;
  end if;

  select count(*) into v_cycle_count from public.platform_orchestrator_cycles;
  select count(*) into v_action_count from public.platform_orchestrator_actions;
  if v_cycle_count < 1 or v_action_count <> 0 then
    raise exception 'PLATFORM_ORCHESTRATOR_RECONCILIATION_ASSERTION_FAILED: baseline persistence invalid';
  end if;

  v_snapshot := public.get_platform_governance_snapshot_rpc();
  if (v_snapshot ->> 'contract_version') <> 'platform-governance-v1.2'
     or not (v_snapshot ? 'orchestrator_cycles')
     or not (v_snapshot ? 'orchestrator_actions') then
    raise exception 'PLATFORM_ORCHESTRATOR_RECONCILIATION_ASSERTION_FAILED: snapshot contract invalid';
  end if;
end;
$assertions$;

commit;
