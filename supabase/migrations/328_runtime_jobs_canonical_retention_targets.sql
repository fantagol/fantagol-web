-- ============================================================================
-- MIGRATION 328
-- Canonical live_runtime_jobs retention target split.
--
-- Registers two new inert target keys:
--   - runtime_jobs_completed -> completed_at / completed
--   - runtime_jobs_cancelled -> cancelled_at / cancelled
--
-- Safety:
--   - planner_enabled=false
--   - execution_enabled=false
--   - runtime_jobs_terminal v1 remains unchanged
--   - no retention plan/execution
-- ============================================================================

do $body$
declare
  v_created_by uuid;
begin
  select created_by
    into v_created_by
  from public.retention_targets
  where target_key='runtime_jobs_terminal'
    and target_version=1
    and retired_at is null;

  perform public.register_retention_target_rpc(
    'runtime_jobs_completed',
    'Runtime Jobs Completed',
    'Canonical retention target for completed live runtime jobs using completed_at.',
    'live_runtime_jobs',
    'id',
    'completed_at',
    'status',
    array['completed']::text[],
    interval '180 days',
    100,
    500,
    'parent_guarded',
    false,
    jsonb_build_object(
      'guard_reference','live_runtime_workflow_steps.job_id',
      'canonical_timestamp','completed_at',
      'canonical_status','completed'
    ),
    v_created_by
  );

  perform public.register_retention_target_rpc(
    'runtime_jobs_cancelled',
    'Runtime Jobs Cancelled',
    'Canonical retention target for cancelled live runtime jobs using cancelled_at.',
    'live_runtime_jobs',
    'id',
    'cancelled_at',
    'status',
    array['cancelled']::text[],
    interval '180 days',
    100,
    500,
    'parent_guarded',
    false,
    jsonb_build_object(
      'guard_reference','live_runtime_workflow_steps.job_id',
      'canonical_timestamp','cancelled_at',
      'canonical_status','cancelled'
    ),
    v_created_by
  );
end
$body$;