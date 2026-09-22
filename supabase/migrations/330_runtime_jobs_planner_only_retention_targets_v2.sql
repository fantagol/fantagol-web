-- ============================================================================
-- MIGRATION 330
-- Runtime jobs canonical retention targets v2 - planner only.
--
-- Purpose:
--   - version runtime_jobs_completed from v1 inert to v2 planner-enabled
--   - version runtime_jobs_cancelled from v1 inert to v2 planner-enabled
--
-- Safety:
--   - execution_enabled remains false by register_retention_target_rpc authority
--   - retention_planner maintenance policy remains disabled
--   - no retention plan/item/receipt is created
-- ============================================================================

do $body$
declare
  v_created_by uuid;
begin
  select created_by
    into v_created_by
  from public.retention_targets
  where target_key='runtime_jobs_completed'
    and target_version=1;

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
    true,
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
    true,
    jsonb_build_object(
      'guard_reference','live_runtime_workflow_steps.job_id',
      'canonical_timestamp','cancelled_at',
      'canonical_status','cancelled'
    ),
    v_created_by
  );
end
$body$;