-- ============================================================================
-- FANTAGOL
-- Migration 176: Account Lifecycle Finalization Privilege Hardening
-- Phase 13.8.6
--
-- Purpose
--   Remove all direct service_role privileges from the Migration 175
--   finalization tables. Runtime access must pass exclusively through the
--   canonical SECURITY DEFINER functions.
--
-- Safety
--   - no command, attempt or receipt is created;
--   - no lifecycle/run/step is advanced;
--   - no Storage, profile or Auth data is deleted;
--   - all execution flags remain disabled;
--   - engine remains installed, disabled and uncertified.
-- ============================================================================

begin;

set local lock_timeout = '10s';
set local statement_timeout = '0';

-- --------------------------------------------------------------------------
-- 1. Preconditions
-- --------------------------------------------------------------------------

do $preflight$
declare
  v_schema_version integer;
  v_engine public.platform_engine_registry%rowtype;
  v_policy public.account_lifecycle_policies%rowtype;
begin
  select schema_version
    into v_schema_version
  from public.platform_configuration
  where configuration_key = 'primary';

  if v_schema_version <> 175 then
    raise exception
      'MIGRATION_176_REQUIRES_SCHEMA_VERSION_175, found %',
      v_schema_version;
  end if;

  if to_regclass('public.account_erasure_external_commands') is null
     or to_regclass('public.account_erasure_external_attempts') is null
     or to_regclass('public.account_erasure_external_receipts') is null
     or to_regclass('public.account_erasure_storage_registry') is null then
    raise exception
      'MIGRATION_176_REQUIRES_MIGRATION_175_TABLES';
  end if;

  select *
    into v_engine
  from public.platform_engine_registry
  where engine_code = 'account_lifecycle_engine';

  select *
    into v_policy
  from public.account_lifecycle_policies
  where policy_code = 'ACCOUNT_DELETION_STANDARD'
    and policy_version = 1;

  if v_engine.runtime_enabled
     or v_engine.is_certified
     or v_policy.automatic_execution_enabled
     or coalesce(
       (v_policy.policy_config ->> 'finalization_handlers_enabled')::boolean,
       false
     )
     or coalesce(
       (v_policy.policy_config ->> 'server_orchestrator_enabled')::boolean,
       false
     )
     or coalesce(
       (v_policy.policy_config ->> 'external_command_execution_enabled')::boolean,
       false
     )
     or coalesce(
       (v_policy.policy_config ->> 'external_receipt_acceptance_enabled')::boolean,
       false
     )
     or coalesce(
       (v_policy.policy_config ->> 'storage_deletion_enabled')::boolean,
       false
     )
     or coalesce(
       (v_policy.policy_config ->> 'profile_deletion_enabled')::boolean,
       false
     )
     or coalesce(
       (v_policy.policy_config ->> 'auth_deletion_enabled')::boolean,
       false
     )
     or coalesce(
       (v_policy.policy_config ->> 'terminal_certification_enabled')::boolean,
       false
     ) then
    raise exception
      'MIGRATION_176_REQUIRES_DISABLED_FINALIZATION_RUNTIME';
  end if;
end;
$preflight$;

-- --------------------------------------------------------------------------
-- 2. Remove direct runtime table access
-- --------------------------------------------------------------------------

revoke all privileges
on table public.account_erasure_external_commands
from service_role;

revoke all privileges
on table public.account_erasure_external_attempts
from service_role;

revoke all privileges
on table public.account_erasure_external_receipts
from service_role;

revoke all privileges
on table public.account_erasure_storage_registry
from service_role;

-- Explicitly preserve the same no-access boundary for client-facing roles.
revoke all privileges
on table public.account_erasure_external_commands
from public, anon, authenticated;

revoke all privileges
on table public.account_erasure_external_attempts
from public, anon, authenticated;

revoke all privileges
on table public.account_erasure_external_receipts
from public, anon, authenticated;

revoke all privileges
on table public.account_erasure_storage_registry
from public, anon, authenticated;

-- Trigger functions do not need to be callable by runtime roles.
revoke all on function
  public.guard_account_erasure_external_command_transition()
from public, anon, authenticated, service_role;

revoke all on function
  public.guard_account_erasure_external_attempt()
from public, anon, authenticated, service_role;

revoke all on function
  public.protect_account_erasure_external_receipt_immutable()
from public, anon, authenticated, service_role;

-- Canonical operational functions remain the only service_role boundary.
-- Reassert exact execution grants after removing drift.
do $function_grants$
declare
  v_signature text;
begin
  foreach v_signature in array array[
    'public.prepare_account_erasure_external_command_internal(uuid,text,uuid)',
    'public.claim_account_erasure_external_command_internal(uuid,text,uuid,interval)',
    'public.heartbeat_account_erasure_external_command_internal(uuid,text,uuid,interval)',
    'public.record_account_erasure_external_receipt_internal(uuid,uuid,text,uuid,text,text,text,jsonb,jsonb,bigint,bigint)',
    'public.complete_account_erasure_external_step_internal(uuid,text,bigint,bigint,jsonb)'
  ]
  loop
    execute format(
      'revoke all on function %s from public, anon, authenticated',
      v_signature
    );
    execute format(
      'grant execute on function %s to service_role',
      v_signature
    );
  end loop;
end;
$function_grants$;

-- --------------------------------------------------------------------------
-- 3. Metadata
-- --------------------------------------------------------------------------

update public.account_lifecycle_policies
set
  policy_config = policy_config || jsonb_build_object(
    'finalization_table_access_contract',
      'security-definer-functions-only-v1',
    'service_role_direct_finalization_table_access',
      false,
    'finalization_privilege_hardening_migration',
      176
  ),
  updated_at = clock_timestamp()
where policy_code = 'ACCOUNT_DELETION_STANDARD'
  and policy_version = 1;

update public.platform_engine_registry
set
  metadata = metadata || jsonb_build_object(
    'finalization_privilege_contract',
      'security-definer-functions-only-v1',
    'finalization_privilege_hardening_migration',
      176,
    'service_role_direct_table_access',
      false
  ),
  updated_at = clock_timestamp()
where engine_code = 'account_lifecycle_engine';

update public.platform_configuration
set
  schema_version = 176,
  metadata = metadata || jsonb_build_object(
    'account_lifecycle_finalization_privilege_contract',
      'security-definer-functions-only-v1',
    'account_lifecycle_finalization_privilege_hardening_migration',
      176
  ),
  updated_at = clock_timestamp()
where configuration_key = 'primary';

-- --------------------------------------------------------------------------
-- 4. Assertions
-- --------------------------------------------------------------------------

do $assertions$
declare
  v_direct_grants bigint;
  v_trigger_execute_grants bigint;
  v_required_function_grants bigint;
  v_operational_rows bigint;
  v_engine public.platform_engine_registry%rowtype;
  v_policy public.account_lifecycle_policies%rowtype;
begin
  select count(*)
    into v_direct_grants
  from information_schema.role_table_grants g
  where g.table_schema = 'public'
    and g.table_name in (
      'account_erasure_external_commands',
      'account_erasure_external_attempts',
      'account_erasure_external_receipts',
      'account_erasure_storage_registry'
    )
    and g.grantee in ('service_role', 'authenticated', 'anon');

  if v_direct_grants <> 0 then
    raise exception
      'MIGRATION_176_ASSERTION_FAILED_DIRECT_TABLE_GRANTS: %',
      v_direct_grants;
  end if;

  select count(*)
    into v_trigger_execute_grants
  from information_schema.routine_privileges p
  where p.specific_schema = 'public'
    and p.routine_name in (
      'guard_account_erasure_external_command_transition',
      'guard_account_erasure_external_attempt',
      'protect_account_erasure_external_receipt_immutable'
    )
    and p.grantee in ('service_role', 'authenticated', 'anon', 'PUBLIC');

  if v_trigger_execute_grants <> 0 then
    raise exception
      'MIGRATION_176_ASSERTION_FAILED_TRIGGER_FUNCTION_GRANTS: %',
      v_trigger_execute_grants;
  end if;

  select count(distinct p.routine_name)
    into v_required_function_grants
  from information_schema.routine_privileges p
  where p.specific_schema = 'public'
    and p.routine_name in (
      'prepare_account_erasure_external_command_internal',
      'claim_account_erasure_external_command_internal',
      'heartbeat_account_erasure_external_command_internal',
      'record_account_erasure_external_receipt_internal',
      'complete_account_erasure_external_step_internal'
    )
    and p.grantee = 'service_role'
    and p.privilege_type = 'EXECUTE';

  if v_required_function_grants <> 5 then
    raise exception
      'MIGRATION_176_ASSERTION_FAILED_REQUIRED_FUNCTION_GRANTS: %',
      v_required_function_grants;
  end if;

  select
      (select count(*) from public.account_erasure_external_commands)
    + (select count(*) from public.account_erasure_external_attempts)
    + (select count(*) from public.account_erasure_external_receipts)
  into v_operational_rows;

  if v_operational_rows <> 0 then
    raise exception
      'MIGRATION_176_ASSERTION_FAILED_OPERATIONAL_ROWS: %',
      v_operational_rows;
  end if;

  select *
    into v_engine
  from public.platform_engine_registry
  where engine_code = 'account_lifecycle_engine';

  select *
    into v_policy
  from public.account_lifecycle_policies
  where policy_code = 'ACCOUNT_DELETION_STANDARD'
    and policy_version = 1;

  if v_engine.runtime_enabled
     or v_engine.is_certified
     or v_policy.automatic_execution_enabled
     or coalesce(
       (v_policy.policy_config ->> 'finalization_handlers_enabled')::boolean,
       false
     )
     or coalesce(
       (v_policy.policy_config ->> 'server_orchestrator_enabled')::boolean,
       false
     )
     or coalesce(
       (v_policy.policy_config ->> 'external_command_execution_enabled')::boolean,
       false
     )
     or coalesce(
       (v_policy.policy_config ->> 'external_receipt_acceptance_enabled')::boolean,
       false
     )
     or coalesce(
       (v_policy.policy_config ->> 'storage_deletion_enabled')::boolean,
       false
     )
     or coalesce(
       (v_policy.policy_config ->> 'profile_deletion_enabled')::boolean,
       false
     )
     or coalesce(
       (v_policy.policy_config ->> 'auth_deletion_enabled')::boolean,
       false
     )
     or coalesce(
       (v_policy.policy_config ->> 'terminal_certification_enabled')::boolean,
       false
     ) then
    raise exception
      'MIGRATION_176_ASSERTION_FAILED_RUNTIME_STATE';
  end if;
end;
$assertions$;

commit;
