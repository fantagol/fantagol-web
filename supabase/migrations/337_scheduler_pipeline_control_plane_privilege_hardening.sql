-- ============================================================================
-- MIGRATION 337
-- Scheduler / pipeline control-plane privilege hardening.
--
-- Removes direct service_role mutation authority from the scheduler and
-- runtime-maintenance pipeline control-plane tables.
--
-- Canonical SECURITY DEFINER RPCs remain the only supported mutation path.
-- SELECT is intentionally preserved.
--
-- No scheduler profile, schedule, pipeline profile, retention policy,
-- retention plan, approval or execution is activated here.
-- ============================================================================

revoke insert, update, delete, truncate
on table public.maintenance_scheduler_profiles
from service_role;

revoke insert, update, delete, truncate
on table public.maintenance_schedules
from service_role;

revoke insert, update, delete, truncate
on table public.maintenance_scheduler_ticks
from service_role;

revoke insert, update, delete, truncate
on table public.maintenance_scheduler_dispatches
from service_role;

revoke insert, update, delete, truncate
on table public.runtime_maintenance_pipeline_profiles
from service_role;

revoke insert, update, delete, truncate
on table public.runtime_maintenance_pipeline_runs
from service_role;

revoke insert, update, delete, truncate
on table public.runtime_maintenance_pipeline_stages
from service_role;

revoke insert, update, delete, truncate
on table public.runtime_maintenance_pipeline_handoffs
from service_role;