-- ============================================================================
-- FANTAGOL
-- Migration 155
-- Voluntary League Admin Transfer Contract
--
-- Adds one atomic Governance Engine primitive:
--
--   transfer_league_admin_rpc(...)
--
-- The authenticated active Admin explicitly selects an eligible successor.
-- The outgoing Admin remains in the League as an active ordinary member.
--
-- The responsible Admin-exit use case is intentionally NOT implemented here.
-- It must be orchestrated as a workflow composed of:
--
--   1. transfer_league_admin_rpc(...)
--   2. leave_league_rpc(...)
--
-- This migration deliberately does NOT modify:
--   * automatic inactivity evaluation;
--   * two-missed-round succession;
--   * Vice-first automatic succession;
--   * ranking/seniority fallback;
--   * leave_league_rpc(uuid);
--   * resign_league_admin_rpc(uuid).
-- ============================================================================

begin;

-- Remove only obsolete draft contracts if they were ever created outside the
-- canonical migration flow. The intended precondition is that migration 155
-- has not yet been applied.
drop function if exists public.transfer_admin_and_leave_league_rpc(uuid, uuid);
drop function if exists public.transfer_league_admin_internal(uuid, uuid, boolean);

create or replace function public.transfer_league_admin_rpc(
  target_league_id uuid,
  successor_member_id uuid
)
returns table(
  former_admin_member_id uuid,
  new_admin_member_id uuid,
  former_admin_status text
)
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_user_id uuid := auth.uid();
  v_admin public.league_members%rowtype;
  v_successor public.league_members%rowtype;
begin
  if v_user_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'AUTH_REQUIRED';
  end if;

  if target_league_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_ID_REQUIRED';
  end if;

  if successor_member_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'SUCCESSOR_MEMBER_REQUIRED';
  end if;

  /*
   * Serialize governance changes for the target League.
   */
  perform 1
  from public.leagues l
  where l.id = target_league_id
    and l.status = 'active'
    and l.lifecycle_status not in ('completed', 'archived')
  for update;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_NOT_EDITABLE';
  end if;

  /*
   * The caller must be the current active Admin.
   */
  select lm.*
  into v_admin
  from public.league_members lm
  where lm.league_id = target_league_id
    and lm.user_id = v_user_id
    and lm.role = 'admin'
    and lm.status = 'active'
  for update;

  if v_admin.id is null then
    raise exception using
      errcode = 'P0001',
      message = 'ACTIVE_ADMIN_REQUIRED';
  end if;

  if successor_member_id = v_admin.id then
    raise exception using
      errcode = 'P0001',
      message = 'SUCCESSOR_MUST_DIFFER_FROM_ADMIN';
  end if;

  /*
   * The successor must be another active authenticated League member.
   */
  select lm.*
  into v_successor
  from public.league_members lm
  where lm.id = successor_member_id
    and lm.league_id = target_league_id
    and lm.status = 'active'
    and lm.role in ('member', 'vice')
    and lm.user_id is not null
    and exists (
      select 1
      from auth.users au
      where au.id = lm.user_id
    )
  for update;

  if v_successor.id is null then
    raise exception using
      errcode = 'P0001',
      message = 'ELIGIBLE_ACTIVE_SUCCESSOR_REQUIRED';
  end if;

  /*
   * Atomic role transition.
   *
   * The outgoing Admin remains active in the League and becomes an ordinary
   * member. If the successor was the Vice, the Vice role becomes vacant.
   * If the successor was an ordinary member, the existing Vice remains Vice.
   */
  update public.league_members
  set role = 'member'
  where id = v_admin.id;

  update public.league_members
  set role = 'admin'
  where id = v_successor.id;

  /*
   * Keep the canonical League owner aligned with the active Admin.
   */
  update public.leagues
  set owner_id = v_successor.user_id
  where id = target_league_id;

  /*
   * Start a fresh governance evaluation cycle for the newly appointed Admin.
   * Historical governance events remain immutable in their event ledger.
   */
  insert into public.league_governance_states (
    league_id,
    current_admin_member_id,
    consecutive_admin_missed_rounds,
    warning_issued_at,
    succession_completed_at,
    succession_blocked_at,
    succession_blocked_reason
  )
  values (
    target_league_id,
    v_successor.id,
    0,
    null,
    null,
    null,
    null
  )
  on conflict (league_id) do update
  set
    current_admin_member_id = excluded.current_admin_member_id,
    consecutive_admin_missed_rounds = 0,
    warning_issued_at = null,
    succession_completed_at = null,
    succession_blocked_at = null,
    succession_blocked_reason = null;

  /*
   * Reuse the certified Admin-governance event contract. The payload
   * distinguishes this voluntary transfer from inactivity succession and from
   * an Admin who subsequently leaves the League.
   */
  perform public.write_league_admin_event(
    target_league_id,
    v_admin.id,
    v_user_id,
    'member',
    'admin_resigned',
    v_admin.id,
    null,
    jsonb_build_object(
      'new_admin_member_id', v_successor.id,
      'new_admin_user_id', v_successor.user_id,
      'successor_previous_role', v_successor.role,
      'former_admin_new_role', 'member',
      'former_admin_new_status', 'active',
      'reason', 'voluntary_admin_transfer',
      'outgoing_admin_leaves', false,
      'automatic_succession', false,
      'voluntary_transfer', true
    )
  );

  return query
  select
    v_admin.id,
    v_successor.id,
    'active'::text;
end;
$function$;

revoke all
on function public.transfer_league_admin_rpc(uuid, uuid)
from public, anon, service_role;

grant execute
on function public.transfer_league_admin_rpc(uuid, uuid)
to authenticated;

comment on function public.transfer_league_admin_rpc(uuid, uuid) is
  'Atomically transfers League administration to an explicitly selected eligible active member. The outgoing authenticated Admin remains an active ordinary member.';


-- ============================================================================
-- Contract certification
-- ============================================================================

do $verification$
declare
  v_definition text;
begin
  select pg_get_functiondef(
    'public.transfer_league_admin_rpc(uuid,uuid)'::regprocedure
  )
  into v_definition;

  if position('SUCCESSOR_MEMBER_REQUIRED' in v_definition) = 0 then
    raise exception
      'VOLUNTARY_ADMIN_TRANSFER_SUCCESSOR_GUARD_MISSING';
  end if;

  if position('SUCCESSOR_MUST_DIFFER_FROM_ADMIN' in v_definition) = 0 then
    raise exception
      'VOLUNTARY_ADMIN_TRANSFER_SELF_SUCCESSOR_GUARD_MISSING';
  end if;

  if position('ELIGIBLE_ACTIVE_SUCCESSOR_REQUIRED' in v_definition) = 0 then
    raise exception
      'VOLUNTARY_ADMIN_TRANSFER_ELIGIBILITY_GUARD_MISSING';
  end if;

  if position('set role = ''member''' in v_definition) = 0 then
    raise exception
      'VOLUNTARY_ADMIN_TRANSFER_FORMER_ADMIN_DEMOTION_MISSING';
  end if;

  if position('set role = ''admin''' in v_definition) = 0 then
    raise exception
      'VOLUNTARY_ADMIN_TRANSFER_SUCCESSOR_PROMOTION_MISSING';
  end if;

  if position('owner_id = v_successor.user_id' in v_definition) = 0 then
    raise exception
      'VOLUNTARY_ADMIN_TRANSFER_OWNER_SYNC_MISSING';
  end if;

  if position(
    'current_admin_member_id = excluded.current_admin_member_id'
    in v_definition
  ) = 0 then
    raise exception
      'VOLUNTARY_ADMIN_TRANSFER_GOVERNANCE_SYNC_MISSING';
  end if;

  if position('voluntary_admin_transfer' in v_definition) = 0 then
    raise exception
      'VOLUNTARY_ADMIN_TRANSFER_AUDIT_REASON_MISSING';
  end if;

  if position('outgoing_admin_leaves'', false' in v_definition) = 0 then
    raise exception
      'VOLUNTARY_ADMIN_TRANSFER_NON_EXIT_MARKER_MISSING';
  end if;

  if position('status = ''left''' in v_definition) > 0 then
    raise exception
      'VOLUNTARY_ADMIN_TRANSFER_MUST_NOT_LEAVE_LEAGUE';
  end if;

  if to_regprocedure(
    'public.transfer_admin_and_leave_league_rpc(uuid,uuid)'
  ) is not null then
    raise exception
      'OBSOLETE_COMBINED_ADMIN_EXIT_RPC_PRESENT';
  end if;

  if to_regprocedure(
    'public.transfer_league_admin_internal(uuid,uuid,boolean)'
  ) is not null then
    raise exception
      'OBSOLETE_BOOLEAN_ADMIN_TRANSFER_HELPER_PRESENT';
  end if;

  if not has_function_privilege(
    'authenticated',
    'public.transfer_league_admin_rpc(uuid,uuid)',
    'EXECUTE'
  ) then
    raise exception
      'VOLUNTARY_ADMIN_TRANSFER_AUTHENTICATED_GRANT_MISSING';
  end if;

  if has_function_privilege(
    'anon',
    'public.transfer_league_admin_rpc(uuid,uuid)',
    'EXECUTE'
  ) then
    raise exception
      'VOLUNTARY_ADMIN_TRANSFER_ANON_GRANT_FORBIDDEN';
  end if;
end;
$verification$;

notify pgrst, 'reload schema';

commit;

\echo ''
\echo 'MILESTONE_12_9_5_12_VOLUNTARY_ADMIN_TRANSFER_CONTRACT_READY'
