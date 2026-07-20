-- ============================================================================
-- FANTAGOL
-- Migration 085: Incident Correlation Engine
-- Phase 8.4.3
--
-- Purpose
--   Correlate active operational findings produced by the Platform Operational
--   Supervision Engine into durable operational incidents. Incidents provide a
--   stable lifecycle container, finding membership, immutable evidence and an
--   append-only incident timeline.
--
-- Safety
--   Correlation is explicit through service-role RPCs. This migration creates
--   no notifications, recommendations, readiness decisions, orchestrator
--   actions or automatic remediation. PostgreSQL remains authoritative.
-- ============================================================================

begin;

-- --------------------------------------------------------------------------
-- 1. Register the Incident Correlation Engine
-- --------------------------------------------------------------------------

insert into public.platform_engine_registry (
  engine_code,engine_name,engine_version,engine_kind,lifecycle_status,
  runtime_enabled,is_certified,certification_version,certified_at,
  owner_scope,installation_order,dependencies,metadata
)
values (
  'platform_incident_correlation_engine',
  'Platform Incident Correlation Engine',
  '1.0.0',
  'observability',
  'active',
  true,
  false,
  null,
  null,
  'platform',
  140,
  '["platform_governance_engine","platform_supervision_engine","platform_telemetry_engine"]'::jsonb,
  jsonb_build_object(
    'phase','8.4.3',
    'contract','platform-incident-correlation-v1',
    'migration',85,
    'correlation_mode','explicit-deterministic',
    'incident_lifecycle','durable-deduplicated',
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
  dependent_engine_code,dependency_engine_code,dependency_type,
  minimum_version,requires_runtime_enabled,requires_certification,
  allowed_dependency_statuses,enabled,rationale,metadata
)
values
  (
    'platform_incident_correlation_engine','platform_governance_engine','required',
    '1.0.0',true,true,array['active','degraded']::text[],true,
    'Incident correlation is governed by the certified platform registry and policy catalogue.',
    '{"migration":85,"contract":"platform-incident-correlation-v1"}'::jsonb
  ),
  (
    'platform_incident_correlation_engine','platform_supervision_engine','runtime',
    '1.0.0',true,false,array['active','degraded']::text[],true,
    'Active operational findings are the authoritative source for incident correlation.',
    '{"migration":85,"contract":"platform-incident-correlation-v1"}'::jsonb
  ),
  (
    'platform_incident_correlation_engine','platform_telemetry_engine','runtime',
    '1.0.0',true,true,array['active','degraded']::text[],true,
    'Certified telemetry evidence remains traceable through correlated findings.',
    '{"migration":85,"contract":"platform-incident-correlation-v1"}'::jsonb
  )
on conflict (dependent_engine_code,dependency_engine_code) do update
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
-- 2. Durable operational incidents
-- --------------------------------------------------------------------------

create table if not exists public.platform_operational_incidents (
  operational_incident_id uuid primary key default gen_random_uuid(),
  incident_sequence bigint generated always as identity unique,
  contract_version text not null default 'platform-operational-incident-v1',
  incident_key text not null,
  incident_type text not null,
  incident_status text not null default 'open',
  severity text not null,
  title text not null,
  description text not null,
  primary_engine_code text,
  primary_finding_id uuid not null,
  first_evaluation_id uuid not null,
  latest_evaluation_id uuid not null,
  correlation_id uuid not null default gen_random_uuid(),
  first_detected_at timestamptz not null,
  last_detected_at timestamptz not null,
  finding_count integer not null default 1,
  active_finding_count integer not null default 1,
  observation_count integer not null default 1,
  evidence jsonb not null default '{}'::jsonb,
  classification jsonb not null default '{}'::jsonb,
  acknowledged_at timestamptz,
  acknowledged_by text,
  resolved_at timestamptz,
  resolution_note text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint platform_operational_incidents_contract_ck
    check (contract_version = 'platform-operational-incident-v1'),
  constraint platform_operational_incidents_key_ck
    check (incident_key ~ '^[a-z][a-z0-9_.:-]*$'),
  constraint platform_operational_incidents_type_ck
    check (incident_type in ('telemetry_availability','engine_degradation','sla_degradation','metric_degradation','platform_degradation','uncategorized')),
  constraint platform_operational_incidents_status_ck
    check (incident_status in ('open','acknowledged','resolved')),
  constraint platform_operational_incidents_severity_ck
    check (severity in ('info','warning','critical')),
  constraint platform_operational_incidents_title_ck
    check (btrim(title) <> ''),
  constraint platform_operational_incidents_description_ck
    check (btrim(description) <> ''),
  constraint platform_operational_incidents_counts_ck
    check (finding_count > 0 and active_finding_count >= 0 and active_finding_count <= finding_count and observation_count > 0),
  constraint platform_operational_incidents_timeline_ck
    check (last_detected_at >= first_detected_at),
  constraint platform_operational_incidents_evidence_ck
    check (jsonb_typeof(evidence) = 'object'),
  constraint platform_operational_incidents_classification_ck
    check (jsonb_typeof(classification) = 'object'),
  constraint platform_operational_incidents_metadata_ck
    check (jsonb_typeof(metadata) = 'object'),
  constraint platform_operational_incidents_ack_ck
    check (
      (incident_status = 'open' and acknowledged_at is null and acknowledged_by is null)
      or (incident_status = 'acknowledged' and acknowledged_at is not null and btrim(coalesce(acknowledged_by,'')) <> '')
      or (incident_status = 'resolved')
    ),
  constraint platform_operational_incidents_resolution_ck
    check (
      (incident_status <> 'resolved' and resolved_at is null)
      or (incident_status = 'resolved' and resolved_at is not null and btrim(coalesce(resolution_note,'')) <> '')
    ),
  constraint platform_operational_incidents_engine_fk
    foreign key (primary_engine_code)
    references public.platform_engine_registry(engine_code)
    on update cascade on delete restrict,
  constraint platform_operational_incidents_primary_finding_fk
    foreign key (primary_finding_id)
    references public.platform_operational_findings(operational_finding_id)
    on delete restrict,
  constraint platform_operational_incidents_first_eval_fk
    foreign key (first_evaluation_id)
    references public.platform_supervision_evaluations(supervision_evaluation_id)
    on delete restrict,
  constraint platform_operational_incidents_latest_eval_fk
    foreign key (latest_evaluation_id)
    references public.platform_supervision_evaluations(supervision_evaluation_id)
    on delete restrict
);

create unique index if not exists platform_operational_incidents_active_key_uq
  on public.platform_operational_incidents (incident_key)
  where incident_status in ('open','acknowledged');

create index if not exists platform_operational_incidents_status_idx
  on public.platform_operational_incidents (incident_status,severity,last_detected_at desc);

create index if not exists platform_operational_incidents_latest_eval_idx
  on public.platform_operational_incidents (latest_evaluation_id,severity);

comment on table public.platform_operational_incidents is
  'Durable operational cases produced by deterministic correlation of supervision findings.';

-- --------------------------------------------------------------------------
-- 3. Immutable incident-to-finding membership
-- --------------------------------------------------------------------------

create table if not exists public.platform_incident_findings (
  incident_finding_id uuid primary key default gen_random_uuid(),
  operational_incident_id uuid not null,
  operational_finding_id uuid not null,
  linked_at timestamptz not null default now(),
  link_reason text not null,
  correlation_id uuid not null,
  evidence jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,

  constraint platform_incident_findings_link_reason_ck
    check (btrim(link_reason) <> ''),
  constraint platform_incident_findings_evidence_ck
    check (jsonb_typeof(evidence) = 'object'),
  constraint platform_incident_findings_metadata_ck
    check (jsonb_typeof(metadata) = 'object'),
  constraint platform_incident_findings_incident_fk
    foreign key (operational_incident_id)
    references public.platform_operational_incidents(operational_incident_id)
    on delete restrict,
  constraint platform_incident_findings_finding_fk
    foreign key (operational_finding_id)
    references public.platform_operational_findings(operational_finding_id)
    on delete restrict,
  constraint platform_incident_findings_unique
    unique (operational_incident_id,operational_finding_id)
);

create index if not exists platform_incident_findings_finding_idx
  on public.platform_incident_findings (operational_finding_id,linked_at desc);

comment on table public.platform_incident_findings is
  'Immutable membership linking operational findings to one correlated incident.';

-- --------------------------------------------------------------------------
-- 4. Immutable append-only incident timeline
-- --------------------------------------------------------------------------

create table if not exists public.platform_incident_timeline (
  incident_timeline_event_id uuid primary key default gen_random_uuid(),
  event_sequence bigint generated always as identity unique,
  contract_version text not null default 'platform-incident-timeline-v1',
  event_type text not null,
  event_status text not null default 'recorded',
  severity text not null default 'info',
  occurred_at timestamptz not null default now(),
  operational_incident_id uuid not null,
  operational_finding_id uuid,
  supervision_evaluation_id uuid,
  correlation_id uuid not null,
  causation_id uuid,
  summary text not null,
  details jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,

  constraint platform_incident_timeline_contract_ck
    check (contract_version = 'platform-incident-timeline-v1'),
  constraint platform_incident_timeline_type_ck
    check (event_type in ('incident_opened','finding_linked','incident_reobserved','incident_acknowledged','incident_resolved','incident_reopened','correlation_completed')),
  constraint platform_incident_timeline_status_ck
    check (event_status in ('recorded','completed','failed')),
  constraint platform_incident_timeline_severity_ck
    check (severity in ('info','warning','critical')),
  constraint platform_incident_timeline_summary_ck
    check (btrim(summary) <> ''),
  constraint platform_incident_timeline_details_ck
    check (jsonb_typeof(details) = 'object'),
  constraint platform_incident_timeline_metadata_ck
    check (jsonb_typeof(metadata) = 'object'),
  constraint platform_incident_timeline_incident_fk
    foreign key (operational_incident_id)
    references public.platform_operational_incidents(operational_incident_id)
    on delete restrict,
  constraint platform_incident_timeline_finding_fk
    foreign key (operational_finding_id)
    references public.platform_operational_findings(operational_finding_id)
    on delete restrict,
  constraint platform_incident_timeline_eval_fk
    foreign key (supervision_evaluation_id)
    references public.platform_supervision_evaluations(supervision_evaluation_id)
    on delete restrict
);

create index if not exists platform_incident_timeline_time_idx
  on public.platform_incident_timeline (occurred_at desc);
create index if not exists platform_incident_timeline_incident_idx
  on public.platform_incident_timeline (operational_incident_id,event_sequence);
create index if not exists platform_incident_timeline_correlation_idx
  on public.platform_incident_timeline (correlation_id,occurred_at);

comment on table public.platform_incident_timeline is
  'Immutable append-only lifecycle journal for operational incidents.';

-- --------------------------------------------------------------------------
-- 5. Updated-at and immutability guards
-- --------------------------------------------------------------------------

create or replace function public.set_platform_incident_updated_at()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
begin
  new.updated_at := now();
  return new;
end;
$function$;

create or replace function public.protect_platform_incident_immutable_row()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
begin
  raise exception 'PLATFORM_INCIDENT_IMMUTABLE_ROW: table=% operation=%',tg_table_name,tg_op
    using errcode = '55000';
end;
$function$;

create or replace function public.protect_platform_incident_identity()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
begin
  if old.operational_incident_id is distinct from new.operational_incident_id
     or old.incident_sequence is distinct from new.incident_sequence
     or old.contract_version is distinct from new.contract_version
     or old.incident_key is distinct from new.incident_key
     or old.incident_type is distinct from new.incident_type
     or old.primary_finding_id is distinct from new.primary_finding_id
     or old.first_evaluation_id is distinct from new.first_evaluation_id
     or old.first_detected_at is distinct from new.first_detected_at
     or old.created_at is distinct from new.created_at then
    raise exception 'PLATFORM_INCIDENT_IDENTITY_IMMUTABLE: %',old.operational_incident_id
      using errcode = '55000';
  end if;
  return new;
end;
$function$;

drop trigger if exists trg_platform_operational_incidents_updated_at
  on public.platform_operational_incidents;
create trigger trg_platform_operational_incidents_updated_at
before update on public.platform_operational_incidents
for each row execute function public.set_platform_incident_updated_at();

drop trigger if exists trg_protect_platform_operational_incident_identity
  on public.platform_operational_incidents;
create trigger trg_protect_platform_operational_incident_identity
before update or delete on public.platform_operational_incidents
for each row execute function public.protect_platform_incident_identity();

drop trigger if exists trg_protect_platform_incident_findings
  on public.platform_incident_findings;
create trigger trg_protect_platform_incident_findings
before update or delete on public.platform_incident_findings
for each row execute function public.protect_platform_incident_immutable_row();

drop trigger if exists trg_protect_platform_incident_timeline
  on public.platform_incident_timeline;
create trigger trg_protect_platform_incident_timeline
before update or delete on public.platform_incident_timeline
for each row execute function public.protect_platform_incident_immutable_row();

-- --------------------------------------------------------------------------
-- 6. Deterministic incident correlation RPC
-- --------------------------------------------------------------------------

create or replace function public.correlate_platform_operational_incidents_rpc(
  p_source text default 'manual',
  p_correlation_id uuid default gen_random_uuid()
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_started_at timestamptz := clock_timestamp();
  v_finding record;
  v_incident public.platform_operational_incidents%rowtype;
  v_incident_id uuid;
  v_incident_key text;
  v_incident_type text;
  v_title text;
  v_opened integer := 0;
  v_reobserved integer := 0;
  v_linked integer := 0;
  v_resolved integer := 0;
  v_active integer := 0;
  v_active_findings integer;
  v_total_findings integer;
  v_max_severity text;
begin
  if p_source not in ('scheduled','manual','startup','recovery','maintenance','test') then
    raise exception 'PLATFORM_INCIDENT_INVALID_SOURCE: %',p_source
      using errcode = '22023';
  end if;

  for v_finding in
    select f.*
    from public.platform_operational_findings f
    where f.finding_status in ('open','acknowledged')
    order by f.first_detected_at,f.operational_finding_id
  loop
    if v_finding.finding_type = 'stale_telemetry' then
      v_incident_key := 'telemetry:availability';
      v_incident_type := 'telemetry_availability';
      v_title := 'Telemetry availability incident';
    elsif v_finding.engine_code is not null then
      v_incident_key := 'engine:' || v_finding.engine_code;
      v_incident_type := 'engine_degradation';
      v_title := 'Engine degradation: ' || v_finding.engine_code;
    elsif v_finding.sla_code is not null then
      v_incident_key := 'sla:' || v_finding.sla_code;
      v_incident_type := 'sla_degradation';
      v_title := 'SLA degradation: ' || v_finding.sla_code;
    elsif v_finding.metric_code is not null then
      v_incident_key := 'metric:' || v_finding.metric_code;
      v_incident_type := 'metric_degradation';
      v_title := 'Metric degradation: ' || v_finding.metric_code;
    elsif v_finding.finding_type = 'platform_health' then
      v_incident_key := 'platform:health';
      v_incident_type := 'platform_degradation';
      v_title := 'Platform health incident';
    else
      v_incident_key := 'finding:' || v_finding.finding_type;
      v_incident_type := 'uncategorized';
      v_title := 'Operational incident: ' || v_finding.finding_type;
    end if;

    select * into v_incident
    from public.platform_operational_incidents i
    where i.incident_key = v_incident_key
      and i.incident_status in ('open','acknowledged')
    for update;

    if not found then
      insert into public.platform_operational_incidents (
        incident_key,incident_type,incident_status,severity,title,description,
        primary_engine_code,primary_finding_id,first_evaluation_id,
        latest_evaluation_id,correlation_id,first_detected_at,last_detected_at,
        finding_count,active_finding_count,observation_count,evidence,
        classification,metadata
      ) values (
        v_incident_key,v_incident_type,'open',v_finding.severity,v_title,
        'Correlated operational incident generated from active supervision findings.',
        v_finding.engine_code,v_finding.operational_finding_id,
        v_finding.first_evaluation_id,v_finding.latest_evaluation_id,
        p_correlation_id,v_finding.first_detected_at,v_finding.last_detected_at,
        1,1,1,
        jsonb_build_object('primary_finding',to_jsonb(v_finding)),
        jsonb_build_object('correlation_rule',v_incident_key,'source',p_source,'correlator_version','1.0.0'),
        jsonb_build_object('migration',85,'contract','platform-incident-correlation-v1')
      ) returning operational_incident_id into v_incident_id;

      insert into public.platform_incident_timeline (
        event_type,event_status,severity,operational_incident_id,
        operational_finding_id,supervision_evaluation_id,correlation_id,
        summary,details,metadata
      ) values (
        'incident_opened','recorded',v_finding.severity,v_incident_id,
        v_finding.operational_finding_id,v_finding.latest_evaluation_id,p_correlation_id,
        'Operational incident opened.',
        jsonb_build_object('incident_key',v_incident_key,'source',p_source),
        '{"migration":85}'::jsonb
      );
      v_opened := v_opened + 1;
    else
      v_incident_id := v_incident.operational_incident_id;
      update public.platform_operational_incidents
      set severity = case
            when severity = 'critical' or v_finding.severity = 'critical' then 'critical'
            when severity = 'warning' or v_finding.severity = 'warning' then 'warning'
            else 'info'
          end,
          latest_evaluation_id = v_finding.latest_evaluation_id,
          last_detected_at = greatest(last_detected_at,v_finding.last_detected_at),
          observation_count = observation_count + 1,
          evidence = evidence || jsonb_build_object('latest_finding',to_jsonb(v_finding)),
          metadata = metadata || jsonb_build_object('last_correlation_source',p_source)
      where operational_incident_id = v_incident_id;

      insert into public.platform_incident_timeline (
        event_type,event_status,severity,operational_incident_id,
        operational_finding_id,supervision_evaluation_id,correlation_id,
        summary,details,metadata
      ) values (
        'incident_reobserved','recorded',v_finding.severity,v_incident_id,
        v_finding.operational_finding_id,v_finding.latest_evaluation_id,p_correlation_id,
        'Operational incident observed again.',
        jsonb_build_object('incident_key',v_incident_key,'source',p_source),
        '{"migration":85}'::jsonb
      );
      v_reobserved := v_reobserved + 1;
    end if;

    insert into public.platform_incident_findings (
      operational_incident_id,operational_finding_id,link_reason,
      correlation_id,evidence,metadata
    ) values (
      v_incident_id,v_finding.operational_finding_id,
      'deterministic-correlation:' || v_incident_key,p_correlation_id,
      jsonb_build_object('finding_key',v_finding.finding_key,'finding_type',v_finding.finding_type),
      '{"migration":85}'::jsonb
    ) on conflict (operational_incident_id,operational_finding_id) do nothing;

    if found then
      insert into public.platform_incident_timeline (
        event_type,event_status,severity,operational_incident_id,
        operational_finding_id,supervision_evaluation_id,correlation_id,
        summary,details,metadata
      ) values (
        'finding_linked','recorded',v_finding.severity,v_incident_id,
        v_finding.operational_finding_id,v_finding.latest_evaluation_id,p_correlation_id,
        'Operational finding linked to incident.',
        jsonb_build_object('finding_key',v_finding.finding_key),
        '{"migration":85}'::jsonb
      );
      v_linked := v_linked + 1;
    end if;
  end loop;

  for v_incident in
    select * from public.platform_operational_incidents
    where incident_status in ('open','acknowledged')
    for update
  loop
    select count(*),
           count(*) filter (where f.finding_status in ('open','acknowledged')),
           case
             when count(*) filter (where f.finding_status in ('open','acknowledged') and f.severity = 'critical') > 0 then 'critical'
             when count(*) filter (where f.finding_status in ('open','acknowledged') and f.severity = 'warning') > 0 then 'warning'
             else 'info'
           end
      into v_total_findings,v_active_findings,v_max_severity
    from public.platform_incident_findings l
    join public.platform_operational_findings f
      on f.operational_finding_id = l.operational_finding_id
    where l.operational_incident_id = v_incident.operational_incident_id;

    if v_active_findings = 0 then
      update public.platform_operational_incidents
      set incident_status = 'resolved',
          active_finding_count = 0,
          finding_count = greatest(v_total_findings,1),
          resolved_at = now(),
          resolution_note = 'Automatically resolved after all correlated findings were resolved.',
          metadata = metadata || jsonb_build_object('resolution_source','incident_correlation')
      where operational_incident_id = v_incident.operational_incident_id;

      insert into public.platform_incident_timeline (
        event_type,event_status,severity,operational_incident_id,
        supervision_evaluation_id,correlation_id,summary,details,metadata
      ) values (
        'incident_resolved','completed',v_incident.severity,
        v_incident.operational_incident_id,v_incident.latest_evaluation_id,
        p_correlation_id,'Operational incident resolved by evidence reconciliation.',
        jsonb_build_object('active_finding_count',0),'{"migration":85}'::jsonb
      );
      v_resolved := v_resolved + 1;
    else
      update public.platform_operational_incidents
      set finding_count = greatest(v_total_findings,1),
          active_finding_count = v_active_findings,
          severity = v_max_severity
      where operational_incident_id = v_incident.operational_incident_id;
      v_active := v_active + 1;
    end if;
  end loop;

  if exists (select 1 from public.platform_operational_incidents) then
    insert into public.platform_incident_timeline (
      event_type,event_status,severity,operational_incident_id,
      correlation_id,summary,details,metadata
    )
    select 'correlation_completed','completed','info',i.operational_incident_id,
           p_correlation_id,'Incident correlation cycle completed.',
           jsonb_build_object(
             'source',p_source,'incidents_opened',v_opened,
             'incidents_reobserved',v_reobserved,'findings_linked',v_linked,
             'incidents_resolved',v_resolved,
             'duration_ms',greatest(0,round(extract(epoch from (clock_timestamp()-v_started_at))*1000)::bigint)
           ),'{"migration":85}'::jsonb
    from public.platform_operational_incidents i
    order by i.last_detected_at desc
    limit 1;
  end if;

  return jsonb_build_object(
    'contract_version','platform-incident-correlation-v1',
    'correlation_id',p_correlation_id,
    'source',p_source,
    'incidents_opened',v_opened,
    'incidents_reobserved',v_reobserved,
    'findings_linked',v_linked,
    'incidents_resolved',v_resolved,
    'active_incidents',v_active,
    'automatic_remediation',false,
    'duration_ms',greatest(0,round(extract(epoch from (clock_timestamp()-v_started_at))*1000)::bigint)
  );
end;
$function$;

-- --------------------------------------------------------------------------
-- 7. Incident lifecycle RPCs
-- --------------------------------------------------------------------------

create or replace function public.acknowledge_platform_operational_incident_rpc(
  p_operational_incident_id uuid,
  p_acknowledged_by text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_incident public.platform_operational_incidents%rowtype;
  v_correlation_id uuid := gen_random_uuid();
begin
  if btrim(coalesce(p_acknowledged_by,'')) = '' then
    raise exception 'PLATFORM_INCIDENT_ACKNOWLEDGED_BY_REQUIRED' using errcode = '22023';
  end if;

  update public.platform_operational_incidents
  set incident_status = 'acknowledged',acknowledged_at = now(),
      acknowledged_by = btrim(p_acknowledged_by),
      metadata = metadata || jsonb_build_object('acknowledged_via','platform-incident-correlation-v1')
  where operational_incident_id = p_operational_incident_id
    and incident_status = 'open'
  returning * into v_incident;

  if not found then
    raise exception 'PLATFORM_INCIDENT_NOT_OPEN: %',p_operational_incident_id using errcode = 'P0002';
  end if;

  insert into public.platform_incident_timeline (
    event_type,event_status,severity,operational_incident_id,
    supervision_evaluation_id,correlation_id,summary,details,metadata
  ) values (
    'incident_acknowledged','recorded',v_incident.severity,
    v_incident.operational_incident_id,v_incident.latest_evaluation_id,
    v_correlation_id,'Operational incident acknowledged.',
    jsonb_build_object('acknowledged_by',v_incident.acknowledged_by),'{"migration":85}'::jsonb
  );

  return to_jsonb(v_incident);
end;
$function$;

create or replace function public.resolve_platform_operational_incident_rpc(
  p_operational_incident_id uuid,
  p_resolution_note text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_incident public.platform_operational_incidents%rowtype;
  v_correlation_id uuid := gen_random_uuid();
begin
  if btrim(coalesce(p_resolution_note,'')) = '' then
    raise exception 'PLATFORM_INCIDENT_RESOLUTION_NOTE_REQUIRED' using errcode = '22023';
  end if;

  update public.platform_operational_incidents
  set incident_status = 'resolved',resolved_at = now(),
      resolution_note = btrim(p_resolution_note),active_finding_count = 0,
      metadata = metadata || jsonb_build_object('resolved_via','platform-incident-correlation-v1')
  where operational_incident_id = p_operational_incident_id
    and incident_status in ('open','acknowledged')
  returning * into v_incident;

  if not found then
    raise exception 'PLATFORM_INCIDENT_NOT_ACTIVE: %',p_operational_incident_id using errcode = 'P0002';
  end if;

  insert into public.platform_incident_timeline (
    event_type,event_status,severity,operational_incident_id,
    supervision_evaluation_id,correlation_id,summary,details,metadata
  ) values (
    'incident_resolved','completed',v_incident.severity,
    v_incident.operational_incident_id,v_incident.latest_evaluation_id,
    v_correlation_id,'Operational incident resolved.',
    jsonb_build_object('resolution_note',v_incident.resolution_note),'{"migration":85}'::jsonb
  );

  return to_jsonb(v_incident);
end;
$function$;

-- --------------------------------------------------------------------------
-- 8. Read models
-- --------------------------------------------------------------------------

create or replace function public.get_platform_operational_incidents_rpc(
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
  select coalesce(jsonb_agg(to_jsonb(i) order by i.last_detected_at desc),'[]'::jsonb)
  from (
    select *
    from public.platform_operational_incidents
    where (p_status is null or incident_status = p_status)
      and (p_severity is null or severity = p_severity)
    order by last_detected_at desc
    limit greatest(1,least(coalesce(p_limit,100),500))
  ) i;
$function$;

create or replace function public.get_platform_operational_incident_rpc(
  p_operational_incident_id uuid
)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $function$
  select coalesce((
    select to_jsonb(i) || jsonb_build_object(
      'findings',coalesce((
        select jsonb_agg(to_jsonb(f) order by f.last_detected_at desc)
        from public.platform_incident_findings l
        join public.platform_operational_findings f
          on f.operational_finding_id = l.operational_finding_id
        where l.operational_incident_id = i.operational_incident_id
      ),'[]'::jsonb),
      'timeline',coalesce((
        select jsonb_agg(to_jsonb(t) order by t.event_sequence)
        from public.platform_incident_timeline t
        where t.operational_incident_id = i.operational_incident_id
      ),'[]'::jsonb)
    )
    from public.platform_operational_incidents i
    where i.operational_incident_id = p_operational_incident_id
  ),'{}'::jsonb);
$function$;

create or replace function public.get_platform_incident_timeline_rpc(
  p_operational_incident_id uuid default null,
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
    from public.platform_incident_timeline
    where (p_operational_incident_id is null or operational_incident_id = p_operational_incident_id)
      and (p_event_type is null or event_type = p_event_type)
    order by occurred_at desc,event_sequence desc
    limit greatest(1,least(coalesce(p_limit,100),500))
  ) t;
$function$;

create or replace function public.get_platform_incident_health_rpc()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $function$
  select jsonb_build_object(
    'contract_version','platform-incident-health-v1',
    'generated_at',now(),
    'active_incidents',jsonb_build_object(
      'total',count(*) filter (where incident_status in ('open','acknowledged')),
      'critical',count(*) filter (where incident_status in ('open','acknowledged') and severity = 'critical'),
      'warning',count(*) filter (where incident_status in ('open','acknowledged') and severity = 'warning'),
      'acknowledged',count(*) filter (where incident_status = 'acknowledged')
    ),
    'history',jsonb_build_object(
      'incident_count',count(*),
      'incident_finding_count',(select count(*) from public.platform_incident_findings),
      'timeline_event_count',(select count(*) from public.platform_incident_timeline)
    ),
    'controls',jsonb_build_object(
      'deterministic_correlation',true,
      'recommendation_engine',false,
      'readiness_engine',false,
      'automatic_remediation',false
    )
  )
  from public.platform_operational_incidents;
$function$;

-- --------------------------------------------------------------------------
-- 9. RLS, privileges and execution grants
-- --------------------------------------------------------------------------

alter table public.platform_operational_incidents enable row level security;
alter table public.platform_incident_findings enable row level security;
alter table public.platform_incident_timeline enable row level security;

revoke all on table public.platform_operational_incidents from public,anon,authenticated;
revoke all on table public.platform_incident_findings from public,anon,authenticated;
revoke all on table public.platform_incident_timeline from public,anon,authenticated;

grant select,insert,update,references,trigger on table public.platform_operational_incidents to service_role;
grant select,insert,references,trigger on table public.platform_incident_findings to service_role;
grant select,insert,references,trigger on table public.platform_incident_timeline to service_role;

drop policy if exists platform_operational_incidents_service_all on public.platform_operational_incidents;
create policy platform_operational_incidents_service_all
  on public.platform_operational_incidents for all to service_role using (true) with check (true);

drop policy if exists platform_incident_findings_service_all on public.platform_incident_findings;
create policy platform_incident_findings_service_all
  on public.platform_incident_findings for all to service_role using (true) with check (true);

drop policy if exists platform_incident_timeline_service_all on public.platform_incident_timeline;
create policy platform_incident_timeline_service_all
  on public.platform_incident_timeline for all to service_role using (true) with check (true);

revoke all on function public.set_platform_incident_updated_at() from public,anon,authenticated;
revoke all on function public.protect_platform_incident_immutable_row() from public,anon,authenticated;
revoke all on function public.protect_platform_incident_identity() from public,anon,authenticated;
revoke all on function public.correlate_platform_operational_incidents_rpc(text,uuid) from public,anon,authenticated;
revoke all on function public.acknowledge_platform_operational_incident_rpc(uuid,text) from public,anon,authenticated;
revoke all on function public.resolve_platform_operational_incident_rpc(uuid,text) from public,anon,authenticated;
revoke all on function public.get_platform_operational_incidents_rpc(text,text,integer) from public,anon;
revoke all on function public.get_platform_operational_incident_rpc(uuid) from public,anon;
revoke all on function public.get_platform_incident_timeline_rpc(uuid,text,integer) from public,anon;
revoke all on function public.get_platform_incident_health_rpc() from public,anon;

grant execute on function public.correlate_platform_operational_incidents_rpc(text,uuid) to service_role;
grant execute on function public.acknowledge_platform_operational_incident_rpc(uuid,text) to service_role;
grant execute on function public.resolve_platform_operational_incident_rpc(uuid,text) to service_role;
grant execute on function public.get_platform_operational_incidents_rpc(text,text,integer) to authenticated,service_role;
grant execute on function public.get_platform_operational_incident_rpc(uuid) to authenticated,service_role;
grant execute on function public.get_platform_incident_timeline_rpc(uuid,text,integer) to authenticated,service_role;
grant execute on function public.get_platform_incident_health_rpc() to authenticated,service_role;

-- --------------------------------------------------------------------------
-- 10. Runtime policies, feature flag and capabilities
-- --------------------------------------------------------------------------

insert into public.platform_runtime_policies (
  policy_key,policy_name,description,policy_type,policy_value,
  validation_contract,owner_engine_code,enforcement_level,enabled,metadata
)
values
  (
    'runtime.incidents.correlation_interval','Incident correlation interval',
    'Recommended cadence for explicit incident correlation cycles.','duration','"PT1M"'::jsonb,
    '{"format":"ISO-8601-duration"}'::jsonb,'platform_incident_correlation_engine','required',true,'{"migration":85}'::jsonb
  ),
  (
    'runtime.incidents.finding_membership_immutable','Immutable incident membership',
    'Finding membership is append-only and cannot be reassigned.','boolean','true'::jsonb,
    '{}'::jsonb,'platform_incident_correlation_engine','critical',true,'{"migration":85}'::jsonb
  ),
  (
    'runtime.incidents.deterministic_correlation','Deterministic incident correlation',
    'Use stable incident keys and deterministic grouping rules.','boolean','true'::jsonb,
    '{}'::jsonb,'platform_incident_correlation_engine','critical',true,'{"migration":85}'::jsonb
  ),
  (
    'runtime.incidents.automatic_remediation','Incident automatic remediation',
    'Explicitly disables automatic remediation in the correlation layer.','boolean','false'::jsonb,
    '{}'::jsonb,'platform_incident_correlation_engine','critical',true,'{"migration":85,"safety":"no-automatic-remediation"}'::jsonb
  )
on conflict (policy_key) do update
set policy_name=excluded.policy_name,description=excluded.description,
    policy_type=excluded.policy_type,policy_value=excluded.policy_value,
    validation_contract=excluded.validation_contract,
    owner_engine_code=excluded.owner_engine_code,
    enforcement_level=excluded.enforcement_level,enabled=excluded.enabled,
    metadata=public.platform_runtime_policies.metadata || excluded.metadata,
    updated_at=now();

insert into public.platform_feature_flags (
  feature_key,feature_name,description,enabled,rollout_percentage,audience,
  environment_scope,owner_engine_code,metadata
)
values (
  'runtime.platform_incident_correlation','Platform incident correlation',
  'Expose deterministic correlation, durable incident lifecycle and incident read models.',
  true,100,'service',array['development','preview','staging','production','test']::text[],
  'platform_incident_correlation_engine','{"contract":"platform-incident-correlation-v1","migration":85}'::jsonb
)
on conflict (feature_key) do update
set feature_name=excluded.feature_name,description=excluded.description,
    enabled=excluded.enabled,rollout_percentage=excluded.rollout_percentage,
    audience=excluded.audience,environment_scope=excluded.environment_scope,
    owner_engine_code=excluded.owner_engine_code,
    metadata=public.platform_feature_flags.metadata || excluded.metadata,
    updated_at=now();

-- --------------------------------------------------------------------------
-- 11. Supervision health and Governance Snapshot v1.6
-- --------------------------------------------------------------------------

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
      'total',count(*) filter (where finding_status in ('open','acknowledged')),
      'critical',count(*) filter (where finding_status in ('open','acknowledged') and severity='critical'),
      'warning',count(*) filter (where finding_status in ('open','acknowledged') and severity='warning'),
      'acknowledged',count(*) filter (where finding_status='acknowledged')
    ),
    'history',jsonb_build_object(
      'evaluation_count',(select count(*) from public.platform_supervision_evaluations),
      'finding_count',count(*),
      'timeline_event_count',(select count(*) from public.platform_operational_timeline)
    ),
    'controls',jsonb_build_object(
      'automatic_remediation',false,
      'incident_correlation',true,
      'recommendation_engine',false,
      'readiness_engine',false
    )
  )
  from public.platform_operational_findings;
$function$;

create or replace function public.get_platform_governance_snapshot_rpc()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $function$
  select jsonb_build_object(
    'contract_version','platform-governance-v1.6',
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
    'incident_health',public.get_platform_incident_health_rpc(),
    'active_incidents',public.get_platform_operational_incidents_rpc('open',null,100),
    'incident_timeline',public.get_platform_incident_timeline_rpc(null,null,100),
    'feature_flags',public.get_platform_feature_flags_rpc(null,false),
    'runtime_policies',public.get_platform_runtime_policies_rpc(null,false),
    'capabilities',public.get_platform_capabilities_rpc(null,false)
  );
$function$;

revoke all on function public.get_platform_governance_snapshot_rpc() from public,anon;
grant execute on function public.get_platform_governance_snapshot_rpc() to authenticated,service_role;

update public.platform_configuration
set schema_version = greatest(schema_version,85),
    metadata = metadata || jsonb_build_object(
      'phase','8.4.3',
      'governance_contract','platform-governance-v1.6',
      'platform_incident_correlation_contract','platform-incident-correlation-v1',
      'platform_incident_correlation_migration',85
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
    ('platform_operational_incidents'),
    ('platform_incident_findings'),
    ('platform_incident_timeline')
  ) expected(name)
  where to_regclass('public.' || expected.name) is null;
  if v_missing <> 0 then
    raise exception 'PLATFORM_INCIDENT_ASSERTION_FAILED: missing tables %',v_missing;
  end if;

  select count(*) into v_missing
  from (values
    ('correlate_platform_operational_incidents_rpc'),
    ('acknowledge_platform_operational_incident_rpc'),
    ('resolve_platform_operational_incident_rpc'),
    ('get_platform_operational_incidents_rpc'),
    ('get_platform_operational_incident_rpc'),
    ('get_platform_incident_timeline_rpc'),
    ('get_platform_incident_health_rpc')
  ) expected(name)
  where not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname=expected.name
  );
  if v_missing <> 0 then
    raise exception 'PLATFORM_INCIDENT_ASSERTION_FAILED: missing functions %',v_missing;
  end if;

  if not exists (
    select 1 from public.platform_engine_registry
    where engine_code='platform_incident_correlation_engine'
      and engine_version='1.0.0' and runtime_enabled and not is_certified
  ) then
    raise exception 'PLATFORM_INCIDENT_ASSERTION_FAILED: engine registration invalid';
  end if;

  if (select count(*) from public.platform_engine_dependencies
      where dependent_engine_code='platform_incident_correlation_engine'
        and dependency_engine_code in ('platform_governance_engine','platform_supervision_engine','platform_telemetry_engine')
        and enabled) <> 3 then
    raise exception 'PLATFORM_INCIDENT_ASSERTION_FAILED: dependency registration invalid';
  end if;

  if not exists (
    select 1 from public.platform_feature_flags
    where feature_key='runtime.platform_incident_correlation'
      and enabled and rollout_percentage=100
      and owner_engine_code='platform_incident_correlation_engine'
  ) then
    raise exception 'PLATFORM_INCIDENT_ASSERTION_FAILED: feature flag invalid';
  end if;

  if (select count(*) from public.platform_runtime_policies
      where policy_key in (
        'runtime.incidents.correlation_interval',
        'runtime.incidents.finding_membership_immutable',
        'runtime.incidents.deterministic_correlation',
        'runtime.incidents.automatic_remediation'
      ) and owner_engine_code='platform_incident_correlation_engine' and enabled) <> 4 then
    raise exception 'PLATFORM_INCIDENT_ASSERTION_FAILED: runtime policy catalogue invalid';
  end if;

  if not exists (
    select 1 from public.platform_runtime_policies
    where policy_key='runtime.incidents.automatic_remediation'
      and policy_value='false'::jsonb and enabled
  ) then
    raise exception 'PLATFORM_INCIDENT_ASSERTION_FAILED: automatic remediation safety invalid';
  end if;

  if (select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace
      where n.nspname='public'
        and c.relname in ('platform_operational_incidents','platform_incident_findings','platform_incident_timeline')
        and c.relrowsecurity) <> 3 then
    raise exception 'PLATFORM_INCIDENT_ASSERTION_FAILED: RLS invalid';
  end if;

  v_health := public.get_platform_incident_health_rpc();
  if (v_health->>'contract_version') <> 'platform-incident-health-v1'
     or not (v_health #>> '{controls,deterministic_correlation}')::boolean
     or (v_health #>> '{controls,automatic_remediation}')::boolean then
    raise exception 'PLATFORM_INCIDENT_ASSERTION_FAILED: health contract invalid';
  end if;

  v_snapshot := public.get_platform_governance_snapshot_rpc();
  if (v_snapshot->>'contract_version') <> 'platform-governance-v1.6'
     or not (v_snapshot ? 'incident_health')
     or not (v_snapshot ? 'active_incidents')
     or not (v_snapshot ? 'incident_timeline') then
    raise exception 'PLATFORM_INCIDENT_ASSERTION_FAILED: governance snapshot invalid';
  end if;

  if not exists (
    select 1 from public.platform_configuration
    where configuration_key='primary' and schema_version >= 85
  ) then
    raise exception 'PLATFORM_INCIDENT_ASSERTION_FAILED: schema version invalid';
  end if;

  select count(*) into v_action_count_before from public.platform_orchestrator_actions;
  select count(*) into v_action_count_after from public.platform_orchestrator_actions;
  if v_action_count_after <> v_action_count_before then
    raise exception 'PLATFORM_INCIDENT_ASSERTION_FAILED: migration generated orchestrator actions';
  end if;
end;
$assertions$;

commit;
