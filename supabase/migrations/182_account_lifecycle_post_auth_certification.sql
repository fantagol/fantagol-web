\set ON_ERROR_STOP on

begin;

-- FantaGol Migration 182
-- Post-Auth certification controlled activation.
-- Enables steps 160 and 170 for the approved certification run only.
-- Stops before terminal certification step 180.
-- Production scope remains disabled.

do $preflight$
declare
  v_activation public.account_lifecycle_runtime_activation%rowtype;
  v_lifecycle public.account_lifecycle%rowtype;
  v_run public.account_erasure_runs%rowtype;
  v_policy public.account_lifecycle_policies%rowtype;
  v_step_150 public.account_erasure_steps%rowtype;
  v_step_160 public.account_erasure_steps%rowtype;
  v_step_170 public.account_erasure_steps%rowtype;
  v_step_180 public.account_erasure_steps%rowtype;
  v_auth_commands bigint;
  v_auth_attempts bigint;
  v_auth_receipts bigint;
begin
  select *
    into v_activation
  from public.account_lifecycle_runtime_activation
  where activation_key = 'primary'
  for update;

  if not found
     or v_activation.activation_level <> 3
     or v_activation.activation_mode <> 'certification'
     or v_activation.desired_state <> 'certification'
     or v_activation.observed_state <> 'idle'
     or v_activation.stop_before_step_order <> 160
     or not v_activation.claims_enabled
     or not v_activation.workers_enabled
     or not v_activation.recovery_enabled
     or not v_activation.reconciliation_enabled
     or not v_activation.storage_provider_enabled
     or not v_activation.auth_provider_enabled
     or v_activation.production_scope_enabled
     or v_activation.certification_account_lifecycle_id <>
       '6b644375-da81-4714-9ce7-2fcd4b649fd4'::uuid
     or v_activation.certification_erasure_run_id <>
       '1bd7fe36-343a-4b6f-895e-6ec9b93e73d1'::uuid
  then
    raise exception
      'MIGRATION_182_ACTIVATION_BASELINE_INVALID';
  end if;

  select *
    into v_lifecycle
  from public.account_lifecycle
  where id = v_activation.certification_account_lifecycle_id
  for update;

  select *
    into v_run
  from public.account_erasure_runs
  where id = v_activation.certification_erasure_run_id
  for update;

  select *
    into v_policy
  from public.account_lifecycle_policies
  where id = v_run.policy_id
  for update;

  select *
    into v_step_150
  from public.account_erasure_steps
  where erasure_run_id = v_run.id
    and step_order = 150
  for update;

  select *
    into v_step_160
  from public.account_erasure_steps
  where erasure_run_id = v_run.id
    and step_order = 160
  for update;

  select *
    into v_step_170
  from public.account_erasure_steps
  where erasure_run_id = v_run.id
    and step_order = 170
  for update;

  select *
    into v_step_180
  from public.account_erasure_steps
  where erasure_run_id = v_run.id
    and step_order = 180
  for update;

  select count(*)
    into v_auth_commands
  from public.account_erasure_external_commands
  where erasure_run_id = v_run.id
    and command_type = 'DELETE_SUPABASE_AUTH_IDENTITY'
    and command_status = 'completed';

  select count(*)
    into v_auth_attempts
  from public.account_erasure_external_attempts a
  join public.account_erasure_external_commands c
    on c.id = a.command_id
  where c.erasure_run_id = v_run.id
    and c.command_type = 'DELETE_SUPABASE_AUTH_IDENTITY'
    and a.attempt_status = 'succeeded';

  select count(*)
    into v_auth_receipts
  from public.account_erasure_external_receipts r
  join public.account_erasure_external_commands c
    on c.id = r.command_id
  where c.erasure_run_id = v_run.id
    and c.command_type = 'DELETE_SUPABASE_AUTH_IDENTITY'
    and r.receipt_type = 'AUTH_DELETION'
    and r.receipt_status = 'verified_success';

  if v_lifecycle.lifecycle_status <> 'erasure_running'
     or v_lifecycle.auth_user_id is not null
     or v_lifecycle.auth_deleted_at is null
     or v_run.run_status <> 'running'
     or v_run.blocker_code is not null
     or v_step_150.step_status <> 'completed'
     or v_step_150.attempt_count <> 1
     or v_step_160.step_status <> 'pending'
     or v_step_160.attempt_count <> 0
     or v_step_170.step_status <> 'pending'
     or v_step_170.attempt_count <> 0
     or v_step_180.step_status <> 'pending'
     or v_step_180.attempt_count <> 0
     or v_auth_commands <> 1
     or v_auth_attempts <> 1
     or v_auth_receipts <> 1
     or not coalesce(
       (
         v_policy.policy_config
         ->> 'auth_deletion_enabled'
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
      'MIGRATION_182_POST_AUTH_BASELINE_INVALID';
  end if;
end;
$preflight$;

update public.account_lifecycle_policies
set
  automatic_execution_enabled = true,
  policy_config =
    policy_config || jsonb_build_object(
      'runtime_activation_level', 4,
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
      'auth_deletion_enabled', true,
      'auth_handler_installed', true,
      'post_auth_certification_enabled', true,
      'final_audit_enabled', true,
      'terminal_certification_enabled', false,
      'certification_scope_enabled', true,
      'certification_account_lifecycle_id',
        '6b644375-da81-4714-9ce7-2fcd4b649fd4',
      'certification_erasure_run_id',
        '1bd7fe36-343a-4b6f-895e-6ec9b93e73d1',
      'certification_stop_before_step_order', 180,
      'production_scope_enabled', false,
      'post_auth_activation_migration', 182,
      'post_auth_activation_scope',
        'approved_lifecycle_only'
    ),
  updated_at = clock_timestamp()
where policy_code = 'ACCOUNT_DELETION_STANDARD'
  and policy_version = 1;

update public.account_lifecycle_runtime_activation
set
  activation_level = 4,
  activation_mode = 'certification',
  desired_state = 'certification',
  observed_state = 'idle',
  stop_before_step_order = 180,
  claims_enabled = true,
  workers_enabled = true,
  recovery_enabled = true,
  reconciliation_enabled = true,
  storage_provider_enabled = true,
  auth_provider_enabled = true,
  production_scope_enabled = false,
  last_transition_code =
    'ACCOUNT_LIFECYCLE_POST_AUTH_CERTIFICATION_ACTIVATED',
  last_error_code = null,
  version = version + 1,
  updated_at = clock_timestamp()
where activation_key = 'primary';

update public.platform_engine_registry
set
  lifecycle_status = 'active',
  runtime_enabled = true,
  is_certified = false,
  metadata =
    metadata || jsonb_build_object(
      'runtime_activation_level', 4,
      'runtime_desired_state', 'certification',
      'runtime_observed_state', 'idle',
      'post_auth_activation_migration', 182,
      'storage_provider_enabled', true,
      'auth_provider_enabled', true,
      'post_auth_certification_enabled', true,
      'final_audit_enabled', true,
      'terminal_certification_enabled', false,
      'production_scope_enabled', false,
      'certification_stop_before_step_order', 180,
      'certification_scope', 'approved_lifecycle_only'
    ),
  updated_at = clock_timestamp()
where engine_code = 'account_lifecycle_engine';

update public.platform_configuration
set
  schema_version = 182,
  metadata =
    metadata || jsonb_build_object(
      'account_lifecycle_runtime_activation_level', 4,
      'account_lifecycle_post_auth_activation_migration', 182,
      'account_lifecycle_post_auth_certification_enabled', true,
      'account_lifecycle_final_audit_enabled', true,
      'account_lifecycle_terminal_certification_enabled', false,
      'account_lifecycle_production_enabled', false,
      'account_lifecycle_certification_stop_before_step_order',
        180
    ),
  updated_at = clock_timestamp()
where configuration_key = 'primary';

do $assertions$
declare
  v_activation public.account_lifecycle_runtime_activation%rowtype;
  v_policy public.account_lifecycle_policies%rowtype;
  v_step_160 public.account_erasure_steps%rowtype;
  v_step_170 public.account_erasure_steps%rowtype;
  v_step_180 public.account_erasure_steps%rowtype;
begin
  select *
    into v_activation
  from public.account_lifecycle_runtime_activation
  where activation_key = 'primary';

  select *
    into v_policy
  from public.account_lifecycle_policies
  where policy_code = 'ACCOUNT_DELETION_STANDARD'
    and policy_version = 1;

  select *
    into v_step_160
  from public.account_erasure_steps
  where erasure_run_id =
    v_activation.certification_erasure_run_id
    and step_order = 160;

  select *
    into v_step_170
  from public.account_erasure_steps
  where erasure_run_id =
    v_activation.certification_erasure_run_id
    and step_order = 170;

  select *
    into v_step_180
  from public.account_erasure_steps
  where erasure_run_id =
    v_activation.certification_erasure_run_id
    and step_order = 180;

  if v_activation.activation_level <> 4
     or v_activation.activation_mode <> 'certification'
     or v_activation.desired_state <> 'certification'
     or v_activation.observed_state <> 'idle'
     or v_activation.stop_before_step_order <> 180
     or not v_activation.storage_provider_enabled
     or not v_activation.auth_provider_enabled
     or v_activation.production_scope_enabled
     or not coalesce(
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
     or v_step_160.step_status <> 'pending'
     or v_step_170.step_status <> 'pending'
     or v_step_180.step_status <> 'pending'
  then
    raise exception
      'MIGRATION_182_ACTIVATION_ASSERTION_FAILED';
  end if;
end;
$assertions$;

commit;
