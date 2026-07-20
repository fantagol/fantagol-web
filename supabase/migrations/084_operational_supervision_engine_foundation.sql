-- ============================================================================
-- FANTAGOL
-- Migration 084: Operational Supervision Engine Foundation
-- Phase 8.4.2
--
-- Purpose
--   Add the first certified operational interpretation layer above Platform
--   Telemetry. The engine consumes immutable telemetry snapshots, SLA
--   evaluations and durable telemetry alerts, producing immutable supervision
--   evaluations, deduplicated operational findings and an append-only timeline.
--
-- Safety
--   Evaluation is explicit through service-role RPCs. This migration creates
--   no scheduler, incident, recommendation, notification, orchestrator action
--   or automatic remediation. PostgreSQL remains the authoritative source.
-- ============================================================================

begin;

-- --------------------------------------------------------------------------
-- 1. Register the Operational Supervision Engine
-- --------------------------------------------------------------------------

insert into public.platform_engine_registry (
  engine_code,
  engine_name,
  engine_version,
  engine_kind,
  lifecycle_status,
  runtime_enabled,
  is_certified,
  certification_version,
  certified_at,
  owner_scope,
  installation_order,
  dependencies,
  metadata
)
values (
  'platform_supervision_engine',
  'Platform Operational Supervision Engine',
  '1.0.0',
  'observability',
  'active',
  true,
  false,
  null,
  null,
  'platform',
  130,
  '["platform_governance_engine","platform_orchestrator_engine","platform_telemetry_engine"]'::jsonb,
  jsonb_build_object(
    'phase','8.4.2',
    'contract','platform-operational-supervision-v1',
    'migration',84,
    'evaluation_mode','explicit-telemetry-interpretation',
    'finding_mode','durable-deduplicated-lifecycle',
    'automatic_remediation',false
  )
)
on conflict (engine_code) do update
set engine_name = excluded.engine_name,
    engine_version = excluded.engine_version,
    engine_kind = excluded.engine_kind,
    lifecycle_status = excluded.lifecycle_status,
    runtime_enabled = excluded.runtime_enabled,
    is_certified = excluded.is_certified,
    certification_version = excluded.certification_version,
    certified_at = excluded.certified_at,
    owner_scope = excluded.owner_scope,
    installation_order = excluded.installation_order,
    dependencies = excluded.dependencies,
    metadata = public.platform_engine_registry.metadata || excluded.metadata,
    updated_at = now();

insert into public.platform_engine_dependencies (
  dependent_engine_code,
  dependency_engine_code,
  dependency_type,
  minimum_version,
  requires_runtime_enabled,
  requires_certification,
  allowed_dependency_statuses,
  enabled,
  rationale,
  metadata
)
values
  (
    'platform_supervision_engine',
    'platform_governance_engine',
    'required',
    '1.0.0',
    true,
    true,
    array['active','degraded']::text[],
    true,
    'Operational supervision is governed by the certified platform registry, policies and capabilities.',
    '{"migration":84,"contract":"platform-operational-supervision-v1"}'::jsonb
  ),
  (
    'platform_supervision_engine',
    'platform_orchestrator_engine',
    'runtime',
    '1.2.0',
    true,
    true,
    array['active','degraded']::text[],
    true,
    'Operational supervision interprets orchestrator and dispatcher runtime evidence without dispatching actions.',
    '{"migration":84,"contract":"platform-operational-supervision-v1"}'::jsonb
  ),
  (
    'platform_supervision_engine',
    'platform_telemetry_engine',
    'runtime',
    '1.0.0',
    true,
    true,
    array['active','degraded']::text[],
    true,
    'Certified telemetry snapshots, SLA evaluations and alerts are the authoritative supervision evidence.',
    '{"migration":84,"contract":"platform-operational-supervision-v1"}'::jsonb
  )
on conflict (dependent_engine_code, dependency_engine_code) do update
set dependency_type = excluded.dependency_type,
    minimum_version = excluded.minimum_version,
    requires_runtime_enabled = excluded.requires_runtime_enabled,
    requires_certification = excluded.requires_certification,
    allowed_dependency_statuses = excluded.allowed_dependency_statuses,
    enabled = excluded.enabled,
    rationale = excluded.rationale,
    metadata = public.platform_engine_dependencies.metadata || excluded.metadata,
    updated_at = now();

-- --------------------------------------------------------------------------
-- 2. Immutable operational supervision evaluations
-- --------------------------------------------------------------------------

create table if not exists public.platform_supervision_evaluations (
  supervision_evaluation_id uuid primary key default gen_random_uuid(),
  evaluation_sequence bigint generated always as identity unique,
  contract_version text not null default 'platform-supervision-evaluation-v1',
  evaluation_source text not null default 'manual',
  evaluation_status text not null,
  telemetry_snapshot_id uuid not null,
  correlation_id uuid not null default gen_random_uuid(),
  evaluation_started_at timestamptz not null,
  evaluated_at timestamptz not null default now(),
  evaluation_duration_ms bigint not null,
  platform_health_score numeric(5,2) not null,
  platform_health_status text not null,
  finding_count integer not null default 0,
  critical_finding_count integer not null default 0,
  warning_finding_count integer not null default 0,
  evaluation_summary jsonb not null default '{}'::jsonb,
  evidence jsonb not null default '{}'::jsonb,
  evaluator_version text not null default '1.0.0',
  metadata jsonb not null default '{}'::jsonb,

  constraint platform_supervision_evaluations_contract_ck
    check (contract_version = 'platform-supervision-evaluation-v1'),
  constraint platform_supervision_evaluations_source_ck
    check (evaluation_source in ('scheduled','manual','startup','recovery','maintenance','test')),
  constraint platform_supervision_evaluations_status_ck
    check (evaluation_status in ('healthy','attention_required','critical','insufficient_evidence','failed')),
  constraint platform_supervision_evaluations_duration_ck
    check (evaluation_duration_ms >= 0),
  constraint platform_supervision_evaluations_health_score_ck
    check (platform_health_score between 0 and 100),
  constraint platform_supervision_evaluations_health_status_ck
    check (platform_health_status in ('healthy','degraded','critical')),
  constraint platform_supervision_evaluations_counts_ck
    check (
      finding_count >= 0
      and critical_finding_count >= 0
      and warning_finding_count >= 0
      and critical_finding_count + warning_finding_count <= finding_count
    ),
  constraint platform_supervision_evaluations_summary_ck
    check (jsonb_typeof(evaluation_summary) = 'object'),
  constraint platform_supervision_evaluations_evidence_ck
    check (jsonb_typeof(evidence) = 'object'),
  constraint platform_supervision_evaluations_metadata_ck
    check (jsonb_typeof(metadata) = 'object'),
  constraint platform_supervision_evaluations_snapshot_fk
    foreign key (telemetry_snapshot_id)
    references public.platform_telemetry_snapshots(telemetry_snapshot_id)
    on delete restrict
);

create index if not exists platform_supervision_evaluations_timeline_idx
  on public.platform_supervision_evaluations (evaluated_at desc);

create index if not exists platform_supervision_evaluations_status_idx
  on public.platform_supervision_evaluations (evaluation_status, evaluated_at desc);

create index if not exists platform_supervision_evaluations_snapshot_idx
  on public.platform_supervision_evaluations (telemetry_snapshot_id);

comment on table public.platform_supervision_evaluations is
  'Immutable interpretation of one certified telemetry snapshot and its active operational evidence.';

-- --------------------------------------------------------------------------
-- 3. Durable deduplicated operational findings
-- --------------------------------------------------------------------------

create table if not exists public.platform_operational_findings (
  operational_finding_id uuid primary key default gen_random_uuid(),
  finding_key text not null,
  finding_type text not null,
  finding_status text not null default 'open',
  severity text not null,
  title text not null,
  description text not null,
  engine_code text,
  metric_code text,
  sla_code text,
  telemetry_alert_id uuid,
  first_evaluation_id uuid not null,
  latest_evaluation_id uuid not null,
  first_detected_at timestamptz not null default now(),
  last_detected_at timestamptz not null default now(),
  occurrence_count integer not null default 1,
  evidence jsonb not null default '{}'::jsonb,
  classification jsonb not null default '{}'::jsonb,
  acknowledged_at timestamptz,
  acknowledged_by text,
  resolved_at timestamptz,
  resolution_note text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint platform_operational_findings_key_ck
    check (finding_key ~ '^[a-z][a-z0-9_.:-]*$'),
  constraint platform_operational_findings_type_ck
    check (finding_type in ('telemetry_alert','sla_breach','platform_health','engine_readiness','stale_telemetry')),
  constraint platform_operational_findings_status_ck
    check (finding_status in ('open','acknowledged','resolved')),
  constraint platform_operational_findings_severity_ck
    check (severity in ('info','warning','critical')),
  constraint platform_operational_findings_title_ck
    check (btrim(title) <> ''),
  constraint platform_operational_findings_description_ck
    check (btrim(description) <> ''),
  constraint platform_operational_findings_occurrence_ck
    check (occurrence_count > 0),
  constraint platform_operational_findings_timeline_ck
    check (last_detected_at >= first_detected_at),
  constraint platform_operational_findings_evidence_ck
    check (jsonb_typeof(evidence) = 'object'),
  constraint platform_operational_findings_classification_ck
    check (jsonb_typeof(classification) = 'object'),
  constraint platform_operational_findings_metadata_ck
    check (jsonb_typeof(metadata) = 'object'),
  constraint platform_operational_findings_ack_ck
    check (
      (finding_status = 'open' and acknowledged_at is null and acknowledged_by is null)
      or
      (finding_status = 'acknowledged' and acknowledged_at is not null and btrim(coalesce(acknowledged_by,'')) <> '')
      or
      (finding_status = 'resolved')
    ),
  constraint platform_operational_findings_resolution_ck
    check (
      (finding_status <> 'resolved' and resolved_at is null)
      or
      (finding_status = 'resolved' and resolved_at is not null and btrim(coalesce(resolution_note,'')) <> '')
    ),
  constraint platform_operational_findings_engine_fk
    foreign key (engine_code)
    references public.platform_engine_registry(engine_code)
    on update cascade on delete restrict,
  constraint platform_operational_findings_metric_fk
    foreign key (metric_code)
    references public.platform_telemetry_metric_definitions(metric_code)
    on update cascade on delete restrict,
  constraint platform_operational_findings_sla_fk
    foreign key (sla_code)
    references public.platform_sla_definitions(sla_code)
    on update cascade on delete restrict,
  constraint platform_operational_findings_alert_fk
    foreign key (telemetry_alert_id)
    references public.platform_telemetry_alerts(telemetry_alert_id)
    on delete restrict,
  constraint platform_operational_findings_first_eval_fk
    foreign key (first_evaluation_id)
    references public.platform_supervision_evaluations(supervision_evaluation_id)
    on delete restrict,
  constraint platform_operational_findings_latest_eval_fk
    foreign key (latest_evaluation_id)
    references public.platform_supervision_evaluations(supervision_evaluation_id)
    on delete restrict
);

create unique index if not exists platform_operational_findings_active_key_uq
  on public.platform_operational_findings (finding_key)
  where finding_status in ('open','acknowledged');

create index if not exists platform_operational_findings_status_idx
  on public.platform_operational_findings (finding_status, severity, last_detected_at desc);

create index if not exists platform_operational_findings_latest_eval_idx
  on public.platform_operational_findings (latest_evaluation_id, severity);

comment on table public.platform_operational_findings is
  'Durable deduplicated operational interpretations derived from certified telemetry evidence.';

-- --------------------------------------------------------------------------
-- 4. Immutable append-only operational timeline
-- --------------------------------------------------------------------------

create table if not exists public.platform_operational_timeline (
  timeline_event_id uuid primary key default gen_random_uuid(),
  event_sequence bigint generated always as identity unique,
  contract_version text not null default 'platform-operational-timeline-v1',
  event_type text not null,
  event_status text not null default 'recorded',
  severity text not null default 'info',
  occurred_at timestamptz not null default now(),
  supervision_evaluation_id uuid,
  operational_finding_id uuid,
  telemetry_snapshot_id uuid,
  telemetry_alert_id uuid,
  engine_code text,
  correlation_id uuid not null default gen_random_uuid(),
  causation_id uuid,
  summary text not null,
  details jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,

  constraint platform_operational_timeline_contract_ck
    check (contract_version = 'platform-operational-timeline-v1'),
  constraint platform_operational_timeline_type_ck
    check (event_type in (
      'evaluation_started',
      'evaluation_completed',
      'evaluation_failed',
      'finding_opened',
      'finding_reobserved',
      'finding_acknowledged',
      'finding_resolved',
      'finding_reopened'
    )),
  constraint platform_operational_timeline_status_ck
    check (event_status in ('recorded','completed','failed')),
  constraint platform_operational_timeline_severity_ck
    check (severity in ('info','warning','critical')),
  constraint platform_operational_timeline_summary_ck
    check (btrim(summary) <> ''),
  constraint platform_operational_timeline_details_ck
    check (jsonb_typeof(details) = 'object'),
  constraint platform_operational_timeline_metadata_ck
    check (jsonb_typeof(metadata) = 'object'),
  constraint platform_operational_timeline_eval_fk
    foreign key (supervision_evaluation_id)
    references public.platform_supervision_evaluations(supervision_evaluation_id)
    on delete restrict,
  constraint platform_operational_timeline_finding_fk
    foreign key (operational_finding_id)
    references public.platform_operational_findings(operational_finding_id)
    on delete restrict,
  constraint platform_operational_timeline_snapshot_fk
    foreign key (telemetry_snapshot_id)
    references public.platform_telemetry_snapshots(telemetry_snapshot_id)
    on delete restrict,
  constraint platform_operational_timeline_alert_fk
    foreign key (telemetry_alert_id)
    references public.platform_telemetry_alerts(telemetry_alert_id)
    on delete restrict,
  constraint platform_operational_timeline_engine_fk
    foreign key (engine_code)
    references public.platform_engine_registry(engine_code)
    on update cascade on delete restrict
);

create index if not exists platform_operational_timeline_time_idx
  on public.platform_operational_timeline (occurred_at desc);

create index if not exists platform_operational_timeline_type_idx
  on public.platform_operational_timeline (event_type, occurred_at desc);

create index if not exists platform_operational_timeline_correlation_idx
  on public.platform_operational_timeline (correlation_id, occurred_at);

comment on table public.platform_operational_timeline is
  'Immutable append-only journal of operational supervision evaluations and finding lifecycle events.';

-- --------------------------------------------------------------------------
-- 5. Timestamp and immutability protection
-- --------------------------------------------------------------------------

drop trigger if exists trg_platform_operational_findings_updated_at
  on public.platform_operational_findings;
create trigger trg_platform_operational_findings_updated_at
before update on public.platform_operational_findings
for each row execute function public.set_platform_governance_updated_at();

create or replace function public.protect_platform_supervision_immutable_row()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $function$
begin
  if tg_table_name = 'platform_supervision_evaluations'
     and tg_op = 'UPDATE'
     and coalesce(current_setting('fantagol.allow_supervision_evaluation_finalize',true),'off') = 'on' then
    return new;
  end if;

  raise exception 'PLATFORM_SUPERVISION_IMMUTABLE_ROW: table=% operation=%', tg_table_name, tg_op
    using errcode = '55000';
end;
$function$;

create or replace function public.protect_platform_operational_finding_identity()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $function$
begin
  if new.operational_finding_id <> old.operational_finding_id
     or new.finding_key <> old.finding_key
     or new.finding_type <> old.finding_type
     or new.first_evaluation_id <> old.first_evaluation_id
     or new.first_detected_at <> old.first_detected_at
     or new.engine_code is distinct from old.engine_code
     or new.metric_code is distinct from old.metric_code
     or new.sla_code is distinct from old.sla_code
     or new.telemetry_alert_id is distinct from old.telemetry_alert_id
     or new.created_at <> old.created_at then
    raise exception 'PLATFORM_SUPERVISION_FINDING_IDENTITY_IMMUTABLE: %', old.operational_finding_id
      using errcode = '55000';
  end if;
  return new;
end;
$function$;

drop trigger if exists trg_protect_platform_supervision_evaluations
  on public.platform_supervision_evaluations;
create trigger trg_protect_platform_supervision_evaluations
before update or delete on public.platform_supervision_evaluations
for each row execute function public.protect_platform_supervision_immutable_row();

drop trigger if exists trg_protect_platform_operational_timeline
  on public.platform_operational_timeline;
create trigger trg_protect_platform_operational_timeline
before update or delete on public.platform_operational_timeline
for each row execute function public.protect_platform_supervision_immutable_row();

drop trigger if exists trg_protect_platform_operational_finding_identity
  on public.platform_operational_findings;
create trigger trg_protect_platform_operational_finding_identity
before update on public.platform_operational_findings
for each row execute function public.protect_platform_operational_finding_identity();

-- --------------------------------------------------------------------------
-- 6. Operational supervision evaluation RPC
-- --------------------------------------------------------------------------

create or replace function public.evaluate_platform_operational_supervision_rpc(
  p_source text default 'manual',
  p_telemetry_snapshot_id uuid default null,
  p_correlation_id uuid default gen_random_uuid()
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $function$
declare
  v_started_at timestamptz := clock_timestamp();
  v_now timestamptz := now();
  v_snapshot public.platform_telemetry_snapshots%rowtype;
  v_evaluation_id uuid;
  v_evaluation_status text;
  v_finding_count integer := 0;
  v_critical_count integer := 0;
  v_warning_count integer := 0;
  v_opened integer := 0;
  v_reobserved integer := 0;
  v_resolved integer := 0;
  v_active_alert_count integer := 0;
  v_stale_seconds numeric := 0;
  v_finding_id uuid;
  v_existing_status text;
  v_finding_key text;
  v_severity text;
  v_title text;
  v_description text;
  v_summary jsonb;
  v_evidence jsonb;
  r record;
begin
  if p_source not in ('scheduled','manual','startup','recovery','maintenance','test') then
    raise exception 'PLATFORM_SUPERVISION_INVALID_SOURCE: %', p_source
      using errcode = '22023';
  end if;

  if p_telemetry_snapshot_id is null then
    select *
      into v_snapshot
    from public.platform_telemetry_snapshots
    order by collected_at desc
    limit 1;
  else
    select *
      into v_snapshot
    from public.platform_telemetry_snapshots
    where telemetry_snapshot_id = p_telemetry_snapshot_id;
  end if;

  if not found then
    raise exception 'PLATFORM_SUPERVISION_TELEMETRY_SNAPSHOT_NOT_FOUND: %',
      coalesce(p_telemetry_snapshot_id::text,'latest')
      using errcode = 'P0002';
  end if;

  if exists (
    select 1
    from public.platform_supervision_evaluations
    where telemetry_snapshot_id = v_snapshot.telemetry_snapshot_id
      and evaluator_version = '1.0.0'
  ) then
    raise exception 'PLATFORM_SUPERVISION_SNAPSHOT_ALREADY_EVALUATED: %',
      v_snapshot.telemetry_snapshot_id
      using errcode = '23505';
  end if;

  v_stale_seconds := greatest(0, extract(epoch from (v_now - v_snapshot.collected_at)));

  select count(*)
    into v_active_alert_count
  from public.platform_telemetry_alerts
  where alert_status in ('open','acknowledged')
    and source_snapshot_id = v_snapshot.telemetry_snapshot_id;

  v_evaluation_status :=
    case
      when v_snapshot.health_status = 'critical' then 'critical'
      when v_snapshot.health_status = 'degraded' then 'attention_required'
      when v_stale_seconds > 300 then 'attention_required'
      when v_active_alert_count > 0 then 'attention_required'
      else 'healthy'
    end;

  insert into public.platform_supervision_evaluations (
    evaluation_source,
    evaluation_status,
    telemetry_snapshot_id,
    correlation_id,
    evaluation_started_at,
    evaluated_at,
    evaluation_duration_ms,
    platform_health_score,
    platform_health_status,
    finding_count,
    critical_finding_count,
    warning_finding_count,
    evaluation_summary,
    evidence,
    evaluator_version,
    metadata
  )
  values (
    p_source,
    v_evaluation_status,
    v_snapshot.telemetry_snapshot_id,
    p_correlation_id,
    v_started_at,
    v_now,
    0,
    v_snapshot.platform_health_score,
    v_snapshot.health_status,
    0,
    0,
    0,
    jsonb_build_object(
      'active_telemetry_alert_count',v_active_alert_count,
      'snapshot_age_seconds',v_stale_seconds,
      'automatic_remediation',false
    ),
    jsonb_build_object(
      'telemetry_snapshot',to_jsonb(v_snapshot),
      'sla_evaluations',coalesce((
        select jsonb_agg(to_jsonb(e) order by e.sla_code)
        from public.platform_sla_evaluations e
        where e.telemetry_snapshot_id = v_snapshot.telemetry_snapshot_id
      ),'[]'::jsonb),
      'active_alerts',coalesce((
        select jsonb_agg(to_jsonb(a) order by a.severity desc,a.alert_key)
        from public.platform_telemetry_alerts a
        where a.alert_status in ('open','acknowledged')
          and a.source_snapshot_id = v_snapshot.telemetry_snapshot_id
      ),'[]'::jsonb)
    ),
    '1.0.0',
    jsonb_build_object('migration',84,'contract','platform-operational-supervision-v1')
  )
  returning supervision_evaluation_id into v_evaluation_id;

  insert into public.platform_operational_timeline (
    event_type,event_status,severity,occurred_at,supervision_evaluation_id,
    telemetry_snapshot_id,engine_code,correlation_id,summary,details,metadata
  )
  values (
    'evaluation_started','recorded','info',v_started_at,v_evaluation_id,
    v_snapshot.telemetry_snapshot_id,'platform_supervision_engine',p_correlation_id,
    'Operational supervision evaluation started.',
    jsonb_build_object('source',p_source,'telemetry_snapshot_id',v_snapshot.telemetry_snapshot_id),
    '{"migration":84}'::jsonb
  );

  for r in
    select
      a.telemetry_alert_id,
      a.alert_key,
      a.alert_type,
      a.severity,
      a.title,
      a.message,
      a.metric_code,
      a.sla_code,
      a.current_value,
      a.threshold_value,
      a.context
    from public.platform_telemetry_alerts a
    where a.alert_status in ('open','acknowledged')
      and a.source_snapshot_id = v_snapshot.telemetry_snapshot_id
    order by
      case a.severity when 'critical' then 1 when 'warning' then 2 else 3 end,
      a.alert_key
  loop
    v_finding_key := 'telemetry:' || r.alert_key;
    v_severity := r.severity;
    v_title := r.title;
    v_description := r.message;
    v_evidence := jsonb_build_object(
      'telemetry_snapshot_id',v_snapshot.telemetry_snapshot_id,
      'telemetry_alert_id',r.telemetry_alert_id,
      'alert_key',r.alert_key,
      'alert_type',r.alert_type,
      'current_value',r.current_value,
      'threshold_value',r.threshold_value,
      'context',r.context
    );

    select operational_finding_id,finding_status
      into v_finding_id,v_existing_status
    from public.platform_operational_findings
    where finding_key = v_finding_key
      and finding_status in ('open','acknowledged')
    for update;

    if found then
      update public.platform_operational_findings
      set severity = v_severity,
          title = v_title,
          description = v_description,
          latest_evaluation_id = v_evaluation_id,
          last_detected_at = v_now,
          occurrence_count = occurrence_count + 1,
          evidence = v_evidence,
          classification = classification || jsonb_build_object(
            'source','platform_telemetry_alert',
            'alert_type',r.alert_type,
            'supervision_version','1.0.0'
          ),
          metadata = metadata || jsonb_build_object('last_evaluated_at',v_now)
      where operational_finding_id = v_finding_id;

      v_reobserved := v_reobserved + 1;

      insert into public.platform_operational_timeline (
        event_type,event_status,severity,occurred_at,supervision_evaluation_id,
        operational_finding_id,telemetry_snapshot_id,telemetry_alert_id,
        engine_code,correlation_id,summary,details,metadata
      )
      values (
        'finding_reobserved','recorded',v_severity,v_now,v_evaluation_id,
        v_finding_id,v_snapshot.telemetry_snapshot_id,r.telemetry_alert_id,
        'platform_supervision_engine',p_correlation_id,
        'Operational finding observed again.',
        jsonb_build_object('finding_key',v_finding_key,'previous_status',v_existing_status),
        '{"migration":84}'::jsonb
      );
    else
      insert into public.platform_operational_findings (
        finding_key,finding_type,finding_status,severity,title,description,
        metric_code,sla_code,telemetry_alert_id,first_evaluation_id,
        latest_evaluation_id,first_detected_at,last_detected_at,
        occurrence_count,evidence,classification,metadata
      )
      values (
        v_finding_key,
        case when r.alert_type = 'sla_breach' then 'sla_breach' else 'telemetry_alert' end,
        'open',
        v_severity,
        v_title,
        v_description,
        r.metric_code,
        r.sla_code,
        r.telemetry_alert_id,
        v_evaluation_id,
        v_evaluation_id,
        v_now,
        v_now,
        1,
        v_evidence,
        jsonb_build_object(
          'source','platform_telemetry_alert',
          'alert_type',r.alert_type,
          'supervision_version','1.0.0'
        ),
        '{"migration":84}'::jsonb
      )
      returning operational_finding_id into v_finding_id;

      v_opened := v_opened + 1;

      insert into public.platform_operational_timeline (
        event_type,event_status,severity,occurred_at,supervision_evaluation_id,
        operational_finding_id,telemetry_snapshot_id,telemetry_alert_id,
        engine_code,correlation_id,summary,details,metadata
      )
      values (
        'finding_opened','recorded',v_severity,v_now,v_evaluation_id,
        v_finding_id,v_snapshot.telemetry_snapshot_id,r.telemetry_alert_id,
        'platform_supervision_engine',p_correlation_id,
        'Operational finding opened.',
        jsonb_build_object('finding_key',v_finding_key,'finding_type',r.alert_type),
        '{"migration":84}'::jsonb
      );
    end if;
  end loop;

  if v_stale_seconds > 300 then
    v_finding_key := 'telemetry:snapshot_stale';
    v_severity := case when v_stale_seconds > 900 then 'critical' else 'warning' end;
    v_title := 'Telemetry snapshot is stale';
    v_description := format(
      'Latest evaluated telemetry snapshot is %s seconds old.',
      round(v_stale_seconds)
    );
    v_evidence := jsonb_build_object(
      'telemetry_snapshot_id',v_snapshot.telemetry_snapshot_id,
      'collected_at',v_snapshot.collected_at,
      'snapshot_age_seconds',v_stale_seconds,
      'warning_threshold_seconds',300,
      'critical_threshold_seconds',900
    );

    select operational_finding_id,finding_status
      into v_finding_id,v_existing_status
    from public.platform_operational_findings
    where finding_key = v_finding_key
      and finding_status in ('open','acknowledged')
    for update;

    if found then
      update public.platform_operational_findings
      set severity = v_severity,
          title = v_title,
          description = v_description,
          latest_evaluation_id = v_evaluation_id,
          last_detected_at = v_now,
          occurrence_count = occurrence_count + 1,
          evidence = v_evidence,
          classification = classification || jsonb_build_object(
            'source','telemetry_freshness',
            'supervision_version','1.0.0'
          ),
          metadata = metadata || jsonb_build_object('last_evaluated_at',v_now)
      where operational_finding_id = v_finding_id;

      v_reobserved := v_reobserved + 1;

      insert into public.platform_operational_timeline (
        event_type,event_status,severity,occurred_at,supervision_evaluation_id,
        operational_finding_id,telemetry_snapshot_id,engine_code,
        correlation_id,summary,details,metadata
      )
      values (
        'finding_reobserved','recorded',v_severity,v_now,v_evaluation_id,
        v_finding_id,v_snapshot.telemetry_snapshot_id,'platform_supervision_engine',
        p_correlation_id,'Stale telemetry finding observed again.',
        jsonb_build_object('finding_key',v_finding_key,'previous_status',v_existing_status),
        '{"migration":84}'::jsonb
      );
    else
      insert into public.platform_operational_findings (
        finding_key,finding_type,finding_status,severity,title,description,
        first_evaluation_id,latest_evaluation_id,first_detected_at,
        last_detected_at,occurrence_count,evidence,classification,metadata
      )
      values (
        v_finding_key,'stale_telemetry','open',v_severity,v_title,v_description,
        v_evaluation_id,v_evaluation_id,v_now,v_now,1,v_evidence,
        jsonb_build_object('source','telemetry_freshness','supervision_version','1.0.0'),
        '{"migration":84}'::jsonb
      )
      returning operational_finding_id into v_finding_id;

      v_opened := v_opened + 1;

      insert into public.platform_operational_timeline (
        event_type,event_status,severity,occurred_at,supervision_evaluation_id,
        operational_finding_id,telemetry_snapshot_id,engine_code,
        correlation_id,summary,details,metadata
      )
      values (
        'finding_opened','recorded',v_severity,v_now,v_evaluation_id,
        v_finding_id,v_snapshot.telemetry_snapshot_id,'platform_supervision_engine',
        p_correlation_id,'Stale telemetry finding opened.',
        jsonb_build_object('finding_key',v_finding_key),
        '{"migration":84}'::jsonb
      );
    end if;
  end if;

  for r in
    select f.operational_finding_id,f.finding_key,f.severity
    from public.platform_operational_findings f
    where f.finding_status in ('open','acknowledged')
      and f.latest_evaluation_id <> v_evaluation_id
      and (
        f.finding_key = 'telemetry:snapshot_stale'
        or f.finding_key like 'telemetry:%'
      )
    for update
  loop
    if r.finding_key = 'telemetry:snapshot_stale' and v_stale_seconds > 300 then
      continue;
    end if;

    if r.finding_key <> 'telemetry:snapshot_stale'
       and exists (
         select 1
         from public.platform_telemetry_alerts a
         where a.alert_status in ('open','acknowledged')
           and a.source_snapshot_id = v_snapshot.telemetry_snapshot_id
           and 'telemetry:' || a.alert_key = r.finding_key
       ) then
      continue;
    end if;

    update public.platform_operational_findings
    set finding_status = 'resolved',
        latest_evaluation_id = v_evaluation_id,
        resolved_at = v_now,
        resolution_note = 'Automatically resolved because the finding was absent from the evaluated certified evidence.',
        metadata = metadata || jsonb_build_object(
          'resolution_source','supervision_evaluation',
          'resolution_evaluation_id',v_evaluation_id
        )
    where operational_finding_id = r.operational_finding_id;

    v_resolved := v_resolved + 1;

    insert into public.platform_operational_timeline (
      event_type,event_status,severity,occurred_at,supervision_evaluation_id,
      operational_finding_id,telemetry_snapshot_id,engine_code,
      correlation_id,summary,details,metadata
    )
    values (
      'finding_resolved','completed',r.severity,v_now,v_evaluation_id,
      r.operational_finding_id,v_snapshot.telemetry_snapshot_id,
      'platform_supervision_engine',p_correlation_id,
      'Operational finding resolved by evidence reconciliation.',
      jsonb_build_object('finding_key',r.finding_key,'resolution_mode','evidence_absent'),
      '{"migration":84}'::jsonb
    );
  end loop;

  select
    count(*),
    count(*) filter (where severity = 'critical'),
    count(*) filter (where severity = 'warning')
  into v_finding_count,v_critical_count,v_warning_count
  from public.platform_operational_findings
  where latest_evaluation_id = v_evaluation_id
    and finding_status in ('open','acknowledged');

  v_evaluation_status :=
    case
      when v_critical_count > 0 or v_snapshot.health_status = 'critical' then 'critical'
      when v_warning_count > 0 or v_finding_count > 0 or v_snapshot.health_status = 'degraded' then 'attention_required'
      else 'healthy'
    end;

  v_summary := jsonb_build_object(
    'active_findings',v_finding_count,
    'critical_findings',v_critical_count,
    'warning_findings',v_warning_count,
    'findings_opened',v_opened,
    'findings_reobserved',v_reobserved,
    'findings_resolved',v_resolved,
    'snapshot_age_seconds',v_stale_seconds,
    'automatic_remediation',false
  );

  perform set_config('fantagol.allow_supervision_evaluation_finalize','on',true);

  update public.platform_supervision_evaluations
  set evaluation_status = v_evaluation_status,
      evaluation_duration_ms = greatest(
        0,
        round(extract(epoch from (clock_timestamp() - v_started_at)) * 1000)::bigint
      ),
      finding_count = v_finding_count,
      critical_finding_count = v_critical_count,
      warning_finding_count = v_warning_count,
      evaluation_summary = v_summary
  where supervision_evaluation_id = v_evaluation_id;

  perform set_config('fantagol.allow_supervision_evaluation_finalize','off',true);

  insert into public.platform_operational_timeline (
    event_type,event_status,severity,occurred_at,supervision_evaluation_id,
    telemetry_snapshot_id,engine_code,correlation_id,summary,details,metadata
  )
  values (
    'evaluation_completed',
    'completed',
    case
      when v_evaluation_status = 'critical' then 'critical'
      when v_evaluation_status = 'attention_required' then 'warning'
      else 'info'
    end,
    now(),
    v_evaluation_id,
    v_snapshot.telemetry_snapshot_id,
    'platform_supervision_engine',
    p_correlation_id,
    'Operational supervision evaluation completed.',
    v_summary || jsonb_build_object('evaluation_status',v_evaluation_status),
    '{"migration":84}'::jsonb
  );

  return jsonb_build_object(
    'contract_version','platform-operational-supervision-v1',
    'supervision_evaluation_id',v_evaluation_id,
    'telemetry_snapshot_id',v_snapshot.telemetry_snapshot_id,
    'evaluation_status',v_evaluation_status,
    'platform_health_score',v_snapshot.platform_health_score,
    'platform_health_status',v_snapshot.health_status,
    'summary',v_summary
  );
exception
  when others then
    raise;
end;
$function$;

-- --------------------------------------------------------------------------
-- 7. Finding lifecycle RPCs
-- --------------------------------------------------------------------------

create or replace function public.acknowledge_platform_operational_finding_rpc(
  p_operational_finding_id uuid,
  p_acknowledged_by text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $function$
declare
  v_finding public.platform_operational_findings%rowtype;
  v_correlation_id uuid := gen_random_uuid();
begin
  if btrim(coalesce(p_acknowledged_by,'')) = '' then
    raise exception 'PLATFORM_SUPERVISION_ACKNOWLEDGED_BY_REQUIRED'
      using errcode = '22023';
  end if;

  update public.platform_operational_findings
  set finding_status = 'acknowledged',
      acknowledged_at = now(),
      acknowledged_by = btrim(p_acknowledged_by),
      metadata = metadata || jsonb_build_object('acknowledged_via','operational-supervision-v1')
  where operational_finding_id = p_operational_finding_id
    and finding_status = 'open'
  returning * into v_finding;

  if not found then
    raise exception 'PLATFORM_SUPERVISION_FINDING_NOT_OPEN: %', p_operational_finding_id
      using errcode = 'P0002';
  end if;

  insert into public.platform_operational_timeline (
    event_type,event_status,severity,operational_finding_id,
    supervision_evaluation_id,telemetry_alert_id,engine_code,
    correlation_id,summary,details,metadata
  )
  values (
    'finding_acknowledged','completed',v_finding.severity,
    v_finding.operational_finding_id,v_finding.latest_evaluation_id,
    v_finding.telemetry_alert_id,'platform_supervision_engine',
    v_correlation_id,'Operational finding acknowledged.',
    jsonb_build_object('acknowledged_by',v_finding.acknowledged_by),
    '{"migration":84}'::jsonb
  );

  return jsonb_build_object(
    'contract_version','platform-operational-finding-v1',
    'finding',to_jsonb(v_finding)
  );
end;
$function$;

create or replace function public.resolve_platform_operational_finding_rpc(
  p_operational_finding_id uuid,
  p_resolution_note text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $function$
declare
  v_finding public.platform_operational_findings%rowtype;
  v_correlation_id uuid := gen_random_uuid();
begin
  if btrim(coalesce(p_resolution_note,'')) = '' then
    raise exception 'PLATFORM_SUPERVISION_RESOLUTION_NOTE_REQUIRED'
      using errcode = '22023';
  end if;

  update public.platform_operational_findings
  set finding_status = 'resolved',
      resolved_at = now(),
      resolution_note = btrim(p_resolution_note),
      metadata = metadata || jsonb_build_object('resolved_via','operational-supervision-v1')
  where operational_finding_id = p_operational_finding_id
    and finding_status in ('open','acknowledged')
  returning * into v_finding;

  if not found then
    raise exception 'PLATFORM_SUPERVISION_FINDING_NOT_ACTIVE: %', p_operational_finding_id
      using errcode = 'P0002';
  end if;

  insert into public.platform_operational_timeline (
    event_type,event_status,severity,operational_finding_id,
    supervision_evaluation_id,telemetry_alert_id,engine_code,
    correlation_id,summary,details,metadata
  )
  values (
    'finding_resolved','completed',v_finding.severity,
    v_finding.operational_finding_id,v_finding.latest_evaluation_id,
    v_finding.telemetry_alert_id,'platform_supervision_engine',
    v_correlation_id,'Operational finding resolved.',
    jsonb_build_object('resolution_note',v_finding.resolution_note),
    '{"migration":84}'::jsonb
  );

  return jsonb_build_object(
    'contract_version','platform-operational-finding-v1',
    'finding',to_jsonb(v_finding)
  );
end;
$function$;

-- --------------------------------------------------------------------------
-- 8. Read models
-- --------------------------------------------------------------------------

create or replace function public.get_platform_supervision_latest_evaluation_rpc()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $function$
  select coalesce(
    (
      select to_jsonb(e)
      from public.platform_supervision_evaluations e
      order by e.evaluated_at desc,e.evaluation_sequence desc
      limit 1
    ),
    '{}'::jsonb
  );
$function$;

create or replace function public.get_platform_operational_findings_rpc(
  p_status text default null,
  p_severity text default null,
  p_limit integer default 100
)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $function$
  select coalesce(jsonb_agg(to_jsonb(f) order by
    case f.severity when 'critical' then 1 when 'warning' then 2 else 3 end,
    f.last_detected_at desc
  ),'[]'::jsonb)
  from (
    select *
    from public.platform_operational_findings
    where (p_status is null or finding_status = p_status)
      and (p_severity is null or severity = p_severity)
    order by
      case severity when 'critical' then 1 when 'warning' then 2 else 3 end,
      last_detected_at desc
    limit greatest(1,least(coalesce(p_limit,100),1000))
  ) f;
$function$;

create or replace function public.get_platform_operational_timeline_rpc(
  p_event_type text default null,
  p_limit integer default 100
)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $function$
  select coalesce(jsonb_agg(to_jsonb(t) order by t.occurred_at desc,t.event_sequence desc),'[]'::jsonb)
  from (
    select *
    from public.platform_operational_timeline
    where p_event_type is null or event_type = p_event_type
    order by occurred_at desc,event_sequence desc
    limit greatest(1,least(coalesce(p_limit,100),1000))
  ) t;
$function$;

create or replace function public.get_platform_supervision_health_rpc()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $function$
  select jsonb_build_object(
    'contract_version','platform-operational-supervision-health-v1',
    'generated_at',now(),
    'latest_evaluation',public.get_platform_supervision_latest_evaluation_rpc(),
    'active_findings',jsonb_build_object(
      'total',(select count(*) from public.platform_operational_findings where finding_status in ('open','acknowledged')),
      'critical',(select count(*) from public.platform_operational_findings where finding_status in ('open','acknowledged') and severity='critical'),
      'warning',(select count(*) from public.platform_operational_findings where finding_status in ('open','acknowledged') and severity='warning'),
      'acknowledged',(select count(*) from public.platform_operational_findings where finding_status='acknowledged')
    ),
    'history',jsonb_build_object(
      'evaluation_count',(select count(*) from public.platform_supervision_evaluations),
      'finding_count',(select count(*) from public.platform_operational_findings),
      'timeline_event_count',(select count(*) from public.platform_operational_timeline)
    ),
    'controls',jsonb_build_object(
      'automatic_remediation',false,
      'incident_correlation',false,
      'recommendation_engine',false,
      'readiness_engine',false
    )
  );
$function$;

-- --------------------------------------------------------------------------
-- 9. RLS, privileges and execution grants
-- --------------------------------------------------------------------------

alter table public.platform_supervision_evaluations enable row level security;
alter table public.platform_operational_findings enable row level security;
alter table public.platform_operational_timeline enable row level security;

revoke all on table public.platform_supervision_evaluations from public,anon,authenticated;
revoke all on table public.platform_operational_findings from public,anon,authenticated;
revoke all on table public.platform_operational_timeline from public,anon,authenticated;

grant select,insert,references,trigger
  on table public.platform_supervision_evaluations to service_role;
grant select,insert,update,references,trigger
  on table public.platform_operational_findings to service_role;
grant select,insert,references,trigger
  on table public.platform_operational_timeline to service_role;

drop policy if exists platform_supervision_evaluations_service_all
  on public.platform_supervision_evaluations;
create policy platform_supervision_evaluations_service_all
  on public.platform_supervision_evaluations
  for all to service_role
  using (true)
  with check (true);

drop policy if exists platform_operational_findings_service_all
  on public.platform_operational_findings;
create policy platform_operational_findings_service_all
  on public.platform_operational_findings
  for all to service_role
  using (true)
  with check (true);

drop policy if exists platform_operational_timeline_service_all
  on public.platform_operational_timeline;
create policy platform_operational_timeline_service_all
  on public.platform_operational_timeline
  for all to service_role
  using (true)
  with check (true);

revoke all on function public.protect_platform_supervision_immutable_row()
  from public,anon,authenticated;
revoke all on function public.protect_platform_operational_finding_identity()
  from public,anon,authenticated;

revoke all on function public.evaluate_platform_operational_supervision_rpc(text,uuid,uuid)
  from public,anon,authenticated;
revoke all on function public.acknowledge_platform_operational_finding_rpc(uuid,text)
  from public,anon,authenticated;
revoke all on function public.resolve_platform_operational_finding_rpc(uuid,text)
  from public,anon,authenticated;

revoke all on function public.get_platform_supervision_latest_evaluation_rpc()
  from public,anon;
revoke all on function public.get_platform_operational_findings_rpc(text,text,integer)
  from public,anon;
revoke all on function public.get_platform_operational_timeline_rpc(text,integer)
  from public,anon;
revoke all on function public.get_platform_supervision_health_rpc()
  from public,anon;

grant execute on function public.evaluate_platform_operational_supervision_rpc(text,uuid,uuid)
  to service_role;
grant execute on function public.acknowledge_platform_operational_finding_rpc(uuid,text)
  to service_role;
grant execute on function public.resolve_platform_operational_finding_rpc(uuid,text)
  to service_role;

grant execute on function public.get_platform_supervision_latest_evaluation_rpc()
  to authenticated,service_role;
grant execute on function public.get_platform_operational_findings_rpc(text,text,integer)
  to authenticated,service_role;
grant execute on function public.get_platform_operational_timeline_rpc(text,integer)
  to authenticated,service_role;
grant execute on function public.get_platform_supervision_health_rpc()
  to authenticated,service_role;

-- --------------------------------------------------------------------------
-- 10. Runtime policies and feature flag
-- --------------------------------------------------------------------------

insert into public.platform_runtime_policies (
  policy_key,policy_name,description,policy_type,policy_value,
  validation_contract,owner_engine_code,enforcement_level,enabled,metadata
)
values
  (
    'runtime.supervision.evaluation_interval',
    'Operational supervision evaluation interval',
    'Recommended cadence for explicit operational supervision evaluations.',
    'duration',
    '"PT1M"'::jsonb,
    '{"format":"ISO-8601-duration"}'::jsonb,
    'platform_supervision_engine',
    'required',
    true,
    '{"migration":84}'::jsonb
  ),
  (
    'runtime.supervision.finding_deduplication',
    'Operational finding deduplication',
    'Maintain one active operational finding per stable finding key.',
    'boolean',
    'true'::jsonb,
    '{}'::jsonb,
    'platform_supervision_engine',
    'critical',
    true,
    '{"migration":84}'::jsonb
  ),
  (
    'runtime.supervision.stale_snapshot_threshold',
    'Telemetry snapshot staleness threshold',
    'Maximum recommended age of telemetry evidence used by operational supervision.',
    'duration',
    '"PT5M"'::jsonb,
    '{"format":"ISO-8601-duration"}'::jsonb,
    'platform_supervision_engine',
    'required',
    true,
    '{"migration":84}'::jsonb
  ),
  (
    'runtime.supervision.automatic_remediation',
    'Automatic remediation',
    'Explicitly disables automatic remediation in the supervision foundation.',
    'boolean',
    'false'::jsonb,
    '{}'::jsonb,
    'platform_supervision_engine',
    'critical',
    true,
    '{"migration":84,"safety":"no-automatic-remediation"}'::jsonb
  )
on conflict (policy_key) do update
set policy_name = excluded.policy_name,
    description = excluded.description,
    policy_type = excluded.policy_type,
    policy_value = excluded.policy_value,
    validation_contract = excluded.validation_contract,
    owner_engine_code = excluded.owner_engine_code,
    enforcement_level = excluded.enforcement_level,
    enabled = excluded.enabled,
    metadata = public.platform_runtime_policies.metadata || excluded.metadata,
    updated_at = now();

insert into public.platform_feature_flags (
  feature_key,feature_name,description,enabled,rollout_percentage,audience,
  environment_scope,owner_engine_code,metadata
)
values (
  'runtime.platform_operational_supervision',
  'Platform operational supervision',
  'Expose immutable operational evaluations, durable findings and the supervision health read model.',
  true,
  100,
  'service',
  array['development','preview','staging','production','test']::text[],
  'platform_supervision_engine',
  '{"contract":"platform-operational-supervision-v1","migration":84}'::jsonb
)
on conflict (feature_key) do update
set feature_name = excluded.feature_name,
    description = excluded.description,
    enabled = excluded.enabled,
    rollout_percentage = excluded.rollout_percentage,
    audience = excluded.audience,
    environment_scope = excluded.environment_scope,
    owner_engine_code = excluded.owner_engine_code,
    metadata = public.platform_feature_flags.metadata || excluded.metadata,
    updated_at = now();

-- --------------------------------------------------------------------------
-- 11. Governance Snapshot v1.5
-- --------------------------------------------------------------------------

create or replace function public.get_platform_governance_snapshot_rpc()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $function$
  select jsonb_build_object(
    'contract_version','platform-governance-v1.5',
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
    'telemetry_health',public.get_platform_telemetry_health_rpc(),
    'telemetry_latest_snapshot',public.get_platform_telemetry_latest_snapshot_rpc(),
    'telemetry_alerts',public.get_platform_telemetry_alerts_rpc(null,null,100),
    'sla_status',public.get_platform_sla_status_rpc(100),
    'supervision_health',public.get_platform_supervision_health_rpc(),
    'supervision_latest_evaluation',public.get_platform_supervision_latest_evaluation_rpc(),
    'supervision_active_findings',public.get_platform_operational_findings_rpc('open',null,100),
    'feature_flags',public.get_platform_feature_flags_rpc(null,false),
    'runtime_policies',public.get_platform_runtime_policies_rpc(null,false),
    'capabilities',public.get_platform_capabilities_rpc(null,false)
  );
$function$;

revoke all on function public.get_platform_governance_snapshot_rpc()
  from public,anon;
grant execute on function public.get_platform_governance_snapshot_rpc()
  to authenticated,service_role;

update public.platform_configuration
set schema_version = greatest(schema_version,84),
    metadata = metadata || jsonb_build_object(
      'phase','8.4.2',
      'governance_contract','platform-governance-v1.5',
      'platform_supervision_contract','platform-operational-supervision-v1',
      'platform_supervision_migration',84
    ),
    updated_at = now()
where configuration_key = 'primary';

-- --------------------------------------------------------------------------
-- 12. Migration assertions
-- --------------------------------------------------------------------------

do $assertions$
declare
  v_missing integer;
  v_health jsonb;
  v_snapshot jsonb;
  v_action_count_before bigint;
  v_action_count_after bigint;
begin
  select count(*) into v_missing
  from (values
    ('platform_supervision_evaluations'),
    ('platform_operational_findings'),
    ('platform_operational_timeline')
  ) required_table(name)
  where to_regclass('public.' || name) is null;

  if v_missing <> 0 then
    raise exception 'PLATFORM_SUPERVISION_ASSERTION_FAILED: missing tables %',v_missing;
  end if;

  select count(*) into v_missing
  from (values
    ('protect_platform_supervision_immutable_row'),
    ('protect_platform_operational_finding_identity'),
    ('evaluate_platform_operational_supervision_rpc'),
    ('acknowledge_platform_operational_finding_rpc'),
    ('resolve_platform_operational_finding_rpc'),
    ('get_platform_supervision_latest_evaluation_rpc'),
    ('get_platform_operational_findings_rpc'),
    ('get_platform_operational_timeline_rpc'),
    ('get_platform_supervision_health_rpc')
  ) required_function(name)
  where not exists (
    select 1
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = required_function.name
  );

  if v_missing <> 0 then
    raise exception 'PLATFORM_SUPERVISION_ASSERTION_FAILED: missing functions %',v_missing;
  end if;

  if not exists (
    select 1
    from public.platform_engine_registry
    where engine_code = 'platform_supervision_engine'
      and engine_version = '1.0.0'
      and engine_kind = 'observability'
      and lifecycle_status = 'active'
      and runtime_enabled
      and not is_certified
      and installation_order = 130
  ) then
    raise exception 'PLATFORM_SUPERVISION_ASSERTION_FAILED: engine registration invalid';
  end if;

  if (
    select count(*)
    from public.platform_engine_dependencies
    where dependent_engine_code = 'platform_supervision_engine'
      and dependency_engine_code in (
        'platform_governance_engine',
        'platform_orchestrator_engine',
        'platform_telemetry_engine'
      )
      and requires_runtime_enabled
      and requires_certification
      and enabled
  ) <> 3 then
    raise exception 'PLATFORM_SUPERVISION_ASSERTION_FAILED: dependency registration invalid';
  end if;

  if not exists (
    select 1
    from public.platform_feature_flags
    where feature_key = 'runtime.platform_operational_supervision'
      and enabled
      and rollout_percentage = 100
      and owner_engine_code = 'platform_supervision_engine'
  ) then
    raise exception 'PLATFORM_SUPERVISION_ASSERTION_FAILED: feature flag invalid';
  end if;

  if (
    select count(*)
    from public.platform_runtime_policies
    where policy_key in (
      'runtime.supervision.evaluation_interval',
      'runtime.supervision.finding_deduplication',
      'runtime.supervision.stale_snapshot_threshold',
      'runtime.supervision.automatic_remediation'
    )
      and owner_engine_code = 'platform_supervision_engine'
      and enabled
  ) <> 4 then
    raise exception 'PLATFORM_SUPERVISION_ASSERTION_FAILED: runtime policy catalogue invalid';
  end if;

  if not exists (
    select 1
    from public.platform_runtime_policies
    where policy_key = 'runtime.supervision.automatic_remediation'
      and policy_value = 'false'::jsonb
      and enforcement_level = 'critical'
      and enabled
  ) then
    raise exception 'PLATFORM_SUPERVISION_ASSERTION_FAILED: automatic remediation safety policy invalid';
  end if;

  if not exists (
    select 1
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname in (
        'platform_supervision_evaluations',
        'platform_operational_findings',
        'platform_operational_timeline'
      )
      and c.relrowsecurity
    group by n.nspname
    having count(*) = 3
  ) then
    raise exception 'PLATFORM_SUPERVISION_ASSERTION_FAILED: RLS invalid';
  end if;

  v_health := public.get_platform_supervision_health_rpc();
  if (v_health ->> 'contract_version') <> 'platform-operational-supervision-health-v1'
     or not (v_health ? 'latest_evaluation')
     or not (v_health ? 'active_findings')
     or not (v_health ? 'controls')
     or (v_health #>> '{controls,automatic_remediation}')::boolean then
    raise exception 'PLATFORM_SUPERVISION_ASSERTION_FAILED: supervision health contract invalid';
  end if;

  v_snapshot := public.get_platform_governance_snapshot_rpc();
  if (v_snapshot ->> 'contract_version') <> 'platform-governance-v1.5'
     or not (v_snapshot ? 'supervision_health')
     or not (v_snapshot ? 'supervision_latest_evaluation')
     or not (v_snapshot ? 'supervision_active_findings') then
    raise exception 'PLATFORM_SUPERVISION_ASSERTION_FAILED: governance snapshot invalid';
  end if;

  if not exists (
    select 1
    from public.platform_configuration
    where configuration_key = 'primary'
      and schema_version >= 84
  ) then
    raise exception 'PLATFORM_SUPERVISION_ASSERTION_FAILED: schema version invalid';
  end if;

  select count(*) into v_action_count_before
  from public.platform_orchestrator_actions;

  select count(*) into v_action_count_after
  from public.platform_orchestrator_actions;

  if v_action_count_after <> v_action_count_before then
    raise exception 'PLATFORM_SUPERVISION_ASSERTION_FAILED: migration generated orchestrator actions';
  end if;
end;
$assertions$;

commit;
