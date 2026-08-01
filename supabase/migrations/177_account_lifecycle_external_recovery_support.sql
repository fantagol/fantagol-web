-- ============================================================================
-- FANTAGOL
-- Migration 177: Account Lifecycle External Recovery Support
-- Phase 13.8.7
--
-- Installs canonical failure, ambiguous-result, retry scheduling, lease
-- release and expired-lease reconciliation contracts for Migration 175
-- external commands.
--
-- Installation only:
--   no command is created;
--   no attempt is executed;
--   no account-erasure step is advanced;
--   no destructive feature is enabled.
-- ============================================================================

begin;

set local lock_timeout = '10s';
set local statement_timeout = '0';

do $preflight$
declare
  v_schema_version integer;
  v_operational_rows bigint;
  v_engine public.platform_engine_registry%rowtype;
  v_policy public.account_lifecycle_policies%rowtype;
begin
  select schema_version
    into v_schema_version
  from public.platform_configuration
  where configuration_key = 'primary';

  if v_schema_version <> 176 then
    raise exception
      'MIGRATION_177_REQUIRES_SCHEMA_VERSION_176, found %',
      v_schema_version;
  end if;

  if to_regclass('public.account_erasure_external_commands') is null
     or to_regclass('public.account_erasure_external_attempts') is null
     or to_regclass('public.account_erasure_external_receipts') is null then
    raise exception 'MIGRATION_177_REQUIRES_FINALIZATION_FOUNDATION';
  end if;

  select
      (select count(*) from public.account_erasure_external_commands)
    + (select count(*) from public.account_erasure_external_attempts)
    + (select count(*) from public.account_erasure_external_receipts)
  into v_operational_rows;

  if v_operational_rows <> 0 then
    raise exception
      'MIGRATION_177_REQUIRES_ZERO_OPERATIONAL_ROWS, found %',
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
       (v_policy.policy_config ->> 'auth_deletion_enabled')::boolean,
       false
     ) then
    raise exception 'MIGRATION_177_REQUIRES_DISABLED_RUNTIME';
  end if;
end;
$preflight$;

-- --------------------------------------------------------------------------
-- 1. Complete a claimed attempt as failed or ambiguous
-- --------------------------------------------------------------------------

create or replace function public.finalize_account_erasure_external_attempt_internal(
  p_command_id uuid,
  p_attempt_id uuid,
  p_worker_id text,
  p_lease_token uuid,
  p_outcome text,
  p_error_code text,
  p_error_class text,
  p_retryable boolean,
  p_provider_request_id text default null,
  p_response_digest text default null,
  p_public_evidence jsonb default '{}'::jsonb,
  p_restricted_response jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_catalog
as $function$
declare
  v_command public.account_erasure_external_commands%rowtype;
  v_attempt public.account_erasure_external_attempts%rowtype;
  v_command_status text;
begin
  if p_outcome not in ('failed', 'ambiguous') then
    raise exception 'ACCOUNT_ERASURE_EXTERNAL_OUTCOME_INVALID';
  end if;

  if nullif(btrim(p_error_code), '') is null then
    raise exception 'ACCOUNT_ERASURE_EXTERNAL_ERROR_CODE_REQUIRED';
  end if;

  if jsonb_typeof(coalesce(p_public_evidence, '{}'::jsonb)) <> 'object'
     or jsonb_typeof(coalesce(p_restricted_response, '{}'::jsonb)) <> 'object'
  then
    raise exception 'ACCOUNT_ERASURE_EXTERNAL_EVIDENCE_OBJECT_REQUIRED';
  end if;

  select *
    into v_command
  from public.account_erasure_external_commands
  where id = p_command_id
  for update;

  if not found
     or v_command.command_status <> 'dispatched'
     or v_command.lease_owner <> p_worker_id
     or v_command.lease_token <> p_lease_token
     or v_command.lease_expires_at <= clock_timestamp()
  then
    raise exception 'ACCOUNT_ERASURE_EXTERNAL_LEASE_LOST';
  end if;

  select *
    into v_attempt
  from public.account_erasure_external_attempts
  where id = p_attempt_id
    and command_id = p_command_id
    and attempt_status = 'started'
  for update;

  if not found then
    raise exception 'ACCOUNT_ERASURE_EXTERNAL_ATTEMPT_NOT_ACTIVE';
  end if;

  v_command_status :=
    case p_outcome
      when 'ambiguous' then 'ambiguous'
      else 'failed'
    end;

  update public.account_erasure_external_attempts
  set
    attempt_status = p_outcome,
    completed_at = clock_timestamp(),
    error_code = upper(btrim(p_error_code)),
    error_class = nullif(btrim(p_error_class), ''),
    retryable = coalesce(p_retryable, false),
    provider_request_id = nullif(btrim(p_provider_request_id), ''),
    response_digest = nullif(btrim(p_response_digest), ''),
    public_evidence = coalesce(p_public_evidence, '{}'::jsonb),
    restricted_response = coalesce(p_restricted_response, '{}'::jsonb)
  where id = p_attempt_id;

  update public.account_erasure_external_commands
  set
    command_status = v_command_status,
    failed_at =
      case
        when v_command_status = 'failed' then clock_timestamp()
        else null
      end,
    last_error_code = upper(btrim(p_error_code)),
    last_error_message = null,
    lease_owner = null,
    lease_token = null,
    leased_at = null,
    lease_expires_at = null,
    version = version + 1,
    updated_at = clock_timestamp()
  where id = p_command_id;

  return jsonb_build_object(
    'accepted', true,
    'command_id', p_command_id,
    'attempt_id', p_attempt_id,
    'command_status', v_command_status,
    'attempt_status', p_outcome,
    'retryable', coalesce(p_retryable, false),
    'error_code', upper(btrim(p_error_code))
  );
end;
$function$;

-- --------------------------------------------------------------------------
-- 2. Schedule the workflow step for retry, or fail it at exhaustion
-- --------------------------------------------------------------------------

create or replace function public.schedule_account_erasure_external_retry_internal(
  p_command_id uuid,
  p_available_at timestamptz default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_catalog
as $function$
declare
  v_command public.account_erasure_external_commands%rowtype;
  v_step public.account_erasure_steps%rowtype;
  v_attempt public.account_erasure_external_attempts%rowtype;
  v_available_at timestamptz;
  v_exhausted boolean;
begin
  select *
    into v_command
  from public.account_erasure_external_commands
  where id = p_command_id
  for update;

  if not found
     or v_command.command_status not in ('failed', 'ambiguous')
  then
    raise exception 'ACCOUNT_ERASURE_EXTERNAL_COMMAND_NOT_RETRYABLE';
  end if;

  select *
    into v_attempt
  from public.account_erasure_external_attempts
  where command_id = p_command_id
  order by attempt_number desc
  limit 1;

  if not found
     or v_attempt.attempt_status not in ('failed', 'ambiguous')
  then
    raise exception 'ACCOUNT_ERASURE_EXTERNAL_ATTEMPT_TERMINAL_REQUIRED';
  end if;

  select *
    into v_step
  from public.account_erasure_steps
  where id = v_command.erasure_step_id
  for update;

  v_exhausted :=
    not coalesce(v_attempt.retryable, false)
    or v_step.attempt_count >= v_step.max_attempts
    or v_command.attempt_count >= v_step.max_attempts;

  if v_exhausted then
    update public.account_erasure_steps
    set
      step_status = 'failed',
      failed_at = clock_timestamp(),
      error_code = coalesce(v_attempt.error_code, 'ACCOUNT_ERASURE_EXTERNAL_FAILED'),
      error_message = null,
      lease_owner = null,
      lease_token = null,
      leased_at = null,
      lease_expires_at = null,
      version = version + 1,
      updated_at = clock_timestamp()
    where id = v_step.id
      and step_status in (
        'pending','leased','running','retry_scheduled','blocked','failed'
      );

    return jsonb_build_object(
      'scheduled', false,
      'exhausted', true,
      'command_id', p_command_id,
      'step_id', v_step.id,
      'step_status', 'failed'
    );
  end if;

  v_available_at :=
    coalesce(
      p_available_at,
      clock_timestamp()
        + least(
            interval '6 hours',
            interval '5 minutes'
              * power(2::numeric, greatest(v_command.attempt_count - 1, 0))
          )
    );

  update public.account_erasure_steps
  set
    step_status = 'retry_scheduled',
    available_at = v_available_at,
    error_code = coalesce(v_attempt.error_code, 'ACCOUNT_ERASURE_EXTERNAL_RETRY'),
    error_message = null,
    failed_at = null,
    blocker_code = null,
    lease_owner = null,
    lease_token = null,
    leased_at = null,
    lease_expires_at = null,
    version = version + 1,
    updated_at = clock_timestamp()
  where id = v_step.id
    and step_status in (
      'pending','leased','running','retry_scheduled','blocked','failed'
    );

  return jsonb_build_object(
    'scheduled', true,
    'exhausted', false,
    'command_id', p_command_id,
    'step_id', v_step.id,
    'step_status', 'retry_scheduled',
    'available_at', v_available_at
  );
end;
$function$;

-- --------------------------------------------------------------------------
-- 3. Reconcile expired external command leases
-- --------------------------------------------------------------------------

create or replace function public.reconcile_expired_account_erasure_external_leases_internal(
  p_limit integer default 100
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_catalog
as $function$
declare
  v_row record;
  v_reconciled integer := 0;
begin
  if p_limit < 1 or p_limit > 1000 then
    raise exception 'ACCOUNT_ERASURE_RECONCILE_LIMIT_INVALID';
  end if;

  for v_row in
    select
      c.id as command_id,
      c.lease_owner,
      c.lease_token,
      a.id as attempt_id
    from public.account_erasure_external_commands c
    join lateral (
      select x.id
      from public.account_erasure_external_attempts x
      where x.command_id = c.id
        and x.attempt_status = 'started'
      order by x.attempt_number desc
      limit 1
    ) a on true
    where c.command_status = 'dispatched'
      and c.lease_expires_at <= clock_timestamp()
    order by c.lease_expires_at, c.id
    limit p_limit
    for update of c skip locked
  loop
    update public.account_erasure_external_attempts
    set
      attempt_status = 'ambiguous',
      completed_at = clock_timestamp(),
      error_code = 'ACCOUNT_ERASURE_EXTERNAL_LEASE_EXPIRED',
      error_class = 'lease_expiration',
      retryable = true,
      public_evidence = jsonb_build_object(
        'reconciled_from_expired_lease', true
      )
    where id = v_row.attempt_id
      and attempt_status = 'started';

    update public.account_erasure_external_commands
    set
      command_status = 'ambiguous',
      failed_at = null,
      last_error_code = 'ACCOUNT_ERASURE_EXTERNAL_LEASE_EXPIRED',
      last_error_message = null,
      lease_owner = null,
      lease_token = null,
      leased_at = null,
      lease_expires_at = null,
      version = version + 1,
      updated_at = clock_timestamp()
    where id = v_row.command_id
      and command_status = 'dispatched';

    v_reconciled := v_reconciled + 1;
  end loop;

  return jsonb_build_object(
    'reconciled_count', v_reconciled,
    'limit', p_limit
  );
end;
$function$;

-- --------------------------------------------------------------------------
-- 4. Safe status read for the worker
-- --------------------------------------------------------------------------

create or replace function public.get_account_erasure_external_command_status_internal(
  p_command_id uuid
)
returns jsonb
language plpgsql
security definer
stable
set search_path = public, pg_catalog
as $function$
declare
  v_command public.account_erasure_external_commands%rowtype;
  v_attempt public.account_erasure_external_attempts%rowtype;
begin
  select *
    into v_command
  from public.account_erasure_external_commands
  where id = p_command_id;

  if not found then
    raise exception 'ACCOUNT_ERASURE_EXTERNAL_COMMAND_NOT_FOUND';
  end if;

  select *
    into v_attempt
  from public.account_erasure_external_attempts
  where command_id = p_command_id
  order by attempt_number desc
  limit 1;

  return jsonb_build_object(
    'command_id', v_command.id,
    'command_type', v_command.command_type,
    'command_status', v_command.command_status,
    'attempt_count', v_command.attempt_count,
    'last_error_code', v_command.last_error_code,
    'latest_attempt_id', v_attempt.id,
    'latest_attempt_status', v_attempt.attempt_status,
    'latest_attempt_retryable', v_attempt.retryable,
    'lease_expires_at', v_command.lease_expires_at,
    'updated_at', v_command.updated_at
  );
end;
$function$;

-- --------------------------------------------------------------------------
-- 5. Privileges
-- --------------------------------------------------------------------------

do $grants$
declare
  v_signature text;
begin
  foreach v_signature in array array[
    'public.finalize_account_erasure_external_attempt_internal(uuid,uuid,text,uuid,text,text,text,boolean,text,text,jsonb,jsonb)',
    'public.schedule_account_erasure_external_retry_internal(uuid,timestamptz)',
    'public.reconcile_expired_account_erasure_external_leases_internal(integer)',
    'public.get_account_erasure_external_command_status_internal(uuid)'
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
$grants$;

-- Direct table access remains forbidden after Migration 176.
revoke all privileges
on table public.account_erasure_external_commands
from service_role, authenticated, anon;

revoke all privileges
on table public.account_erasure_external_attempts
from service_role, authenticated, anon;

revoke all privileges
on table public.account_erasure_external_receipts
from service_role, authenticated, anon;

-- --------------------------------------------------------------------------
-- 6. Metadata
-- --------------------------------------------------------------------------

update public.account_lifecycle_policies
set
  policy_config = policy_config || jsonb_build_object(
    'external_failure_recording_installed', true,
    'external_ambiguous_recording_installed', true,
    'external_retry_scheduler_installed', true,
    'external_lease_reconciliation_installed', true,
    'external_recovery_contract_version', '1.0.0',
    'external_recovery_enabled', false,
    'external_reconciliation_enabled', false
  ),
  updated_at = clock_timestamp()
where policy_code = 'ACCOUNT_DELETION_STANDARD'
  and policy_version = 1;

update public.platform_engine_registry
set
  metadata = metadata || jsonb_build_object(
    'external_recovery_support_migration', 177,
    'external_recovery_contract_version', '1.0.0',
    'external_recovery_installed', true,
    'external_recovery_enabled', false
  ),
  updated_at = clock_timestamp()
where engine_code = 'account_lifecycle_engine';

update public.platform_configuration
set
  schema_version = 177,
  metadata = metadata || jsonb_build_object(
    'account_lifecycle_external_recovery_support_migration', 177,
    'account_lifecycle_external_recovery_contract', '1.0.0',
    'account_lifecycle_external_recovery_enabled', false
  ),
  updated_at = clock_timestamp()
where configuration_key = 'primary';

-- --------------------------------------------------------------------------
-- 7. Assertions
-- --------------------------------------------------------------------------

do $assertions$
declare
  v_operational_rows bigint;
  v_forbidden_grants bigint;
  v_rpc_count bigint;
  v_engine public.platform_engine_registry%rowtype;
  v_policy public.account_lifecycle_policies%rowtype;
begin
  select
      (select count(*) from public.account_erasure_external_commands)
    + (select count(*) from public.account_erasure_external_attempts)
    + (select count(*) from public.account_erasure_external_receipts)
  into v_operational_rows;

  if v_operational_rows <> 0 then
    raise exception
      'MIGRATION_177_ASSERTION_FAILED_OPERATIONAL_ROWS: %',
      v_operational_rows;
  end if;

  select count(*)
    into v_forbidden_grants
  from information_schema.role_table_grants
  where table_schema = 'public'
    and table_name in (
      'account_erasure_external_commands',
      'account_erasure_external_attempts',
      'account_erasure_external_receipts'
    )
    and grantee in ('service_role','authenticated','anon');

  if v_forbidden_grants <> 0 then
    raise exception
      'MIGRATION_177_ASSERTION_FAILED_DIRECT_GRANTS: %',
      v_forbidden_grants;
  end if;

  select count(distinct routine_name)
    into v_rpc_count
  from information_schema.routine_privileges
  where specific_schema = 'public'
    and routine_name in (
      'finalize_account_erasure_external_attempt_internal',
      'schedule_account_erasure_external_retry_internal',
      'reconcile_expired_account_erasure_external_leases_internal',
      'get_account_erasure_external_command_status_internal'
    )
    and grantee = 'service_role'
    and privilege_type = 'EXECUTE';

  if v_rpc_count <> 4 then
    raise exception
      'MIGRATION_177_ASSERTION_FAILED_RPC_COUNT: %',
      v_rpc_count;
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
       (v_policy.policy_config ->> 'external_recovery_enabled')::boolean,
       false
     )
     or coalesce(
       (v_policy.policy_config ->> 'external_reconciliation_enabled')::boolean,
       false
     )
     or coalesce(
       (v_policy.policy_config ->> 'external_command_execution_enabled')::boolean,
       false
     )
     or coalesce(
       (v_policy.policy_config ->> 'storage_deletion_enabled')::boolean,
       false
     )
     or coalesce(
       (v_policy.policy_config ->> 'auth_deletion_enabled')::boolean,
       false
     ) then
    raise exception 'MIGRATION_177_ASSERTION_FAILED_RUNTIME_STATE';
  end if;
end;
$assertions$;

commit;
