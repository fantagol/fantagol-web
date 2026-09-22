-- ============================================================================
-- MIGRATION 322
-- Workflow observability STEP_DEAD terminal-time repair
--
-- Purpose:
--   Preserve canonical dead-letter semantics while satisfying the existing
--   observability terminal-time contract:
--     step status 'dead' => failed_at IS NOT NULL
--
-- Scope:
--   record_live_runtime_workflow_event_rpc only.
--
-- Changes:
--   - step_dead contributes to failed_steps / failure_count.
--   - step_dead clears waiting_since as a terminal transition.
--   - step_dead sets failed_at.
--   - step_dead sets timeline finished_at.
--
-- Non-goals:
--   - no job mutation
--   - no workflow/job state vocabulary change
--   - no trigger/constraint changes
--   - no data rewrite
-- ============================================================================
CREATE OR REPLACE FUNCTION public.record_live_runtime_workflow_event_rpc(p_workflow_instance_id uuid, p_workflow_key text, p_event_type text, p_workflow_status text DEFAULT NULL::text, p_workflow_version integer DEFAULT 1, p_workflow_name text DEFAULT NULL::text, p_idempotency_key text DEFAULT NULL::text, p_correlation_id uuid DEFAULT NULL::uuid, p_causation_id uuid DEFAULT NULL::uuid, p_parent_workflow_instance_id uuid DEFAULT NULL::uuid, p_aggregate_type text DEFAULT NULL::text, p_aggregate_id uuid DEFAULT NULL::uuid, p_league_id uuid DEFAULT NULL::uuid, p_league_round_id uuid DEFAULT NULL::uuid, p_match_id uuid DEFAULT NULL::uuid, p_step_instance_id uuid DEFAULT NULL::uuid, p_step_key text DEFAULT NULL::text, p_step_name text DEFAULT NULL::text, p_step_index integer DEFAULT NULL::integer, p_step_status text DEFAULT NULL::text, p_attempt_no integer DEFAULT NULL::integer, p_job_id uuid DEFAULT NULL::uuid, p_occurred_at timestamp with time zone DEFAULT clock_timestamp(), p_scheduled_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_error_code text DEFAULT NULL::text, p_error_message text DEFAULT NULL::text, p_error_details jsonb DEFAULT NULL::jsonb, p_input_payload jsonb DEFAULT '{}'::jsonb, p_output_payload jsonb DEFAULT NULL::jsonb, p_payload jsonb DEFAULT '{}'::jsonb, p_metadata jsonb DEFAULT '{}'::jsonb)
 RETURNS TABLE(workflow_registry_id uuid, timeline_event_id uuid, sequence_no bigint)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_catalog'
AS $function$
declare
  v_now timestamptz := coalesce(p_occurred_at, clock_timestamp());
  v_registry public.live_runtime_workflow_registry%rowtype;
  v_sequence bigint;
  v_timeline_event_id uuid;
  v_workflow_status text;
  v_step_status text;
begin
  if p_workflow_instance_id is null then
    raise exception using errcode = '22004', message = 'workflow_instance_id is required';
  end if;

  if p_workflow_key is null or length(btrim(p_workflow_key)) = 0 then
    raise exception using errcode = '22023', message = 'workflow_key is required';
  end if;

  if p_event_type is null or length(btrim(p_event_type)) = 0 then
    raise exception using errcode = '22023', message = 'event_type is required';
  end if;

  v_workflow_status := coalesce(
    p_workflow_status,
    case p_event_type
      when 'workflow_created' then 'created'
      when 'workflow_queued' then 'queued'
      when 'workflow_started' then 'running'
      when 'workflow_waiting' then 'waiting'
      when 'workflow_retry_scheduled' then 'retry_scheduled'
      when 'workflow_resumed' then 'running'
      when 'workflow_completed' then 'completed'
      when 'workflow_failed' then 'failed'
      when 'workflow_cancelled' then 'cancelled'
      when 'workflow_dead' then 'dead'
      else null
    end
  );

  v_step_status := coalesce(
    p_step_status,
    case p_event_type
      when 'step_created' then 'created'
      when 'step_queued' then 'queued'
      when 'step_started' then 'running'
      when 'step_waiting' then 'waiting'
      when 'step_retry_scheduled' then 'retry_scheduled'
      when 'step_completed' then 'completed'
      when 'step_failed' then 'failed'
      when 'step_skipped' then 'skipped'
      else null
    end
  );

  insert into public.live_runtime_workflow_registry (
    workflow_instance_id,
    workflow_key,
    workflow_version,
    workflow_name,
    idempotency_key,
    correlation_id,
    causation_id,
    parent_workflow_instance_id,
    aggregate_type,
    aggregate_id,
    league_id,
    league_round_id,
    match_id,
    status,
    current_step_key,
    current_step_index,
    total_steps,
    completed_steps,
    failed_steps,
    retry_count,
    failure_count,
    created_at,
    started_at,
    waiting_since,
    last_transition_at,
    last_heartbeat_at,
    completed_at,
    failed_at,
    cancelled_at,
    last_error_code,
    last_error_message,
    last_error_details,
    input_payload,
    output_payload,
    metadata
  )
  values (
    p_workflow_instance_id,
    btrim(p_workflow_key),
    coalesce(p_workflow_version, 1),
    p_workflow_name,
    p_idempotency_key,
    p_correlation_id,
    p_causation_id,
    p_parent_workflow_instance_id,
    p_aggregate_type,
    p_aggregate_id,
    p_league_id,
    p_league_round_id,
    p_match_id,
    coalesce(v_workflow_status, 'created'),
    p_step_key,
    p_step_index,
    nullif((p_metadata ->> 'total_steps')::integer, 0),
    case when p_event_type = 'step_completed' then 1 else 0 end,
    case when p_event_type in ('step_failed', 'step_dead') then 1 else 0 end,
    case when p_event_type in ('workflow_retry_scheduled', 'step_retry_scheduled') then 1 else 0 end,
    case when p_event_type in ('workflow_failed', 'workflow_dead', 'step_failed', 'step_dead') then 1 else 0 end,
    v_now,
    case when p_event_type = 'workflow_started' then v_now else null end,
    case when p_event_type in ('workflow_waiting', 'workflow_retry_scheduled') then v_now else null end,
    v_now,
    case when p_event_type = 'heartbeat' then v_now else null end,
    case when p_event_type = 'workflow_completed' then v_now else null end,
    case when p_event_type in ('workflow_failed', 'workflow_dead') then v_now else null end,
    case when p_event_type = 'workflow_cancelled' then v_now else null end,
    p_error_code,
    p_error_message,
    p_error_details,
    coalesce(p_input_payload, '{}'::jsonb),
    p_output_payload,
    coalesce(p_metadata, '{}'::jsonb)
  )
  on conflict (workflow_instance_id) do update
  set
    workflow_key = excluded.workflow_key,
    workflow_version = excluded.workflow_version,
    workflow_name = coalesce(excluded.workflow_name, live_runtime_workflow_registry.workflow_name),
    idempotency_key = coalesce(excluded.idempotency_key, live_runtime_workflow_registry.idempotency_key),
    correlation_id = coalesce(excluded.correlation_id, live_runtime_workflow_registry.correlation_id),
    causation_id = coalesce(excluded.causation_id, live_runtime_workflow_registry.causation_id),
    parent_workflow_instance_id = coalesce(excluded.parent_workflow_instance_id, live_runtime_workflow_registry.parent_workflow_instance_id),
    aggregate_type = coalesce(excluded.aggregate_type, live_runtime_workflow_registry.aggregate_type),
    aggregate_id = coalesce(excluded.aggregate_id, live_runtime_workflow_registry.aggregate_id),
    league_id = coalesce(excluded.league_id, live_runtime_workflow_registry.league_id),
    league_round_id = coalesce(excluded.league_round_id, live_runtime_workflow_registry.league_round_id),
    match_id = coalesce(excluded.match_id, live_runtime_workflow_registry.match_id),
    status = coalesce(v_workflow_status, live_runtime_workflow_registry.status),
    current_step_key = coalesce(p_step_key, live_runtime_workflow_registry.current_step_key),
    current_step_index = coalesce(p_step_index, live_runtime_workflow_registry.current_step_index),
    total_steps = coalesce(nullif((coalesce(p_metadata, '{}'::jsonb) ->> 'total_steps')::integer, 0), live_runtime_workflow_registry.total_steps),
    completed_steps = live_runtime_workflow_registry.completed_steps
      + case when p_event_type = 'step_completed' then 1 else 0 end,
    failed_steps = live_runtime_workflow_registry.failed_steps
      + case when p_event_type in ('step_failed', 'step_dead') then 1 else 0 end,
    retry_count = live_runtime_workflow_registry.retry_count
      + case when p_event_type in ('workflow_retry_scheduled', 'step_retry_scheduled') then 1 else 0 end,
    failure_count = live_runtime_workflow_registry.failure_count
      + case when p_event_type in ('workflow_failed', 'workflow_dead', 'step_failed', 'step_dead') then 1 else 0 end,
    started_at = coalesce(
      live_runtime_workflow_registry.started_at,
      case when p_event_type in ('workflow_started', 'step_started') then v_now else null end
    ),
    waiting_since = case
      when p_event_type in ('workflow_waiting', 'workflow_retry_scheduled') then v_now
      when p_event_type in ('workflow_resumed', 'workflow_completed', 'workflow_failed', 'workflow_cancelled', 'workflow_dead') then null
      else live_runtime_workflow_registry.waiting_since
    end,
    last_transition_at = v_now,
    last_heartbeat_at = case
      when p_event_type = 'heartbeat' then v_now
      else live_runtime_workflow_registry.last_heartbeat_at
    end,
    completed_at = case
      when p_event_type = 'workflow_completed' then v_now
      else live_runtime_workflow_registry.completed_at
    end,
    failed_at = case
      when p_event_type in ('workflow_failed', 'workflow_dead') then v_now
      else live_runtime_workflow_registry.failed_at
    end,
    cancelled_at = case
      when p_event_type = 'workflow_cancelled' then v_now
      else live_runtime_workflow_registry.cancelled_at
    end,
    last_error_code = case
      when p_error_code is not null then p_error_code
      when p_event_type in ('workflow_resumed', 'workflow_completed') then null
      else live_runtime_workflow_registry.last_error_code
    end,
    last_error_message = case
      when p_error_message is not null then p_error_message
      when p_event_type in ('workflow_resumed', 'workflow_completed') then null
      else live_runtime_workflow_registry.last_error_message
    end,
    last_error_details = case
      when p_error_details is not null then p_error_details
      when p_event_type in ('workflow_resumed', 'workflow_completed') then null
      else live_runtime_workflow_registry.last_error_details
    end,
    input_payload = case
      when p_input_payload is not null and p_input_payload <> '{}'::jsonb then p_input_payload
      else live_runtime_workflow_registry.input_payload
    end,
    output_payload = coalesce(p_output_payload, live_runtime_workflow_registry.output_payload),
    metadata = live_runtime_workflow_registry.metadata || coalesce(p_metadata, '{}'::jsonb)
  returning * into v_registry;

  if p_step_instance_id is not null then
    if p_step_key is null or p_step_index is null then
      raise exception using
        errcode = '22023',
        message = 'step_key and step_index are required when step_instance_id is provided';
    end if;

    insert into public.live_runtime_workflow_step_registry (
      workflow_instance_id,
      step_instance_id,
      step_key,
      step_name,
      step_index,
      status,
      attempt_count,
      retry_count,
      job_id,
      created_at,
      queued_at,
      started_at,
      waiting_since,
      last_transition_at,
      completed_at,
      failed_at,
      last_error_code,
      last_error_message,
      last_error_details,
      input_payload,
      output_payload,
      metadata
    )
    values (
      p_workflow_instance_id,
      p_step_instance_id,
      btrim(p_step_key),
      p_step_name,
      p_step_index,
      coalesce(v_step_status, 'created'),
      coalesce(p_attempt_no, 0),
      case when p_event_type = 'step_retry_scheduled' then 1 else 0 end,
      p_job_id,
      v_now,
      case when p_event_type = 'step_queued' then v_now else null end,
      case when p_event_type = 'step_started' then v_now else null end,
      case when p_event_type in ('step_waiting', 'step_retry_scheduled') then v_now else null end,
      v_now,
      case when p_event_type in ('step_completed', 'step_skipped') then v_now else null end,
      case when p_event_type in ('step_failed', 'step_dead') then v_now else null end,
      p_error_code,
      p_error_message,
      p_error_details,
      coalesce(p_input_payload, '{}'::jsonb),
      p_output_payload,
      coalesce(p_metadata, '{}'::jsonb)
    )
    on conflict (step_instance_id) do update
    set
      step_key = excluded.step_key,
      step_name = coalesce(excluded.step_name, live_runtime_workflow_step_registry.step_name),
      step_index = excluded.step_index,
      status = coalesce(v_step_status, live_runtime_workflow_step_registry.status),
      attempt_count = greatest(
        live_runtime_workflow_step_registry.attempt_count,
        coalesce(p_attempt_no, live_runtime_workflow_step_registry.attempt_count)
      ),
      retry_count = live_runtime_workflow_step_registry.retry_count
        + case when p_event_type = 'step_retry_scheduled' then 1 else 0 end,
      job_id = coalesce(p_job_id, live_runtime_workflow_step_registry.job_id),
      queued_at = coalesce(
        live_runtime_workflow_step_registry.queued_at,
        case when p_event_type = 'step_queued' then v_now else null end
      ),
      started_at = coalesce(
        live_runtime_workflow_step_registry.started_at,
        case when p_event_type = 'step_started' then v_now else null end
      ),
      waiting_since = case
        when p_event_type in ('step_waiting', 'step_retry_scheduled') then v_now
        when p_event_type in ('step_started', 'step_completed', 'step_failed', 'step_dead', 'step_skipped') then null
        else live_runtime_workflow_step_registry.waiting_since
      end,
      last_transition_at = v_now,
      completed_at = case
        when p_event_type in ('step_completed', 'step_skipped') then v_now
        else live_runtime_workflow_step_registry.completed_at
      end,
      failed_at = case
        when p_event_type in ('step_failed', 'step_dead') then v_now
        else live_runtime_workflow_step_registry.failed_at
      end,
      last_error_code = case
        when p_error_code is not null then p_error_code
        when p_event_type = 'step_completed' then null
        else live_runtime_workflow_step_registry.last_error_code
      end,
      last_error_message = case
        when p_error_message is not null then p_error_message
        when p_event_type = 'step_completed' then null
        else live_runtime_workflow_step_registry.last_error_message
      end,
      last_error_details = case
        when p_error_details is not null then p_error_details
        when p_event_type = 'step_completed' then null
        else live_runtime_workflow_step_registry.last_error_details
      end,
      input_payload = case
        when p_input_payload is not null and p_input_payload <> '{}'::jsonb then p_input_payload
        else live_runtime_workflow_step_registry.input_payload
      end,
      output_payload = coalesce(p_output_payload, live_runtime_workflow_step_registry.output_payload),
      metadata = live_runtime_workflow_step_registry.metadata || coalesce(p_metadata, '{}'::jsonb);
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_workflow_instance_id::text, 0));

  select coalesce(max(t.sequence_no), 0) + 1
  into v_sequence
  from public.live_runtime_workflow_timeline t
  where t.workflow_instance_id = p_workflow_instance_id;

  insert into public.live_runtime_workflow_timeline (
    workflow_instance_id,
    sequence_no,
    event_type,
    workflow_status,
    step_instance_id,
    step_key,
    step_index,
    step_status,
    attempt_no,
    job_id,
    correlation_id,
    causation_id,
    occurred_at,
    scheduled_at,
    started_at,
    finished_at,
    error_code,
    error_message,
    error_details,
    payload,
    metadata
  )
  values (
    p_workflow_instance_id,
    v_sequence,
    p_event_type,
    v_workflow_status,
    p_step_instance_id,
    p_step_key,
    p_step_index,
    v_step_status,
    p_attempt_no,
    p_job_id,
    coalesce(p_correlation_id, v_registry.correlation_id),
    coalesce(p_causation_id, v_registry.causation_id),
    v_now,
    p_scheduled_at,
    case when p_event_type in ('workflow_started', 'step_started') then v_now else null end,
    case when p_event_type in (
      'workflow_completed', 'workflow_failed', 'workflow_cancelled', 'workflow_dead',
      'step_completed', 'step_failed', 'step_dead', 'step_skipped'
    ) then v_now else null end,
    p_error_code,
    p_error_message,
    p_error_details,
    coalesce(p_payload, '{}'::jsonb),
    coalesce(p_metadata, '{}'::jsonb)
  )
  returning event_id into v_timeline_event_id;

  return query
  select v_registry.id, v_timeline_event_id, v_sequence;
end;
$function$;


-- ============================================================================
-- Workflow timeline vocabulary alignment
--
-- RuntimeWorkflowStepDeadLettered is canonically projected as `step_dead`,
-- and observability step status `dead` is already part of the allowed status
-- vocabulary. The timeline event_type constraint must admit the same event.
-- ============================================================================

alter table public.live_runtime_workflow_timeline
  drop constraint if exists live_runtime_workflow_timeline_event_type_ck;

alter table public.live_runtime_workflow_timeline
  add constraint live_runtime_workflow_timeline_event_type_ck
  check (
    event_type = any (
      array[
        'workflow_created'::text,
        'workflow_queued'::text,
        'workflow_started'::text,
        'workflow_waiting'::text,
        'workflow_retry_scheduled'::text,
        'workflow_resumed'::text,
        'workflow_completed'::text,
        'workflow_failed'::text,
        'workflow_cancelled'::text,
        'workflow_dead'::text,
        'workflow_recovery_requested'::text,
        'workflow_recovery_started'::text,
        'workflow_recovery_retry_scheduled'::text,
        'workflow_recovery_cancelled'::text,
        'workflow_replayed'::text,
        'step_created'::text,
        'step_queued'::text,
        'step_started'::text,
        'step_waiting'::text,
        'step_retry_scheduled'::text,
        'step_completed'::text,
        'step_failed'::text,
        'step_dead'::text,
        'step_skipped'::text,
        'job_linked'::text,
        'heartbeat'::text,
        'diagnostic_note'::text
      ]
    )
  );
