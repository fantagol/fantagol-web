-- FantaGol
-- Migration 073: Runtime Maintenance Pipeline Integration
-- Purpose: integrate maintenance, retention, reconciliation, health monitoring and scheduler contracts
-- Safety: disabled by default; proposal-only handoffs; no automatic invocation or destructive action
-- Dependencies: 067, 068, 069, 070, 071, 072

begin;

create extension if not exists pgcrypto;

create table if not exists public.runtime_maintenance_pipeline_profiles (
  id uuid primary key default gen_random_uuid(),
  profile_key text not null,
  profile_version integer not null default 1,
  display_name text not null,
  description text,
  enabled boolean not null default false,
  automatic_orchestration_enabled boolean not null default false,
  scheduler_profile_key text not null,
  maintenance_policy_key text not null,
  retention_profile_key text not null,
  reconciliation_profile_key text not null,
  health_monitor_profile_key text not null,
  maximum_stages_per_run integer not null default 16,
  minimum_run_interval interval not null default interval '15 minutes',
  pipeline_config jsonb not null default '{}'::jsonb,
  created_by uuid,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  retired_at timestamptz,
  constraint runtime_maintenance_pipeline_profiles_key_check check (btrim(profile_key) <> ''),
  constraint runtime_maintenance_pipeline_profiles_version_check check (profile_version > 0),
  constraint runtime_maintenance_pipeline_profiles_name_check check (btrim(display_name) <> ''),
  constraint runtime_maintenance_pipeline_profiles_orchestration_guard check (automatic_orchestration_enabled = false),
  constraint runtime_maintenance_pipeline_profiles_stage_limit_check check (maximum_stages_per_run between 1 and 100),
  constraint runtime_maintenance_pipeline_profiles_interval_check check (minimum_run_interval >= interval '5 minutes'),
  constraint runtime_maintenance_pipeline_profiles_unique unique (profile_key, profile_version)
);

create index if not exists runtime_maintenance_pipeline_profiles_active_idx
  on public.runtime_maintenance_pipeline_profiles (enabled, profile_key)
  where retired_at is null;

create trigger runtime_maintenance_pipeline_profiles_set_updated_at
before update on public.runtime_maintenance_pipeline_profiles
for each row execute function public.set_maintenance_updated_at();

comment on table public.runtime_maintenance_pipeline_profiles is
'Disabled-by-default integration profiles joining the 067-072 maintenance subsystem contracts.';

create table if not exists public.runtime_maintenance_pipeline_runs (
  id uuid primary key default gen_random_uuid(),
  pipeline_profile_id uuid not null references public.runtime_maintenance_pipeline_profiles(id),
  status text not null default 'requested',
  overall_status text not null default 'pending',
  idempotency_key text not null,
  requested_by uuid,
  requested_at timestamptz not null default clock_timestamp(),
  started_at timestamptz,
  completed_at timestamptz,
  evaluation_at timestamptz,
  stage_count integer not null default 0,
  proposed_handoff_count integer not null default 0,
  skipped_stage_count integer not null default 0,
  pipeline_version text not null default 'runtime-maintenance-pipeline-v1',
  run_hash text,
  request_payload jsonb not null default '{}'::jsonb,
  pipeline_snapshot jsonb not null default '{}'::jsonb,
  error_code text,
  error_message text,
  error_details jsonb not null default '{}'::jsonb,
  correlation_id uuid,
  causation_id uuid,
  created_at timestamptz not null default clock_timestamp(),
  constraint runtime_maintenance_pipeline_runs_status_check check (status in ('requested','building','completed','failed','cancelled')),
  constraint runtime_maintenance_pipeline_runs_overall_check check (overall_status in ('pending','ready','attention','blocked','failed','cancelled')),
  constraint runtime_maintenance_pipeline_runs_idempotency_check check (btrim(idempotency_key) <> ''),
  constraint runtime_maintenance_pipeline_runs_count_check check (stage_count >= 0 and proposed_handoff_count >= 0 and skipped_stage_count >= 0),
  constraint runtime_maintenance_pipeline_runs_unique unique (pipeline_profile_id, idempotency_key)
);

create index if not exists runtime_maintenance_pipeline_runs_status_idx
  on public.runtime_maintenance_pipeline_runs (status, requested_at desc);
create index if not exists runtime_maintenance_pipeline_runs_profile_idx
  on public.runtime_maintenance_pipeline_runs (pipeline_profile_id, requested_at desc);

comment on table public.runtime_maintenance_pipeline_runs is
'Immutable-core pipeline run envelope. Build operations only produce stage and handoff proposals.';

create table if not exists public.runtime_maintenance_pipeline_stages (
  id uuid primary key default gen_random_uuid(),
  pipeline_run_id uuid not null references public.runtime_maintenance_pipeline_runs(id) on delete cascade,
  stage_key text not null,
  stage_order integer not null,
  stage_type text not null,
  target_profile_key text not null,
  status text not null default 'proposed',
  prerequisite_stage_key text,
  readiness_status text not null default 'unknown',
  source_record_id uuid,
  source_record_type text,
  reason text,
  stage_payload jsonb not null default '{}'::jsonb,
  stage_hash text not null,
  observed_at timestamptz not null default clock_timestamp(),
  created_at timestamptz not null default clock_timestamp(),
  constraint runtime_maintenance_pipeline_stages_key_check check (btrim(stage_key) <> ''),
  constraint runtime_maintenance_pipeline_stages_order_check check (stage_order > 0),
  constraint runtime_maintenance_pipeline_stages_type_check check (stage_type in ('scheduler','maintenance','retention','reconciliation','health_monitor')),
  constraint runtime_maintenance_pipeline_stages_status_check check (status in ('proposed','ready','blocked','skipped','acknowledged')),
  constraint runtime_maintenance_pipeline_stages_readiness_check check (readiness_status in ('unknown','ready','blocked','not_due','disabled','missing_dependency')),
  constraint runtime_maintenance_pipeline_stages_unique unique (pipeline_run_id, stage_key),
  constraint runtime_maintenance_pipeline_stages_order_unique unique (pipeline_run_id, stage_order)
);

create index if not exists runtime_maintenance_pipeline_stages_run_idx
  on public.runtime_maintenance_pipeline_stages (pipeline_run_id, stage_order);
create index if not exists runtime_maintenance_pipeline_stages_attention_idx
  on public.runtime_maintenance_pipeline_stages (status, readiness_status, observed_at desc);

comment on table public.runtime_maintenance_pipeline_stages is
'Ordered observation-only stages composing a runtime maintenance pipeline run.';

create table if not exists public.runtime_maintenance_pipeline_handoffs (
  id uuid primary key default gen_random_uuid(),
  pipeline_run_id uuid not null references public.runtime_maintenance_pipeline_runs(id) on delete cascade,
  pipeline_stage_id uuid not null references public.runtime_maintenance_pipeline_stages(id) on delete cascade,
  handoff_key text not null,
  target_rpc text not null,
  target_profile_key text not null,
  status text not null default 'proposed',
  invocation_enabled boolean not null default false,
  request_payload jsonb not null default '{}'::jsonb,
  reason text,
  skip_code text,
  skip_details jsonb not null default '{}'::jsonb,
  acknowledged_at timestamptz,
  acknowledged_by uuid,
  acknowledgement_note text,
  handoff_hash text not null,
  created_at timestamptz not null default clock_timestamp(),
  constraint runtime_maintenance_pipeline_handoffs_key_check check (btrim(handoff_key) <> ''),
  constraint runtime_maintenance_pipeline_handoffs_rpc_check check (target_rpc in (
    'request_maintenance_scheduler_tick_rpc',
    'request_maintenance_run_rpc',
    'request_retention_plan_rpc',
    'request_runtime_reconciliation_scan_rpc',
    'request_health_monitor_run_rpc'
  )),
  constraint runtime_maintenance_pipeline_handoffs_status_check check (status in ('proposed','skipped','acknowledged','cancelled')),
  constraint runtime_maintenance_pipeline_handoffs_invocation_guard check (invocation_enabled = false),
  constraint runtime_maintenance_pipeline_handoffs_unique unique (pipeline_run_id, handoff_key)
);

create index if not exists runtime_maintenance_pipeline_handoffs_run_idx
  on public.runtime_maintenance_pipeline_handoffs (pipeline_run_id, created_at);
create index if not exists runtime_maintenance_pipeline_handoffs_attention_idx
  on public.runtime_maintenance_pipeline_handoffs (status, created_at desc);

comment on table public.runtime_maintenance_pipeline_handoffs is
'Non-executable integration handoff ledger. invocation_enabled is structurally forced to false.';

create or replace function public.protect_runtime_maintenance_pipeline_run_core()
returns trigger
language plpgsql
as $$
begin
  if old.pipeline_profile_id <> new.pipeline_profile_id
     or old.idempotency_key <> new.idempotency_key
     or old.requested_by is distinct from new.requested_by
     or old.requested_at <> new.requested_at
     or old.pipeline_version <> new.pipeline_version
     or old.request_payload <> new.request_payload
     or old.correlation_id is distinct from new.correlation_id
     or old.causation_id is distinct from new.causation_id
     or old.created_at <> new.created_at then
    raise exception 'runtime maintenance pipeline run core is immutable';
  end if;
  return new;
end;
$$;

create trigger protect_runtime_maintenance_pipeline_run_core_trigger
before update on public.runtime_maintenance_pipeline_runs
for each row execute function public.protect_runtime_maintenance_pipeline_run_core();

create or replace function public.protect_runtime_maintenance_pipeline_stage()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'runtime maintenance pipeline stages are immutable';
  end if;
  if old.pipeline_run_id <> new.pipeline_run_id
     or old.stage_key <> new.stage_key
     or old.stage_order <> new.stage_order
     or old.stage_type <> new.stage_type
     or old.target_profile_key <> new.target_profile_key
     or old.prerequisite_stage_key is distinct from new.prerequisite_stage_key
     or old.source_record_id is distinct from new.source_record_id
     or old.source_record_type is distinct from new.source_record_type
     or old.stage_payload <> new.stage_payload
     or old.stage_hash <> new.stage_hash
     or old.observed_at <> new.observed_at
     or old.created_at <> new.created_at then
    raise exception 'runtime maintenance pipeline stage evidence is immutable';
  end if;
  return new;
end;
$$;

create trigger protect_runtime_maintenance_pipeline_stage_update_trigger
before update on public.runtime_maintenance_pipeline_stages
for each row execute function public.protect_runtime_maintenance_pipeline_stage();
create trigger protect_runtime_maintenance_pipeline_stage_delete_trigger
before delete on public.runtime_maintenance_pipeline_stages
for each row execute function public.protect_runtime_maintenance_pipeline_stage();

create or replace function public.protect_runtime_maintenance_pipeline_handoff()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'runtime maintenance pipeline handoffs are immutable';
  end if;
  if old.pipeline_run_id <> new.pipeline_run_id
     or old.pipeline_stage_id <> new.pipeline_stage_id
     or old.handoff_key <> new.handoff_key
     or old.target_rpc <> new.target_rpc
     or old.target_profile_key <> new.target_profile_key
     or old.invocation_enabled <> new.invocation_enabled
     or old.request_payload <> new.request_payload
     or old.handoff_hash <> new.handoff_hash
     or old.created_at <> new.created_at then
    raise exception 'runtime maintenance pipeline handoff core is immutable';
  end if;
  return new;
end;
$$;

create trigger protect_runtime_maintenance_pipeline_handoff_update_trigger
before update on public.runtime_maintenance_pipeline_handoffs
for each row execute function public.protect_runtime_maintenance_pipeline_handoff();
create trigger protect_runtime_maintenance_pipeline_handoff_delete_trigger
before delete on public.runtime_maintenance_pipeline_handoffs
for each row execute function public.protect_runtime_maintenance_pipeline_handoff();

create or replace function public.request_runtime_maintenance_pipeline_run_rpc(
  p_profile_key text,
  p_idempotency_key text,
  p_requested_by uuid default null,
  p_request_payload jsonb default '{}'::jsonb,
  p_correlation_id uuid default null,
  p_causation_id uuid default null
)
returns public.runtime_maintenance_pipeline_runs
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_profile public.runtime_maintenance_pipeline_profiles;
  v_run public.runtime_maintenance_pipeline_runs;
begin
  if btrim(coalesce(p_profile_key,'')) = '' or btrim(coalesce(p_idempotency_key,'')) = '' then
    raise exception 'profile_key and idempotency_key are required';
  end if;

  select * into v_profile
  from public.runtime_maintenance_pipeline_profiles
  where profile_key = p_profile_key and retired_at is null
  order by profile_version desc
  limit 1;

  if not found then raise exception 'pipeline profile not found: %', p_profile_key; end if;

  insert into public.runtime_maintenance_pipeline_runs (
    pipeline_profile_id, idempotency_key, requested_by, request_payload, correlation_id, causation_id
  ) values (
    v_profile.id, p_idempotency_key, p_requested_by, coalesce(p_request_payload,'{}'::jsonb), p_correlation_id, p_causation_id
  )
  on conflict (pipeline_profile_id, idempotency_key) do update
    set idempotency_key = excluded.idempotency_key
  returning * into v_run;

  return v_run;
end;
$$;

comment on function public.request_runtime_maintenance_pipeline_run_rpc is
'Requests an idempotent integration run. It does not invoke child engines.';

create or replace function public.build_runtime_maintenance_pipeline_run_rpc(
  p_pipeline_run_id uuid,
  p_evaluation_at timestamptz default clock_timestamp()
)
returns public.runtime_maintenance_pipeline_runs
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_run public.runtime_maintenance_pipeline_runs;
  v_profile public.runtime_maintenance_pipeline_profiles;
  v_stage_id uuid;
  v_stage_count integer := 0;
  v_handoff_count integer := 0;
  v_skipped_count integer := 0;
  v_stage record;
  v_readiness text;
  v_status text;
  v_rpc text;
  v_hash text;
begin
  select * into v_run from public.runtime_maintenance_pipeline_runs where id = p_pipeline_run_id for update;
  if not found then raise exception 'pipeline run not found: %', p_pipeline_run_id; end if;
  if v_run.status in ('completed','cancelled') then return v_run; end if;

  select * into v_profile from public.runtime_maintenance_pipeline_profiles where id = v_run.pipeline_profile_id;

  update public.runtime_maintenance_pipeline_runs
  set status = 'building', started_at = coalesce(started_at, clock_timestamp()), evaluation_at = p_evaluation_at
  where id = v_run.id;

  for v_stage in
    select * from (values
      (1, 'scheduler',      'scheduler',      v_profile.scheduler_profile_key,      null::text, 'request_maintenance_scheduler_tick_rpc'),
      (2, 'maintenance',    'maintenance',    v_profile.maintenance_policy_key,     'scheduler', 'request_maintenance_run_rpc'),
      (3, 'retention',      'retention',      v_profile.retention_profile_key,      'maintenance', 'request_retention_plan_rpc'),
      (4, 'reconciliation', 'reconciliation', v_profile.reconciliation_profile_key,'retention', 'request_runtime_reconciliation_scan_rpc'),
      (5, 'health-monitor', 'health_monitor', v_profile.health_monitor_profile_key, 'reconciliation', 'request_health_monitor_run_rpc')
    ) as s(stage_order, stage_key, stage_type, target_profile_key, prerequisite_stage_key, target_rpc)
  loop
    v_readiness := case when v_profile.enabled then 'ready' else 'disabled' end;
    v_status := case when v_profile.enabled then 'ready' else 'skipped' end;
    v_rpc := v_stage.target_rpc;
    v_hash := encode(digest(concat_ws('|', v_run.id::text, v_stage.stage_key, v_stage.stage_order::text,
      v_stage.target_profile_key, v_readiness, p_evaluation_at::text), 'sha256'), 'hex');

    insert into public.runtime_maintenance_pipeline_stages (
      pipeline_run_id, stage_key, stage_order, stage_type, target_profile_key,
      status, prerequisite_stage_key, readiness_status, reason, stage_payload, stage_hash, observed_at
    ) values (
      v_run.id, v_stage.stage_key, v_stage.stage_order, v_stage.stage_type, v_stage.target_profile_key,
      v_status, v_stage.prerequisite_stage_key, v_readiness,
      case when v_profile.enabled then 'integration stage ready for manual handoff acknowledgement'
           else 'pipeline profile disabled by default' end,
      jsonb_build_object('automatic_orchestration_enabled', false, 'evaluation_at', p_evaluation_at),
      v_hash, p_evaluation_at
    )
    on conflict (pipeline_run_id, stage_key) do nothing
    returning id into v_stage_id;

    if v_stage_id is not null then
      v_stage_count := v_stage_count + 1;
      if v_status = 'skipped' then v_skipped_count := v_skipped_count + 1; end if;

      insert into public.runtime_maintenance_pipeline_handoffs (
        pipeline_run_id, pipeline_stage_id, handoff_key, target_rpc, target_profile_key,
        status, invocation_enabled, request_payload, reason, skip_code, handoff_hash
      ) values (
        v_run.id, v_stage_id, v_stage.stage_key || '-handoff', v_rpc, v_stage.target_profile_key,
        case when v_profile.enabled then 'proposed' else 'skipped' end,
        false,
        jsonb_build_object(
          'target_profile_key', v_stage.target_profile_key,
          'idempotency_key', v_run.idempotency_key || ':' || v_stage.stage_key,
          'correlation_id', coalesce(v_run.correlation_id, v_run.id),
          'causation_id', v_run.id,
          'invocation_enabled', false
        ),
        case when v_profile.enabled then 'manual integration handoff proposal'
             else 'pipeline profile disabled by default' end,
        case when v_profile.enabled then null else 'pipeline_disabled' end,
        encode(digest(concat_ws('|', v_run.id::text, v_stage.stage_key, v_rpc,
          v_stage.target_profile_key, 'invocation_enabled=false'), 'sha256'), 'hex')
      );
      v_handoff_count := v_handoff_count + 1;
    end if;
    v_stage_id := null;
  end loop;

  update public.runtime_maintenance_pipeline_runs
  set status = 'completed',
      overall_status = case when v_profile.enabled then 'ready' else 'blocked' end,
      completed_at = clock_timestamp(),
      stage_count = (select count(*) from public.runtime_maintenance_pipeline_stages where pipeline_run_id = v_run.id),
      proposed_handoff_count = (select count(*) from public.runtime_maintenance_pipeline_handoffs where pipeline_run_id = v_run.id and status = 'proposed'),
      skipped_stage_count = (select count(*) from public.runtime_maintenance_pipeline_stages where pipeline_run_id = v_run.id and status = 'skipped'),
      pipeline_snapshot = jsonb_build_object(
        'profile_key', v_profile.profile_key,
        'profile_version', v_profile.profile_version,
        'profile_enabled', v_profile.enabled,
        'automatic_orchestration_enabled', v_profile.automatic_orchestration_enabled,
        'stage_count', (select count(*) from public.runtime_maintenance_pipeline_stages where pipeline_run_id = v_run.id),
        'handoff_count', (select count(*) from public.runtime_maintenance_pipeline_handoffs where pipeline_run_id = v_run.id),
        'invocation_enabled_count', (select count(*) from public.runtime_maintenance_pipeline_handoffs where pipeline_run_id = v_run.id and invocation_enabled)
      ),
      run_hash = encode(digest(concat_ws('|', v_run.id::text, v_profile.profile_key,
        p_evaluation_at::text, (select count(*) from public.runtime_maintenance_pipeline_stages where pipeline_run_id=v_run.id)::text), 'sha256'), 'hex')
  where id = v_run.id
  returning * into v_run;

  return v_run;
exception when others then
  update public.runtime_maintenance_pipeline_runs
  set status = 'failed', overall_status = 'failed', completed_at = clock_timestamp(),
      error_code = sqlstate, error_message = sqlerrm
  where id = p_pipeline_run_id;
  raise;
end;
$$;

comment on function public.build_runtime_maintenance_pipeline_run_rpc is
'Builds ordered stages and non-executable handoff proposals without invoking dependent engines.';

create or replace function public.acknowledge_runtime_maintenance_pipeline_handoff_rpc(
  p_handoff_id uuid,
  p_acknowledged_by uuid,
  p_note text default null
)
returns public.runtime_maintenance_pipeline_handoffs
language plpgsql
security definer
set search_path = public
as $$
declare v_row public.runtime_maintenance_pipeline_handoffs;
begin
  update public.runtime_maintenance_pipeline_handoffs
  set status = 'acknowledged', acknowledged_at = clock_timestamp(),
      acknowledged_by = p_acknowledged_by, acknowledgement_note = p_note
  where id = p_handoff_id and status in ('proposed','skipped')
  returning * into v_row;
  if not found then raise exception 'handoff not found or not acknowledgeable: %', p_handoff_id; end if;
  return v_row;
end;
$$;

create or replace function public.cancel_runtime_maintenance_pipeline_run_rpc(
  p_pipeline_run_id uuid,
  p_reason text default null
)
returns public.runtime_maintenance_pipeline_runs
language plpgsql
security definer
set search_path = public
as $$
declare v_row public.runtime_maintenance_pipeline_runs;
begin
  update public.runtime_maintenance_pipeline_runs
  set status = 'cancelled', overall_status = 'cancelled', completed_at = clock_timestamp(),
      error_code = 'cancelled', error_message = coalesce(p_reason,'cancelled by operator')
  where id = p_pipeline_run_id and status in ('requested','building')
  returning * into v_row;
  if not found then raise exception 'pipeline run not found or not cancellable: %', p_pipeline_run_id; end if;
  return v_row;
end;
$$;

create or replace function public.get_runtime_maintenance_pipeline_contract_rpc()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
select jsonb_build_object(
  'contract_version', 'runtime-maintenance-pipeline-v1',
  'stages', jsonb_build_array('scheduler','maintenance','retention','reconciliation','health_monitor'),
  'automatic_orchestration_enabled', false,
  'invocation_enabled', false,
  'dependent_request_rpcs', jsonb_build_array(
    'request_maintenance_scheduler_tick_rpc',
    'request_maintenance_run_rpc',
    'request_retention_plan_rpc',
    'request_runtime_reconciliation_scan_rpc',
    'request_health_monitor_run_rpc'
  )
);
$$;

create or replace function public.validate_runtime_maintenance_pipeline_dependencies_rpc()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare v_missing text[] := array[]::text[];
begin
  if to_regprocedure('public.request_maintenance_scheduler_tick_rpc(text,text,uuid,jsonb,uuid,uuid)') is null then v_missing := array_append(v_missing,'request_maintenance_scheduler_tick_rpc'); end if;
  if to_regprocedure('public.request_maintenance_run_rpc(text,text,text,uuid,timestamptz,boolean,jsonb,uuid,uuid)') is null then v_missing := array_append(v_missing,'request_maintenance_run_rpc'); end if;
  if to_regprocedure('public.request_retention_plan_rpc(text,text,uuid,interval,integer,jsonb,uuid,uuid)') is null then v_missing := array_append(v_missing,'request_retention_plan_rpc'); end if;
  if to_regprocedure('public.request_runtime_reconciliation_scan_rpc(text,text,uuid,uuid,jsonb,uuid,uuid)') is null then v_missing := array_append(v_missing,'request_runtime_reconciliation_scan_rpc'); end if;
  if to_regprocedure('public.request_health_monitor_run_rpc(text,text,uuid,jsonb,uuid,uuid)') is null then v_missing := array_append(v_missing,'request_health_monitor_run_rpc'); end if;
  return jsonb_build_object('valid', cardinality(v_missing)=0, 'missing', to_jsonb(v_missing));
end;
$$;

create or replace view public.runtime_maintenance_pipeline_run_status_v1 as
select
  r.id as pipeline_run_id,
  r.pipeline_profile_id,
  p.profile_key,
  p.profile_version,
  p.display_name as profile_display_name,
  p.enabled as profile_enabled,
  p.automatic_orchestration_enabled,
  r.status,
  r.overall_status,
  r.idempotency_key,
  r.requested_by,
  r.requested_at,
  r.started_at,
  r.evaluation_at,
  r.completed_at,
  r.stage_count,
  r.proposed_handoff_count,
  r.skipped_stage_count,
  r.pipeline_version,
  r.run_hash,
  r.request_payload,
  r.pipeline_snapshot,
  r.error_code,
  r.error_message,
  r.error_details,
  r.correlation_id,
  r.causation_id,
  r.created_at
from public.runtime_maintenance_pipeline_runs r
join public.runtime_maintenance_pipeline_profiles p on p.id = r.pipeline_profile_id;

create or replace view public.runtime_maintenance_pipeline_attention_v1 as
select
  h.id as pipeline_handoff_id,
  h.pipeline_run_id,
  h.pipeline_stage_id,
  s.stage_key,
  s.stage_order,
  s.stage_type,
  s.status as stage_status,
  s.readiness_status,
  h.handoff_key,
  h.target_rpc,
  h.target_profile_key,
  h.status as handoff_status,
  h.invocation_enabled,
  h.reason,
  h.skip_code,
  h.skip_details,
  h.acknowledged_at,
  h.acknowledged_by,
  h.acknowledgement_note,
  h.handoff_hash,
  h.created_at,
  p.profile_key,
  p.profile_version,
  r.status as pipeline_run_status,
  r.overall_status as pipeline_overall_status,
  r.requested_at as run_requested_at,
  case
    when h.invocation_enabled then 'critical'
    when s.readiness_status in ('blocked','missing_dependency') then 'high'
    when h.status = 'skipped' then 'medium'
    else 'info'
  end as attention_level,
  greatest(h.created_at, s.observed_at) as attention_reference_at
from public.runtime_maintenance_pipeline_handoffs h
join public.runtime_maintenance_pipeline_stages s on s.id = h.pipeline_stage_id
join public.runtime_maintenance_pipeline_runs r on r.id = h.pipeline_run_id
join public.runtime_maintenance_pipeline_profiles p on p.id = r.pipeline_profile_id
where h.status in ('proposed','skipped') or h.invocation_enabled;

alter table public.runtime_maintenance_pipeline_profiles enable row level security;
alter table public.runtime_maintenance_pipeline_runs enable row level security;
alter table public.runtime_maintenance_pipeline_stages enable row level security;
alter table public.runtime_maintenance_pipeline_handoffs enable row level security;

create policy runtime_maintenance_pipeline_profiles_service_role_all on public.runtime_maintenance_pipeline_profiles for all to service_role using (true) with check (true);
create policy runtime_maintenance_pipeline_runs_service_role_all on public.runtime_maintenance_pipeline_runs for all to service_role using (true) with check (true);
create policy runtime_maintenance_pipeline_stages_service_role_all on public.runtime_maintenance_pipeline_stages for all to service_role using (true) with check (true);
create policy runtime_maintenance_pipeline_handoffs_service_role_all on public.runtime_maintenance_pipeline_handoffs for all to service_role using (true) with check (true);

revoke all on public.runtime_maintenance_pipeline_profiles from public, anon, authenticated;
revoke all on public.runtime_maintenance_pipeline_runs from public, anon, authenticated;
revoke all on public.runtime_maintenance_pipeline_stages from public, anon, authenticated;
revoke all on public.runtime_maintenance_pipeline_handoffs from public, anon, authenticated;
grant select, insert, update on public.runtime_maintenance_pipeline_profiles to service_role;
grant select, insert, update on public.runtime_maintenance_pipeline_runs to service_role;
grant select, insert, update on public.runtime_maintenance_pipeline_stages to service_role;
grant select, insert, update on public.runtime_maintenance_pipeline_handoffs to service_role;

revoke all on public.runtime_maintenance_pipeline_run_status_v1 from public, anon, authenticated, service_role;
revoke all on public.runtime_maintenance_pipeline_attention_v1 from public, anon, authenticated, service_role;
grant select on public.runtime_maintenance_pipeline_run_status_v1 to service_role;
grant select on public.runtime_maintenance_pipeline_attention_v1 to service_role;

revoke all on function public.request_runtime_maintenance_pipeline_run_rpc(text,text,uuid,jsonb,uuid,uuid) from public, anon, authenticated;
revoke all on function public.build_runtime_maintenance_pipeline_run_rpc(uuid,timestamptz) from public, anon, authenticated;
revoke all on function public.acknowledge_runtime_maintenance_pipeline_handoff_rpc(uuid,uuid,text) from public, anon, authenticated;
revoke all on function public.cancel_runtime_maintenance_pipeline_run_rpc(uuid,text) from public, anon, authenticated;
revoke all on function public.get_runtime_maintenance_pipeline_contract_rpc() from public, anon, authenticated;
revoke all on function public.validate_runtime_maintenance_pipeline_dependencies_rpc() from public, anon, authenticated;
grant execute on function public.request_runtime_maintenance_pipeline_run_rpc(text,text,uuid,jsonb,uuid,uuid) to service_role;
grant execute on function public.build_runtime_maintenance_pipeline_run_rpc(uuid,timestamptz) to service_role;
grant execute on function public.acknowledge_runtime_maintenance_pipeline_handoff_rpc(uuid,uuid,text) to service_role;
grant execute on function public.cancel_runtime_maintenance_pipeline_run_rpc(uuid,text) to service_role;
grant execute on function public.get_runtime_maintenance_pipeline_contract_rpc() to service_role;
grant execute on function public.validate_runtime_maintenance_pipeline_dependencies_rpc() to service_role;

insert into public.runtime_maintenance_pipeline_profiles (
  profile_key, profile_version, display_name, description, enabled,
  automatic_orchestration_enabled, scheduler_profile_key, maintenance_policy_key,
  retention_profile_key, reconciliation_profile_key, health_monitor_profile_key,
  maximum_stages_per_run, minimum_run_interval, pipeline_config
) values (
  'runtime-maintenance-core', 1, 'Runtime Maintenance Core',
  'Disabled-by-default integration profile for scheduler, maintenance, retention, reconciliation and health monitoring.',
  false, false, 'maintenance-runtime-core', 'runtime_consistency_scan', 'runtime-retention-core',
  'runtime-core', 'runtime-health-core', 16, interval '15 minutes',
  jsonb_build_object(
    'mode','proposal_only',
    'stage_order',jsonb_build_array('scheduler','maintenance','retention','reconciliation','health_monitor'),
    'automatic_orchestration_enabled',false,
    'invocation_enabled',false
  )
) on conflict (profile_key, profile_version) do nothing;

do $$
declare v_validation jsonb;
begin
  if exists (select 1 from public.runtime_maintenance_pipeline_profiles where automatic_orchestration_enabled) then
    raise exception 'automatic orchestration safety invariant violated';
  end if;
  if exists (select 1 from public.runtime_maintenance_pipeline_handoffs where invocation_enabled) then
    raise exception 'handoff invocation safety invariant violated';
  end if;
  select public.validate_runtime_maintenance_pipeline_dependencies_rpc() into v_validation;
  if not coalesce((v_validation->>'valid')::boolean,false) then
    raise exception 'runtime maintenance pipeline dependencies missing: %', v_validation->'missing';
  end if;
end;
$$;

commit;
