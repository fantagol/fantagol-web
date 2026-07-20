-- ============================================================================
-- FantaGol
-- Migration 071: Health Monitoring Engine
-- Milestone 7.4.4
--
-- Purpose
--   Introduce a non-destructive health monitoring layer above the runtime
--   reconciliation engine. Health runs summarize reconciliation availability,
--   stale or failed scans, unacknowledged findings and safety invariants.
--
-- Safety contract
--   * Monitoring is disabled by default.
--   * The engine only records observations and incidents.
--   * No runtime, workflow, recovery, maintenance or retention record is changed.
--   * No automated remediation or command execution exists in this migration.
--   * All mutation RPCs are restricted to service_role.
-- ============================================================================

begin;

create extension if not exists pgcrypto with schema extensions;

-- --------------------------------------------------------------------------
-- Health monitor profile registry
-- --------------------------------------------------------------------------

create table if not exists public.health_monitor_profiles (
  id uuid primary key default extensions.gen_random_uuid(),
  profile_key text not null,
  profile_version integer not null default 1,
  display_name text not null,
  description text,
  enabled boolean not null default false,
  automatic_remediation_enabled boolean not null default false,
  reconciliation_profile_key text not null default 'runtime-core',
  lookback_interval interval not null default interval '24 hours',
  stale_requested_interval interval not null default interval '15 minutes',
  stale_running_interval interval not null default interval '30 minutes',
  maximum_observations integer not null default 1000,
  check_config jsonb not null default '{}'::jsonb,
  created_by uuid,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  retired_at timestamptz,
  constraint health_monitor_profiles_key_not_blank
    check (btrim(profile_key) <> ''),
  constraint health_monitor_profiles_display_not_blank
    check (btrim(display_name) <> ''),
  constraint health_monitor_profiles_reconciliation_key_not_blank
    check (btrim(reconciliation_profile_key) <> ''),
  constraint health_monitor_profiles_version_positive
    check (profile_version > 0),
  constraint health_monitor_profiles_intervals_positive
    check (
      lookback_interval > interval '0 seconds'
      and stale_requested_interval > interval '0 seconds'
      and stale_running_interval > interval '0 seconds'
    ),
  constraint health_monitor_profiles_maximum_positive
    check (maximum_observations > 0 and maximum_observations <= 10000),
  constraint health_monitor_profiles_config_object
    check (jsonb_typeof(check_config) = 'object'),
  constraint health_monitor_profiles_incident_guard
    check (automatic_remediation_enabled = false),
  constraint health_monitor_profiles_unique_version
    unique (profile_key, profile_version)
);

create unique index if not exists health_monitor_profiles_active_uidx
  on public.health_monitor_profiles (profile_key)
  where retired_at is null;

create index if not exists health_monitor_profiles_enabled_idx
  on public.health_monitor_profiles (enabled, profile_key)
  where retired_at is null;

create trigger trg_health_monitor_profiles_updated_at
before update on public.health_monitor_profiles
for each row
execute function public.set_maintenance_updated_at();

comment on table public.health_monitor_profiles
is 'Versioned, disabled-by-default health monitoring profiles. Automatic remediation is structurally disabled.';

-- --------------------------------------------------------------------------
-- Health monitor runs
-- --------------------------------------------------------------------------

create table if not exists public.health_monitor_runs (
  id uuid primary key default extensions.gen_random_uuid(),
  profile_id uuid not null
    references public.health_monitor_profiles(id) on delete restrict,
  profile_key text not null,
  profile_version integer not null,
  status text not null default 'requested',
  idempotency_key text not null,
  requested_by uuid,
  requested_at timestamptz not null default clock_timestamp(),
  started_at timestamptz,
  completed_at timestamptz,
  observation_cutoff_at timestamptz not null default clock_timestamp(),
  monitor_version text not null default 'health-monitor-v1',
  overall_status text,
  health_score integer,
  observation_count integer not null default 0,
  critical_count integer not null default 0,
  high_count integer not null default 0,
  medium_count integer not null default 0,
  low_count integer not null default 0,
  info_count integer not null default 0,
  incident_count integer not null default 0,
  truncated boolean not null default false,
  run_hash text,
  request_payload jsonb not null default '{}'::jsonb,
  monitor_snapshot jsonb,
  error_code text,
  error_message text,
  error_details jsonb,
  correlation_id uuid not null default extensions.gen_random_uuid(),
  causation_id uuid,
  created_at timestamptz not null default clock_timestamp(),
  constraint health_monitor_runs_status
    check (status in ('requested', 'running', 'completed', 'failed', 'cancelled')),
  constraint health_monitor_runs_overall_status
    check (overall_status is null or overall_status in ('healthy', 'degraded', 'unhealthy', 'critical')),
  constraint health_monitor_runs_score_range
    check (health_score is null or health_score between 0 and 100),
  constraint health_monitor_runs_idempotency_not_blank
    check (btrim(idempotency_key) <> ''),
  constraint health_monitor_runs_profile_not_blank
    check (btrim(profile_key) <> '' and profile_version > 0),
  constraint health_monitor_runs_version_not_blank
    check (btrim(monitor_version) <> ''),
  constraint health_monitor_runs_counts_nonnegative
    check (
      observation_count >= 0 and critical_count >= 0 and high_count >= 0
      and medium_count >= 0 and low_count >= 0 and info_count >= 0
      and incident_count >= 0
    ),
  constraint health_monitor_runs_request_object
    check (jsonb_typeof(request_payload) = 'object'),
  constraint health_monitor_runs_snapshot_object
    check (monitor_snapshot is null or jsonb_typeof(monitor_snapshot) = 'object'),
  constraint health_monitor_runs_error_object
    check (error_details is null or jsonb_typeof(error_details) = 'object'),
  constraint health_monitor_runs_terminal_time
    check (status not in ('completed', 'failed', 'cancelled') or completed_at is not null),
  constraint health_monitor_runs_complete_contract
    check (
      status <> 'completed'
      or (run_hash is not null and overall_status is not null and health_score is not null)
    ),
  constraint health_monitor_runs_idempotency_unique
    unique (idempotency_key)
);

create index if not exists health_monitor_runs_status_idx
  on public.health_monitor_runs (status, requested_at desc);

create index if not exists health_monitor_runs_profile_idx
  on public.health_monitor_runs (profile_key, requested_at desc);

create index if not exists health_monitor_runs_overall_idx
  on public.health_monitor_runs (overall_status, completed_at desc)
  where status = 'completed';

comment on table public.health_monitor_runs
is 'Immutable-after-terminal health monitoring run header and aggregate health score.';

-- --------------------------------------------------------------------------
-- Immutable observations
-- --------------------------------------------------------------------------

create table if not exists public.health_monitor_observations (
  id uuid primary key default extensions.gen_random_uuid(),
  health_monitor_run_id uuid not null
    references public.health_monitor_runs(id) on delete cascade,
  observation_key text not null,
  check_type text not null,
  severity text not null,
  component text not null,
  source_table text,
  source_record_id uuid,
  observed_status text,
  expected_status text,
  observed_value numeric,
  threshold_value numeric,
  reference_at timestamptz,
  observed_at timestamptz not null default clock_timestamp(),
  evidence jsonb not null default '{}'::jsonb,
  observation_hash text not null,
  created_at timestamptz not null default clock_timestamp(),
  constraint health_monitor_observations_key_not_blank
    check (btrim(observation_key) <> ''),
  constraint health_monitor_observations_type_not_blank
    check (btrim(check_type) <> ''),
  constraint health_monitor_observations_severity
    check (severity in ('critical', 'high', 'medium', 'low', 'info')),
  constraint health_monitor_observations_component_not_blank
    check (btrim(component) <> ''),
  constraint health_monitor_observations_evidence_object
    check (jsonb_typeof(evidence) = 'object'),
  constraint health_monitor_observations_hash_not_blank
    check (btrim(observation_hash) <> ''),
  constraint health_monitor_observations_unique_key
    unique (health_monitor_run_id, observation_key),
  constraint health_monitor_observations_unique_hash
    unique (health_monitor_run_id, observation_hash)
);

create index if not exists health_monitor_observations_run_idx
  on public.health_monitor_observations
    (health_monitor_run_id, severity, observed_at desc);

create index if not exists health_monitor_observations_component_idx
  on public.health_monitor_observations
    (component, check_type, observed_at desc);

comment on table public.health_monitor_observations
is 'Append-only evidence ledger generated by a health monitor run.';

-- --------------------------------------------------------------------------
-- Incident ledger
-- --------------------------------------------------------------------------

create table if not exists public.health_monitor_incidents (
  id uuid primary key default extensions.gen_random_uuid(),
  health_monitor_run_id uuid not null
    references public.health_monitor_runs(id) on delete cascade,
  health_monitor_observation_id uuid not null
    references public.health_monitor_observations(id) on delete cascade,
  incident_key text not null,
  incident_type text not null,
  severity text not null,
  status text not null default 'open',
  title text not null,
  summary text,
  component text not null,
  source_record_id uuid,
  first_detected_at timestamptz not null,
  last_detected_at timestamptz not null,
  acknowledged_at timestamptz,
  acknowledged_by uuid,
  acknowledgement_note text,
  resolved_at timestamptz,
  resolution_note text,
  automatic_action_enabled boolean not null default false,
  incident_hash text not null,
  created_at timestamptz not null default clock_timestamp(),
  constraint health_monitor_incidents_key_not_blank
    check (btrim(incident_key) <> ''),
  constraint health_monitor_incidents_type_not_blank
    check (btrim(incident_type) <> ''),
  constraint health_monitor_incidents_title_not_blank
    check (btrim(title) <> ''),
  constraint health_monitor_incidents_component_not_blank
    check (btrim(component) <> ''),
  constraint health_monitor_incidents_severity
    check (severity in ('critical', 'high', 'medium')),
  constraint health_monitor_incidents_status
    check (status in ('open', 'acknowledged', 'resolved', 'suppressed')),
  constraint health_monitor_incidents_detection_order
    check (last_detected_at >= first_detected_at),
  constraint health_monitor_incidents_ack_consistency
    check (
      status <> 'acknowledged'
      or (acknowledged_at is not null and acknowledged_by is not null)
    ),
  constraint health_monitor_incidents_resolution_consistency
    check (status <> 'resolved' or resolved_at is not null),
  constraint health_monitor_incidents_action_guard
    check (automatic_action_enabled = false),
  constraint health_monitor_incidents_hash_not_blank
    check (btrim(incident_hash) <> ''),
  constraint health_monitor_incidents_unique_observation
    unique (health_monitor_observation_id),
  constraint health_monitor_incidents_unique_hash
    unique (incident_hash)
);

create index if not exists health_monitor_incidents_attention_idx
  on public.health_monitor_incidents (severity, first_detected_at desc)
  where status in ('open', 'acknowledged');

create index if not exists health_monitor_incidents_component_idx
  on public.health_monitor_incidents (component, status, last_detected_at desc);

comment on table public.health_monitor_incidents
is 'Non-executable incident ledger derived from high and critical observations. Automatic remediation is structurally disabled.';

-- --------------------------------------------------------------------------
-- Immutability guards
-- --------------------------------------------------------------------------

create or replace function public.protect_health_monitor_run_core()
returns trigger
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
begin
  if old.status in ('completed', 'failed', 'cancelled') then
    raise exception using
      errcode = '55000',
      message = 'terminal health monitor run is immutable';
  end if;
  return new;
end;
$$;

create trigger trg_protect_health_monitor_run_core
before update or delete on public.health_monitor_runs
for each row
execute function public.protect_health_monitor_run_core();

create or replace function public.protect_health_monitor_observation()
returns trigger
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
begin
  raise exception using
    errcode = '55000',
    message = 'health monitor observations are append-only';
end;
$$;

create trigger trg_protect_health_monitor_observation_update
before update on public.health_monitor_observations
for each row
execute function public.protect_health_monitor_observation();

create trigger trg_protect_health_monitor_observation_delete
before delete on public.health_monitor_observations
for each row
execute function public.protect_health_monitor_observation();

-- --------------------------------------------------------------------------
-- Request health run RPC
-- --------------------------------------------------------------------------

create or replace function public.request_health_monitor_run_rpc(
  p_profile_key text,
  p_idempotency_key text,
  p_requested_by uuid default null,
  p_request_payload jsonb default '{}'::jsonb,
  p_correlation_id uuid default null,
  p_causation_id uuid default null
)
returns public.health_monitor_runs
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_profile public.health_monitor_profiles;
  v_run public.health_monitor_runs;
begin
  if p_profile_key is null or btrim(p_profile_key) = '' then
    raise exception using errcode = '22023', message = 'profile_key is required';
  end if;
  if p_idempotency_key is null or btrim(p_idempotency_key) = '' then
    raise exception using errcode = '22023', message = 'idempotency_key is required';
  end if;
  if p_request_payload is null or jsonb_typeof(p_request_payload) <> 'object' then
    raise exception using errcode = '22023', message = 'request_payload must be a JSON object';
  end if;

  select * into v_profile
  from public.health_monitor_profiles
  where profile_key = btrim(p_profile_key)
    and retired_at is null;

  if not found then
    raise exception using errcode = 'P0002', message = 'health monitor profile not found';
  end if;
  if not v_profile.enabled then
    raise exception using errcode = '55000', message = 'health monitor profile is disabled';
  end if;

  insert into public.health_monitor_runs (
    profile_id, profile_key, profile_version,
    idempotency_key, requested_by, request_payload,
    correlation_id, causation_id
  ) values (
    v_profile.id, v_profile.profile_key, v_profile.profile_version,
    btrim(p_idempotency_key), p_requested_by, p_request_payload,
    coalesce(p_correlation_id, extensions.gen_random_uuid()), p_causation_id
  )
  on conflict (idempotency_key) do nothing
  returning * into v_run;

  if not found then
    select * into v_run
    from public.health_monitor_runs
    where idempotency_key = btrim(p_idempotency_key);
  end if;

  return v_run;
end;
$$;

comment on function public.request_health_monitor_run_rpc(text,text,uuid,jsonb,uuid,uuid)
is 'Requests an idempotent health monitor run using an enabled profile.';

-- --------------------------------------------------------------------------
-- Build health run RPC
-- --------------------------------------------------------------------------

create or replace function public.build_health_monitor_run_rpc(
  p_health_monitor_run_id uuid
)
returns public.health_monitor_runs
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_run public.health_monitor_runs;
  v_profile public.health_monitor_profiles;
  v_now timestamptz := clock_timestamp();
  v_observation_count integer;
  v_critical integer;
  v_high integer;
  v_medium integer;
  v_low integer;
  v_info integer;
  v_incident_count integer;
  v_score integer;
  v_overall text;
  v_hash text;
begin
  select * into v_run
  from public.health_monitor_runs
  where id = p_health_monitor_run_id
  for update;

  if not found then
    raise exception using errcode = 'P0002', message = 'health monitor run not found';
  end if;
  if v_run.status = 'completed' then
    return v_run;
  end if;
  if v_run.status <> 'requested' then
    raise exception using errcode = '55000', message = 'health monitor run is not requestable';
  end if;

  select * into v_profile
  from public.health_monitor_profiles
  where id = v_run.profile_id;

  update public.health_monitor_runs
  set status = 'running', started_at = v_now
  where id = v_run.id;

  -- 1. Reconciliation profile availability.
  insert into public.health_monitor_observations (
    health_monitor_run_id, observation_key, check_type, severity,
    component, source_table, source_record_id,
    observed_status, expected_status, reference_at, observed_at,
    evidence, observation_hash
  )
  select
    v_run.id,
    'reconciliation-profile:' || v_profile.reconciliation_profile_key,
    'reconciliation_profile_availability',
    case when p.id is null then 'critical'
         when not p.enabled then 'high'
         else 'info' end,
    'runtime_reconciliation', 'runtime_reconciliation_profiles', p.id,
    case when p.id is null then 'missing'
         when p.enabled then 'enabled'
         else 'disabled' end,
    'enabled', coalesce(p.updated_at, v_now), v_now,
    jsonb_build_object(
      'profile_key', v_profile.reconciliation_profile_key,
      'profile_found', p.id is not null,
      'profile_enabled', coalesce(p.enabled, false),
      'auto_action_enabled', coalesce(p.auto_action_enabled, false)
    ),
    encode(extensions.digest(
      concat_ws('|', 'reconciliation_profile_availability',
        v_profile.reconciliation_profile_key,
        coalesce(p.id::text, 'missing'),
        coalesce(p.enabled::text, 'false'),
        coalesce(p.updated_at::text, v_now::text)), 'sha256'
    ), 'hex')
  from (select 1) seed
  left join public.runtime_reconciliation_profiles p
    on p.profile_key = v_profile.reconciliation_profile_key
   and p.retired_at is null
  on conflict do nothing;

  -- 2. Reconciliation scans stuck in requested state.
  insert into public.health_monitor_observations (
    health_monitor_run_id, observation_key, check_type, severity,
    component, source_table, source_record_id,
    observed_status, expected_status, reference_at, observed_at,
    evidence, observation_hash
  )
  select
    v_run.id,
    'stale-requested-scan:' || s.id::text,
    'stale_reconciliation_scan_requested', 'medium',
    'runtime_reconciliation', 'runtime_reconciliation_scans', s.id,
    s.status, 'running_or_terminal', s.requested_at, v_now,
    jsonb_build_object(
      'profile_key', s.profile_key,
      'requested_at', s.requested_at,
      'age_seconds', extract(epoch from (v_now - s.requested_at)),
      'threshold', v_profile.stale_requested_interval
    ),
    encode(extensions.digest(
      concat_ws('|', 'stale_reconciliation_scan_requested', s.id::text,
        s.status, s.requested_at::text), 'sha256'
    ), 'hex')
  from public.runtime_reconciliation_scans s
  where s.status = 'requested'
    and s.requested_at < v_now - v_profile.stale_requested_interval
  order by s.requested_at
  limit v_profile.maximum_observations
  on conflict do nothing;

  -- 3. Reconciliation scans stuck in running state.
  insert into public.health_monitor_observations (
    health_monitor_run_id, observation_key, check_type, severity,
    component, source_table, source_record_id,
    observed_status, expected_status, reference_at, observed_at,
    evidence, observation_hash
  )
  select
    v_run.id,
    'stale-running-scan:' || s.id::text,
    'stale_reconciliation_scan_running', 'high',
    'runtime_reconciliation', 'runtime_reconciliation_scans', s.id,
    s.status, 'completed_or_failed', coalesce(s.started_at, s.requested_at), v_now,
    jsonb_build_object(
      'profile_key', s.profile_key,
      'started_at', s.started_at,
      'age_seconds', extract(epoch from (v_now - coalesce(s.started_at, s.requested_at))),
      'threshold', v_profile.stale_running_interval
    ),
    encode(extensions.digest(
      concat_ws('|', 'stale_reconciliation_scan_running', s.id::text,
        s.status, coalesce(s.started_at, s.requested_at)::text), 'sha256'
    ), 'hex')
  from public.runtime_reconciliation_scans s
  where s.status = 'running'
    and coalesce(s.started_at, s.requested_at) < v_now - v_profile.stale_running_interval
  order by coalesce(s.started_at, s.requested_at)
  limit v_profile.maximum_observations
  on conflict do nothing;

  -- 4. Failed reconciliation scans in the configured lookback window.
  insert into public.health_monitor_observations (
    health_monitor_run_id, observation_key, check_type, severity,
    component, source_table, source_record_id,
    observed_status, expected_status, reference_at, observed_at,
    evidence, observation_hash
  )
  select
    v_run.id,
    'failed-reconciliation-scan:' || s.id::text,
    'failed_reconciliation_scan', 'high',
    'runtime_reconciliation', 'runtime_reconciliation_scans', s.id,
    s.status, 'completed', coalesce(s.completed_at, s.requested_at), v_now,
    jsonb_build_object(
      'profile_key', s.profile_key,
      'error_code', s.error_code,
      'error_message', s.error_message,
      'completed_at', s.completed_at
    ),
    encode(extensions.digest(
      concat_ws('|', 'failed_reconciliation_scan', s.id::text,
        s.status, coalesce(s.completed_at, s.requested_at)::text,
        coalesce(s.error_code, '')), 'sha256'
    ), 'hex')
  from public.runtime_reconciliation_scans s
  where s.status = 'failed'
    and coalesce(s.completed_at, s.requested_at) >= v_now - v_profile.lookback_interval
  order by coalesce(s.completed_at, s.requested_at) desc
  limit v_profile.maximum_observations
  on conflict do nothing;

  -- 5. Unacknowledged reconciliation findings requiring attention.
  insert into public.health_monitor_observations (
    health_monitor_run_id, observation_key, check_type, severity,
    component, source_table, source_record_id,
    observed_status, expected_status, reference_at, observed_at,
    evidence, observation_hash
  )
  select
    v_run.id,
    'unacknowledged-finding:' || f.id::text,
    'unacknowledged_reconciliation_finding',
    case when f.severity = 'critical' then 'critical' else 'high' end,
    'runtime_reconciliation', 'runtime_reconciliation_findings', f.id,
    'unacknowledged', 'acknowledged_or_resolved', f.observed_at, v_now,
    jsonb_build_object(
      'finding_key', f.finding_key,
      'finding_type', f.finding_type,
      'finding_severity', f.severity,
      'source_component', f.source_component,
      'source_table', f.source_table,
      'source_record_id', f.source_record_id,
      'reconciliation_scan_id', f.reconciliation_scan_id,
      'proposed_action_type', f.proposed_action_type,
      'action_safe', f.action_safe
    ),
    encode(extensions.digest(
      concat_ws('|', 'unacknowledged_reconciliation_finding', f.id::text,
        f.severity, f.observed_at::text), 'sha256'
    ), 'hex')
  from public.runtime_reconciliation_findings f
  where f.acknowledged_at is null
    and f.severity in ('critical', 'high')
    and f.observed_at >= v_now - v_profile.lookback_interval
  order by f.observed_at desc
  limit v_profile.maximum_observations
  on conflict do nothing;

  -- 6. Safety invariant: no executable reconciliation action may exist.
  insert into public.health_monitor_observations (
    health_monitor_run_id, observation_key, check_type, severity,
    component, source_table,
    observed_status, expected_status, observed_value, threshold_value,
    reference_at, observed_at, evidence, observation_hash
  )
  select
    v_run.id,
    'reconciliation-executable-actions',
    'reconciliation_execution_safety_invariant',
    case when count(*) filter (where a.execution_enabled) > 0 then 'critical' else 'info' end,
    'runtime_reconciliation', 'runtime_reconciliation_actions',
    case when count(*) filter (where a.execution_enabled) > 0 then 'violated' else 'satisfied' end,
    'satisfied', count(*) filter (where a.execution_enabled)::numeric, 0,
    max(a.created_at), v_now,
    jsonb_build_object(
      'executable_action_count', count(*) filter (where a.execution_enabled),
      'total_action_count', count(*)
    ),
    encode(extensions.digest(
      concat_ws('|', 'reconciliation_execution_safety_invariant',
        (count(*) filter (where a.execution_enabled))::text,
        coalesce(max(a.created_at)::text, 'none')), 'sha256'
    ), 'hex')
  from public.runtime_reconciliation_actions a
  on conflict do nothing;

  -- Incidents are materialized only for high or critical observations.
  insert into public.health_monitor_incidents (
    health_monitor_run_id, health_monitor_observation_id,
    incident_key, incident_type, severity, status,
    title, summary, component, source_record_id,
    first_detected_at, last_detected_at,
    automatic_action_enabled, incident_hash
  )
  select
    o.health_monitor_run_id, o.id,
    'health-incident:' || o.observation_key,
    o.check_type, o.severity, 'open',
    replace(initcap(replace(o.check_type, '_', ' ')), 'Reconciliation', 'Reconciliation'),
    concat_ws(' ', 'Health monitor detected', o.check_type, 'for component', o.component || '.'),
    o.component, o.source_record_id,
    o.observed_at, o.observed_at,
    false,
    encode(extensions.digest(
      concat_ws('|', 'health_incident', o.id::text, o.observation_hash), 'sha256'
    ), 'hex')
  from public.health_monitor_observations o
  where o.health_monitor_run_id = v_run.id
    and o.severity in ('critical', 'high')
  on conflict do nothing;

  select
    count(*)::integer,
    count(*) filter (where severity = 'critical')::integer,
    count(*) filter (where severity = 'high')::integer,
    count(*) filter (where severity = 'medium')::integer,
    count(*) filter (where severity = 'low')::integer,
    count(*) filter (where severity = 'info')::integer
  into v_observation_count, v_critical, v_high, v_medium, v_low, v_info
  from public.health_monitor_observations
  where health_monitor_run_id = v_run.id;

  select count(*)::integer
  into v_incident_count
  from public.health_monitor_incidents
  where health_monitor_run_id = v_run.id;

  v_score := greatest(0, 100 - (v_critical * 40) - (v_high * 20) - (v_medium * 8) - (v_low * 2));
  v_overall := case
    when v_critical > 0 then 'critical'
    when v_high > 0 then 'unhealthy'
    when v_medium > 0 then 'degraded'
    else 'healthy'
  end;

  select encode(extensions.digest(
    coalesce(string_agg(observation_hash, '|' order by observation_hash), 'empty'),
    'sha256'
  ), 'hex')
  into v_hash
  from public.health_monitor_observations
  where health_monitor_run_id = v_run.id;

  update public.health_monitor_runs
  set
    status = 'completed',
    completed_at = clock_timestamp(),
    overall_status = v_overall,
    health_score = v_score,
    observation_count = v_observation_count,
    critical_count = v_critical,
    high_count = v_high,
    medium_count = v_medium,
    low_count = v_low,
    info_count = v_info,
    incident_count = v_incident_count,
    truncated = v_observation_count >= v_profile.maximum_observations,
    run_hash = v_hash,
    monitor_snapshot = jsonb_build_object(
      'monitor_version', monitor_version,
      'profile_key', v_profile.profile_key,
      'profile_version', v_profile.profile_version,
      'reconciliation_profile_key', v_profile.reconciliation_profile_key,
      'lookback_interval', v_profile.lookback_interval,
      'stale_requested_interval', v_profile.stale_requested_interval,
      'stale_running_interval', v_profile.stale_running_interval,
      'automatic_remediation_enabled', false,
      'observation_count', v_observation_count,
      'incident_count', v_incident_count,
      'overall_status', v_overall,
      'health_score', v_score
    )
  where id = v_run.id
  returning * into v_run;

  return v_run;
exception
  when others then
    update public.health_monitor_runs
    set
      status = 'failed',
      completed_at = clock_timestamp(),
      error_code = sqlstate,
      error_message = sqlerrm,
      error_details = jsonb_build_object('function', 'build_health_monitor_run_rpc')
    where id = p_health_monitor_run_id
      and status not in ('completed', 'failed', 'cancelled');
    raise;
end;
$$;

comment on function public.build_health_monitor_run_rpc(uuid)
is 'Builds a deterministic non-destructive health snapshot from reconciliation state and safety invariants.';

-- --------------------------------------------------------------------------
-- Incident acknowledgement RPC
-- --------------------------------------------------------------------------

create or replace function public.acknowledge_health_monitor_incident_rpc(
  p_incident_id uuid,
  p_acknowledged_by uuid,
  p_note text default null
)
returns public.health_monitor_incidents
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_incident public.health_monitor_incidents;
begin
  if p_incident_id is null then
    raise exception using errcode = '22023', message = 'incident_id is required';
  end if;
  if p_acknowledged_by is null then
    raise exception using errcode = '22023', message = 'acknowledged_by is required';
  end if;

  update public.health_monitor_incidents
  set
    status = 'acknowledged',
    acknowledged_at = coalesce(acknowledged_at, clock_timestamp()),
    acknowledged_by = coalesce(acknowledged_by, p_acknowledged_by),
    acknowledgement_note = coalesce(p_note, acknowledgement_note)
  where id = p_incident_id
    and status = 'open'
  returning * into v_incident;

  if not found then
    select * into v_incident
    from public.health_monitor_incidents
    where id = p_incident_id;
  end if;

  if not found then
    raise exception using errcode = 'P0002', message = 'health monitor incident not found';
  end if;

  return v_incident;
end;
$$;

comment on function public.acknowledge_health_monitor_incident_rpc(uuid,uuid,text)
is 'Acknowledges an open health incident without executing any remediation.';

-- --------------------------------------------------------------------------
-- Read models
-- --------------------------------------------------------------------------

create or replace view public.health_monitor_run_status_v1 as
select
  r.id as health_monitor_run_id,
  r.profile_id,
  r.profile_key,
  r.profile_version,
  p.display_name as profile_display_name,
  p.enabled as profile_enabled,
  p.automatic_remediation_enabled,
  p.reconciliation_profile_key,
  r.status,
  r.overall_status,
  r.health_score,
  r.idempotency_key,
  r.requested_by,
  r.requested_at,
  r.started_at,
  r.completed_at,
  r.observation_cutoff_at,
  r.monitor_version,
  r.observation_count,
  r.critical_count,
  r.high_count,
  r.medium_count,
  r.low_count,
  r.info_count,
  r.incident_count,
  r.truncated,
  r.run_hash,
  r.request_payload,
  r.monitor_snapshot,
  r.error_code,
  r.error_message,
  r.error_details,
  r.correlation_id,
  r.causation_id,
  r.created_at
from public.health_monitor_runs r
join public.health_monitor_profiles p on p.id = r.profile_id;

comment on view public.health_monitor_run_status_v1
is 'Operational health run read model with profile, score, severity and lifecycle context.';

create or replace view public.health_monitor_attention_v1 as
select
  i.id as health_monitor_incident_id,
  i.health_monitor_run_id,
  i.health_monitor_observation_id,
  i.incident_key,
  i.incident_type,
  i.severity,
  i.status,
  i.title,
  i.summary,
  i.component,
  i.source_record_id,
  i.first_detected_at,
  i.last_detected_at,
  i.acknowledged_at,
  i.acknowledged_by,
  i.acknowledgement_note,
  i.resolved_at,
  i.resolution_note,
  i.automatic_action_enabled,
  i.incident_hash,
  i.created_at,
  o.observation_key,
  o.check_type,
  o.source_table,
  o.observed_status,
  o.expected_status,
  o.observed_value,
  o.threshold_value,
  o.reference_at,
  o.observed_at,
  o.evidence,
  r.profile_key,
  r.profile_version,
  r.overall_status as run_overall_status,
  r.health_score,
  r.requested_at as run_requested_at,
  r.completed_at as run_completed_at,
  case
    when i.status = 'open' and i.severity = 'critical' then 'immediate'
    when i.status = 'open' and i.severity = 'high' then 'urgent'
    when i.status = 'acknowledged' then 'tracked'
    else 'none'
  end as attention_level,
  coalesce(i.acknowledged_at, i.first_detected_at) as attention_reference_at
from public.health_monitor_incidents i
join public.health_monitor_observations o
  on o.id = i.health_monitor_observation_id
join public.health_monitor_runs r
  on r.id = i.health_monitor_run_id
where i.status in ('open', 'acknowledged');

comment on view public.health_monitor_attention_v1
is 'Open and acknowledged health incidents requiring operational attention.';

-- --------------------------------------------------------------------------
-- RLS and policies
-- --------------------------------------------------------------------------

alter table public.health_monitor_profiles enable row level security;
alter table public.health_monitor_runs enable row level security;
alter table public.health_monitor_observations enable row level security;
alter table public.health_monitor_incidents enable row level security;

create policy health_monitor_profiles_service_role_all
on public.health_monitor_profiles
for all to service_role
using (true) with check (true);

create policy health_monitor_runs_service_role_all
on public.health_monitor_runs
for all to service_role
using (true) with check (true);

create policy health_monitor_observations_service_role_all
on public.health_monitor_observations
for all to service_role
using (true) with check (true);

create policy health_monitor_incidents_service_role_all
on public.health_monitor_incidents
for all to service_role
using (true) with check (true);

-- --------------------------------------------------------------------------
-- Privileges
-- --------------------------------------------------------------------------

revoke all on public.health_monitor_profiles from public, anon, authenticated;
revoke all on public.health_monitor_runs from public, anon, authenticated;
revoke all on public.health_monitor_observations from public, anon, authenticated;
revoke all on public.health_monitor_incidents from public, anon, authenticated;

grant select, insert, update, delete on public.health_monitor_profiles to service_role;
grant select, insert, update, delete on public.health_monitor_runs to service_role;
grant select, insert, update, delete on public.health_monitor_observations to service_role;
grant select, insert, update, delete on public.health_monitor_incidents to service_role;

revoke all on function public.request_health_monitor_run_rpc(text,text,uuid,jsonb,uuid,uuid)
  from public, anon, authenticated;
revoke all on function public.build_health_monitor_run_rpc(uuid)
  from public, anon, authenticated;
revoke all on function public.acknowledge_health_monitor_incident_rpc(uuid,uuid,text)
  from public, anon, authenticated;

grant execute on function public.request_health_monitor_run_rpc(text,text,uuid,jsonb,uuid,uuid)
  to service_role;
grant execute on function public.build_health_monitor_run_rpc(uuid)
  to service_role;
grant execute on function public.acknowledge_health_monitor_incident_rpc(uuid,uuid,text)
  to service_role;

revoke all on public.health_monitor_run_status_v1 from public, anon, authenticated, service_role;
revoke all on public.health_monitor_attention_v1 from public, anon, authenticated, service_role;
grant select on public.health_monitor_run_status_v1 to service_role;
grant select on public.health_monitor_attention_v1 to service_role;

-- Preserve read-only service_role contracts on prior read models.
revoke all on public.runtime_reconciliation_scan_status_v1 from service_role;
revoke all on public.runtime_reconciliation_attention_v1 from service_role;
grant select on public.runtime_reconciliation_scan_status_v1 to service_role;
grant select on public.runtime_reconciliation_attention_v1 to service_role;

-- --------------------------------------------------------------------------
-- Disabled seed profile
-- --------------------------------------------------------------------------

insert into public.health_monitor_profiles (
  profile_key,
  profile_version,
  display_name,
  description,
  enabled,
  automatic_remediation_enabled,
  reconciliation_profile_key,
  lookback_interval,
  stale_requested_interval,
  stale_running_interval,
  maximum_observations,
  check_config
) values (
  'runtime-health-core',
  1,
  'Runtime Health Core',
  'Disabled-by-default health monitor for reconciliation availability, scan lifecycle, findings and execution safety.',
  false,
  false,
  'runtime-core',
  interval '24 hours',
  interval '15 minutes',
  interval '30 minutes',
  1000,
  jsonb_build_object(
    'checks', jsonb_build_array(
      'reconciliation_profile_availability',
      'stale_reconciliation_scan_requested',
      'stale_reconciliation_scan_running',
      'failed_reconciliation_scan',
      'unacknowledged_reconciliation_finding',
      'reconciliation_execution_safety_invariant'
    ),
    'automatic_remediation_enabled', false,
    'automatic_remediation', false
  )
)
on conflict (profile_key, profile_version) do nothing;

-- --------------------------------------------------------------------------
-- Migration assertions
-- --------------------------------------------------------------------------

do $$
declare
  v_table_count integer;
  v_function_count integer;
  v_view_count integer;
  v_profile_count integer;
begin
  select count(*) into v_table_count
  from information_schema.tables
  where table_schema = 'public'
    and table_name in (
      'health_monitor_profiles',
      'health_monitor_runs',
      'health_monitor_observations',
      'health_monitor_incidents'
    );

  select count(*) into v_function_count
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname in (
      'protect_health_monitor_run_core',
      'protect_health_monitor_observation',
      'request_health_monitor_run_rpc',
      'build_health_monitor_run_rpc',
      'acknowledge_health_monitor_incident_rpc'
    );

  select count(*) into v_view_count
  from information_schema.views
  where table_schema = 'public'
    and table_name in (
      'health_monitor_run_status_v1',
      'health_monitor_attention_v1'
    );

  select count(*) into v_profile_count
  from public.health_monitor_profiles
  where profile_key = 'runtime-health-core'
    and profile_version = 1
    and enabled = false
    and automatic_remediation_enabled = false;

  if v_table_count <> 4 then
    raise exception '071 assertion failed: expected 4 tables, found %', v_table_count;
  end if;
  if v_function_count <> 5 then
    raise exception '071 assertion failed: expected 5 functions, found %', v_function_count;
  end if;
  if v_view_count <> 2 then
    raise exception '071 assertion failed: expected 2 views, found %', v_view_count;
  end if;
  if v_profile_count <> 1 then
    raise exception '071 assertion failed: disabled seed profile missing or unsafe';
  end if;
end;
$$;

commit;
