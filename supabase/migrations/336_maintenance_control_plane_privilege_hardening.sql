-- ============================================================================
-- MIGRATION 336
-- Maintenance control-plane privilege hardening.
--
-- Removes direct service_role mutation authority from maintenance_runs,
-- maintenance_command_outbox and maintenance_tasks.
--
-- Canonical SECURITY DEFINER RPCs remain the only supported mutation path.
-- SELECT is intentionally preserved.
--
-- No maintenance policy, retention target, plan, approval or execution is
-- activated here.
-- ============================================================================

revoke insert, update, delete, truncate
on table public.maintenance_runs
from service_role;

revoke insert, update, delete, truncate
on table public.maintenance_command_outbox
from service_role;

revoke insert, update, delete, truncate
on table public.maintenance_tasks
from service_role;