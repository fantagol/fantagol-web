\set ON_ERROR_STOP on

begin;

create or replace function
public.assert_account_lifecycle_certification_scope_internal(
  p_account_lifecycle_id uuid,
  p_erasure_run_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_catalog
as $function$
declare
  v_activation public.account_lifecycle_runtime_activation%rowtype;
  v_engine public.platform_engine_registry%rowtype;
  v_policy public.account_lifecycle_policies%rowtype;
begin
  select *
    into v_activation
  from public.account_lifecycle_runtime_activation
  where activation_key = 'primary';

  if not found
     or v_activation.activation_level not in (1, 2, 3, 4, 5)
     or v_activation.activation_mode <> 'certification'
     or v_activation.desired_state <> 'certification'
     or not v_activation.claims_enabled
     or not v_activation.workers_enabled
  then
    raise exception 'ACCOUNT_LIFECYCLE_RUNTIME_NOT_ACTIVE';
  end if;

  if v_activation.certification_account_lifecycle_id
       is distinct from p_account_lifecycle_id
     or v_activation.certification_erasure_run_id
       is distinct from p_erasure_run_id
  then
    raise exception 'ACCOUNT_LIFECYCLE_CERTIFICATION_SCOPE_MISMATCH';
  end if;

  if v_activation.production_scope_enabled then
    raise exception 'ACCOUNT_LIFECYCLE_PRODUCTION_SCOPE_FORBIDDEN';
  end if;

  if v_activation.activation_level = 1 then
    if v_activation.storage_provider_enabled
       or v_activation.auth_provider_enabled
       or v_activation.stop_before_step_order <> 120
    then
      raise exception
        'ACCOUNT_LIFECYCLE_LEVEL1_PROVIDER_STATE_INVALID';
    end if;
  elsif v_activation.activation_level = 2 then
    if not v_activation.storage_provider_enabled
       or v_activation.auth_provider_enabled
       or v_activation.stop_before_step_order <> 150
    then
      raise exception
        'ACCOUNT_LIFECYCLE_LEVEL2_PROVIDER_STATE_INVALID';
    end if;
  elsif v_activation.activation_level = 3 then
    if not v_activation.storage_provider_enabled
       or not v_activation.auth_provider_enabled
       or v_activation.stop_before_step_order <> 160
    then
      raise exception
        'ACCOUNT_LIFECYCLE_LEVEL3_PROVIDER_STATE_INVALID';
    end if;
  elsif v_activation.activation_level = 4 then
    if not v_activation.storage_provider_enabled
       or not v_activation.auth_provider_enabled
       or v_activation.stop_before_step_order <> 180
    then
      raise exception
        'ACCOUNT_LIFECYCLE_LEVEL4_PROVIDER_STATE_INVALID';
    end if;
  elsif v_activation.activation_level = 5 then
    if not v_activation.storage_provider_enabled
       or not v_activation.auth_provider_enabled
       or v_activation.stop_before_step_order <> 190
    then
      raise exception
        'ACCOUNT_LIFECYCLE_LEVEL5_PROVIDER_STATE_INVALID';
    end if;
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

  if not v_engine.runtime_enabled
     or v_engine.is_certified
     or not v_policy.automatic_execution_enabled
     or not coalesce(
       (
         v_policy.policy_config
         ->> 'domain_handlers_enabled'
       )::boolean,
       false
     )
  then
    raise exception
      'ACCOUNT_LIFECYCLE_ENGINE_CERTIFICATION_STATE_INVALID';
  end if;

  if v_activation.activation_level = 1 then
    if coalesce(
         (
           v_policy.policy_config
           ->> 'storage_deletion_enabled'
         )::boolean,
         false
       )
       or coalesce(
         (
           v_policy.policy_config
           ->> 'auth_deletion_enabled'
         )::boolean,
         false
       )
    then
      raise exception
        'ACCOUNT_LIFECYCLE_LEVEL1_POLICY_STATE_INVALID';
    end if;
  elsif v_activation.activation_level = 2 then
    if not coalesce(
         (
           v_policy.policy_config
           ->> 'storage_deletion_enabled'
         )::boolean,
         false
       )
       or not coalesce(
         (
           v_policy.policy_config
           ->> 'profile_deletion_enabled'
         )::boolean,
         false
       )
       or not coalesce(
         (
           v_policy.policy_config
           ->> 'pre_auth_certification_enabled'
         )::boolean,
         false
       )
       or coalesce(
         (
           v_policy.policy_config
           ->> 'auth_deletion_enabled'
         )::boolean,
         false
       )
    then
      raise exception
        'ACCOUNT_LIFECYCLE_LEVEL2_POLICY_STATE_INVALID';
    end if;
  elsif v_activation.activation_level = 3 then
    if not coalesce(
         (
           v_policy.policy_config
           ->> 'storage_deletion_enabled'
         )::boolean,
         false
       )
       or not coalesce(
         (
           v_policy.policy_config
           ->> 'profile_deletion_enabled'
         )::boolean,
         false
       )
       or not coalesce(
         (
           v_policy.policy_config
           ->> 'pre_auth_certification_enabled'
         )::boolean,
         false
       )
       or not coalesce(
         (
           v_policy.policy_config
           ->> 'auth_deletion_enabled'
         )::boolean,
         false
       )
       or not coalesce(
         (
           v_policy.policy_config
           ->> 'auth_handler_installed'
         )::boolean,
         false
       )
       or coalesce(
         (
           v_policy.policy_config
           ->> 'post_auth_certification_enabled'
         )::boolean,
         false
       )
       or coalesce(
         (
           v_policy.policy_config
           ->> 'production_scope_enabled'
         )::boolean,
         false
       )
    then
      raise exception
        'ACCOUNT_LIFECYCLE_LEVEL3_POLICY_STATE_INVALID';
    end if;
  elsif v_activation.activation_level = 4 then
    if not coalesce(
         (
           v_policy.policy_config
           ->> 'post_auth_certification_enabled'
         )::boolean,
         false
       )
       or not coalesce(
         (
           v_policy.policy_config
           ->> 'final_audit_enabled'
         )::boolean,
         false
       )
       or coalesce(
         (
           v_policy.policy_config
           ->> 'terminal_certification_enabled'
         )::boolean,
         false
       )
       or coalesce(
         (
           v_policy.policy_config
           ->> 'production_scope_enabled'
         )::boolean,
         false
       )
    then
      raise exception
        'ACCOUNT_LIFECYCLE_LEVEL4_POLICY_STATE_INVALID';
    end if;
  elsif v_activation.activation_level = 5 then
    if not coalesce(
         (
           v_policy.policy_config
           ->> 'post_auth_certification_enabled'
         )::boolean,
         false
       )
       or not coalesce(
         (
           v_policy.policy_config
           ->> 'final_audit_enabled'
         )::boolean,
         false
       )
       or not coalesce(
         (
           v_policy.policy_config
           ->> 'terminal_certification_enabled'
         )::boolean,
         false
       )
       or coalesce(
         (
           v_policy.policy_config
           ->> 'production_scope_enabled'
         )::boolean,
         false
       )
    then
      raise exception
        'ACCOUNT_LIFECYCLE_LEVEL5_POLICY_STATE_INVALID';
    end if;
  end if;

  return jsonb_build_object(
    'allowed', true,
    'activation_level', v_activation.activation_level,
    'activation_mode', v_activation.activation_mode,
    'account_lifecycle_id',
      v_activation.certification_account_lifecycle_id,
    'erasure_run_id',
      v_activation.certification_erasure_run_id,
    'stop_before_step_order',
      v_activation.stop_before_step_order,
    'storage_provider_enabled',
      v_activation.storage_provider_enabled,
    'auth_provider_enabled',
      v_activation.auth_provider_enabled
  );
end;
$function$;

-- FantaGol Phase 180 — Storage Provider Activation
-- Level 2 certification only. Auth remains disabled.

do $preflight$
declare
  v_activation public.account_lifecycle_runtime_activation%rowtype;
  v_lifecycle public.account_lifecycle%rowtype;
  v_run public.account_erasure_runs%rowtype;
  v_next_step public.account_erasure_steps%rowtype;
  v_completed bigint;
  v_external bigint;
  v_registry public.account_erasure_storage_registry%rowtype;
begin
  select * into v_activation
  from public.account_lifecycle_runtime_activation
  where activation_key = 'primary'
  for update;

  if not found
     or v_activation.activation_level <> 1
     or v_activation.activation_mode <> 'certification'
     or v_activation.observed_state <> 'certification_paused'
     or not v_activation.claims_enabled
     or not v_activation.workers_enabled
     or v_activation.storage_provider_enabled
     or v_activation.auth_provider_enabled
     or v_activation.production_scope_enabled
     or v_activation.certification_account_lifecycle_id <>
       '6b644375-da81-4714-9ce7-2fcd4b649fd4'::uuid
     or v_activation.certification_erasure_run_id <>
       '1bd7fe36-343a-4b6f-895e-6ec9b93e73d1'::uuid
  then
    raise exception 'MIGRATION_180_ACTIVATION_BASELINE_INVALID';
  end if;

  select * into v_run
  from public.account_erasure_runs
  where id = v_activation.certification_erasure_run_id
  for update;

  select * into v_lifecycle
  from public.account_lifecycle
  where id = v_activation.certification_account_lifecycle_id
  for update;

  select * into v_next_step
  from public.account_erasure_steps
  where erasure_run_id = v_run.id
    and step_order = 120
  for update;

  select count(*) into v_completed
  from public.account_erasure_steps
  where erasure_run_id = v_run.id
    and step_order between 10 and 110
    and step_status = 'completed';

  select
      (select count(*) from public.account_erasure_external_commands)
    + (select count(*) from public.account_erasure_external_attempts)
    + (select count(*) from public.account_erasure_external_receipts)
  into v_external;

  select * into v_registry
  from public.account_erasure_storage_registry
  where bucket_code = 'club-avatars'
    and registry_version = 1
  for update;

  if v_lifecycle.lifecycle_status <> 'erasure_running'
     or v_run.run_status <> 'running'
     or v_run.blocker_code is not null
     or v_completed <> 11
     or v_next_step.step_status <> 'pending'
     or v_next_step.attempt_count <> 0
     or v_external <> 0
     or not found
     or not v_registry.approved
     or v_registry.active
     or v_registry.retired_at is not null
  then
    raise exception 'MIGRATION_180_STORAGE_BASELINE_INVALID';
  end if;
end;
$preflight$;

update public.account_erasure_storage_registry
set
  active = true,
  approved = true,
  metadata = metadata || jsonb_build_object(
    'activated_by_migration', 180,
    'activation_mode', 'certification',
    'certification_scope', 'approved_lifecycle_only',
    'activated_at', clock_timestamp()
  ),
  updated_at = clock_timestamp()
where bucket_code = 'club-avatars'
  and registry_version = 1
  and approved = true
  and retired_at is null;

update public.account_lifecycle_policies
set
  automatic_execution_enabled = true,
  policy_config = policy_config || jsonb_build_object(
    'runtime_activation_level', 2,
    'runtime_activation_mode', 'certification',
    'runtime_launch_enabled', true,
    'runtime_claim_enabled', true,
    'runtime_worker_enabled', true,
    'domain_handlers_enabled', true,
    'finalization_handlers_enabled', true,
    'server_orchestrator_enabled', true,
    'external_command_execution_enabled', true,
    'external_receipt_acceptance_enabled', true,
    'external_recovery_enabled', true,
    'external_reconciliation_enabled', true,
    'storage_deletion_enabled', true,
    'profile_deletion_enabled', true,
    'pre_auth_certification_enabled', true,
    'auth_deletion_enabled', false,
    'post_auth_certification_enabled', false,
    'final_audit_enabled', false,
    'terminal_certification_enabled', false,
    'certification_scope_enabled', true,
    'certification_account_lifecycle_id',
      '6b644375-da81-4714-9ce7-2fcd4b649fd4',
    'certification_erasure_run_id',
      '1bd7fe36-343a-4b6f-895e-6ec9b93e73d1',
    'certification_stop_before_step_order', 150,
    'production_scope_enabled', false
  ),
  updated_at = clock_timestamp()
where policy_code = 'ACCOUNT_DELETION_STANDARD'
  and policy_version = 1;

update public.account_lifecycle_runtime_activation
set
  activation_level = 2,
  activation_mode = 'certification',
  desired_state = 'certification',
  observed_state = 'idle',
  stop_before_step_order = 150,
  claims_enabled = true,
  workers_enabled = true,
  recovery_enabled = true,
  reconciliation_enabled = true,
  storage_provider_enabled = true,
  auth_provider_enabled = false,
  production_scope_enabled = false,
  last_transition_code =
    'ACCOUNT_LIFECYCLE_STORAGE_CERTIFICATION_ACTIVATED',
  last_error_code = null,
  version = version + 1,
  updated_at = clock_timestamp()
where activation_key = 'primary';

update public.platform_engine_registry
set
  lifecycle_status = 'active',
  runtime_enabled = true,
  is_certified = false,
  metadata = metadata || jsonb_build_object(
    'runtime_activation_level', 2,
    'runtime_desired_state', 'certification',
    'runtime_observed_state', 'idle',
    'storage_activation_migration', 180,
    'storage_registry_version', 1,
    'storage_provider_enabled', true,
    'auth_provider_enabled', false,
    'production_scope_enabled', false,
    'certification_stop_before_step_order', 150
  ),
  updated_at = clock_timestamp()
where engine_code = 'account_lifecycle_engine';

update public.platform_configuration
set
  schema_version = 180,
  metadata = metadata || jsonb_build_object(
    'account_lifecycle_runtime_activation_level', 2,
    'account_lifecycle_storage_activation_migration', 180,
    'account_lifecycle_storage_provider_enabled', true,
    'account_lifecycle_auth_provider_enabled', false,
    'account_lifecycle_production_enabled', false
  ),
  updated_at = clock_timestamp()
where configuration_key = 'primary';

do $assertions$
declare
  v_activation public.account_lifecycle_runtime_activation%rowtype;
  v_policy public.account_lifecycle_policies%rowtype;
  v_external bigint;
  v_registry_count bigint;
begin
  select * into v_activation
  from public.account_lifecycle_runtime_activation
  where activation_key = 'primary';

  select * into v_policy
  from public.account_lifecycle_policies
  where policy_code = 'ACCOUNT_DELETION_STANDARD'
    and policy_version = 1;

  select count(*) into v_registry_count
  from public.account_erasure_storage_registry
  where bucket_code = 'club-avatars'
    and registry_version = 1
    and active
    and approved
    and retired_at is null;

  select
      (select count(*) from public.account_erasure_external_commands)
    + (select count(*) from public.account_erasure_external_attempts)
    + (select count(*) from public.account_erasure_external_receipts)
  into v_external;

  if v_activation.activation_level <> 2
     or v_activation.activation_mode <> 'certification'
     or v_activation.observed_state <> 'idle'
     or not v_activation.storage_provider_enabled
     or v_activation.auth_provider_enabled
     or v_activation.production_scope_enabled
     or v_activation.stop_before_step_order <> 150
     or not coalesce((v_policy.policy_config ->> 'storage_deletion_enabled')::boolean,false)
     or not coalesce((v_policy.policy_config ->> 'profile_deletion_enabled')::boolean,false)
     or not coalesce((v_policy.policy_config ->> 'pre_auth_certification_enabled')::boolean,false)
     or coalesce((v_policy.policy_config ->> 'auth_deletion_enabled')::boolean,false)
     or v_registry_count <> 1
     or v_external <> 0
  then
    raise exception 'MIGRATION_180_ACTIVATION_ASSERTION_FAILED';
  end if;
end;
$assertions$;


update public.account_lifecycle_runtime_activation
set
  last_transition_code =
    'ACCOUNT_LIFECYCLE_LEVEL2_DISPATCHER_ENABLED',
  version = version + 1,
  updated_at = clock_timestamp()
where activation_key = 'primary';
commit;
