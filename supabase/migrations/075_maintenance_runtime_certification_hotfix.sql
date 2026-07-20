-- FantaGol migration 075
-- Maintenance Runtime E2E Certification hash and safety contract hotfix
-- Corrects migration 074 without mutating certification evidence or source engines.

begin;

create extension if not exists pgcrypto with schema extensions;

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
  values(v_run.id,v_order,'required-source-tables','structure','critical',v_result,to_jsonb(v_expected),to_jsonb(v_actual),'{}',encode(extensions.digest(concat_ws('|',v_run.id,v_order,v_result,v_actual),'sha256'),'hex'));

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
  insert into public.maintenance_runtime_certification_checks values(default,v_run.id,v_order,'required-read-models','read_model','error',v_result,to_jsonb(v_expected),to_jsonb(v_actual),'{}',encode(extensions.digest(concat_ws('|',v_run.id,v_order,v_result,v_actual),'sha256'),'hex'),default);

  -- 3: dependency validation
  v_order := v_order + 1; v_dependencies := public.validate_maintenance_runtime_certification_dependencies_rpc();
  v_result := case when coalesce((v_dependencies->>'valid')::boolean,false) then 'passed' else 'failed' end;
  insert into public.maintenance_runtime_certification_checks values(default,v_run.id,v_order,'dependency-contracts','dependency','critical',v_result,'true'::jsonb,v_dependencies,jsonb_build_object('validator','validate_maintenance_runtime_certification_dependencies_rpc'),encode(extensions.digest(concat_ws('|',v_run.id,v_order,v_result,v_dependencies::text),'sha256'),'hex'),default);

  -- 4: pipeline contract stage order
  v_order := v_order + 1; v_pipeline_contract := public.get_runtime_maintenance_pipeline_contract_rpc();
  v_stage_array := v_pipeline_contract->'stages';
  v_result := case when v_stage_array = to_jsonb(v_profile.expected_pipeline_stages) then 'passed' else 'failed' end;
  insert into public.maintenance_runtime_certification_checks values(default,v_run.id,v_order,'pipeline-stage-order','contract','critical',v_result,to_jsonb(v_profile.expected_pipeline_stages),v_stage_array,jsonb_build_object('pipeline_contract',v_pipeline_contract),encode(extensions.digest(concat_ws('|',v_run.id,v_order,v_result,coalesce(v_stage_array::text,'')),'sha256'),'hex'),default);

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
  insert into public.maintenance_runtime_certification_checks values(default,v_run.id,v_order,'source-rls-enabled','security','critical',v_result,to_jsonb(v_expected),to_jsonb(v_actual),'{}',encode(extensions.digest(concat_ws('|',v_run.id,v_order,v_result,v_actual),'sha256'),'hex'),default);

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
  insert into public.maintenance_runtime_certification_checks values(default,v_run.id,v_order,'source-policies-present','security','error',v_result,to_jsonb(v_expected),to_jsonb(v_actual),'{}',encode(extensions.digest(concat_ws('|',v_run.id,v_order,v_result,v_actual),'sha256'),'hex'),default);

  -- 7: safety flags disabled
  v_order := v_order + 1;
  select
    (select count(*) from public.maintenance_policies where enabled)
    + (select count(*) from public.retention_targets where planner_enabled or execution_enabled)
    + (select count(*) from public.runtime_reconciliation_profiles where enabled or automatic_remediation_enabled)
    + (select count(*) from public.health_monitor_profiles where enabled or automatic_remediation_enabled)
    + (select count(*) from public.maintenance_scheduler_profiles where enabled or automatic_dispatch_enabled)
    + (select count(*) from public.maintenance_schedules where enabled)
    + (select count(*) from public.maintenance_scheduler_dispatches where dispatch_enabled)
    + (select count(*) from public.runtime_maintenance_pipeline_profiles where enabled or automatic_orchestration_enabled)
    + (select count(*) from public.runtime_maintenance_pipeline_handoffs where invocation_enabled)
  into v_actual;
  v_result := case when v_actual=0 then 'passed' else 'failed' end;
  insert into public.maintenance_runtime_certification_checks values(default,v_run.id,v_order,'automatic-actions-disabled','safety','critical',v_result,'0'::jsonb,to_jsonb(v_actual),'{}',encode(extensions.digest(concat_ws('|',v_run.id,v_order,v_result,v_actual),'sha256'),'hex'),default);

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
  insert into public.maintenance_runtime_certification_checks values(default,v_run.id,v_order,'service-role-view-privileges','security','error',v_result,'0'::jsonb,to_jsonb(v_service_view_excess),'{}',encode(extensions.digest(concat_ws('|',v_run.id,v_order,v_result,v_service_view_excess),'sha256'),'hex'),default);

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

  v_report_hash := encode(extensions.digest(v_report::text,'sha256'),'hex');
  insert into public.maintenance_runtime_certification_reports(certification_run_id,overall_result,generated_at,report_payload,report_hash)
  values(v_run.id,v_overall,p_evaluation_at,v_report,v_report_hash)
  on conflict (certification_run_id) do nothing;

  v_run_hash := encode(extensions.digest(concat_ws('|',v_run.id,v_overall,v_report_hash,p_evaluation_at::text),'sha256'),'hex');
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


-- Default privileges in the deployment environment may grant non-SELECT
-- privileges on newly created views to service_role. Reassert the intended
-- read-only contract for the 074 read models.
revoke all on public.maintenance_runtime_certification_run_status_v1 from service_role;
revoke all on public.maintenance_runtime_certification_attention_v1 from service_role;
grant select on public.maintenance_runtime_certification_run_status_v1 to service_role;
grant select on public.maintenance_runtime_certification_attention_v1 to service_role;

do $$
declare
  v_definition text;
begin
  select pg_get_functiondef(
    'public.build_maintenance_runtime_certification_rpc(uuid,timestamptz)'::regprocedure
  ) into v_definition;

  if position('extensions.digest' in v_definition) = 0 then
    raise exception '075 hotfix validation failed: extensions.digest is not present';
  end if;

  if position('maintenance_policies where enabled or automatic_execution_enabled' in v_definition) > 0 then
    raise exception '075 hotfix validation failed: invalid maintenance safety columns remain';
  end if;

  if position('retention_targets where enabled or automatic_execution_enabled' in v_definition) > 0 then
    raise exception '075 hotfix validation failed: invalid retention safety columns remain';
  end if;

  if exists (
    select 1
    from information_schema.role_table_grants
    where table_schema = 'public'
      and table_name in (
        'maintenance_runtime_certification_run_status_v1',
        'maintenance_runtime_certification_attention_v1'
      )
      and grantee = 'service_role'
      and privilege_type <> 'SELECT'
  ) then
    raise exception '075 hotfix validation failed: service_role has excessive 074 view privileges';
  end if;
end;
$$;

commit;
