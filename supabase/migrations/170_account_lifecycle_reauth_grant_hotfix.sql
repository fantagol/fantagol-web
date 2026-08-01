-- ============================================================================
-- FANTAGOL
-- Migration 170: Account Lifecycle Reauthentication Grant Ambiguity Hotfix
-- Phase 13.5.4
--
-- Purpose
--   Fix the PL/pgSQL ambiguity between the RETURNS TABLE output column
--   `expires_at` and account_deletion_reauth_grants.expires_at.
--
-- Safety
--   - function signature remains unchanged;
--   - no existing lifecycle data is mutated;
--   - no workflow is launched;
--   - no destructive feature is enabled;
--   - engine remains installed, runtime-disabled and uncertified.
-- ============================================================================

begin;

create or replace function public.issue_account_deletion_reauth_grant_internal(
  p_user_id uuid,
  p_confirmation_method text,
  p_ttl interval default interval '5 minutes',
  p_correlation_id uuid default null,
  p_metadata jsonb default '{}'::jsonb
)
returns table (
  grant_id uuid,
  grant_token text,
  expires_at timestamptz
)
language plpgsql
security definer
set search_path = public, auth, extensions, pg_catalog
as $function$
declare
  v_raw_token text;
  v_digest text;
  v_grant_id uuid;
  v_expires_at timestamptz;
begin
  if p_user_id is null then
    raise exception using
      errcode = '22023',
      message = 'ACCOUNT_DELETION_REAUTH_USER_REQUIRED';
  end if;

  if not exists (
    select 1
    from auth.users as au
    where au.id = p_user_id
  ) then
    raise exception using
      errcode = 'P0002',
      message = 'ACCOUNT_DELETION_REAUTH_USER_NOT_FOUND';
  end if;

  if p_confirmation_method not in (
    'password_reauthentication',
    'oauth_reauthentication',
    'recent_session',
    'signed_email_link',
    'support_verified'
  ) then
    raise exception using
      errcode = '22023',
      message = 'ACCOUNT_DELETION_REAUTH_METHOD_INVALID';
  end if;

  if p_ttl < interval '30 seconds'
     or p_ttl > interval '15 minutes' then
    raise exception using
      errcode = '22023',
      message = 'ACCOUNT_DELETION_REAUTH_TTL_INVALID';
  end if;

  if jsonb_typeof(coalesce(p_metadata, '{}'::jsonb)) <> 'object' then
    raise exception using
      errcode = '22023',
      message = 'ACCOUNT_DELETION_REAUTH_METADATA_INVALID';
  end if;

  update public.account_deletion_reauth_grants as g
  set
    grant_status = 'expired'
  where g.user_id = p_user_id
    and g.grant_status = 'active'
    and g.expires_at <= clock_timestamp();

  update public.account_deletion_reauth_grants as g
  set
    grant_status = 'revoked',
    revoked_at = clock_timestamp()
  where g.user_id = p_user_id
    and g.grant_status = 'active';

  v_raw_token := encode(extensions.gen_random_bytes(32), 'hex');
  v_digest := encode(
    extensions.digest(convert_to(v_raw_token, 'UTF8'), 'sha256'),
    'hex'
  );
  v_expires_at := clock_timestamp() + p_ttl;

  insert into public.account_deletion_reauth_grants (
    user_id,
    token_digest,
    confirmation_method,
    grant_status,
    issued_at,
    expires_at,
    issued_by,
    correlation_id,
    metadata
  )
  values (
    p_user_id,
    v_digest,
    p_confirmation_method,
    'active',
    clock_timestamp(),
    v_expires_at,
    'trusted_backend',
    p_correlation_id,
    coalesce(p_metadata, '{}'::jsonb)
  )
  returning account_deletion_reauth_grants.id
  into v_grant_id;

  return query
  select
    v_grant_id,
    v_raw_token,
    v_expires_at;
end;
$function$;

comment on function public.issue_account_deletion_reauth_grant_internal(
  uuid, text, interval, uuid, jsonb
) is
  'Service-only one-time grant issuer, hotfixed in migration 170 with fully qualified grant-table column references.';

revoke all on function public.issue_account_deletion_reauth_grant_internal(
  uuid, text, interval, uuid, jsonb
) from public, anon, authenticated;

grant execute on function public.issue_account_deletion_reauth_grant_internal(
  uuid, text, interval, uuid, jsonb
) to service_role;

update public.platform_configuration
set
  schema_version = greatest(schema_version, 170),
  metadata = metadata || jsonb_build_object(
    'account_lifecycle_reauth_grant_hotfix_migration', 170,
    'account_lifecycle_reauth_grant_contract', 'one-time-sha256-v1.1'
  ),
  updated_at = now()
where configuration_key = 'primary';

update public.platform_engine_registry
set
  metadata = metadata || jsonb_build_object(
    'reauth_grant_hotfix_migration', 170,
    'reauth_grant_contract', 'one-time-sha256-v1.1',
    'reauth_grant_column_qualification', true
  ),
  updated_at = now()
where engine_code = 'account_lifecycle_engine';

do $assertions$
declare
  v_definition text;
  v_engine public.platform_engine_registry%rowtype;
  v_policy public.account_lifecycle_policies%rowtype;
begin
  if to_regprocedure(
    'public.issue_account_deletion_reauth_grant_internal(uuid,text,interval,uuid,jsonb)'
  ) is null then
    raise exception
      'ACCOUNT_LIFECYCLE_REAUTH_HOTFIX_ASSERTION_FAILED: function missing';
  end if;

  select pg_get_functiondef(
    'public.issue_account_deletion_reauth_grant_internal(uuid,text,interval,uuid,jsonb)'::regprocedure
  )
  into v_definition;

  if position('g.expires_at <= clock_timestamp()' in v_definition) = 0 then
    raise exception
      'ACCOUNT_LIFECYCLE_REAUTH_HOTFIX_ASSERTION_FAILED: expires_at is not qualified';
  end if;

  if position('g.user_id = p_user_id' in v_definition) = 0
     or position('g.grant_status = ''active''' in v_definition) = 0 then
    raise exception
      'ACCOUNT_LIFECYCLE_REAUTH_HOTFIX_ASSERTION_FAILED: grant predicates are not qualified';
  end if;

  select *
  into v_engine
  from public.platform_engine_registry
  where engine_code = 'account_lifecycle_engine';

  if not found
     or v_engine.runtime_enabled
     or v_engine.is_certified
     or v_engine.lifecycle_status <> 'installed' then
    raise exception
      'ACCOUNT_LIFECYCLE_REAUTH_HOTFIX_ASSERTION_FAILED: engine safety state changed';
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
     ) then
    raise exception
      'ACCOUNT_LIFECYCLE_REAUTH_HOTFIX_ASSERTION_FAILED: destructive execution enabled';
  end if;

  if exists (
    select 1
    from public.account_deletion_reauth_grants
  ) or exists (
    select 1
    from public.account_lifecycle
  ) or exists (
    select 1
    from public.account_deletion_requests
  ) or exists (
    select 1
    from public.account_erasure_runs
  ) or exists (
    select 1
    from public.account_erasure_steps
  ) or exists (
    select 1
    from public.account_deletion_audit
  ) then
    raise exception
      'ACCOUNT_LIFECYCLE_REAUTH_HOTFIX_ASSERTION_FAILED: hotfix created operational data';
  end if;
end;
$assertions$;

commit;
