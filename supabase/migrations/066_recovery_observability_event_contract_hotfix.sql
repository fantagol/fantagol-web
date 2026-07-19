-- ============================================================================
-- FANTAGOL
-- Migration 066 - Recovery Observability Event Contract Hotfix
-- Milestone 7.3.3
--
-- Purpose
--   Extend the Workflow Observability timeline event contract so the Recovery
--   Engine introduced by migration 065 can persist its audit-only events.
--
-- Notes
--   These recovery lifecycle events do not directly mutate workflow status.
--   The existing record_live_runtime_workflow_event_rpc safely preserves the
--   current registry status when an event has no workflow-status mapping.
-- ============================================================================

begin;

alter table public.live_runtime_workflow_timeline
  drop constraint if exists live_runtime_workflow_timeline_event_type_ck;

alter table public.live_runtime_workflow_timeline
  add constraint live_runtime_workflow_timeline_event_type_ck
  check (event_type in (
    'workflow_created',
    'workflow_queued',
    'workflow_started',
    'workflow_waiting',
    'workflow_retry_scheduled',
    'workflow_resumed',
    'workflow_completed',
    'workflow_failed',
    'workflow_cancelled',
    'workflow_dead',

    'workflow_recovery_requested',
    'workflow_recovery_started',
    'workflow_recovery_retry_scheduled',
    'workflow_recovery_cancelled',
    'workflow_replayed',

    'step_created',
    'step_queued',
    'step_started',
    'step_waiting',
    'step_retry_scheduled',
    'step_completed',
    'step_failed',
    'step_skipped',

    'job_linked',
    'heartbeat',
    'diagnostic_note'
  ));

comment on constraint live_runtime_workflow_timeline_event_type_ck
  on public.live_runtime_workflow_timeline
is 'Allowed Workflow Observability events, including Recovery Engine lifecycle audit events.';

do $$
declare
  v_constraint_definition text;
begin
  select pg_get_constraintdef(c.oid)
  into v_constraint_definition
  from pg_constraint c
  join pg_class t
    on t.oid = c.conrelid
  join pg_namespace n
    on n.oid = t.relnamespace
  where n.nspname = 'public'
    and t.relname = 'live_runtime_workflow_timeline'
    and c.conname = 'live_runtime_workflow_timeline_event_type_ck';

  if v_constraint_definition is null then
    raise exception
      'Missing live_runtime_workflow_timeline_event_type_ck';
  end if;

  if position(
    'workflow_recovery_requested'
    in v_constraint_definition
  ) = 0 then
    raise exception
      'Recovery observability event contract was not installed';
  end if;

  if position(
    'workflow_replayed'
    in v_constraint_definition
  ) = 0 then
    raise exception
      'Replay observability event contract was not installed';
  end if;
end;
$$;

commit;
