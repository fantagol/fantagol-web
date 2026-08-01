-- ============================================================================
-- FANTAGOL
-- Migration 172: Account Deletion Runtime Foundation
-- Phase 13.6
--
-- Purpose
--   Integrate ACCOUNT_DELETION_V1 with the certified Live Runtime Workflow
--   Engine without enabling execution or destructive handlers.
--
-- Installs
--   - account_lifecycle scope support in generic workflow/job tables;
--   - execute_account_erasure_step generic job type;
--   - deterministic workflow DAG builder from the frozen 18-step plan;
--   - due-run claim/lease contract;
--   - idempotent workflow launcher;
--   - batch launcher and lease reconciliation;
--   - service-only diagnostics/readiness functions;
--   - corrected runtime boundary separating orchestration launch from
--     destructive handler permissions.
--
-- Safety
--   - account_lifecycle_engine remains installed and runtime-disabled;
--   - runtime_launch_enabled remains false;
--   - automatic_execution_enabled remains false;
--   - every destructive feature remains false;
--   - no existing scheduled run is claimed or linked;
--   - no workflow, job or erasure step is created by this migration.
-- ============================================================================

begin;

-- --------------------------------------------------------------------------
-- 1. Extend generic Live Runtime vocabularies
-- --------------------------------------------------------------------------

alter table public.live_runtime_jobs
  drop constraint if exists live_runtime_jobs_scope_check;

alter table public.live_runtime_jobs
  add constraint live_runtime_jobs_scope_check
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

alter table public.live_runtime_workflow_steps
  drop constraint if exists live_runtime_workflow_steps_scope_check;

alter table public.live_runtime_workflow_steps
  add constraint live_runtime_workflow_steps_scope_check
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

do $extend_job_types$
declare
  v_definition text;
  v_values text;
begin
  select pg_get_constraintdef(c.oid)
    into v_definition
  from pg_constraint c
  join pg_class t on t.oid = c.conrelid
  join pg_namespace n on n.oid = t.relnamespace
  where n.nspname = 'public'
    and t.relname = 'live_runtime_jobs'
    and c.conname = 'live_runtime_jobs_type_check'
    and c.contype = 'c';

  if v_definition is null then
    raise exception
      'ACCOUNT_DELETION_RUNTIME_ASSERTION_FAILED: live job type constraint missing';
  end if;

  if position('execute_account_erasure_step' in v_definition) = 0 then
    select string_agg(quote_literal(matches.value), ',' order by matches.value)
      into v_values
    from (
      select distinct match_row[1] as value
      from regexp_matches(v_definition, '''([^'']+)''', 'g') match_row
    ) matches;

    if v_values is null then
      raise exception
        'ACCOUNT_DELETION_RUNTIME_ASSERTION_FAILED: unable to parse live job types';
    end if;

    execute
      'alter table public.live_runtime_jobs ' ||
      'drop constraint live_runtime_jobs_type_check';

    execute
      'alter table public.live_runtime_jobs ' ||
      'add constraint live_runtime_jobs_type_check check (' ||
      'job_type in (' ||
      v_values || ',' ||
      quote_literal('execute_account_erasure_step') ||
      '))';
  end if;
end;
$extend_job_types$;

-- --------------------------------------------------------------------------
-- 2. Policy-level orchestration flags
-- --------------------------------------------------------------------------

update public.account_lifecycle_policies
set
  policy_config = policy_config || jsonb_build_object(
    'runtime_launch_enabled', false,
    'runtime_claim_enabled', false,
    'runtime_worker_enabled', false,
    'runtime_dry_run_enabled', true,
    'runtime_scope_type', 'account_lifecycle',
    'runtime_job_type', 'execute_account_erasure_step',
    'runtime_contract_version', '1.0.0'
  ),
  updated_at = clock_timestamp()
where policy_code = 'ACCOUNT_DELETION_STANDARD'
  and policy_version = 1;

-- --------------------------------------------------------------------------
-- 3. Runtime boundary guard
-- --------------------------------------------------------------------------

create or replace function public.guard_account_erasure_run_runtime_boundary()
returns trigger
language plpgsql
security invoker
set search_path = public, pg_catalog
as $function$
declare
  v_policy public.account_lifecycle_policies%rowtype;
  v_launch_enabled boolean;
  v_claim_enabled boolean;
begin
  select p.*
    into v_policy
  from public.account_lifecycle_policies p
  where p.id = new.policy_id;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'ACCOUNT_DELETION_POLICY_NOT_FOUND';
  end if;

  v_launch_enabled := coalesce(
    (v_policy.policy_config ->> 'runtime_launch_enabled')::boolean,
    false
  );

  v_claim_enabled := coalesce(
    (v_policy.policy_config ->> 'runtime_claim_enabled')::boolean,
    false
  );

  if (
    new.workflow_id is distinct from old.workflow_id
    and new.workflow_id is not null
  ) and (
    not v_policy.automatic_execution_enabled
    or not v_launch_enabled
  ) then
    raise exception using
      errcode = '55000',
      message = 'ACCOUNT_DELETION_WORKFLOW_LAUNCH_NOT_ENABLED';
  end if;

  if new.run_status in ('leased','running')
     and old.run_status is distinct from new.run_status
     and (
       not v_policy.automatic_execution_enabled
       or not v_claim_enabled
     ) then
    raise exception using
      errcode = '55000',
      message = 'ACCOUNT_DELETION_RUNTIME_CLAIM_NOT_ENABLED';
  end if;

  return new;
end;
$function$;

revoke all on function public.guard_account_erasure_run_runtime_boundary()
  from public, anon, authenticated;

grant execute on function public.guard_account_erasure_run_runtime_boundary()
  to service_role;

-- Existing trigger remains attached and now uses the separated boundary.

-- --------------------------------------------------------------------------
-- 4. Frozen plan -> generic Workflow DAG mapper
-- --------------------------------------------------------------------------

create or replace function public.build_account_deletion_workflow_steps_internal(
  p_erasure_run_id uuid
)
returns jsonb
language plpgsql
security definer
stable
set search_path = public, pg_catalog
as $function$
declare
  v_run public.account_erasure_runs%rowtype;
  v_steps jsonb;
begin
  select r.*
    into v_run
  from public.account_erasure_runs r
  where r.id = p_erasure_run_id;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'ACCOUNT_ERASURE_RUN_NOT_FOUND';
  end if;

  if v_run.workflow_code <> 'ACCOUNT_DELETION_V1'
     or v_run.workflow_version <> '1.0.0' then
    raise exception using
      errcode = '22023',
      message = 'ACCOUNT_ERASURE_WORKFLOW_VERSION_UNSUPPORTED';
  end if;

  with ordered_steps as (
    select
      s.id,
      s.step_code,
      s.step_order,
      s.mandatory,
      s.irreversible,
      s.max_attempts,
      c.handler_code,
      lag(s.step_code) over (order by s.step_order) as previous_step_code
    from public.account_erasure_steps s
    join public.account_erasure_step_catalog c
      on c.id = s.step_catalog_id
    where s.erasure_run_id = v_run.id
  )
  select jsonb_agg(
    jsonb_build_object(
      'step_key', lower(os.step_code),
      'step_order', os.step_order,
      'job_type', 'execute_account_erasure_step',
      'scope_type', 'account_lifecycle',
      'scope_id', v_run.account_lifecycle_id,
      'depends_on',
        case
          when os.previous_step_code is null
            then '[]'::jsonb
          else jsonb_build_array(lower(os.previous_step_code))
        end,
      'priority', 100 + os.step_order,
      'max_attempts', os.max_attempts,
      'scheduled_at', v_run.scheduled_for,
      'payload', jsonb_build_object(
        'account_lifecycle_id', v_run.account_lifecycle_id,
        'account_erasure_run_id', v_run.id,
        'account_erasure_step_id', os.id,
        'step_code', os.step_code,
        'step_order', os.step_order,
        'mandatory', os.mandatory,
        'irreversible', os.irreversible,
        'handler_code', os.handler_code,
        'runtime_contract_version', '1.0.0'
      )
    )
    order by os.step_order
  )
  into v_steps
  from ordered_steps os;

  if v_steps is null
     or jsonb_array_length(v_steps) <> 18 then
    raise exception using
      errcode = '55000',
      message = 'ACCOUNT_ERASURE_FROZEN_PLAN_INVALID';
  end if;

  return v_steps;
end;
$function$;

comment on function public.build_account_deletion_workflow_steps_internal(uuid) is
  'Maps the frozen Account Erasure plan to the certified generic workflow DAG contract. Does not create or execute a workflow.';

revoke all on function public.build_account_deletion_workflow_steps_internal(uuid)
  from public, anon, authenticated;

grant execute on function public.build_account_deletion_workflow_steps_internal(uuid)
  to service_role;

-- --------------------------------------------------------------------------
-- 5. Runtime readiness
-- --------------------------------------------------------------------------

create or replace function public.get_account_deletion_runtime_readiness_internal(
  p_erasure_run_id uuid default null
)
returns jsonb
language plpgsql
security definer
stable
set search_path = public, pg_catalog
as $function$
declare
  v_policy public.account_lifecycle_policies%rowtype;
  v_engine public.platform_engine_registry%rowtype;
  v_run public.account_erasure_runs%rowtype;
  v_dependency_validation jsonb;
  v_step_count integer := 0;
  v_pending_count integer := 0;
  v_runtime_launch_enabled boolean;
  v_runtime_claim_enabled boolean;
  v_runtime_worker_enabled boolean;
begin
  select p.*
    into v_policy
  from public.account_lifecycle_policies p
  where p.policy_code = 'ACCOUNT_DELETION_STANDARD'
    and p.retired_at is null
  order by p.policy_version desc
  limit 1;

  select e.*
    into v_engine
  from public.platform_engine_registry e
  where e.engine_code = 'account_lifecycle_engine';

  v_dependency_validation :=
    public.validate_platform_dependency_graph_rpc(
      'account_lifecycle_engine'
    );

  v_runtime_launch_enabled := coalesce(
    (v_policy.policy_config ->> 'runtime_launch_enabled')::boolean,
    false
  );
  v_runtime_claim_enabled := coalesce(
    (v_policy.policy_config ->> 'runtime_claim_enabled')::boolean,
    false
  );
  v_runtime_worker_enabled := coalesce(
    (v_policy.policy_config ->> 'runtime_worker_enabled')::boolean,
    false
  );

  if p_erasure_run_id is not null then
    select r.*
      into v_run
    from public.account_erasure_runs r
    where r.id = p_erasure_run_id;

    if not found then
      raise exception using
        errcode = 'P0002',
        message = 'ACCOUNT_ERASURE_RUN_NOT_FOUND';
    end if;

    select
      count(*),
      count(*) filter (where s.step_status = 'pending')
    into
      v_step_count,
      v_pending_count
    from public.account_erasure_steps s
    where s.erasure_run_id = v_run.id;
  end if;

  return jsonb_build_object(
    'engine_code', v_engine.engine_code,
    'engine_lifecycle_status', v_engine.lifecycle_status,
    'engine_runtime_enabled', v_engine.runtime_enabled,
    'engine_certified', v_engine.is_certified,
    'dependencies_valid',
      coalesce((v_dependency_validation ->> 'is_valid')::boolean, false),
    'automatic_execution_enabled',
      coalesce(v_policy.automatic_execution_enabled, false),
    'runtime_launch_enabled', v_runtime_launch_enabled,
    'runtime_claim_enabled', v_runtime_claim_enabled,
    'runtime_worker_enabled', v_runtime_worker_enabled,
    'auth_deletion_enabled',
      coalesce(
        (v_policy.policy_config ->> 'auth_deletion_enabled')::boolean,
        false
      ),
    'storage_deletion_enabled',
      coalesce(
        (v_policy.policy_config ->> 'storage_deletion_enabled')::boolean,
        false
      ),
    'commercial_detach_enabled',
      coalesce(
        (v_policy.policy_config ->> 'commercial_detach_enabled')::boolean,
        false
      ),
    'competitive_anonymization_enabled',
      coalesce(
        (
          v_policy.policy_config
          ->> 'competitive_anonymization_enabled'
        )::boolean,
        false
      ),
    'run_id', v_run.id,
    'run_status', v_run.run_status,
    'run_scheduled_for', v_run.scheduled_for,
    'run_due',
      case
        when v_run.id is null then null
        else v_run.scheduled_for <= clock_timestamp()
      end,
    'run_workflow_id', v_run.workflow_id,
    'frozen_step_count', v_step_count,
    'pending_step_count', v_pending_count,
    'launch_ready',
      coalesce(v_engine.runtime_enabled, false)
      and coalesce(v_policy.automatic_execution_enabled, false)
      and v_runtime_launch_enabled
      and v_runtime_claim_enabled
      and v_runtime_worker_enabled
      and coalesce(
        (v_dependency_validation ->> 'is_valid')::boolean,
        false
      )
      and (
        v_run.id is null
        or (
          v_run.run_status in ('scheduled','retry_scheduled')
          and v_run.workflow_id is null
          and v_step_count = 18
          and v_pending_count = 18
        )
      ),
    'runtime_contract_version', '1.0.0',
    'server_time', clock_timestamp()
  );
end;
$function$;

comment on function public.get_account_deletion_runtime_readiness_internal(uuid) is
  'Service-only Account Deletion Runtime readiness model. It never enables or launches execution.';

revoke all on function public.get_account_deletion_runtime_readiness_internal(uuid)
  from public, anon, authenticated;

grant execute on function public.get_account_deletion_runtime_readiness_internal(uuid)
  to service_role;

-- --------------------------------------------------------------------------
-- 6. Due-run lease/claim
-- --------------------------------------------------------------------------

create or replace function public.claim_due_account_erasure_run_internal(
  p_worker_id text,
  p_lease_seconds integer default 120
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_catalog
as $function$
declare
  v_worker_id text := nullif(btrim(p_worker_id), '');
  v_lease_seconds integer :=
    greatest(30, least(coalesce(p_lease_seconds, 120), 3600));
  v_policy public.account_lifecycle_policies%rowtype;
  v_engine public.platform_engine_registry%rowtype;
  v_run public.account_erasure_runs%rowtype;
  v_token uuid := extensions.gen_random_uuid();
begin
  if v_worker_id is null or length(v_worker_id) < 3 then
    raise exception using
      errcode = '22023',
      message = 'ACCOUNT_ERASURE_WORKER_ID_INVALID';
  end if;

  select p.*
    into v_policy
  from public.account_lifecycle_policies p
  where p.policy_code = 'ACCOUNT_DELETION_STANDARD'
    and p.retired_at is null
  order by p.policy_version desc
  limit 1;

  select e.*
    into v_engine
  from public.platform_engine_registry e
  where e.engine_code = 'account_lifecycle_engine';

  if not coalesce(v_engine.runtime_enabled, false)
     or not coalesce(v_policy.automatic_execution_enabled, false)
     or not coalesce(
       (v_policy.policy_config ->> 'runtime_claim_enabled')::boolean,
       false
     )
     or not coalesce(
       (v_policy.policy_config ->> 'runtime_worker_enabled')::boolean,
       false
     ) then
    return jsonb_build_object(
      'claimed', false,
      'reason', 'ACCOUNT_DELETION_RUNTIME_DISABLED',
      'server_time', clock_timestamp()
    );
  end if;

  select r.*
    into v_run
  from public.account_erasure_runs r
  join public.account_lifecycle l
    on l.id = r.account_lifecycle_id
  join public.account_deletion_requests d
    on d.id = r.deletion_request_id
  where r.run_status in ('scheduled','retry_scheduled')
    and r.scheduled_for <= clock_timestamp()
    and r.workflow_id is null
    and l.lifecycle_status = 'deletion_scheduled'
    and d.request_status = 'scheduled'
    and (
      r.lease_expires_at is null
      or r.lease_expires_at <= clock_timestamp()
    )
  order by r.scheduled_for, r.created_at, r.id
  for update of r skip locked
  limit 1;

  if not found then
    return jsonb_build_object(
      'claimed', false,
      'reason', 'NO_DUE_ACCOUNT_ERASURE_RUN',
      'server_time', clock_timestamp()
    );
  end if;

  update public.account_erasure_runs r
  set
    run_status = 'leased',
    lease_owner = v_worker_id,
    lease_token = v_token,
    leased_at = clock_timestamp(),
    lease_expires_at =
      clock_timestamp() + make_interval(secs => v_lease_seconds),
    attempt_count = r.attempt_count + 1,
    version = r.version + 1
  where r.id = v_run.id
  returning r.* into v_run;

  return jsonb_build_object(
    'claimed', true,
    'erasure_run_id', v_run.id,
    'account_lifecycle_id', v_run.account_lifecycle_id,
    'deletion_request_id', v_run.deletion_request_id,
    'lease_owner', v_run.lease_owner,
    'lease_token', v_run.lease_token,
    'lease_expires_at', v_run.lease_expires_at,
    'attempt_count', v_run.attempt_count,
    'max_attempts', v_run.max_attempts,
    'server_time', clock_timestamp()
  );
end;
$function$;

comment on function public.claim_due_account_erasure_run_internal(text, integer) is
  'Claims one due erasure run using FOR UPDATE SKIP LOCKED. Returns disabled without mutation until runtime activation.';

revoke all on function public.claim_due_account_erasure_run_internal(text, integer)
  from public, anon, authenticated;

grant execute on function public.claim_due_account_erasure_run_internal(text, integer)
  to service_role;

-- --------------------------------------------------------------------------
-- 7. Idempotent workflow launcher
-- --------------------------------------------------------------------------

create or replace function public.launch_account_deletion_workflow_internal(
  p_erasure_run_id uuid,
  p_worker_id text,
  p_lease_token uuid,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_catalog
as $function$
declare
  v_run public.account_erasure_runs%rowtype;
  v_lifecycle public.account_lifecycle%rowtype;
  v_request public.account_deletion_requests%rowtype;
  v_policy public.account_lifecycle_policies%rowtype;
  v_steps jsonb;
  v_workflow_id uuid;
  v_workflow_status text;
  v_inserted boolean;
  v_step_count integer;
  v_correlation_id uuid;
  v_idempotency_key text;
begin
  select r.*
    into v_run
  from public.account_erasure_runs r
  where r.id = p_erasure_run_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'ACCOUNT_ERASURE_RUN_NOT_FOUND';
  end if;

  if v_run.run_status <> 'leased'
     or v_run.lease_owner <> btrim(p_worker_id)
     or v_run.lease_token is distinct from p_lease_token
     or v_run.lease_expires_at <= clock_timestamp() then
    raise exception using
      errcode = '42501',
      message = 'ACCOUNT_ERASURE_RUN_LEASE_INVALID';
  end if;

  select l.*
    into v_lifecycle
  from public.account_lifecycle l
  where l.id = v_run.account_lifecycle_id
  for update;

  select d.*
    into v_request
  from public.account_deletion_requests d
  where d.id = v_run.deletion_request_id
  for update;

  select p.*
    into v_policy
  from public.account_lifecycle_policies p
  where p.id = v_run.policy_id;

  if not v_policy.automatic_execution_enabled
     or not coalesce(
       (v_policy.policy_config ->> 'runtime_launch_enabled')::boolean,
       false
     ) then
    raise exception using
      errcode = '55000',
      message = 'ACCOUNT_DELETION_WORKFLOW_LAUNCH_NOT_ENABLED';
  end if;

  if v_lifecycle.lifecycle_status <> 'deletion_scheduled'
     or v_request.request_status <> 'scheduled' then
    raise exception using
      errcode = '55000',
      message = 'ACCOUNT_DELETION_LIFECYCLE_NOT_LAUNCHABLE';
  end if;

  if v_run.workflow_id is not null then
    return jsonb_build_object(
      'launched', true,
      'idempotent_replay', true,
      'workflow_id', v_run.workflow_id,
      'erasure_run_id', v_run.id
    );
  end if;

  v_steps :=
    public.build_account_deletion_workflow_steps_internal(v_run.id);

  v_idempotency_key :=
    'account-deletion:' || v_run.deletion_request_id::text || ':v1';

  select
    w.workflow_id,
    w.workflow_status,
    w.inserted,
    w.step_count,
    w.correlation_id
  into
    v_workflow_id,
    v_workflow_status,
    v_inserted,
    v_step_count,
    v_correlation_id
  from public.create_live_runtime_workflow_rpc(
    p_workflow_type => 'ACCOUNT_DELETION_V1',
    p_scope_type => 'account_lifecycle',
    p_scope_id => v_run.account_lifecycle_id,
    p_idempotency_key => v_idempotency_key,
    p_steps => v_steps,
    p_workflow_version => 1,
    p_metadata => jsonb_build_object(
      'account_lifecycle_id', v_run.account_lifecycle_id,
      'account_erasure_run_id', v_run.id,
      'deletion_request_id', v_run.deletion_request_id,
      'plan_digest', v_run.plan_digest,
      'runtime_contract_version', '1.0.0'
    ),
    p_correlation_id => coalesce(
      p_correlation_id,
      extensions.gen_random_uuid()
    ),
    p_causation_id => null,
    p_trigger_job_id => null
  ) w;

  update public.account_erasure_runs r
  set
    workflow_id = v_workflow_id,
    run_status = 'running',
    started_at = coalesce(r.started_at, clock_timestamp()),
    lease_owner = null,
    lease_token = null,
    leased_at = null,
    lease_expires_at = null,
    version = r.version + 1
  where r.id = v_run.id;

  update public.account_lifecycle l
  set
    lifecycle_status = 'erasure_running',
    workflow_id = v_workflow_id,
    erasure_started_at = coalesce(
      l.erasure_started_at,
      clock_timestamp()
    ),
    mutation_frozen_at = coalesce(
      l.mutation_frozen_at,
      clock_timestamp()
    ),
    version = l.version + 1
  where l.id = v_lifecycle.id;

  update public.account_deletion_requests d
  set request_status = 'executing'
  where d.id = v_request.id;

  perform public.append_account_deletion_audit_internal(
    v_lifecycle.id,
    v_run.id,
    'ACCOUNT_ERASURE_STARTED',
    'started',
    null,
    1,
    0,
    v_run.plan_digest,
    v_correlation_id,
    null,
    null,
    null,
    jsonb_build_object(
      'workflow_id', v_workflow_id,
      'workflow_inserted', v_inserted,
      'workflow_status', v_workflow_status,
      'workflow_step_count', v_step_count,
      'runtime_contract_version', '1.0.0'
    )
  );

  return jsonb_build_object(
    'launched', true,
    'idempotent_replay', not v_inserted,
    'workflow_id', v_workflow_id,
    'workflow_status', v_workflow_status,
    'workflow_step_count', v_step_count,
    'correlation_id', v_correlation_id,
    'erasure_run_id', v_run.id
  );
end;
$function$;

comment on function public.launch_account_deletion_workflow_internal(uuid, text, uuid, uuid) is
  'Launches the certified generic workflow only for a valid leased due run and only after explicit runtime activation.';

revoke all on function public.launch_account_deletion_workflow_internal(
  uuid, text, uuid, uuid
) from public, anon, authenticated;

grant execute on function public.launch_account_deletion_workflow_internal(
  uuid, text, uuid, uuid
) to service_role;

-- --------------------------------------------------------------------------
-- 8. Batch due launcher
-- --------------------------------------------------------------------------

create or replace function public.execute_due_account_deletions_internal(
  p_worker_id text,
  p_limit integer default 10,
  p_lease_seconds integer default 120
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_catalog
as $function$
declare
  v_limit integer := greatest(1, least(coalesce(p_limit, 10), 100));
  v_index integer;
  v_claim jsonb;
  v_launch jsonb;
  v_claimed integer := 0;
  v_launched integer := 0;
  v_disabled boolean := false;
  v_results jsonb := '[]'::jsonb;
begin
  for v_index in 1..v_limit loop
    v_claim :=
      public.claim_due_account_erasure_run_internal(
        p_worker_id,
        p_lease_seconds
      );

    if not coalesce((v_claim ->> 'claimed')::boolean, false) then
      if v_claim ->> 'reason' = 'ACCOUNT_DELETION_RUNTIME_DISABLED' then
        v_disabled := true;
      end if;
      exit;
    end if;

    v_claimed := v_claimed + 1;

    v_launch :=
      public.launch_account_deletion_workflow_internal(
        (v_claim ->> 'erasure_run_id')::uuid,
        p_worker_id,
        (v_claim ->> 'lease_token')::uuid,
        null
      );

    if coalesce((v_launch ->> 'launched')::boolean, false) then
      v_launched := v_launched + 1;
    end if;

    v_results := v_results || jsonb_build_array(v_launch);
  end loop;

  return jsonb_build_object(
    'worker_id', p_worker_id,
    'runtime_disabled', v_disabled,
    'claimed_count', v_claimed,
    'launched_count', v_launched,
    'results', v_results,
    'server_time', clock_timestamp()
  );
end;
$function$;

comment on function public.execute_due_account_deletions_internal(text, integer, integer) is
  'Claims and launches due deletion workflows. It is a no-op while runtime activation flags remain false.';

revoke all on function public.execute_due_account_deletions_internal(
  text, integer, integer
) from public, anon, authenticated;

grant execute on function public.execute_due_account_deletions_internal(
  text, integer, integer
) to service_role;

-- --------------------------------------------------------------------------
-- 9. Expired lease reconciliation
-- --------------------------------------------------------------------------

create or replace function public.reconcile_expired_account_erasure_leases_internal(
  p_limit integer default 100
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_catalog
as $function$
declare
  v_limit integer := greatest(1, least(coalesce(p_limit, 100), 1000));
  v_requeued integer := 0;
  v_failed integer := 0;
begin
  with expired as (
    select r.id
    from public.account_erasure_runs r
    where r.run_status = 'leased'
      and r.lease_expires_at <= clock_timestamp()
    order by r.lease_expires_at, r.id
    limit v_limit
    for update skip locked
  ),
  updated as (
    update public.account_erasure_runs r
    set
      run_status =
        case
          when r.attempt_count >= r.max_attempts then 'failed'
          else 'retry_scheduled'
        end,
      scheduled_for =
        case
          when r.attempt_count >= r.max_attempts
            then r.scheduled_for
          else clock_timestamp()
            + make_interval(
                secs => least(
                  21600,
                  60 * power(2, greatest(r.attempt_count - 1, 0))::integer
                )
              )
        end,
      failed_at =
        case
          when r.attempt_count >= r.max_attempts
            then clock_timestamp()
          else null
        end,
      failure_code =
        case
          when r.attempt_count >= r.max_attempts
            then 'ACCOUNT_ERASURE_LEASE_EXHAUSTED'
          else null
        end,
      last_error_message =
        case
          when r.attempt_count >= r.max_attempts
            then 'Account erasure lease expired after maximum attempts.'
          else 'Account erasure lease expired and was requeued.'
        end,
      lease_owner = null,
      lease_token = null,
      leased_at = null,
      lease_expires_at = null,
      version = r.version + 1
    from expired e
    where r.id = e.id
    returning r.run_status
  )
  select
    count(*) filter (where run_status = 'retry_scheduled'),
    count(*) filter (where run_status = 'failed')
  into
    v_requeued,
    v_failed
  from updated;

  return jsonb_build_object(
    'requeued_count', coalesce(v_requeued, 0),
    'failed_count', coalesce(v_failed, 0),
    'server_time', clock_timestamp()
  );
end;
$function$;

comment on function public.reconcile_expired_account_erasure_leases_internal(integer) is
  'Requeues or fails expired account erasure leases using the run attempt budget.';

revoke all on function public.reconcile_expired_account_erasure_leases_internal(integer)
  from public, anon, authenticated;

grant execute on function public.reconcile_expired_account_erasure_leases_internal(integer)
  to service_role;

-- --------------------------------------------------------------------------
-- 10. Dry-run preview
-- --------------------------------------------------------------------------

create or replace function public.preview_account_deletion_workflow_internal(
  p_erasure_run_id uuid
)
returns jsonb
language plpgsql
security definer
stable
set search_path = public, pg_catalog
as $function$
declare
  v_run public.account_erasure_runs%rowtype;
  v_steps jsonb;
  v_readiness jsonb;
begin
  select r.*
    into v_run
  from public.account_erasure_runs r
  where r.id = p_erasure_run_id;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'ACCOUNT_ERASURE_RUN_NOT_FOUND';
  end if;

  v_steps :=
    public.build_account_deletion_workflow_steps_internal(v_run.id);

  v_readiness :=
    public.get_account_deletion_runtime_readiness_internal(v_run.id);

  return jsonb_build_object(
    'dry_run', true,
    'erasure_run_id', v_run.id,
    'account_lifecycle_id', v_run.account_lifecycle_id,
    'workflow_code', v_run.workflow_code,
    'workflow_version', v_run.workflow_version,
    'plan_digest', v_run.plan_digest,
    'scheduled_for', v_run.scheduled_for,
    'workflow_steps', v_steps,
    'readiness', v_readiness,
    'no_mutation_performed', true,
    'server_time', clock_timestamp()
  );
end;
$function$;

comment on function public.preview_account_deletion_workflow_internal(uuid) is
  'Produces a deterministic no-mutation preview of the generic workflow DAG and runtime readiness.';

revoke all on function public.preview_account_deletion_workflow_internal(uuid)
  from public, anon, authenticated;

grant execute on function public.preview_account_deletion_workflow_internal(uuid)
  to service_role;

-- --------------------------------------------------------------------------
-- 11. Platform metadata
-- --------------------------------------------------------------------------

update public.platform_configuration
set
  schema_version = greatest(schema_version, 172),
  metadata = metadata || jsonb_build_object(
    'account_deletion_runtime_foundation_migration', 172,
    'account_deletion_runtime_contract', 'account-deletion-runtime-v1',
    'account_deletion_runtime_enabled', false,
    'account_deletion_runtime_dry_run_enabled', true
  ),
  updated_at = now()
where configuration_key = 'primary';

update public.platform_engine_registry
set
  metadata = metadata || jsonb_build_object(
    'runtime_foundation_migration', 172,
    'runtime_contract', 'account-deletion-runtime-v1',
    'runtime_scope_type', 'account_lifecycle',
    'runtime_job_type', 'execute_account_erasure_step',
    'runtime_readiness_rpc',
      'get_account_deletion_runtime_readiness_internal',
    'runtime_preview_rpc',
      'preview_account_deletion_workflow_internal',
    'runtime_claim_rpc',
      'claim_due_account_erasure_run_internal',
    'runtime_launch_rpc',
      'launch_account_deletion_workflow_internal',
    'runtime_batch_rpc',
      'execute_due_account_deletions_internal',
    'runtime_reconcile_rpc',
      'reconcile_expired_account_erasure_leases_internal',
    'runtime_launch_enabled', false,
    'runtime_worker_enabled', false,
    'destructive_handlers_installed', false
  ),
  updated_at = now()
where engine_code = 'account_lifecycle_engine';

-- --------------------------------------------------------------------------
-- 12. Migration assertions
-- --------------------------------------------------------------------------

do $assertions$
declare
  v_engine public.platform_engine_registry%rowtype;
  v_policy public.account_lifecycle_policies%rowtype;
  v_job_scope_definition text;
  v_workflow_scope_definition text;
  v_step_scope_definition text;
  v_job_type_definition text;
  v_existing_workflows bigint;
  v_existing_jobs bigint;
  v_linked_runs bigint;
begin
  select *
    into v_engine
  from public.platform_engine_registry
  where engine_code = 'account_lifecycle_engine';

  if not found
     or v_engine.lifecycle_status <> 'installed'
     or v_engine.runtime_enabled
     or v_engine.is_certified then
    raise exception
      'ACCOUNT_DELETION_RUNTIME_ASSERTION_FAILED: engine safety state changed';
  end if;

  select *
    into v_policy
  from public.account_lifecycle_policies
  where policy_code = 'ACCOUNT_DELETION_STANDARD'
    and policy_version = 1;

  if not found
     or v_policy.automatic_execution_enabled
     or coalesce(
       (v_policy.policy_config ->> 'runtime_launch_enabled')::boolean,
       true
     )
     or coalesce(
       (v_policy.policy_config ->> 'runtime_claim_enabled')::boolean,
       true
     )
     or coalesce(
       (v_policy.policy_config ->> 'runtime_worker_enabled')::boolean,
       true
     )
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
       (
         v_policy.policy_config
         ->> 'competitive_anonymization_enabled'
       )::boolean,
       true
     ) then
    raise exception
      'ACCOUNT_DELETION_RUNTIME_ASSERTION_FAILED: execution flag enabled';
  end if;

  select pg_get_constraintdef(c.oid)
    into v_job_scope_definition
  from pg_constraint c
  where c.conrelid = 'public.live_runtime_jobs'::regclass
    and c.conname = 'live_runtime_jobs_scope_check';

  select pg_get_constraintdef(c.oid)
    into v_workflow_scope_definition
  from pg_constraint c
  where c.conrelid = 'public.live_runtime_workflows'::regclass
    and c.conname = 'live_runtime_workflows_scope_check';

  select pg_get_constraintdef(c.oid)
    into v_step_scope_definition
  from pg_constraint c
  where c.conrelid = 'public.live_runtime_workflow_steps'::regclass
    and c.conname = 'live_runtime_workflow_steps_scope_check';

  select pg_get_constraintdef(c.oid)
    into v_job_type_definition
  from pg_constraint c
  where c.conrelid = 'public.live_runtime_jobs'::regclass
    and c.conname = 'live_runtime_jobs_type_check';

  if position('account_lifecycle' in v_job_scope_definition) = 0
     or position('account_lifecycle' in v_workflow_scope_definition) = 0
     or position('account_lifecycle' in v_step_scope_definition) = 0
     or position(
       'execute_account_erasure_step'
       in v_job_type_definition
     ) = 0 then
    raise exception
      'ACCOUNT_DELETION_RUNTIME_ASSERTION_FAILED: runtime vocabulary missing';
  end if;

  if to_regprocedure(
    'public.build_account_deletion_workflow_steps_internal(uuid)'
  ) is null
     or to_regprocedure(
       'public.get_account_deletion_runtime_readiness_internal(uuid)'
     ) is null
     or to_regprocedure(
       'public.claim_due_account_erasure_run_internal(text,integer)'
     ) is null
     or to_regprocedure(
       'public.launch_account_deletion_workflow_internal(uuid,text,uuid,uuid)'
     ) is null
     or to_regprocedure(
       'public.execute_due_account_deletions_internal(text,integer,integer)'
     ) is null
     or to_regprocedure(
       'public.reconcile_expired_account_erasure_leases_internal(integer)'
     ) is null
     or to_regprocedure(
       'public.preview_account_deletion_workflow_internal(uuid)'
     ) is null then
    raise exception
      'ACCOUNT_DELETION_RUNTIME_ASSERTION_FAILED: runtime function missing';
  end if;

  select count(*)
    into v_existing_workflows
  from public.live_runtime_workflows
  where workflow_type = 'ACCOUNT_DELETION_V1';

  select count(*)
    into v_existing_jobs
  from public.live_runtime_jobs
  where job_type = 'execute_account_erasure_step';

  select count(*)
    into v_linked_runs
  from public.account_erasure_runs
  where workflow_id is not null;

  if v_existing_workflows <> 0
     or v_existing_jobs <> 0
     or v_linked_runs <> 0 then
    raise exception
      'ACCOUNT_DELETION_RUNTIME_ASSERTION_FAILED: migration created runtime execution data';
  end if;

  if exists (
    select 1
    from public.account_erasure_runs
    where run_status in ('leased','running')
  ) then
    raise exception
      'ACCOUNT_DELETION_RUNTIME_ASSERTION_FAILED: migration advanced an erasure run';
  end if;
end;
$assertions$;

commit;
