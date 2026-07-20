-- ============================================================================
-- FANTAGOL
-- Migration 087: Platform Readiness Engine
-- Phase 8.4.5
--
-- Purpose
--   Evaluate the operational readiness of the FantaGol platform through
--   deterministic, explainable and durable readiness assessments. The engine
--   consolidates registry, governance, supervision, incidents,
--   recommendations and safety-policy evidence into a single snapshot.
--
-- Safety
--   This engine is observational and non-authoritative. It never dispatches
--   jobs, creates orchestrator actions, mutates findings/incidents/
--   recommendations, changes platform configuration or executes remediation.
--   A READY result is decision support only and is not an execution permit.
-- ============================================================================

begin;

-- --------------------------------------------------------------------------
-- 1. Engine registration and dependencies
-- --------------------------------------------------------------------------

insert into public.platform_engine_registry (
  engine_code,engine_name,engine_version,engine_kind,lifecycle_status,
  runtime_enabled,is_certified,certification_version,certified_at,
  owner_scope,installation_order,dependencies,metadata
)
values (
  'platform_readiness_engine','Platform Readiness Engine','1.0.0',
  'governance','active',true,false,null,null,'platform',160,
  '["platform_governance_engine","platform_supervision_engine","platform_incident_correlation_engine","platform_recommendation_engine"]'::jsonb,
  jsonb_build_object(
    'phase','8.4.5','contract','platform-readiness-assessment-v1',
    'migration',87,'evaluation_mode','explicit-deterministic',
    'explainable',true,'authorizes_execution',false,
    'automatic_remediation',false
  )
)
on conflict (engine_code) do update
set engine_name=excluded.engine_name,
    engine_version=excluded.engine_version,
    engine_kind=excluded.engine_kind,
    lifecycle_status=excluded.lifecycle_status,
    runtime_enabled=excluded.runtime_enabled,
    is_certified=excluded.is_certified,
    certification_version=excluded.certification_version,
    certified_at=excluded.certified_at,
    owner_scope=excluded.owner_scope,
    installation_order=excluded.installation_order,
    dependencies=excluded.dependencies,
    metadata=public.platform_engine_registry.metadata || excluded.metadata,
    updated_at=now();

insert into public.platform_engine_dependencies (
  dependent_engine_code,dependency_engine_code,dependency_type,minimum_version,
  requires_runtime_enabled,requires_certification,allowed_dependency_statuses,
  enabled,rationale,metadata
)
values
  (
    'platform_readiness_engine','platform_governance_engine','required','1.0.0',
    true,true,array['active','degraded']::text[],true,
    'Readiness requires the certified platform governance contract and registry.',
    '{"migration":87}'::jsonb
  ),
  (
    'platform_readiness_engine','platform_supervision_engine','runtime','1.0.0',
    true,false,array['active','degraded']::text[],true,
    'Operational findings are direct readiness evidence.',
    '{"migration":87}'::jsonb
  ),
  (
    'platform_readiness_engine','platform_incident_correlation_engine','runtime','1.0.0',
    true,false,array['active','degraded']::text[],true,
    'Correlated incidents determine blocking operational conditions.',
    '{"migration":87}'::jsonb
  ),
  (
    'platform_readiness_engine','platform_recommendation_engine','runtime','1.0.0',
    true,false,array['active','degraded']::text[],true,
    'Active recommendations expose unresolved operator decisions.',
    '{"migration":87}'::jsonb
  )
on conflict (dependent_engine_code,dependency_engine_code) do update
set dependency_type=excluded.dependency_type,
    minimum_version=excluded.minimum_version,
    requires_runtime_enabled=excluded.requires_runtime_enabled,
    requires_certification=excluded.requires_certification,
    allowed_dependency_statuses=excluded.allowed_dependency_statuses,
    enabled=excluded.enabled,
    rationale=excluded.rationale,
    metadata=public.platform_engine_dependencies.metadata || excluded.metadata,
    updated_at=now();

-- --------------------------------------------------------------------------
-- 2. Durable readiness assessments
-- --------------------------------------------------------------------------

create table if not exists public.platform_readiness_assessments (
  readiness_assessment_id uuid primary key default gen_random_uuid(),
  assessment_sequence bigint generated always as identity unique,
  contract_version text not null default 'platform-readiness-assessment-v1',
  readiness_status text not null,
  readiness_score numeric(5,2) not null,
  blocking_check_count integer not null default 0,
  degraded_check_count integer not null default 0,
  passed_check_count integer not null default 0,
  total_check_count integer not null,
  source text not null,
  correlation_id uuid not null default gen_random_uuid(),
  evaluated_at timestamptz not null default now(),
  summary text not null,
  blocking_reasons jsonb not null default '[]'::jsonb,
  evidence_summary jsonb not null default '{}'::jsonb,
  decision_context jsonb not null default '{}'::jsonb,
  authorizes_execution boolean not null default false,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),

  constraint platform_readiness_assessment_contract_ck
    check (contract_version='platform-readiness-assessment-v1'),
  constraint platform_readiness_assessment_status_ck
    check (readiness_status in ('ready','degraded','blocked')),
  constraint platform_readiness_assessment_score_ck
    check (readiness_score >= 0 and readiness_score <= 100),
  constraint platform_readiness_assessment_counts_ck
    check (
      blocking_check_count >= 0 and degraded_check_count >= 0
      and passed_check_count >= 0 and total_check_count > 0
      and blocking_check_count + degraded_check_count + passed_check_count = total_check_count
    ),
  constraint platform_readiness_assessment_source_ck
    check (btrim(source)<>''),
  constraint platform_readiness_assessment_summary_ck
    check (btrim(summary)<>''),
  constraint platform_readiness_assessment_reasons_ck
    check (jsonb_typeof(blocking_reasons)='array'),
  constraint platform_readiness_assessment_evidence_ck
    check (jsonb_typeof(evidence_summary)='object'),
  constraint platform_readiness_assessment_context_ck
    check (jsonb_typeof(decision_context)='object'),
  constraint platform_readiness_assessment_metadata_ck
    check (jsonb_typeof(metadata)='object'),
  constraint platform_readiness_assessment_safety_ck
    check (authorizes_execution=false),
  constraint platform_readiness_assessment_semantics_ck
    check (
      (readiness_status='ready' and blocking_check_count=0 and degraded_check_count=0)
      or (readiness_status='degraded' and blocking_check_count=0 and degraded_check_count>0)
      or (readiness_status='blocked' and blocking_check_count>0)
    )
);

create index if not exists platform_readiness_assessments_status_idx
  on public.platform_readiness_assessments(readiness_status,evaluated_at desc);
create index if not exists platform_readiness_assessments_correlation_idx
  on public.platform_readiness_assessments(correlation_id);

comment on table public.platform_readiness_assessments is
  'Immutable, explainable platform readiness snapshots. READY is not an execution authorization.';

-- --------------------------------------------------------------------------
-- 3. Immutable assessment checks
-- --------------------------------------------------------------------------

create table if not exists public.platform_readiness_checks (
  readiness_check_id uuid primary key default gen_random_uuid(),
  check_sequence bigint generated always as identity unique,
  contract_version text not null default 'platform-readiness-check-v1',
  readiness_assessment_id uuid not null,
  check_key text not null,
  check_category text not null,
  check_status text not null,
  severity text not null,
  title text not null,
  description text not null,
  observed_value jsonb not null default 'null'::jsonb,
  expected_value jsonb not null default 'null'::jsonb,
  evidence jsonb not null default '{}'::jsonb,
  blocking boolean not null default false,
  remediation_hint text,
  evaluated_at timestamptz not null default now(),
  metadata jsonb not null default '{}'::jsonb,

  constraint platform_readiness_checks_contract_ck
    check (contract_version='platform-readiness-check-v1'),
  constraint platform_readiness_checks_key_ck
    check (check_key ~ '^[a-z][a-z0-9_.:-]*$'),
  constraint platform_readiness_checks_category_ck
    check (check_category in (
      'configuration','governance','engine_registry','supervision',
      'incident','recommendation','safety','orchestrator'
    )),
  constraint platform_readiness_checks_status_ck
    check (check_status in ('passed','degraded','failed')),
  constraint platform_readiness_checks_severity_ck
    check (severity in ('info','warning','critical')),
  constraint platform_readiness_checks_text_ck
    check (btrim(title)<>'' and btrim(description)<>''),
  constraint platform_readiness_checks_evidence_ck
    check (jsonb_typeof(evidence)='object'),
  constraint platform_readiness_checks_metadata_ck
    check (jsonb_typeof(metadata)='object'),
  constraint platform_readiness_checks_blocking_ck
    check ((blocking and check_status='failed') or not blocking),
  constraint platform_readiness_checks_assessment_fk
    foreign key (readiness_assessment_id)
      references public.platform_readiness_assessments(readiness_assessment_id)
      on delete restrict,
  constraint platform_readiness_checks_assessment_key_uq
    unique (readiness_assessment_id,check_key)
);

create index if not exists platform_readiness_checks_assessment_idx
  on public.platform_readiness_checks(readiness_assessment_id,check_sequence);
create index if not exists platform_readiness_checks_status_idx
  on public.platform_readiness_checks(check_status,severity,blocking);

comment on table public.platform_readiness_checks is
  'Immutable evidence-backed checks belonging to a readiness assessment.';

-- --------------------------------------------------------------------------
-- 4. Immutable readiness timeline
-- --------------------------------------------------------------------------

create table if not exists public.platform_readiness_timeline (
  readiness_timeline_event_id uuid primary key default gen_random_uuid(),
  event_sequence bigint generated always as identity unique,
  contract_version text not null default 'platform-readiness-timeline-v1',
  event_type text not null,
  event_status text not null default 'completed',
  readiness_status text not null,
  occurred_at timestamptz not null default now(),
  readiness_assessment_id uuid not null,
  correlation_id uuid not null,
  summary text not null,
  details jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,

  constraint platform_readiness_timeline_contract_ck
    check (contract_version='platform-readiness-timeline-v1'),
  constraint platform_readiness_timeline_type_ck
    check (event_type in ('readiness_evaluated','readiness_ready','readiness_degraded','readiness_blocked')),
  constraint platform_readiness_timeline_event_status_ck
    check (event_status in ('recorded','completed','failed')),
  constraint platform_readiness_timeline_readiness_status_ck
    check (readiness_status in ('ready','degraded','blocked')),
  constraint platform_readiness_timeline_summary_ck
    check (btrim(summary)<>''),
  constraint platform_readiness_timeline_details_ck
    check (jsonb_typeof(details)='object'),
  constraint platform_readiness_timeline_metadata_ck
    check (jsonb_typeof(metadata)='object'),
  constraint platform_readiness_timeline_assessment_fk
    foreign key (readiness_assessment_id)
      references public.platform_readiness_assessments(readiness_assessment_id)
      on delete restrict
);

create index if not exists platform_readiness_timeline_assessment_idx
  on public.platform_readiness_timeline(readiness_assessment_id,event_sequence);
create index if not exists platform_readiness_timeline_status_idx
  on public.platform_readiness_timeline(readiness_status,occurred_at desc);

comment on table public.platform_readiness_timeline is
  'Append-only timeline of platform readiness outcomes.';

-- --------------------------------------------------------------------------
-- 5. Immutability guards
-- --------------------------------------------------------------------------

create or replace function public.protect_platform_readiness_immutable_row()
returns trigger
language plpgsql
security definer
set search_path=public,pg_temp
as $function$
begin
  if tg_table_name='platform_readiness_assessments'
     and tg_op='UPDATE'
     and coalesce(current_setting('fantagol.allow_readiness_finalize',true),'off')='on' then
    return new;
  end if;

  raise exception 'PLATFORM_READINESS_IMMUTABLE_ROW: %.%',tg_table_schema,tg_table_name
    using errcode='55000';
end;
$function$;

create or replace function public.protect_platform_readiness_assessment_identity()
returns trigger
language plpgsql
security definer
set search_path=public,pg_temp
as $function$
begin
  if new.readiness_assessment_id<>old.readiness_assessment_id
     or new.assessment_sequence<>old.assessment_sequence
     or new.contract_version<>old.contract_version
     or new.correlation_id<>old.correlation_id
     or new.evaluated_at<>old.evaluated_at
     or new.created_at<>old.created_at then
    raise exception 'PLATFORM_READINESS_ASSESSMENT_IDENTITY_IMMUTABLE'
      using errcode='55000';
  end if;
  return new;
end;
$function$;

-- Assessments are complete snapshots and therefore immutable after insert.
drop trigger if exists trg_protect_platform_readiness_assessments on public.platform_readiness_assessments;
create trigger trg_protect_platform_readiness_assessments
before update or delete on public.platform_readiness_assessments
for each row execute function public.protect_platform_readiness_immutable_row();

drop trigger if exists trg_protect_platform_readiness_checks on public.platform_readiness_checks;
create trigger trg_protect_platform_readiness_checks
before update or delete on public.platform_readiness_checks
for each row execute function public.protect_platform_readiness_immutable_row();

drop trigger if exists trg_protect_platform_readiness_timeline on public.platform_readiness_timeline;
create trigger trg_protect_platform_readiness_timeline
before update or delete on public.platform_readiness_timeline
for each row execute function public.protect_platform_readiness_immutable_row();

-- --------------------------------------------------------------------------
-- 6. Deterministic readiness evaluator
-- --------------------------------------------------------------------------

create or replace function public.evaluate_platform_readiness_rpc(
  p_source text default 'manual',
  p_correlation_id uuid default gen_random_uuid()
)
returns jsonb
language plpgsql
security definer
set search_path=public,pg_temp
as $function$
declare
  v_started_at timestamptz:=clock_timestamp();
  v_evaluated_at timestamptz:=now();
  v_assessment_id uuid:=gen_random_uuid();
  v_source text:=btrim(coalesce(p_source,''));
  v_correlation_id uuid:=coalesce(p_correlation_id,gen_random_uuid());
  v_configuration_version integer:=0;
  v_required_engines integer:=0;
  v_invalid_required_engines integer:=0;
  v_critical_findings integer:=0;
  v_warning_findings integer:=0;
  v_critical_incidents integer:=0;
  v_warning_incidents integer:=0;
  v_urgent_recommendations integer:=0;
  v_high_recommendations integer:=0;
  v_auto_execution_safe boolean:=false;
  v_human_approval_safe boolean:=false;
  v_orchestrator_actions_before bigint:=0;
  v_blocking integer:=0;
  v_degraded integer:=0;
  v_passed integer:=0;
  v_total integer:=8;
  v_score numeric(5,2);
  v_status text;
  v_summary text;
  v_blocking_reasons jsonb:='[]'::jsonb;
  v_duration_ms integer;
begin
  if v_source='' then
    raise exception 'PLATFORM_READINESS_SOURCE_REQUIRED' using errcode='22023';
  end if;

  select coalesce(max(schema_version),0)
    into v_configuration_version
  from public.platform_configuration
  where configuration_key='primary';

  select count(*),
         count(*) filter (
           where not r.runtime_enabled
              or r.lifecycle_status not in ('active','degraded')
              or (d.requires_certification and not r.is_certified)
         )
    into v_required_engines,v_invalid_required_engines
  from public.platform_engine_dependencies d
  join public.platform_engine_registry r
    on r.engine_code=d.dependency_engine_code
  where d.dependent_engine_code='platform_readiness_engine'
    and d.enabled;

  select
    count(*) filter (where finding_status in ('open','acknowledged') and severity='critical'),
    count(*) filter (where finding_status in ('open','acknowledged') and severity='warning')
    into v_critical_findings,v_warning_findings
  from public.platform_operational_findings;

  select
    count(*) filter (where incident_status in ('open','acknowledged') and severity='critical'),
    count(*) filter (where incident_status in ('open','acknowledged') and severity='warning')
    into v_critical_incidents,v_warning_incidents
  from public.platform_operational_incidents;

  select
    count(*) filter (
      where recommendation_status in ('proposed','accepted') and priority='urgent'
    ),
    count(*) filter (
      where recommendation_status in ('proposed','accepted') and priority='high'
    )
    into v_urgent_recommendations,v_high_recommendations
  from public.platform_operational_recommendations;

  select exists(
    select 1 from public.platform_runtime_policies
    where policy_key='runtime.recommendations.automatic_execution'
      and enabled and policy_value='false'::jsonb
  ) into v_auto_execution_safe;

  select exists(
    select 1 from public.platform_runtime_policies
    where policy_key='runtime.recommendations.human_approval_required'
      and enabled and policy_value='true'::jsonb
  ) into v_human_approval_safe;

  select count(*) into v_orchestrator_actions_before
  from public.platform_orchestrator_actions;

  insert into public.platform_readiness_assessments(
    readiness_assessment_id,readiness_status,readiness_score,
    blocking_check_count,degraded_check_count,passed_check_count,total_check_count,
    source,correlation_id,evaluated_at,summary,blocking_reasons,
    evidence_summary,decision_context,authorizes_execution,metadata
  ) values (
    v_assessment_id,'blocked',0,1,0,7,v_total,
    v_source,v_correlation_id,v_evaluated_at,
    'Readiness assessment is being assembled.',
    '["assessment_pending"]'::jsonb,
    '{}'::jsonb,
    jsonb_build_object('evaluator_version','1.0.0','source',v_source),
    false,'{"migration":87}'::jsonb
  );

  -- Check 1: configuration version.
  insert into public.platform_readiness_checks(
    readiness_assessment_id,check_key,check_category,check_status,severity,
    title,description,observed_value,expected_value,evidence,blocking,remediation_hint,metadata
  ) values (
    v_assessment_id,'configuration.schema_version','configuration',
    case when v_configuration_version>=86 then 'passed' else 'failed' end,
    case when v_configuration_version>=86 then 'info' else 'critical' end,
    'Platform configuration schema version',
    'The platform configuration must include all prerequisites through migration 086.',
    to_jsonb(v_configuration_version),to_jsonb(86),
    jsonb_build_object('configuration_key','primary'),
    v_configuration_version<86,
    case when v_configuration_version<86 then 'Apply and certify all migrations through 086.' end,
    '{"migration":87}'::jsonb
  );

  -- Check 2: readiness dependencies.
  insert into public.platform_readiness_checks(
    readiness_assessment_id,check_key,check_category,check_status,severity,
    title,description,observed_value,expected_value,evidence,blocking,remediation_hint,metadata
  ) values (
    v_assessment_id,'governance.dependencies','governance',
    case when v_required_engines=4 and v_invalid_required_engines=0 then 'passed' else 'failed' end,
    case when v_required_engines=4 and v_invalid_required_engines=0 then 'info' else 'critical' end,
    'Readiness dependency contract',
    'All declared readiness dependencies must exist and satisfy runtime/certification requirements.',
    jsonb_build_object('declared',v_required_engines,'invalid',v_invalid_required_engines),
    jsonb_build_object('declared',4,'invalid',0),
    jsonb_build_object('dependent_engine_code','platform_readiness_engine'),
    not(v_required_engines=4 and v_invalid_required_engines=0),
    case when not(v_required_engines=4 and v_invalid_required_engines=0)
      then 'Restore required engine registrations, runtime state or certification.' end,
    '{"migration":87}'::jsonb
  );

  -- Check 3: active critical findings.
  insert into public.platform_readiness_checks(
    readiness_assessment_id,check_key,check_category,check_status,severity,
    title,description,observed_value,expected_value,evidence,blocking,remediation_hint,metadata
  ) values (
    v_assessment_id,'supervision.critical_findings','supervision',
    case when v_critical_findings=0 then 'passed' else 'failed' end,
    case when v_critical_findings=0 then 'info' else 'critical' end,
    'Active critical supervision findings',
    'No open or acknowledged critical supervision finding may remain for READY status.',
    to_jsonb(v_critical_findings),to_jsonb(0),
    jsonb_build_object('warning_findings',v_warning_findings),
    v_critical_findings>0,
    case when v_critical_findings>0 then 'Resolve or explicitly close the underlying critical findings.' end,
    '{"migration":87}'::jsonb
  );

  -- Check 4: active critical incidents.
  insert into public.platform_readiness_checks(
    readiness_assessment_id,check_key,check_category,check_status,severity,
    title,description,observed_value,expected_value,evidence,blocking,remediation_hint,metadata
  ) values (
    v_assessment_id,'incident.critical_active','incident',
    case when v_critical_incidents=0 then 'passed' else 'failed' end,
    case when v_critical_incidents=0 then 'info' else 'critical' end,
    'Active critical operational incidents',
    'No open or acknowledged critical incident may remain for READY status.',
    to_jsonb(v_critical_incidents),to_jsonb(0),
    jsonb_build_object('warning_incidents',v_warning_incidents),
    v_critical_incidents>0,
    case when v_critical_incidents>0 then 'Investigate and resolve the critical operational incidents.' end,
    '{"migration":87}'::jsonb
  );

  -- Check 5: urgent recommendations.
  insert into public.platform_readiness_checks(
    readiness_assessment_id,check_key,check_category,check_status,severity,
    title,description,observed_value,expected_value,evidence,blocking,remediation_hint,metadata
  ) values (
    v_assessment_id,'recommendation.urgent_active','recommendation',
    case when v_urgent_recommendations=0 then 'passed' else 'failed' end,
    case when v_urgent_recommendations=0 then 'info' else 'critical' end,
    'Active urgent operational recommendations',
    'Urgent proposed or accepted recommendations represent unresolved blocking decisions.',
    to_jsonb(v_urgent_recommendations),to_jsonb(0),
    jsonb_build_object('high_recommendations',v_high_recommendations),
    v_urgent_recommendations>0,
    case when v_urgent_recommendations>0 then 'Review the urgent recommendations and resolve their source incidents.' end,
    '{"migration":87}'::jsonb
  );

  -- Check 6: automatic execution disabled.
  insert into public.platform_readiness_checks(
    readiness_assessment_id,check_key,check_category,check_status,severity,
    title,description,observed_value,expected_value,evidence,blocking,remediation_hint,metadata
  ) values (
    v_assessment_id,'safety.automatic_execution_disabled','safety',
    case when v_auto_execution_safe then 'passed' else 'failed' end,
    case when v_auto_execution_safe then 'info' else 'critical' end,
    'Automatic recommendation execution disabled',
    'The recommendation layer must remain non-executing.',
    to_jsonb(v_auto_execution_safe),to_jsonb(true),
    jsonb_build_object('policy_key','runtime.recommendations.automatic_execution'),
    not v_auto_execution_safe,
    case when not v_auto_execution_safe then 'Restore automatic_execution=false and enable the safety policy.' end,
    '{"migration":87}'::jsonb
  );

  -- Check 7: human approval required.
  insert into public.platform_readiness_checks(
    readiness_assessment_id,check_key,check_category,check_status,severity,
    title,description,observed_value,expected_value,evidence,blocking,remediation_hint,metadata
  ) values (
    v_assessment_id,'safety.human_approval_required','safety',
    case when v_human_approval_safe then 'passed' else 'failed' end,
    case when v_human_approval_safe then 'info' else 'critical' end,
    'Human approval safety policy',
    'Operational recommendations must continue to require explicit human or service approval.',
    to_jsonb(v_human_approval_safe),to_jsonb(true),
    jsonb_build_object('policy_key','runtime.recommendations.human_approval_required'),
    not v_human_approval_safe,
    case when not v_human_approval_safe then 'Restore and enable the human approval policy.' end,
    '{"migration":87}'::jsonb
  );

  -- Check 8: warnings produce degraded readiness, not a hard block.
  insert into public.platform_readiness_checks(
    readiness_assessment_id,check_key,check_category,check_status,severity,
    title,description,observed_value,expected_value,evidence,blocking,remediation_hint,metadata
  ) values (
    v_assessment_id,'operations.warning_evidence','supervision',
    case when (v_warning_findings+v_warning_incidents+v_high_recommendations)=0
      then 'passed' else 'degraded' end,
    case when (v_warning_findings+v_warning_incidents+v_high_recommendations)=0
      then 'info' else 'warning' end,
    'Non-critical operational evidence',
    'Warning findings, warning incidents or high-priority recommendations degrade readiness.',
    jsonb_build_object(
      'warning_findings',v_warning_findings,
      'warning_incidents',v_warning_incidents,
      'high_recommendations',v_high_recommendations
    ),
    jsonb_build_object(
      'warning_findings',0,'warning_incidents',0,'high_recommendations',0
    ),
    '{}'::jsonb,false,
    case when (v_warning_findings+v_warning_incidents+v_high_recommendations)>0
      then 'Review non-critical operational evidence before critical execution.' end,
    '{"migration":87}'::jsonb
  );

  select
    count(*) filter(where check_status='failed' and blocking),
    count(*) filter(where check_status='degraded'),
    count(*) filter(where check_status='passed')
  into v_blocking,v_degraded,v_passed
  from public.platform_readiness_checks
  where readiness_assessment_id=v_assessment_id;

  v_status:=case
    when v_blocking>0 then 'blocked'
    when v_degraded>0 then 'degraded'
    else 'ready'
  end;

  v_score:=round(
    greatest(0::numeric,
      ((v_passed::numeric + (v_degraded::numeric * 0.5)) / v_total::numeric) * 100
    ),2
  );

  select coalesce(jsonb_agg(jsonb_build_object(
    'check_key',check_key,'title',title,'observed_value',observed_value,
    'remediation_hint',remediation_hint
  ) order by check_sequence),'[]'::jsonb)
  into v_blocking_reasons
  from public.platform_readiness_checks
  where readiness_assessment_id=v_assessment_id
    and blocking and check_status='failed';

  v_summary:=case v_status
    when 'ready' then 'Platform readiness checks passed without blocking or degraded evidence.'
    when 'degraded' then 'Platform is operationally degraded and requires review before critical execution.'
    else 'Platform readiness is blocked by one or more critical operational conditions.'
  end;

  -- Permit one controlled finalization update inside this transaction only.
  perform set_config('fantagol.allow_readiness_finalize','on',true);

  update public.platform_readiness_assessments
  set readiness_status=v_status,
      readiness_score=v_score,
      blocking_check_count=v_blocking,
      degraded_check_count=v_degraded,
      passed_check_count=v_passed,
      total_check_count=v_total,
      summary=v_summary,
      blocking_reasons=v_blocking_reasons,
      evidence_summary=jsonb_build_object(
        'configuration_schema_version',v_configuration_version,
        'required_engines',v_required_engines,
        'invalid_required_engines',v_invalid_required_engines,
        'critical_findings',v_critical_findings,
        'warning_findings',v_warning_findings,
        'critical_incidents',v_critical_incidents,
        'warning_incidents',v_warning_incidents,
        'urgent_recommendations',v_urgent_recommendations,
        'high_recommendations',v_high_recommendations,
        'orchestrator_actions_observed',v_orchestrator_actions_before
      ),
      decision_context=jsonb_build_object(
        'evaluator_version','1.0.0',
        'source',v_source,
        'readiness_is_execution_authorization',false,
        'automatic_remediation',false
      )
  where readiness_assessment_id=v_assessment_id;

  perform set_config('fantagol.allow_readiness_finalize','off',true);

  insert into public.platform_readiness_timeline(
    event_type,event_status,readiness_status,occurred_at,
    readiness_assessment_id,correlation_id,summary,details,metadata
  ) values (
    'readiness_evaluated','completed',v_status,v_evaluated_at,
    v_assessment_id,v_correlation_id,'Platform readiness evaluation completed.',
    jsonb_build_object(
      'readiness_score',v_score,
      'blocking_check_count',v_blocking,
      'degraded_check_count',v_degraded,
      'passed_check_count',v_passed,
      'total_check_count',v_total,
      'source',v_source
    ),'{"migration":87}'::jsonb
  );

  insert into public.platform_readiness_timeline(
    event_type,event_status,readiness_status,occurred_at,
    readiness_assessment_id,correlation_id,summary,details,metadata
  ) values (
    case v_status
      when 'ready' then 'readiness_ready'
      when 'degraded' then 'readiness_degraded'
      else 'readiness_blocked'
    end,
    'recorded',v_status,v_evaluated_at,
    v_assessment_id,v_correlation_id,v_summary,
    jsonb_build_object('blocking_reasons',v_blocking_reasons),
    '{"migration":87}'::jsonb
  );

  v_duration_ms:=greatest(0,round(extract(epoch from (clock_timestamp()-v_started_at))*1000)::integer);

  return jsonb_build_object(
    'contract_version','platform-readiness-evaluation-v1',
    'readiness_assessment_id',v_assessment_id,
    'assessment_sequence',(select assessment_sequence from public.platform_readiness_assessments where readiness_assessment_id=v_assessment_id),
    'readiness_status',v_status,
    'readiness_score',v_score,
    'blocking_check_count',v_blocking,
    'degraded_check_count',v_degraded,
    'passed_check_count',v_passed,
    'total_check_count',v_total,
    'authorizes_execution',false,
    'source',v_source,
    'correlation_id',v_correlation_id,
    'duration_ms',v_duration_ms
  );
exception when others then
  perform set_config('fantagol.allow_readiness_finalize','off',true);
  raise;
end;
$function$;

-- --------------------------------------------------------------------------
-- 7. Read models
-- --------------------------------------------------------------------------

create or replace function public.get_platform_readiness_assessments_rpc(
  p_status text default null,
  p_limit integer default 100
)
returns jsonb
language sql
stable
security definer
set search_path=public,pg_temp
as $function$
  select coalesce(jsonb_agg(to_jsonb(a) order by a.assessment_sequence desc),'[]'::jsonb)
  from (
    select * from public.platform_readiness_assessments
    where p_status is null or readiness_status=p_status
    order by assessment_sequence desc
    limit greatest(1,least(coalesce(p_limit,100),500))
  ) a;
$function$;

create or replace function public.get_platform_readiness_latest_assessment_rpc()
returns jsonb
language sql
stable
security definer
set search_path=public,pg_temp
as $function$
  select case when a.readiness_assessment_id is null then null else
    to_jsonb(a) || jsonb_build_object(
      'checks',coalesce((select jsonb_agg(to_jsonb(c) order by c.check_sequence)
        from public.platform_readiness_checks c
        where c.readiness_assessment_id=a.readiness_assessment_id),'[]'::jsonb),
      'timeline',coalesce((select jsonb_agg(to_jsonb(t) order by t.event_sequence)
        from public.platform_readiness_timeline t
        where t.readiness_assessment_id=a.readiness_assessment_id),'[]'::jsonb)
    ) end
  from (
    select * from public.platform_readiness_assessments
    order by assessment_sequence desc limit 1
  ) a;
$function$;

create or replace function public.get_platform_readiness_assessment_rpc(
  p_readiness_assessment_id uuid
)
returns jsonb
language sql
stable
security definer
set search_path=public,pg_temp
as $function$
  select to_jsonb(a) || jsonb_build_object(
    'checks',coalesce((select jsonb_agg(to_jsonb(c) order by c.check_sequence)
      from public.platform_readiness_checks c
      where c.readiness_assessment_id=a.readiness_assessment_id),'[]'::jsonb),
    'timeline',coalesce((select jsonb_agg(to_jsonb(t) order by t.event_sequence)
      from public.platform_readiness_timeline t
      where t.readiness_assessment_id=a.readiness_assessment_id),'[]'::jsonb)
  )
  from public.platform_readiness_assessments a
  where a.readiness_assessment_id=p_readiness_assessment_id;
$function$;

create or replace function public.get_platform_readiness_timeline_rpc(
  p_readiness_assessment_id uuid default null,
  p_readiness_status text default null,
  p_limit integer default 100
)
returns jsonb
language sql
stable
security definer
set search_path=public,pg_temp
as $function$
  select coalesce(jsonb_agg(to_jsonb(t) order by t.event_sequence desc),'[]'::jsonb)
  from (
    select * from public.platform_readiness_timeline
    where (p_readiness_assessment_id is null or readiness_assessment_id=p_readiness_assessment_id)
      and (p_readiness_status is null or readiness_status=p_readiness_status)
    order by event_sequence desc
    limit greatest(1,least(coalesce(p_limit,100),500))
  ) t;
$function$;

create or replace function public.get_platform_readiness_health_rpc()
returns jsonb
language sql
stable
security definer
set search_path=public,pg_temp
as $function$
  select jsonb_build_object(
    'contract_version','platform-readiness-health-v1',
    'generated_at',now(),
    'latest_assessment',public.get_platform_readiness_latest_assessment_rpc(),
    'history',jsonb_build_object(
      'assessment_count',(select count(*) from public.platform_readiness_assessments),
      'check_count',(select count(*) from public.platform_readiness_checks),
      'timeline_event_count',(select count(*) from public.platform_readiness_timeline)
    ),
    'controls',jsonb_build_object(
      'deterministic_evaluation',true,
      'explainable',true,
      'authorizes_execution',false,
      'automatic_remediation',false,
      'orchestrator_dispatch',false
    )
  );
$function$;

-- --------------------------------------------------------------------------
-- 8. RLS and privileges
-- --------------------------------------------------------------------------

alter table public.platform_readiness_assessments enable row level security;
alter table public.platform_readiness_checks enable row level security;
alter table public.platform_readiness_timeline enable row level security;

revoke all on public.platform_readiness_assessments from public,anon,authenticated;
revoke all on public.platform_readiness_checks from public,anon,authenticated;
revoke all on public.platform_readiness_timeline from public,anon,authenticated;

grant select,insert on public.platform_readiness_assessments to service_role;
grant select,insert on public.platform_readiness_checks to service_role;
grant select,insert on public.platform_readiness_timeline to service_role;

drop policy if exists platform_readiness_assessments_service_all on public.platform_readiness_assessments;
create policy platform_readiness_assessments_service_all
  on public.platform_readiness_assessments for all to service_role using(true) with check(true);

drop policy if exists platform_readiness_checks_service_all on public.platform_readiness_checks;
create policy platform_readiness_checks_service_all
  on public.platform_readiness_checks for all to service_role using(true) with check(true);

drop policy if exists platform_readiness_timeline_service_all on public.platform_readiness_timeline;
create policy platform_readiness_timeline_service_all
  on public.platform_readiness_timeline for all to service_role using(true) with check(true);

revoke all on function public.protect_platform_readiness_immutable_row() from public,anon,authenticated;
revoke all on function public.protect_platform_readiness_assessment_identity() from public,anon,authenticated;
revoke all on function public.evaluate_platform_readiness_rpc(text,uuid) from public,anon,authenticated;
revoke all on function public.get_platform_readiness_assessments_rpc(text,integer) from public,anon;
revoke all on function public.get_platform_readiness_latest_assessment_rpc() from public,anon;
revoke all on function public.get_platform_readiness_assessment_rpc(uuid) from public,anon;
revoke all on function public.get_platform_readiness_timeline_rpc(uuid,text,integer) from public,anon;
revoke all on function public.get_platform_readiness_health_rpc() from public,anon;

grant execute on function public.evaluate_platform_readiness_rpc(text,uuid) to service_role;
grant execute on function public.get_platform_readiness_assessments_rpc(text,integer) to authenticated,service_role;
grant execute on function public.get_platform_readiness_latest_assessment_rpc() to authenticated,service_role;
grant execute on function public.get_platform_readiness_assessment_rpc(uuid) to authenticated,service_role;
grant execute on function public.get_platform_readiness_timeline_rpc(uuid,text,integer) to authenticated,service_role;
grant execute on function public.get_platform_readiness_health_rpc() to authenticated,service_role;

-- --------------------------------------------------------------------------
-- 9. Runtime policies and feature flag
-- --------------------------------------------------------------------------

insert into public.platform_runtime_policies(
  policy_key,policy_name,description,policy_type,policy_value,
  validation_contract,owner_engine_code,enforcement_level,enabled,metadata
)
values
  (
    'runtime.readiness.evaluation_interval','Readiness evaluation interval',
    'Recommended cadence for explicit readiness evaluation cycles.',
    'duration','"PT1M"'::jsonb,'{"format":"ISO-8601-duration"}'::jsonb,
    'platform_readiness_engine','required',true,'{"migration":87}'::jsonb
  ),
  (
    'runtime.readiness.deterministic_evaluation','Deterministic readiness evaluation',
    'Readiness checks must be deterministic and evidence-backed.',
    'boolean','true'::jsonb,'{}'::jsonb,
    'platform_readiness_engine','critical',true,'{"migration":87}'::jsonb
  ),
  (
    'runtime.readiness.authorizes_execution','Readiness execution authorization',
    'A readiness outcome is decision support and never an execution permit.',
    'boolean','false'::jsonb,'{}'::jsonb,
    'platform_readiness_engine','critical',true,
    '{"migration":87,"safety":"non-authoritative"}'::jsonb
  ),
  (
    'runtime.readiness.automatic_remediation','Readiness automatic remediation',
    'The readiness layer cannot execute remediation or dispatch runtime work.',
    'boolean','false'::jsonb,'{}'::jsonb,
    'platform_readiness_engine','critical',true,
    '{"migration":87,"safety":"no-automatic-remediation"}'::jsonb
  )
on conflict(policy_key) do update
set policy_name=excluded.policy_name,
    description=excluded.description,
    policy_type=excluded.policy_type,
    policy_value=excluded.policy_value,
    validation_contract=excluded.validation_contract,
    owner_engine_code=excluded.owner_engine_code,
    enforcement_level=excluded.enforcement_level,
    enabled=excluded.enabled,
    metadata=public.platform_runtime_policies.metadata || excluded.metadata,
    updated_at=now();

insert into public.platform_feature_flags(
  feature_key,feature_name,description,enabled,rollout_percentage,audience,
  environment_scope,owner_engine_code,metadata
)
values(
  'runtime.platform_readiness','Platform readiness engine',
  'Expose deterministic readiness assessments, checks, timeline and health read models.',
  true,100,'service',
  array['development','preview','staging','production','test']::text[],
  'platform_readiness_engine',
  '{"contract":"platform-readiness-assessment-v1","migration":87}'::jsonb
)
on conflict(feature_key) do update
set feature_name=excluded.feature_name,
    description=excluded.description,
    enabled=excluded.enabled,
    rollout_percentage=excluded.rollout_percentage,
    audience=excluded.audience,
    environment_scope=excluded.environment_scope,
    owner_engine_code=excluded.owner_engine_code,
    metadata=public.platform_feature_flags.metadata || excluded.metadata,
    updated_at=now();

-- --------------------------------------------------------------------------
-- 10. Upstream health projections and Governance Snapshot v1.8
-- --------------------------------------------------------------------------

create or replace function public.get_platform_recommendation_health_rpc()
returns jsonb
language sql
stable
security definer
set search_path=public,pg_temp
as $function$
  select jsonb_build_object(
    'contract_version','platform-recommendation-health-v1','generated_at',now(),
    'active_recommendations',jsonb_build_object(
      'total',count(*) filter(where recommendation_status in ('proposed','accepted')),
      'proposed',count(*) filter(where recommendation_status='proposed'),
      'accepted',count(*) filter(where recommendation_status='accepted'),
      'urgent',count(*) filter(where recommendation_status in ('proposed','accepted') and priority='urgent')
    ),
    'history',jsonb_build_object(
      'recommendation_count',count(*),
      'timeline_event_count',(select count(*) from public.platform_recommendation_timeline)
    ),
    'controls',jsonb_build_object(
      'deterministic_generation',true,'explainable',true,
      'requires_human_approval',true,'automatic_execution',false,
      'remediation_engine',false,'readiness_engine',true
    )
  ) from public.platform_operational_recommendations;
$function$;

create or replace function public.get_platform_governance_snapshot_rpc()
returns jsonb
language sql
stable
security definer
set search_path=public,pg_temp
as $function$
  select jsonb_build_object(
    'contract_version','platform-governance-v1.8','generated_at',now(),
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
    'telemetry_health',public.get_platform_telemetry_health_rpc(),
    'telemetry_latest_snapshot',public.get_platform_telemetry_latest_snapshot_rpc(),
    'telemetry_alerts',public.get_platform_telemetry_alerts_rpc(null,null,100),
    'sla_status',public.get_platform_sla_status_rpc(100),
    'supervision_health',public.get_platform_supervision_health_rpc(),
    'supervision_latest_evaluation',public.get_platform_supervision_latest_evaluation_rpc(),
    'supervision_active_findings',public.get_platform_operational_findings_rpc('open',null,100),
    'incident_health',public.get_platform_incident_health_rpc(),
    'active_incidents',public.get_platform_operational_incidents_rpc('open',null,100),
    'incident_timeline',public.get_platform_incident_timeline_rpc(null,null,100),
    'recommendation_health',public.get_platform_recommendation_health_rpc(),
    'active_recommendations',public.get_platform_operational_recommendations_rpc('proposed',null,100),
    'recommendation_timeline',public.get_platform_recommendation_timeline_rpc(null,null,100),
    'readiness_health',public.get_platform_readiness_health_rpc(),
    'readiness_latest_assessment',public.get_platform_readiness_latest_assessment_rpc(),
    'readiness_timeline',public.get_platform_readiness_timeline_rpc(null,null,100),
    'feature_flags',public.get_platform_feature_flags_rpc(null,false),
    'runtime_policies',public.get_platform_runtime_policies_rpc(null,false),
    'capabilities',public.get_platform_capabilities_rpc(null,false)
  );
$function$;

revoke all on function public.get_platform_governance_snapshot_rpc() from public,anon;
grant execute on function public.get_platform_governance_snapshot_rpc() to authenticated,service_role;

update public.platform_configuration
set schema_version=greatest(schema_version,87),
    metadata=metadata || jsonb_build_object(
      'phase','8.4.5',
      'governance_contract','platform-governance-v1.8',
      'platform_readiness_contract','platform-readiness-assessment-v1',
      'platform_readiness_migration',87
    ),
    updated_at=now()
where configuration_key='primary';

-- --------------------------------------------------------------------------
-- 11. Migration assertions
-- --------------------------------------------------------------------------

do $assertions$
declare
  v_missing integer;
  v_health jsonb;
  v_snapshot jsonb;
  v_actions bigint;
begin
  select count(*) into v_missing
  from (values
    ('platform_readiness_assessments'),
    ('platform_readiness_checks'),
    ('platform_readiness_timeline')
  ) expected(name)
  where to_regclass('public.'||expected.name) is null;

  if v_missing<>0 then
    raise exception 'PLATFORM_READINESS_ASSERTION_FAILED: missing tables %',v_missing;
  end if;

  select count(*) into v_missing
  from (values
    ('evaluate_platform_readiness_rpc'),
    ('get_platform_readiness_assessments_rpc'),
    ('get_platform_readiness_latest_assessment_rpc'),
    ('get_platform_readiness_assessment_rpc'),
    ('get_platform_readiness_timeline_rpc'),
    ('get_platform_readiness_health_rpc')
  ) expected(name)
  where not exists(
    select 1 from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname=expected.name
  );

  if v_missing<>0 then
    raise exception 'PLATFORM_READINESS_ASSERTION_FAILED: missing functions %',v_missing;
  end if;

  if not exists(
    select 1 from public.platform_engine_registry
    where engine_code='platform_readiness_engine'
      and engine_version='1.0.0'
      and runtime_enabled
      and not is_certified
  ) then
    raise exception 'PLATFORM_READINESS_ASSERTION_FAILED: engine registration invalid';
  end if;

  if (
    select count(*) from public.platform_engine_dependencies
    where dependent_engine_code='platform_readiness_engine'
      and dependency_engine_code in (
        'platform_governance_engine','platform_supervision_engine',
        'platform_incident_correlation_engine','platform_recommendation_engine'
      ) and enabled
  )<>4 then
    raise exception 'PLATFORM_READINESS_ASSERTION_FAILED: dependencies invalid';
  end if;

  if (
    select count(*) from public.platform_runtime_policies
    where policy_key in (
      'runtime.readiness.evaluation_interval',
      'runtime.readiness.deterministic_evaluation',
      'runtime.readiness.authorizes_execution',
      'runtime.readiness.automatic_remediation'
    ) and owner_engine_code='platform_readiness_engine' and enabled
  )<>4 then
    raise exception 'PLATFORM_READINESS_ASSERTION_FAILED: runtime policies invalid';
  end if;

  if not exists(
    select 1 from public.platform_runtime_policies
    where policy_key='runtime.readiness.authorizes_execution'
      and policy_value='false'::jsonb and enabled
  ) or not exists(
    select 1 from public.platform_runtime_policies
    where policy_key='runtime.readiness.automatic_remediation'
      and policy_value='false'::jsonb and enabled
  ) then
    raise exception 'PLATFORM_READINESS_ASSERTION_FAILED: safety policies invalid';
  end if;

  if not exists(
    select 1 from public.platform_feature_flags
    where feature_key='runtime.platform_readiness'
      and enabled and rollout_percentage=100
      and owner_engine_code='platform_readiness_engine'
  ) then
    raise exception 'PLATFORM_READINESS_ASSERTION_FAILED: feature flag invalid';
  end if;

  if (
    select count(*) from pg_class c
    join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public'
      and c.relname in (
        'platform_readiness_assessments','platform_readiness_checks','platform_readiness_timeline'
      ) and c.relrowsecurity
  )<>3 then
    raise exception 'PLATFORM_READINESS_ASSERTION_FAILED: RLS invalid';
  end if;

  v_health:=public.get_platform_readiness_health_rpc();
  if v_health->>'contract_version'<>'platform-readiness-health-v1'
     or (v_health#>>'{controls,authorizes_execution}')::boolean
     or (v_health#>>'{controls,automatic_remediation}')::boolean
     or (v_health#>>'{controls,orchestrator_dispatch}')::boolean then
    raise exception 'PLATFORM_READINESS_ASSERTION_FAILED: health safety invalid';
  end if;

  v_snapshot:=public.get_platform_governance_snapshot_rpc();
  if v_snapshot->>'contract_version'<>'platform-governance-v1.8'
     or not(v_snapshot?'readiness_health')
     or not(v_snapshot?'readiness_latest_assessment')
     or not(v_snapshot?'readiness_timeline') then
    raise exception 'PLATFORM_READINESS_ASSERTION_FAILED: governance projection invalid';
  end if;

  if not exists(
    select 1 from public.platform_configuration
    where configuration_key='primary' and schema_version>=87
  ) then
    raise exception 'PLATFORM_READINESS_ASSERTION_FAILED: schema version invalid';
  end if;

  select count(*) into v_actions
  from public.platform_orchestrator_actions
  where created_at>=transaction_timestamp();

  if v_actions<>0 then
    raise exception 'PLATFORM_READINESS_ASSERTION_FAILED: migration generated orchestrator actions (%)',v_actions;
  end if;
end;
$assertions$;

commit;
