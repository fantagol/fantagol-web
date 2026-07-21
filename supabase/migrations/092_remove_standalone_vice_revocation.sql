-- ============================================================================
-- FANTAGOL
-- Migration 092
-- Remove Standalone Vice Revocation
--
-- Governance rule:
--   A Vice is never revoked leaving a governance vacancy.
--   The Admin may only assign/change the Vice through:
--
--     public.assign_league_vice_rpc(
--       target_league_id uuid,
--       target_member_id uuid
--     )
--
-- That RPC already performs the contextual switch atomically:
--   current Vice -> member
--   selected active member -> Vice
--
-- The historical event type "vice_revoked" is intentionally preserved because
-- it may already exist in the administration ledger and remains valid history.
-- ============================================================================

begin;

-- Remove every executable privilege before dropping the obsolete public
-- contract. The explicit revokes also protect environments with grants added
-- after the original migration.
revoke all on function public.revoke_league_vice_rpc(uuid)
  from public;

revoke all on function public.revoke_league_vice_rpc(uuid)
  from anon;

revoke all on function public.revoke_league_vice_rpc(uuid)
  from authenticated;

revoke all on function public.revoke_league_vice_rpc(uuid)
  from service_role;

-- DROP without CASCADE is deliberate. If an unexpected database object depends
-- on this obsolete RPC, the migration must stop instead of deleting that object.
drop function public.revoke_league_vice_rpc(uuid);

-- Document the surviving governance contract.
comment on function public.assign_league_vice_rpc(uuid, uuid) is
  'Atomically assigns or changes the active League Vice. Any current active Vice is returned to member before the selected active member becomes Vice. Standalone Vice revocation is not permitted.';

-- Ask PostgREST/Supabase to refresh the exposed schema contract immediately.
notify pgrst, 'reload schema';

commit;
