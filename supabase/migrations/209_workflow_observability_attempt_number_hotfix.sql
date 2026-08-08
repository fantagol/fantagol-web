begin;

-- ============================================================================
-- FANTAGOL
-- MIGRATION 209
-- WORKFLOW OBSERVABILITY ATTEMPT NUMBER HOTFIX
--
-- ROOT CAUSE
--
-- live_runtime_workflow_step_registry:
--   attempt_count = 0 is valid before the first worker attempt.
--
-- live_runtime_workflow_timeline:
--   attempt_no must be NULL or > 0.
--
-- Migration 202 projected attempt_count=0 directly into timeline attempt_no
-- for RuntimeWorkflowStepEnqueued.
--
-- FIX
--
-- Preserve the strict Observability constraint.
-- Normalize:
--
--   0 -> NULL
--   1 -> 1
--   2 -> 2
--   ...
--
-- No other projection semantics change.
-- ============================================================================


create or replace function public.project_live_runtime_workflow_event_internal(
  p_event_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_catalog
as $function$
declare
  v_event public.live_runtime_workflow_events%rowtype;
  v_workflow public.live_runtime_workflows%rowtype;
  v_step public.live_runtime_workflow_steps%rowtype;

  v_has_step boolean := false;

  v_observability_event_type text;
  v_workflow_status text;
  v_step_status text;

  v_total_steps integer := 0;
  v_attempt_count integer := 0;

  v_league_id uuid;
  v_league_round_id uuid;
  v_match_id uuid;

  v_error_code text;
  v_error_message text;
  v_error_details jsonb;

  v_projection record;
begin

  if p_event_id is null then
    raise exception using
      errcode = '22004',
      message = 'WORKFLOW_PROJECTION_EVENT_ID_REQUIRED';
  end if;


  perform pg_advisory_xact_lock(
    hashtextextended(
      'workflow-observability-event:'
      || p_event_id::text,
      0
    )
  );


  if exists (
    select 1
    from public.live_runtime_workflow_projection_receipts r
    where r.canonical_event_id = p_event_id
  ) then

    return jsonb_build_object(
      'projected', true,
      'duplicate', true,
      'canonical_event_id', p_event_id
    );

  end if;


  select e.*
  into v_event
  from public.live_runtime_workflow_events e
  where e.id = p_event_id;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'WORKFLOW_PROJECTION_EVENT_NOT_FOUND';
  end if;


  select w.*
  into v_workflow
  from public.live_runtime_workflows w
  where w.id = v_event.workflow_id;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'WORKFLOW_PROJECTION_WORKFLOW_NOT_FOUND';
  end if;


  select count(*)::integer
  into v_total_steps
  from public.live_runtime_workflow_steps s
  where s.workflow_id = v_workflow.id;


  if v_event.workflow_step_id is not null then

    select s.*
    into v_step
    from public.live_runtime_workflow_steps s
    where s.id = v_event.workflow_step_id
      and s.workflow_id = v_workflow.id;

    v_has_step := found;


    if v_has_step then

      v_step_status :=
        public.map_live_runtime_step_observability_status_internal(
          v_step.status
        );


      if v_step.job_id is not null then

        select coalesce(
          j.attempt_count,
          0
        )
        into v_attempt_count
        from public.live_runtime_jobs j
        where j.id = v_step.job_id;

        v_attempt_count :=
          coalesce(
            v_attempt_count,
            0
          );

      end if;


      if v_step.last_error is not null
         and jsonb_typeof(
               v_step.last_error
             ) = 'object'
      then

        v_error_code :=
          coalesce(
            v_step.last_error ->> 'code',
            v_step.last_error ->> 'error_code'
          );

        v_error_message :=
          coalesce(
            v_step.last_error ->> 'message',
            v_step.last_error ->> 'error_message'
          );

        v_error_details :=
          v_step.last_error;

      end if;

    end if;

  end if;


  v_workflow_status :=
    public.map_live_runtime_workflow_observability_status_internal(
      v_workflow.status
    );


  -- ========================================================================
  -- Canonical Runtime vocabulary -> Observability vocabulary
  -- ========================================================================

  v_observability_event_type :=
    case v_event.event_type

      when 'RuntimeWorkflowCreated'
        then 'workflow_created'

      when 'RuntimeWorkflowStepEnqueued'
        then 'step_queued'

      when 'RuntimeWorkflowStepStarted'
        then 'step_started'

      when 'RuntimeWorkflowStepRetryScheduled'
        then 'step_retry_scheduled'

      when 'RuntimeWorkflowStepCompleted'
        then 'step_completed'

      when 'RuntimeWorkflowStepFailed'
        then 'step_failed'

      when 'RuntimeWorkflowStepDeadLettered'
        then 'step_dead'

      when 'RuntimeWorkflowStepCancelled'
        then 'step_cancelled'

      when 'RuntimeWorkflowStepUpdated'
        then 'step_updated'

      when 'RuntimeWorkflowStatusChanged'
        then case v_workflow.status

          when 'running'
            then 'workflow_started'

          when 'completed'
            then 'workflow_completed'

          when 'failed'
            then 'workflow_failed'

          when 'cancelled'
            then 'workflow_cancelled'

          else
            'workflow_updated'

        end

      else
        'runtime_event'

    end;


  -- ========================================================================
  -- Domain context
  -- ========================================================================

  if v_workflow.scope_type = 'league_round' then

    v_league_round_id :=
      v_workflow.scope_id;

    select lr.league_id
    into v_league_id
    from public.league_rounds lr
    where lr.id = v_workflow.scope_id;


  elsif v_workflow.scope_type = 'match' then

    v_match_id :=
      v_workflow.scope_id;


  elsif v_workflow.scope_type = 'league' then

    v_league_id :=
      v_workflow.scope_id;


  elsif v_workflow.scope_type = 'league_member' then

    select lm.league_id
    into v_league_id
    from public.league_members lm
    where lm.id = v_workflow.scope_id;

  end if;


  -- ========================================================================
  -- Project canonical event
  -- ========================================================================

  select *
  into v_projection
  from public.record_live_runtime_workflow_event_rpc(

    p_workflow_instance_id =>
      v_workflow.id,

    p_workflow_key =>
      v_workflow.workflow_type,

    p_event_type =>
      v_observability_event_type,

    p_workflow_status =>
      v_workflow_status,

    p_workflow_version =>
      v_workflow.workflow_version,

    p_workflow_name =>
      v_workflow.workflow_type,

    p_idempotency_key =>
      v_workflow.idempotency_key,

    p_correlation_id =>
      v_event.correlation_id,

    p_causation_id =>
      v_event.causation_id,

    p_parent_workflow_instance_id =>
      null,

    p_aggregate_type =>
      v_workflow.scope_type,

    p_aggregate_id =>
      v_workflow.scope_id,

    p_league_id =>
      v_league_id,

    p_league_round_id =>
      v_league_round_id,

    p_match_id =>
      v_match_id,

    p_step_instance_id =>
      case
        when v_has_step
          then v_step.id
        else null
      end,

    p_step_key =>
      case
        when v_has_step
          then v_step.step_key
        else null
      end,

    p_step_name =>
      case
        when v_has_step
          then v_step.step_key
        else null
      end,

    p_step_index =>
      case
        when v_has_step
          then v_step.step_order
        else null
      end,

    p_step_status =>
      case
        when v_has_step
          then v_step_status
        else null
      end,


    -- ======================================================================
    -- MIGRATION 209 FIX
    --
    -- Timeline attempt numbers represent actual execution attempts.
    -- A merely queued job still has attempt_count=0 in the current registry,
    -- therefore its timeline attempt_no must be NULL.
    -- ======================================================================

    p_attempt_no =>
      case
        when v_has_step
          then nullif(
            v_attempt_count,
            0
          )
        else null
      end,


    p_job_id =>
      case
        when v_has_step
          then v_step.job_id
        else null
      end,

    p_occurred_at =>
      v_event.occurred_at,

    p_scheduled_at =>
      case
        when v_has_step
          then v_step.scheduled_at
        else null
      end,

    p_error_code =>
      v_error_code,

    p_error_message =>
      v_error_message,

    p_error_details =>
      v_error_details,

    p_input_payload =>
      case
        when v_has_step
          then coalesce(
            v_step.payload,
            '{}'::jsonb
          )
        else
          '{}'::jsonb
      end,

    p_output_payload =>
      case
        when v_has_step
          then v_step.result
        else null
      end,

    p_payload =>
      coalesce(
        v_event.payload,
        '{}'::jsonb
      ),

    p_metadata =>
      coalesce(
        v_workflow.metadata,
        '{}'::jsonb
      )
      || jsonb_build_object(
        'total_steps',
          v_total_steps,
        'projection_source',
          'canonical_workflow_event',
        'canonical_event_id',
          v_event.id,
        'canonical_event_type',
          v_event.event_type,
        'canonical_workflow_status',
          v_workflow.status
      )
  );


  -- ========================================================================
  -- Idempotency receipt
  -- ========================================================================

  insert into public.live_runtime_workflow_projection_receipts (
    canonical_event_id,
    workflow_id,
    canonical_event_type,
    observability_event_type,
    metadata
  )
  values (
    v_event.id,
    v_workflow.id,
    v_event.event_type,
    v_observability_event_type,

    jsonb_build_object(
      'workflow_registry_id',
        v_projection.workflow_registry_id,
      'timeline_event_id',
        v_projection.timeline_event_id,
      'sequence_no',
        v_projection.sequence_no
    )
  );


  return jsonb_build_object(
    'projected', true,
    'duplicate', false,
    'canonical_event_id',
      v_event.id,
    'canonical_event_type',
      v_event.event_type,
    'observability_event_type',
      v_observability_event_type,
    'workflow_registry_id',
      v_projection.workflow_registry_id,
    'timeline_event_id',
      v_projection.timeline_event_id,
    'sequence_no',
      v_projection.sequence_no
  );

end;
$function$;


comment on function public.project_live_runtime_workflow_event_internal(uuid)
is
  'Projects canonical Live Runtime workflow events into Workflow Observability. Timeline attempt_no is NULL before the first real worker attempt and positive thereafter.';


-- ============================================================================
-- ASSERTIONS
-- ============================================================================

do $assertions$
declare
  v_definition text;
  v_constraint text;
begin

  select pg_get_functiondef(
    'public.project_live_runtime_workflow_event_internal(uuid)'
      ::regprocedure
  )
  into v_definition;


  if position(
      'nullif('
      in lower(v_definition)
    ) = 0
    or position(
      'v_attempt_count'
      in lower(v_definition)
    ) = 0
  then
    raise exception
      'MIGRATION_209_ATTEMPT_NORMALIZATION_MISSING';
  end if;


  if position(
      'league_member'
      in lower(v_definition)
    ) = 0
    or position(
      'league'
      in lower(v_definition)
    ) = 0
  then
    raise exception
      'MIGRATION_209_ACHIEVEMENT_SCOPE_CONTEXT_MISSING';
  end if;


  select pg_get_constraintdef(c.oid)
  into v_constraint
  from pg_constraint c
  where c.conrelid =
        'public.live_runtime_workflow_timeline'::regclass
    and c.conname =
        'live_runtime_workflow_timeline_numeric_ck';


  if v_constraint is null then
    raise exception
      'MIGRATION_209_TIMELINE_NUMERIC_CONSTRAINT_MISSING';
  end if;


  if position(
      'attempt_no is null'
      in lower(v_constraint)
    ) = 0
  then
    raise exception
      'MIGRATION_209_NULL_ATTEMPT_CONTRACT_CHANGED';
  end if;


  if position(
      'attempt_no > 0'
      in lower(v_constraint)
    ) = 0
  then
    raise exception
      'MIGRATION_209_POSITIVE_ATTEMPT_CONTRACT_CHANGED';
  end if;

end;
$assertions$;

commit;