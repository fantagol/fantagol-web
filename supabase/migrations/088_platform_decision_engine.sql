-- ============================================================================
-- FANTAGOL
-- Migration 088: Platform Decision Engine
-- Phase 8.4.6
--
-- Purpose
--   Convert an immutable Platform Readiness assessment into a durable,
--   explainable and deterministic operational decision for critical platform
--   operations. Decisions are the authorization boundary consumed by the
--   Platform Orchestrator, but this engine never dispatches or executes work.
--
-- Decision semantics
--   READY     -> approved / authorize / authorizes_execution = true
--   DEGRADED  -> held     / hold      / authorizes_execution = false
--   BLOCKED   -> denied   / deny      / authorizes_execution = false
--
-- Safety
--   The engine records authorization only. It cannot create orchestrator
--   actions, dispatch jobs, mutate readiness snapshots, remediate incidents,
--   or bypass human/service governance. Authorization and execution remain
--   separate responsibilities.
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
  'platform_decision_engine','Platform Decision Engine','1.0.0',
  'governance','active',true,false,null,null,'platform',170,
  '["platform_governance_engine","platform_readiness_engine"]'::jsonb,
  jsonb_build_object(
    'phase','8.4.6',
    'contract','platform-operational-decision-v1',
    'migration',88,
    'decision_mode','explicit-deterministic',
    'explainable',true,
    'can_authorize_execution',true,
    'automatic_dispatch',false,
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
    'platform_decision_engine','platform_governance_engine','required','1.0.0',
    true,true,array['active','degraded']::text[],true,
    'Decision records require the certified platform governance contract.',
    '{"migration":88}'::jsonb
  ),
  (
    'platform_decision_engine','platform_readiness_engine','runtime','1.0.0',
    true,false,array['active','degraded']::text[],true,
    'Every operational decision must be derived from an immutable readiness assessment.',
    '{"migration":88}'::jsonb
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
-- 2. Durable operational decisions
-- --------------------------------------------------------------------------

create table if not exists public.platform_operational_decisions (
  operational_decision_id uuid primary key default gen_random_uuid(),
  decision_sequence bigint generated always as identity unique,
  contract_version text not null default 'platform-operational-decision-v1',
  decision_key text not null unique,
  decision_scope text not null default 'platform_critical_operations',
  decision_status text not null,
  decision_code text not null,
  readiness_assessment_id uuid not null,
  readiness_status text not null,
  readiness_score numeric(5,2) not null,
  authorizes_execution boolean not null default false,
  source text not null,
  correlation_id uuid not null unique default gen_random_uuid(),
  decided_at timestamptz not null default now(),
  summary text not null,
  rationale jsonb not null default '[]'::jsonb,
  evidence_summary jsonb not null default '{}'::jsonb,
  authorization_context jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),

  constraint platform_operational_decisions_contract_ck
    check (contract_version='platform-operational-decision-v1'),
  constraint platform_operational_decisions_key_ck
    check (decision_key ~ '^decision:[a-z0-9_.:-]+$'),
  constraint platform_operational_decisions_scope_ck
    check (decision_scope='platform_critical_operations'),
  constraint platform_operational_decisions_status_ck
    check (decision_status in ('approved','held','denied')),
  constraint platform_operational_decisions_code_ck
    check (decision_code in ('authorize','hold','deny')),
  constraint platform_operational_decisions_readiness_status_ck
    check (readiness_status in ('ready','degraded','blocked')),
  constraint platform_operational_decisions_score_ck
    check (readiness_score between 0 and 100),
  constraint platform_operational_decisions_source_ck
    check (btrim(source)<>''),
  constraint platform_operational_decisions_summary_ck
    check (btrim(summary)<>''),
  constraint platform_operational_decisions_rationale_ck
    check (jsonb_typeof(rationale)='array'),
  constraint platform_operational_decisions_evidence_ck
    check (jsonb_typeof(evidence_summary)='object'),
  constraint platform_operational_decisions_context_ck
    check (jsonb_typeof(authorization_context)='object'),
  constraint platform_operational_decisions_metadata_ck
    check (jsonb_typeof(metadata)='object'),
  constraint platform_operational_decisions_mapping_ck
    check (
      (readiness_status='ready' and decision_status='approved'
        and decision_code='authorize' and authorizes_execution)
      or
      (readiness_status='degraded' and decision_status='held'
        and decision_code='hold' and not authorizes_execution)
      or
      (readiness_status='blocked' and decision_status='denied'
        and decision_code='deny' and not authorizes_execution)
    ),
  constraint platform_operational_decisions_readiness_fk
    foreign key (readiness_assessment_id)
      references public.platform_readiness_assessments(readiness_assessment_id)
      on delete restrict
);

create index if not exists platform_operational_decisions_status_idx
  on public.platform_operational_decisions(decision_status,decided_at desc);
create index if not exists platform_operational_decisions_readiness_idx
  on public.platform_operational_decisions(readiness_assessment_id,decision_sequence desc);

comment on table public.platform_operational_decisions is
  'Immutable authorization decisions derived from immutable readiness assessments. Decisions never dispatch work.';

-- --------------------------------------------------------------------------
-- 3. Immutable decision rule evaluations
-- --------------------------------------------------------------------------

create table if not exists public.platform_decision_rules (
  decision_rule_id uuid primary key default gen_random_uuid(),
  rule_sequence bigint generated always as identity unique,
  contract_version text not null default 'platform-decision-rule-v1',
  operational_decision_id uuid not null,
  rule_key text not null,
  rule_category text not null,
  rule_status text not null,
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

  constraint platform_decision_rules_contract_ck
    check (contract_version='platform-decision-rule-v1'),
  constraint platform_decision_rules_key_ck
    check (rule_key ~ '^[a-z][a-z0-9_.:-]*$'),
  constraint platform_decision_rules_category_ck
    check (rule_category in ('readiness','authorization','safety','governance')),
  constraint platform_decision_rules_status_ck
    check (rule_status in ('passed','failed')),
  constraint platform_decision_rules_severity_ck
    check (severity in ('info','critical')),
  constraint platform_decision_rules_text_ck
    check (btrim(title)<>'' and btrim(description)<>''),
  constraint platform_decision_rules_evidence_ck
    check (jsonb_typeof(evidence)='object'),
  constraint platform_decision_rules_metadata_ck
    check (jsonb_typeof(metadata)='object'),
  constraint platform_decision_rules_blocking_ck
    check ((blocking and rule_status='failed') or not blocking),
  constraint platform_decision_rules_decision_fk
    foreign key (operational_decision_id)
      references public.platform_operational_decisions(operational_decision_id)
      on delete restrict,
  constraint platform_decision_rules_decision_key_uq
    unique (operational_decision_id,rule_key)
);

create index if not exists platform_decision_rules_decision_idx
  on public.platform_decision_rules(operational_decision_id,rule_sequence);
create index if not exists platform_decision_rules_status_idx
  on public.platform_decision_rules(rule_status,severity,blocking);

comment on table public.platform_decision_rules is
  'Immutable evidence explaining why an operational decision is valid.';

-- --------------------------------------------------------------------------
-- 4. Append-only decision timeline
-- --------------------------------------------------------------------------

create table if not exists public.platform_decision_timeline (
  decision_timeline_event_id uuid primary key default gen_random_uuid(),
  event_sequence bigint generated always as identity unique,
  contract_version text not null default 'platform-decision-timeline-v1',
  operational_decision_id uuid not null,
  event_type text not null,
  event_status text not null,
  decision_status text not null,
  correlation_id uuid not null,
  occurred_at timestamptz not null default now(),
  summary text not null,
  details jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,

  constraint platform_decision_timeline_contract_ck
    check (contract_version='platform-decision-timeline-v1'),
  constraint platform_decision_timeline_type_ck
    check (event_type in (
      'decision_evaluated','decision_approved','decision_held','decision_denied'
    )),
  constraint platform_decision_timeline_event_status_ck
    check (event_status in ('completed','recorded')),
  constraint platform_decision_timeline_decision_status_ck
    check (decision_status in ('approved','held','denied')),
  constraint platform_decision_timeline_summary_ck
    check (btrim(summary)<>''),
  constraint platform_decision_timeline_details_ck
    check (jsonb_typeof(details)='object'),
  constraint platform_decision_timeline_metadata_ck
    check (jsonb_typeof(metadata)='object'),
  constraint platform_decision_timeline_decision_fk
    foreign key (operational_decision_id)
      references public.platform_operational_decisions(operational_decision_id)
      on delete restrict
);

create index if not exists platform_decision_timeline_decision_idx
  on public.platform_decision_timeline(operational_decision_id,event_sequence);
create index if not exists platform_decision_timeline_status_idx
  on public.platform_decision_timeline(decision_status,occurred_at desc);

comment on table public.platform_decision_timeline is
  'Append-only timeline for certified operational authorization decisions.';

-- --------------------------------------------------------------------------
-- 5. Immutability guards
-- --------------------------------------------------------------------------

create or replace function public.protect_platform_decision_immutable_row()
returns trigger
language plpgsql
security definer
set search_path=public,pg_temp
as $function$
begin
  raise exception 'PLATFORM_DECISION_ROW_IMMUTABLE'
    using errcode='55000';
end;
$function$;

drop trigger if exists trg_protect_platform_operational_decisions
  on public.platform_operational_decisions;
create trigger trg_protect_platform_operational_decisions
before update or delete on public.platform_operational_decisions
for each row execute function public.protect_platform_decision_immutable_row();

drop trigger if exists trg_protect_platform_decision_rules
  on public.platform_decision_rules;
create trigger trg_protect_platform_decision_rules
before update or delete on public.platform_decision_rules
for each row execute function public.protect_platform_decision_immutable_row();

drop trigger if exists trg_protect_platform_decision_timeline
  on public.platform_decision_timeline;
create trigger trg_protect_platform_decision_timeline
before update or delete on public.platform_decision_timeline
for each row execute function public.protect_platform_decision_immutable_row();

-- --------------------------------------------------------------------------
-- 6. Deterministic decision evaluator
-- --------------------------------------------------------------------------

create or replace function public.evaluate_platform_decision_rpc(
  p_readiness_assessment_id uuid default null,
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
  v_decided_at timestamptz:=now();
  v_decision_id uuid:=gen_random_uuid();
  v_source text:=btrim(coalesce(p_source,''));
  v_correlation_id uuid:=coalesce(p_correlation_id,gen_random_uuid());
  v_readiness public.platform_readiness_assessments%rowtype;
  v_existing public.platform_operational_decisions%rowtype;
  v_decision_key text;
  v_decision_status text;
  v_decision_code text;
  v_authorizes boolean:=false;
  v_summary text;
  v_rationale jsonb:='[]'::jsonb;
  v_auto_dispatch_disabled boolean:=false;
  v_explicit_readiness_required boolean:=false;
  v_actions_before bigint:=0;
  v_actions_after bigint:=0;
  v_rule_count integer:=4;
  v_duration_ms integer;
begin
  if v_source='' then
    raise exception 'PLATFORM_DECISION_SOURCE_REQUIRED' using errcode='22023';
  end if;

  select * into v_existing
  from public.platform_operational_decisions
  where correlation_id=v_correlation_id;

  if found then
    return jsonb_build_object(
      'contract_version','platform-decision-evaluation-v1',
      'operational_decision_id',v_existing.operational_decision_id,
      'decision_sequence',v_existing.decision_sequence,
      'decision_status',v_existing.decision_status,
      'decision_code',v_existing.decision_code,
      'authorizes_execution',v_existing.authorizes_execution,
      'readiness_assessment_id',v_existing.readiness_assessment_id,
      'correlation_id',v_existing.correlation_id,
      'decision_reused',true,
      'rule_count',(select count(*) from public.platform_decision_rules r
                    where r.operational_decision_id=v_existing.operational_decision_id)
    );
  end if;

  if p_readiness_assessment_id is null then
    select * into v_readiness
    from public.platform_readiness_assessments
    order by assessment_sequence desc
    limit 1;
  else
    select * into v_readiness
    from public.platform_readiness_assessments
    where readiness_assessment_id=p_readiness_assessment_id;
  end if;

  if not found then
    raise exception 'PLATFORM_DECISION_READINESS_ASSESSMENT_NOT_FOUND'
      using errcode='P0002';
  end if;

  if v_readiness.authorizes_execution then
    raise exception 'PLATFORM_DECISION_INVALID_READINESS_AUTHORITY'
      using errcode='55000';
  end if;

  select exists(
    select 1 from public.platform_runtime_policies
    where policy_key='runtime.decision.automatic_dispatch'
      and enabled and policy_value='false'::jsonb
  ) into v_auto_dispatch_disabled;

  select exists(
    select 1 from public.platform_runtime_policies
    where policy_key='runtime.decision.explicit_readiness_required'
      and enabled and policy_value='true'::jsonb
  ) into v_explicit_readiness_required;

  if not v_auto_dispatch_disabled or not v_explicit_readiness_required then
    raise exception 'PLATFORM_DECISION_SAFETY_POLICY_INVALID'
      using errcode='55000';
  end if;

  case v_readiness.readiness_status
    when 'ready' then
      v_decision_status:='approved';
      v_decision_code:='authorize';
      v_authorizes:=true;
      v_summary:='Critical platform operations are authorized by a READY readiness assessment.';
    when 'degraded' then
      v_decision_status:='held';
      v_decision_code:='hold';
      v_authorizes:=false;
      v_summary:='Critical platform operations are held while degraded readiness evidence remains.';
    when 'blocked' then
      v_decision_status:='denied';
      v_decision_code:='deny';
      v_authorizes:=false;
      v_summary:='Critical platform operations are denied by blocking readiness conditions.';
    else
      raise exception 'PLATFORM_DECISION_UNSUPPORTED_READINESS_STATUS: %',
        v_readiness.readiness_status using errcode='22023';
  end case;

  v_decision_key:='decision:platform-critical:'||v_readiness.readiness_assessment_id::text;
  v_rationale:=case
    when v_readiness.readiness_status='blocked' then v_readiness.blocking_reasons
    when v_readiness.readiness_status='degraded' then
      jsonb_build_array(jsonb_build_object(
        'reason','degraded_readiness',
        'degraded_check_count',v_readiness.degraded_check_count
      ))
    else jsonb_build_array(jsonb_build_object(
      'reason','all_readiness_checks_satisfied',
      'readiness_score',v_readiness.readiness_score
    ))
  end;

  select count(*) into v_actions_before
  from public.platform_orchestrator_actions;

  insert into public.platform_operational_decisions(
    operational_decision_id,decision_key,decision_scope,decision_status,
    decision_code,readiness_assessment_id,readiness_status,readiness_score,
    authorizes_execution,source,correlation_id,decided_at,summary,rationale,
    evidence_summary,authorization_context,metadata
  ) values (
    v_decision_id,v_decision_key,'platform_critical_operations',v_decision_status,
    v_decision_code,v_readiness.readiness_assessment_id,
    v_readiness.readiness_status,v_readiness.readiness_score,
    v_authorizes,v_source,v_correlation_id,v_decided_at,v_summary,v_rationale,
    jsonb_build_object(
      'readiness_sequence',v_readiness.assessment_sequence,
      'blocking_check_count',v_readiness.blocking_check_count,
      'degraded_check_count',v_readiness.degraded_check_count,
      'passed_check_count',v_readiness.passed_check_count,
      'total_check_count',v_readiness.total_check_count,
      'readiness_correlation_id',v_readiness.correlation_id
    ),
    jsonb_build_object(
      'decision_engine_version','1.0.0',
      'authorization_scope','platform_critical_operations',
      'automatic_dispatch',false,
      'automatic_remediation',false,
      'requires_separate_orchestrator_dispatch',true
    ),
    '{"migration":88}'::jsonb
  )
  on conflict(decision_key) do nothing;

  if not found then
    select * into strict v_existing
    from public.platform_operational_decisions
    where decision_key=v_decision_key;

    return jsonb_build_object(
      'contract_version','platform-decision-evaluation-v1',
      'operational_decision_id',v_existing.operational_decision_id,
      'decision_sequence',v_existing.decision_sequence,
      'decision_status',v_existing.decision_status,
      'decision_code',v_existing.decision_code,
      'authorizes_execution',v_existing.authorizes_execution,
      'readiness_assessment_id',v_existing.readiness_assessment_id,
      'correlation_id',v_existing.correlation_id,
      'decision_reused',true,
      'rule_count',(select count(*) from public.platform_decision_rules r
                    where r.operational_decision_id=v_existing.operational_decision_id)
    );
  end if;

  insert into public.platform_decision_rules(
    operational_decision_id,rule_key,rule_category,rule_status,severity,
    title,description,observed_value,expected_value,evidence,blocking,
    remediation_hint,metadata
  ) values
  (
    v_decision_id,'readiness.snapshot_bound','readiness','passed','info',
    'Immutable readiness snapshot bound',
    'The decision must reference one existing immutable readiness assessment.',
    to_jsonb(v_readiness.readiness_assessment_id),
    to_jsonb(v_readiness.readiness_assessment_id),
    jsonb_build_object('assessment_sequence',v_readiness.assessment_sequence),
    false,null,'{"migration":88}'::jsonb
  ),
  (
    v_decision_id,'authorization.status_mapping','authorization','passed','info',
    'Readiness-to-decision mapping',
    'READY maps to authorize, DEGRADED maps to hold and BLOCKED maps to deny.',
    jsonb_build_object(
      'readiness_status',v_readiness.readiness_status,
      'decision_status',v_decision_status,
      'decision_code',v_decision_code
    ),
    case v_readiness.readiness_status
      when 'ready' then '{"readiness_status":"ready","decision_status":"approved","decision_code":"authorize"}'::jsonb
      when 'degraded' then '{"readiness_status":"degraded","decision_status":"held","decision_code":"hold"}'::jsonb
      else '{"readiness_status":"blocked","decision_status":"denied","decision_code":"deny"}'::jsonb
    end,
    jsonb_build_object('readiness_score',v_readiness.readiness_score),
    false,null,'{"migration":88}'::jsonb
  ),
  (
    v_decision_id,'safety.readiness_non_authoritative','safety','passed','info',
    'Readiness remains non-authoritative',
    'The upstream readiness snapshot must never authorize execution directly.',
    to_jsonb(v_readiness.authorizes_execution),'false'::jsonb,
    jsonb_build_object('readiness_assessment_id',v_readiness.readiness_assessment_id),
    false,null,'{"migration":88}'::jsonb
  ),
  (
    v_decision_id,'safety.automatic_dispatch_disabled','safety','passed','info',
    'Automatic dispatch disabled',
    'The decision engine records authorization but cannot dispatch orchestrator actions.',
    to_jsonb(v_auto_dispatch_disabled),'true'::jsonb,
    jsonb_build_object('policy_key','runtime.decision.automatic_dispatch'),
    false,null,'{"migration":88}'::jsonb
  );

  insert into public.platform_decision_timeline(
    operational_decision_id,event_type,event_status,decision_status,
    correlation_id,occurred_at,summary,details,metadata
  ) values
  (
    v_decision_id,'decision_evaluated','completed',v_decision_status,
    v_correlation_id,v_decided_at,'Platform operational decision evaluation completed.',
    jsonb_build_object(
      'source',v_source,
      'readiness_assessment_id',v_readiness.readiness_assessment_id,
      'readiness_status',v_readiness.readiness_status,
      'readiness_score',v_readiness.readiness_score,
      'rule_count',v_rule_count
    ),'{"migration":88}'::jsonb
  ),
  (
    v_decision_id,
    case v_decision_status
      when 'approved' then 'decision_approved'
      when 'held' then 'decision_held'
      else 'decision_denied'
    end,
    'recorded',v_decision_status,v_correlation_id,v_decided_at,v_summary,
    jsonb_build_object(
      'decision_code',v_decision_code,
      'authorizes_execution',v_authorizes,
      'rationale',v_rationale
    ),'{"migration":88}'::jsonb
  );

  select count(*) into v_actions_after
  from public.platform_orchestrator_actions;

  if v_actions_after<>v_actions_before then
    raise exception 'PLATFORM_DECISION_ORCHESTRATOR_ISOLATION_VIOLATION'
      using errcode='55000';
  end if;

  v_duration_ms:=greatest(0,round(extract(epoch from (clock_timestamp()-v_started_at))*1000)::integer);

  return jsonb_build_object(
    'contract_version','platform-decision-evaluation-v1',
    'operational_decision_id',v_decision_id,
    'decision_sequence',(select decision_sequence from public.platform_operational_decisions where operational_decision_id=v_decision_id),
    'decision_status',v_decision_status,
    'decision_code',v_decision_code,
    'authorizes_execution',v_authorizes,
    'readiness_assessment_id',v_readiness.readiness_assessment_id,
    'readiness_status',v_readiness.readiness_status,
    'readiness_score',v_readiness.readiness_score,
    'correlation_id',v_correlation_id,
    'decision_reused',false,
    'rule_count',v_rule_count,
    'timeline_event_count',2,
    'duration_ms',v_duration_ms
  );
end;
$function$;

-- --------------------------------------------------------------------------
-- 7. Read models
-- --------------------------------------------------------------------------

create or replace function public.get_platform_operational_decisions_rpc(
  p_status text default null,
  p_limit integer default 100
)
returns jsonb
language sql
stable
security definer
set search_path=public,pg_temp
as $function$
  select coalesce(jsonb_agg(to_jsonb(d) order by d.decision_sequence desc),'[]'::jsonb)
  from (
    select * from public.platform_operational_decisions
    where p_status is null or decision_status=p_status
    order by decision_sequence desc
    limit greatest(1,least(coalesce(p_limit,100),500))
  ) d;
$function$;

create or replace function public.get_platform_operational_decision_rpc(
  p_operational_decision_id uuid
)
returns jsonb
language sql
stable
security definer
set search_path=public,pg_temp
as $function$
  select to_jsonb(d) || jsonb_build_object(
    'rules',coalesce((select jsonb_agg(to_jsonb(r) order by r.rule_sequence)
      from public.platform_decision_rules r
      where r.operational_decision_id=d.operational_decision_id),'[]'::jsonb),
    'timeline',coalesce((select jsonb_agg(to_jsonb(t) order by t.event_sequence)
      from public.platform_decision_timeline t
      where t.operational_decision_id=d.operational_decision_id),'[]'::jsonb),
    'readiness_assessment',public.get_platform_readiness_assessment_rpc(d.readiness_assessment_id)
  )
  from public.platform_operational_decisions d
  where d.operational_decision_id=p_operational_decision_id;
$function$;

create or replace function public.get_platform_latest_decision_rpc()
returns jsonb
language sql
stable
security definer
set search_path=public,pg_temp
as $function$
  select public.get_platform_operational_decision_rpc(
    (select operational_decision_id
     from public.platform_operational_decisions
     order by decision_sequence desc limit 1)
  );
$function$;

create or replace function public.get_platform_decision_timeline_rpc(
  p_operational_decision_id uuid default null,
  p_decision_status text default null,
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
    select * from public.platform_decision_timeline
    where (p_operational_decision_id is null or operational_decision_id=p_operational_decision_id)
      and (p_decision_status is null or decision_status=p_decision_status)
    order by event_sequence desc
    limit greatest(1,least(coalesce(p_limit,100),500))
  ) t;
$function$;

create or replace function public.get_platform_decision_health_rpc()
returns jsonb
language sql
stable
security definer
set search_path=public,pg_temp
as $function$
  select jsonb_build_object(
    'contract_version','platform-decision-health-v1',
    'generated_at',now(),
    'latest_decision',public.get_platform_latest_decision_rpc(),
    'history',jsonb_build_object(
      'decision_count',(select count(*) from public.platform_operational_decisions),
      'approved_count',(select count(*) from public.platform_operational_decisions where decision_status='approved'),
      'held_count',(select count(*) from public.platform_operational_decisions where decision_status='held'),
      'denied_count',(select count(*) from public.platform_operational_decisions where decision_status='denied'),
      'rule_count',(select count(*) from public.platform_decision_rules),
      'timeline_event_count',(select count(*) from public.platform_decision_timeline)
    ),
    'controls',jsonb_build_object(
      'deterministic_evaluation',true,
      'explicit_readiness_required',true,
      'can_authorize_execution',true,
      'automatic_dispatch',false,
      'automatic_remediation',false,
      'orchestrator_dispatch',false
    )
  );
$function$;

-- --------------------------------------------------------------------------
-- 8. RLS and privileges
-- --------------------------------------------------------------------------

alter table public.platform_operational_decisions enable row level security;
alter table public.platform_decision_rules enable row level security;
alter table public.platform_decision_timeline enable row level security;

revoke all on public.platform_operational_decisions from public,anon,authenticated;
revoke all on public.platform_decision_rules from public,anon,authenticated;
revoke all on public.platform_decision_timeline from public,anon,authenticated;

grant select,insert on public.platform_operational_decisions to service_role;
grant select,insert on public.platform_decision_rules to service_role;
grant select,insert on public.platform_decision_timeline to service_role;

drop policy if exists platform_operational_decisions_service_all
  on public.platform_operational_decisions;
create policy platform_operational_decisions_service_all
  on public.platform_operational_decisions for all to service_role
  using (true) with check (true);

drop policy if exists platform_decision_rules_service_all
  on public.platform_decision_rules;
create policy platform_decision_rules_service_all
  on public.platform_decision_rules for all to service_role
  using (true) with check (true);

drop policy if exists platform_decision_timeline_service_all
  on public.platform_decision_timeline;
create policy platform_decision_timeline_service_all
  on public.platform_decision_timeline for all to service_role
  using (true) with check (true);

revoke all on function public.evaluate_platform_decision_rpc(uuid,text,uuid) from public,anon,authenticated;
revoke all on function public.get_platform_operational_decisions_rpc(text,integer) from public,anon;
revoke all on function public.get_platform_latest_decision_rpc() from public,anon;
revoke all on function public.get_platform_operational_decision_rpc(uuid) from public,anon;
revoke all on function public.get_platform_decision_timeline_rpc(uuid,text,integer) from public,anon;
revoke all on function public.get_platform_decision_health_rpc() from public,anon;

grant execute on function public.evaluate_platform_decision_rpc(uuid,text,uuid) to service_role;
grant execute on function public.get_platform_operational_decisions_rpc(text,integer) to authenticated,service_role;
grant execute on function public.get_platform_latest_decision_rpc() to authenticated,service_role;
grant execute on function public.get_platform_operational_decision_rpc(uuid) to authenticated,service_role;
grant execute on function public.get_platform_decision_timeline_rpc(uuid,text,integer) to authenticated,service_role;
grant execute on function public.get_platform_decision_health_rpc() to authenticated,service_role;

-- --------------------------------------------------------------------------
-- 9. Runtime policies and feature flag
-- --------------------------------------------------------------------------

insert into public.platform_runtime_policies(
  policy_key,policy_name,description,policy_type,policy_value,
  validation_contract,owner_engine_code,enforcement_level,enabled,metadata
)
values
  (
    'runtime.decision.deterministic_evaluation','Deterministic decision evaluation',
    'The same immutable readiness assessment always maps to the same decision.',
    'boolean','true'::jsonb,'{}'::jsonb,
    'platform_decision_engine','critical',true,'{"migration":88}'::jsonb
  ),
  (
    'runtime.decision.explicit_readiness_required','Explicit readiness required',
    'Every operational decision must reference one immutable readiness assessment.',
    'boolean','true'::jsonb,'{}'::jsonb,
    'platform_decision_engine','critical',true,'{"migration":88}'::jsonb
  ),
  (
    'runtime.decision.can_authorize_execution','Decision authorization capability',
    'Only an approved decision derived from READY may authorize critical execution.',
    'boolean','true'::jsonb,'{}'::jsonb,
    'platform_decision_engine','critical',true,
    '{"migration":88,"safety":"authorization-boundary"}'::jsonb
  ),
  (
    'runtime.decision.automatic_dispatch','Decision automatic dispatch',
    'The decision layer cannot create or dispatch orchestrator actions.',
    'boolean','false'::jsonb,'{}'::jsonb,
    'platform_decision_engine','critical',true,
    '{"migration":88,"safety":"no-automatic-dispatch"}'::jsonb
  ),
  (
    'runtime.decision.automatic_remediation','Decision automatic remediation',
    'The decision layer cannot mutate incidents, recommendations or readiness evidence.',
    'boolean','false'::jsonb,'{}'::jsonb,
    'platform_decision_engine','critical',true,
    '{"migration":88,"safety":"no-automatic-remediation"}'::jsonb
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
  'runtime.platform_decisions','Platform decision engine',
  'Expose certified operational decisions, rule evidence, timeline and health read models.',
  true,100,'service',
  array['development','preview','staging','production','test']::text[],
  'platform_decision_engine',
  '{"contract":"platform-operational-decision-v1","migration":88}'::jsonb
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
-- 10. Governance Snapshot v1.9
-- --------------------------------------------------------------------------

create or replace function public.get_platform_governance_snapshot_rpc()
returns jsonb
language sql
stable
security definer
set search_path=public,pg_temp
as $function$
  select jsonb_build_object(
    'contract_version','platform-governance-v1.9','generated_at',now(),
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
    'decision_health',public.get_platform_decision_health_rpc(),
    'decision_latest',public.get_platform_latest_decision_rpc(),
    'decision_timeline',public.get_platform_decision_timeline_rpc(null,null,100),
    'feature_flags',public.get_platform_feature_flags_rpc(null,false),
    'runtime_policies',public.get_platform_runtime_policies_rpc(null,false),
    'capabilities',public.get_platform_capabilities_rpc(null,false)
  );
$function$;

revoke all on function public.get_platform_governance_snapshot_rpc() from public,anon;
grant execute on function public.get_platform_governance_snapshot_rpc() to authenticated,service_role;

update public.platform_configuration
set schema_version=greatest(schema_version,88),
    metadata=metadata || jsonb_build_object(
      'phase','8.4.6',
      'governance_contract','platform-governance-v1.9',
      'platform_decision_contract','platform-operational-decision-v1',
      'platform_decision_migration',88
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
    ('platform_operational_decisions'),
    ('platform_decision_rules'),
    ('platform_decision_timeline')
  ) expected(name)
  where to_regclass('public.'||expected.name) is null;

  if v_missing<>0 then
    raise exception 'PLATFORM_DECISION_ASSERTION_FAILED: missing tables %',v_missing;
  end if;

  select count(*) into v_missing
  from (values
    ('evaluate_platform_decision_rpc'),
    ('get_platform_operational_decisions_rpc'),
    ('get_platform_latest_decision_rpc'),
    ('get_platform_operational_decision_rpc'),
    ('get_platform_decision_timeline_rpc'),
    ('get_platform_decision_health_rpc')
  ) expected(name)
  where not exists(
    select 1 from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname=expected.name
  );

  if v_missing<>0 then
    raise exception 'PLATFORM_DECISION_ASSERTION_FAILED: missing functions %',v_missing;
  end if;

  if not exists(
    select 1 from public.platform_engine_registry
    where engine_code='platform_decision_engine'
      and engine_version='1.0.0'
      and runtime_enabled
      and not is_certified
  ) then
    raise exception 'PLATFORM_DECISION_ASSERTION_FAILED: engine registration invalid';
  end if;

  if (
    select count(*) from public.platform_engine_dependencies
    where dependent_engine_code='platform_decision_engine'
      and dependency_engine_code in (
        'platform_governance_engine','platform_readiness_engine'
      ) and enabled
  )<>2 then
    raise exception 'PLATFORM_DECISION_ASSERTION_FAILED: dependencies invalid';
  end if;

  if (
    select count(*) from public.platform_runtime_policies
    where policy_key in (
      'runtime.decision.deterministic_evaluation',
      'runtime.decision.explicit_readiness_required',
      'runtime.decision.can_authorize_execution',
      'runtime.decision.automatic_dispatch',
      'runtime.decision.automatic_remediation'
    ) and owner_engine_code='platform_decision_engine' and enabled
  )<>5 then
    raise exception 'PLATFORM_DECISION_ASSERTION_FAILED: runtime policies invalid';
  end if;

  if not exists(
    select 1 from public.platform_runtime_policies
    where policy_key='runtime.decision.explicit_readiness_required'
      and policy_value='true'::jsonb and enabled
  ) or not exists(
    select 1 from public.platform_runtime_policies
    where policy_key='runtime.decision.automatic_dispatch'
      and policy_value='false'::jsonb and enabled
  ) or not exists(
    select 1 from public.platform_runtime_policies
    where policy_key='runtime.decision.automatic_remediation'
      and policy_value='false'::jsonb and enabled
  ) then
    raise exception 'PLATFORM_DECISION_ASSERTION_FAILED: safety policies invalid';
  end if;

  if not exists(
    select 1 from public.platform_feature_flags
    where feature_key='runtime.platform_decisions'
      and enabled and rollout_percentage=100
      and owner_engine_code='platform_decision_engine'
  ) then
    raise exception 'PLATFORM_DECISION_ASSERTION_FAILED: feature flag invalid';
  end if;

  if (
    select count(*) from pg_class c
    join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public'
      and c.relname in (
        'platform_operational_decisions','platform_decision_rules','platform_decision_timeline'
      ) and c.relrowsecurity
  )<>3 then
    raise exception 'PLATFORM_DECISION_ASSERTION_FAILED: RLS invalid';
  end if;

  v_health:=public.get_platform_decision_health_rpc();
  if v_health->>'contract_version'<>'platform-decision-health-v1'
     or not (v_health#>>'{controls,can_authorize_execution}')::boolean
     or (v_health#>>'{controls,automatic_dispatch}')::boolean
     or (v_health#>>'{controls,automatic_remediation}')::boolean
     or (v_health#>>'{controls,orchestrator_dispatch}')::boolean then
    raise exception 'PLATFORM_DECISION_ASSERTION_FAILED: health safety invalid';
  end if;

  v_snapshot:=public.get_platform_governance_snapshot_rpc();
  if v_snapshot->>'contract_version'<>'platform-governance-v1.9'
     or not(v_snapshot?'decision_health')
     or not(v_snapshot?'decision_latest')
     or not(v_snapshot?'decision_timeline') then
    raise exception 'PLATFORM_DECISION_ASSERTION_FAILED: governance projection invalid';
  end if;

  if not exists(
    select 1 from public.platform_configuration
    where configuration_key='primary' and schema_version>=88
  ) then
    raise exception 'PLATFORM_DECISION_ASSERTION_FAILED: schema version invalid';
  end if;

  select count(*) into v_actions
  from public.platform_orchestrator_actions
  where created_at>=transaction_timestamp();

  if v_actions<>0 then
    raise exception 'PLATFORM_DECISION_ASSERTION_FAILED: migration generated orchestrator actions (%)',v_actions;
  end if;
end;
$assertions$;

commit;
