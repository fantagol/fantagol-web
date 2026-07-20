-- ============================================================================
-- FANTAGOL
-- Migration 080: Platform Orchestrator Runtime State Foundation
-- Phase 8.3.1
--
-- Purpose
--   Introduce the persistent control-loop foundation for platform engine
--   orchestration: desired/observed runtime state, readiness evaluation,
--   transition journal and service-only reconciliation commands.
--
-- Safety
--   This migration does not start, stop or restart any process. It records and
--   validates orchestration intent while preserving all certified runtimes.
-- ============================================================================

begin;

-- --------------------------------------------------------------------------
-- 1. Register and certify the governance/orchestrator control-plane engines
-- --------------------------------------------------------------------------

update public.platform_engine_registry
set
  is_certified = true,
  certification_version = coalesce(certification_version, '1.0.0'),
  certified_at = coalesce(certified_at, now()),
  metadata = metadata || jsonb_build_object(
    'certification_basis', 'migrations-077-079',
    'certified_by_migration', 80
  )
where engine_code = 'platform_governance_engine';

insert into public.platform_engine_registry (
  engine_code, engine_name, engine_version, engine_kind,
  lifecycle_status, runtime_enabled, is_certified,
  certification_version, certified_at, owner_scope,
  installation_order, dependencies, metadata
)
values (
  'platform_orchestrator_engine',
  'Platform Orchestrator Engine',
  '1.0.0',
  'orchestration',
  'active',
  true,
  true,
  '1.0.0',
  now(),
  'platform',
  110,
  '["workflow_engine","recovery_engine","maintenance_engine","platform_governance_engine"]'::jsonb,
  jsonb_build_object(
    'contract', 'platform-orchestrator-v1',
    'phase', '8.3.1',
    'foundation_migration', 80,
    'execution_mode', 'control-plane-only'
  )
)
on conflict (engine_code) do update
set
  engine_name = excluded.engine_name,
  engine_version = excluded.engine_version,
  engine_kind = excluded.engine_kind,
  lifecycle_status = excluded.lifecycle_status,
  runtime_enabled = excluded.runtime_enabled,
  is_certified = excluded.is_certified,
  certification_version = excluded.certification_version,
  certified_at = coalesce(public.platform_engine_registry.certified_at, excluded.certified_at),
  installation_order = excluded.installation_order,
  metadata = public.platform_engine_registry.metadata || excluded.metadata;

insert into public.platform_engine_dependencies (
  dependent_engine_code,
  dependency_engine_code,
  dependency_type,
  minimum_version,
  maximum_version_exclusive,
  requires_runtime_enabled,
  requires_certification,
  allowed_dependency_statuses,
  enabled,
  rationale,
  metadata
)
values
  ('platform_orchestrator_engine','workflow_engine','runtime','1.0.0',null,true,true,array['active']::text[],true,'Delegates domain execution to the certified Workflow Engine.','{"phase":"8.3.1"}'::jsonb),
  ('platform_orchestrator_engine','recovery_engine','runtime','1.0.0',null,true,true,array['active']::text[],true,'Delegates recoverable failure handling to the Recovery Engine.','{"phase":"8.3.1"}'::jsonb),
  ('platform_orchestrator_engine','maintenance_engine','runtime','1.0.0',null,true,true,array['active']::text[],true,'Coordinates controlled maintenance state with the Maintenance Engine.','{"phase":"8.3.1"}'::jsonb),
  ('platform_orchestrator_engine','platform_governance_engine','required','1.0.0',null,true,true,array['active']::text[],true,'Consumes canonical registry, policy and dependency contracts.','{"phase":"8.3.1"}'::jsonb)
on conflict (dependent_engine_code, dependency_engine_code) do update
set
  dependency_type = excluded.dependency_type,
  minimum_version = excluded.minimum_version,
  maximum_version_exclusive = excluded.maximum_version_exclusive,
  requires_runtime_enabled = excluded.requires_runtime_enabled,
  requires_certification = excluded.requires_certification,
  allowed_dependency_statuses = excluded.allowed_dependency_statuses,
  enabled = excluded.enabled,
  rationale = excluded.rationale,
  metadata = public.platform_engine_dependencies.metadata || excluded.metadata;

-- --------------------------------------------------------------------------
-- 2. Canonical runtime state aggregate
-- --------------------------------------------------------------------------

create table if not exists public.platform_engine_runtime_states (
  engine_code text primary key,
  desired_status text not null default 'running',
  observed_status text not null default 'unknown',
  readiness_status text not null default 'unknown',
  generation bigint not null default 1,
  observed_generation bigint not null default 0,
  transition_sequence bigint not null default 0,
  last_transition_at timestamptz,
  last_heartbeat_at timestamptz,
  last_ready_at timestamptz,
  status_reason text,
  status_details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint platform_engine_runtime_states_engine_fk
    foreign key (engine_code)
    references public.platform_engine_registry(engine_code)
    on update cascade
    on delete cascade,
  constraint platform_engine_runtime_states_desired_ck
    check (desired_status in ('stopped','running','maintenance','disabled')),
  constraint platform_engine_runtime_states_observed_ck
    check (observed_status in ('unknown','stopped','starting','running','degraded','maintenance','recovering','stopping','failed','disabled')),
  constraint platform_engine_runtime_states_readiness_ck
    check (readiness_status in ('unknown','ready','not_ready','blocked')),
  constraint platform_engine_runtime_states_generation_ck
    check (generation > 0 and observed_generation >= 0 and observed_generation <= generation),
  constraint platform_engine_runtime_states_sequence_ck
    check (transition_sequence >= 0),
  constraint platform_engine_runtime_states_details_ck
    check (jsonb_typeof(status_details) = 'object'),
  constraint platform_engine_runtime_states_ready_ck
    check (readiness_status <> 'ready' or observed_status in ('running','maintenance'))
);

create index if not exists platform_engine_runtime_states_status_idx
  on public.platform_engine_runtime_states (desired_status, observed_status, readiness_status);

create index if not exists platform_engine_runtime_states_heartbeat_idx
  on public.platform_engine_runtime_states (last_heartbeat_at);

comment on table public.platform_engine_runtime_states is
  'Canonical desired/observed runtime state used by the Platform Orchestrator control loop.';

-- --------------------------------------------------------------------------
-- 3. Immutable transition journal
-- --------------------------------------------------------------------------

create table if not exists public.platform_engine_runtime_events (
  event_id uuid primary key default gen_random_uuid(),
  engine_code text not null,
  transition_sequence bigint not null,
  event_type text not null,
  previous_desired_status text,
  desired_status text not null,
  previous_observed_status text,
  observed_status text not null,
  previous_readiness_status text,
  readiness_status text not null,
  generation bigint not null,
  observed_generation bigint not null,
  reason text,
  details jsonb not null default '{}'::jsonb,
  correlation_id uuid,
  causation_id uuid,
  occurred_at timestamptz not null default now(),

  constraint platform_engine_runtime_events_engine_fk
    foreign key (engine_code)
    references public.platform_engine_registry(engine_code)
    on update cascade
    on delete cascade,
  constraint platform_engine_runtime_events_sequence_uq
    unique (engine_code, transition_sequence),
  constraint platform_engine_runtime_events_type_ck
    check (event_type in ('bootstrap','desired_state_requested','observation_reconciled','readiness_evaluated','heartbeat','failure_detected','recovery_started','maintenance_entered','maintenance_exited')),
  constraint platform_engine_runtime_events_details_ck
    check (jsonb_typeof(details) = 'object')
);

create index if not exists platform_engine_runtime_events_timeline_idx
  on public.platform_engine_runtime_events (engine_code, occurred_at desc);

comment on table public.platform_engine_runtime_events is
  'Append-oriented audit journal for Platform Orchestrator state transitions.';

-- --------------------------------------------------------------------------
-- 4. updated_at and immutability guards
-- --------------------------------------------------------------------------

drop trigger if exists trg_platform_engine_runtime_states_updated_at
  on public.platform_engine_runtime_states;
create trigger trg_platform_engine_runtime_states_updated_at
before update on public.platform_engine_runtime_states
for each row execute function public.set_platform_governance_updated_at();

create or replace function public.protect_platform_engine_runtime_event_immutability()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $function$
begin
  raise exception 'PLATFORM_ORCHESTRATOR_EVENT_IMMUTABLE: runtime events cannot be updated or deleted';
end;
$function$;

drop trigger if exists trg_protect_platform_engine_runtime_event_immutability
  on public.platform_engine_runtime_events;
create trigger trg_protect_platform_engine_runtime_event_immutability
before update or delete on public.platform_engine_runtime_events
for each row execute function public.protect_platform_engine_runtime_event_immutability();

-- --------------------------------------------------------------------------
-- 5. Seed one runtime state per registered engine
-- --------------------------------------------------------------------------

insert into public.platform_engine_runtime_states (
  engine_code, desired_status, observed_status, readiness_status,
  generation, observed_generation, transition_sequence,
  last_transition_at, last_heartbeat_at, last_ready_at,
  status_reason, status_details
)
select
  e.engine_code,
  case when e.runtime_enabled then 'running' else 'disabled' end,
  case when e.runtime_enabled and e.lifecycle_status = 'active' then 'running'
       when not e.runtime_enabled then 'disabled'
       when e.lifecycle_status = 'degraded' then 'degraded'
       else 'stopped' end,
  case when e.runtime_enabled and e.lifecycle_status = 'active' and e.is_certified then 'ready'
       else 'not_ready' end,
  1,
  1,
  1,
  now(),
  now(),
  case when e.runtime_enabled and e.lifecycle_status = 'active' and e.is_certified then now() else null end,
  'bootstrap_from_certified_registry',
  jsonb_build_object('migration',80,'source','platform_engine_registry')
from public.platform_engine_registry e
on conflict (engine_code) do nothing;

insert into public.platform_engine_runtime_events (
  engine_code, transition_sequence, event_type,
  desired_status, observed_status, readiness_status,
  generation, observed_generation, reason, details
)
select
  s.engine_code, s.transition_sequence, 'bootstrap',
  s.desired_status, s.observed_status, s.readiness_status,
  s.generation, s.observed_generation,
  s.status_reason, s.status_details
from public.platform_engine_runtime_states s
where not exists (
  select 1 from public.platform_engine_runtime_events ev
  where ev.engine_code = s.engine_code
    and ev.transition_sequence = s.transition_sequence
);

-- --------------------------------------------------------------------------
-- 6. Readiness evaluation
-- --------------------------------------------------------------------------

create or replace function public.evaluate_platform_engine_readiness_rpc(
  p_engine_code text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $function$
declare
  v_engine public.platform_engine_registry%rowtype;
  v_state public.platform_engine_runtime_states%rowtype;
  v_configuration public.platform_configuration%rowtype;
  v_dependencies jsonb;
  v_dependencies_valid boolean;
  v_ready boolean;
  v_blockers jsonb := '[]'::jsonb;
begin
  select * into v_engine
  from public.platform_engine_registry
  where engine_code = p_engine_code;

  if not found then
    raise exception 'PLATFORM_ORCHESTRATOR_ENGINE_NOT_FOUND: %', p_engine_code;
  end if;

  select * into v_state
  from public.platform_engine_runtime_states
  where engine_code = p_engine_code;

  select * into v_configuration
  from public.platform_configuration
  where configuration_key = 'primary';

  v_dependencies := public.validate_platform_dependency_graph_rpc(p_engine_code);
  v_dependencies_valid := coalesce((v_dependencies ->> 'is_valid')::boolean, false);

  if v_engine.lifecycle_status <> 'active' then
    v_blockers := v_blockers || jsonb_build_array(jsonb_build_object('code','engine_not_active','actual',v_engine.lifecycle_status));
  end if;
  if not v_engine.runtime_enabled then
    v_blockers := v_blockers || jsonb_build_array(jsonb_build_object('code','runtime_disabled'));
  end if;
  if not v_engine.is_certified then
    v_blockers := v_blockers || jsonb_build_array(jsonb_build_object('code','engine_not_certified'));
  end if;
  if not v_dependencies_valid then
    v_blockers := v_blockers || jsonb_build_array(jsonb_build_object('code','dependencies_unsatisfied','validation',v_dependencies));
  end if;
  if v_state.desired_status = 'disabled' then
    v_blockers := v_blockers || jsonb_build_array(jsonb_build_object('code','desired_disabled'));
  end if;
  if v_configuration.maintenance_mode and v_state.desired_status = 'running' then
    v_blockers := v_blockers || jsonb_build_array(jsonb_build_object('code','platform_maintenance_mode'));
  end if;
  if v_state.observed_generation <> v_state.generation then
    v_blockers := v_blockers || jsonb_build_array(jsonb_build_object('code','generation_not_reconciled','generation',v_state.generation,'observed_generation',v_state.observed_generation));
  end if;
  if v_state.desired_status = 'running' and v_state.observed_status <> 'running' then
    v_blockers := v_blockers || jsonb_build_array(jsonb_build_object('code','runtime_not_running','observed_status',v_state.observed_status));
  end if;
  if v_state.desired_status = 'maintenance' and v_state.observed_status <> 'maintenance' then
    v_blockers := v_blockers || jsonb_build_array(jsonb_build_object('code','maintenance_not_reconciled','observed_status',v_state.observed_status));
  end if;

  v_ready := jsonb_array_length(v_blockers) = 0;

  return jsonb_build_object(
    'contract_version','platform-engine-readiness-v1',
    'generated_at',now(),
    'engine_code',p_engine_code,
    'desired_status',v_state.desired_status,
    'observed_status',v_state.observed_status,
    'generation',v_state.generation,
    'observed_generation',v_state.observed_generation,
    'is_ready',v_ready,
    'computed_readiness_status',case when v_ready then 'ready' else 'blocked' end,
    'dependency_validation',v_dependencies,
    'blockers',v_blockers
  );
end;
$function$;

-- --------------------------------------------------------------------------
-- 7. Stable read contracts
-- --------------------------------------------------------------------------

create or replace function public.get_platform_engine_runtime_states_rpc(
  p_engine_code text default null
)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $function$
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'engine_code',s.engine_code,
      'engine_name',e.engine_name,
      'installation_order',e.installation_order,
      'desired_status',s.desired_status,
      'observed_status',s.observed_status,
      'readiness_status',s.readiness_status,
      'generation',s.generation,
      'observed_generation',s.observed_generation,
      'transition_sequence',s.transition_sequence,
      'last_transition_at',s.last_transition_at,
      'last_heartbeat_at',s.last_heartbeat_at,
      'last_ready_at',s.last_ready_at,
      'status_reason',s.status_reason,
      'status_details',s.status_details,
      'updated_at',s.updated_at
    ) order by e.installation_order, s.engine_code
  ), '[]'::jsonb)
  from public.platform_engine_runtime_states s
  join public.platform_engine_registry e using (engine_code)
  where p_engine_code is null or s.engine_code = p_engine_code;
$function$;

create or replace function public.get_platform_runtime_events_rpc(
  p_engine_code text default null,
  p_limit integer default 100
)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $function$
  select coalesce(jsonb_agg(to_jsonb(x) order by x.occurred_at desc, x.transition_sequence desc), '[]'::jsonb)
  from (
    select ev.*
    from public.platform_engine_runtime_events ev
    where p_engine_code is null or ev.engine_code = p_engine_code
    order by ev.occurred_at desc, ev.transition_sequence desc
    limit greatest(1, least(coalesce(p_limit,100),500))
  ) x;
$function$;

-- --------------------------------------------------------------------------
-- 8. Service-only desired-state and reconciliation commands
-- --------------------------------------------------------------------------

create or replace function public.request_platform_engine_desired_state_rpc(
  p_engine_code text,
  p_desired_status text,
  p_reason text,
  p_details jsonb default '{}'::jsonb,
  p_correlation_id uuid default null,
  p_causation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_old public.platform_engine_runtime_states%rowtype;
  v_new public.platform_engine_runtime_states%rowtype;
begin
  if p_desired_status not in ('stopped','running','maintenance','disabled') then
    raise exception 'PLATFORM_ORCHESTRATOR_INVALID_DESIRED_STATUS: %', p_desired_status;
  end if;
  if p_details is null or jsonb_typeof(p_details) <> 'object' then
    raise exception 'PLATFORM_ORCHESTRATOR_INVALID_DETAILS: details must be a JSON object';
  end if;

  select * into v_old from public.platform_engine_runtime_states
  where engine_code = p_engine_code for update;
  if not found then raise exception 'PLATFORM_ORCHESTRATOR_ENGINE_STATE_NOT_FOUND: %', p_engine_code; end if;

  if v_old.desired_status = p_desired_status then
    return jsonb_build_object('changed',false,'engine_code',p_engine_code,'generation',v_old.generation,'desired_status',v_old.desired_status);
  end if;

  update public.platform_engine_runtime_states
  set desired_status = p_desired_status,
      readiness_status = 'not_ready',
      generation = generation + 1,
      transition_sequence = transition_sequence + 1,
      last_transition_at = now(),
      status_reason = p_reason,
      status_details = p_details
  where engine_code = p_engine_code
  returning * into v_new;

  insert into public.platform_engine_runtime_events (
    engine_code,transition_sequence,event_type,
    previous_desired_status,desired_status,
    previous_observed_status,observed_status,
    previous_readiness_status,readiness_status,
    generation,observed_generation,reason,details,correlation_id,causation_id
  ) values (
    p_engine_code,v_new.transition_sequence,'desired_state_requested',
    v_old.desired_status,v_new.desired_status,
    v_old.observed_status,v_new.observed_status,
    v_old.readiness_status,v_new.readiness_status,
    v_new.generation,v_new.observed_generation,p_reason,p_details,p_correlation_id,p_causation_id
  );

  return jsonb_build_object('changed',true,'engine_code',p_engine_code,'generation',v_new.generation,'desired_status',v_new.desired_status);
end;
$function$;

create or replace function public.reconcile_platform_engine_runtime_state_rpc(
  p_engine_code text,
  p_observed_status text,
  p_observed_generation bigint,
  p_reason text default null,
  p_details jsonb default '{}'::jsonb,
  p_correlation_id uuid default null,
  p_causation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_old public.platform_engine_runtime_states%rowtype;
  v_new public.platform_engine_runtime_states%rowtype;
  v_readiness jsonb;
  v_readiness_status text;
begin
  if p_observed_status not in ('unknown','stopped','starting','running','degraded','maintenance','recovering','stopping','failed','disabled') then
    raise exception 'PLATFORM_ORCHESTRATOR_INVALID_OBSERVED_STATUS: %', p_observed_status;
  end if;
  if p_details is null or jsonb_typeof(p_details) <> 'object' then
    raise exception 'PLATFORM_ORCHESTRATOR_INVALID_DETAILS: details must be a JSON object';
  end if;

  select * into v_old from public.platform_engine_runtime_states
  where engine_code = p_engine_code for update;
  if not found then raise exception 'PLATFORM_ORCHESTRATOR_ENGINE_STATE_NOT_FOUND: %', p_engine_code; end if;
  if p_observed_generation < 0 or p_observed_generation > v_old.generation then
    raise exception 'PLATFORM_ORCHESTRATOR_INVALID_GENERATION: observed % current %', p_observed_generation, v_old.generation;
  end if;

  update public.platform_engine_runtime_states
  set observed_status = p_observed_status,
      observed_generation = p_observed_generation,
      readiness_status = 'not_ready',
      transition_sequence = transition_sequence + 1,
      last_transition_at = now(),
      last_heartbeat_at = now(),
      status_reason = p_reason,
      status_details = p_details
  where engine_code = p_engine_code
  returning * into v_new;

  v_readiness := public.evaluate_platform_engine_readiness_rpc(p_engine_code);
  v_readiness_status := case when (v_readiness ->> 'is_ready')::boolean then 'ready' else 'blocked' end;

  update public.platform_engine_runtime_states
  set readiness_status = v_readiness_status,
      last_ready_at = case when v_readiness_status = 'ready' then now() else last_ready_at end,
      status_details = p_details || jsonb_build_object('readiness',v_readiness)
  where engine_code = p_engine_code
  returning * into v_new;

  insert into public.platform_engine_runtime_events (
    engine_code,transition_sequence,event_type,
    previous_desired_status,desired_status,
    previous_observed_status,observed_status,
    previous_readiness_status,readiness_status,
    generation,observed_generation,reason,details,correlation_id,causation_id
  ) values (
    p_engine_code,v_new.transition_sequence,'observation_reconciled',
    v_old.desired_status,v_new.desired_status,
    v_old.observed_status,v_new.observed_status,
    v_old.readiness_status,v_new.readiness_status,
    v_new.generation,v_new.observed_generation,p_reason,
    p_details || jsonb_build_object('readiness',v_readiness),p_correlation_id,p_causation_id
  );

  return jsonb_build_object('engine_code',p_engine_code,'state',to_jsonb(v_new),'readiness',v_readiness);
end;
$function$;

-- --------------------------------------------------------------------------
-- 9. Security
-- --------------------------------------------------------------------------

alter table public.platform_engine_runtime_states enable row level security;
alter table public.platform_engine_runtime_events enable row level security;

revoke all on table public.platform_engine_runtime_states from anon, authenticated;
revoke all on table public.platform_engine_runtime_events from anon, authenticated;
grant select, insert, update, delete on table public.platform_engine_runtime_states to service_role;
grant select, insert on table public.platform_engine_runtime_events to service_role;

drop policy if exists platform_engine_runtime_states_service_all on public.platform_engine_runtime_states;
create policy platform_engine_runtime_states_service_all
  on public.platform_engine_runtime_states for all to service_role using (true) with check (true);

drop policy if exists platform_engine_runtime_events_service_all on public.platform_engine_runtime_events;
create policy platform_engine_runtime_events_service_all
  on public.platform_engine_runtime_events for all to service_role using (true) with check (true);

revoke all on function public.protect_platform_engine_runtime_event_immutability() from public, anon, authenticated;
revoke all on function public.evaluate_platform_engine_readiness_rpc(text) from public, anon;
revoke all on function public.get_platform_engine_runtime_states_rpc(text) from public, anon;
revoke all on function public.get_platform_runtime_events_rpc(text, integer) from public, anon;
revoke all on function public.request_platform_engine_desired_state_rpc(text,text,text,jsonb,uuid,uuid) from public, anon, authenticated;
revoke all on function public.reconcile_platform_engine_runtime_state_rpc(text,text,bigint,text,jsonb,uuid,uuid) from public, anon, authenticated;

grant execute on function public.evaluate_platform_engine_readiness_rpc(text) to authenticated, service_role;
grant execute on function public.get_platform_engine_runtime_states_rpc(text) to authenticated, service_role;
grant execute on function public.get_platform_runtime_events_rpc(text, integer) to authenticated, service_role;
grant execute on function public.request_platform_engine_desired_state_rpc(text,text,text,jsonb,uuid,uuid) to service_role;
grant execute on function public.reconcile_platform_engine_runtime_state_rpc(text,text,bigint,text,jsonb,uuid,uuid) to service_role;

-- --------------------------------------------------------------------------
-- 10. Feature, policies and consolidated snapshot
-- --------------------------------------------------------------------------

insert into public.platform_feature_flags (
  feature_key,feature_name,description,enabled,rollout_percentage,audience,
  environment_scope,owner_engine_code,metadata
)
values (
  'runtime.platform_orchestrator',
  'Platform orchestrator control plane',
  'Expose persistent desired/observed engine state and readiness contracts.',
  true,100,'service',
  array['development','preview','staging','production','test'],
  'platform_orchestrator_engine',
  '{"contract":"platform-orchestrator-v1","migration":80}'::jsonb
)
on conflict (feature_key) do update
set enabled = excluded.enabled,
    rollout_percentage = excluded.rollout_percentage,
    owner_engine_code = excluded.owner_engine_code,
    metadata = public.platform_feature_flags.metadata || excluded.metadata;

insert into public.platform_runtime_policies (
  policy_key,policy_name,description,policy_type,policy_value,
  validation_contract,owner_engine_code,enforcement_level,enabled,metadata
)
values
  ('runtime.orchestrator.heartbeat_stale_after','Orchestrator heartbeat stale threshold','Duration after which an engine observation is considered stale.','duration','"PT10M"'::jsonb,'{"format":"ISO-8601-duration"}'::jsonb,'platform_orchestrator_engine','required',true,'{"migration":80}'::jsonb),
  ('runtime.orchestrator.require_generation_match','Require orchestrator generation match','An engine is ready only after observed generation matches desired generation.','boolean','true'::jsonb,'{}'::jsonb,'platform_orchestrator_engine','critical',true,'{"migration":80}'::jsonb)
on conflict (policy_key) do update
set policy_value = excluded.policy_value,
    owner_engine_code = excluded.owner_engine_code,
    enforcement_level = excluded.enforcement_level,
    enabled = excluded.enabled,
    metadata = public.platform_runtime_policies.metadata || excluded.metadata;

create or replace function public.get_platform_governance_snapshot_rpc()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $function$
  select jsonb_build_object(
    'contract_version','platform-governance-v1.1',
    'generated_at',now(),
    'configuration',public.get_platform_configuration_rpc(),
    'engines',public.get_platform_engine_registry_rpc(false),
    'dependencies',public.get_platform_engine_dependencies_rpc(null,false),
    'dependency_validation',public.validate_platform_dependency_graph_rpc(null),
    'runtime_states',public.get_platform_engine_runtime_states_rpc(null),
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
set schema_version = greatest(schema_version,80),
    metadata = metadata || jsonb_build_object(
      'phase','8.3.1',
      'platform_orchestrator_foundation_migration',80,
      'platform_orchestrator_contract','platform-orchestrator-v1',
      'governance_contract','platform-governance-v1.1'
    )
where configuration_key = 'primary';

do $assertions$
declare
  v_engine_count integer;
  v_state_count integer;
  v_event_count integer;
  v_dependency_validation jsonb;
  v_readiness jsonb;
  v_snapshot jsonb;
begin
  select count(*) into v_engine_count from public.platform_engine_registry;
  select count(*) into v_state_count from public.platform_engine_runtime_states;
  select count(*) into v_event_count from public.platform_engine_runtime_events;

  if v_engine_count <> 11 then
    raise exception 'PLATFORM_ORCHESTRATOR_ASSERTION_FAILED: expected 11 engines, found %', v_engine_count;
  end if;
  if v_state_count <> v_engine_count then
    raise exception 'PLATFORM_ORCHESTRATOR_ASSERTION_FAILED: runtime states % differ from engines %', v_state_count, v_engine_count;
  end if;
  if v_event_count < v_engine_count then
    raise exception 'PLATFORM_ORCHESTRATOR_ASSERTION_FAILED: bootstrap events incomplete';
  end if;

  v_dependency_validation := public.validate_platform_dependency_graph_rpc('platform_orchestrator_engine');
  if not coalesce((v_dependency_validation ->> 'is_valid')::boolean,false) then
    raise exception 'PLATFORM_ORCHESTRATOR_ASSERTION_FAILED: orchestrator dependencies invalid: %', v_dependency_validation;
  end if;

  v_readiness := public.evaluate_platform_engine_readiness_rpc('platform_orchestrator_engine');
  if not coalesce((v_readiness ->> 'is_ready')::boolean,false) then
    raise exception 'PLATFORM_ORCHESTRATOR_ASSERTION_FAILED: orchestrator not ready: %', v_readiness;
  end if;

  v_snapshot := public.get_platform_governance_snapshot_rpc();
  if not (v_snapshot ? 'runtime_states')
     or jsonb_array_length(v_snapshot -> 'runtime_states') <> v_engine_count then
    raise exception 'PLATFORM_ORCHESTRATOR_ASSERTION_FAILED: governance snapshot runtime states invalid';
  end if;
end;
$assertions$;

commit;
