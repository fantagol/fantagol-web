-- FANTAGOL MIGRATION 300
-- Round timing reconcile runtime ACL repair.
--
-- Root cause:
--   Migration 273 introduced reconcile_fantagol_round_timing_internal(uuid)
--   and the Live Runtime refresh-round handler calls it after kickoff changes,
--   but service_role lacks EXECUTE on the function.
--
-- Contract:
--   - grant EXECUTE only to service_role (postgres owner remains intact);
--   - keep public / anon / authenticated denied;
--   - no data mutation in this migration;
--   - one-shot historical G3 reconciliation is executed separately by the
--     controlled R78 production repair runner.

grant execute
on function public.reconcile_fantagol_round_timing_internal(uuid)
to service_role;

do $$
begin
  if not has_function_privilege(
    'service_role',
    'public.reconcile_fantagol_round_timing_internal(uuid)',
    'EXECUTE'
  ) then
    raise exception 'M300_SERVICE_ROLE_EXECUTE_ASSERTION_FAILED';
  end if;

  if has_function_privilege(
    'anon',
    'public.reconcile_fantagol_round_timing_internal(uuid)',
    'EXECUTE'
  ) then
    raise exception 'M300_ANON_EXECUTE_MUST_REMAIN_DENIED';
  end if;

  if has_function_privilege(
    'authenticated',
    'public.reconcile_fantagol_round_timing_internal(uuid)',
    'EXECUTE'
  ) then
    raise exception 'M300_AUTHENTICATED_EXECUTE_MUST_REMAIN_DENIED';
  end if;
end;
$$;

comment on function public.reconcile_fantagol_round_timing_internal(uuid) is
'Canonical pre-live round timing reconciliation. Runtime service_role EXECUTE restored by Migration 300 after production refresh_round jobs exposed the missing ACL; public, anon and authenticated remain denied.';