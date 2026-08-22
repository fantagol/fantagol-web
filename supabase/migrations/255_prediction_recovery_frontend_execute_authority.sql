begin;

-- ============================================================================
-- FANTAGOL - MIGRATION 255
-- PREDICTION RECOVERY FRONTEND EXECUTE AUTHORITY
--
-- Purpose:
--   Allow an authenticated client to invoke the existing
--   open_missing_predictions_recovery_rpc(uuid,text).
--
-- Security remains server-authoritative:
--   * auth.uid() binds caller identity;
--   * caller must be an ACTIVE league Admin;
--   * member targets are derived automatically;
--   * match targets are derived automatically;
--   * complete official grids remain protected;
--   * active live phases reject opening;
--   * the RPC remains SECURITY DEFINER;
--   * anon remains denied.
--
-- No Recovery data is created by this migration.
-- ============================================================================


revoke all on function
    public.open_missing_predictions_recovery_rpc(uuid,text)
from public;

revoke all on function
    public.open_missing_predictions_recovery_rpc(uuid,text)
from anon;


grant execute on function
    public.open_missing_predictions_recovery_rpc(uuid,text)
to authenticated;


grant execute on function
    public.open_missing_predictions_recovery_rpc(uuid,text)
to service_role;


do $migration255$
begin

    if has_function_privilege(
        'anon',
        'public.open_missing_predictions_recovery_rpc(uuid,text)',
        'EXECUTE'
    ) then
        raise exception
            'MIGRATION_255_ANON_EXECUTE_SURVIVED';
    end if;


    if not has_function_privilege(
        'authenticated',
        'public.open_missing_predictions_recovery_rpc(uuid,text)',
        'EXECUTE'
    ) then
        raise exception
            'MIGRATION_255_AUTHENTICATED_EXECUTE_MISSING';
    end if;


    if not has_function_privilege(
        'service_role',
        'public.open_missing_predictions_recovery_rpc(uuid,text)',
        'EXECUTE'
    ) then
        raise exception
            'MIGRATION_255_SERVICE_ROLE_EXECUTE_MISSING';
    end if;

end;
$migration255$;

commit;