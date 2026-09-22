-- ============================================================================
-- MIGRATION 329
-- Retention authority table privilege hardening.
--
-- Purpose:
--   - remove direct service_role writes from retention authority tables
--   - preserve read access
--   - preserve canonical SECURITY DEFINER RPC authority
--
-- Safety:
--   - no retention target/policy activation
--   - no retention plan/item/receipt mutation
-- ============================================================================

revoke insert, update, delete, truncate, references, trigger
on table public.retention_targets
from service_role;

revoke insert, update, delete, truncate, references, trigger
on table public.maintenance_policies
from service_role;