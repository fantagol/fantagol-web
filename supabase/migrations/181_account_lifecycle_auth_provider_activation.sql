\set ON_ERROR_STOP on

begin;

-- FantaGol Phase 181 — Supabase Auth Provider Controlled Activation
-- Level 3 certification only.
-- Scope: one approved lifecycle/run.
-- Production scope remains disabled.
-- This migration does not call Supabase Auth and does not delete any identity.

do $preflight$
declare
  v_activation public.account_lifecycle_runtime_activation%rowtype;
  v_lifecycle public.account_lifecycle%rowtype;
  v_run public.account_erasure_runs%rowtype;
  v_step_150 public.account_erasure_steps%rowtype;
  v_completed bigint;
  v_commands bigint;
  v_attempts bigint;
  v_receipts bigint;
  v_storage_receipts bigint;
  v_auth_commands bigint;
  v_policy public.account_lifecycle_policies%rowtype;
begin
  select *
    into v_activation
  from public.account_lifecycle_runtime_activation
  where activation_key = 'primary'
  for update;

  if not found
     or v_activation.activation_level <> 2
     or v_activation.activation_mode <> 'certification'
     or v_activation.desired_state <> 'certification'
     or v_activation.observed_state <> 'certification_paused'
     or v_activation.stop_before_step_order <> 150
     or not v_activation.claims_enabled
     or not v_activation.workers_enabled
     or not v_activation.recovery_enabled
     or not v_activation.reconciliation_enabled
     or not v_activation.storage_provider_enabled
     or v_activation.auth_provider_enabled
     or v_activation.production_scope_enabled
     or v_activation.certification_account_lifecycle_id <>
       '6b644375-da81-4714-9ce7-2fcd4b649fd4'::uuid
     or v_activation.certification_erasure_run_id <>
       '1bd7fe36-343a-4b6f-895e-6ec9b93e73d1'::uuid
  then
    raise exception
      'MIGRATION_181_ACTIVATION_BASELINE_INVALID';
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
    into v_step_150
  from public.account_erasure_steps
  where erasure_run_id = v_run.id
    and step_order = 150
  for update;

  select *
    into v_policy
  from public.account_lifecycle_policies
  where id = v_run.policy_id
  for update;

  select count(*)
    into v_completed
  from public.account_erasure_steps
  where erasure_run_id = v_run.id
    and step_order between 10 and 140
    and step_status = 'completed';

  select count(*)
    into v_commands
  from public.account_erasure_external_commands
  where erasure_run_id = v_run.id;

  select count(*)
    into v_attempts
  from public.account_erasure_external_attempts a
  join public.account_erasure_external_commands c
    on c.id = a.command_id
  where c.erasure_run_id = v_run.id;

  select count(*)
    into v_receipts
  from public.account_erasure_external_receipts r
  join public.account_erasure_external_commands c
    on c.id = r.command_id
  where c.erasure_run_id = v_run.id;

  select count(*)
    into v_storage_receipts
  from public.account_erasure_external_receipts r
  join public.account_erasure_external_commands c
    on c.id = r.command_id
  where c.erasure_run_id = v_run.id
    and c.command_type = 'DELETE_STORAGE_ASSETS'
    and c.command_status = 'completed'
    and r.receipt_type = 'STORAGE_DELETION'
    and r.receipt_status in (
      'verified_success',
      'verified_already_absent'
    )
    and r.residual_object_count = 0;

  select count(*)
    into v_auth_commands
  from public.account_erasure_external_commands
  where erasure_run_id = v_run.id
    and command_type = 'DELETE_SUPABASE_AUTH_IDENTITY';

  if v_lifecycle.lifecycle_status <> 'erasure_running'
     or v_lifecycle.auth_user_id is null
     or v_lifecycle.auth_deleted_at is not null
     or v_run.run_status <> 'running'
     or v_run.blocker_code is not null
     or v_completed <> 14
     or v_step_150.step_code <>
       'DELETE_SUPABASE_AUTH_IDENTITY'
     or v_step_150.step_status <> 'pending'
     or v_step_150.attempt_count <> 0
     or v_commands <> 1
     or v_attempts <> 2
     or v_receipts <> 1
     or v_storage_receipts <> 1
     or v_auth_commands <> 0
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
      'MIGRATION_181_AUTH_BASELINE_INVALID';
  end if;
end;
$preflight$;

update public.account_lifecycle_policies
set
  automatic_execution_enabled = true,
  policy_config =
    policy_config || jsonb_build_object(
      'runtime_activation_level', 3,
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
      'post_auth_certification_enabled', false,
      'final_audit_enabled', false,
      'terminal_certification_enabled', false,
      'certification_scope_enabled', true,
      'certification_account_lifecycle_id',
        '6b644375-da81-4714-9ce7-2fcd4b649fd4',
      'certification_erasure_run_id',
        '1bd7fe36-343a-4b6f-895e-6ec9b93e73d1',
      'certification_stop_before_step_order', 160,
      'production_scope_enabled', false,
      'auth_activation_migration', 181,
      'auth_activation_scope', 'approved_lifecycle_only'
    ),
  updated_at = clock_timestamp()
where policy_code = 'ACCOUNT_DELETION_STANDARD'
  and policy_version = 1;

update public.account_lifecycle_runtime_activation
set
  activation_level = 3,
  activation_mode = 'certification',
  desired_state = 'certification',
  observed_state = 'idle',
  stop_before_step_order = 160,
  claims_enabled = true,
  workers_enabled = true,
  recovery_enabled = true,
  reconciliation_enabled = true,
  storage_provider_enabled = true,
  auth_provider_enabled = true,
  production_scope_enabled = false,
  last_transition_code =
    'ACCOUNT_LIFECYCLE_AUTH_CERTIFICATION_ACTIVATED',
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
      'runtime_activation_level', 3,
      'runtime_desired_state', 'certification',
      'runtime_observed_state', 'idle',
      'auth_activation_migration', 181,
      'storage_provider_enabled', true,
      'auth_provider_enabled', true,
      'production_scope_enabled', false,
      'certification_stop_before_step_order', 160,
      'certification_scope', 'approved_lifecycle_only'
    ),
  updated_at = clock_timestamp()
where engine_code = 'account_lifecycle_engine';

update public.platform_configuration
set
  schema_version = 181,
  metadata =
    metadata || jsonb_build_object(
      'account_lifecycle_runtime_activation_level', 3,
      'account_lifecycle_auth_activation_migration', 181,
      'account_lifecycle_storage_provider_enabled', true,
      'account_lifecycle_auth_provider_enabled', true,
      'account_lifecycle_production_enabled', false,
      'account_lifecycle_certification_stop_before_step_order',
        160
    ),
  updated_at = clock_timestamp()
where configuration_key = 'primary';

do $assertions$
declare
  v_activation public.account_lifecycle_runtime_activation%rowtype;
  v_policy public.account_lifecycle_policies%rowtype;
  v_step_150 public.account_erasure_steps%rowtype;
  v_auth_commands bigint;
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
    into v_step_150
  from public.account_erasure_steps
  where erasure_run_id =
    v_activation.certification_erasure_run_id
    and step_order = 150;

  select count(*)
    into v_auth_commands
  from public.account_erasure_external_commands
  where erasure_run_id =
    v_activation.certification_erasure_run_id
    and command_type = 'DELETE_SUPABASE_AUTH_IDENTITY';

  if v_activation.activation_level <> 3
     or v_activation.activation_mode <> 'certification'
     or v_activation.desired_state <> 'certification'
     or v_activation.observed_state <> 'idle'
     or v_activation.stop_before_step_order <> 160
     or not v_activation.storage_provider_enabled
     or not v_activation.auth_provider_enabled
     or v_activation.production_scope_enabled
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
     or v_step_150.step_status <> 'pending'
     or v_step_150.attempt_count <> 0
     or v_auth_commands <> 0
  then
    raise exception
      'MIGRATION_181_ACTIVATION_ASSERTION_FAILED';
  end if;
end;
$assertions$;

commit;
