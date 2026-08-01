-- ============================================================================
-- FANTAGOL
-- Migration 171: Account Lifecycle Frontend Read Model Hardening
-- Phase 13.5.5.2
--
-- Adds a single user-safe frontend state RPC and declares the supported
-- reauthentication presentation contract. No lifecycle execution is enabled.
-- ============================================================================

begin;

create or replace function public.get_my_account_deletion_frontend_state_rpc()
returns jsonb
language plpgsql
security definer
stable
set search_path = public, auth, pg_catalog
as $function$
declare
  v_user_id uuid := auth.uid();
  v_status jsonb;
  v_policy public.account_lifecycle_policies%rowtype;
  v_engine public.platform_engine_registry%rowtype;
begin
  if v_user_id is null then
    raise exception using
      errcode = '42501',
      message = 'AUTHENTICATION_REQUIRED';
  end if;

  v_status := public.compose_my_account_deletion_status_internal(v_user_id);

  select *
    into v_policy
  from public.account_lifecycle_policies
  where policy_code = 'ACCOUNT_DELETION_STANDARD'
    and retired_at is null
    and effective_from <= clock_timestamp()
  order by policy_version desc
  limit 1;

  select *
    into v_engine
  from public.platform_engine_registry
  where engine_code = 'account_lifecycle_engine';

  return v_status || jsonb_build_object(
    'request_enabled',
      coalesce(v_policy.authenticated_request_enabled, false),
    'public_request_enabled',
      coalesce(v_policy.public_request_enabled, false),
    'confirmation_phrase',
      coalesce(v_policy.policy_config ->> 'confirmation_phrase', 'ELIMINA'),
    'reauthentication_methods',
      coalesce(
        v_policy.policy_config -> 'frontend_reauthentication_methods',
        '["password_reauthentication","oauth_reauthentication"]'::jsonb
      ),
    'engine_lifecycle_status', v_engine.lifecycle_status,
    'engine_runtime_enabled', coalesce(v_engine.runtime_enabled, false),
    'engine_certified', coalesce(v_engine.is_certified, false),
    'erasure_execution_enabled',
      coalesce(v_policy.automatic_execution_enabled, false)
      and coalesce(
        (v_policy.policy_config ->> 'auth_deletion_enabled')::boolean,
        false
      ),
    'frontend_contract_version', '1.0.0'
  );
end;
$function$;

comment on function public.get_my_account_deletion_frontend_state_rpc() is
  'Authenticated user-safe read model for the web and Android account deletion UI.';

revoke all on function public.get_my_account_deletion_frontend_state_rpc()
  from public, anon;

grant execute on function public.get_my_account_deletion_frontend_state_rpc()
  to authenticated, service_role;

update public.account_lifecycle_policies
set
  policy_config = policy_config || jsonb_build_object(
    'frontend_reauthentication_methods',
      '["password_reauthentication","oauth_reauthentication"]'::jsonb,
    'frontend_contract_version', '1.0.0',
    'public_page_path', '/elimina-account',
    'authenticated_page_path', '/elimina-account'
  ),
  updated_at = clock_timestamp()
where policy_code = 'ACCOUNT_DELETION_STANDARD'
  and policy_version = 1;

update public.platform_configuration
set
  schema_version = greatest(schema_version, 171),
  metadata = metadata || jsonb_build_object(
    'account_lifecycle_frontend_read_model_migration', 171,
    'account_lifecycle_frontend_contract', 'account-lifecycle-frontend-v1',
    'account_lifecycle_public_page', '/elimina-account'
  ),
  updated_at = now()
where configuration_key = 'primary';

update public.platform_engine_registry
set
  metadata = metadata || jsonb_build_object(
    'frontend_read_model_migration', 171,
    'frontend_contract', 'account-lifecycle-frontend-v1',
    'frontend_state_rpc', 'get_my_account_deletion_frontend_state_rpc',
    'public_page', '/elimina-account',
    'runtime_launch_enabled', false
  ),
  updated_at = now()
where engine_code = 'account_lifecycle_engine';

do $assertions$
declare
  v_engine public.platform_engine_registry%rowtype;
  v_policy public.account_lifecycle_policies%rowtype;
begin
  if to_regprocedure(
    'public.get_my_account_deletion_frontend_state_rpc()'
  ) is null then
    raise exception
      'ACCOUNT_LIFECYCLE_FRONTEND_ASSERTION_FAILED: frontend state RPC missing';
  end if;

  select *
    into v_engine
  from public.platform_engine_registry
  where engine_code = 'account_lifecycle_engine';

  if not found
     or v_engine.lifecycle_status <> 'installed'
     or v_engine.runtime_enabled
     or v_engine.is_certified then
    raise exception
      'ACCOUNT_LIFECYCLE_FRONTEND_ASSERTION_FAILED: engine safety state changed';
  end if;

  select *
    into v_policy
  from public.account_lifecycle_policies
  where policy_code = 'ACCOUNT_DELETION_STANDARD'
    and policy_version = 1;

  if not found
     or v_policy.automatic_execution_enabled
     or coalesce(
       (v_policy.policy_config ->> 'auth_deletion_enabled')::boolean,
       true
     )
     or coalesce(
       (v_policy.policy_config ->> 'storage_deletion_enabled')::boolean,
       true
     )
     or coalesce(
       (v_policy.policy_config ->> 'commercial_detach_enabled')::boolean,
       true
     )
     or coalesce(
       (v_policy.policy_config ->> 'competitive_anonymization_enabled')::boolean,
       true
     ) then
    raise exception
      'ACCOUNT_LIFECYCLE_FRONTEND_ASSERTION_FAILED: destructive features enabled';
  end if;
end;
$assertions$;

commit;
