-- ============================================================================
-- FANTAGOL
-- Migration 089: Platform Execution Authorization Engine
-- Phase 8.4.7
--
-- Purpose
--   Convert one immutable Platform Operational Decision into one durable,
--   explainable and deterministic execution authorization for critical
--   platform operations.
--
-- Authorization semantics
--   approved / authorize / true  -> authorized / permit / permits_dispatch=true
--   held     / hold      / false -> withheld   / hold   / permits_dispatch=false
--   denied   / deny      / false -> rejected   / reject / permits_dispatch=false
--
-- Safety
--   This engine issues an authorization record only. It cannot create
--   orchestrator actions, dispatch batches, jobs, execution attempts or
--   receipts. Physical dispatch remains a separate explicit responsibility.
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
  'platform_execution_authorization_engine',
  'Platform Execution Authorization Engine','1.0.0','governance','active',
  true,false,null,null,'platform',180,
  '["platform_governance_engine","platform_decision_engine"]'::jsonb,
  jsonb_build_object(
    'phase','8.4.7',
    'contract','platform-execution-authorization-v1',
    'migration',89,
    'authorization_mode','explicit-deterministic',
    'explainable',true,
    'can_permit_dispatch',true,
    'automatic_dispatch',false,
    'automatic_execution',false,
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
    'platform_execution_authorization_engine','platform_governance_engine',
    'required','1.0.0',true,true,array['active','degraded']::text[],true,
    'Execution authorization requires the certified platform governance contract.',
    '{"migration":89}'::jsonb
  ),
  (
    'platform_execution_authorization_engine','platform_decision_engine',
    'runtime','1.0.0',true,false,array['active','degraded']::text[],true,
    'Every execution authorization must derive from one immutable operational decision.',
    '{"migration":89}'::jsonb
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
-- 2. Durable execution authorizations
-- --------------------------------------------------------------------------

create table if not exists public.platform_execution_authorizations (
  execution_authorization_id uuid primary key default gen_random_uuid(),
  authorization_sequence bigint generated always as identity unique,
  contract_version text not null default 'platform-execution-authorization-v1',
  authorization_key text not null unique,
  authorization_scope text not null default 'platform_critical_operations',
  authorization_status text not null,
  authorization_code text not null,
  operational_decision_id uuid not null unique,
  decision_status text not null,
  decision_code text not null,
  decision_authorizes_execution boolean not null,
  permits_dispatch boolean not null default false,
  source text not null,
  correlation_id uuid not null unique default gen_random_uuid(),
  authorized_at timestamptz not null default now(),
  summary text not null,
  rationale jsonb not null default '[]'::jsonb,
  evidence_summary jsonb not null default '{}'::jsonb,
  dispatch_constraints jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),

  constraint platform_execution_authorizations_contract_ck
    check (contract_version='platform-execution-authorization-v1'),
  constraint platform_execution_authorizations_key_ck
    check (authorization_key ~ '^authorization:[a-z0-9_.:-]+$'),
  constraint platform_execution_authorizations_scope_ck
    check (authorization_scope='platform_critical_operations'),
  constraint platform_execution_authorizations_status_ck
    check (authorization_status in ('authorized','withheld','rejected')),
  constraint platform_execution_authorizations_code_ck
    check (authorization_code in ('permit','hold','reject')),
  constraint platform_execution_authorizations_decision_status_ck
    check (decision_status in ('approved','held','denied')),
  constraint platform_execution_authorizations_decision_code_ck
    check (decision_code in ('authorize','hold','deny')),
  constraint platform_execution_authorizations_source_ck
    check (btrim(source)<>''),
  constraint platform_execution_authorizations_summary_ck
    check (btrim(summary)<>''),
  constraint platform_execution_authorizations_rationale_ck
    check (jsonb_typeof(rationale)='array'),
  constraint platform_execution_authorizations_evidence_ck
    check (jsonb_typeof(evidence_summary)='object'),
  constraint platform_execution_authorizations_constraints_ck
    check (jsonb_typeof(dispatch_constraints)='object'),
  constraint platform_execution_authorizations_metadata_ck
    check (jsonb_typeof(metadata)='object'),
  constraint platform_execution_authorizations_mapping_ck
    check (
      (decision_status='approved' and decision_code='authorize'
       and decision_authorizes_execution
       and authorization_status='authorized'
       and authorization_code='permit' and permits_dispatch)
      or
      (decision_status='held' and decision_code='hold'
       and not decision_authorizes_execution
       and authorization_status='withheld'
       and authorization_code='hold' and not permits_dispatch)
      or
      (decision_status='denied' and decision_code='deny'
       and not decision_authorizes_execution
       and authorization_status='rejected'
       and authorization_code='reject' and not permits_dispatch)
    ),
  constraint platform_execution_authorizations_decision_fk
    foreign key (operational_decision_id)
      references public.platform_operational_decisions(operational_decision_id)
      on delete restrict
);

create index if not exists platform_execution_authorizations_status_idx
  on public.platform_execution_authorizations(
    authorization_status,authorized_at desc
  );
create index if not exists platform_execution_authorizations_decision_idx
  on public.platform_execution_authorizations(
    operational_decision_id,authorization_sequence desc
  );

comment on table public.platform_execution_authorizations is
  'Immutable dispatch-permission records derived from immutable operational decisions. They never dispatch work.';

-- --------------------------------------------------------------------------
-- 3. Immutable authorization rule evaluations
-- --------------------------------------------------------------------------

create table if not exists public.platform_execution_authorization_rules (
  execution_authorization_rule_id uuid primary key default gen_random_uuid(),
  rule_sequence bigint generated always as identity unique,
  contract_version text not null default 'platform-execution-authorization-rule-v1',
  execution_authorization_id uuid not null,
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

  constraint platform_execution_authorization_rules_contract_ck
    check (contract_version='platform-execution-authorization-rule-v1'),
  constraint platform_execution_authorization_rules_key_ck
    check (rule_key ~ '^[a-z][a-z0-9_.:-]*$'),
  constraint platform_execution_authorization_rules_category_ck
    check (rule_category in ('decision','authorization','dispatch','safety')),
  constraint platform_execution_authorization_rules_status_ck
    check (rule_status in ('passed','failed')),
  constraint platform_execution_authorization_rules_severity_ck
    check (severity in ('info','critical')),
  constraint platform_execution_authorization_rules_text_ck
    check (btrim(title)<>'' and btrim(description)<>''),
  constraint platform_execution_authorization_rules_evidence_ck
    check (jsonb_typeof(evidence)='object'),
  constraint platform_execution_authorization_rules_metadata_ck
    check (jsonb_typeof(metadata)='object'),
  constraint platform_execution_authorization_rules_blocking_ck
    check ((blocking and rule_status='failed') or not blocking),
  constraint platform_execution_authorization_rules_authorization_fk
    foreign key (execution_authorization_id)
      references public.platform_execution_authorizations(execution_authorization_id)
      on delete restrict,
  constraint platform_execution_authorization_rules_key_uq
    unique (execution_authorization_id,rule_key)
);

create index if not exists platform_execution_authorization_rules_auth_idx
  on public.platform_execution_authorization_rules(
    execution_authorization_id,rule_sequence
  );

comment on table public.platform_execution_authorization_rules is
  'Immutable evidence explaining how an execution authorization was derived.';

-- --------------------------------------------------------------------------
-- 4. Append-only authorization timeline
-- --------------------------------------------------------------------------

create table if not exists public.platform_execution_authorization_timeline (
  execution_authorization_timeline_event_id uuid primary key default gen_random_uuid(),
  event_sequence bigint generated always as identity unique,
  contract_version text not null default 'platform-execution-authorization-timeline-v1',
  execution_authorization_id uuid not null,
  event_type text not null,
  event_status text not null,
  authorization_status text not null,
  correlation_id uuid not null,
  occurred_at timestamptz not null default now(),
  summary text not null,
  details jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,

  constraint platform_execution_authorization_timeline_contract_ck
    check (contract_version='platform-execution-authorization-timeline-v1'),
  constraint platform_execution_authorization_timeline_type_ck
    check (event_type in (
      'authorization_evaluated','authorization_granted',
      'authorization_withheld','authorization_rejected'
    )),
  constraint platform_execution_authorization_timeline_event_status_ck
    check (event_status in ('completed','recorded')),
  constraint platform_execution_authorization_timeline_auth_status_ck
    check (authorization_status in ('authorized','withheld','rejected')),
  constraint platform_execution_authorization_timeline_summary_ck
    check (btrim(summary)<>''),
  constraint platform_execution_authorization_timeline_details_ck
    check (jsonb_typeof(details)='object'),
  constraint platform_execution_authorization_timeline_metadata_ck
    check (jsonb_typeof(metadata)='object'),
  constraint platform_execution_authorization_timeline_auth_fk
    foreign key (execution_authorization_id)
      references public.platform_execution_authorizations(execution_authorization_id)
      on delete restrict
);

create index if not exists platform_execution_authorization_timeline_auth_idx
  on public.platform_execution_authorization_timeline(
    execution_authorization_id,event_sequence
  );
create index if not exists platform_execution_authorization_timeline_status_idx
  on public.platform_execution_authorization_timeline(
    authorization_status,occurred_at desc
  );

comment on table public.platform_execution_authorization_timeline is
  'Append-only timeline for platform execution authorization evaluations.';

-- --------------------------------------------------------------------------
-- 5. Immutability guards
-- --------------------------------------------------------------------------

create or replace function public.protect_platform_execution_authorization_immutable_row()
returns trigger
language plpgsql
security definer
set search_path=public,pg_temp
as $function$
begin
  raise exception 'PLATFORM_EXECUTION_AUTHORIZATION_ROW_IMMUTABLE'
    using errcode='55000';
end;
$function$;

drop trigger if exists trg_protect_platform_execution_authorizations
  on public.platform_execution_authorizations;
create trigger trg_protect_platform_execution_authorizations
before update or delete on public.platform_execution_authorizations
for each row execute function
  public.protect_platform_execution_authorization_immutable_row();

drop trigger if exists trg_protect_platform_execution_authorization_rules
  on public.platform_execution_authorization_rules;
create trigger trg_protect_platform_execution_authorization_rules
before update or delete on public.platform_execution_authorization_rules
for each row execute function
  public.protect_platform_execution_authorization_immutable_row();

drop trigger if exists trg_protect_platform_execution_authorization_timeline
  on public.platform_execution_authorization_timeline;
create trigger trg_protect_platform_execution_authorization_timeline
before update or delete on public.platform_execution_authorization_timeline
for each row execute function
  public.protect_platform_execution_authorization_immutable_row();

-- --------------------------------------------------------------------------
-- 6. Deterministic authorization evaluator
-- --------------------------------------------------------------------------

create or replace function public.evaluate_platform_execution_authorization_rpc(
  p_operational_decision_id uuid default null,
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
  v_authorized_at timestamptz:=now();
  v_authorization_id uuid:=gen_random_uuid();
  v_source text:=btrim(coalesce(p_source,''));
  v_correlation_id uuid:=coalesce(p_correlation_id,gen_random_uuid());
  v_decision public.platform_operational_decisions%rowtype;
  v_existing public.platform_execution_authorizations%rowtype;
  v_authorization_key text;
  v_authorization_status text;
  v_authorization_code text;
  v_permits_dispatch boolean:=false;
  v_summary text;
  v_rationale jsonb:='[]'::jsonb;
  v_auto_dispatch_disabled boolean:=false;
  v_separate_dispatch_required boolean:=false;
  v_actions_before bigint:=0;
  v_actions_after bigint:=0;
  v_batches_before bigint:=0;
  v_batches_after bigint:=0;
  v_rule_count integer:=5;
  v_duration_ms integer;
begin
  if v_source='' then
    raise exception 'PLATFORM_EXECUTION_AUTHORIZATION_SOURCE_REQUIRED'
      using errcode='22023';
  end if;

  select * into v_existing
  from public.platform_execution_authorizations
  where correlation_id=v_correlation_id;

  if found then
    return jsonb_build_object(
      'contract_version','platform-execution-authorization-evaluation-v1',
      'execution_authorization_id',v_existing.execution_authorization_id,
      'authorization_sequence',v_existing.authorization_sequence,
      'authorization_status',v_existing.authorization_status,
      'authorization_code',v_existing.authorization_code,
      'permits_dispatch',v_existing.permits_dispatch,
      'operational_decision_id',v_existing.operational_decision_id,
      'correlation_id',v_existing.correlation_id,
      'authorization_reused',true,
      'rule_count',(
        select count(*)
        from public.platform_execution_authorization_rules r
        where r.execution_authorization_id=
          v_existing.execution_authorization_id
      )
    );
  end if;

  if p_operational_decision_id is null then
    select * into v_decision
    from public.platform_operational_decisions
    order by decision_sequence desc
    limit 1;
  else
    select * into v_decision
    from public.platform_operational_decisions
    where operational_decision_id=p_operational_decision_id;
  end if;

  if not found then
    raise exception 'PLATFORM_OPERATIONAL_DECISION_NOT_FOUND'
      using errcode='P0002';
  end if;

  select * into v_existing
  from public.platform_execution_authorizations
  where operational_decision_id=v_decision.operational_decision_id;

  if found then
    return jsonb_build_object(
      'contract_version','platform-execution-authorization-evaluation-v1',
      'execution_authorization_id',v_existing.execution_authorization_id,
      'authorization_sequence',v_existing.authorization_sequence,
      'authorization_status',v_existing.authorization_status,
      'authorization_code',v_existing.authorization_code,
      'permits_dispatch',v_existing.permits_dispatch,
      'operational_decision_id',v_existing.operational_decision_id,
      'correlation_id',v_existing.correlation_id,
      'authorization_reused',true,
      'rule_count',(
        select count(*)
        from public.platform_execution_authorization_rules r
        where r.execution_authorization_id=
          v_existing.execution_authorization_id
      )
    );
  end if;

  select coalesce((policy_value#>>'{}')::boolean,false)
  into v_auto_dispatch_disabled
  from public.platform_runtime_policies
  where policy_key='runtime.execution_authorization.automatic_dispatch'
    and enabled;
  v_auto_dispatch_disabled:=not coalesce(v_auto_dispatch_disabled,true);

  select coalesce((policy_value#>>'{}')::boolean,false)
  into v_separate_dispatch_required
  from public.platform_runtime_policies
  where policy_key='runtime.execution_authorization.separate_dispatch_required'
    and enabled;

  if not v_auto_dispatch_disabled then
    raise exception 'PLATFORM_EXECUTION_AUTHORIZATION_AUTOMATIC_DISPATCH_POLICY_INVALID';
  end if;
  if not v_separate_dispatch_required then
    raise exception 'PLATFORM_EXECUTION_AUTHORIZATION_SEPARATE_DISPATCH_POLICY_REQUIRED';
  end if;

  select count(*) into v_actions_before
  from public.platform_orchestrator_actions;
  select count(*) into v_batches_before
  from public.platform_dispatch_batches;

  if v_decision.decision_status='approved'
     and v_decision.decision_code='authorize'
     and v_decision.authorizes_execution then
    v_authorization_status:='authorized';
    v_authorization_code:='permit';
    v_permits_dispatch:=true;
    v_summary:='Critical platform dispatch is explicitly permitted by an approved operational decision.';
    v_rationale:=jsonb_build_array(jsonb_build_object(
      'decision_status',v_decision.decision_status,
      'decision_code',v_decision.decision_code,
      'authorizes_execution',v_decision.authorizes_execution,
      'reason','The upstream immutable decision explicitly authorizes execution.'
    ));
  elsif v_decision.decision_status='held'
        and v_decision.decision_code='hold'
        and not v_decision.authorizes_execution then
    v_authorization_status:='withheld';
    v_authorization_code:='hold';
    v_permits_dispatch:=false;
    v_summary:='Critical platform dispatch is withheld while the operational decision remains held.';
    v_rationale:=jsonb_build_array(jsonb_build_object(
      'decision_status',v_decision.decision_status,
      'decision_code',v_decision.decision_code,
      'authorizes_execution',v_decision.authorizes_execution,
      'reason','A held decision cannot permit dispatch.'
    ));
  elsif v_decision.decision_status='denied'
        and v_decision.decision_code='deny'
        and not v_decision.authorizes_execution then
    v_authorization_status:='rejected';
    v_authorization_code:='reject';
    v_permits_dispatch:=false;
    v_summary:='Critical platform dispatch is rejected by the denied operational decision.';
    v_rationale:=coalesce(v_decision.rationale,'[]'::jsonb);
  else
    raise exception 'PLATFORM_EXECUTION_AUTHORIZATION_DECISION_MAPPING_INVALID';
  end if;

  v_authorization_key:=
    'authorization:platform-critical:'||v_decision.operational_decision_id::text;

  insert into public.platform_execution_authorizations(
    execution_authorization_id,authorization_key,authorization_scope,
    authorization_status,authorization_code,operational_decision_id,
    decision_status,decision_code,decision_authorizes_execution,
    permits_dispatch,source,correlation_id,authorized_at,summary,rationale,
    evidence_summary,dispatch_constraints,metadata
  ) values (
    v_authorization_id,v_authorization_key,'platform_critical_operations',
    v_authorization_status,v_authorization_code,
    v_decision.operational_decision_id,v_decision.decision_status,
    v_decision.decision_code,v_decision.authorizes_execution,
    v_permits_dispatch,v_source,v_correlation_id,v_authorized_at,v_summary,
    v_rationale,
    jsonb_build_object(
      'decision_sequence',v_decision.decision_sequence,
      'decision_correlation_id',v_decision.correlation_id,
      'readiness_assessment_id',v_decision.readiness_assessment_id,
      'readiness_status',v_decision.readiness_status,
      'readiness_score',v_decision.readiness_score
    ),
    jsonb_build_object(
      'automatic_dispatch',false,
      'automatic_execution',false,
      'requires_separate_dispatch_command',true,
      'authorization_scope','platform_critical_operations',
      'single_use_enforced',false
    ),
    jsonb_build_object('migration',89)
  );

  insert into public.platform_execution_authorization_rules(
    execution_authorization_id,rule_key,rule_category,rule_status,severity,
    title,description,observed_value,expected_value,evidence,blocking,
    remediation_hint,evaluated_at,metadata
  ) values
  (
    v_authorization_id,'decision.snapshot_bound','decision','passed','info',
    'Immutable operational decision bound',
    'The authorization must reference one existing immutable operational decision.',
    to_jsonb(v_decision.operational_decision_id),
    to_jsonb(v_decision.operational_decision_id),
    jsonb_build_object('decision_sequence',v_decision.decision_sequence),
    false,null,v_authorized_at,'{"migration":89}'::jsonb
  ),
  (
    v_authorization_id,'authorization.status_mapping','authorization',
    'passed','info','Decision-to-authorization mapping',
    'Approved maps to permit, held maps to hold and denied maps to reject.',
    jsonb_build_object(
      'decision_status',v_decision.decision_status,
      'authorization_status',v_authorization_status,
      'authorization_code',v_authorization_code
    ),
    jsonb_build_object(
      'decision_status',v_decision.decision_status,
      'authorization_status',v_authorization_status,
      'authorization_code',v_authorization_code
    ),
    jsonb_build_object('decision_code',v_decision.decision_code),
    false,null,v_authorized_at,'{"migration":89}'::jsonb
  ),
  (
    v_authorization_id,'authorization.decision_capability_consistent',
    'authorization','passed','info','Decision capability consistency',
    'Dispatch permission must exactly match the upstream decision capability.',
    to_jsonb(v_permits_dispatch),
    to_jsonb(v_decision.authorizes_execution),
    jsonb_build_object(
      'operational_decision_id',v_decision.operational_decision_id
    ),false,null,v_authorized_at,'{"migration":89}'::jsonb
  ),
  (
    v_authorization_id,'safety.automatic_dispatch_disabled','safety',
    'passed','info','Automatic dispatch disabled',
    'The authorization engine cannot create orchestrator actions or dispatch batches.',
    to_jsonb(v_auto_dispatch_disabled),
    'true'::jsonb,
    jsonb_build_object(
      'policy_key','runtime.execution_authorization.automatic_dispatch'
    ),false,null,v_authorized_at,'{"migration":89}'::jsonb
  ),
  (
    v_authorization_id,'safety.separate_dispatch_required','dispatch',
    'passed','info','Separate dispatch command required',
    'A permitted authorization still requires a separate dispatch command.',
    to_jsonb(v_separate_dispatch_required),
    'true'::jsonb,
    jsonb_build_object(
      'policy_key','runtime.execution_authorization.separate_dispatch_required'
    ),false,null,v_authorized_at,'{"migration":89}'::jsonb
  );

  insert into public.platform_execution_authorization_timeline(
    execution_authorization_id,event_type,event_status,
    authorization_status,correlation_id,occurred_at,summary,details,metadata
  ) values
  (
    v_authorization_id,'authorization_evaluated','completed',
    v_authorization_status,v_correlation_id,v_authorized_at,
    'Platform execution authorization evaluation completed.',
    jsonb_build_object(
      'source',v_source,
      'rule_count',v_rule_count,
      'operational_decision_id',v_decision.operational_decision_id,
      'decision_status',v_decision.decision_status,
      'decision_code',v_decision.decision_code
    ),'{"migration":89}'::jsonb
  ),
  (
    v_authorization_id,
    case v_authorization_status
      when 'authorized' then 'authorization_granted'
      when 'withheld' then 'authorization_withheld'
      else 'authorization_rejected'
    end,
    'recorded',v_authorization_status,v_correlation_id,v_authorized_at,
    v_summary,
    jsonb_build_object(
      'authorization_code',v_authorization_code,
      'permits_dispatch',v_permits_dispatch,
      'rationale',v_rationale
    ),'{"migration":89}'::jsonb
  );

  select count(*) into v_actions_after
  from public.platform_orchestrator_actions;
  select count(*) into v_batches_after
  from public.platform_dispatch_batches;

  if v_actions_after<>v_actions_before or v_batches_after<>v_batches_before then
    raise exception 'PLATFORM_EXECUTION_AUTHORIZATION_SAFETY_BOUNDARY_VIOLATED';
  end if;

  v_duration_ms:=greatest(
    0,round(extract(epoch from (clock_timestamp()-v_started_at))*1000)::integer
  );

  return jsonb_build_object(
    'contract_version','platform-execution-authorization-evaluation-v1',
    'execution_authorization_id',v_authorization_id,
    'authorization_status',v_authorization_status,
    'authorization_code',v_authorization_code,
    'permits_dispatch',v_permits_dispatch,
    'operational_decision_id',v_decision.operational_decision_id,
    'decision_status',v_decision.decision_status,
    'correlation_id',v_correlation_id,
    'authorization_reused',false,
    'rule_count',v_rule_count,
    'timeline_event_count',2,
    'duration_ms',v_duration_ms
  );
end;
$function$;

-- --------------------------------------------------------------------------
-- 7. Read models
-- --------------------------------------------------------------------------

create or replace function public.get_platform_execution_authorizations_rpc(
  p_status text default null,
  p_limit integer default 100
)
returns jsonb
language sql
stable
security definer
set search_path=public,pg_temp
as $function$
  select coalesce(jsonb_agg(to_jsonb(a) order by a.authorization_sequence desc),'[]'::jsonb)
  from (
    select *
    from public.platform_execution_authorizations x
    where p_status is null or x.authorization_status=p_status
    order by x.authorization_sequence desc
    limit greatest(1,least(coalesce(p_limit,100),500))
  ) a;
$function$;

create or replace function public.get_platform_execution_authorization_rpc(
  p_execution_authorization_id uuid
)
returns jsonb
language sql
stable
security definer
set search_path=public,pg_temp
as $function$
  select case when a.execution_authorization_id is null then null else
    to_jsonb(a)
    || jsonb_build_object(
      'rules',coalesce((
        select jsonb_agg(to_jsonb(r) order by r.rule_sequence)
        from public.platform_execution_authorization_rules r
        where r.execution_authorization_id=a.execution_authorization_id
      ),'[]'::jsonb),
      'timeline',coalesce((
        select jsonb_agg(to_jsonb(t) order by t.event_sequence)
        from public.platform_execution_authorization_timeline t
        where t.execution_authorization_id=a.execution_authorization_id
      ),'[]'::jsonb),
      'operational_decision',
        public.get_platform_operational_decision_rpc(a.operational_decision_id)
    ) end
  from public.platform_execution_authorizations a
  where a.execution_authorization_id=p_execution_authorization_id;
$function$;

create or replace function public.get_platform_latest_execution_authorization_rpc()
returns jsonb
language sql
stable
security definer
set search_path=public,pg_temp
as $function$
  select public.get_platform_execution_authorization_rpc(
    (select execution_authorization_id
     from public.platform_execution_authorizations
     order by authorization_sequence desc limit 1)
  );
$function$;

create or replace function public.get_platform_execution_authorization_timeline_rpc(
  p_execution_authorization_id uuid default null,
  p_authorization_status text default null,
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
    select *
    from public.platform_execution_authorization_timeline x
    where (p_execution_authorization_id is null
           or x.execution_authorization_id=p_execution_authorization_id)
      and (p_authorization_status is null
           or x.authorization_status=p_authorization_status)
    order by x.event_sequence desc
    limit greatest(1,least(coalesce(p_limit,100),500))
  ) t;
$function$;

create or replace function public.get_platform_execution_authorization_health_rpc()
returns jsonb
language sql
stable
security definer
set search_path=public,pg_temp
as $function$
  select jsonb_build_object(
    'contract_version','platform-execution-authorization-health-v1',
    'generated_at',now(),
    'history',jsonb_build_object(
      'authorization_count',(select count(*) from public.platform_execution_authorizations),
      'authorized_count',(select count(*) from public.platform_execution_authorizations where authorization_status='authorized'),
      'withheld_count',(select count(*) from public.platform_execution_authorizations where authorization_status='withheld'),
      'rejected_count',(select count(*) from public.platform_execution_authorizations where authorization_status='rejected'),
      'rule_count',(select count(*) from public.platform_execution_authorization_rules),
      'timeline_event_count',(select count(*) from public.platform_execution_authorization_timeline)
    ),
    'controls',jsonb_build_object(
      'can_permit_dispatch',true,
      'automatic_dispatch',false,
      'automatic_execution',false,
      'automatic_remediation',false,
      'separate_dispatch_required',true,
      'orchestrator_action_creation',false,
      'dispatch_batch_creation',false
    ),
    'latest_authorization',public.get_platform_latest_execution_authorization_rpc()
  );
$function$;

-- --------------------------------------------------------------------------
-- 8. Security, RLS and grants
-- --------------------------------------------------------------------------

alter table public.platform_execution_authorizations enable row level security;
alter table public.platform_execution_authorization_rules enable row level security;
alter table public.platform_execution_authorization_timeline enable row level security;

revoke all on public.platform_execution_authorizations from public,anon,authenticated;
revoke all on public.platform_execution_authorization_rules from public,anon,authenticated;
revoke all on public.platform_execution_authorization_timeline from public,anon,authenticated;
grant all on public.platform_execution_authorizations to service_role;
grant all on public.platform_execution_authorization_rules to service_role;
grant all on public.platform_execution_authorization_timeline to service_role;

drop policy if exists platform_execution_authorizations_service_all
  on public.platform_execution_authorizations;
create policy platform_execution_authorizations_service_all
  on public.platform_execution_authorizations
  for all to service_role using (true) with check (true);

drop policy if exists platform_execution_authorization_rules_service_all
  on public.platform_execution_authorization_rules;
create policy platform_execution_authorization_rules_service_all
  on public.platform_execution_authorization_rules
  for all to service_role using (true) with check (true);

drop policy if exists platform_execution_authorization_timeline_service_all
  on public.platform_execution_authorization_timeline;
create policy platform_execution_authorization_timeline_service_all
  on public.platform_execution_authorization_timeline
  for all to service_role using (true) with check (true);

revoke all on function public.evaluate_platform_execution_authorization_rpc(uuid,text,uuid) from public,anon,authenticated;
grant execute on function public.evaluate_platform_execution_authorization_rpc(uuid,text,uuid) to service_role;

revoke all on function public.get_platform_execution_authorizations_rpc(text,integer) from public,anon;
revoke all on function public.get_platform_execution_authorization_rpc(uuid) from public,anon;
revoke all on function public.get_platform_latest_execution_authorization_rpc() from public,anon;
revoke all on function public.get_platform_execution_authorization_timeline_rpc(uuid,text,integer) from public,anon;
revoke all on function public.get_platform_execution_authorization_health_rpc() from public,anon;
grant execute on function public.get_platform_execution_authorizations_rpc(text,integer) to authenticated,service_role;
grant execute on function public.get_platform_execution_authorization_rpc(uuid) to authenticated,service_role;
grant execute on function public.get_platform_latest_execution_authorization_rpc() to authenticated,service_role;
grant execute on function public.get_platform_execution_authorization_timeline_rpc(uuid,text,integer) to authenticated,service_role;
grant execute on function public.get_platform_execution_authorization_health_rpc() to authenticated,service_role;

-- --------------------------------------------------------------------------
-- 9. Runtime policies and feature flag
-- --------------------------------------------------------------------------

insert into public.platform_runtime_policies(
  policy_key,policy_name,description,policy_type,policy_value,
  validation_contract,owner_engine_code,enforcement_level,enabled,metadata
)
values
  (
    'runtime.execution_authorization.deterministic_evaluation',
    'Deterministic execution authorization evaluation',
    'The same immutable decision always maps to the same authorization.',
    'boolean','true'::jsonb,'{}'::jsonb,
    'platform_execution_authorization_engine','critical',true,
    '{"migration":89}'::jsonb
  ),
  (
    'runtime.execution_authorization.explicit_decision_required',
    'Explicit operational decision required',
    'Every authorization must reference one immutable operational decision.',
    'boolean','true'::jsonb,'{}'::jsonb,
    'platform_execution_authorization_engine','critical',true,
    '{"migration":89}'::jsonb
  ),
  (
    'runtime.execution_authorization.can_permit_dispatch',
    'Dispatch permission capability',
    'Only an authorization derived from an approved decision may permit dispatch.',
    'boolean','true'::jsonb,'{}'::jsonb,
    'platform_execution_authorization_engine','critical',true,
    '{"migration":89,"safety":"authorization-boundary"}'::jsonb
  ),
  (
    'runtime.execution_authorization.automatic_dispatch',
    'Execution authorization automatic dispatch',
    'The authorization engine cannot create orchestrator actions or dispatch batches.',
    'boolean','false'::jsonb,'{}'::jsonb,
    'platform_execution_authorization_engine','critical',true,
    '{"migration":89,"safety":"no-automatic-dispatch"}'::jsonb
  ),
  (
    'runtime.execution_authorization.automatic_execution',
    'Execution authorization automatic execution',
    'The authorization engine cannot execute runtime work.',
    'boolean','false'::jsonb,'{}'::jsonb,
    'platform_execution_authorization_engine','critical',true,
    '{"migration":89,"safety":"no-automatic-execution"}'::jsonb
  ),
  (
    'runtime.execution_authorization.separate_dispatch_required',
    'Separate dispatch command required',
    'A permitted authorization requires a separate explicit dispatch command.',
    'boolean','true'::jsonb,'{}'::jsonb,
    'platform_execution_authorization_engine','critical',true,
    '{"migration":89,"safety":"separation-of-duties"}'::jsonb
  ),
  (
    'runtime.execution_authorization.automatic_remediation',
    'Execution authorization automatic remediation',
    'The authorization layer cannot mutate incidents, recommendations, readiness or decisions.',
    'boolean','false'::jsonb,'{}'::jsonb,
    'platform_execution_authorization_engine','critical',true,
    '{"migration":89,"safety":"no-automatic-remediation"}'::jsonb
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
  'runtime.execution_authorizations','Platform execution authorization engine',
  'Expose immutable dispatch permissions, rules, timeline and health read models.',
  true,100,'service',
  array['development','preview','staging','production','test']::text[],
  'platform_execution_authorization_engine',
  '{"contract":"platform-execution-authorization-v1","migration":89}'::jsonb
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
-- 10. Governance Snapshot v2.0
-- --------------------------------------------------------------------------

create or replace function public.get_platform_governance_snapshot_rpc()
returns jsonb
language sql
stable
security definer
set search_path=public,pg_temp
as $function$
  select jsonb_build_object(
    'contract_version','platform-governance-v2.0','generated_at',now(),
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
    'execution_authorization_health',public.get_platform_execution_authorization_health_rpc(),
    'execution_authorization_latest',public.get_platform_latest_execution_authorization_rpc(),
    'execution_authorization_timeline',public.get_platform_execution_authorization_timeline_rpc(null,null,100),
    'feature_flags',public.get_platform_feature_flags_rpc(null,false),
    'runtime_policies',public.get_platform_runtime_policies_rpc(null,false),
    'capabilities',public.get_platform_capabilities_rpc(null,false)
  );
$function$;

revoke all on function public.get_platform_governance_snapshot_rpc() from public,anon;
grant execute on function public.get_platform_governance_snapshot_rpc() to authenticated,service_role;

update public.platform_configuration
set schema_version=greatest(schema_version,89),
    metadata=metadata || jsonb_build_object(
      'phase','8.4.7',
      'governance_contract','platform-governance-v2.0',
      'platform_execution_authorization_contract',
        'platform-execution-authorization-v1',
      'platform_execution_authorization_migration',89
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
  v_batches bigint;
begin
  select count(*) into v_missing
  from (values
    ('platform_execution_authorizations'),
    ('platform_execution_authorization_rules'),
    ('platform_execution_authorization_timeline')
  ) expected(name)
  where to_regclass('public.'||expected.name) is null;

  if v_missing<>0 then
    raise exception
      'PLATFORM_EXECUTION_AUTHORIZATION_ASSERTION_FAILED: missing tables %',
      v_missing;
  end if;

  if not exists (
    select 1 from public.platform_engine_registry
    where engine_code='platform_execution_authorization_engine'
      and engine_version='1.0.0'
      and runtime_enabled
  ) then
    raise exception
      'PLATFORM_EXECUTION_AUTHORIZATION_ASSERTION_FAILED: engine registry';
  end if;

  if (
    select count(*) from public.platform_engine_dependencies
    where dependent_engine_code='platform_execution_authorization_engine'
      and enabled
  )<>2 then
    raise exception
      'PLATFORM_EXECUTION_AUTHORIZATION_ASSERTION_FAILED: dependencies';
  end if;

  if (
    select count(*) from public.platform_runtime_policies
    where policy_key in (
      'runtime.execution_authorization.deterministic_evaluation',
      'runtime.execution_authorization.explicit_decision_required',
      'runtime.execution_authorization.can_permit_dispatch',
      'runtime.execution_authorization.automatic_dispatch',
      'runtime.execution_authorization.automatic_execution',
      'runtime.execution_authorization.separate_dispatch_required',
      'runtime.execution_authorization.automatic_remediation'
    ) and enabled
  )<>7 then
    raise exception
      'PLATFORM_EXECUTION_AUTHORIZATION_ASSERTION_FAILED: runtime policies';
  end if;

  if exists (
    select 1 from public.platform_runtime_policies
    where policy_key in (
      'runtime.execution_authorization.automatic_dispatch',
      'runtime.execution_authorization.automatic_execution',
      'runtime.execution_authorization.automatic_remediation'
    ) and enabled and (policy_value#>>'{}')::boolean
  ) then
    raise exception
      'PLATFORM_EXECUTION_AUTHORIZATION_ASSERTION_FAILED: automatic capability enabled';
  end if;

  if not exists (
    select 1 from public.platform_runtime_policies
    where policy_key='runtime.execution_authorization.separate_dispatch_required'
      and enabled and (policy_value#>>'{}')::boolean
  ) then
    raise exception
      'PLATFORM_EXECUTION_AUTHORIZATION_ASSERTION_FAILED: separate dispatch disabled';
  end if;

  if not exists (
    select 1 from public.platform_feature_flags
    where feature_key='runtime.execution_authorizations' and enabled
  ) then
    raise exception
      'PLATFORM_EXECUTION_AUTHORIZATION_ASSERTION_FAILED: feature flag';
  end if;

  v_health:=public.get_platform_execution_authorization_health_rpc();
  if v_health->>'contract_version'<>
       'platform-execution-authorization-health-v1'
     or (v_health#>>'{controls,automatic_dispatch}')::boolean
     or (v_health#>>'{controls,automatic_execution}')::boolean
     or (v_health#>>'{controls,automatic_remediation}')::boolean
     or not (v_health#>>'{controls,separate_dispatch_required}')::boolean
  then
    raise exception
      'PLATFORM_EXECUTION_AUTHORIZATION_ASSERTION_FAILED: health safety contract';
  end if;

  v_snapshot:=public.get_platform_governance_snapshot_rpc();
  if v_snapshot->>'contract_version'<>'platform-governance-v2.0'
     or not (v_snapshot ? 'execution_authorization_health')
     or not (v_snapshot ? 'execution_authorization_latest')
     or not (v_snapshot ? 'execution_authorization_timeline')
  then
    raise exception
      'PLATFORM_EXECUTION_AUTHORIZATION_ASSERTION_FAILED: governance projection';
  end if;

  if not exists (
    select 1 from public.platform_configuration
    where configuration_key='primary' and schema_version>=89
  ) then
    raise exception
      'PLATFORM_EXECUTION_AUTHORIZATION_ASSERTION_FAILED: schema version';
  end if;

  select count(*) into v_actions from public.platform_orchestrator_actions;
  select count(*) into v_batches from public.platform_dispatch_batches;

  raise notice
    'MIGRATION 089 INSTALLED: actions=%, batches=%, automatic_dispatch=false, separate_dispatch=true',
    v_actions,v_batches;
end;
$assertions$;

commit;
