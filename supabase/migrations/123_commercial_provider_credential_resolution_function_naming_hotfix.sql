-- =============================================================================
-- FANTAGOL
-- Migration: 123_commercial_provider_credential_resolution_function_naming_hotfix.sql
-- Milestone: Commercial Platform - Credential Vault Governance
--
-- Purpose:
--   Replace the PostgreSQL-truncated function identifier created by migration 122
--   with an explicit, stable name below the 63-byte identifier limit.
--
-- Previous persisted name:
--   record_blocked_commercial_provider_credential_resolution_intern
--
-- New canonical name:
--   record_blocked_provider_credential_resolution_internal
--
-- Scope:
--   - rename only;
--   - preserve function body and signature;
--   - preserve SECURITY DEFINER and search_path;
--   - reassert privileges;
--   - no data mutation.
-- =============================================================================

\set ON_ERROR_STOP on

begin;

do $$
declare
  v_old regprocedure;
  v_new regprocedure;
begin
  v_old :=
    to_regprocedure(
      'public.record_blocked_commercial_provider_credential_resolution_intern(uuid,text,text)'
    );

  v_new :=
    to_regprocedure(
      'public.record_blocked_provider_credential_resolution_internal(uuid,text,text)'
    );

  if v_old is null and v_new is null then
    raise exception
      'MIGRATION_123_TARGET_FUNCTION_NOT_FOUND';
  end if;

  if v_old is not null and v_new is not null then
    raise exception
      'MIGRATION_123_AMBIGUOUS_FUNCTION_STATE';
  end if;
end
$$;

do $$
begin
  if to_regprocedure(
    'public.record_blocked_commercial_provider_credential_resolution_intern(uuid,text,text)'
  ) is not null then
    execute
      'alter function public.record_blocked_commercial_provider_credential_resolution_intern(uuid,text,text) ' ||
      'rename to record_blocked_provider_credential_resolution_internal';
  end if;
end
$$;

revoke all on function
  public.record_blocked_provider_credential_resolution_internal(uuid,text,text)
from public, anon, authenticated;

grant execute on function
  public.record_blocked_provider_credential_resolution_internal(uuid,text,text)
to service_role;

do $$
declare
  v_function_oid oid;
  v_proname text;
  v_identity_arguments text;
  v_security_definer boolean;
  v_config text[];
  v_service_role_has_execute boolean;
  v_public_has_execute boolean;
  v_anon_has_execute boolean;
  v_authenticated_has_execute boolean;
begin
  select
    p.oid,
    p.proname,
    pg_get_function_identity_arguments(p.oid),
    p.prosecdef,
    p.proconfig
  into strict
    v_function_oid,
    v_proname,
    v_identity_arguments,
    v_security_definer,
    v_config
  from pg_proc p
  join pg_namespace n
    on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname = 'record_blocked_provider_credential_resolution_internal'
    and pg_get_function_identity_arguments(p.oid) = 'p_access_request_id uuid, p_recorded_by text, p_reason text';

  if v_proname <> 'record_blocked_provider_credential_resolution_internal' then
    raise exception 'MIGRATION_123_CANONICAL_NAME_ASSERTION_FAILED';
  end if;

  if length(v_proname) > 63 then
    raise exception 'MIGRATION_123_IDENTIFIER_LENGTH_ASSERTION_FAILED';
  end if;

  if v_identity_arguments <>
     'p_access_request_id uuid, p_recorded_by text, p_reason text' then
    raise exception
      'MIGRATION_123_SIGNATURE_ASSERTION_FAILED actual=%',
      v_identity_arguments;
  end if;

  if v_security_definer is not true then
    raise exception 'MIGRATION_123_SECURITY_DEFINER_ASSERTION_FAILED';
  end if;

  if v_config is null
     or not ('search_path=public, pg_temp' = any(v_config)) then
    raise exception
      'MIGRATION_123_SEARCH_PATH_ASSERTION_FAILED config=%',
      v_config;
  end if;

  v_service_role_has_execute :=
    has_function_privilege(
      'service_role',
      v_function_oid,
      'EXECUTE'
    );

  v_public_has_execute :=
    has_function_privilege(
      'public',
      v_function_oid,
      'EXECUTE'
    );

  v_anon_has_execute :=
    has_function_privilege(
      'anon',
      v_function_oid,
      'EXECUTE'
    );

  v_authenticated_has_execute :=
    has_function_privilege(
      'authenticated',
      v_function_oid,
      'EXECUTE'
    );

  if v_service_role_has_execute is not true
     or v_public_has_execute
     or v_anon_has_execute
     or v_authenticated_has_execute then
    raise exception
      'MIGRATION_123_PRIVILEGE_ASSERTION_FAILED service_role=%, public=%, anon=%, authenticated=%',
      v_service_role_has_execute,
      v_public_has_execute,
      v_anon_has_execute,
      v_authenticated_has_execute;
  end if;

  if to_regprocedure(
    'public.record_blocked_commercial_provider_credential_resolution_intern(uuid,text,text)'
  ) is not null then
    raise exception 'MIGRATION_123_OLD_NAME_STILL_PRESENT';
  end if;

  raise notice
    'MIGRATION_123_CERTIFIED canonical_name=record_blocked_provider_credential_resolution_internal, identifier_length=%, signature_preserved=true, security_definer=true, search_path_preserved=true, service_role_execute=true, public_execute=false, anon_execute=false, authenticated_execute=false, old_truncated_name_removed=true',
    length(v_proname);
end
$$;

commit;
