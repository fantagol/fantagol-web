-- ============================================================================
-- FANTAGOL
-- Migration 179: Account Lifecycle Controlled Runtime Activation
-- Phase 13.9.2
--
-- Activates Level 1 certification orchestration for one approved lifecycle/run.
-- Storage and Auth provider execution remain disabled.
-- ============================================================================

begin;

set local lock_timeout = '10s';
set local statement_timeout = '0';

do $preflight$
declare
  v_schema_version integer;
  v_engine public.platform_engine_registry%rowtype;
  v_policy public.account_lifecycle_policies%rowtype;
  v_lifecycle public.account_lifecycle%rowtype;
  v_run public.account_erasure_runs%rowtype;
  v_step_count bigint;
  v_non_pending bigint;
  v_external_rows bigint;
begin
  select schema_version
    into v_schema_version
  from public.platform_configuration
  where configuration_key = 'primary';

  if v_schema_version <> 177 then
    raise exception
      'MIGRATION_179_REQUIRES_SCHEMA_VERSION_177, found %',
      v_schema_version;
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
     or v_policy.automatic_execution_enabled then
    raise exception 'MIGRATION_179_REQUIRES_DISABLED_RUNTIME';
  end if;

  select *
    into v_lifecycle
  from public.account_lifecycle
  where id = '6b644375-da81-4714-9ce7-2fcd4b649fd4'::uuid;

  if not found
     or v_lifecycle.auth_user_id is distinct from
       '3068cf3b-8251-4817-8a7b-377ef14ba71d'::uuid
     or v_lifecycle.lifecycle_status <> 'deletion_scheduled'
  then
    raise exception 'MIGRATION_179_CERTIFICATION_LIFECYCLE_INVALID';
  end if;

  select *
    into v_run
  from public.account_erasure_runs
  where id = '1bd7fe36-343a-4b6f-895e-6ec9b93e73d1'::uuid
    and account_lifecycle_id = v_lifecycle.id;

  if not found
     or v_run.run_status <> 'scheduled'
     or v_run.workflow_id is not null
     or v_run.lease_token is not null
  then
    raise exception 'MIGRATION_179_CERTIFICATION_RUN_INVALID';
  end if;

  select
    count(*),
    count(*) filter (where step_status <> 'pending')
  into v_step_count, v_non_pending
  from public.account_erasure_steps
  where erasure_run_id = v_run.id;

  if v_step_count <> 18 or v_non_pending <> 0 then
    raise exception
      'MIGRATION_179_STEP_BASELINE_INVALID: count %, non_pending %',
      v_step_count,
      v_non_pending;
  end if;

  select
      (select count(*) from public.account_erasure_external_commands)
    + (select count(*) from public.account_erasure_external_attempts)
    + (select count(*) from public.account_erasure_external_receipts)
  into v_external_rows;

  if v_external_rows <> 0 then
    raise exception
      'MIGRATION_179_REQUIRES_ZERO_EXTERNAL_ROWS, found %',
      v_external_rows;
  end if;
end;
$preflight$;

-- Phase 179 Workflow Engine scope compatibility.
-- Account Lifecycle is a first-class workflow scope.
alter table public.live_runtime_workflows
  drop constraint if exists live_runtime_workflows_scope_check;

alter table public.live_runtime_workflows
  add constraint live_runtime_workflows_scope_check
  check (
    scope_type in (
      'match',
      'fantagol_round',
      'league_round',
      'round_simulation',
      'live_state_snapshot',
      'publication',
      'account_lifecycle'
    )
  );

do $workflow_scope_factory$
declare
  v_function_definition text;
  v_updated_definition text;
begin
  select pg_get_functiondef(p.oid)
    into v_function_definition
  from pg_proc p
  join pg_namespace n
    on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname = 'create_live_runtime_workflow_rpc'
    and pg_get_function_identity_arguments(p.oid) =
      'p_workflow_type text, p_scope_type text, p_scope_id uuid, p_idempotency_key text, p_steps jsonb, p_workflow_version integer, p_metadata jsonb, p_correlation_id uuid, p_causation_id uuid, p_trigger_job_id uuid';

  if v_function_definition is null then
    raise exception
      'MIGRATION_179_WORKFLOW_FACTORY_NOT_FOUND';
  end if;

  if v_function_definition ~
     $pattern$'account_lifecycle'$pattern$ then
    return;
  end if;

  v_updated_definition := regexp_replace(
    v_function_definition,
    $pattern$'publication'([[:space:]]*)\)$pattern$,
    $replacement$'publication', 'account_lifecycle'\1)$replacement$,
    'n'
  );

  if v_updated_definition = v_function_definition
     or v_updated_definition !~
       $pattern$'account_lifecycle'$pattern$ then
    raise exception
      'MIGRATION_179_WORKFLOW_FACTORY_SCOPE_PATCH_FAILED';
  end if;

  execute v_updated_definition;
end;
$workflow_scope_factory$;

revoke all on function
public.create_live_runtime_workflow_rpc(
  text,text,uuid,text,jsonb,integer,jsonb,uuid,uuid,uuid
)
from public, anon, authenticated;

grant execute on function
public.create_live_runtime_workflow_rpc(
  text,text,uuid,text,jsonb,integer,jsonb,uuid,uuid,uuid
)
to service_role;

create table if not exists public.account_lifecycle_runtime_activation (
  activation_key text primary key,
  activation_level integer not null,
  activation_mode text not null,
  desired_state text not null,
  observed_state text not null,

  certification_account_lifecycle_id uuid,
  certification_erasure_run_id uuid,
  stop_before_step_order integer,

  claims_enabled boolean not null default false,
  workers_enabled boolean not null default false,
  recovery_enabled boolean not null default false,
  reconciliation_enabled boolean not null default false,

  storage_provider_enabled boolean not null default false,
  auth_provider_enabled boolean not null default false,
  production_scope_enabled boolean not null default false,

  certification_original_scheduled_for timestamptz,
  certification_override_applied_at timestamptz,

  last_scheduler_at timestamptz,
  last_dispatcher_at timestamptz,
  last_worker_at timestamptz,
  last_transition_code text,
  last_error_code text,

  version bigint not null default 1,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),

  constraint account_lifecycle_runtime_activation_lifecycle_fk
    foreign key (certification_account_lifecycle_id)
    references public.account_lifecycle(id)
    on delete restrict,

  constraint account_lifecycle_runtime_activation_run_fk
    foreign key (certification_erasure_run_id)
    references public.account_erasure_runs(id)
    on delete restrict,

  constraint account_lifecycle_runtime_activation_level_ck
    check (activation_level between 0 and 5),

  constraint account_lifecycle_runtime_activation_mode_ck
    check (
      activation_mode in (
        'disabled','certification','production','suspended'
      )
    ),

  constraint account_lifecycle_runtime_activation_desired_ck
    check (
      desired_state in (
        'disabled','certification','production','suspended'
      )
    ),

  constraint account_lifecycle_runtime_activation_observed_ck
    check (
      observed_state in (
        'stopped','starting','idle','claiming','executing',
        'certification_paused','draining','degraded','failed'
      )
    ),

  constraint account_lifecycle_runtime_activation_scope_ck
    check (
      activation_mode <> 'certification'
      or (
        certification_account_lifecycle_id is not null
        and certification_erasure_run_id is not null
        and production_scope_enabled = false
      )
    ),

  constraint account_lifecycle_runtime_activation_provider_ck
    check (
      activation_level >= 2
      or (
        storage_provider_enabled = false
        and auth_provider_enabled = false
      )
    ),

  constraint account_lifecycle_runtime_activation_stop_ck
    check (
      stop_before_step_order is null
      or stop_before_step_order > 0
    ),

  constraint account_lifecycle_runtime_activation_version_ck
    check (version > 0)
);

alter table public.account_lifecycle_runtime_activation enable row level security;
alter table public.account_lifecycle_runtime_activation force row level security;

revoke all privileges
on table public.account_lifecycle_runtime_activation
from public, anon, authenticated, service_role;

insert into public.account_lifecycle_runtime_activation (
  activation_key,
  activation_level,
  activation_mode,
  desired_state,
  observed_state,
  certification_account_lifecycle_id,
  certification_erasure_run_id,
  stop_before_step_order,
  claims_enabled,
  workers_enabled,
  recovery_enabled,
  reconciliation_enabled,
  storage_provider_enabled,
  auth_provider_enabled,
  production_scope_enabled,
  last_transition_code
)
values (
  'primary',
  1,
  'certification',
  'certification',
  'stopped',
  '6b644375-da81-4714-9ce7-2fcd4b649fd4'::uuid,
  '1bd7fe36-343a-4b6f-895e-6ec9b93e73d1'::uuid,
  120,
  true,
  true,
  true,
  true,
  false,
  false,
  false,
  'ACCOUNT_LIFECYCLE_RUNTIME_LEVEL_1_INSTALLED'
)
on conflict (activation_key) do update
set
  activation_level = excluded.activation_level,
  activation_mode = excluded.activation_mode,
  desired_state = excluded.desired_state,
  observed_state = excluded.observed_state,
  certification_account_lifecycle_id =
    excluded.certification_account_lifecycle_id,
  certification_erasure_run_id =
    excluded.certification_erasure_run_id,
  stop_before_step_order = excluded.stop_before_step_order,
  claims_enabled = excluded.claims_enabled,
  workers_enabled = excluded.workers_enabled,
  recovery_enabled = excluded.recovery_enabled,
  reconciliation_enabled = excluded.reconciliation_enabled,
  storage_provider_enabled = false,
  auth_provider_enabled = false,
  production_scope_enabled = false,
  last_transition_code = excluded.last_transition_code,
  last_error_code = null,
  version = public.account_lifecycle_runtime_activation.version + 1,
  updated_at = clock_timestamp();

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

create or replace function
public.activate_account_lifecycle_certification_run_internal(
  p_reason_code text,
  p_correlation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_catalog
as $function$
declare
  v_activation public.account_lifecycle_runtime_activation%rowtype;
  v_run public.account_erasure_runs%rowtype;
  v_reason text := upper(nullif(btrim(p_reason_code), ''));
begin
  if v_reason <> 'PHASE_179_CONTROLLED_RUNTIME_CERTIFICATION' then
    raise exception 'ACCOUNT_LIFECYCLE_CERTIFICATION_REASON_INVALID';
  end if;

  select *
    into v_activation
  from public.account_lifecycle_runtime_activation
  where activation_key = 'primary'
  for update;

  perform public.assert_account_lifecycle_certification_scope_internal(
    v_activation.certification_account_lifecycle_id,
    v_activation.certification_erasure_run_id
  );

  select *
    into v_run
  from public.account_erasure_runs
  where id = v_activation.certification_erasure_run_id
  for update;

  if v_run.run_status <> 'scheduled'
     or v_run.workflow_id is not null then
    raise exception 'ACCOUNT_LIFECYCLE_CERTIFICATION_RUN_NOT_OVERRIDABLE';
  end if;

  update public.account_lifecycle_runtime_activation
  set
    certification_original_scheduled_for =
      coalesce(certification_original_scheduled_for, v_run.scheduled_for),
    certification_override_applied_at = clock_timestamp(),
    observed_state = 'idle',
    last_transition_code =
      'ACCOUNT_DELETION_CERTIFICATION_TIME_OVERRIDE',
    last_error_code = null,
    version = version + 1,
    updated_at = clock_timestamp()
  where activation_key = 'primary';

  update public.account_erasure_runs
  set
    scheduled_for = clock_timestamp(),
    version = version + 1,
    updated_at = clock_timestamp()
  where id = v_run.id;

  update public.account_erasure_steps
  set
    available_at = clock_timestamp(),
    version = version + 1,
    updated_at = clock_timestamp()
  where erasure_run_id = v_run.id
    and step_status = 'pending';

  perform public.append_account_deletion_audit_internal(
    v_run.account_lifecycle_id,
    v_run.id,
    'ACCOUNT_DELETION_SCHEDULED',
    'scheduled',
    null,
    0,
    0,
    null,
    coalesce(p_correlation_id, extensions.gen_random_uuid()),
    null,
    null,
    null,
    jsonb_build_object(
      'reason_code', v_reason,
      'activation_level', 1,
      'original_scheduled_for', v_run.scheduled_for
    )
  );

  return jsonb_build_object(
    'activated', true,
    'account_lifecycle_id', v_run.account_lifecycle_id,
    'erasure_run_id', v_run.id,
    'original_scheduled_for', v_run.scheduled_for,
    'scheduled_for', clock_timestamp()
  );
end;
$function$;

create or replace function
public.claim_account_lifecycle_certification_run_internal(
  p_worker_id text,
  p_lease_seconds integer default 300,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_catalog
as $function$
declare
  v_activation public.account_lifecycle_runtime_activation%rowtype;
  v_run public.account_erasure_runs%rowtype;
  v_worker_id text := nullif(btrim(p_worker_id), '');
  v_lease_seconds integer :=
    greatest(30, least(coalesce(p_lease_seconds, 300), 3600));
  v_token uuid := extensions.gen_random_uuid();
begin
  if v_worker_id is null or length(v_worker_id) < 3 then
    raise exception 'ACCOUNT_ERASURE_WORKER_ID_INVALID';
  end if;

  select *
    into v_activation
  from public.account_lifecycle_runtime_activation
  where activation_key = 'primary'
  for update;

  perform public.assert_account_lifecycle_certification_scope_internal(
    v_activation.certification_account_lifecycle_id,
    v_activation.certification_erasure_run_id
  );

  select *
    into v_run
  from public.account_erasure_runs
  where id = v_activation.certification_erasure_run_id
  for update;

  if v_run.workflow_id is not null
     and v_run.run_status in ('running','blocked') then
    return jsonb_build_object(
      'claimed', true,
      'idempotent_runtime', true,
      'erasure_run_id', v_run.id,
      'account_lifecycle_id', v_run.account_lifecycle_id,
      'workflow_id', v_run.workflow_id,
      'run_status', v_run.run_status,
      'correlation_id', coalesce(
        p_correlation_id,
        extensions.gen_random_uuid()
      )
    );
  end if;

  if v_run.run_status not in ('scheduled','retry_scheduled')
     or v_run.scheduled_for > clock_timestamp()
     or v_run.workflow_id is not null
  then
    return jsonb_build_object(
      'claimed', false,
      'reason', 'CERTIFICATION_RUN_NOT_CLAIMABLE',
      'run_status', v_run.run_status
    );
  end if;

  update public.account_erasure_runs
  set
    run_status = 'leased',
    lease_owner = v_worker_id,
    lease_token = v_token,
    leased_at = clock_timestamp(),
    lease_expires_at =
      clock_timestamp() + make_interval(secs => v_lease_seconds),
    attempt_count = attempt_count + 1,
    version = version + 1,
    updated_at = clock_timestamp()
  where id = v_run.id;

  update public.account_lifecycle_runtime_activation
  set
    observed_state = 'claiming',
    last_worker_at = clock_timestamp(),
    last_transition_code =
      'ACCOUNT_DELETION_CERTIFICATION_RUN_CLAIMED',
    version = version + 1,
    updated_at = clock_timestamp()
  where activation_key = 'primary';

  return jsonb_build_object(
    'claimed', true,
    'idempotent_runtime', false,
    'erasure_run_id', v_run.id,
    'account_lifecycle_id', v_run.account_lifecycle_id,
    'lease_token', v_token,
    'worker_id', v_worker_id,
    'correlation_id', coalesce(
      p_correlation_id,
      extensions.gen_random_uuid()
    )
  );
end;
$function$;

create or replace function
public.pause_account_lifecycle_at_external_boundary_internal(
  p_erasure_run_id uuid,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_catalog
as $function$
declare
  v_run public.account_erasure_runs%rowtype;
  v_step public.account_erasure_steps%rowtype;
  v_incomplete_prior bigint;
  v_external_rows bigint;
begin
  select *
    into v_run
  from public.account_erasure_runs
  where id = p_erasure_run_id
  for update;

  perform public.assert_account_lifecycle_certification_scope_internal(
    v_run.account_lifecycle_id,
    v_run.id
  );

  select *
    into v_step
  from public.account_erasure_steps
  where erasure_run_id = v_run.id
    and step_order = 120
  for update;

  select count(*)
    into v_incomplete_prior
  from public.account_erasure_steps
  where erasure_run_id = v_run.id
    and step_order < 120
    and mandatory
    and step_status <> 'completed';

  select
      (select count(*) from public.account_erasure_external_commands)
    + (select count(*) from public.account_erasure_external_attempts)
    + (select count(*) from public.account_erasure_external_receipts)
  into v_external_rows;

  if v_step.step_code <> 'DELETE_STORAGE_ASSETS'
     or v_incomplete_prior <> 0
     or v_external_rows <> 0 then
    raise exception
      'ACCOUNT_LIFECYCLE_CERTIFICATION_PAUSE_PRECONDITION_FAILED';
  end if;

  if v_run.run_status <> 'running'
     or v_step.step_status <> 'pending'
     or v_step.attempt_count <> 0 then
    raise exception
      'ACCOUNT_LIFECYCLE_CERTIFICATION_PAUSE_STATE_INVALID';
  end if;

  update public.account_lifecycle_runtime_activation
  set
    observed_state = 'certification_paused',
    last_transition_code =
      'ACCOUNT_DELETION_CERTIFICATION_EXTERNAL_BOUNDARY_REACHED',
    last_error_code = null,
    version = version + 1,
    updated_at = clock_timestamp()
  where activation_key = 'primary';

  return jsonb_build_object(
    'paused', true,
    'result_code', 'CERTIFICATION_EXTERNAL_BOUNDARY_REACHED',
    'erasure_run_id', v_run.id,
    'step_id', v_step.id,
    'step_code', v_step.step_code,
    'external_command_count', 0
  );
end;
$function$;

create or replace function
public.execute_account_lifecycle_certification_cycle_internal(
  p_worker_id text,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_catalog
as $function$
declare
  v_activation public.account_lifecycle_runtime_activation%rowtype;
  v_run public.account_erasure_runs%rowtype;
  v_claim jsonb;
  v_launch jsonb;
  v_step public.account_erasure_steps%rowtype;
  v_result jsonb;
  v_correlation_id uuid :=
    coalesce(p_correlation_id, extensions.gen_random_uuid());
begin
  select *
    into v_activation
  from public.account_lifecycle_runtime_activation
  where activation_key = 'primary';

  perform public.assert_account_lifecycle_certification_scope_internal(
    v_activation.certification_account_lifecycle_id,
    v_activation.certification_erasure_run_id
  );

  select *
    into v_run
  from public.account_erasure_runs
  where id = v_activation.certification_erasure_run_id;

  if v_run.run_status = 'blocked'
     and v_run.blocker_code =
       'CERTIFICATION_EXTERNAL_BOUNDARY_REACHED' then
    return jsonb_build_object(
      'result_code', 'RUN_ALREADY_CERTIFICATION_PAUSED',
      'erasure_run_id', v_run.id,
      'run_status', v_run.run_status
    );
  end if;

  if v_run.workflow_id is null then
    v_claim :=
      public.claim_account_lifecycle_certification_run_internal(
        p_worker_id,
        300,
        v_correlation_id
      );

    if not coalesce((v_claim ->> 'claimed')::boolean, false) then
      return v_claim;
    end if;

    v_launch :=
      public.launch_account_deletion_workflow_internal(
        (v_claim ->> 'erasure_run_id')::uuid,
        p_worker_id,
        (v_claim ->> 'lease_token')::uuid,
        v_correlation_id
      );
  else
    v_launch := jsonb_build_object(
      'launched', true,
      'idempotent_replay', true,
      'workflow_id', v_run.workflow_id,
      'erasure_run_id', v_run.id
    );
  end if;

  select *
    into v_step
  from public.account_erasure_steps
  where erasure_run_id = v_activation.certification_erasure_run_id
    and mandatory
    and step_status <> 'completed'
  order by step_order
  limit 1
  for update;

  if not found then
    raise exception 'ACCOUNT_LIFECYCLE_CERTIFICATION_NEXT_STEP_MISSING';
  end if;

  if v_step.step_order < v_activation.stop_before_step_order then
    if v_step.step_order < 120 then
      update public.account_erasure_steps
      set
        step_status = 'running',
        attempt_count = attempt_count + 1,
        started_at = coalesce(started_at, clock_timestamp()),
        blocker_code = null,
        error_code = null,
        error_message = null,
        version = version + 1,
        updated_at = clock_timestamp()
      where id = v_step.id
        and step_status in ('pending','retry_scheduled');

      if not found then
        raise exception
          'ACCOUNT_LIFECYCLE_CERTIFICATION_STEP_NOT_RUNNABLE';
      end if;

      v_result :=
        public.execute_account_erasure_domain_step_internal(v_step.id);
    elsif v_step.step_order in (120, 150) then
      v_result :=
        public.prepare_account_erasure_external_command_internal(
          v_step.id,
          p_worker_id,
          v_correlation_id
        );

      update public.account_lifecycle_runtime_activation
      set
        observed_state = 'idle',
        last_dispatcher_at = clock_timestamp(),
        last_transition_code =
          case v_step.step_order
            when 120 then
              'ACCOUNT_DELETION_STORAGE_COMMAND_PREPARED'
            when 150 then
              'ACCOUNT_DELETION_AUTH_COMMAND_PREPARED'
          end,
        last_error_code = null,
        version = version + 1,
        updated_at = clock_timestamp()
      where activation_key = 'primary';

      return jsonb_build_object(
        'result_code', 'EXTERNAL_COMMAND_PREPARED',
        'launch', v_launch,
        'step_id', v_step.id,
        'step_code', v_step.step_code,
        'command', v_result,
        'correlation_id', v_correlation_id
      );
    else
      update public.account_erasure_steps
      set
        step_status = 'running',
        attempt_count = attempt_count + 1,
        started_at = coalesce(started_at, clock_timestamp()),
        blocker_code = null,
        error_code = null,
        error_message = null,
        version = version + 1,
        updated_at = clock_timestamp()
      where id = v_step.id
        and step_status in ('pending','retry_scheduled');

      if not found then
        raise exception
          'ACCOUNT_LIFECYCLE_CERTIFICATION_STEP_NOT_RUNNABLE';
      end if;

      v_result :=
        public.execute_account_erasure_domain_step_internal(v_step.id);
    end if;

    update public.account_lifecycle_runtime_activation
    set
      observed_state = 'idle',
      last_dispatcher_at = clock_timestamp(),
      last_worker_at = clock_timestamp(),
      last_transition_code =
        'ACCOUNT_DELETION_CERTIFICATION_STEP_COMPLETED',
      last_error_code = null,
      version = version + 1,
      updated_at = clock_timestamp()
    where activation_key = 'primary';

    return jsonb_build_object(
      'result_code', 'STEP_COMPLETED',
      'launch', v_launch,
      'step', v_result,
      'correlation_id', v_correlation_id
    );
  end if;

  if v_step.step_order = v_activation.stop_before_step_order then
    update public.account_lifecycle_runtime_activation
    set
      observed_state = 'certification_paused',
      last_transition_code =
        'ACCOUNT_DELETION_CERTIFICATION_EXTERNAL_BOUNDARY_REACHED',
      last_error_code = null,
      version = version + 1,
      updated_at = clock_timestamp()
    where activation_key = 'primary';

    return jsonb_build_object(
      'paused', true,
      'result_code', 'CERTIFICATION_EXTERNAL_BOUNDARY_REACHED',
      'erasure_run_id', v_activation.certification_erasure_run_id,
      'step_id', v_step.id,
      'step_code', v_step.step_code,
      'external_command_count',
        (
          select count(*)
          from public.account_erasure_external_commands
          where erasure_run_id =
            v_activation.certification_erasure_run_id
        )
    );
  end if;

  raise exception
    'ACCOUNT_LIFECYCLE_CERTIFICATION_STEP_BOUNDARY_VIOLATION';
end;
$function$;

create or replace function
public.get_account_lifecycle_runtime_activation_state_internal()
returns jsonb
language plpgsql
security definer
stable
set search_path = public, pg_catalog
as $function$
declare
  v_activation public.account_lifecycle_runtime_activation%rowtype;
  v_run public.account_erasure_runs%rowtype;
  v_next_step public.account_erasure_steps%rowtype;
  v_completed bigint;
  v_external_commands bigint;
  v_external_attempts bigint;
  v_external_receipts bigint;
begin
  select *
    into v_activation
  from public.account_lifecycle_runtime_activation
  where activation_key = 'primary';

  select *
    into v_run
  from public.account_erasure_runs
  where id = v_activation.certification_erasure_run_id;

  select *
    into v_next_step
  from public.account_erasure_steps
  where erasure_run_id = v_run.id
    and mandatory
    and step_status <> 'completed'
  order by step_order
  limit 1;

  select count(*)
    into v_completed
  from public.account_erasure_steps
  where erasure_run_id = v_run.id
    and step_status = 'completed';

  select count(*) into v_external_commands
  from public.account_erasure_external_commands;

  select count(*) into v_external_attempts
  from public.account_erasure_external_attempts;

  select count(*) into v_external_receipts
  from public.account_erasure_external_receipts;

  return jsonb_build_object(
    'activation_level', v_activation.activation_level,
    'activation_mode', v_activation.activation_mode,
    'desired_state', v_activation.desired_state,
    'observed_state', v_activation.observed_state,
    'claims_enabled', v_activation.claims_enabled,
    'workers_enabled', v_activation.workers_enabled,
    'storage_provider_enabled',
      v_activation.storage_provider_enabled,
    'auth_provider_enabled',
      v_activation.auth_provider_enabled,
    'approved_account_lifecycle_id',
      v_activation.certification_account_lifecycle_id,
    'approved_erasure_run_id',
      v_activation.certification_erasure_run_id,
    'run_status', v_run.run_status,
    'run_blocker_code', v_run.blocker_code,
    'next_step_code', v_next_step.step_code,
    'next_step_order', v_next_step.step_order,
    'next_step_status', v_next_step.step_status,
    'completed_step_count', v_completed,
    'external_command_count', v_external_commands,
    'external_attempt_count', v_external_attempts,
    'external_receipt_count', v_external_receipts,
    'server_time', clock_timestamp()
  );
end;
$function$;

do $grants$
declare
  v_signature text;
begin
  foreach v_signature in array array[
    'public.assert_account_lifecycle_certification_scope_internal(uuid,uuid)',
    'public.activate_account_lifecycle_certification_run_internal(text,uuid)',
    'public.claim_account_lifecycle_certification_run_internal(text,integer,uuid)',
    'public.pause_account_lifecycle_at_external_boundary_internal(uuid,uuid)',
    'public.execute_account_lifecycle_certification_cycle_internal(text,uuid)',
    'public.get_account_lifecycle_runtime_activation_state_internal()'
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

update public.account_lifecycle_policies
set
  automatic_execution_enabled = true,
  policy_config = policy_config || jsonb_build_object(
    'runtime_activation_level', 1,
    'runtime_activation_mode', 'certification',
    'runtime_launch_enabled', true,
    'runtime_claim_enabled', true,
    'runtime_worker_enabled', true,
    'domain_handlers_enabled', true,
    'commercial_detach_enabled', true,
    'competitive_anonymization_enabled', true,
    'finalization_handlers_enabled', false,
    'server_orchestrator_enabled', false,
    'external_command_execution_enabled', false,
    'external_receipt_acceptance_enabled', false,
    'external_recovery_enabled', true,
    'external_reconciliation_enabled', true,
    'storage_deletion_enabled', false,
    'profile_deletion_enabled', false,
    'pre_auth_certification_enabled', false,
    'auth_deletion_enabled', false,
    'post_auth_certification_enabled', false,
    'final_audit_enabled', false,
    'terminal_certification_enabled', false,
    'certification_scope_enabled', true,
    'certification_account_lifecycle_id',
      '6b644375-da81-4714-9ce7-2fcd4b649fd4',
    'certification_erasure_run_id',
      '1bd7fe36-343a-4b6f-895e-6ec9b93e73d1',
    'certification_stop_before_step_order', 120,
    'certification_time_override_enabled', true,
    'certification_pause_enabled', true,
    'certification_pause_code',
      'CERTIFICATION_EXTERNAL_BOUNDARY_REACHED',
    'production_scope_enabled', false
  ),
  updated_at = clock_timestamp()
where policy_code = 'ACCOUNT_DELETION_STANDARD'
  and policy_version = 1;

update public.platform_engine_registry
set
  lifecycle_status = 'active',
  runtime_enabled = true,
  is_certified = false,
  metadata = metadata || jsonb_build_object(
    'runtime_activation_level', 1,
    'runtime_desired_state', 'certification',
    'runtime_observed_state', 'stopped',
    'controlled_runtime_activation_migration', 179,
    'certification_account_lifecycle_id',
      '6b644375-da81-4714-9ce7-2fcd4b649fd4',
    'certification_erasure_run_id',
      '1bd7fe36-343a-4b6f-895e-6ec9b93e73d1',
    'certification_stop_before_step_order', 120,
    'storage_provider_enabled', false,
    'auth_provider_enabled', false,
    'production_scope_enabled', false
  ),
  updated_at = clock_timestamp()
where engine_code = 'account_lifecycle_engine';

update public.platform_configuration
set
  schema_version = 179,
  metadata = metadata || jsonb_build_object(
    'account_lifecycle_runtime_activation_level', 1,
    'account_lifecycle_runtime_activation_mode', 'certification',
    'account_lifecycle_runtime_activation_migration', 179,
    'account_lifecycle_runtime_activation_enabled', true,
    'account_lifecycle_production_enabled', false
  ),
  updated_at = clock_timestamp()
where configuration_key = 'primary';

do $assertions$
declare
  v_forbidden_grants bigint;
  v_external_rows bigint;
  v_activation public.account_lifecycle_runtime_activation%rowtype;
  v_policy public.account_lifecycle_policies%rowtype;
begin
  select count(*)
    into v_forbidden_grants
  from information_schema.role_table_grants
  where table_schema = 'public'
    and table_name = 'account_lifecycle_runtime_activation'
    and grantee in ('service_role','authenticated','anon');

  if v_forbidden_grants <> 0 then
    raise exception
      'MIGRATION_179_FORBIDDEN_ACTIVATION_TABLE_GRANTS: %',
      v_forbidden_grants;
  end if;

  select
      (select count(*) from public.account_erasure_external_commands)
    + (select count(*) from public.account_erasure_external_attempts)
    + (select count(*) from public.account_erasure_external_receipts)
  into v_external_rows;

  if v_external_rows <> 0 then
    raise exception
      'MIGRATION_179_CREATED_EXTERNAL_ROWS: %',
      v_external_rows;
  end if;

  select *
    into v_activation
  from public.account_lifecycle_runtime_activation
  where activation_key = 'primary';

  select *
    into v_policy
  from public.account_lifecycle_policies
  where policy_code = 'ACCOUNT_DELETION_STANDARD'
    and policy_version = 1;

  if v_activation.activation_level <> 1
     or v_activation.activation_mode <> 'certification'
     or not v_activation.claims_enabled
     or not v_activation.workers_enabled
     or v_activation.storage_provider_enabled
     or v_activation.auth_provider_enabled
     or v_activation.production_scope_enabled
     or not v_policy.automatic_execution_enabled
     or not coalesce(
       (v_policy.policy_config ->> 'runtime_claim_enabled')::boolean,
       false
     )
     or not coalesce(
       (v_policy.policy_config ->> 'commercial_detach_enabled')::boolean,
       false
     )
     or not coalesce(
       (v_policy.policy_config ->> 'competitive_anonymization_enabled')::boolean,
       false
     )
     or coalesce(
       (v_policy.policy_config ->> 'storage_deletion_enabled')::boolean,
       false
     )
     or coalesce(
       (v_policy.policy_config ->> 'auth_deletion_enabled')::boolean,
       false
     )
  then
    raise exception 'MIGRATION_179_ACTIVATION_STATE_INVALID';
  end if;
end;
$assertions$;

commit;
