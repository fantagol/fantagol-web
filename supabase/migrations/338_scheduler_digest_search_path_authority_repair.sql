-- ============================================================================
-- MIGRATION 338
-- Scheduler digest search_path authority repair.
--
-- build_maintenance_scheduler_tick_rpc uses digest(), which is installed in
-- schema extensions. The legacy function search_path omitted that schema.
--
-- This migration changes only the function-local search_path. The function
-- body, scheduler configuration, schedules and execution semantics are
-- unchanged.
-- ============================================================================

alter function public.build_maintenance_scheduler_tick_rpc(
  uuid,
  timestamp with time zone
)
set search_path = pg_catalog, public, extensions;