begin;

-- ============================================================================
-- FANTAGOL
-- MIGRATION 204
-- LIVE RUNTIME ACHIEVEMENT SCOPE EXTENSION
--
-- Adds only the aggregate scopes required by the missing certified
-- Achievement workflows:
--
--   league
--     - league_governance_certification
--     - competition_season_certification
--
--   league_member
--     - profile_state_certification
--     - participation_certification
--
-- season_id / profile_id remain evidence and metadata, not execution scopes.
--
-- No workflow is created.
-- No job is enqueued.
-- No Achievement / Loyalty / Commercial mutation occurs.
-- ============================================================================


-- ============================================================================
-- 1. LIVE RUNTIME JOB SCOPE
-- ============================================================================

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
      'account_lifecycle',
      'league',
      'league_member'
    )
  );


-- ============================================================================
-- 2. WORKFLOW AGGREGATE SCOPE
-- ============================================================================

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
      'account_lifecycle',
      'league',
      'league_member'
    )
  );


-- ============================================================================
-- 3. WORKFLOW STEP SCOPE
-- ============================================================================

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
      'account_lifecycle',
      'league',
      'league_member'
    )
  );


-- ============================================================================
-- 4. CREATE WORKFLOW RPC
--    Same canonical 062 implementation, extended scope vocabulary only.
-- ============================================================================

create or replace function public.create_live_runtime_workflow_rpc(
  p_workflow_type text,
  p_scope_type text,
  p_scope_id uuid,
  p_idempotency_key text,
  p_steps jsonb,
  p_workflow_version integer default 1,
  p_metadata jsonb default '{}'::jsonb,
  p_correlation_id uuid default null,
  p_causation_id uuid default null,
  p_trigger_job_id uuid default null
)
returns table (
  workflow_id uuid,
  workflow_status text,
  inserted boolean,
  step_count integer,
  correlation_id uuid
)
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_workflow public.live_runtime_workflows%rowtype;
  v_step jsonb;
  v_step_key text;
  v_step_scope_type text;
  v_step_scope_id uuid;
  v_depends_on text[];
  v_step_count integer := 0;
  v_missing_dependency text;
begin
  if nullif(btrim(p_workflow_type), '') is null then
    raise exception using
      errcode = 'P0001',
      message = 'LIVE_WORKFLOW_TYPE_REQUIRED';
  end if;

  if p_scope_type not in (
    'match',
    'fantagol_round',
    'league_round',
    'round_simulation',
    'live_state_snapshot',
    'publication',
    'account_lifecycle',
    'league',
    'league_member'
  ) then
    raise exception using
      errcode = 'P0001',
      message = 'LIVE_WORKFLOW_SCOPE_INVALID';
  end if;

  if p_scope_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'LIVE_WORKFLOW_SCOPE_ID_REQUIRED';
  end if;

  if nullif(btrim(p_idempotency_key), '') is null then
    raise exception using
      errcode = 'P0001',
      message = 'LIVE_WORKFLOW_IDEMPOTENCY_KEY_REQUIRED';
  end if;

  if p_workflow_version is null
     or p_workflow_version <= 0 then
    raise exception using
      errcode = 'P0001',
      message = 'LIVE_WORKFLOW_VERSION_INVALID';
  end if;

  if p_steps is null
     or jsonb_typeof(p_steps) <> 'array'
     or jsonb_array_length(p_steps) = 0 then
    raise exception using
      errcode = 'P0001',
      message = 'LIVE_WORKFLOW_STEPS_REQUIRED';
  end if;

  insert into public.live_runtime_workflows (
    workflow_type,
    workflow_version,
    status,
    scope_type,
    scope_id,
    idempotency_key,
    correlation_id,
    causation_id,
    trigger_job_id,
    metadata
  )
  values (
    btrim(p_workflow_type),
    p_workflow_version,
    'pending',
    p_scope_type,
    p_scope_id,
    btrim(p_idempotency_key),
    coalesce(p_correlation_id, gen_random_uuid()),
    p_causation_id,
    p_trigger_job_id,
    coalesce(p_metadata, '{}'::jsonb)
  )
  on conflict (idempotency_key)
  do nothing
  returning *
  into v_workflow;

  if not found then
    select w.*
    into v_workflow
    from public.live_runtime_workflows w
    where w.idempotency_key =
      btrim(p_idempotency_key);

    select count(*)
    into v_step_count
    from public.live_runtime_workflow_steps s
    where s.workflow_id = v_workflow.id;

    return query
    select
      v_workflow.id,
      v_workflow.status,
      false,
      v_step_count,
      v_workflow.correlation_id;

    return;
  end if;

  for v_step in
    select value
    from jsonb_array_elements(p_steps)
  loop

    if jsonb_typeof(v_step) <> 'object' then
      raise exception using
        errcode = 'P0001',
        message = 'LIVE_WORKFLOW_STEP_OBJECT_REQUIRED';
    end if;

    v_step_key :=
      nullif(
        btrim(v_step ->> 'step_key'),
        ''
      );

    if v_step_key is null then
      raise exception using
        errcode = 'P0001',
        message = 'LIVE_WORKFLOW_STEP_KEY_REQUIRED';
    end if;

    if nullif(
         btrim(v_step ->> 'job_type'),
         ''
       ) is null then
      raise exception using
        errcode = 'P0001',
        message = 'LIVE_WORKFLOW_STEP_JOB_TYPE_REQUIRED';
    end if;

    v_step_scope_type :=
      coalesce(
        nullif(
          btrim(v_step ->> 'scope_type'),
          ''
        ),
        p_scope_type
      );

    if v_step_scope_type not in (
      'match',
      'fantagol_round',
      'league_round',
      'round_simulation',
      'live_state_snapshot',
      'publication',
      'account_lifecycle',
      'league',
      'league_member'
    ) then
      raise exception using
        errcode = 'P0001',
        message = 'LIVE_WORKFLOW_STEP_SCOPE_INVALID';
    end if;

    v_step_scope_id :=
      coalesce(
        nullif(
          v_step ->> 'scope_id',
          ''
        )::uuid,
        p_scope_id
      );

    select coalesce(
      array_agg(
        value
        order by ordinality
      ),
      '{}'::text[]
    )
    into v_depends_on
    from jsonb_array_elements_text(
      coalesce(
        v_step -> 'depends_on',
        '[]'::jsonb
      )
    )
    with ordinality as dependency(
      value,
      ordinality
    );

    insert into public.live_runtime_workflow_steps (
      workflow_id,
      step_key,
      step_order,
      job_type,
      scope_type,
      scope_id,
      status,
      depends_on,
      idempotency_key,
      priority,
      max_attempts,
      scheduled_at,
      payload
    )
    values (
      v_workflow.id,
      v_step_key,
      coalesce(
        (v_step ->> 'step_order')::integer,
        100
      ),
      btrim(v_step ->> 'job_type'),
      v_step_scope_type,
      v_step_scope_id,
      case
        when cardinality(v_depends_on) = 0
          then 'ready'
        else 'blocked'
      end,
      v_depends_on,
      'workflow:'
        || v_workflow.id::text
        || ':step:'
        || v_step_key,
      coalesce(
        (v_step ->> 'priority')::integer,
        100
      ),
      coalesce(
        (v_step ->> 'max_attempts')::integer,
        5
      ),
      coalesce(
        (v_step ->> 'scheduled_at')::timestamptz,
        clock_timestamp()
      ),
      coalesce(
        v_step -> 'payload',
        '{}'::jsonb
      )
      || jsonb_build_object(
        'workflow_id',
          v_workflow.id,
        'workflow_type',
          v_workflow.workflow_type,
        'workflow_step_key',
          v_step_key
      )
    );

    v_step_count := v_step_count + 1;
  end loop;

  select dependency_name
  into v_missing_dependency
  from (
    select distinct
      unnest(s.depends_on)
        as dependency_name
    from public.live_runtime_workflow_steps s
    where s.workflow_id = v_workflow.id
  ) dependencies
  where not exists (
    select 1
    from public.live_runtime_workflow_steps defined_step
    where defined_step.workflow_id =
            v_workflow.id
      and defined_step.step_key =
            dependencies.dependency_name
  )
  limit 1;

  if v_missing_dependency is not null then
    raise exception using
      errcode = 'P0001',
      message = 'LIVE_WORKFLOW_DEPENDENCY_NOT_FOUND',
      detail = v_missing_dependency;
  end if;

  insert into public.live_runtime_workflow_events (
    workflow_id,
    workflow_step_id,
    event_type,
    payload,
    correlation_id,
    causation_id
  )
  values (
    v_workflow.id,
    null,
    'RuntimeWorkflowCreated',
    jsonb_build_object(
      'workflow_type',
        v_workflow.workflow_type,
      'workflow_version',
        v_workflow.workflow_version,
      'scope_type',
        v_workflow.scope_type,
      'scope_id',
        v_workflow.scope_id,
      'step_count',
        v_step_count
    ),
    v_workflow.correlation_id,
    v_workflow.causation_id
  );

  return query
  select
    v_workflow.id,
    v_workflow.status,
    true,
    v_step_count,
    v_workflow.correlation_id;
end;
$function$;

comment on function public.create_live_runtime_workflow_rpc(
  text,
  text,
  uuid,
  text,
  jsonb,
  integer,
  jsonb,
  uuid,
  uuid,
  uuid
)
is
  'Creates an idempotent Live Runtime workflow DAG. Canonical scopes include league and league_member for certified Achievement workflows.';


-- ============================================================================
-- 5. ASSERTIONS
-- ============================================================================

do $assertions$
declare
  v_definition text;
  v_function text;
begin

  select pg_get_constraintdef(c.oid)
  into v_definition
  from pg_constraint c
  where c.conrelid =
          'public.live_runtime_jobs'::regclass
    and c.conname =
          'live_runtime_jobs_scope_check';

  if position(
      '''league''' in v_definition
    ) = 0
    or position(
      '''league_member''' in v_definition
    ) = 0
    or position(
      '''account_lifecycle''' in v_definition
    ) = 0
  then
    raise exception
      'MIGRATION_204_JOB_SCOPE_CONTRACT_FAILED';
  end if;


  select pg_get_constraintdef(c.oid)
  into v_definition
  from pg_constraint c
  where c.conrelid =
          'public.live_runtime_workflows'::regclass
    and c.conname =
          'live_runtime_workflows_scope_check';

  if position(
      '''league''' in v_definition
    ) = 0
    or position(
      '''league_member''' in v_definition
    ) = 0
  then
    raise exception
      'MIGRATION_204_WORKFLOW_SCOPE_CONTRACT_FAILED';
  end if;


  select pg_get_constraintdef(c.oid)
  into v_definition
  from pg_constraint c
  where c.conrelid =
          'public.live_runtime_workflow_steps'::regclass
    and c.conname =
          'live_runtime_workflow_steps_scope_check';

  if position(
      '''league''' in v_definition
    ) = 0
    or position(
      '''league_member''' in v_definition
    ) = 0
  then
    raise exception
      'MIGRATION_204_STEP_SCOPE_CONTRACT_FAILED';
  end if;


  select pg_get_functiondef(
    'public.create_live_runtime_workflow_rpc(
      text,text,uuid,text,jsonb,integer,jsonb,uuid,uuid,uuid
    )'::regprocedure
  )
  into v_function;

  if position(
      '''league''' in v_function
    ) = 0
    or position(
      '''league_member''' in v_function
    ) = 0
  then
    raise exception
      'MIGRATION_204_CREATE_RPC_SCOPE_FAILED';
  end if;

end;
$assertions$;

commit;