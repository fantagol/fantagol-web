begin;

-- ============================================================================
-- FANTAGOL
-- MIGRATION 202
-- WORKFLOW OBSERVABILITY PROJECTION
--
-- Canonical execution truth:
--   live_runtime_workflows
--   live_runtime_workflow_steps
--   live_runtime_workflow_events
--
-- Operational projections:
--   live_runtime_workflow_registry
--   live_runtime_workflow_step_registry
--   live_runtime_workflow_timeline
--
-- Rules:
--   * canonical workflow events remain append-only truth;
--   * canonical events project exactly once into Observability;
--   * step registry also receives current-state snapshots because migration 062
--     does not emit a StepCreated event for every persisted workflow step;
--   * no Achievement / Loyalty / Commercial mutation occurs here.
-- ============================================================================


-- ============================================================================
-- 1. EVENT PROJECTION RECEIPTS
-- ============================================================================

create table if not exists public.live_runtime_workflow_projection_receipts (
  canonical_event_id uuid primary key
    references public.live_runtime_workflow_events(id)
    on delete restrict,

  workflow_id uuid not null
    references public.live_runtime_workflows(id)
    on delete restrict,

  canonical_event_type text not null,
  observability_event_type text not null,

  projected_at timestamptz not null default clock_timestamp(),

  metadata jsonb not null default '{}'::jsonb,

  constraint live_runtime_workflow_projection_receipts_event_type_ck
    check (
      length(btrim(canonical_event_type)) > 0
      and length(btrim(observability_event_type)) > 0
    ),

  constraint live_runtime_workflow_projection_receipts_metadata_ck
    check (jsonb_typeof(metadata) = 'object')
);

comment on table public.live_runtime_workflow_projection_receipts is
  'Idempotency receipts proving that each canonical Workflow Runtime event was projected into Workflow Observability exactly once.';


-- ============================================================================
-- 2. STATUS MAPPERS
-- ============================================================================

create or replace function public.map_live_runtime_workflow_observability_status_internal(
  p_status text
)
returns text
language sql
immutable
security invoker
set search_path = public, pg_catalog
as $function$
  select case p_status
    when 'pending'   then 'created'
    when 'running'   then 'running'
    when 'completed' then 'completed'
    when 'failed'    then 'failed'
    when 'cancelled' then 'cancelled'
    else 'created'
  end;
$function$;


create or replace function public.map_live_runtime_step_observability_status_internal(
  p_status text
)
returns text
language sql
immutable
security invoker
set search_path = public, pg_catalog
as $function$
  select case p_status
    when 'ready'       then 'created'
    when 'blocked'     then 'waiting'
    when 'enqueued'    then 'queued'
    when 'running'     then 'running'
    when 'retry_wait'  then 'retry_scheduled'
    when 'completed'   then 'completed'
    when 'failed'      then 'failed'
    when 'dead_letter' then 'dead'
    when 'cancelled'   then 'cancelled'
    when 'skipped'     then 'skipped'
    else 'created'
  end;
$function$;


-- ============================================================================
-- 3. CURRENT STEP SNAPSHOT PROJECTOR
--
-- No timeline entry is created here.
-- Timeline belongs to canonical workflow events.
-- ============================================================================

create or replace function public.project_live_runtime_workflow_step_snapshot_internal(
  p_workflow_step_id uuid
)
returns void
language plpgsql
security definer
set search_path = public, extensions, pg_catalog
as $function$
declare
  v_step public.live_runtime_workflow_steps%rowtype;
  v_workflow public.live_runtime_workflows%rowtype;

  v_status text;
  v_attempt_count integer := 0;
  v_error_code text;
  v_error_message text;
begin
  select s.*
  into v_step
  from public.live_runtime_workflow_steps s
  where s.id = p_workflow_step_id;

  if not found then
    return;
  end if;

  select w.*
  into v_workflow
  from public.live_runtime_workflows w
  where w.id = v_step.workflow_id;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'WORKFLOW_PROJECTION_PARENT_NOT_FOUND';
  end if;

  v_status :=
    public.map_live_runtime_step_observability_status_internal(
      v_step.status
    );

  if v_step.job_id is not null then
    select coalesce(j.attempt_count, 0)
    into v_attempt_count
    from public.live_runtime_jobs j
    where j.id = v_step.job_id;

    v_attempt_count := coalesce(v_attempt_count, 0);
  end if;

  if v_step.last_error is not null
     and jsonb_typeof(v_step.last_error) = 'object'
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
    v_workflow.id,
    v_step.id,
    v_step.step_key,
    v_step.step_key,
    v_step.step_order,

    v_status,
    v_attempt_count,
    case
      when v_step.status = 'retry_wait'
        then greatest(v_attempt_count - 1, 0)
      else 0
    end,
    v_step.job_id,

    v_step.created_at,
    v_step.enqueued_at,
    v_step.started_at,

    case
      when v_status in ('waiting', 'retry_scheduled')
        then coalesce(
          v_step.updated_at,
          v_step.created_at
        )
      else null
    end,

    v_step.updated_at,

    case
      when v_status in ('completed', 'skipped')
        then coalesce(
          v_step.completed_at,
          v_step.skipped_at,
          v_step.updated_at
        )
      else null
    end,

    case
      when v_status in ('failed', 'dead')
        then coalesce(
          v_step.failed_at,
          v_step.updated_at
        )
      else null
    end,

    v_error_code,
    v_error_message,
    v_step.last_error,

    coalesce(v_step.payload, '{}'::jsonb),
    v_step.result,

    jsonb_build_object(
      'projection_source', 'canonical_step_snapshot',
      'canonical_status', v_step.status,
      'job_type', v_step.job_type,
      'scope_type', v_step.scope_type,
      'scope_id', v_step.scope_id,
      'depends_on', to_jsonb(v_step.depends_on),
      'idempotency_key', v_step.idempotency_key
    )
  )

  on conflict (step_instance_id) do update
  set
    workflow_instance_id = excluded.workflow_instance_id,
    step_key = excluded.step_key,
    step_name = excluded.step_name,
    step_index = excluded.step_index,

    status = excluded.status,
    attempt_count = excluded.attempt_count,
    retry_count = excluded.retry_count,
    job_id = excluded.job_id,

    queued_at = excluded.queued_at,
    started_at = excluded.started_at,
    waiting_since = excluded.waiting_since,
    last_transition_at = excluded.last_transition_at,
    completed_at = excluded.completed_at,
    failed_at = excluded.failed_at,

    last_error_code = excluded.last_error_code,
    last_error_message = excluded.last_error_message,
    last_error_details = excluded.last_error_details,

    input_payload = excluded.input_payload,
    output_payload = excluded.output_payload,
    metadata =
      public.live_runtime_workflow_step_registry.metadata
      || excluded.metadata;
end;
$function$;


-- ============================================================================
-- 4. STEP SNAPSHOT TRIGGER
-- ============================================================================

create or replace function public.project_live_runtime_workflow_step_snapshot_trigger()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, pg_catalog
as $function$
begin
  perform public.project_live_runtime_workflow_step_snapshot_internal(new.id);
  return new;
end;
$function$;


drop trigger if exists live_runtime_workflow_step_observability_projection
  on public.live_runtime_workflow_steps;

create trigger live_runtime_workflow_step_observability_projection
after insert or update
on public.live_runtime_workflow_steps
for each row
execute function public.project_live_runtime_workflow_step_snapshot_trigger();


-- ============================================================================
-- 5. CANONICAL EVENT -> OBSERVABILITY ADAPTER
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
      'workflow-observability-event:' || p_event_id::text,
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
        select coalesce(j.attempt_count, 0)
        into v_attempt_count
        from public.live_runtime_jobs j
        where j.id = v_step.job_id;

        v_attempt_count := coalesce(v_attempt_count, 0);
      end if;

      if v_step.last_error is not null
         and jsonb_typeof(v_step.last_error) = 'object'
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

        v_error_details := v_step.last_error;
      end if;
    end if;
  end if;

  v_workflow_status :=
    public.map_live_runtime_workflow_observability_status_internal(
      v_workflow.status
    );

  -- Canonical Runtime event vocabulary -> Observability vocabulary.
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
          else 'workflow_updated'
        end

      else
        'runtime_event'
    end;

  -- Domain context available from canonical scope.
  if v_workflow.scope_type = 'league_round' then
    v_league_round_id := v_workflow.scope_id;

    select lr.league_id
    into v_league_id
    from public.league_rounds lr
    where lr.id = v_workflow.scope_id;

  elsif v_workflow.scope_type = 'match' then
    v_match_id := v_workflow.scope_id;
  end if;

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
        when v_has_step then v_step.id
        else null
      end,

    p_step_key =>
      case
        when v_has_step then v_step.step_key
        else null
      end,

    p_step_name =>
      case
        when v_has_step then v_step.step_key
        else null
      end,

    p_step_index =>
      case
        when v_has_step then v_step.step_order
        else null
      end,

    p_step_status =>
      case
        when v_has_step then v_step_status
        else null
      end,

    p_attempt_no =>
      case
        when v_has_step then v_attempt_count
        else null
      end,

    p_job_id =>
      case
        when v_has_step then v_step.job_id
        else null
      end,

    p_occurred_at =>
      v_event.occurred_at,

    p_scheduled_at =>
      case
        when v_has_step then v_step.scheduled_at
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
          then coalesce(v_step.payload, '{}'::jsonb)
        else '{}'::jsonb
      end,

    p_output_payload =>
      case
        when v_has_step
          then v_step.result
        else null
      end,

    p_payload =>
      coalesce(v_event.payload, '{}'::jsonb),

    p_metadata =>
      coalesce(v_workflow.metadata, '{}'::jsonb)
      || jsonb_build_object(
        'total_steps', v_total_steps,
        'projection_source', 'canonical_workflow_event',
        'canonical_event_id', v_event.id,
        'canonical_event_type', v_event.event_type,
        'canonical_workflow_status', v_workflow.status
      )
  );

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
    'canonical_event_id', v_event.id,
    'canonical_event_type', v_event.event_type,
    'observability_event_type', v_observability_event_type,
    'workflow_registry_id', v_projection.workflow_registry_id,
    'timeline_event_id', v_projection.timeline_event_id,
    'sequence_no', v_projection.sequence_no
  );
end;
$function$;


-- ============================================================================
-- 6. CANONICAL EVENT TRIGGER
-- ============================================================================

create or replace function public.project_live_runtime_workflow_event_trigger()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, pg_catalog
as $function$
begin
  perform public.project_live_runtime_workflow_event_internal(new.id);
  return new;
end;
$function$;


drop trigger if exists live_runtime_workflow_event_observability_projection
  on public.live_runtime_workflow_events;

create trigger live_runtime_workflow_event_observability_projection
after insert
on public.live_runtime_workflow_events
for each row
execute function public.project_live_runtime_workflow_event_trigger();


-- ============================================================================
-- 7. ONE-TIME HISTORICAL BOOTSTRAP
--
-- 7A: replay canonical events into timeline/registry.
-- 7B: snapshot all persisted steps into step registry.
--
-- The receipt ledger makes event replay idempotent.
-- ============================================================================

do $bootstrap$
declare
  v_event record;
  v_step record;
begin
  for v_event in
    select e.id
    from public.live_runtime_workflow_events e
    order by e.occurred_at, e.id
  loop
    perform public.project_live_runtime_workflow_event_internal(
      v_event.id
    );
  end loop;

  for v_step in
    select s.id
    from public.live_runtime_workflow_steps s
    order by s.created_at, s.step_order, s.id
  loop
    perform public.project_live_runtime_workflow_step_snapshot_internal(
      v_step.id
    );
  end loop;
end;
$bootstrap$;


-- ============================================================================
-- 8. PRIVILEGE BOUNDARY
-- ============================================================================

alter table public.live_runtime_workflow_projection_receipts
  enable row level security;

revoke all
on table public.live_runtime_workflow_projection_receipts
from public, anon, authenticated;

grant select, insert
on table public.live_runtime_workflow_projection_receipts
to service_role;


revoke all
on function public.project_live_runtime_workflow_event_internal(uuid)
from public, anon, authenticated;

grant execute
on function public.project_live_runtime_workflow_event_internal(uuid)
to service_role;


revoke all
on function public.project_live_runtime_workflow_step_snapshot_internal(uuid)
from public, anon, authenticated;

grant execute
on function public.project_live_runtime_workflow_step_snapshot_internal(uuid)
to service_role;


revoke all
on function public.map_live_runtime_workflow_observability_status_internal(text)
from public, anon, authenticated;

revoke all
on function public.map_live_runtime_step_observability_status_internal(text)
from public, anon, authenticated;


-- ============================================================================
-- 9. INSTALLATION ASSERTIONS
-- ============================================================================

do $assertions$
declare
  v_canonical_workflows bigint;
  v_projected_workflows bigint;

  v_canonical_steps bigint;
  v_projected_steps bigint;

  v_canonical_events bigint;
  v_receipts bigint;
  v_timeline bigint;
begin
  if to_regclass(
    'public.live_runtime_workflow_projection_receipts'
  ) is null then
    raise exception
      'MIGRATION_202_PROJECTION_RECEIPTS_MISSING';
  end if;

  if to_regprocedure(
    'public.project_live_runtime_workflow_event_internal(uuid)'
  ) is null then
    raise exception
      'MIGRATION_202_EVENT_PROJECTOR_MISSING';
  end if;

  if to_regprocedure(
    'public.project_live_runtime_workflow_step_snapshot_internal(uuid)'
  ) is null then
    raise exception
      'MIGRATION_202_STEP_PROJECTOR_MISSING';
  end if;

  select count(*)
  into v_canonical_workflows
  from public.live_runtime_workflows;

  select count(*)
  into v_projected_workflows
  from public.live_runtime_workflow_registry;

  select count(*)
  into v_canonical_steps
  from public.live_runtime_workflow_steps;

  select count(*)
  into v_projected_steps
  from public.live_runtime_workflow_step_registry;

  select count(*)
  into v_canonical_events
  from public.live_runtime_workflow_events;

  select count(*)
  into v_receipts
  from public.live_runtime_workflow_projection_receipts;

  select count(*)
  into v_timeline
  from public.live_runtime_workflow_timeline;

  if v_projected_workflows <> v_canonical_workflows then
    raise exception
      'MIGRATION_202_WORKFLOW_PROJECTION_MISMATCH canonical=% projected=%',
      v_canonical_workflows,
      v_projected_workflows;
  end if;

  if v_projected_steps <> v_canonical_steps then
    raise exception
      'MIGRATION_202_STEP_PROJECTION_MISMATCH canonical=% projected=%',
      v_canonical_steps,
      v_projected_steps;
  end if;

  if v_receipts <> v_canonical_events then
    raise exception
      'MIGRATION_202_EVENT_RECEIPT_MISMATCH canonical=% receipts=%',
      v_canonical_events,
      v_receipts;
  end if;

  if v_timeline <> v_canonical_events then
    raise exception
      'MIGRATION_202_TIMELINE_MISMATCH canonical=% timeline=%',
      v_canonical_events,
      v_timeline;
  end if;
end;
$assertions$;

commit;