-- ============================================================================
-- FantaGol
-- Migration 069: Retention Read Model Contract Hotfix
-- Milestone 7.4.2 hardening
--
-- Purpose
--   Stabilize the operational read contract exposed by the Retention Planner
--   without renaming physical columns or changing retention data.
--
-- Safety contract
--   * No application data is modified or deleted.
--   * No physical retention column is renamed.
--   * Existing 068 planner RPC signatures remain unchanged.
--   * Compatibility aliases are exposed only through versioned views.
-- ============================================================================

begin;

-- --------------------------------------------------------------------------
-- Versioned target registry read model
-- --------------------------------------------------------------------------

create or replace view public.retention_target_registry_v1
with (security_invoker = true)
as
select
  rt.id as retention_target_id,
  rt.target_key,
  rt.target_version,
  rt.display_name,
  rt.description,

  -- Canonical physical names.
  rt.target_schema,
  rt.target_table,
  rt.identity_column,
  rt.timestamp_column,
  rt.status_column,
  rt.terminal_statuses,
  rt.additional_predicate_sql,
  rt.default_retention_interval,
  rt.default_batch_size,
  rt.maximum_batch_size,
  rt.dependency_class,
  rt.planner_enabled,
  rt.execution_enabled,
  rt.destructive,
  rt.target_config,
  rt.created_by,
  rt.created_at,
  rt.updated_at,
  rt.retired_at,

  -- Stable compatibility aliases used by maintenance/operator tooling.
  rt.target_schema as source_schema,
  rt.target_table as source_table,
  rt.default_retention_interval as retention_interval,
  rt.default_batch_size as batch_size,
  rt.maximum_batch_size as max_batch_size,
  rt.planner_enabled as enabled,

  (rt.retired_at is null) as active,
  (
    rt.retired_at is null
    and rt.planner_enabled
  ) as planning_available,
  (
    rt.retired_at is null
    and rt.planner_enabled
    and rt.execution_enabled
  ) as execution_available
from public.retention_targets rt;

comment on view public.retention_target_registry_v1
is 'Stable target-registry projection with canonical retention columns and compatibility aliases for operator tooling.';

-- --------------------------------------------------------------------------
-- Replace existing dependent read models safely
-- --------------------------------------------------------------------------

-- PostgreSQL does not allow CREATE OR REPLACE VIEW to reorder or rename
-- existing output columns. Drop the dependent attention view first, then the
-- status view; both are recreated below in the same transaction.
drop view if exists public.retention_plan_attention_v1;
drop view if exists public.retention_plan_status_v1;

-- --------------------------------------------------------------------------
-- Stable retention plan operational contract
-- --------------------------------------------------------------------------

create or replace view public.retention_plan_status_v1
with (security_invoker = true)
as
select
  rp.id as retention_plan_id,
  rp.maintenance_run_id,
  rp.target_id as retention_target_id,
  rp.target_key,
  rp.target_version,
  rt.display_name as target_display_name,

  -- Canonical target definition.
  rt.target_schema,
  rt.target_table,
  rt.identity_column,
  rt.timestamp_column,
  rt.status_column,
  rt.terminal_statuses,
  rt.dependency_class,
  rt.planner_enabled,
  rt.execution_enabled,

  -- Compatibility target aliases.
  rt.target_schema as source_schema,
  rt.target_table as source_table,
  rt.planner_enabled as target_enabled,

  -- Plan lifecycle.
  rp.status,
  rp.dry_run,
  rp.cutoff_at,
  rp.retention_interval,
  rp.requested_batch_size,
  rp.candidate_count,
  rp.truncated,
  rp.candidate_min_timestamp,
  rp.candidate_max_timestamp,
  rp.planner_version,
  rp.plan_hash,
  rp.planner_snapshot,

  -- Stable lifecycle timestamps.
  rp.created_at as requested_at,
  rp.created_at,
  rp.generated_at,
  rp.approved_at,
  rp.approved_by,
  rp.approval_reason,
  rp.cancelled_at,
  rp.cancelled_by,
  rp.cancellation_reason,
  case
    when rp.status = 'approved' then rp.approved_at
    when rp.status = 'cancelled' then rp.cancelled_at
    when rp.status = 'expired' then coalesce(rp.cancelled_at, mr.completed_at)
    else null
  end as completed_at,

  -- Parent maintenance-run state.
  mr.status as maintenance_run_status,
  mr.requested_at as maintenance_requested_at,
  mr.scheduled_for as maintenance_scheduled_for,
  mr.started_at as maintenance_started_at,
  mr.completed_at as maintenance_completed_at,
  mr.worker_id,
  mr.attempt_count as maintenance_attempt_count,
  mr.max_attempts as maintenance_max_attempts,
  mr.lease_expires_at as maintenance_lease_expires_at,
  mr.correlation_id,
  mr.causation_id,
  mr.error_code,
  mr.error_message
from public.retention_plans rp
join public.retention_targets rt
  on rt.id = rp.target_id
join public.maintenance_runs mr
  on mr.id = rp.maintenance_run_id;

comment on view public.retention_plan_status_v1
is 'Stable operational retention-plan contract with requested/completed timestamps, target aliases and parent maintenance-run state.';

-- --------------------------------------------------------------------------
-- Attention projection over the stabilized contract
-- --------------------------------------------------------------------------

create or replace view public.retention_plan_attention_v1
with (security_invoker = true)
as
select
  s.*,
  case
    when s.maintenance_run_status = 'failed'
      then 'maintenance_run_failed'
    when s.maintenance_run_status = 'expired'
      then 'maintenance_run_expired'
    when s.status = 'generated'
     and s.generated_at < clock_timestamp() - interval '24 hours'
      then 'generated_plan_awaiting_decision'
    when s.status = 'approved'
     and s.execution_enabled = false
      then 'approved_plan_execution_disabled'
    when s.truncated
      then 'candidate_batch_truncated'
    else 'review_required'
  end as attention_reason,
  case
    when s.maintenance_run_status in ('failed', 'expired') then 'critical'
    when s.status = 'generated'
     and s.generated_at < clock_timestamp() - interval '24 hours' then 'warning'
    when s.status = 'approved'
     and s.execution_enabled = false then 'warning'
    when s.truncated then 'info'
    else 'info'
  end as attention_severity,
  coalesce(
    s.maintenance_completed_at,
    s.completed_at,
    s.generated_at,
    s.requested_at
  ) as attention_reference_at
from public.retention_plan_status_v1 s
where s.maintenance_run_status in ('failed', 'expired')
   or (
     s.status = 'generated'
     and s.generated_at < clock_timestamp() - interval '24 hours'
   )
   or (
     s.status = 'approved'
     and s.execution_enabled = false
   )
   or s.truncated;

comment on view public.retention_plan_attention_v1
is 'Retention plans requiring attention, exposed through the stable operational contract with severity and reference timestamp.';

-- --------------------------------------------------------------------------
-- Privileges
-- --------------------------------------------------------------------------

revoke all on table public.retention_target_registry_v1
  from public, anon, authenticated;
revoke all on table public.retention_plan_status_v1
  from public, anon, authenticated;
revoke all on table public.retention_plan_attention_v1
  from public, anon, authenticated;

grant select on table public.retention_target_registry_v1
  to service_role;
grant select on table public.retention_plan_status_v1
  to service_role;
grant select on table public.retention_plan_attention_v1
  to service_role;

commit;
