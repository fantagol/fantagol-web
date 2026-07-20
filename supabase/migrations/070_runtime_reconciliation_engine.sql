-- ============================================================================
-- FantaGol
-- Migration 070: Runtime Reconciliation Engine
-- Milestone 7.4.3
--
-- Purpose
--   Introduce a non-destructive reconciliation layer that detects divergence
--   between runtime workflows, workflow steps, runtime jobs, recovery leases
--   and maintenance leases.
--
-- Safety contract
--   * This migration never repairs or deletes runtime data.
--   * Scans persist immutable observations and proposed actions only.
--   * Proposed actions are disabled by default and require a future executor.
--   * All mutation RPCs are service_role only.
-- ============================================================================

begin;

create extension if not exists pgcrypto with schema extensions;

-- --------------------------------------------------------------------------
-- Reconciliation profile registry
-- --------------------------------------------------------------------------

create table if not exists public.runtime_reconciliation_profiles (
  id uuid primary key default extensions.gen_random_uuid(),
  profile_key text not null,
  profile_version integer not null default 1,
  display_name text not null,
  description text,
  enabled boolean not null default false,
  auto_action_enabled boolean not null default false,
  stale_job_interval interval not null default interval '15 minutes',
  stale_workflow_interval interval not null default interval '30 minutes',
  lease_grace_interval interval not null default interval '2 minutes',
  maximum_findings integer not null default 1000,
  check_config jsonb not null default '{}'::jsonb,
  created_by uuid,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  retired_at timestamptz,
  constraint runtime_reconciliation_profiles_key_not_blank
    check (btrim(profile_key) <> ''),
  constraint runtime_reconciliation_profiles_display_not_blank
    check (btrim(display_name) <> ''),
  constraint runtime_reconciliation_profiles_version_positive
    check (profile_version > 0),
  constraint runtime_reconciliation_profiles_intervals_positive
    check (
      stale_job_interval > interval '0 seconds'
      and stale_workflow_interval > interval '0 seconds'
      and lease_grace_interval >= interval '0 seconds'
    ),
  constraint runtime_reconciliation_profiles_maximum_positive
    check (maximum_findings > 0 and maximum_findings <= 10000),
  constraint runtime_reconciliation_profiles_config_object
    check (jsonb_typeof(check_config) = 'object'),
  constraint runtime_reconciliation_profiles_auto_action_guard
    check (auto_action_enabled = false),
  constraint runtime_reconciliation_profiles_unique_version
    unique (profile_key, profile_version)
);

create unique index if not exists runtime_reconciliation_profiles_active_uidx
  on public.runtime_reconciliation_profiles (profile_key)
  where retired_at is null;

create index if not exists runtime_reconciliation_profiles_enabled_idx
  on public.runtime_reconciliation_profiles (enabled, profile_key)
  where retired_at is null;

create trigger trg_runtime_reconciliation_profiles_updated_at
before update on public.runtime_reconciliation_profiles
for each row
execute function public.set_maintenance_updated_at();

comment on table public.runtime_reconciliation_profiles
is 'Versioned and disabled-by-default configuration for non-destructive runtime reconciliation scans.';

-- --------------------------------------------------------------------------
-- Reconciliation scans
-- --------------------------------------------------------------------------

create table if not exists public.runtime_reconciliation_scans (
  id uuid primary key default extensions.gen_random_uuid(),
  profile_id uuid not null
    references public.runtime_reconciliation_profiles(id) on delete restrict,
  profile_key text not null,
  profile_version integer not null,
  maintenance_run_id uuid
    references public.maintenance_runs(id) on delete set null,
  status text not null default 'requested',
  idempotency_key text not null,
  requested_by uuid,
  requested_at timestamptz not null default clock_timestamp(),
  started_at timestamptz,
  completed_at timestamptz,
  scan_cutoff_at timestamptz not null default clock_timestamp(),
  scanner_version text not null default 'runtime-reconciliation-v1',
  finding_count integer not null default 0,
  critical_count integer not null default 0,
  high_count integer not null default 0,
  medium_count integer not null default 0,
  low_count integer not null default 0,
  truncated boolean not null default false,
  scan_hash text,
  request_payload jsonb not null default '{}'::jsonb,
  scanner_snapshot jsonb,
  error_code text,
  error_message text,
  error_details jsonb,
  correlation_id uuid not null default extensions.gen_random_uuid(),
  causation_id uuid,
  created_at timestamptz not null default clock_timestamp(),
  constraint runtime_reconciliation_scans_status
    check (status in ('requested', 'running', 'completed', 'failed', 'cancelled')),
  constraint runtime_reconciliation_scans_idempotency_not_blank
    check (btrim(idempotency_key) <> ''),
  constraint runtime_reconciliation_scans_profile_not_blank
    check (btrim(profile_key) <> '' and profile_version > 0),
  constraint runtime_reconciliation_scans_version_not_blank
    check (btrim(scanner_version) <> ''),
  constraint runtime_reconciliation_scans_counts_nonnegative
    check (
      finding_count >= 0 and critical_count >= 0 and high_count >= 0
      and medium_count >= 0 and low_count >= 0
    ),
  constraint runtime_reconciliation_scans_request_object
    check (jsonb_typeof(request_payload) = 'object'),
  constraint runtime_reconciliation_scans_snapshot_object
    check (scanner_snapshot is null or jsonb_typeof(scanner_snapshot) = 'object'),
  constraint runtime_reconciliation_scans_error_object
    check (error_details is null or jsonb_typeof(error_details) = 'object'),
  constraint runtime_reconciliation_scans_terminal_time
    check (
      status not in ('completed', 'failed', 'cancelled')
      or completed_at is not null
    ),
  constraint runtime_reconciliation_scans_hash_on_complete
    check (status <> 'completed' or scan_hash is not null),
  constraint runtime_reconciliation_scans_idempotency_unique
    unique (idempotency_key)
);

create index if not exists runtime_reconciliation_scans_status_idx
  on public.runtime_reconciliation_scans (status, requested_at desc);

create index if not exists runtime_reconciliation_scans_profile_idx
  on public.runtime_reconciliation_scans (profile_key, requested_at desc);

create index if not exists runtime_reconciliation_scans_maintenance_idx
  on public.runtime_reconciliation_scans (maintenance_run_id)
  where maintenance_run_id is not null;

comment on table public.runtime_reconciliation_scans
is 'Immutable-after-completion scan header for runtime consistency inspections.';

-- --------------------------------------------------------------------------
-- Immutable findings
-- --------------------------------------------------------------------------

create table if not exists public.runtime_reconciliation_findings (
  id uuid primary key default extensions.gen_random_uuid(),
  reconciliation_scan_id uuid not null
    references public.runtime_reconciliation_scans(id) on delete cascade,
  finding_key text not null,
  finding_type text not null,
  severity text not null,
  source_component text not null,
  source_table text not null,
  source_record_id uuid,
  workflow_id uuid,
  workflow_step_id uuid,
  job_id uuid,
  recovery_request_id uuid,
  maintenance_run_id uuid,
  observed_status text,
  expected_status text,
  observed_at timestamptz not null default clock_timestamp(),
  reference_at timestamptz,
  evidence jsonb not null default '{}'::jsonb,
  proposed_action_type text,
  action_safe boolean not null default false,
  finding_hash text not null,
  acknowledged_at timestamptz,
  acknowledged_by uuid,
  acknowledgement_note text,
  created_at timestamptz not null default clock_timestamp(),
  constraint runtime_reconciliation_findings_key_not_blank
    check (btrim(finding_key) <> ''),
  constraint runtime_reconciliation_findings_type_not_blank
    check (btrim(finding_type) <> ''),
  constraint runtime_reconciliation_findings_severity
    check (severity in ('critical', 'high', 'medium', 'low', 'info')),
  constraint runtime_reconciliation_findings_component_not_blank
    check (btrim(source_component) <> '' and btrim(source_table) <> ''),
  constraint runtime_reconciliation_findings_evidence_object
    check (jsonb_typeof(evidence) = 'object'),
  constraint runtime_reconciliation_findings_hash_not_blank
    check (btrim(finding_hash) <> ''),
  constraint runtime_reconciliation_findings_ack_consistency
    check (
      (acknowledged_at is null and acknowledged_by is null)
      or (acknowledged_at is not null and acknowledged_by is not null)
    ),
  constraint runtime_reconciliation_findings_unique_key
    unique (reconciliation_scan_id, finding_key),
  constraint runtime_reconciliation_findings_unique_hash
    unique (reconciliation_scan_id, finding_hash)
);

create index if not exists runtime_reconciliation_findings_scan_idx
  on public.runtime_reconciliation_findings
    (reconciliation_scan_id, severity, created_at);

create index if not exists runtime_reconciliation_findings_attention_idx
  on public.runtime_reconciliation_findings
    (severity, observed_at desc)
  where acknowledged_at is null;

create index if not exists runtime_reconciliation_findings_workflow_idx
  on public.runtime_reconciliation_findings (workflow_id, observed_at desc)
  where workflow_id is not null;

comment on table public.runtime_reconciliation_findings
is 'Immutable evidence ledger produced by reconciliation scans. Only acknowledgement fields may change.';

-- --------------------------------------------------------------------------
-- Proposed action ledger
-- --------------------------------------------------------------------------

create table if not exists public.runtime_reconciliation_actions (
  id uuid primary key default extensions.gen_random_uuid(),
  reconciliation_scan_id uuid not null
    references public.runtime_reconciliation_scans(id) on delete cascade,
  reconciliation_finding_id uuid not null
    references public.runtime_reconciliation_findings(id) on delete cascade,
  action_type text not null,
  action_status text not null default 'proposed',
  execution_enabled boolean not null default false,
  target_component text not null,
  target_record_id uuid,
  command_payload jsonb not null default '{}'::jsonb,
  action_hash text not null,
  approved_at timestamptz,
  approved_by uuid,
  approval_reason text,
  cancelled_at timestamptz,
  cancelled_by uuid,
  cancellation_reason text,
  created_at timestamptz not null default clock_timestamp(),
  constraint runtime_reconciliation_actions_type_not_blank
    check (btrim(action_type) <> ''),
  constraint runtime_reconciliation_actions_status
    check (action_status in ('proposed', 'approved', 'cancelled', 'superseded')),
  constraint runtime_reconciliation_actions_execution_guard
    check (execution_enabled = false),
  constraint runtime_reconciliation_actions_target_not_blank
    check (btrim(target_component) <> ''),
  constraint runtime_reconciliation_actions_payload_object
    check (jsonb_typeof(command_payload) = 'object'),
  constraint runtime_reconciliation_actions_hash_not_blank
    check (btrim(action_hash) <> ''),
  constraint runtime_reconciliation_actions_approval_consistency
    check (
      (action_status <> 'approved')
      or (approved_at is not null and approved_by is not null)
    ),
  constraint runtime_reconciliation_actions_cancel_consistency
    check (
      (action_status <> 'cancelled')
      or (cancelled_at is not null and cancelled_by is not null)
    ),
  constraint runtime_reconciliation_actions_finding_unique
    unique (reconciliation_finding_id, action_type),
  constraint runtime_reconciliation_actions_hash_unique
    unique (action_hash)
);

create index if not exists runtime_reconciliation_actions_scan_idx
  on public.runtime_reconciliation_actions
    (reconciliation_scan_id, action_status, created_at);

comment on table public.runtime_reconciliation_actions
is 'Non-executable proposed remediation ledger. execution_enabled is structurally forced to false.';

-- --------------------------------------------------------------------------
-- Immutability guards
-- --------------------------------------------------------------------------

create or replace function public.protect_runtime_reconciliation_scan_core()
returns trigger
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
begin
  if old.status in ('completed', 'failed', 'cancelled') then
    raise exception using
      errcode = '55000',
      message = 'terminal reconciliation scan is immutable';
  end if;
  return new;
end;
$$;

create trigger trg_protect_runtime_reconciliation_scan_core
before update or delete on public.runtime_reconciliation_scans
for each row
execute function public.protect_runtime_reconciliation_scan_core();

create or replace function public.protect_runtime_reconciliation_finding()
returns trigger
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'DELETE' then
    raise exception using
      errcode = '55000',
      message = 'reconciliation findings are append-only';
  end if;

  if new.reconciliation_scan_id is distinct from old.reconciliation_scan_id
     or new.finding_key is distinct from old.finding_key
     or new.finding_type is distinct from old.finding_type
     or new.severity is distinct from old.severity
     or new.source_component is distinct from old.source_component
     or new.source_table is distinct from old.source_table
     or new.source_record_id is distinct from old.source_record_id
     or new.workflow_id is distinct from old.workflow_id
     or new.workflow_step_id is distinct from old.workflow_step_id
     or new.job_id is distinct from old.job_id
     or new.recovery_request_id is distinct from old.recovery_request_id
     or new.maintenance_run_id is distinct from old.maintenance_run_id
     or new.observed_status is distinct from old.observed_status
     or new.expected_status is distinct from old.expected_status
     or new.observed_at is distinct from old.observed_at
     or new.reference_at is distinct from old.reference_at
     or new.evidence is distinct from old.evidence
     or new.proposed_action_type is distinct from old.proposed_action_type
     or new.action_safe is distinct from old.action_safe
     or new.finding_hash is distinct from old.finding_hash
     or new.created_at is distinct from old.created_at then
    raise exception using
      errcode = '55000',
      message = 'reconciliation finding evidence is immutable';
  end if;

  return new;
end;
$$;

create trigger trg_protect_runtime_reconciliation_finding_update
before update on public.runtime_reconciliation_findings
for each row
execute function public.protect_runtime_reconciliation_finding();

create trigger trg_protect_runtime_reconciliation_finding_delete
before delete on public.runtime_reconciliation_findings
for each row
execute function public.protect_runtime_reconciliation_finding();

-- --------------------------------------------------------------------------
-- Request scan RPC
-- --------------------------------------------------------------------------

create or replace function public.request_runtime_reconciliation_scan_rpc(
  p_profile_key text,
  p_idempotency_key text,
  p_requested_by uuid default null,
  p_maintenance_run_id uuid default null,
  p_request_payload jsonb default '{}'::jsonb,
  p_correlation_id uuid default null,
  p_causation_id uuid default null
)
returns public.runtime_reconciliation_scans
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_profile public.runtime_reconciliation_profiles;
  v_scan public.runtime_reconciliation_scans;
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
  from public.runtime_reconciliation_profiles
  where profile_key = btrim(p_profile_key)
    and retired_at is null;

  if not found then
    raise exception using errcode = 'P0002', message = 'reconciliation profile not found';
  end if;
  if not v_profile.enabled then
    raise exception using errcode = '55000', message = 'reconciliation profile is disabled';
  end if;

  insert into public.runtime_reconciliation_scans (
    profile_id, profile_key, profile_version, maintenance_run_id,
    idempotency_key, requested_by, request_payload,
    correlation_id, causation_id
  ) values (
    v_profile.id, v_profile.profile_key, v_profile.profile_version,
    p_maintenance_run_id, btrim(p_idempotency_key), p_requested_by,
    p_request_payload, coalesce(p_correlation_id, extensions.gen_random_uuid()),
    p_causation_id
  )
  on conflict (idempotency_key) do nothing
  returning * into v_scan;

  if not found then
    select * into v_scan
    from public.runtime_reconciliation_scans
    where idempotency_key = btrim(p_idempotency_key);
  end if;

  return v_scan;
end;
$$;

comment on function public.request_runtime_reconciliation_scan_rpc(text,text,uuid,uuid,jsonb,uuid,uuid)
is 'Requests an idempotent non-destructive reconciliation scan using an enabled profile.';

-- --------------------------------------------------------------------------
-- Build scan RPC
-- --------------------------------------------------------------------------

create or replace function public.build_runtime_reconciliation_scan_rpc(
  p_reconciliation_scan_id uuid
)
returns public.runtime_reconciliation_scans
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_scan public.runtime_reconciliation_scans;
  v_profile public.runtime_reconciliation_profiles;
  v_now timestamptz := clock_timestamp();
  v_count integer;
  v_critical integer;
  v_high integer;
  v_medium integer;
  v_low integer;
  v_hash text;
begin
  select * into v_scan
  from public.runtime_reconciliation_scans
  where id = p_reconciliation_scan_id
  for update;

  if not found then
    raise exception using errcode = 'P0002', message = 'reconciliation scan not found';
  end if;
  if v_scan.status = 'completed' then
    return v_scan;
  end if;
  if v_scan.status <> 'requested' then
    raise exception using errcode = '55000', message = 'reconciliation scan is not requestable';
  end if;

  select * into v_profile
  from public.runtime_reconciliation_profiles
  where id = v_scan.profile_id;

  update public.runtime_reconciliation_scans
  set status = 'running', started_at = v_now
  where id = v_scan.id;

  -- 1. Workflow step status differs from its linked runtime job.
  insert into public.runtime_reconciliation_findings (
    reconciliation_scan_id, finding_key, finding_type, severity,
    source_component, source_table, source_record_id,
    workflow_id, workflow_step_id, job_id,
    observed_status, expected_status, observed_at, reference_at,
    evidence, proposed_action_type, action_safe, finding_hash
  )
  select
    v_scan.id,
    'workflow-step-job-status:' || s.id::text,
    'workflow_step_job_status_mismatch',
    case when j.status in ('dead_letter', 'failed') then 'high' else 'medium' end,
    'workflow_orchestration', 'live_runtime_workflow_steps', s.id,
    s.workflow_id, s.id, j.id,
    s.status,
    case j.status
      when 'pending' then 'enqueued'
      when 'claimed' then 'running'
      when 'running' then 'running'
      when 'retry_wait' then 'retry_wait'
      when 'completed' then 'completed'
      when 'failed' then 'failed'
      when 'dead_letter' then 'dead_letter'
      when 'cancelled' then 'cancelled'
      else s.status
    end,
    v_now, greatest(s.updated_at, j.updated_at),
    jsonb_build_object(
      'step_key', s.step_key,
      'step_status', s.status,
      'job_status', j.status,
      'job_type', j.job_type,
      'step_updated_at', s.updated_at,
      'job_updated_at', j.updated_at
    ),
    'reconcile_workflow', false,
    encode(extensions.digest(
      concat_ws('|', 'workflow_step_job_status_mismatch', s.id::text,
        s.status, j.status, greatest(s.updated_at, j.updated_at)::text), 'sha256'
    ), 'hex')
  from public.live_runtime_workflow_steps s
  join public.live_runtime_jobs j on j.id = s.job_id
  where s.status is distinct from case j.status
      when 'pending' then 'enqueued'
      when 'claimed' then 'running'
      when 'running' then 'running'
      when 'retry_wait' then 'retry_wait'
      when 'completed' then 'completed'
      when 'failed' then 'failed'
      when 'dead_letter' then 'dead_letter'
      when 'cancelled' then 'cancelled'
      else s.status
    end
  order by greatest(s.updated_at, j.updated_at) desc
  limit v_profile.maximum_findings
  on conflict do nothing;

  -- 2. Workflow aggregate state differs from deterministic step roll-up.
  with rollup as (
    select
      w.id as workflow_id,
      w.status as observed_status,
      w.updated_at,
      case
        when count(s.id) = 0 then 'pending'
        when count(*) filter (where s.status in ('failed', 'dead_letter')) > 0 then 'failed'
        when count(*) filter (where s.status = 'cancelled') = count(s.id) then 'cancelled'
        when count(*) filter (where s.status in ('completed', 'skipped')) = count(s.id) then 'completed'
        when count(*) filter (where s.status in ('enqueued', 'running', 'retry_wait')) > 0 then 'running'
        else 'pending'
      end as expected_status,
      count(s.id)::integer as step_count,
      count(*) filter (where s.status in ('failed', 'dead_letter'))::integer as failed_step_count,
      count(*) filter (where s.status in ('completed', 'skipped'))::integer as completed_step_count
    from public.live_runtime_workflows w
    left join public.live_runtime_workflow_steps s on s.workflow_id = w.id
    group by w.id, w.status, w.updated_at
  )
  insert into public.runtime_reconciliation_findings (
    reconciliation_scan_id, finding_key, finding_type, severity,
    source_component, source_table, source_record_id, workflow_id,
    observed_status, expected_status, observed_at, reference_at,
    evidence, proposed_action_type, action_safe, finding_hash
  )
  select
    v_scan.id,
    'workflow-rollup:' || r.workflow_id::text,
    'workflow_rollup_status_mismatch',
    case when r.expected_status = 'failed' then 'high' else 'medium' end,
    'workflow_orchestration', 'live_runtime_workflows', r.workflow_id,
    r.workflow_id, r.observed_status, r.expected_status, v_now, r.updated_at,
    jsonb_build_object(
      'step_count', r.step_count,
      'failed_step_count', r.failed_step_count,
      'completed_step_count', r.completed_step_count,
      'workflow_updated_at', r.updated_at
    ),
    'reconcile_workflow', false,
    encode(extensions.digest(
      concat_ws('|', 'workflow_rollup_status_mismatch', r.workflow_id::text,
        r.observed_status, r.expected_status, r.updated_at::text), 'sha256'
    ), 'hex')
  from rollup r
  where r.observed_status is distinct from r.expected_status
  order by r.updated_at desc
  limit v_profile.maximum_findings
  on conflict do nothing;

  -- 3. Active runtime jobs that have not changed within the configured interval.
  insert into public.runtime_reconciliation_findings (
    reconciliation_scan_id, finding_key, finding_type, severity,
    source_component, source_table, source_record_id, job_id,
    observed_status, expected_status, observed_at, reference_at,
    evidence, proposed_action_type, action_safe, finding_hash
  )
  select
    v_scan.id,
    'stale-runtime-job:' || j.id::text,
    'stale_runtime_job',
    case when j.status in ('claimed', 'running') then 'high' else 'medium' end,
    'live_runtime', 'live_runtime_jobs', j.id, j.id,
    j.status, 'progress_or_terminal', v_now, j.updated_at,
    jsonb_build_object(
      'job_type', j.job_type,
      'scope_type', j.scope_type,
      'scope_id', j.scope_id,
      'attempt_count', j.attempt_count,
      'max_attempts', j.max_attempts,
      'claimed_by', j.claimed_by,
      'claimed_at', j.claimed_at,
      'updated_at', j.updated_at,
      'stale_interval', v_profile.stale_job_interval
    ),
    case when j.attempt_count >= j.max_attempts then 'mark_job_dead_letter' else 'requeue_job_review' end,
    false,
    encode(extensions.digest(
      concat_ws('|', 'stale_runtime_job', j.id::text, j.status, j.updated_at::text), 'sha256'
    ), 'hex')
  from public.live_runtime_jobs j
  where j.status in ('claimed', 'running', 'retry_wait')
    and j.updated_at < v_scan.scan_cutoff_at - v_profile.stale_job_interval
  order by j.updated_at asc
  limit v_profile.maximum_findings
  on conflict do nothing;

  -- 4. Expired recovery command leases.
  insert into public.runtime_reconciliation_findings (
    reconciliation_scan_id, finding_key, finding_type, severity,
    source_component, source_table, source_record_id, recovery_request_id,
    observed_status, expected_status, observed_at, reference_at,
    evidence, proposed_action_type, action_safe, finding_hash
  )
  select
    v_scan.id,
    'expired-recovery-lease:' || r.id::text,
    'expired_recovery_lease', 'high',
    'workflow_recovery', 'live_runtime_recovery_requests', r.id, r.id,
    r.status, 'requeued_or_terminal', v_now, r.lease_expires_at,
    jsonb_build_object(
      'workflow_instance_id', r.workflow_instance_id,
      'recovery_action', r.recovery_action,
      'claimed_by', r.claimed_by,
      'lease_expires_at', r.lease_expires_at,
      'attempt_count', r.attempt_count,
      'max_attempts', r.max_attempts
    ),
    'release_or_requeue_recovery_lease', false,
    encode(extensions.digest(
      concat_ws('|', 'expired_recovery_lease', r.id::text, r.status,
        r.lease_expires_at::text), 'sha256'
    ), 'hex')
  from public.live_runtime_recovery_requests r
  where r.status in ('claimed', 'running')
    and r.lease_expires_at < v_scan.scan_cutoff_at - v_profile.lease_grace_interval
  order by r.lease_expires_at asc
  limit v_profile.maximum_findings
  on conflict do nothing;

  -- 5. Expired maintenance leases.
  insert into public.runtime_reconciliation_findings (
    reconciliation_scan_id, finding_key, finding_type, severity,
    source_component, source_table, source_record_id, maintenance_run_id,
    observed_status, expected_status, observed_at, reference_at,
    evidence, proposed_action_type, action_safe, finding_hash
  )
  select
    v_scan.id,
    'expired-maintenance-lease:' || m.id::text,
    'expired_maintenance_lease', 'high',
    'maintenance_engine', 'maintenance_runs', m.id, m.id,
    m.status, 'requeued_or_terminal', v_now, m.lease_expires_at,
    jsonb_build_object(
      'policy_key', m.policy_key,
      'worker_id', m.worker_id,
      'lease_expires_at', m.lease_expires_at,
      'heartbeat_at', m.heartbeat_at,
      'attempt_count', m.attempt_count,
      'max_attempts', m.max_attempts
    ),
    'requeue_expired_maintenance_lease', false,
    encode(extensions.digest(
      concat_ws('|', 'expired_maintenance_lease', m.id::text, m.status,
        m.lease_expires_at::text), 'sha256'
    ), 'hex')
  from public.maintenance_runs m
  where m.status = 'running'
    and m.lease_expires_at < v_scan.scan_cutoff_at - v_profile.lease_grace_interval
  order by m.lease_expires_at asc
  limit v_profile.maximum_findings
  on conflict do nothing;

  -- Persist proposed, structurally non-executable actions.
  insert into public.runtime_reconciliation_actions (
    reconciliation_scan_id, reconciliation_finding_id,
    action_type, target_component, target_record_id,
    command_payload, action_hash
  )
  select
    f.reconciliation_scan_id,
    f.id,
    f.proposed_action_type,
    f.source_component,
    f.source_record_id,
    jsonb_build_object(
      'finding_id', f.id,
      'finding_hash', f.finding_hash,
      'source_table', f.source_table,
      'source_record_id', f.source_record_id,
      'execution_enabled', false
    ),
    encode(extensions.digest(
      concat_ws('|', f.finding_hash, f.proposed_action_type, 'execution-disabled'),
      'sha256'
    ), 'hex')
  from public.runtime_reconciliation_findings f
  where f.reconciliation_scan_id = v_scan.id
    and f.proposed_action_type is not null
  on conflict do nothing;

  select
    count(*)::integer,
    count(*) filter (where severity = 'critical')::integer,
    count(*) filter (where severity = 'high')::integer,
    count(*) filter (where severity = 'medium')::integer,
    count(*) filter (where severity = 'low')::integer
  into v_count, v_critical, v_high, v_medium, v_low
  from public.runtime_reconciliation_findings
  where reconciliation_scan_id = v_scan.id;

  select encode(extensions.digest(
    coalesce(string_agg(f.finding_hash, '|' order by f.finding_hash), '') ||
    '|' || v_scan.id::text || '|' || v_scan.scan_cutoff_at::text,
    'sha256'
  ), 'hex')
  into v_hash
  from public.runtime_reconciliation_findings f
  where f.reconciliation_scan_id = v_scan.id;

  update public.runtime_reconciliation_scans
  set status = 'completed',
      completed_at = clock_timestamp(),
      finding_count = v_count,
      critical_count = v_critical,
      high_count = v_high,
      medium_count = v_medium,
      low_count = v_low,
      scan_hash = v_hash,
      scanner_snapshot = jsonb_build_object(
        'scanner_version', scanner_version,
        'profile_key', profile_key,
        'profile_version', profile_version,
        'scan_cutoff_at', scan_cutoff_at,
        'maximum_findings_per_check', v_profile.maximum_findings,
        'auto_action_enabled', false,
        'checks', jsonb_build_array(
          'workflow_step_job_status_mismatch',
          'workflow_rollup_status_mismatch',
          'stale_runtime_job',
          'expired_recovery_lease',
          'expired_maintenance_lease'
        )
      )
  where id = v_scan.id
  returning * into v_scan;

  return v_scan;
exception when others then
  update public.runtime_reconciliation_scans
  set status = 'failed',
      completed_at = clock_timestamp(),
      error_code = sqlstate,
      error_message = sqlerrm,
      error_details = jsonb_build_object('scanner_version', 'runtime-reconciliation-v1')
  where id = p_reconciliation_scan_id
    and status in ('requested', 'running');
  raise;
end;
$$;

comment on function public.build_runtime_reconciliation_scan_rpc(uuid)
is 'Builds an immutable, non-destructive reconciliation scan and proposed-action ledger.';

-- --------------------------------------------------------------------------
-- Finding acknowledgement RPC
-- --------------------------------------------------------------------------

create or replace function public.acknowledge_runtime_reconciliation_finding_rpc(
  p_finding_id uuid,
  p_acknowledged_by uuid,
  p_note text default null
)
returns public.runtime_reconciliation_findings
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_finding public.runtime_reconciliation_findings;
begin
  if p_acknowledged_by is null then
    raise exception using errcode = '22023', message = 'acknowledged_by is required';
  end if;

  update public.runtime_reconciliation_findings
  set acknowledged_at = coalesce(acknowledged_at, clock_timestamp()),
      acknowledged_by = coalesce(acknowledged_by, p_acknowledged_by),
      acknowledgement_note = coalesce(acknowledgement_note, nullif(btrim(p_note), ''))
  where id = p_finding_id
  returning * into v_finding;

  if not found then
    raise exception using errcode = 'P0002', message = 'reconciliation finding not found';
  end if;

  return v_finding;
end;
$$;

comment on function public.acknowledge_runtime_reconciliation_finding_rpc(uuid,uuid,text)
is 'Acknowledges a finding without mutating its evidence or proposed remediation.';

-- --------------------------------------------------------------------------
-- Read models
-- --------------------------------------------------------------------------

create or replace view public.runtime_reconciliation_scan_status_v1 as
select
  s.id as reconciliation_scan_id,
  s.profile_id,
  s.profile_key,
  s.profile_version,
  p.display_name as profile_display_name,
  p.enabled as profile_enabled,
  p.auto_action_enabled,
  s.maintenance_run_id,
  s.status,
  s.idempotency_key,
  s.requested_by,
  s.requested_at,
  s.started_at,
  s.completed_at,
  s.scan_cutoff_at,
  s.scanner_version,
  s.finding_count,
  s.critical_count,
  s.high_count,
  s.medium_count,
  s.low_count,
  s.truncated,
  s.scan_hash,
  s.request_payload,
  s.scanner_snapshot,
  s.error_code,
  s.error_message,
  s.error_details,
  s.correlation_id,
  s.causation_id,
  s.created_at,
  coalesce(a.proposed_action_count, 0) as proposed_action_count,
  coalesce(a.approved_action_count, 0) as approved_action_count,
  coalesce(a.executable_action_count, 0) as executable_action_count
from public.runtime_reconciliation_scans s
join public.runtime_reconciliation_profiles p on p.id = s.profile_id
left join lateral (
  select
    count(*)::integer as proposed_action_count,
    count(*) filter (where action_status = 'approved')::integer as approved_action_count,
    count(*) filter (where execution_enabled)::integer as executable_action_count
  from public.runtime_reconciliation_actions ra
  where ra.reconciliation_scan_id = s.id
) a on true;

comment on view public.runtime_reconciliation_scan_status_v1
is 'Operational read model for reconciliation scan progress, immutable hashes and disabled action counts.';

create or replace view public.runtime_reconciliation_attention_v1 as
select
  f.id as reconciliation_finding_id,
  f.reconciliation_scan_id,
  s.profile_key,
  s.status as scan_status,
  s.scan_hash,
  f.finding_key,
  f.finding_type,
  f.severity,
  f.source_component,
  f.source_table,
  f.source_record_id,
  f.workflow_id,
  f.workflow_step_id,
  f.job_id,
  f.recovery_request_id,
  f.maintenance_run_id,
  f.observed_status,
  f.expected_status,
  f.observed_at,
  f.reference_at,
  f.evidence,
  f.proposed_action_type,
  f.action_safe,
  f.finding_hash,
  f.acknowledged_at,
  f.acknowledged_by,
  f.acknowledgement_note,
  a.id as proposed_action_id,
  a.action_status,
  a.execution_enabled,
  case f.severity
    when 'critical' then 1
    when 'high' then 2
    when 'medium' then 3
    when 'low' then 4
    else 5
  end as attention_rank
from public.runtime_reconciliation_findings f
join public.runtime_reconciliation_scans s
  on s.id = f.reconciliation_scan_id
left join public.runtime_reconciliation_actions a
  on a.reconciliation_finding_id = f.id
where f.acknowledged_at is null;

comment on view public.runtime_reconciliation_attention_v1
is 'Unacknowledged runtime reconciliation findings ordered by operational severity.';

-- --------------------------------------------------------------------------
-- RLS and policies
-- --------------------------------------------------------------------------

alter table public.runtime_reconciliation_profiles enable row level security;
alter table public.runtime_reconciliation_scans enable row level security;
alter table public.runtime_reconciliation_findings enable row level security;
alter table public.runtime_reconciliation_actions enable row level security;

create policy runtime_reconciliation_profiles_service_role_all
on public.runtime_reconciliation_profiles
for all to service_role using (true) with check (true);

create policy runtime_reconciliation_scans_service_role_all
on public.runtime_reconciliation_scans
for all to service_role using (true) with check (true);

create policy runtime_reconciliation_findings_service_role_all
on public.runtime_reconciliation_findings
for all to service_role using (true) with check (true);

create policy runtime_reconciliation_actions_service_role_all
on public.runtime_reconciliation_actions
for all to service_role using (true) with check (true);

-- --------------------------------------------------------------------------
-- Privileges, including 069 view hardening
-- --------------------------------------------------------------------------

revoke all on public.runtime_reconciliation_profiles from public, anon, authenticated;
revoke all on public.runtime_reconciliation_scans from public, anon, authenticated;
revoke all on public.runtime_reconciliation_findings from public, anon, authenticated;
revoke all on public.runtime_reconciliation_actions from public, anon, authenticated;

grant select, insert, update on public.runtime_reconciliation_profiles to service_role;
grant select, insert, update on public.runtime_reconciliation_scans to service_role;
grant select, insert, update on public.runtime_reconciliation_findings to service_role;
grant select, insert, update on public.runtime_reconciliation_actions to service_role;

revoke all on public.runtime_reconciliation_scan_status_v1 from public, anon, authenticated, service_role;
revoke all on public.runtime_reconciliation_attention_v1 from public, anon, authenticated, service_role;
grant select on public.runtime_reconciliation_scan_status_v1 to service_role;
grant select on public.runtime_reconciliation_attention_v1 to service_role;

-- Harden the read models introduced by migration 069 to SELECT-only.
revoke all on public.retention_target_registry_v1 from public, anon, authenticated, service_role;
revoke all on public.retention_plan_status_v1 from public, anon, authenticated, service_role;
revoke all on public.retention_plan_attention_v1 from public, anon, authenticated, service_role;
grant select on public.retention_target_registry_v1 to service_role;
grant select on public.retention_plan_status_v1 to service_role;
grant select on public.retention_plan_attention_v1 to service_role;

revoke all on function public.request_runtime_reconciliation_scan_rpc(text,text,uuid,uuid,jsonb,uuid,uuid)
  from public, anon, authenticated;
revoke all on function public.build_runtime_reconciliation_scan_rpc(uuid)
  from public, anon, authenticated;
revoke all on function public.acknowledge_runtime_reconciliation_finding_rpc(uuid,uuid,text)
  from public, anon, authenticated;

grant execute on function public.request_runtime_reconciliation_scan_rpc(text,text,uuid,uuid,jsonb,uuid,uuid)
  to service_role;
grant execute on function public.build_runtime_reconciliation_scan_rpc(uuid)
  to service_role;
grant execute on function public.acknowledge_runtime_reconciliation_finding_rpc(uuid,uuid,text)
  to service_role;

-- --------------------------------------------------------------------------
-- Disabled seed policy and profile
-- --------------------------------------------------------------------------

insert into public.maintenance_policies (
  policy_key, policy_version, display_name, description,
  operation_type, target_scope, batch_size, max_attempts,
  timeout_interval, dry_run_default, destructive, enabled, policy_config
)
values (
  'runtime_reconciliation_scan', 1,
  'Runtime Reconciliation Scan',
  'Non-destructive scan of workflow, job, recovery and maintenance consistency.',
  'reconciliation_scan', 'runtime', 1000, 3,
  interval '15 minutes', true, false, false,
  jsonb_build_object(
    'scanner_version', 'runtime-reconciliation-v1',
    'auto_action_enabled', false,
    'execution_enabled', false
  )
)
on conflict (policy_key, policy_version) do nothing;

insert into public.runtime_reconciliation_profiles (
  profile_key, profile_version, display_name, description,
  enabled, auto_action_enabled, stale_job_interval,
  stale_workflow_interval, lease_grace_interval,
  maximum_findings, check_config
)
values (
  'runtime_core_consistency', 1,
  'Runtime Core Consistency',
  'Workflow, job and lease consistency checks. Disabled by default.',
  false, false, interval '15 minutes', interval '30 minutes',
  interval '2 minutes', 1000,
  jsonb_build_object(
    'workflow_step_job_status_mismatch', true,
    'workflow_rollup_status_mismatch', true,
    'stale_runtime_job', true,
    'expired_recovery_lease', true,
    'expired_maintenance_lease', true,
    'execution_enabled', false
  )
)
on conflict (profile_key, profile_version) do nothing;

-- --------------------------------------------------------------------------
-- Installation verification
-- --------------------------------------------------------------------------

do $$
declare
  v_missing text[];
begin
  select array_agg(x.object_name order by x.object_name)
  into v_missing
  from (
    values
      ('runtime_reconciliation_profiles'),
      ('runtime_reconciliation_scans'),
      ('runtime_reconciliation_findings'),
      ('runtime_reconciliation_actions'),
      ('runtime_reconciliation_scan_status_v1'),
      ('runtime_reconciliation_attention_v1')
  ) as x(object_name)
  where to_regclass('public.' || x.object_name) is null;

  if v_missing is not null then
    raise exception 'Runtime Reconciliation migration incomplete. Missing: %', v_missing;
  end if;

  if to_regprocedure('public.request_runtime_reconciliation_scan_rpc(text,text,uuid,uuid,jsonb,uuid,uuid)') is null then
    raise exception 'Missing request_runtime_reconciliation_scan_rpc';
  end if;
  if to_regprocedure('public.build_runtime_reconciliation_scan_rpc(uuid)') is null then
    raise exception 'Missing build_runtime_reconciliation_scan_rpc';
  end if;
  if to_regprocedure('public.acknowledge_runtime_reconciliation_finding_rpc(uuid,uuid,text)') is null then
    raise exception 'Missing acknowledge_runtime_reconciliation_finding_rpc';
  end if;
end;
$$;

commit;
