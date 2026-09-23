-- ============================================================================
-- MIGRATION 335
-- Retention plan / item / receipt privilege hardening.
--
-- Closes direct mutation bypasses while preserving canonical SECURITY DEFINER
-- RPC authorities.
--
-- No retention target, policy, plan, approval or execution is activated here.
-- ============================================================================

revoke insert, update, delete, truncate
on table public.retention_plans
from service_role;

revoke insert, update, delete, truncate
on table public.retention_plan_items
from service_role;

revoke truncate
on table public.retention_execution_receipts
from anon;

revoke truncate
on table public.retention_execution_receipts
from authenticated;

revoke truncate
on table public.retention_execution_receipts
from service_role;