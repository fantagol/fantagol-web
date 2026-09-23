-- ============================================================================
-- MIGRATION 339
-- Retention schedule proposal activation.
--
-- Enables only the canonical retention-planner-core schedule.
--
-- The scheduler profile remains disabled.
-- automatic_dispatch_enabled remains false by structural constraint.
-- The runtime maintenance pipeline remains disabled.
-- The retention_planner maintenance policy remains disabled.
-- This migration does not request, approve or execute retention.
-- ============================================================================

update public.maintenance_schedules
set
  enabled = true,
  last_due_at = null,
  next_due_at = clock_timestamp()
where schedule_key = 'retention-planner-core'
  and target_engine = 'retention'
  and retired_at is null;