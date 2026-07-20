-- ============================================================================
-- FANTAGOL
-- Migration 083: Platform Telemetry Engine
-- Phase 8.4.1
--
-- Purpose
--   Add certified platform telemetry, immutable metric snapshots, normalized
--   metric samples, KPI calculation, SLA evaluation and a durable alert
--   lifecycle on top of the Platform Control Plane completed by migrations
--   077-082.
--
-- Safety
--   Collection is explicit through a service-role RPC. This migration creates
--   no scheduler, external notification or synthetic persistent telemetry.
--   PostgreSQL remains the authoritative source for all measurements.
-- ============================================================================

begin;

-- --------------------------------------------------------------------------
-- 1. Register the Platform Telemetry Engine
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
  'platform_telemetry_engine',
  'Platform Telemetry Engine',
  '1.0.0',
  'observability',
  'active',
  true,
  true,
  '1.0.0',
  now(),
  'platform',
  120,
  '["platform_orchestrator_engine"]'::jsonb,
  jsonb_build_object(
    'phase','8.4.1',
    'contract','platform-telemetry-v1',
    'migration',83,
    'collection_mode','explicit-certified-snapshot',
    'alert_mode','durable-deduplicated-lifecycle'
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
values (
  'platform_telemetry_engine',
  'platform_orchestrator_engine',
  'runtime',
  '1.2.0',
  true,
  true,
  array['active','degraded']::text[],
  true,
  'Platform telemetry measures the certified orchestrator, dispatcher and worker runtime.',
  '{"migration":83,"contract":"platform-telemetry-v1"}'::jsonb
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
-- 2. Metric catalogue
-- --------------------------------------------------------------------------

create table if not exists public.platform_telemetry_metric_definitions (
  metric_code text primary key,
  metric_name text not null,
  description text not null,
  metric_group text not null,
  unit text not null,
  value_kind text not null default 'gauge',
  target_direction text not null default 'lower_is_better',
  warning_threshold numeric,
  critical_threshold numeric,
  enabled boolean not null default true,
  owner_engine_code text not null default 'platform_telemetry_engine',
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint platform_telemetry_metric_code_ck
    check (metric_code ~ '^[a-z][a-z0-9_.-]*$'),
  constraint platform_telemetry_metric_name_ck
    check (btrim(metric_name) <> ''),
  constraint platform_telemetry_metric_description_ck
    check (btrim(description) <> ''),
  constraint platform_telemetry_metric_group_ck
    check (metric_group in ('queue','workers','dispatcher','execution','reconciliation','recovery','maintenance','platform')),
  constraint platform_telemetry_metric_unit_ck
    check (unit in ('count','ratio','percent','milliseconds','seconds','score')),
  constraint platform_telemetry_metric_kind_ck
    check (value_kind in ('gauge','counter','rate','duration','score')),
  constraint platform_telemetry_metric_direction_ck
    check (target_direction in ('lower_is_better','higher_is_better','informational')),
  constraint platform_telemetry_metric_threshold_ck
    check (
      warning_threshold is null or critical_threshold is null
      or target_direction = 'informational'
      or (target_direction = 'lower_is_better' and warning_threshold <= critical_threshold)
      or (target_direction = 'higher_is_better' and warning_threshold >= critical_threshold)
    ),
  constraint platform_telemetry_metric_metadata_ck
    check (jsonb_typeof(metadata) = 'object'),
  constraint platform_telemetry_metric_owner_fk
    foreign key (owner_engine_code)
    references public.platform_engine_registry(engine_code)
    on update cascade on delete restrict
);

create index if not exists platform_telemetry_metric_definitions_group_idx
  on public.platform_telemetry_metric_definitions (metric_group, enabled, metric_code);

comment on table public.platform_telemetry_metric_definitions is
  'Canonical catalogue of certified FantaGol platform telemetry metrics and thresholds.';

-- --------------------------------------------------------------------------
-- 3. Immutable telemetry snapshots
-- --------------------------------------------------------------------------

create table if not exists public.platform_telemetry_snapshots (
  telemetry_snapshot_id uuid primary key default gen_random_uuid(),
  snapshot_sequence bigint generated always as identity unique,
  contract_version text not null default 'platform-telemetry-snapshot-v1',
  source text not null default 'manual',
  correlation_id uuid not null default gen_random_uuid(),
  collection_started_at timestamptz not null,
  collected_at timestamptz not null default now(),
  collection_duration_ms bigint not null,
  window_started_at timestamptz not null,
  window_ended_at timestamptz not null,
  metrics jsonb not null,
  kpis jsonb not null,
  platform_health_score numeric(5,2) not null,
  health_status text not null,
  collector_version text not null default '1.0.0',
  metadata jsonb not null default '{}'::jsonb,

  constraint platform_telemetry_snapshots_contract_ck
    check (contract_version = 'platform-telemetry-snapshot-v1'),
  constraint platform_telemetry_snapshots_source_ck
    check (source in ('scheduled','manual','startup','recovery','maintenance','test')),
  constraint platform_telemetry_snapshots_duration_ck
    check (collection_duration_ms >= 0),
  constraint platform_telemetry_snapshots_window_ck
    check (window_ended_at >= window_started_at),
  constraint platform_telemetry_snapshots_metrics_ck
    check (jsonb_typeof(metrics) = 'object'),
  constraint platform_telemetry_snapshots_kpis_ck
    check (jsonb_typeof(kpis) = 'object'),
  constraint platform_telemetry_snapshots_health_score_ck
    check (platform_health_score between 0 and 100),
  constraint platform_telemetry_snapshots_health_status_ck
    check (health_status in ('healthy','degraded','critical')),
  constraint platform_telemetry_snapshots_metadata_ck
    check (jsonb_typeof(metadata) = 'object')
);

create index if not exists platform_telemetry_snapshots_timeline_idx
  on public.platform_telemetry_snapshots (collected_at desc);

create index if not exists platform_telemetry_snapshots_health_idx
  on public.platform_telemetry_snapshots (health_status, collected_at desc);

comment on table public.platform_telemetry_snapshots is
  'Immutable point-in-time snapshots of platform metrics, KPIs and health score.';

-- --------------------------------------------------------------------------
-- 4. Normalized immutable metric samples
-- --------------------------------------------------------------------------

create table if not exists public.platform_telemetry_metric_samples (
  metric_sample_id uuid primary key default gen_random_uuid(),
  telemetry_snapshot_id uuid not null,
  metric_code text not null,
  metric_value numeric not null,
  measured_at timestamptz not null,
  dimensions jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,

  constraint platform_telemetry_metric_samples_snapshot_fk
    foreign key (telemetry_snapshot_id)
    references public.platform_telemetry_snapshots(telemetry_snapshot_id)
    on delete restrict,
  constraint platform_telemetry_metric_samples_metric_fk
    foreign key (metric_code)
    references public.platform_telemetry_metric_definitions(metric_code)
    on update cascade on delete restrict,
  constraint platform_telemetry_metric_samples_snapshot_metric_uq
    unique (telemetry_snapshot_id, metric_code),
  constraint platform_telemetry_metric_samples_dimensions_ck
    check (jsonb_typeof(dimensions) = 'object'),
  constraint platform_telemetry_metric_samples_metadata_ck
    check (jsonb_typeof(metadata) = 'object')
);

create index if not exists platform_telemetry_metric_samples_timeline_idx
  on public.platform_telemetry_metric_samples (metric_code, measured_at desc);

comment on table public.platform_telemetry_metric_samples is
  'Normalized immutable values belonging to a certified telemetry snapshot.';

-- --------------------------------------------------------------------------
-- 5. SLA definitions and immutable evaluations
-- --------------------------------------------------------------------------

create table if not exists public.platform_sla_definitions (
  sla_code text primary key,
  sla_name text not null,
  description text not null,
  metric_code text not null,
  comparison_operator text not null,
  objective_threshold numeric not null,
  warning_threshold numeric,
  critical_threshold numeric not null,
  evaluation_window_seconds integer not null default 3600,
  severity text not null default 'warning',
  enabled boolean not null default true,
  owner_engine_code text not null default 'platform_telemetry_engine',
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint platform_sla_definitions_code_ck
    check (sla_code ~ '^[a-z][a-z0-9_.-]*$'),
  constraint platform_sla_definitions_name_ck
    check (btrim(sla_name) <> ''),
  constraint platform_sla_definitions_description_ck
    check (btrim(description) <> ''),
  constraint platform_sla_definitions_operator_ck
    check (comparison_operator in ('lte','gte')),
  constraint platform_sla_definitions_window_ck
    check (evaluation_window_seconds between 60 and 2592000),
  constraint platform_sla_definitions_severity_ck
    check (severity in ('info','warning','critical')),
  constraint platform_sla_definitions_thresholds_ck
    check (
      (comparison_operator = 'lte'
        and objective_threshold <= coalesce(warning_threshold, critical_threshold)
        and coalesce(warning_threshold, objective_threshold) <= critical_threshold)
      or
      (comparison_operator = 'gte'
        and objective_threshold >= coalesce(warning_threshold, critical_threshold)
        and coalesce(warning_threshold, objective_threshold) >= critical_threshold)
    ),
  constraint platform_sla_definitions_metadata_ck
    check (jsonb_typeof(metadata) = 'object'),
  constraint platform_sla_definitions_metric_fk
    foreign key (metric_code)
    references public.platform_telemetry_metric_definitions(metric_code)
    on update cascade on delete restrict,
  constraint platform_sla_definitions_owner_fk
    foreign key (owner_engine_code)
    references public.platform_engine_registry(engine_code)
    on update cascade on delete restrict
);

create table if not exists public.platform_sla_evaluations (
  sla_evaluation_id uuid primary key default gen_random_uuid(),
  telemetry_snapshot_id uuid not null,
  sla_code text not null,
  metric_code text not null,
  observed_value numeric not null,
  objective_threshold numeric not null,
  evaluation_status text not null,
  breach_severity text,
  evaluated_at timestamptz not null default now(),
  details jsonb not null default '{}'::jsonb,

  constraint platform_sla_evaluations_snapshot_fk
    foreign key (telemetry_snapshot_id)
    references public.platform_telemetry_snapshots(telemetry_snapshot_id)
    on delete restrict,
  constraint platform_sla_evaluations_sla_fk
    foreign key (sla_code)
    references public.platform_sla_definitions(sla_code)
    on update cascade on delete restrict,
  constraint platform_sla_evaluations_metric_fk
    foreign key (metric_code)
    references public.platform_telemetry_metric_definitions(metric_code)
    on update cascade on delete restrict,
  constraint platform_sla_evaluations_snapshot_sla_uq
    unique (telemetry_snapshot_id, sla_code),
  constraint platform_sla_evaluations_status_ck
    check (evaluation_status in ('met','warning','breached','not_applicable')),
  constraint platform_sla_evaluations_severity_ck
    check (breach_severity is null or breach_severity in ('info','warning','critical')),
  constraint platform_sla_evaluations_details_ck
    check (jsonb_typeof(details) = 'object')
);

create index if not exists platform_sla_evaluations_timeline_idx
  on public.platform_sla_evaluations (evaluation_status, evaluated_at desc);

comment on table public.platform_sla_definitions is
  'Configurable platform service-level objectives evaluated from certified metrics.';
comment on table public.platform_sla_evaluations is
  'Immutable SLA evaluation results generated for each telemetry snapshot.';

-- --------------------------------------------------------------------------
-- 6. Durable telemetry alerts
-- --------------------------------------------------------------------------

create table if not exists public.platform_telemetry_alerts (
  telemetry_alert_id uuid primary key default gen_random_uuid(),
  alert_key text not null,
  alert_type text not null,
  alert_status text not null default 'open',
  severity text not null,
  title text not null,
  message text not null,
  metric_code text,
  sla_code text,
  source_snapshot_id uuid not null,
  current_value numeric,
  threshold_value numeric,
  occurrence_count integer not null default 1,
  first_detected_at timestamptz not null default now(),
  last_detected_at timestamptz not null default now(),
  acknowledged_at timestamptz,
  acknowledged_by text,
  resolved_at timestamptz,
  resolution_note text,
  context jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint platform_telemetry_alerts_key_ck
    check (alert_key ~ '^[a-z][a-z0-9_.:-]*$'),
  constraint platform_telemetry_alerts_type_ck
    check (alert_type in ('sla_breach','metric_threshold','worker_health','queue_pressure','platform_health')),
  constraint platform_telemetry_alerts_status_ck
    check (alert_status in ('open','acknowledged','resolved')),
  constraint platform_telemetry_alerts_severity_ck
    check (severity in ('info','warning','critical')),
  constraint platform_telemetry_alerts_title_ck
    check (btrim(title) <> ''),
  constraint platform_telemetry_alerts_message_ck
    check (btrim(message) <> ''),
  constraint platform_telemetry_alerts_occurrence_ck
    check (occurrence_count > 0),
  constraint platform_telemetry_alerts_context_ck
    check (jsonb_typeof(context) = 'object'),
  constraint platform_telemetry_alerts_ack_ck
    check (
      (alert_status = 'open' and acknowledged_at is null and acknowledged_by is null)
      or (alert_status in ('acknowledged','resolved'))
    ),
  constraint platform_telemetry_alerts_resolution_ck
    check (
      (alert_status <> 'resolved' and resolved_at is null)
      or (alert_status = 'resolved' and resolved_at is not null)
    ),
  constraint platform_telemetry_alerts_metric_fk
    foreign key (metric_code)
    references public.platform_telemetry_metric_definitions(metric_code)
    on update cascade on delete restrict,
  constraint platform_telemetry_alerts_sla_fk
    foreign key (sla_code)
    references public.platform_sla_definitions(sla_code)
    on update cascade on delete restrict,
  constraint platform_telemetry_alerts_snapshot_fk
    foreign key (source_snapshot_id)
    references public.platform_telemetry_snapshots(telemetry_snapshot_id)
    on delete restrict
);

create unique index if not exists platform_telemetry_alerts_active_key_uq
  on public.platform_telemetry_alerts (alert_key)
  where alert_status in ('open','acknowledged');

create index if not exists platform_telemetry_alerts_status_idx
  on public.platform_telemetry_alerts (alert_status, severity, last_detected_at desc);

comment on table public.platform_telemetry_alerts is
  'Durable deduplicated alert lifecycle produced from metrics and SLA evaluations.';

-- --------------------------------------------------------------------------
-- 7. Timestamp and immutability triggers
-- --------------------------------------------------------------------------

drop trigger if exists trg_platform_telemetry_metric_definitions_updated_at
  on public.platform_telemetry_metric_definitions;
create trigger trg_platform_telemetry_metric_definitions_updated_at
before update on public.platform_telemetry_metric_definitions
for each row execute function public.set_platform_governance_updated_at();

drop trigger if exists trg_platform_sla_definitions_updated_at
  on public.platform_sla_definitions;
create trigger trg_platform_sla_definitions_updated_at
before update on public.platform_sla_definitions
for each row execute function public.set_platform_governance_updated_at();

drop trigger if exists trg_platform_telemetry_alerts_updated_at
  on public.platform_telemetry_alerts;
create trigger trg_platform_telemetry_alerts_updated_at
before update on public.platform_telemetry_alerts
for each row execute function public.set_platform_governance_updated_at();

create or replace function public.protect_platform_telemetry_immutable_row()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $function$
begin
  raise exception 'PLATFORM_TELEMETRY_IMMUTABLE_ROW: table=% operation=%', tg_table_name, tg_op
    using errcode = '55000';
end;
$function$;

drop trigger if exists trg_protect_platform_telemetry_snapshots
  on public.platform_telemetry_snapshots;
create trigger trg_protect_platform_telemetry_snapshots
before update or delete on public.platform_telemetry_snapshots
for each row execute function public.protect_platform_telemetry_immutable_row();

drop trigger if exists trg_protect_platform_telemetry_metric_samples
  on public.platform_telemetry_metric_samples;
create trigger trg_protect_platform_telemetry_metric_samples
before update or delete on public.platform_telemetry_metric_samples
for each row execute function public.protect_platform_telemetry_immutable_row();

drop trigger if exists trg_protect_platform_sla_evaluations
  on public.platform_sla_evaluations;
create trigger trg_protect_platform_sla_evaluations
before update or delete on public.platform_sla_evaluations
for each row execute function public.protect_platform_telemetry_immutable_row();

-- --------------------------------------------------------------------------
-- 8. Seed metric definitions
-- --------------------------------------------------------------------------

insert into public.platform_telemetry_metric_definitions (
  metric_code,metric_name,description,metric_group,unit,value_kind,
  target_direction,warning_threshold,critical_threshold,metadata
)
values
  ('queue.depth.total','Queue depth total','All non-terminal orchestrator actions.','queue','count','gauge','lower_is_better',10,25,'{"migration":83}'::jsonb),
  ('queue.depth.pending','Pending queue depth','Actions immediately eligible or waiting for dispatch.','queue','count','gauge','lower_is_better',8,20,'{"migration":83}'::jsonb),
  ('queue.depth.retry_wait','Retry queue depth','Actions waiting for their deterministic retry time.','queue','count','gauge','lower_is_better',5,15,'{"migration":83}'::jsonb),
  ('queue.oldest_age_seconds','Oldest actionable queue age','Age of the oldest pending or retry action currently eligible.','queue','seconds','duration','lower_is_better',120,300,'{"migration":83}'::jsonb),
  ('workers.total','Registered workers','Total workers known to the dispatcher.','workers','count','gauge','informational',null,null,'{"migration":83}'::jsonb),
  ('workers.online','Online workers','Workers online with a valid heartbeat lease.','workers','count','gauge','higher_is_better',1,0,'{"migration":83}'::jsonb),
  ('workers.stale','Stale workers','Workers whose heartbeat lease has expired while not offline.','workers','count','gauge','lower_is_better',1,2,'{"migration":83}'::jsonb),
  ('workers.reliability_percent','Worker reliability','Completed worker actions succeeding in the evaluation window.','workers','percent','rate','higher_is_better',95,85,'{"migration":83}'::jsonb),
  ('dispatcher.avg_dispatch_latency_ms','Average dispatch latency','Average time from action creation to dispatcher claim.','dispatcher','milliseconds','duration','lower_is_better',30000,120000,'{"migration":83}'::jsonb),
  ('execution.avg_duration_ms','Average execution duration','Average completed action execution duration.','execution','milliseconds','duration','lower_is_better',60000,180000,'{"migration":83}'::jsonb),
  ('execution.success_rate_percent','Execution success rate','Successful receipts divided by terminal receipts in the window.','execution','percent','rate','higher_is_better',95,85,'{"migration":83}'::jsonb),
  ('execution.retry_rate_percent','Execution retry rate','Retry-scheduled attempts divided by terminal attempts.','execution','percent','rate','lower_is_better',10,25,'{"migration":83}'::jsonb),
  ('execution.dead_letters.unresolved','Unresolved dead letters','Dead letters that still require operational resolution.','execution','count','gauge','lower_is_better',1,3,'{"migration":83}'::jsonb),
  ('reconciliation.avg_duration_ms','Average reconciliation duration','Average completed reconciliation cycle duration.','reconciliation','milliseconds','duration','lower_is_better',30000,90000,'{"migration":83}'::jsonb),
  ('reconciliation.failure_rate_percent','Reconciliation failure rate','Failed or abandoned cycles divided by terminal cycles.','reconciliation','percent','rate','lower_is_better',5,15,'{"migration":83}'::jsonb),
  ('platform.health_score','Platform health score','Composite certified health score from zero to one hundred.','platform','score','score','higher_is_better',85,70,'{"migration":83}'::jsonb)
on conflict (metric_code) do update
set metric_name = excluded.metric_name,
    description = excluded.description,
    metric_group = excluded.metric_group,
    unit = excluded.unit,
    value_kind = excluded.value_kind,
    target_direction = excluded.target_direction,
    warning_threshold = excluded.warning_threshold,
    critical_threshold = excluded.critical_threshold,
    enabled = true,
    owner_engine_code = 'platform_telemetry_engine',
    metadata = public.platform_telemetry_metric_definitions.metadata || excluded.metadata;

-- --------------------------------------------------------------------------
-- 9. Seed SLA definitions
-- --------------------------------------------------------------------------

insert into public.platform_sla_definitions (
  sla_code,sla_name,description,metric_code,comparison_operator,
  objective_threshold,warning_threshold,critical_threshold,
  evaluation_window_seconds,severity,metadata
)
values
  ('sla.queue.depth','Queue depth objective','Keep the active dispatcher queue below operational pressure thresholds.','queue.depth.total','lte',5,10,25,3600,'critical','{"migration":83}'::jsonb),
  ('sla.queue.oldest_age','Queue age objective','Dispatch eligible work before it becomes operationally stale.','queue.oldest_age_seconds','lte',60,120,300,3600,'critical','{"migration":83}'::jsonb),
  ('sla.workers.stale','Worker heartbeat objective','Keep stale runtime workers at zero.','workers.stale','lte',0,1,2,3600,'critical','{"migration":83}'::jsonb),
  ('sla.execution.success_rate','Execution success objective','Maintain a high certified runtime execution success rate.','execution.success_rate_percent','gte',99,95,85,3600,'critical','{"migration":83}'::jsonb),
  ('sla.execution.retry_rate','Execution retry objective','Keep retry scheduling within the expected operational envelope.','execution.retry_rate_percent','lte',5,10,25,3600,'warning','{"migration":83}'::jsonb),
  ('sla.execution.dead_letters','Dead-letter objective','Maintain zero unresolved dead letters.','execution.dead_letters.unresolved','lte',0,1,3,3600,'critical','{"migration":83}'::jsonb),
  ('sla.reconciliation.failure_rate','Reconciliation reliability objective','Keep failed or abandoned reconciliation cycles rare.','reconciliation.failure_rate_percent','lte',1,5,15,3600,'critical','{"migration":83}'::jsonb),
  ('sla.platform.health_score','Platform health objective','Maintain the composite platform health score in the healthy range.','platform.health_score','gte',95,85,70,3600,'critical','{"migration":83}'::jsonb)
on conflict (sla_code) do update
set sla_name = excluded.sla_name,
    description = excluded.description,
    metric_code = excluded.metric_code,
    comparison_operator = excluded.comparison_operator,
    objective_threshold = excluded.objective_threshold,
    warning_threshold = excluded.warning_threshold,
    critical_threshold = excluded.critical_threshold,
    evaluation_window_seconds = excluded.evaluation_window_seconds,
    severity = excluded.severity,
    enabled = true,
    owner_engine_code = 'platform_telemetry_engine',
    metadata = public.platform_sla_definitions.metadata || excluded.metadata;

-- --------------------------------------------------------------------------
-- 10. Deterministic health scoring helper
-- --------------------------------------------------------------------------

create or replace function public.calculate_platform_health_score(
  p_metrics jsonb
)
returns numeric
language plpgsql
immutable
security definer
set search_path = public, pg_temp
as $function$
declare
  v_score numeric := 100;
  v_queue numeric := coalesce((p_metrics ->> 'queue.depth.total')::numeric,0);
  v_oldest numeric := coalesce((p_metrics ->> 'queue.oldest_age_seconds')::numeric,0);
  v_stale numeric := coalesce((p_metrics ->> 'workers.stale')::numeric,0);
  v_success numeric := coalesce((p_metrics ->> 'execution.success_rate_percent')::numeric,100);
  v_retry numeric := coalesce((p_metrics ->> 'execution.retry_rate_percent')::numeric,0);
  v_dead numeric := coalesce((p_metrics ->> 'execution.dead_letters.unresolved')::numeric,0);
  v_recon_failure numeric := coalesce((p_metrics ->> 'reconciliation.failure_rate_percent')::numeric,0);
begin
  v_score := v_score - least(20, v_queue * 1.5);
  v_score := v_score - least(15, v_oldest / 30);
  v_score := v_score - least(20, v_stale * 10);
  v_score := v_score - least(20, greatest(0, 100 - v_success));
  v_score := v_score - least(10, v_retry / 2);
  v_score := v_score - least(10, v_dead * 5);
  v_score := v_score - least(5, v_recon_failure / 3);
  return round(greatest(0, least(100, v_score)),2);
end;
$function$;

-- --------------------------------------------------------------------------
-- 11. Certified snapshot collection, SLA evaluation and alert reconciliation
-- --------------------------------------------------------------------------

create or replace function public.collect_platform_telemetry_snapshot_rpc(
  p_source text default 'manual',
  p_correlation_id uuid default gen_random_uuid(),
  p_window_seconds integer default 3600
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
  v_window_start timestamptz;
  v_snapshot_id uuid;
  v_metrics jsonb;
  v_kpis jsonb;
  v_health_score numeric;
  v_health_status text;
  v_terminal_receipts numeric;
  v_success_receipts numeric;
  v_terminal_attempts numeric;
  v_retry_attempts numeric;
  v_terminal_cycles numeric;
  v_failed_cycles numeric;
  v_alerts_opened integer := 0;
  v_alerts_resolved integer := 0;
  r record;
  v_observed numeric;
  v_eval_status text;
  v_severity text;
  v_threshold numeric;
  v_alert_key text;
begin
  if p_source not in ('scheduled','manual','startup','recovery','maintenance','test') then
    raise exception 'PLATFORM_TELEMETRY_INVALID_SOURCE: %', p_source using errcode = '22023';
  end if;
  if p_window_seconds < 60 or p_window_seconds > 2592000 then
    raise exception 'PLATFORM_TELEMETRY_INVALID_WINDOW_SECONDS: %', p_window_seconds using errcode = '22023';
  end if;

  v_window_start := v_now - make_interval(secs => p_window_seconds);

  select count(*)::numeric,
         count(*) filter (where receipt_status = 'succeeded')::numeric
    into v_terminal_receipts, v_success_receipts
  from public.platform_action_execution_receipts
  where completed_at >= v_window_start and completed_at <= v_now;

  select count(*) filter (where attempt_status in ('succeeded','retry_scheduled','failed','cancelled','expired','dead_lettered'))::numeric,
         count(*) filter (where attempt_status = 'retry_scheduled')::numeric
    into v_terminal_attempts, v_retry_attempts
  from public.platform_action_execution_attempts
  where coalesce(completed_at,claimed_at) >= v_window_start
    and coalesce(completed_at,claimed_at) <= v_now;

  select count(*) filter (where cycle_status <> 'running')::numeric,
         count(*) filter (where cycle_status in ('failed','abandoned'))::numeric
    into v_terminal_cycles, v_failed_cycles
  from public.platform_orchestrator_cycles
  where started_at >= v_window_start and started_at <= v_now;

  v_metrics := jsonb_build_object(
    'queue.depth.total', (select count(*) from public.platform_orchestrator_actions where action_status in ('pending','claimed','running','retry_wait')),
    'queue.depth.pending', (select count(*) from public.platform_orchestrator_actions where action_status = 'pending'),
    'queue.depth.retry_wait', (select count(*) from public.platform_orchestrator_actions where action_status = 'retry_wait'),
    'queue.oldest_age_seconds', coalesce((select extract(epoch from (v_now - min(created_at))) from public.platform_orchestrator_actions where action_status in ('pending','retry_wait') and available_at <= v_now),0),
    'workers.total', (select count(*) from public.platform_runtime_workers),
    'workers.online', (select count(*) from public.platform_runtime_workers where worker_status = 'online' and lease_expires_at >= v_now),
    'workers.stale', (select count(*) from public.platform_runtime_workers where worker_status <> 'offline' and lease_expires_at < v_now),
    'workers.reliability_percent', case when v_terminal_receipts = 0 then 100 else round((v_success_receipts * 100.0) / v_terminal_receipts,2) end,
    'dispatcher.avg_dispatch_latency_ms', coalesce((select round(avg(extract(epoch from (a.claimed_at - q.created_at)) * 1000)::numeric,2) from public.platform_action_execution_attempts a join public.platform_orchestrator_actions q on q.action_id = a.action_id where a.claimed_at >= v_window_start and a.claimed_at <= v_now),0),
    'execution.avg_duration_ms', coalesce((select round(avg(duration_ms)::numeric,2) from public.platform_action_execution_receipts where completed_at >= v_window_start and completed_at <= v_now),0),
    'execution.success_rate_percent', case when v_terminal_receipts = 0 then 100 else round((v_success_receipts * 100.0) / v_terminal_receipts,2) end,
    'execution.retry_rate_percent', case when v_terminal_attempts = 0 then 0 else round((v_retry_attempts * 100.0) / v_terminal_attempts,2) end,
    'execution.dead_letters.unresolved', (select count(*) from public.platform_orchestrator_dead_letters where resolution_status <> 'resolved'),
    'reconciliation.avg_duration_ms', coalesce((select round(avg(extract(epoch from (completed_at - started_at)) * 1000)::numeric,2) from public.platform_orchestrator_cycles where completed_at is not null and started_at >= v_window_start and started_at <= v_now),0),
    'reconciliation.failure_rate_percent', case when v_terminal_cycles = 0 then 0 else round((v_failed_cycles * 100.0) / v_terminal_cycles,2) end
  );

  v_health_score := public.calculate_platform_health_score(v_metrics);
  v_metrics := v_metrics || jsonb_build_object('platform.health_score',v_health_score);
  v_health_status := case when v_health_score >= 85 then 'healthy' when v_health_score >= 70 then 'degraded' else 'critical' end;

  v_kpis := jsonb_build_object(
    'contract_version','platform-telemetry-kpis-v1',
    'platform_health_score',v_health_score,
    'runtime_availability_percent',case when (v_metrics ->> 'workers.total')::numeric = 0 then 100 else round(((v_metrics ->> 'workers.online')::numeric * 100.0) / greatest(1,(v_metrics ->> 'workers.total')::numeric),2) end,
    'worker_reliability_percent',(v_metrics ->> 'workers.reliability_percent')::numeric,
    'queue_pressure_score',round(greatest(0,100 - least(100,(v_metrics ->> 'queue.depth.total')::numeric * 4)),2),
    'execution_success_percent',(v_metrics ->> 'execution.success_rate_percent')::numeric,
    'reconciliation_reliability_percent',round(greatest(0,100 - (v_metrics ->> 'reconciliation.failure_rate_percent')::numeric),2)
  );

  insert into public.platform_telemetry_snapshots (
    source,correlation_id,collection_started_at,collected_at,collection_duration_ms,
    window_started_at,window_ended_at,metrics,kpis,platform_health_score,
    health_status,collector_version,metadata
  ) values (
    p_source,p_correlation_id,v_started_at,v_now,
    greatest(0,round(extract(epoch from (clock_timestamp() - v_started_at)) * 1000)::bigint),
    v_window_start,v_now,v_metrics,v_kpis,v_health_score,v_health_status,'1.0.0',
    jsonb_build_object('window_seconds',p_window_seconds,'migration',83)
  ) returning telemetry_snapshot_id into v_snapshot_id;

  insert into public.platform_telemetry_metric_samples (
    telemetry_snapshot_id,metric_code,metric_value,measured_at,metadata
  )
  select v_snapshot_id,d.metric_code,(v_metrics ->> d.metric_code)::numeric,v_now,'{"collector":"platform-telemetry-v1"}'::jsonb
  from public.platform_telemetry_metric_definitions d
  where d.enabled and v_metrics ? d.metric_code;

  for r in
    select s.* from public.platform_sla_definitions s where s.enabled order by s.sla_code
  loop
    v_observed := (v_metrics ->> r.metric_code)::numeric;
    if v_observed is null then
      v_eval_status := 'not_applicable'; v_severity := null; v_threshold := r.objective_threshold;
    elsif r.comparison_operator = 'lte' then
      if v_observed <= r.objective_threshold then
        v_eval_status := 'met'; v_severity := null; v_threshold := r.objective_threshold;
      elsif r.warning_threshold is not null and v_observed < r.critical_threshold then
        v_eval_status := 'warning'; v_severity := 'warning'; v_threshold := r.warning_threshold;
      else
        v_eval_status := 'breached'; v_severity := r.severity; v_threshold := r.critical_threshold;
      end if;
    else
      if v_observed >= r.objective_threshold then
        v_eval_status := 'met'; v_severity := null; v_threshold := r.objective_threshold;
      elsif r.warning_threshold is not null and v_observed > r.critical_threshold then
        v_eval_status := 'warning'; v_severity := 'warning'; v_threshold := r.warning_threshold;
      else
        v_eval_status := 'breached'; v_severity := r.severity; v_threshold := r.critical_threshold;
      end if;
    end if;

    insert into public.platform_sla_evaluations (
      telemetry_snapshot_id,sla_code,metric_code,observed_value,objective_threshold,
      evaluation_status,breach_severity,evaluated_at,details
    ) values (
      v_snapshot_id,r.sla_code,r.metric_code,coalesce(v_observed,0),r.objective_threshold,
      v_eval_status,v_severity,v_now,
      jsonb_build_object('comparison_operator',r.comparison_operator,'warning_threshold',r.warning_threshold,'critical_threshold',r.critical_threshold)
    );

    v_alert_key := 'sla:' || r.sla_code;
    if v_eval_status in ('warning','breached') then
      insert into public.platform_telemetry_alerts (
        alert_key,alert_type,alert_status,severity,title,message,metric_code,sla_code,
        source_snapshot_id,current_value,threshold_value,context
      ) values (
        v_alert_key,'sla_breach','open',coalesce(v_severity,'warning'),r.sla_name,
        format('SLA %s observed %s against objective %s.',r.sla_code,v_observed,r.objective_threshold),
        r.metric_code,r.sla_code,v_snapshot_id,v_observed,v_threshold,
        jsonb_build_object('evaluation_status',v_eval_status,'comparison_operator',r.comparison_operator)
      )
      on conflict (alert_key) where alert_status in ('open','acknowledged') do update
      set severity = excluded.severity,
          message = excluded.message,
          source_snapshot_id = excluded.source_snapshot_id,
          current_value = excluded.current_value,
          threshold_value = excluded.threshold_value,
          occurrence_count = public.platform_telemetry_alerts.occurrence_count + 1,
          last_detected_at = now(),
          context = public.platform_telemetry_alerts.context || excluded.context;
      v_alerts_opened := v_alerts_opened + 1;
    else
      update public.platform_telemetry_alerts
      set alert_status = 'resolved',resolved_at = v_now,
          resolution_note = 'Automatically resolved by a compliant telemetry snapshot.',
          source_snapshot_id = v_snapshot_id,last_detected_at = v_now
      where alert_key = v_alert_key and alert_status in ('open','acknowledged');
      if found then v_alerts_resolved := v_alerts_resolved + 1; end if;
    end if;
  end loop;

  return jsonb_build_object(
    'contract_version','platform-telemetry-collection-v1',
    'telemetry_snapshot_id',v_snapshot_id,
    'collected_at',v_now,
    'window_seconds',p_window_seconds,
    'health_status',v_health_status,
    'platform_health_score',v_health_score,
    'metric_count',(select count(*) from public.platform_telemetry_metric_definitions d where d.enabled and v_metrics ? d.metric_code),
    'alerts_evaluated',v_alerts_opened,
    'alerts_resolved',v_alerts_resolved,
    'metrics',v_metrics,
    'kpis',v_kpis
  );
end;
$function$;

-- --------------------------------------------------------------------------
-- 12. Alert lifecycle commands
-- --------------------------------------------------------------------------

create or replace function public.acknowledge_platform_telemetry_alert_rpc(
  p_telemetry_alert_id uuid,
  p_acknowledged_by text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $function$
declare v_alert public.platform_telemetry_alerts%rowtype;
begin
  if nullif(btrim(p_acknowledged_by),'') is null then
    raise exception 'PLATFORM_TELEMETRY_ACKNOWLEDGED_BY_REQUIRED' using errcode = '22023';
  end if;
  update public.platform_telemetry_alerts
  set alert_status = 'acknowledged',acknowledged_at = now(),acknowledged_by = btrim(p_acknowledged_by)
  where telemetry_alert_id = p_telemetry_alert_id and alert_status = 'open'
  returning * into v_alert;
  if not found then raise exception 'PLATFORM_TELEMETRY_ALERT_NOT_OPEN: %',p_telemetry_alert_id using errcode='P0002'; end if;
  return to_jsonb(v_alert) || jsonb_build_object('contract_version','platform-telemetry-alert-v1');
end;
$function$;

create or replace function public.resolve_platform_telemetry_alert_rpc(
  p_telemetry_alert_id uuid,
  p_resolution_note text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $function$
declare v_alert public.platform_telemetry_alerts%rowtype;
begin
  if nullif(btrim(p_resolution_note),'') is null then
    raise exception 'PLATFORM_TELEMETRY_RESOLUTION_NOTE_REQUIRED' using errcode = '22023';
  end if;
  update public.platform_telemetry_alerts
  set alert_status = 'resolved',resolved_at = now(),resolution_note = btrim(p_resolution_note)
  where telemetry_alert_id = p_telemetry_alert_id and alert_status in ('open','acknowledged')
  returning * into v_alert;
  if not found then raise exception 'PLATFORM_TELEMETRY_ALERT_NOT_ACTIVE: %',p_telemetry_alert_id using errcode='P0002'; end if;
  return to_jsonb(v_alert) || jsonb_build_object('contract_version','platform-telemetry-alert-v1');
end;
$function$;

-- --------------------------------------------------------------------------
-- 13. Read models
-- --------------------------------------------------------------------------

create or replace function public.get_platform_telemetry_latest_snapshot_rpc()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $function$
  select coalesce(
    (select to_jsonb(s) || jsonb_build_object('contract_version','platform-telemetry-snapshot-v1')
     from public.platform_telemetry_snapshots s order by collected_at desc limit 1),
    jsonb_build_object('contract_version','platform-telemetry-snapshot-v1','status','not_collected')
  );
$function$;

create or replace function public.get_platform_telemetry_metric_series_rpc(
  p_metric_code text,
  p_from timestamptz default now() - interval '24 hours',
  p_to timestamptz default now(),
  p_limit integer default 1000
)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $function$
  select coalesce(jsonb_agg(to_jsonb(x) order by x.measured_at),'[]'::jsonb)
  from (
    select metric_sample_id,telemetry_snapshot_id,metric_code,metric_value,measured_at,dimensions,metadata
    from public.platform_telemetry_metric_samples
    where metric_code = p_metric_code and measured_at >= p_from and measured_at <= p_to
    order by measured_at desc limit greatest(1,least(coalesce(p_limit,1000),10000))
  ) x;
$function$;

create or replace function public.get_platform_telemetry_alerts_rpc(
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
  select coalesce(jsonb_agg(to_jsonb(x) order by x.last_detected_at desc),'[]'::jsonb)
  from (
    select * from public.platform_telemetry_alerts
    where (p_status is null or alert_status = p_status)
      and (p_severity is null or severity = p_severity)
    order by last_detected_at desc limit greatest(1,least(coalesce(p_limit,100),1000))
  ) x;
$function$;

create or replace function public.get_platform_sla_status_rpc(
  p_limit integer default 100
)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $function$
  with latest as (
    select distinct on (e.sla_code) e.*
    from public.platform_sla_evaluations e
    order by e.sla_code,e.evaluated_at desc
  )
  select coalesce(jsonb_agg(to_jsonb(x) order by x.sla_code),'[]'::jsonb)
  from (
    select d.sla_code,d.sla_name,d.metric_code,d.comparison_operator,d.objective_threshold,
           d.warning_threshold,d.critical_threshold,d.enabled,
           l.observed_value,l.evaluation_status,l.breach_severity,l.evaluated_at,l.telemetry_snapshot_id
    from public.platform_sla_definitions d left join latest l using (sla_code)
    order by d.sla_code limit greatest(1,least(coalesce(p_limit,100),1000))
  ) x;
$function$;

create or replace function public.get_platform_telemetry_health_rpc()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $function$
  select jsonb_build_object(
    'contract_version','platform-telemetry-health-v1',
    'generated_at',now(),
    'latest_snapshot',public.get_platform_telemetry_latest_snapshot_rpc(),
    'active_alerts',jsonb_build_object(
      'total',(select count(*) from public.platform_telemetry_alerts where alert_status in ('open','acknowledged')),
      'critical',(select count(*) from public.platform_telemetry_alerts where alert_status in ('open','acknowledged') and severity='critical'),
      'warning',(select count(*) from public.platform_telemetry_alerts where alert_status in ('open','acknowledged') and severity='warning')
    ),
    'sla',jsonb_build_object(
      'enabled',(select count(*) from public.platform_sla_definitions where enabled),
      'latest_breached',(select count(*) from (select distinct on (sla_code) sla_code,evaluation_status from public.platform_sla_evaluations order by sla_code,evaluated_at desc) z where evaluation_status='breached'),
      'latest_warning',(select count(*) from (select distinct on (sla_code) sla_code,evaluation_status from public.platform_sla_evaluations order by sla_code,evaluated_at desc) z where evaluation_status='warning')
    ),
    'retention',jsonb_build_object(
      'snapshot_count',(select count(*) from public.platform_telemetry_snapshots),
      'sample_count',(select count(*) from public.platform_telemetry_metric_samples),
      'evaluation_count',(select count(*) from public.platform_sla_evaluations)
    )
  );
$function$;

-- --------------------------------------------------------------------------
-- 14. RLS and grants
-- --------------------------------------------------------------------------

alter table public.platform_telemetry_metric_definitions enable row level security;
alter table public.platform_telemetry_snapshots enable row level security;
alter table public.platform_telemetry_metric_samples enable row level security;
alter table public.platform_sla_definitions enable row level security;
alter table public.platform_sla_evaluations enable row level security;
alter table public.platform_telemetry_alerts enable row level security;

revoke all on table public.platform_telemetry_metric_definitions from public,anon,authenticated;
revoke all on table public.platform_telemetry_snapshots from public,anon,authenticated;
revoke all on table public.platform_telemetry_metric_samples from public,anon,authenticated;
revoke all on table public.platform_sla_definitions from public,anon,authenticated;
revoke all on table public.platform_sla_evaluations from public,anon,authenticated;
revoke all on table public.platform_telemetry_alerts from public,anon,authenticated;

grant select,insert,update,truncate,references,trigger on table public.platform_telemetry_metric_definitions to service_role;
grant select,insert,truncate,references,trigger on table public.platform_telemetry_snapshots to service_role;
grant select,insert,truncate,references,trigger on table public.platform_telemetry_metric_samples to service_role;
grant select,insert,update,truncate,references,trigger on table public.platform_sla_definitions to service_role;
grant select,insert,truncate,references,trigger on table public.platform_sla_evaluations to service_role;
grant select,insert,update,truncate,references,trigger on table public.platform_telemetry_alerts to service_role;

drop policy if exists platform_telemetry_metric_definitions_service_all on public.platform_telemetry_metric_definitions;
create policy platform_telemetry_metric_definitions_service_all on public.platform_telemetry_metric_definitions for all to service_role using (true) with check (true);
drop policy if exists platform_telemetry_snapshots_service_all on public.platform_telemetry_snapshots;
create policy platform_telemetry_snapshots_service_all on public.platform_telemetry_snapshots for all to service_role using (true) with check (true);
drop policy if exists platform_telemetry_metric_samples_service_all on public.platform_telemetry_metric_samples;
create policy platform_telemetry_metric_samples_service_all on public.platform_telemetry_metric_samples for all to service_role using (true) with check (true);
drop policy if exists platform_sla_definitions_service_all on public.platform_sla_definitions;
create policy platform_sla_definitions_service_all on public.platform_sla_definitions for all to service_role using (true) with check (true);
drop policy if exists platform_sla_evaluations_service_all on public.platform_sla_evaluations;
create policy platform_sla_evaluations_service_all on public.platform_sla_evaluations for all to service_role using (true) with check (true);
drop policy if exists platform_telemetry_alerts_service_all on public.platform_telemetry_alerts;
create policy platform_telemetry_alerts_service_all on public.platform_telemetry_alerts for all to service_role using (true) with check (true);

revoke all on function public.calculate_platform_health_score(jsonb) from public,anon;
revoke all on function public.collect_platform_telemetry_snapshot_rpc(text,uuid,integer) from public,anon,authenticated;
revoke all on function public.acknowledge_platform_telemetry_alert_rpc(uuid,text) from public,anon,authenticated;
revoke all on function public.resolve_platform_telemetry_alert_rpc(uuid,text) from public,anon,authenticated;
revoke all on function public.get_platform_telemetry_latest_snapshot_rpc() from public,anon;
revoke all on function public.get_platform_telemetry_metric_series_rpc(text,timestamptz,timestamptz,integer) from public,anon;
revoke all on function public.get_platform_telemetry_alerts_rpc(text,text,integer) from public,anon;
revoke all on function public.get_platform_sla_status_rpc(integer) from public,anon;
revoke all on function public.get_platform_telemetry_health_rpc() from public,anon;

grant execute on function public.calculate_platform_health_score(jsonb) to authenticated,service_role;
grant execute on function public.collect_platform_telemetry_snapshot_rpc(text,uuid,integer) to service_role;
grant execute on function public.acknowledge_platform_telemetry_alert_rpc(uuid,text) to service_role;
grant execute on function public.resolve_platform_telemetry_alert_rpc(uuid,text) to service_role;
grant execute on function public.get_platform_telemetry_latest_snapshot_rpc() to authenticated,service_role;
grant execute on function public.get_platform_telemetry_metric_series_rpc(text,timestamptz,timestamptz,integer) to authenticated,service_role;
grant execute on function public.get_platform_telemetry_alerts_rpc(text,text,integer) to authenticated,service_role;
grant execute on function public.get_platform_sla_status_rpc(integer) to authenticated,service_role;
grant execute on function public.get_platform_telemetry_health_rpc() to authenticated,service_role;

-- --------------------------------------------------------------------------
-- 15. Policies, feature flag and governance v1.4
-- --------------------------------------------------------------------------

insert into public.platform_runtime_policies (
  policy_key,policy_name,description,policy_type,policy_value,
  validation_contract,owner_engine_code,enforcement_level,enabled,metadata
)
values
  ('runtime.telemetry.collection_interval','Telemetry collection interval','Recommended cadence for certified platform telemetry snapshots.','duration','"PT1M"'::jsonb,'{"format":"ISO-8601-duration"}'::jsonb,'platform_telemetry_engine','required',true,'{"migration":83}'::jsonb),
  ('runtime.telemetry.evaluation_window','Telemetry evaluation window','Default lookback used for rate and latency measurements.','duration','"PT1H"'::jsonb,'{"format":"ISO-8601-duration"}'::jsonb,'platform_telemetry_engine','required',true,'{"migration":83}'::jsonb),
  ('runtime.telemetry.snapshot_retention','Telemetry snapshot retention','Recommended retention horizon for immutable telemetry snapshots.','duration','"P90D"'::jsonb,'{"format":"ISO-8601-duration"}'::jsonb,'platform_telemetry_engine','advisory',true,'{"migration":83}'::jsonb),
  ('runtime.telemetry.alert_deduplication','Telemetry alert deduplication','Keep one active alert per stable alert key while counting repeated occurrences.','boolean','true'::jsonb,'{}'::jsonb,'platform_telemetry_engine','critical',true,'{"migration":83}'::jsonb)
on conflict (policy_key) do update
set policy_value=excluded.policy_value,validation_contract=excluded.validation_contract,
    owner_engine_code=excluded.owner_engine_code,enforcement_level=excluded.enforcement_level,
    enabled=excluded.enabled,metadata=public.platform_runtime_policies.metadata || excluded.metadata;

insert into public.platform_feature_flags (
  feature_key,feature_name,description,enabled,rollout_percentage,audience,
  environment_scope,owner_engine_code,metadata
)
values (
  'runtime.platform_telemetry','Platform telemetry and SLA monitoring',
  'Expose certified platform metrics, KPI snapshots, SLA evaluations and durable alerts.',
  true,100,'service',array['development','preview','staging','production','test']::text[],
  'platform_telemetry_engine','{"contract":"platform-telemetry-v1","migration":83}'::jsonb
)
on conflict (feature_key) do update
set feature_name=excluded.feature_name,description=excluded.description,enabled=excluded.enabled,
    rollout_percentage=excluded.rollout_percentage,audience=excluded.audience,
    environment_scope=excluded.environment_scope,owner_engine_code=excluded.owner_engine_code,
    metadata=public.platform_feature_flags.metadata || excluded.metadata,updated_at=now();

create or replace function public.get_platform_governance_snapshot_rpc()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $function$
  select jsonb_build_object(
    'contract_version','platform-governance-v1.4',
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
    'feature_flags',public.get_platform_feature_flags_rpc(null,false),
    'runtime_policies',public.get_platform_runtime_policies_rpc(null,false),
    'capabilities',public.get_platform_capabilities_rpc(null,false)
  );
$function$;

revoke all on function public.get_platform_governance_snapshot_rpc() from public,anon;
grant execute on function public.get_platform_governance_snapshot_rpc() to authenticated,service_role;

update public.platform_configuration
set schema_version = greatest(schema_version,83),
    metadata = metadata || jsonb_build_object(
      'phase','8.4.1',
      'governance_contract','platform-governance-v1.4',
      'platform_telemetry_contract','platform-telemetry-v1',
      'platform_telemetry_migration',83
    ),
    updated_at = now()
where configuration_key='primary';

-- --------------------------------------------------------------------------
-- 16. Migration assertions (read-only; no synthetic telemetry persisted)
-- --------------------------------------------------------------------------

do $assertions$
declare
  v_missing integer;
  v_health jsonb;
  v_snapshot jsonb;
  v_score numeric;
begin
  select count(*) into v_missing
  from (values
    ('platform_telemetry_metric_definitions'),
    ('platform_telemetry_snapshots'),
    ('platform_telemetry_metric_samples'),
    ('platform_sla_definitions'),
    ('platform_sla_evaluations'),
    ('platform_telemetry_alerts')
  ) required_table(name)
  where to_regclass('public.' || name) is null;
  if v_missing <> 0 then raise exception 'PLATFORM_TELEMETRY_ASSERTION_FAILED: missing tables %',v_missing; end if;

  select count(*) into v_missing
  from (values
    ('calculate_platform_health_score'),
    ('collect_platform_telemetry_snapshot_rpc'),
    ('acknowledge_platform_telemetry_alert_rpc'),
    ('resolve_platform_telemetry_alert_rpc'),
    ('get_platform_telemetry_latest_snapshot_rpc'),
    ('get_platform_telemetry_metric_series_rpc'),
    ('get_platform_telemetry_alerts_rpc'),
    ('get_platform_sla_status_rpc'),
    ('get_platform_telemetry_health_rpc')
  ) required_function(name)
  where not exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname=required_function.name);
  if v_missing <> 0 then raise exception 'PLATFORM_TELEMETRY_ASSERTION_FAILED: missing functions %',v_missing; end if;

  if (select count(*) from public.platform_telemetry_metric_definitions where enabled) < 16 then
    raise exception 'PLATFORM_TELEMETRY_ASSERTION_FAILED: metric catalogue incomplete';
  end if;
  if (select count(*) from public.platform_sla_definitions where enabled) < 8 then
    raise exception 'PLATFORM_TELEMETRY_ASSERTION_FAILED: SLA catalogue incomplete';
  end if;

  v_score := public.calculate_platform_health_score('{"queue.depth.total":0,"queue.oldest_age_seconds":0,"workers.stale":0,"execution.success_rate_percent":100,"execution.retry_rate_percent":0,"execution.dead_letters.unresolved":0,"reconciliation.failure_rate_percent":0}'::jsonb);
  if v_score <> 100 then raise exception 'PLATFORM_TELEMETRY_ASSERTION_FAILED: health score baseline invalid %',v_score; end if;

  v_health := public.get_platform_telemetry_health_rpc();
  if (v_health ->> 'contract_version') <> 'platform-telemetry-health-v1'
     or not (v_health ? 'latest_snapshot') or not (v_health ? 'active_alerts') or not (v_health ? 'sla') then
    raise exception 'PLATFORM_TELEMETRY_ASSERTION_FAILED: telemetry health contract invalid';
  end if;

  v_snapshot := public.get_platform_governance_snapshot_rpc();
  if (v_snapshot ->> 'contract_version') <> 'platform-governance-v1.4'
     or not (v_snapshot ? 'telemetry_health') or not (v_snapshot ? 'telemetry_latest_snapshot')
     or not (v_snapshot ? 'telemetry_alerts') or not (v_snapshot ? 'sla_status') then
    raise exception 'PLATFORM_TELEMETRY_ASSERTION_FAILED: governance snapshot invalid';
  end if;

  if not exists (
    select 1 from public.platform_engine_registry
    where engine_code='platform_telemetry_engine' and engine_version='1.0.0'
      and certification_version='1.0.0' and runtime_enabled and is_certified
  ) then raise exception 'PLATFORM_TELEMETRY_ASSERTION_FAILED: engine certification invalid'; end if;
end;
$assertions$;

commit;

