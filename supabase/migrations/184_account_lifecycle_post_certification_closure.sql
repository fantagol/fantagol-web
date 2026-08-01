\set ON_ERROR_STOP on

begin;

-- Migration 184
-- Post-certification closure.
-- Retires the approved certification scope after a fully completed
-- account deletion lifecycle.
-- Production scope remains disabled.

do $preflight$
declare
  v_activation public.account_lifecycle_runtime_activation%rowtype;
  v_policy public.account_lifecycle_policies%rowtype;
  v_lifecycle public.account_lifecycle%rowtype;
  v_run public.account_erasure_runs%rowtype;
  v_request public.account_deletion_requests%rowtype;
  v_completed_steps bigint;
  v_total_steps bigint;
  v_completed_commands bigint;
  v_total_commands bigint;
  v_verified_receipts bigint;
  v_total_receipts bigint;
  v_final_audit_rows bigint;
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
    '6b644375-da81-4714-9ce7-2fcd4b649fd4'::uuid
  for update;

  select *
    into v_run
  from public.account_erasure_runs
  where id =
    '1bd7fe36-343a-4b6f-895e-6ec9b93e73d1'::uuid
  for update;

  select *
    into v_request
  from public.account_deletion_requests
  where id = v_run.deletion_request_id
  for update;

  select count(*),
         count(*) filter (where step_status = 'completed')
    into v_total_steps, v_completed_steps
  from public.account_erasure_steps
  where erasure_run_id = v_run.id;

  select count(*),
         count(*) filter (where command_status = 'completed')
    into v_total_commands, v_completed_commands
  from public.account_erasure_external_commands
  where erasure_run_id = v_run.id;

  select count(*),
         count(*) filter (
           where receipt_status in (
             'verified_success',
             'verified_already_absent'
           )
         )
    into v_total_receipts, v_verified_receipts
  from public.account_erasure_external_receipts r
  join public.account_erasure_external_commands c
    on c.id = r.command_id
  where c.erasure_run_id = v_run.id;

  select count(*)
    into v_final_audit_rows
  from public.account_deletion_audit
  where account_lifecycle_id = v_lifecycle.id
    and erasure_run_id = v_run.id
    and event_code = 'ACCOUNT_DELETED'
    and event_result = 'completed'
    and step_code = 'WRITE_FINAL_NON_IDENTIFYING_AUDIT';

  if v_activation.activation_level <> 5
     or v_activation.activation_mode <> 'certification'
     or v_activation.desired_state <> 'certification'
     or v_activation.observed_state <> 'idle'
     or v_activation.stop_before_step_order <> 190
     or v_activation.production_scope_enabled
     or v_activation.certification_account_lifecycle_id <>
       v_lifecycle.id
     or v_activation.certification_erasure_run_id <>
       v_run.id
     or v_lifecycle.lifecycle_status <> 'deleted'
     or v_lifecycle.auth_user_id is not null
     or v_lifecycle.auth_deleted_at is null
     or v_lifecycle.completed_at is null
     or v_run.run_status <> 'completed'
     or v_run.completed_at is null
     or v_request.request_status <> 'completed'
     or v_total_steps <> 18
     or v_completed_steps <> 18
     or v_total_commands <> 2
     or v_completed_commands <> 2
     or v_total_receipts <> 2
     or v_verified_receipts <> 2
     or v_final_audit_rows <> 1
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
      'MIGRATION_184_POST_CERTIFICATION_BASELINE_INVALID';
  end if;
end;
$preflight$;

update public.account_lifecycle_policies
set
  automatic_execution_enabled = false,
  policy_config =
    policy_config || jsonb_build_object(
      'runtime_activation_level', 0,
      'runtime_activation_mode', 'disabled',
      'runtime_launch_enabled', false,
      'runtime_claim_enabled', false,
      'runtime_worker_enabled', false,
      'server_orchestrator_enabled', false,
      'external_command_execution_enabled', false,
      'external_receipt_acceptance_enabled', false,
      'external_recovery_enabled', false,
      'external_reconciliation_enabled', false,
      'terminal_certification_enabled', false,
      'certification_scope_enabled', false,
      'certification_account_lifecycle_id', null,
      'certification_erasure_run_id', null,
      'certification_stop_before_step_order', null,
      'production_scope_enabled', false,
      'post_certification_closure_migration', 184,
      'post_certification_state', 'closed'
    ),
  updated_at = clock_timestamp()
where policy_code = 'ACCOUNT_DELETION_STANDARD'
  and policy_version = 1;

update public.account_lifecycle_runtime_activation
set
  activation_level = 0,
  activation_mode = 'disabled',
  desired_state = 'disabled',
  observed_state = 'stopped',
  stop_before_step_order = null,
  claims_enabled = false,
  workers_enabled = false,
  recovery_enabled = false,
  reconciliation_enabled = false,
  storage_provider_enabled = false,
  auth_provider_enabled = false,
  production_scope_enabled = false,
  certification_account_lifecycle_id = null,
  certification_erasure_run_id = null,
  last_scheduler_at = null,
  last_dispatcher_at = null,
  last_worker_at = null,
  last_transition_code =
    'ACCOUNT_LIFECYCLE_CERTIFICATION_CLOSED',
  last_error_code = null,
  version = version + 1,
  updated_at = clock_timestamp()
where activation_key = 'primary';

update public.platform_engine_registry
set
  runtime_enabled = false,
  is_certified = true,
  certification_version = '1.0.0',
  certified_at = coalesce(certified_at, clock_timestamp()),
  metadata =
    metadata || jsonb_build_object(
      'runtime_activation_level', 0,
      'runtime_desired_state', 'disabled',
      'runtime_observed_state', 'stopped',
      'certification_closed', true,
      'certification_closed_migration', 184,
      'terminal_certification_enabled', false,
      'production_scope_enabled', false,
      'certification_scope', null,
      'certification_version', '1.0.0',
      'certification_result',
        'account_lifecycle_end_to_end_pass'
    ),
  updated_at = clock_timestamp()
where engine_code = 'account_lifecycle_engine';

update public.platform_configuration
set
  schema_version = 184,
  metadata =
    metadata || jsonb_build_object(
      'account_lifecycle_runtime_activation_level', 0,
      'account_lifecycle_certification_closed', true,
      'account_lifecycle_certification_closed_migration', 184,
      'account_lifecycle_terminal_certification_enabled', false,
      'account_lifecycle_production_enabled', false
    ),
  updated_at = clock_timestamp()
where configuration_key = 'primary';

do $assertions$
declare
  v_activation public.account_lifecycle_runtime_activation%rowtype;
  v_policy public.account_lifecycle_policies%rowtype;
  v_lifecycle public.account_lifecycle%rowtype;
  v_run public.account_erasure_runs%rowtype;
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
    into v_lifecycle
  from public.account_lifecycle
  where id =
    '6b644375-da81-4714-9ce7-2fcd4b649fd4'::uuid;

  select *
    into v_run
  from public.account_erasure_runs
  where id =
    '1bd7fe36-343a-4b6f-895e-6ec9b93e73d1'::uuid;

  if v_activation.activation_level <> 0
     or v_activation.activation_mode <> 'disabled'
     or v_activation.desired_state <> 'disabled'
     or v_activation.observed_state <> 'stopped'
     or v_activation.stop_before_step_order is not null
     or v_activation.claims_enabled
     or v_activation.workers_enabled
     or v_activation.recovery_enabled
     or v_activation.reconciliation_enabled
     or v_activation.storage_provider_enabled
     or v_activation.auth_provider_enabled
     or v_activation.production_scope_enabled
     or v_activation.certification_account_lifecycle_id is not null
     or v_activation.certification_erasure_run_id is not null
     or v_policy.automatic_execution_enabled
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
     or v_lifecycle.lifecycle_status <> 'deleted'
     or v_lifecycle.completed_at is null
     or v_run.run_status <> 'completed'
     or v_run.completed_at is null
  then
    raise exception
      'MIGRATION_184_POST_CERTIFICATION_ASSERTION_FAILED';
  end if;
end;
$assertions$;

commit;
