-- ============================================================================
-- MIGRATION 327
-- Retention receipt append-only trigger function privilege hardening.
--
-- Purpose:
--   - remove unnecessary PUBLIC EXECUTE privilege from the receipt guard
--   - preserve trigger execution and all M326/M325 authority
--
-- Safety:
--   - no retention target/policy activation
--   - no retention plan/item/receipt mutation
-- ============================================================================

revoke all on function public.protect_retention_execution_receipt_append_only()
from public;