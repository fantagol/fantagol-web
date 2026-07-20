-- ============================================================================
-- FANTAGOL
-- Migration 086: Operational Recommendation Engine
-- Phase 8.4.4
--
-- Purpose
--   Derive deterministic, explainable and non-executing operational
--   recommendations from active correlated incidents. Recommendations are
--   durable decision-support records with immutable evidence and timeline.
--
-- Safety
--   This engine never dispatches jobs, mutates incident/finding lifecycle,
--   changes platform configuration or creates orchestrator actions. Acceptance
--   is an explicit human/service decision and does not execute remediation.
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
  'platform_recommendation_engine','Platform Operational Recommendation Engine',
  '1.0.0','observability','active',true,false,null,null,'platform',150,
  '["platform_governance_engine","platform_supervision_engine","platform_incident_correlation_engine"]'::jsonb,
  jsonb_build_object(
    'phase','8.4.4','contract','platform-operational-recommendation-v1',
    'migration',86,'generation_mode','explicit-deterministic',
    'explainable',true,'automatic_execution',false
  )
)
on conflict (engine_code) do update
set engine_name=excluded.engine_name,engine_version=excluded.engine_version,
    engine_kind=excluded.engine_kind,lifecycle_status=excluded.lifecycle_status,
    runtime_enabled=excluded.runtime_enabled,is_certified=excluded.is_certified,
    certification_version=excluded.certification_version,certified_at=excluded.certified_at,
    owner_scope=excluded.owner_scope,installation_order=excluded.installation_order,
    dependencies=excluded.dependencies,
    metadata=public.platform_engine_registry.metadata || excluded.metadata,
    updated_at=now();

insert into public.platform_engine_dependencies (
  dependent_engine_code,dependency_engine_code,dependency_type,minimum_version,
  requires_runtime_enabled,requires_certification,allowed_dependency_statuses,
  enabled,rationale,metadata
)
values
 ('platform_recommendation_engine','platform_governance_engine','required','1.0.0',true,true,array['active','degraded']::text[],true,
  'Recommendation generation is governed by the certified platform registry and policy catalogue.','{"migration":86}'::jsonb),
 ('platform_recommendation_engine','platform_supervision_engine','runtime','1.0.0',true,false,array['active','degraded']::text[],true,
  'Supervision evidence remains authoritative and traceable through incidents.','{"migration":86}'::jsonb),
 ('platform_recommendation_engine','platform_incident_correlation_engine','runtime','1.0.0',true,false,array['active','degraded']::text[],true,
  'Active correlated incidents are the authoritative recommendation input.','{"migration":86}'::jsonb)
on conflict (dependent_engine_code,dependency_engine_code) do update
set dependency_type=excluded.dependency_type,minimum_version=excluded.minimum_version,
    requires_runtime_enabled=excluded.requires_runtime_enabled,
    requires_certification=excluded.requires_certification,
    allowed_dependency_statuses=excluded.allowed_dependency_statuses,
    enabled=excluded.enabled,rationale=excluded.rationale,
    metadata=public.platform_engine_dependencies.metadata || excluded.metadata,
    updated_at=now();

-- --------------------------------------------------------------------------
-- 2. Durable operational recommendations
-- --------------------------------------------------------------------------

create table if not exists public.platform_operational_recommendations (
  operational_recommendation_id uuid primary key default gen_random_uuid(),
  recommendation_sequence bigint generated always as identity unique,
  contract_version text not null default 'platform-operational-recommendation-v1',
  recommendation_key text not null,
  recommendation_type text not null,
  recommendation_status text not null default 'proposed',
  priority text not null,
  title text not null,
  rationale text not null,
  proposed_action text not null,
  operational_incident_id uuid not null,
  source_incident_key text not null,
  source_incident_severity text not null,
  correlation_id uuid not null default gen_random_uuid(),
  first_generated_at timestamptz not null default now(),
  last_generated_at timestamptz not null default now(),
  observation_count integer not null default 1,
  confidence_score numeric(5,4) not null,
  estimated_risk text not null,
  requires_human_approval boolean not null default true,
  executable boolean not null default false,
  evidence jsonb not null default '{}'::jsonb,
  decision_context jsonb not null default '{}'::jsonb,
  accepted_at timestamptz,
  accepted_by text,
  dismissed_at timestamptz,
  dismissed_by text,
  decision_note text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint platform_recommendations_contract_ck check (contract_version='platform-operational-recommendation-v1'),
  constraint platform_recommendations_key_ck check (recommendation_key ~ '^[a-z][a-z0-9_.:-]*$'),
  constraint platform_recommendations_type_ck check (recommendation_type in (
    'refresh_telemetry','inspect_engine','review_sla','inspect_metric','review_platform_health','manual_investigation'
  )),
  constraint platform_recommendations_status_ck check (recommendation_status in ('proposed','accepted','dismissed','superseded')),
  constraint platform_recommendations_priority_ck check (priority in ('low','medium','high','urgent')),
  constraint platform_recommendations_severity_ck check (source_incident_severity in ('info','warning','critical')),
  constraint platform_recommendations_risk_ck check (estimated_risk in ('low','medium','high')),
  constraint platform_recommendations_text_ck check (btrim(title)<>'' and btrim(rationale)<>'' and btrim(proposed_action)<>''),
  constraint platform_recommendations_confidence_ck check (confidence_score >= 0 and confidence_score <= 1),
  constraint platform_recommendations_observation_ck check (observation_count > 0 and last_generated_at >= first_generated_at),
  constraint platform_recommendations_safety_ck check (requires_human_approval and not executable),
  constraint platform_recommendations_evidence_ck check (jsonb_typeof(evidence)='object'),
  constraint platform_recommendations_context_ck check (jsonb_typeof(decision_context)='object'),
  constraint platform_recommendations_metadata_ck check (jsonb_typeof(metadata)='object'),
  constraint platform_recommendations_accept_ck check (
    (recommendation_status <> 'accepted' and accepted_at is null and accepted_by is null)
    or (recommendation_status='accepted' and accepted_at is not null and btrim(coalesce(accepted_by,''))<>'')
  ),
  constraint platform_recommendations_dismiss_ck check (
    (recommendation_status <> 'dismissed' and dismissed_at is null and dismissed_by is null)
    or (recommendation_status='dismissed' and dismissed_at is not null and btrim(coalesce(dismissed_by,''))<>'')
  ),
  constraint platform_recommendations_incident_fk foreign key (operational_incident_id)
    references public.platform_operational_incidents(operational_incident_id) on delete restrict
);

create unique index if not exists platform_recommendations_active_key_uq
  on public.platform_operational_recommendations(recommendation_key)
  where recommendation_status in ('proposed','accepted');
create index if not exists platform_recommendations_status_idx
  on public.platform_operational_recommendations(recommendation_status,priority,last_generated_at desc);
create index if not exists platform_recommendations_incident_idx
  on public.platform_operational_recommendations(operational_incident_id,recommendation_status);

comment on table public.platform_operational_recommendations is
  'Explainable, non-executing operational recommendations derived from correlated incidents.';

-- --------------------------------------------------------------------------
-- 3. Immutable recommendation timeline
-- --------------------------------------------------------------------------

create table if not exists public.platform_recommendation_timeline (
  recommendation_timeline_event_id uuid primary key default gen_random_uuid(),
  event_sequence bigint generated always as identity unique,
  contract_version text not null default 'platform-recommendation-timeline-v1',
  event_type text not null,
  event_status text not null default 'recorded',
  priority text not null default 'low',
  occurred_at timestamptz not null default now(),
  operational_recommendation_id uuid not null,
  operational_incident_id uuid not null,
  correlation_id uuid not null,
  causation_id uuid,
  summary text not null,
  details jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,

  constraint platform_recommendation_timeline_contract_ck check (contract_version='platform-recommendation-timeline-v1'),
  constraint platform_recommendation_timeline_type_ck check (event_type in (
    'recommendation_proposed','recommendation_reobserved','recommendation_accepted',
    'recommendation_dismissed','recommendation_superseded','generation_completed'
  )),
  constraint platform_recommendation_timeline_status_ck check (event_status in ('recorded','completed','failed')),
  constraint platform_recommendation_timeline_priority_ck check (priority in ('low','medium','high','urgent')),
  constraint platform_recommendation_timeline_summary_ck check (btrim(summary)<>''),
  constraint platform_recommendation_timeline_details_ck check (jsonb_typeof(details)='object'),
  constraint platform_recommendation_timeline_metadata_ck check (jsonb_typeof(metadata)='object'),
  constraint platform_recommendation_timeline_recommendation_fk foreign key (operational_recommendation_id)
    references public.platform_operational_recommendations(operational_recommendation_id) on delete restrict,
  constraint platform_recommendation_timeline_incident_fk foreign key (operational_incident_id)
    references public.platform_operational_incidents(operational_incident_id) on delete restrict
);

create index if not exists platform_recommendation_timeline_time_idx
  on public.platform_recommendation_timeline(occurred_at desc);
create index if not exists platform_recommendation_timeline_recommendation_idx
  on public.platform_recommendation_timeline(operational_recommendation_id,event_sequence);
create index if not exists platform_recommendation_timeline_correlation_idx
  on public.platform_recommendation_timeline(correlation_id,occurred_at);

comment on table public.platform_recommendation_timeline is
  'Immutable append-only journal for recommendation generation and decisions.';

-- --------------------------------------------------------------------------
-- 4. Guards
-- --------------------------------------------------------------------------

create or replace function public.set_platform_recommendation_updated_at()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $function$
begin new.updated_at:=now(); return new; end;
$function$;

create or replace function public.protect_platform_recommendation_identity()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $function$
begin
  if tg_op='DELETE' then
    raise exception 'PLATFORM_RECOMMENDATION_DELETE_FORBIDDEN' using errcode='55000';
  end if;
  if old.operational_recommendation_id is distinct from new.operational_recommendation_id
     or old.recommendation_sequence is distinct from new.recommendation_sequence
     or old.contract_version is distinct from new.contract_version
     or old.recommendation_key is distinct from new.recommendation_key
     or old.recommendation_type is distinct from new.recommendation_type
     or old.operational_incident_id is distinct from new.operational_incident_id
     or old.source_incident_key is distinct from new.source_incident_key
     or old.first_generated_at is distinct from new.first_generated_at
     or old.created_at is distinct from new.created_at
     or new.executable
     or not new.requires_human_approval then
    raise exception 'PLATFORM_RECOMMENDATION_IDENTITY_IMMUTABLE: %',old.operational_recommendation_id using errcode='55000';
  end if;
  return new;
end;
$function$;

create or replace function public.protect_platform_recommendation_timeline_row()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $function$
begin
  raise exception 'PLATFORM_RECOMMENDATION_TIMELINE_IMMUTABLE: operation=%',tg_op using errcode='55000';
end;
$function$;

drop trigger if exists trg_platform_recommendations_updated_at on public.platform_operational_recommendations;
create trigger trg_platform_recommendations_updated_at before update on public.platform_operational_recommendations
for each row execute function public.set_platform_recommendation_updated_at();

drop trigger if exists trg_protect_platform_recommendation_identity on public.platform_operational_recommendations;
create trigger trg_protect_platform_recommendation_identity before update or delete on public.platform_operational_recommendations
for each row execute function public.protect_platform_recommendation_identity();

drop trigger if exists trg_protect_platform_recommendation_timeline on public.platform_recommendation_timeline;
create trigger trg_protect_platform_recommendation_timeline before update or delete on public.platform_recommendation_timeline
for each row execute function public.protect_platform_recommendation_timeline_row();

-- --------------------------------------------------------------------------
-- 5. Deterministic recommendation generation
-- --------------------------------------------------------------------------

create or replace function public.generate_platform_operational_recommendations_rpc(
  p_source text default 'manual',
  p_correlation_id uuid default gen_random_uuid()
)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $function$
declare
  v_started_at timestamptz:=clock_timestamp();
  v_incident record;
  v_existing public.platform_operational_recommendations%rowtype;
  v_key text; v_type text; v_title text; v_rationale text; v_action text;
  v_priority text; v_risk text; v_confidence numeric(5,4);
  v_id uuid; v_proposed integer:=0; v_reobserved integer:=0; v_superseded integer:=0; v_active integer:=0;
begin
  if p_source not in ('scheduled','manual','startup','recovery','maintenance','test') then
    raise exception 'PLATFORM_RECOMMENDATION_INVALID_SOURCE: %',p_source using errcode='22023';
  end if;

  for v_incident in
    select * from public.platform_operational_incidents
    where incident_status in ('open','acknowledged')
    order by incident_sequence
  loop
    v_key := 'recommendation:' || v_incident.incident_key;
    v_priority := case v_incident.severity when 'critical' then 'urgent' when 'warning' then 'high' else 'medium' end;
    v_risk := case v_incident.severity when 'critical' then 'high' when 'warning' then 'medium' else 'low' end;

    case v_incident.incident_type
      when 'telemetry_availability' then
        v_type:='refresh_telemetry'; v_title:='Refresh and validate platform telemetry';
        v_rationale:='The latest correlated incident indicates stale or unavailable telemetry evidence.';
        v_action:='Run a fresh telemetry collection cycle, validate snapshot freshness, then re-run operational supervision.';
        v_confidence:=0.9800;
      when 'engine_degradation' then
        v_type:='inspect_engine'; v_title:='Inspect degraded platform engine';
        v_rationale:='A correlated incident identifies degradation associated with a registered platform engine.';
        v_action:='Inspect the engine runtime state, dependencies, recent receipts and dead letters before any intervention.';
        v_confidence:=0.9400;
      when 'sla_degradation' then
        v_type:='review_sla'; v_title:='Review degraded service-level objective';
        v_rationale:='A correlated incident identifies a service-level objective outside its expected operating range.';
        v_action:='Review SLA evidence, affected engine receipts and the governing threshold before approving corrective work.';
        v_confidence:=0.9200;
      when 'metric_degradation' then
        v_type:='inspect_metric'; v_title:='Inspect degraded operational metric';
        v_rationale:='A correlated incident identifies a monitored metric outside its accepted range.';
        v_action:='Inspect the metric trend, source evidence and related engine state to determine the appropriate response.';
        v_confidence:=0.9000;
      when 'platform_degradation' then
        v_type:='review_platform_health'; v_title:='Review overall platform health';
        v_rationale:='A correlated incident indicates broad platform health degradation.';
        v_action:='Review governance, telemetry, dispatcher, supervision and incident health projections before intervention.';
        v_confidence:=0.9000;
      else
        v_type:='manual_investigation'; v_title:='Perform manual operational investigation';
        v_rationale:='The incident is not covered by a specialized deterministic recommendation rule.';
        v_action:='Review the complete incident, linked findings and timeline, then document an explicit operator decision.';
        v_confidence:=0.7500;
    end case;

    select * into v_existing from public.platform_operational_recommendations
    where recommendation_key=v_key and recommendation_status in ('proposed','accepted') for update;

    if not found then
      insert into public.platform_operational_recommendations(
        recommendation_key,recommendation_type,recommendation_status,priority,title,rationale,
        proposed_action,operational_incident_id,source_incident_key,source_incident_severity,
        correlation_id,confidence_score,estimated_risk,requires_human_approval,executable,
        evidence,decision_context,metadata
      ) values (
        v_key,v_type,'proposed',v_priority,v_title,v_rationale,v_action,
        v_incident.operational_incident_id,v_incident.incident_key,v_incident.severity,
        p_correlation_id,v_confidence,v_risk,true,false,
        jsonb_build_object('incident',to_jsonb(v_incident)),
        jsonb_build_object('source',p_source,'rule',v_type,'generator_version','1.0.0'),
        '{"migration":86}'::jsonb
      ) returning operational_recommendation_id into v_id;

      insert into public.platform_recommendation_timeline(
        event_type,event_status,priority,operational_recommendation_id,operational_incident_id,
        correlation_id,summary,details,metadata
      ) values ('recommendation_proposed','recorded',v_priority,v_id,v_incident.operational_incident_id,
        p_correlation_id,'Operational recommendation proposed.',
        jsonb_build_object('recommendation_key',v_key,'source',p_source,'confidence_score',v_confidence),
        '{"migration":86}'::jsonb);
      v_proposed:=v_proposed+1;
    else
      v_id:=v_existing.operational_recommendation_id;
      update public.platform_operational_recommendations
      set last_generated_at=now(),observation_count=observation_count+1,
          priority=v_priority,source_incident_severity=v_incident.severity,
          confidence_score=v_confidence,estimated_risk=v_risk,
          evidence=jsonb_build_object('incident',to_jsonb(v_incident)),
          decision_context=decision_context || jsonb_build_object('last_source',p_source,'last_correlation_id',p_correlation_id)
      where operational_recommendation_id=v_id;

      insert into public.platform_recommendation_timeline(
        event_type,event_status,priority,operational_recommendation_id,operational_incident_id,
        correlation_id,summary,details,metadata
      ) values ('recommendation_reobserved','recorded',v_priority,v_id,v_incident.operational_incident_id,
        p_correlation_id,'Operational recommendation observed again.',
        jsonb_build_object('recommendation_key',v_key,'source',p_source),'{"migration":86}'::jsonb);
      v_reobserved:=v_reobserved+1;
    end if;
  end loop;

  update public.platform_operational_recommendations r
  set recommendation_status='superseded',decision_note='Source incident is no longer active.',
      decision_context=decision_context || jsonb_build_object('superseded_at',now())
  where r.recommendation_status='proposed'
    and not exists (
      select 1 from public.platform_operational_incidents i
      where i.operational_incident_id=r.operational_incident_id and i.incident_status in ('open','acknowledged')
    );
  get diagnostics v_superseded=row_count;

  if v_superseded>0 then
    insert into public.platform_recommendation_timeline(
      event_type,event_status,priority,operational_recommendation_id,operational_incident_id,
      correlation_id,summary,details,metadata
    )
    select 'recommendation_superseded','recorded',r.priority,r.operational_recommendation_id,
      r.operational_incident_id,p_correlation_id,'Operational recommendation superseded.',
      jsonb_build_object('reason','source-incident-not-active'),'{"migration":86}'::jsonb
    from public.platform_operational_recommendations r
    where r.recommendation_status='superseded'
      and (r.decision_context->>'superseded_at')::timestamptz >= v_started_at;
  end if;

  select count(*) into v_active from public.platform_operational_recommendations
  where recommendation_status in ('proposed','accepted');

  if coalesce(v_id,(select operational_recommendation_id from public.platform_operational_recommendations order by recommendation_sequence limit 1)) is not null then
    insert into public.platform_recommendation_timeline(
      event_type,event_status,priority,operational_recommendation_id,operational_incident_id,
      correlation_id,summary,details,metadata
    )
    select 'generation_completed','completed','low',r.operational_recommendation_id,r.operational_incident_id,
      p_correlation_id,'Recommendation generation cycle completed.',
      jsonb_build_object('source',p_source,'recommendations_proposed',v_proposed,
        'recommendations_reobserved',v_reobserved,'recommendations_superseded',v_superseded,
        'duration_ms',greatest(0,extract(epoch from(clock_timestamp()-v_started_at))*1000)::bigint),
      '{"migration":86}'::jsonb
    from public.platform_operational_recommendations r
    where r.operational_recommendation_id=coalesce(v_id,(select operational_recommendation_id from public.platform_operational_recommendations order by recommendation_sequence limit 1));
  end if;

  return jsonb_build_object(
    'contract_version','platform-recommendation-generation-v1','source',p_source,
    'correlation_id',p_correlation_id,'recommendations_proposed',v_proposed,
    'recommendations_reobserved',v_reobserved,'recommendations_superseded',v_superseded,
    'active_recommendations',v_active,'requires_human_approval',true,
    'automatic_execution',false,
    'duration_ms',greatest(0,extract(epoch from(clock_timestamp()-v_started_at))*1000)::bigint
  );
end;
$function$;

-- --------------------------------------------------------------------------
-- 6. Explicit decision RPCs (acceptance never executes remediation)
-- --------------------------------------------------------------------------

create or replace function public.accept_platform_operational_recommendation_rpc(
  p_operational_recommendation_id uuid,p_accepted_by text,p_decision_note text default null
)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $function$
declare v_row public.platform_operational_recommendations%rowtype; v_corr uuid:=gen_random_uuid();
begin
  if btrim(coalesce(p_accepted_by,''))='' then raise exception 'PLATFORM_RECOMMENDATION_ACCEPTOR_REQUIRED' using errcode='22023'; end if;
  update public.platform_operational_recommendations
  set recommendation_status='accepted',accepted_at=now(),accepted_by=btrim(p_accepted_by),decision_note=nullif(btrim(p_decision_note),'')
  where operational_recommendation_id=p_operational_recommendation_id and recommendation_status='proposed'
  returning * into v_row;
  if not found then raise exception 'PLATFORM_RECOMMENDATION_NOT_PROPOSED: %',p_operational_recommendation_id using errcode='P0002'; end if;
  insert into public.platform_recommendation_timeline(event_type,event_status,priority,operational_recommendation_id,
    operational_incident_id,correlation_id,summary,details,metadata)
  values('recommendation_accepted','recorded',v_row.priority,v_row.operational_recommendation_id,
    v_row.operational_incident_id,v_corr,'Operational recommendation accepted.',
    jsonb_build_object('accepted_by',v_row.accepted_by,'decision_note',v_row.decision_note,'executed',false),'{"migration":86}'::jsonb);
  return to_jsonb(v_row) || jsonb_build_object('automatic_execution',false,'execution_created',false);
end;
$function$;

create or replace function public.dismiss_platform_operational_recommendation_rpc(
  p_operational_recommendation_id uuid,p_dismissed_by text,p_decision_note text
)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $function$
declare v_row public.platform_operational_recommendations%rowtype; v_corr uuid:=gen_random_uuid();
begin
  if btrim(coalesce(p_dismissed_by,''))='' or btrim(coalesce(p_decision_note,''))='' then
    raise exception 'PLATFORM_RECOMMENDATION_DISMISSAL_DETAILS_REQUIRED' using errcode='22023'; end if;
  update public.platform_operational_recommendations
  set recommendation_status='dismissed',dismissed_at=now(),dismissed_by=btrim(p_dismissed_by),decision_note=btrim(p_decision_note)
  where operational_recommendation_id=p_operational_recommendation_id and recommendation_status='proposed'
  returning * into v_row;
  if not found then raise exception 'PLATFORM_RECOMMENDATION_NOT_PROPOSED: %',p_operational_recommendation_id using errcode='P0002'; end if;
  insert into public.platform_recommendation_timeline(event_type,event_status,priority,operational_recommendation_id,
    operational_incident_id,correlation_id,summary,details,metadata)
  values('recommendation_dismissed','recorded',v_row.priority,v_row.operational_recommendation_id,
    v_row.operational_incident_id,v_corr,'Operational recommendation dismissed.',
    jsonb_build_object('dismissed_by',v_row.dismissed_by,'decision_note',v_row.decision_note),'{"migration":86}'::jsonb);
  return to_jsonb(v_row);
end;
$function$;

-- --------------------------------------------------------------------------
-- 7. Read models
-- --------------------------------------------------------------------------

create or replace function public.get_platform_operational_recommendations_rpc(
  p_status text default null,p_priority text default null,p_limit integer default 100
)
returns jsonb language sql stable security definer set search_path=public,pg_temp as $function$
  select coalesce(jsonb_agg(to_jsonb(r) order by r.recommendation_sequence desc),'[]'::jsonb)
  from (select * from public.platform_operational_recommendations
        where (p_status is null or recommendation_status=p_status)
          and (p_priority is null or priority=p_priority)
        order by recommendation_sequence desc limit greatest(1,least(coalesce(p_limit,100),500))) r;
$function$;

create or replace function public.get_platform_operational_recommendation_rpc(p_operational_recommendation_id uuid)
returns jsonb language sql stable security definer set search_path=public,pg_temp as $function$
  select to_jsonb(r) || jsonb_build_object(
    'incident',public.get_platform_operational_incident_rpc(r.operational_incident_id),
    'timeline',coalesce((select jsonb_agg(to_jsonb(t) order by t.event_sequence)
      from public.platform_recommendation_timeline t
      where t.operational_recommendation_id=r.operational_recommendation_id),'[]'::jsonb)
  ) from public.platform_operational_recommendations r
  where r.operational_recommendation_id=p_operational_recommendation_id;
$function$;

create or replace function public.get_platform_recommendation_timeline_rpc(
  p_operational_recommendation_id uuid default null,p_event_type text default null,p_limit integer default 100
)
returns jsonb language sql stable security definer set search_path=public,pg_temp as $function$
  select coalesce(jsonb_agg(to_jsonb(t) order by t.event_sequence desc),'[]'::jsonb)
  from (select * from public.platform_recommendation_timeline
        where (p_operational_recommendation_id is null or operational_recommendation_id=p_operational_recommendation_id)
          and (p_event_type is null or event_type=p_event_type)
        order by event_sequence desc limit greatest(1,least(coalesce(p_limit,100),500))) t;
$function$;

create or replace function public.get_platform_recommendation_health_rpc()
returns jsonb language sql stable security definer set search_path=public,pg_temp as $function$
  select jsonb_build_object(
    'contract_version','platform-recommendation-health-v1','generated_at',now(),
    'active_recommendations',jsonb_build_object(
      'total',count(*) filter(where recommendation_status in ('proposed','accepted')),
      'proposed',count(*) filter(where recommendation_status='proposed'),
      'accepted',count(*) filter(where recommendation_status='accepted'),
      'urgent',count(*) filter(where recommendation_status in ('proposed','accepted') and priority='urgent')
    ),
    'history',jsonb_build_object('recommendation_count',count(*),
      'timeline_event_count',(select count(*) from public.platform_recommendation_timeline)),
    'controls',jsonb_build_object('deterministic_generation',true,'explainable',true,
      'requires_human_approval',true,'automatic_execution',false,'remediation_engine',false)
  ) from public.platform_operational_recommendations;
$function$;

-- --------------------------------------------------------------------------
-- 8. RLS and privileges
-- --------------------------------------------------------------------------

alter table public.platform_operational_recommendations enable row level security;
alter table public.platform_recommendation_timeline enable row level security;

revoke all on public.platform_operational_recommendations from public,anon,authenticated;
revoke all on public.platform_recommendation_timeline from public,anon,authenticated;
grant select,insert,update on public.platform_operational_recommendations to service_role;
grant select,insert on public.platform_recommendation_timeline to service_role;

drop policy if exists platform_operational_recommendations_service_all on public.platform_operational_recommendations;
create policy platform_operational_recommendations_service_all on public.platform_operational_recommendations
for all to service_role using(true) with check(true);
drop policy if exists platform_recommendation_timeline_service_all on public.platform_recommendation_timeline;
create policy platform_recommendation_timeline_service_all on public.platform_recommendation_timeline
for all to service_role using(true) with check(true);

revoke all on function public.set_platform_recommendation_updated_at() from public,anon,authenticated;
revoke all on function public.protect_platform_recommendation_identity() from public,anon,authenticated;
revoke all on function public.protect_platform_recommendation_timeline_row() from public,anon,authenticated;
revoke all on function public.generate_platform_operational_recommendations_rpc(text,uuid) from public,anon,authenticated;
revoke all on function public.accept_platform_operational_recommendation_rpc(uuid,text,text) from public,anon,authenticated;
revoke all on function public.dismiss_platform_operational_recommendation_rpc(uuid,text,text) from public,anon,authenticated;
revoke all on function public.get_platform_operational_recommendations_rpc(text,text,integer) from public,anon;
revoke all on function public.get_platform_operational_recommendation_rpc(uuid) from public,anon;
revoke all on function public.get_platform_recommendation_timeline_rpc(uuid,text,integer) from public,anon;
revoke all on function public.get_platform_recommendation_health_rpc() from public,anon;

grant execute on function public.generate_platform_operational_recommendations_rpc(text,uuid) to service_role;
grant execute on function public.accept_platform_operational_recommendation_rpc(uuid,text,text) to service_role;
grant execute on function public.dismiss_platform_operational_recommendation_rpc(uuid,text,text) to service_role;
grant execute on function public.get_platform_operational_recommendations_rpc(text,text,integer) to authenticated,service_role;
grant execute on function public.get_platform_operational_recommendation_rpc(uuid) to authenticated,service_role;
grant execute on function public.get_platform_recommendation_timeline_rpc(uuid,text,integer) to authenticated,service_role;
grant execute on function public.get_platform_recommendation_health_rpc() to authenticated,service_role;

-- --------------------------------------------------------------------------
-- 9. Policies and feature flag
-- --------------------------------------------------------------------------

insert into public.platform_runtime_policies(
  policy_key,policy_name,description,policy_type,policy_value,validation_contract,
  owner_engine_code,enforcement_level,enabled,metadata
)
values
 ('runtime.recommendations.generation_interval','Recommendation generation interval',
  'Recommended cadence for explicit recommendation generation cycles.','duration','"PT1M"'::jsonb,
  '{"format":"ISO-8601-duration"}'::jsonb,'platform_recommendation_engine','required',true,'{"migration":86}'::jsonb),
 ('runtime.recommendations.deterministic_generation','Deterministic recommendation generation',
  'Recommendation rules must be stable, deterministic and evidence-backed.','boolean','true'::jsonb,
  '{}'::jsonb,'platform_recommendation_engine','critical',true,'{"migration":86}'::jsonb),
 ('runtime.recommendations.human_approval_required','Human approval required',
  'Every recommendation requires an explicit operator or service decision.','boolean','true'::jsonb,
  '{}'::jsonb,'platform_recommendation_engine','critical',true,'{"migration":86}'::jsonb),
 ('runtime.recommendations.automatic_execution','Recommendation automatic execution',
  'Explicitly disables execution and remediation in the recommendation layer.','boolean','false'::jsonb,
  '{}'::jsonb,'platform_recommendation_engine','critical',true,'{"migration":86,"safety":"no-automatic-execution"}'::jsonb)
on conflict(policy_key) do update
set policy_name=excluded.policy_name,description=excluded.description,policy_type=excluded.policy_type,
    policy_value=excluded.policy_value,validation_contract=excluded.validation_contract,
    owner_engine_code=excluded.owner_engine_code,enforcement_level=excluded.enforcement_level,
    enabled=excluded.enabled,metadata=public.platform_runtime_policies.metadata || excluded.metadata,updated_at=now();

insert into public.platform_feature_flags(
  feature_key,feature_name,description,enabled,rollout_percentage,audience,
  environment_scope,owner_engine_code,metadata
)
values('runtime.platform_operational_recommendations','Platform operational recommendations',
  'Expose deterministic incident-derived recommendations and decision read models.',true,100,'service',
  array['development','preview','staging','production','test']::text[],
  'platform_recommendation_engine','{"contract":"platform-operational-recommendation-v1","migration":86}'::jsonb)
on conflict(feature_key) do update
set feature_name=excluded.feature_name,description=excluded.description,enabled=excluded.enabled,
    rollout_percentage=excluded.rollout_percentage,audience=excluded.audience,
    environment_scope=excluded.environment_scope,owner_engine_code=excluded.owner_engine_code,
    metadata=public.platform_feature_flags.metadata || excluded.metadata,updated_at=now();

-- --------------------------------------------------------------------------
-- 10. Health projections and Governance Snapshot v1.7
-- --------------------------------------------------------------------------

create or replace function public.get_platform_incident_health_rpc()
returns jsonb language sql stable security definer set search_path=public,pg_temp as $function$
  select jsonb_build_object(
    'contract_version','platform-incident-health-v1','generated_at',now(),
    'active_incidents',jsonb_build_object(
      'total',count(*) filter(where incident_status in ('open','acknowledged')),
      'warning',count(*) filter(where incident_status in ('open','acknowledged') and severity='warning'),
      'critical',count(*) filter(where incident_status in ('open','acknowledged') and severity='critical'),
      'acknowledged',count(*) filter(where incident_status='acknowledged')),
    'history',jsonb_build_object('incident_count',count(*),
      'incident_finding_count',(select count(*) from public.platform_incident_findings),
      'timeline_event_count',(select count(*) from public.platform_incident_timeline)),
    'controls',jsonb_build_object('deterministic_correlation',true,'automatic_remediation',false,
      'recommendation_engine',true,'readiness_engine',false)
  ) from public.platform_operational_incidents;
$function$;

create or replace function public.get_platform_governance_snapshot_rpc()
returns jsonb language sql stable security definer set search_path=public,pg_temp as $function$
  select jsonb_build_object(
    'contract_version','platform-governance-v1.7','generated_at',now(),
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
    'feature_flags',public.get_platform_feature_flags_rpc(null,false),
    'runtime_policies',public.get_platform_runtime_policies_rpc(null,false),
    'capabilities',public.get_platform_capabilities_rpc(null,false)
  );
$function$;

revoke all on function public.get_platform_governance_snapshot_rpc() from public,anon;
grant execute on function public.get_platform_governance_snapshot_rpc() to authenticated,service_role;

update public.platform_configuration
set schema_version=greatest(schema_version,86),
    metadata=metadata || jsonb_build_object(
      'phase','8.4.4','governance_contract','platform-governance-v1.7',
      'platform_recommendation_contract','platform-operational-recommendation-v1',
      'platform_recommendation_migration',86),updated_at=now()
where configuration_key='primary';

-- --------------------------------------------------------------------------
-- 11. Assertions
-- --------------------------------------------------------------------------

do $assertions$
declare v_missing integer; v_health jsonb; v_snapshot jsonb; v_actions bigint;
begin
  select count(*) into v_missing from (values
    ('platform_operational_recommendations'),('platform_recommendation_timeline')
  ) expected(name) where to_regclass('public.'||expected.name) is null;
  if v_missing<>0 then raise exception 'PLATFORM_RECOMMENDATION_ASSERTION_FAILED: missing tables %',v_missing; end if;

  select count(*) into v_missing from (values
    ('generate_platform_operational_recommendations_rpc'),
    ('accept_platform_operational_recommendation_rpc'),
    ('dismiss_platform_operational_recommendation_rpc'),
    ('get_platform_operational_recommendations_rpc'),
    ('get_platform_operational_recommendation_rpc'),
    ('get_platform_recommendation_timeline_rpc'),
    ('get_platform_recommendation_health_rpc')
  ) expected(name) where not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname=expected.name);
  if v_missing<>0 then raise exception 'PLATFORM_RECOMMENDATION_ASSERTION_FAILED: missing functions %',v_missing; end if;

  if not exists(select 1 from public.platform_engine_registry where engine_code='platform_recommendation_engine'
    and engine_version='1.0.0' and runtime_enabled and not is_certified) then
    raise exception 'PLATFORM_RECOMMENDATION_ASSERTION_FAILED: engine registration invalid'; end if;

  if (select count(*) from public.platform_engine_dependencies where dependent_engine_code='platform_recommendation_engine'
    and dependency_engine_code in ('platform_governance_engine','platform_supervision_engine','platform_incident_correlation_engine') and enabled)<>3 then
    raise exception 'PLATFORM_RECOMMENDATION_ASSERTION_FAILED: dependencies invalid'; end if;

  if (select count(*) from public.platform_runtime_policies where policy_key in (
    'runtime.recommendations.generation_interval','runtime.recommendations.deterministic_generation',
    'runtime.recommendations.human_approval_required','runtime.recommendations.automatic_execution'
  ) and owner_engine_code='platform_recommendation_engine' and enabled)<>4 then
    raise exception 'PLATFORM_RECOMMENDATION_ASSERTION_FAILED: runtime policies invalid'; end if;

  if not exists(select 1 from public.platform_runtime_policies where policy_key='runtime.recommendations.automatic_execution'
    and policy_value='false'::jsonb and enabled) then
    raise exception 'PLATFORM_RECOMMENDATION_ASSERTION_FAILED: automatic execution safety invalid'; end if;

  if not exists(select 1 from public.platform_feature_flags where feature_key='runtime.platform_operational_recommendations'
    and enabled and rollout_percentage=100 and owner_engine_code='platform_recommendation_engine') then
    raise exception 'PLATFORM_RECOMMENDATION_ASSERTION_FAILED: feature flag invalid'; end if;

  if (select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public'
    and c.relname in ('platform_operational_recommendations','platform_recommendation_timeline') and c.relrowsecurity)<>2 then
    raise exception 'PLATFORM_RECOMMENDATION_ASSERTION_FAILED: RLS invalid'; end if;

  v_health:=public.get_platform_recommendation_health_rpc();
  if v_health->>'contract_version'<>'platform-recommendation-health-v1'
     or not (v_health#>>'{controls,deterministic_generation}')::boolean
     or not (v_health#>>'{controls,requires_human_approval}')::boolean
     or (v_health#>>'{controls,automatic_execution}')::boolean then
    raise exception 'PLATFORM_RECOMMENDATION_ASSERTION_FAILED: health invalid'; end if;

  v_snapshot:=public.get_platform_governance_snapshot_rpc();
  if v_snapshot->>'contract_version'<>'platform-governance-v1.7'
     or not(v_snapshot?'recommendation_health') or not(v_snapshot?'active_recommendations')
     or not(v_snapshot?'recommendation_timeline') then
    raise exception 'PLATFORM_RECOMMENDATION_ASSERTION_FAILED: governance invalid'; end if;

  if not exists(select 1 from public.platform_configuration where configuration_key='primary' and schema_version>=86) then
    raise exception 'PLATFORM_RECOMMENDATION_ASSERTION_FAILED: schema version invalid'; end if;

  select count(*) into v_actions
  from public.platform_orchestrator_actions
  where created_at >= transaction_timestamp();

  if v_actions <> 0 then
    raise exception 'PLATFORM_RECOMMENDATION_ASSERTION_FAILED: migration generated orchestrator actions (%).',v_actions;
  end if;
end;
$assertions$;

commit;
