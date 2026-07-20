begin;

create extension if not exists pgcrypto;

create table if not exists public.maintenance_runtime_certification_profiles (
  id uuid primary key default gen_random_uuid(),
  profile_key text not null,
  profile_version integer not null default 1 check (profile_version > 0),
  display_name text not null,
  description text,
  enabled boolean not null default false,
  automatic_execution_enabled boolean not null default false,
  certification_version text not null default 'maintenance-runtime-e2e-v1',
  required_migrations integer[] not null default array[67,68,69,70,71,72,73],
  expected_pipeline_stages text[] not null default array['scheduler','maintenance','retention','reconciliation','health_monitor'],
  certification_config jsonb not null default '{}'::jsonb,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  retired_at timestamptz,
  constraint maintenance_runtime_certification_profiles_key_uq unique(profile_key, profile_version),
  constraint maintenance_runtime_certification_profiles_execution_guard check (automatic_execution_enabled = false),
  constraint maintenance_runtime_certification_profiles_config_object check (jsonb_typeof(certification_config) = 'object')
);

create index if not exists maintenance_runtime_certification_profiles_active_idx
  on public.maintenance_runtime_certification_profiles(profile_key, profile_version desc)
  where retired_at is null;

create trigger maintenance_runtime_certification_profiles_updated_at_trg
before update on public.maintenance_runtime_certification_profiles
for each row execute function public.set_maintenance_updated_at();

comment on table public.maintenance_runtime_certification_profiles is
'Disabled-by-default profiles for non-destructive end-to-end certification of the maintenance runtime subsystem.';

create table if not exists public.maintenance_runtime_certification_runs (
  id uuid primary key default gen_random_uuid(),
  certification_profile_id uuid not null references public.maintenance_runtime_certification_profiles(id),
  status text not null default 'requested' check (status in ('requested','running','completed','failed','cancelled')),
  overall_result text check (overall_result in ('passed','warning','failed','cancelled')),
  idempotency_key text not null,
  requested_by uuid,
  requested_at timestamptz not null default now(),
  started_at timestamptz,
  evaluation_at timestamptz,
  completed_at timestamptz,
  certification_version text not null,
  check_count integer not null default 0 check (check_count >= 0),
  passed_count integer not null default 0 check (passed_count >= 0),
  warning_count integer not null default 0 check (warning_count >= 0),
  failed_count integer not null default 0 check (failed_count >= 0),
  run_hash text,
  request_payload jsonb not null default '{}'::jsonb,
  certification_snapshot jsonb not null default '{}'::jsonb,
  error_code text,
  error_message text,
  error_details jsonb,
  correlation_id uuid,
  causation_id uuid,
  created_at timestamptz not null default now(),
  constraint maintenance_runtime_certification_runs_idempotency_uq unique(certification_profile_id, idempotency_key),
  constraint maintenance_runtime_certification_runs_request_object check (jsonb_typeof(request_payload) = 'object'),
  constraint maintenance_runtime_certification_runs_snapshot_object check (jsonb_typeof(certification_snapshot) = 'object')
);

create index if not exists maintenance_runtime_certification_runs_status_idx
  on public.maintenance_runtime_certification_runs(status, requested_at desc);
create index if not exists maintenance_runtime_certification_runs_correlation_idx
  on public.maintenance_runtime_certification_runs(correlation_id)
  where correlation_id is not null;

comment on table public.maintenance_runtime_certification_runs is
'Immutable certification run ledger for migrations 067 through 073.';

create table if not exists public.maintenance_runtime_certification_checks (
  id uuid primary key default gen_random_uuid(),
  certification_run_id uuid not null references public.maintenance_runtime_certification_runs(id) on delete cascade,
  check_order integer not null check (check_order > 0),
  check_key text not null,
  check_category text not null check (check_category in ('structure','contract','dependency','security','safety','read_model')),
  severity text not null default 'error' check (severity in ('info','warning','error','critical')),
  result text not null check (result in ('passed','warning','failed')),
  expected_value jsonb,
  actual_value jsonb,
  details jsonb not null default '{}'::jsonb,
  check_hash text not null,
  created_at timestamptz not null default now(),
  constraint maintenance_runtime_certification_checks_order_uq unique(certification_run_id, check_order),
  constraint maintenance_runtime_certification_checks_key_uq unique(certification_run_id, check_key),
  constraint maintenance_runtime_certification_checks_details_object check (jsonb_typeof(details) = 'object')
);

create index if not exists maintenance_runtime_certification_checks_result_idx
  on public.maintenance_runtime_certification_checks(certification_run_id, result, severity);

comment on table public.maintenance_runtime_certification_checks is
'Append-only evidence ledger for each maintenance runtime certification assertion.';

create table if not exists public.maintenance_runtime_certification_reports (
  id uuid primary key default gen_random_uuid(),
  certification_run_id uuid not null unique references public.maintenance_runtime_certification_runs(id) on delete cascade,
  report_version text not null default 'maintenance-runtime-e2e-report-v1',
  overall_result text not null check (overall_result in ('passed','warning','failed','cancelled')),
  generated_at timestamptz not null default now(),
  report_payload jsonb not null,
  report_hash text not null,
  created_at timestamptz not null default now(),
  constraint maintenance_runtime_certification_reports_payload_object check (jsonb_typeof(report_payload) = 'object')
);

comment on table public.maintenance_runtime_certification_reports is
'Immutable final reports produced by maintenance runtime end-to-end certification.';

create or replace function public.protect_maintenance_runtime_certification_run_core()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if old.certification_profile_id <> new.certification_profile_id
     or old.idempotency_key <> new.idempotency_key
     or old.requested_by is distinct from new.requested_by
     or old.requested_at <> new.requested_at
     or old.certification_version <> new.certification_version
     or old.request_payload <> new.request_payload
     or old.correlation_id is distinct from new.correlation_id
     or old.causation_id is distinct from new.causation_id
     or old.created_at <> new.created_at then
    raise exception 'maintenance runtime certification run core is immutable';
  end if;
  return new;
end;
$$;

create trigger protect_maintenance_runtime_certification_run_core_trg
before update on public.maintenance_runtime_certification_runs
for each row execute function public.protect_maintenance_runtime_certification_run_core();

create or replace function public.protect_maintenance_runtime_certification_check()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  raise exception 'maintenance runtime certification checks are immutable';
end;
$$;

create trigger protect_maintenance_runtime_certification_check_update_trg
before update on public.maintenance_runtime_certification_checks
for each row execute function public.protect_maintenance_runtime_certification_check();
create trigger protect_maintenance_runtime_certification_check_delete_trg
before delete on public.maintenance_runtime_certification_checks
for each row execute function public.protect_maintenance_runtime_certification_check();

create or replace function public.protect_maintenance_runtime_certification_report()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  raise exception 'maintenance runtime certification reports are immutable';
end;
$$;

create trigger protect_maintenance_runtime_certification_report_update_trg
before update on public.maintenance_runtime_certification_reports
for each row execute function public.protect_maintenance_runtime_certification_report();
create trigger protect_maintenance_runtime_certification_report_delete_trg
before delete on public.maintenance_runtime_certification_reports
for each row execute function public.protect_maintenance_runtime_certification_report();

create or replace function public.request_maintenance_runtime_certification_rpc(
  p_profile_key text,
  p_idempotency_key text,
  p_requested_by uuid,
  p_request_payload jsonb default '{}'::jsonb,
  p_correlation_id uuid default null,
  p_causation_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_profile public.maintenance_runtime_certification_profiles%rowtype;
  v_run_id uuid;
begin
  if nullif(btrim(p_profile_key), '') is null then raise exception 'profile key is required'; end if;
  if nullif(btrim(p_idempotency_key), '') is null then raise exception 'idempotency key is required'; end if;
  if p_request_payload is null or jsonb_typeof(p_request_payload) <> 'object' then raise exception 'request payload must be a JSON object'; end if;

  select * into v_profile
  from public.maintenance_runtime_certification_profiles
  where profile_key = p_profile_key and retired_at is null
  order by profile_version desc limit 1;

  if not found then raise exception 'maintenance runtime certification profile not found: %', p_profile_key; end if;
  if not v_profile.enabled then raise exception 'maintenance runtime certification profile is disabled: %', p_profile_key; end if;

  insert into public.maintenance_runtime_certification_runs(
    certification_profile_id, idempotency_key, requested_by, certification_version,
    request_payload, correlation_id, causation_id
  ) values (
    v_profile.id, p_idempotency_key, p_requested_by, v_profile.certification_version,
    p_request_payload, p_correlation_id, p_causation_id
  )
  on conflict (certification_profile_id, idempotency_key)
  do update set idempotency_key = excluded.idempotency_key
  returning id into v_run_id;

  return v_run_id;
end;
$$;

create or replace function public.validate_maintenance_runtime_certification_dependencies_rpc()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_missing text[] := array[]::text[];
  v_pipeline_validation jsonb;
begin
  if to_regprocedure('public.request_maintenance_run_rpc(text,text,text,uuid,timestamptz,boolean,jsonb,uuid,uuid)') is null then v_missing := array_append(v_missing,'request_maintenance_run_rpc'); end if;
  if to_regprocedure('public.request_retention_plan_rpc(text,text,uuid,interval,integer,jsonb,uuid,uuid)') is null then v_missing := array_append(v_missing,'request_retention_plan_rpc'); end if;
  if to_regprocedure('public.request_runtime_reconciliation_scan_rpc(text,text,uuid,uuid,jsonb,uuid,uuid)') is null then v_missing := array_append(v_missing,'request_runtime_reconciliation_scan_rpc'); end if;
  if to_regprocedure('public.request_health_monitor_run_rpc(text,text,uuid,jsonb,uuid,uuid)') is null then v_missing := array_append(v_missing,'request_health_monitor_run_rpc'); end if;
  if to_regprocedure('public.request_maintenance_scheduler_tick_rpc(text,text,uuid,jsonb,uuid,uuid)') is null then v_missing := array_append(v_missing,'request_maintenance_scheduler_tick_rpc'); end if;
  if to_regprocedure('public.get_runtime_maintenance_pipeline_contract_rpc()') is null then v_missing := array_append(v_missing,'get_runtime_maintenance_pipeline_contract_rpc'); end if;
  if to_regprocedure('public.validate_runtime_maintenance_pipeline_dependencies_rpc()') is null then v_missing := array_append(v_missing,'validate_runtime_maintenance_pipeline_dependencies_rpc'); end if;

  if to_regprocedure('public.validate_runtime_maintenance_pipeline_dependencies_rpc()') is not null then
    v_pipeline_validation := public.validate_runtime_maintenance_pipeline_dependencies_rpc();
  else
    v_pipeline_validation := jsonb_build_object('valid',false,'missing',jsonb_build_array('pipeline validator unavailable'));
  end if;

  return jsonb_build_object(
    'valid', cardinality(v_missing) = 0 and coalesce((v_pipeline_validation->>'valid')::boolean,false),
    'missing', to_jsonb(v_missing),
    'pipeline_validation', v_pipeline_validation
  );
end;
$$;

create or replace function public.get_maintenance_runtime_certification_contract_rpc()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
select jsonb_build_object(
  'contract_version','maintenance-runtime-e2e-v1',
  'covered_migrations',jsonb_build_array(67,68,69,70,71,72,73),
  'covered_engines',jsonb_build_array('maintenance','retention','reconciliation','health_monitor','scheduler','pipeline'),
  'pipeline_stages',jsonb_build_array('scheduler','maintenance','retention','reconciliation','health_monitor'),
  'non_destructive',true,
  'automatic_execution_enabled',false
);
$$;

create or replace function public.build_maintenance_runtime_certification_rpc(
  p_certification_run_id uuid,
  p_evaluation_at timestamptz default now()
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_run public.maintenance_runtime_certification_runs%rowtype;
  v_profile public.maintenance_runtime_certification_profiles%rowtype;
  v_order integer := 0;
  v_expected integer;
  v_actual integer;
  v_result text;
  v_dependencies jsonb;
  v_pipeline_contract jsonb;
  v_stage_array jsonb;
  v_passed integer;
  v_warning integer;
  v_failed integer;
  v_overall text;
  v_report jsonb;
  v_report_hash text;
  v_run_hash text;
  v_service_view_excess integer;
  v_insert record;
begin
  select * into v_run from public.maintenance_runtime_certification_runs where id = p_certification_run_id for update;
  if not found then raise exception 'certification run not found: %', p_certification_run_id; end if;
  if v_run.status = 'completed' then
    select report_payload into v_report from public.maintenance_runtime_certification_reports where certification_run_id = v_run.id;
    return v_report;
  end if;
  if v_run.status not in ('requested','failed') then raise exception 'certification run cannot be built from status %', v_run.status; end if;

  select * into v_profile from public.maintenance_runtime_certification_profiles where id = v_run.certification_profile_id;
  update public.maintenance_runtime_certification_runs
  set status='running', started_at=coalesce(started_at,now()), evaluation_at=p_evaluation_at,
      error_code=null,error_message=null,error_details=null
  where id=v_run.id;

  -- 1: required source tables
  v_order := v_order + 1; v_expected := 24;
  select count(*) into v_actual from pg_class c join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='public' and c.relkind='r' and c.relname = any(array[
    'maintenance_policies','maintenance_runs','maintenance_tasks','maintenance_command_outbox',
    'retention_targets','retention_plans','retention_plan_items','retention_plan_decisions',
    'runtime_reconciliation_profiles','runtime_reconciliation_scans','runtime_reconciliation_findings','runtime_reconciliation_actions',
    'health_monitor_profiles','health_monitor_runs','health_monitor_observations','health_monitor_incidents',
    'maintenance_scheduler_profiles','maintenance_schedules','maintenance_scheduler_ticks','maintenance_scheduler_dispatches',
    'runtime_maintenance_pipeline_profiles','runtime_maintenance_pipeline_runs','runtime_maintenance_pipeline_stages','runtime_maintenance_pipeline_handoffs']);
  v_result := case when v_actual=v_expected then 'passed' else 'failed' end;
  insert into public.maintenance_runtime_certification_checks(certification_run_id,check_order,check_key,check_category,severity,result,expected_value,actual_value,details,check_hash)
  values(v_run.id,v_order,'required-source-tables','structure','critical',v_result,to_jsonb(v_expected),to_jsonb(v_actual),'{}',encode(digest(concat_ws('|',v_run.id,v_order,v_result,v_actual),'sha256'),'hex'));

  -- 2: required source views
  v_order := v_order + 1; v_expected := 10;
  select count(*) into v_actual from pg_class c join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='public' and c.relkind='v' and c.relname = any(array[
    'retention_plan_status_v1','retention_plan_attention_v1',
    'runtime_reconciliation_scan_status_v1','runtime_reconciliation_attention_v1',
    'health_monitor_run_status_v1','health_monitor_attention_v1',
    'maintenance_scheduler_tick_status_v1','maintenance_scheduler_attention_v1',
    'runtime_maintenance_pipeline_run_status_v1','runtime_maintenance_pipeline_attention_v1']);
  v_result := case when v_actual=v_expected then 'passed' else 'failed' end;
  insert into public.maintenance_runtime_certification_checks values(default,v_run.id,v_order,'required-read-models','read_model','error',v_result,to_jsonb(v_expected),to_jsonb(v_actual),'{}',encode(digest(concat_ws('|',v_run.id,v_order,v_result,v_actual),'sha256'),'hex'),default);

  -- 3: dependency validation
  v_order := v_order + 1; v_dependencies := public.validate_maintenance_runtime_certification_dependencies_rpc();
  v_result := case when coalesce((v_dependencies->>'valid')::boolean,false) then 'passed' else 'failed' end;
  insert into public.maintenance_runtime_certification_checks values(default,v_run.id,v_order,'dependency-contracts','dependency','critical',v_result,'true'::jsonb,v_dependencies,jsonb_build_object('validator','validate_maintenance_runtime_certification_dependencies_rpc'),encode(digest(concat_ws('|',v_run.id,v_order,v_result,v_dependencies::text),'sha256'),'hex'),default);

  -- 4: pipeline contract stage order
  v_order := v_order + 1; v_pipeline_contract := public.get_runtime_maintenance_pipeline_contract_rpc();
  v_stage_array := v_pipeline_contract->'stages';
  v_result := case when v_stage_array = to_jsonb(v_profile.expected_pipeline_stages) then 'passed' else 'failed' end;
  insert into public.maintenance_runtime_certification_checks values(default,v_run.id,v_order,'pipeline-stage-order','contract','critical',v_result,to_jsonb(v_profile.expected_pipeline_stages),v_stage_array,jsonb_build_object('pipeline_contract',v_pipeline_contract),encode(digest(concat_ws('|',v_run.id,v_order,v_result,coalesce(v_stage_array::text,'')),'sha256'),'hex'),default);

  -- 5: all source RLS enabled
  v_order := v_order + 1; v_expected := 24;
  select count(*) into v_actual from pg_class c join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='public' and c.relkind='r' and c.relrowsecurity and c.relname = any(array[
    'maintenance_policies','maintenance_runs','maintenance_tasks','maintenance_command_outbox',
    'retention_targets','retention_plans','retention_plan_items','retention_plan_decisions',
    'runtime_reconciliation_profiles','runtime_reconciliation_scans','runtime_reconciliation_findings','runtime_reconciliation_actions',
    'health_monitor_profiles','health_monitor_runs','health_monitor_observations','health_monitor_incidents',
    'maintenance_scheduler_profiles','maintenance_schedules','maintenance_scheduler_ticks','maintenance_scheduler_dispatches',
    'runtime_maintenance_pipeline_profiles','runtime_maintenance_pipeline_runs','runtime_maintenance_pipeline_stages','runtime_maintenance_pipeline_handoffs']);
  v_result := case when v_actual=v_expected then 'passed' else 'failed' end;
  insert into public.maintenance_runtime_certification_checks values(default,v_run.id,v_order,'source-rls-enabled','security','critical',v_result,to_jsonb(v_expected),to_jsonb(v_actual),'{}',encode(digest(concat_ws('|',v_run.id,v_order,v_result,v_actual),'sha256'),'hex'),default);

  -- 6: source policies exist (at least one per table)
  v_order := v_order + 1; v_expected := 24;
  select count(distinct tablename) into v_actual from pg_policies
  where schemaname='public' and tablename = any(array[
    'maintenance_policies','maintenance_runs','maintenance_tasks','maintenance_command_outbox',
    'retention_targets','retention_plans','retention_plan_items','retention_plan_decisions',
    'runtime_reconciliation_profiles','runtime_reconciliation_scans','runtime_reconciliation_findings','runtime_reconciliation_actions',
    'health_monitor_profiles','health_monitor_runs','health_monitor_observations','health_monitor_incidents',
    'maintenance_scheduler_profiles','maintenance_schedules','maintenance_scheduler_ticks','maintenance_scheduler_dispatches',
    'runtime_maintenance_pipeline_profiles','runtime_maintenance_pipeline_runs','runtime_maintenance_pipeline_stages','runtime_maintenance_pipeline_handoffs']);
  v_result := case when v_actual=v_expected then 'passed' else 'failed' end;
  insert into public.maintenance_runtime_certification_checks values(default,v_run.id,v_order,'source-policies-present','security','error',v_result,to_jsonb(v_expected),to_jsonb(v_actual),'{}',encode(digest(concat_ws('|',v_run.id,v_order,v_result,v_actual),'sha256'),'hex'),default);

  -- 7: safety flags disabled
  v_order := v_order + 1;
  select
    (select count(*) from public.maintenance_policies where enabled or automatic_execution_enabled)
    + (select count(*) from public.retention_targets where enabled or automatic_execution_enabled)
    + (select count(*) from public.runtime_reconciliation_profiles where enabled or automatic_remediation_enabled)
    + (select count(*) from public.health_monitor_profiles where enabled or automatic_remediation_enabled)
    + (select count(*) from public.maintenance_scheduler_profiles where enabled or automatic_dispatch_enabled)
    + (select count(*) from public.maintenance_schedules where enabled)
    + (select count(*) from public.maintenance_scheduler_dispatches where dispatch_enabled)
    + (select count(*) from public.runtime_maintenance_pipeline_profiles where enabled or automatic_orchestration_enabled)
    + (select count(*) from public.runtime_maintenance_pipeline_handoffs where invocation_enabled)
  into v_actual;
  v_result := case when v_actual=0 then 'passed' else 'failed' end;
  insert into public.maintenance_runtime_certification_checks values(default,v_run.id,v_order,'automatic-actions-disabled','safety','critical',v_result,'0'::jsonb,to_jsonb(v_actual),'{}',encode(digest(concat_ws('|',v_run.id,v_order,v_result,v_actual),'sha256'),'hex'),default);

  -- 8: service_role read-model grants are SELECT only
  v_order := v_order + 1;
  select count(*) into v_service_view_excess from information_schema.role_table_grants
  where table_schema='public' and grantee='service_role'
    and table_name = any(array[
      'retention_plan_status_v1','retention_plan_attention_v1',
      'runtime_reconciliation_scan_status_v1','runtime_reconciliation_attention_v1',
      'health_monitor_run_status_v1','health_monitor_attention_v1',
      'maintenance_scheduler_tick_status_v1','maintenance_scheduler_attention_v1',
      'runtime_maintenance_pipeline_run_status_v1','runtime_maintenance_pipeline_attention_v1'])
    and privilege_type <> 'SELECT';
  v_result := case when v_service_view_excess=0 then 'passed' else 'failed' end;
  insert into public.maintenance_runtime_certification_checks values(default,v_run.id,v_order,'service-role-view-privileges','security','error',v_result,'0'::jsonb,to_jsonb(v_service_view_excess),'{}',encode(digest(concat_ws('|',v_run.id,v_order,v_result,v_service_view_excess),'sha256'),'hex'),default);

  select count(*) filter(where result='passed'), count(*) filter(where result='warning'), count(*) filter(where result='failed')
  into v_passed,v_warning,v_failed from public.maintenance_runtime_certification_checks where certification_run_id=v_run.id;
  v_overall := case when v_failed>0 then 'failed' when v_warning>0 then 'warning' else 'passed' end;

  select jsonb_build_object(
    'report_version','maintenance-runtime-e2e-report-v1',
    'certification_run_id',v_run.id,
    'certification_version',v_run.certification_version,
    'evaluated_at',p_evaluation_at,
    'overall_result',v_overall,
    'summary',jsonb_build_object('checks',v_passed+v_warning+v_failed,'passed',v_passed,'warnings',v_warning,'failed',v_failed),
    'contract',public.get_maintenance_runtime_certification_contract_rpc(),
    'dependency_validation',v_dependencies,
    'checks',coalesce(jsonb_agg(jsonb_build_object(
      'check_order',c.check_order,'check_key',c.check_key,'category',c.check_category,
      'severity',c.severity,'result',c.result,'expected',c.expected_value,'actual',c.actual_value,'details',c.details,'check_hash',c.check_hash
    ) order by c.check_order),'[]'::jsonb)
  ) into v_report
  from public.maintenance_runtime_certification_checks c where c.certification_run_id=v_run.id;

  v_report_hash := encode(digest(v_report::text,'sha256'),'hex');
  insert into public.maintenance_runtime_certification_reports(certification_run_id,overall_result,generated_at,report_payload,report_hash)
  values(v_run.id,v_overall,p_evaluation_at,v_report,v_report_hash)
  on conflict (certification_run_id) do nothing;

  v_run_hash := encode(digest(concat_ws('|',v_run.id,v_overall,v_report_hash,p_evaluation_at::text),'sha256'),'hex');
  update public.maintenance_runtime_certification_runs
  set status=case when v_overall='failed' then 'failed' else 'completed' end,
      overall_result=v_overall, completed_at=now(), check_count=v_passed+v_warning+v_failed,
      passed_count=v_passed, warning_count=v_warning, failed_count=v_failed,
      run_hash=v_run_hash, certification_snapshot=jsonb_build_object('report_hash',v_report_hash,'non_destructive',true),
      error_code=case when v_overall='failed' then 'CERTIFICATION_FAILED' else null end,
      error_message=case when v_overall='failed' then 'One or more maintenance runtime certification checks failed' else null end
  where id=v_run.id;

  return v_report || jsonb_build_object('report_hash',v_report_hash,'run_hash',v_run_hash);
exception when others then
  update public.maintenance_runtime_certification_runs
  set status='failed', overall_result='failed', completed_at=now(), error_code='CERTIFICATION_BUILD_ERROR',
      error_message=sqlerrm, error_details=jsonb_build_object('sqlstate',sqlstate)
  where id=p_certification_run_id;
  raise;
end;
$$;

create or replace function public.cancel_maintenance_runtime_certification_rpc(
  p_certification_run_id uuid,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_run public.maintenance_runtime_certification_runs%rowtype;
begin
  if nullif(btrim(p_reason),'') is null then raise exception 'cancellation reason is required'; end if;
  select * into v_run from public.maintenance_runtime_certification_runs where id=p_certification_run_id for update;
  if not found then raise exception 'certification run not found: %',p_certification_run_id; end if;
  if v_run.status not in ('requested','running') then raise exception 'certification run cannot be cancelled from status %',v_run.status; end if;
  update public.maintenance_runtime_certification_runs
  set status='cancelled',overall_result='cancelled',completed_at=now(),error_code='CANCELLED',error_message=p_reason
  where id=v_run.id;
  return jsonb_build_object('certification_run_id',v_run.id,'status','cancelled','reason',p_reason);
end;
$$;

create or replace view public.maintenance_runtime_certification_run_status_v1 as
select
  r.id as certification_run_id,
  r.certification_profile_id,
  p.profile_key,
  p.profile_version,
  p.display_name as profile_display_name,
  p.enabled as profile_enabled,
  p.automatic_execution_enabled,
  r.status,
  r.overall_result,
  r.idempotency_key,
  r.requested_by,
  r.requested_at,
  r.started_at,
  r.evaluation_at,
  r.completed_at,
  r.certification_version,
  r.check_count,
  r.passed_count,
  r.warning_count,
  r.failed_count,
  r.run_hash,
  r.request_payload,
  r.certification_snapshot,
  rep.report_hash,
  r.error_code,
  r.error_message,
  r.error_details,
  r.correlation_id,
  r.causation_id,
  r.created_at
from public.maintenance_runtime_certification_runs r
join public.maintenance_runtime_certification_profiles p on p.id=r.certification_profile_id
left join public.maintenance_runtime_certification_reports rep on rep.certification_run_id=r.id;

create or replace view public.maintenance_runtime_certification_attention_v1 as
select
  c.id as certification_check_id,
  c.certification_run_id,
  c.check_order,
  c.check_key,
  c.check_category,
  c.severity,
  c.result,
  c.expected_value,
  c.actual_value,
  c.details,
  c.check_hash,
  c.created_at,
  p.profile_key,
  p.profile_version,
  r.status as certification_run_status,
  r.overall_result,
  r.requested_at,
  case
    when c.result='failed' and c.severity='critical' then 'critical'
    when c.result='failed' then 'high'
    when c.result='warning' then 'medium'
    else 'low'
  end as attention_level,
  c.created_at as attention_reference_at
from public.maintenance_runtime_certification_checks c
join public.maintenance_runtime_certification_runs r on r.id=c.certification_run_id
join public.maintenance_runtime_certification_profiles p on p.id=r.certification_profile_id
where c.result in ('warning','failed');

alter table public.maintenance_runtime_certification_profiles enable row level security;
alter table public.maintenance_runtime_certification_runs enable row level security;
alter table public.maintenance_runtime_certification_checks enable row level security;
alter table public.maintenance_runtime_certification_reports enable row level security;

create policy maintenance_runtime_certification_profiles_service_role_all on public.maintenance_runtime_certification_profiles for all to service_role using (true) with check (true);
create policy maintenance_runtime_certification_runs_service_role_all on public.maintenance_runtime_certification_runs for all to service_role using (true) with check (true);
create policy maintenance_runtime_certification_checks_service_role_all on public.maintenance_runtime_certification_checks for all to service_role using (true) with check (true);
create policy maintenance_runtime_certification_reports_service_role_all on public.maintenance_runtime_certification_reports for all to service_role using (true) with check (true);

revoke all on public.maintenance_runtime_certification_profiles from public, anon, authenticated;
revoke all on public.maintenance_runtime_certification_runs from public, anon, authenticated;
revoke all on public.maintenance_runtime_certification_checks from public, anon, authenticated;
revoke all on public.maintenance_runtime_certification_reports from public, anon, authenticated;
grant all on public.maintenance_runtime_certification_profiles to service_role;
grant all on public.maintenance_runtime_certification_runs to service_role;
grant all on public.maintenance_runtime_certification_checks to service_role;
grant all on public.maintenance_runtime_certification_reports to service_role;

revoke all on public.maintenance_runtime_certification_run_status_v1 from public, anon, authenticated;
revoke all on public.maintenance_runtime_certification_attention_v1 from public, anon, authenticated;
grant select on public.maintenance_runtime_certification_run_status_v1 to service_role;
grant select on public.maintenance_runtime_certification_attention_v1 to service_role;

revoke all on function public.request_maintenance_runtime_certification_rpc(text,text,uuid,jsonb,uuid,uuid) from public, anon, authenticated;
revoke all on function public.build_maintenance_runtime_certification_rpc(uuid,timestamptz) from public, anon, authenticated;
revoke all on function public.cancel_maintenance_runtime_certification_rpc(uuid,text) from public, anon, authenticated;
revoke all on function public.get_maintenance_runtime_certification_contract_rpc() from public, anon, authenticated;
revoke all on function public.validate_maintenance_runtime_certification_dependencies_rpc() from public, anon, authenticated;
grant execute on function public.request_maintenance_runtime_certification_rpc(text,text,uuid,jsonb,uuid,uuid) to service_role;
grant execute on function public.build_maintenance_runtime_certification_rpc(uuid,timestamptz) to service_role;
grant execute on function public.cancel_maintenance_runtime_certification_rpc(uuid,text) to service_role;
grant execute on function public.get_maintenance_runtime_certification_contract_rpc() to service_role;
grant execute on function public.validate_maintenance_runtime_certification_dependencies_rpc() to service_role;

insert into public.maintenance_runtime_certification_profiles(
  profile_key,profile_version,display_name,description,enabled,automatic_execution_enabled,
  certification_version,required_migrations,expected_pipeline_stages,certification_config
) values (
  'maintenance-runtime-e2e',1,'Maintenance Runtime E2E Certification',
  'Disabled-by-default, non-destructive certification profile for migrations 067 through 073.',
  false,false,'maintenance-runtime-e2e-v1',array[67,68,69,70,71,72,73],
  array['scheduler','maintenance','retention','reconciliation','health_monitor'],
  jsonb_build_object('mode','evidence_only','automatic_execution_enabled',false,'non_destructive',true,'source_mutation_allowed',false)
) on conflict (profile_key,profile_version) do nothing;

do $$
begin
  if not exists(select 1 from public.maintenance_runtime_certification_profiles where profile_key='maintenance-runtime-e2e' and profile_version=1) then
    raise exception 'maintenance runtime certification seed missing';
  end if;
  if exists(select 1 from public.maintenance_runtime_certification_profiles where automatic_execution_enabled) then
    raise exception 'automatic certification execution must remain disabled';
  end if;
  if not coalesce((public.validate_maintenance_runtime_certification_dependencies_rpc()->>'valid')::boolean,false) then
    raise exception 'maintenance runtime certification dependencies are invalid: %',public.validate_maintenance_runtime_certification_dependencies_rpc();
  end if;
end;
$$;

commit;
