\set ON_ERROR_STOP on

begin;

-- Migration 183
-- Controlled terminal certification activation for the approved
-- certification lifecycle/run only.
-- Production scope remains disabled.

do $preflight$
declare
  v_activation public.account_lifecycle_runtime_activation%rowtype;
  v_policy public.account_lifecycle_policies%rowtype;
  v_lifecycle public.account_lifecycle%rowtype;
  v_run public.account_erasure_runs%rowtype;
  v_step_180 public.account_erasure_steps%rowtype;
  v_completed_steps bigint;
  v_final_audit_rows bigint;
  v_completed_commands bigint;
  v_verified_receipts bigint;
begin
  select *
    into v_activation
  from public.account_lifecycle_runtime_activation
  where activation_key = 'primary'
  for update;

  select *
    into v_policy
  from public.account_lifecycle_policies
  where policy_code = 'ACCOUNT_DELETION_STANDARD'
    and policy_version = 1
  for update;

  select *
    into v_lifecycle
  from public.account_lifecycle
  where id =
    v_activation.certification_account_lifecycle_id
  for update;

  select *
    into v_run
  from public.account_erasure_runs
  where id =
    v_activation.certification_erasure_run_id
  for update;

  select *
    into v_step_180
  from public.account_erasure_steps
  where erasure_run_id = v_run.id
    and step_order = 180
  for update;

  select count(*)
    into v_completed_steps
  from public.account_erasure_steps
  where erasure_run_id = v_run.id
    and step_order between 10 and 170
    and step_status = 'completed';

  select count(*)
    into v_final_audit_rows
  from public.account_deletion_audit
  where account_lifecycle_id = v_lifecycle.id
    and erasure_run_id = v_run.id
    and event_code = 'ACCOUNT_DELETED'
    and event_result = 'completed'
    and step_code = 'WRITE_FINAL_NON_IDENTIFYING_AUDIT';

  select count(*)
    into v_completed_commands
  from public.account_erasure_external_commands
  where erasure_run_id = v_run.id
    and command_status = 'completed';

  select count(*)
    into v_verified_receipts
  from public.account_erasure_external_receipts r
  join public.account_erasure_external_commands c
    on c.id = r.command_id
  where c.erasure_run_id = v_run.id
    and r.receipt_status in (
      'verified_success',
      'verified_already_absent'
    );

  if v_activation.activation_level <> 4
     or v_activation.activation_mode <> 'certification'
     or v_activation.desired_state <> 'certification'
     or v_activation.observed_state <> 'idle'
     or v_activation.stop_before_step_order <> 180
     or not v_activation.storage_provider_enabled
     or not v_activation.auth_provider_enabled
     or v_activation.production_scope_enabled
     or v_lifecycle.lifecycle_status <> 'erasure_running'
     or v_lifecycle.auth_user_id is not null
     or v_lifecycle.auth_deleted_at is null
     or v_lifecycle.completed_at is not null
     or v_run.run_status <> 'running'
     or v_run.completed_at is not null
     or v_completed_steps <> 17
     or v_step_180.step_code <> 'CERTIFY_ACCOUNT_DELETION'
     or v_step_180.step_status <> 'pending'
     or v_step_180.attempt_count <> 0
     or v_final_audit_rows <> 1
     or v_completed_commands <> 2
     or v_verified_receipts <> 2
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
     or coalesce(
       (
         v_policy.policy_config
         ->> 'production_scope_enabled'
       )::boolean,
       false
     )
  then
    raise exception
      'MIGRATION_183_TERMINAL_ACTIVATION_BASELINE_INVALID';
  end if;
end;
$preflight$;

update public.account_lifecycle_policies
set
  policy_config =
    policy_config || jsonb_build_object(
      'runtime_activation_level', 5,
      'runtime_activation_mode', 'certification',
      'terminal_certification_enabled', true,
      'certification_stop_before_step_order', 190,
      'production_scope_enabled', false,
      'terminal_activation_migration', 183,
      'terminal_activation_scope',
        'approved_lifecycle_only'
    ),
  updated_at = clock_timestamp()
where policy_code = 'ACCOUNT_DELETION_STANDARD'
  and policy_version = 1;

update public.account_lifecycle_runtime_activation
set
  activation_level = 5,
  activation_mode = 'certification',
  desired_state = 'certification',
  observed_state = 'idle',
  stop_before_step_order = 190,
  storage_provider_enabled = true,
  auth_provider_enabled = true,
  production_scope_enabled = false,
  last_transition_code =
    'ACCOUNT_LIFECYCLE_TERMINAL_CERTIFICATION_ACTIVATED',
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
      'runtime_activation_level', 5,
      'terminal_certification_enabled', true,
      'production_scope_enabled', false,
      'certification_stop_before_step_order', 190,
      'terminal_activation_migration', 183,
      'terminal_activation_scope',
        'approved_lifecycle_only'
    ),
  updated_at = clock_timestamp()
where engine_code = 'account_lifecycle_engine';

update public.platform_configuration
set
  schema_version = 183,
  metadata =
    metadata || jsonb_build_object(
      'account_lifecycle_runtime_activation_level', 5,
      'account_lifecycle_terminal_activation_migration', 183,
      'account_lifecycle_terminal_certification_enabled', true,
      'account_lifecycle_production_enabled', false,
      'account_lifecycle_certification_stop_before_step_order',
        190
    ),
  updated_at = clock_timestamp()
where configuration_key = 'primary';

do $assertions$
declare
  v_activation public.account_lifecycle_runtime_activation%rowtype;
  v_policy public.account_lifecycle_policies%rowtype;
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
    into v_step_180
  from public.account_erasure_steps
  where erasure_run_id =
    v_activation.certification_erasure_run_id
    and step_order = 180;

  if v_activation.activation_level <> 5
     or v_activation.activation_mode <> 'certification'
     or v_activation.desired_state <> 'certification'
     or v_activation.observed_state <> 'idle'
     or v_activation.stop_before_step_order <> 190
     or v_activation.production_scope_enabled
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
     or v_step_180.step_status <> 'pending'
     or v_step_180.attempt_count <> 0
  then
    raise exception
      'MIGRATION_183_TERMINAL_ACTIVATION_ASSERTION_FAILED';
  end if;
end;
$assertions$;

commit;
