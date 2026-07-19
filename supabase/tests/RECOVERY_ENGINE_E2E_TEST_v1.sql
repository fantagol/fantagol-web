-- ============================================================================
-- FANTAGOL
-- RECOVERY ENGINE E2E TEST HARNESS v1
-- Covers migrations 063, 064, 065 and 066
--
-- This script is fully transactional and ends with ROLLBACK.
-- It creates no persistent test data.
-- ============================================================================

\set ON_ERROR_STOP on
\pset pager off
\timing on
\r

\echo ''
\echo '============================================================'
\echo 'RECOVERY ENGINE E2E TEST HARNESS v1'
\echo '============================================================'

BEGIN;

-- Fixed test identities.
-- Workflow: 74030000-0000-4000-8000-000000000001
-- Correlation: 74030000-0000-4000-8000-000000000010
-- Idempotency: recovery-functional-test-retry-001

\echo ''
\echo '--- 1. CREATE FAILED TEST WORKFLOW ---'

select *
from public.record_live_runtime_workflow_event_rpc(
  p_workflow_instance_id =>
    '74030000-0000-4000-8000-000000000001'::uuid,
  p_workflow_key =>
    'recovery-functional-test',
  p_event_type =>
    'workflow_created',
  p_workflow_name =>
    'Recovery Functional Test',
  p_idempotency_key =>
    'recovery-functional-test-workflow',
  p_correlation_id =>
    '74030000-0000-4000-8000-000000000010'::uuid,
  p_metadata =>
    jsonb_build_object(
      'test', true,
      'migration', 65,
      'total_steps', 1
    )
);

select *
from public.record_live_runtime_workflow_event_rpc(
  p_workflow_instance_id =>
    '74030000-0000-4000-8000-000000000001'::uuid,
  p_workflow_key =>
    'recovery-functional-test',
  p_event_type =>
    'workflow_started',
  p_correlation_id =>
    '74030000-0000-4000-8000-000000000010'::uuid
);

select *
from public.record_live_runtime_workflow_event_rpc(
  p_workflow_instance_id =>
    '74030000-0000-4000-8000-000000000001'::uuid,
  p_workflow_key =>
    'recovery-functional-test',
  p_event_type =>
    'workflow_failed',
  p_correlation_id =>
    '74030000-0000-4000-8000-000000000010'::uuid,
  p_error_code =>
    'TEST_WORKFLOW_FAILURE',
  p_error_message =>
    'Synthetic failure for Recovery Engine test',
  p_error_details =>
    jsonb_build_object('reversible', true)
);

do $$
declare
  v_status text;
  v_health text;
  v_priority integer;
begin
  select status, health_state, diagnostic_priority
  into v_status, v_health, v_priority
  from public.live_runtime_workflow_diagnostics_v
  where workflow_instance_id =
    '74030000-0000-4000-8000-000000000001'::uuid;

  if v_status <> 'failed'
     or v_health <> 'error'
     or v_priority <> 90 then
    raise exception
      'Unexpected failed workflow diagnostics: status %, health %, priority %',
      v_status, v_health, v_priority;
  end if;
end;
$$;

\echo ''
\echo '--- 2. VERIFY RECOVERY ELIGIBILITY ---'

select
  workflow_instance_id,
  workflow_status,
  can_retry,
  can_resume,
  can_replay,
  can_cancel,
  can_mark_dead,
  has_active_recovery
from public.live_runtime_workflow_recovery_eligibility_v
where workflow_instance_id =
  '74030000-0000-4000-8000-000000000001'::uuid;

do $$
declare
  v_row public.live_runtime_workflow_recovery_eligibility_v%rowtype;
begin
  select *
  into v_row
  from public.live_runtime_workflow_recovery_eligibility_v
  where workflow_instance_id =
    '74030000-0000-4000-8000-000000000001'::uuid;

  if not v_row.can_retry
     or not v_row.can_resume
     or not v_row.can_replay
     or v_row.can_cancel
     or not v_row.can_mark_dead
     or v_row.has_active_recovery then
    raise exception 'Unexpected recovery eligibility state';
  end if;
end;
$$;

\echo ''
\echo '--- 3. REQUEST RECOVERY ---'

select
  id,
  workflow_instance_id,
  recovery_action,
  status,
  idempotency_key,
  max_attempts,
  attempt_count,
  outbox_status
from public.request_live_runtime_workflow_recovery_rpc(
  p_workflow_instance_id =>
    '74030000-0000-4000-8000-000000000001'::uuid,
  p_recovery_action =>
    'retry',
  p_idempotency_key =>
    'recovery-functional-test-retry-001',
  p_requested_by =>
    'milestone-7.3.3-test',
  p_request_reason =>
    'Verify retry, backoff and completion lifecycle',
  p_command_payload =>
    jsonb_build_object(
      'test', true,
      'expected_result', 'retry'
    ),
  p_metadata =>
    jsonb_build_object(
      'suite', 'recovery-engine-functional'
    )
);

\echo ''
\echo '--- 4. VERIFY IDEMPOTENCY ---'

select
  id,
  status,
  idempotency_key
from public.request_live_runtime_workflow_recovery_rpc(
  p_workflow_instance_id =>
    '74030000-0000-4000-8000-000000000001'::uuid,
  p_recovery_action =>
    'retry',
  p_idempotency_key =>
    'recovery-functional-test-retry-001',
  p_requested_by =>
    'milestone-7.3.3-test',
  p_request_reason =>
    'Repeated request with identical idempotency key'
);

do $$
declare
  v_requests integer;
  v_outbox integer;
begin
  select count(*)
  into v_requests
  from public.live_runtime_recovery_requests
  where idempotency_key =
    'recovery-functional-test-retry-001';

  select count(*)
  into v_outbox
  from public.live_runtime_recovery_outbox
  where command_key =
    'workflow-recovery:recovery-functional-test-retry-001';

  if v_requests <> 1 or v_outbox <> 1 then
    raise exception
      'Idempotency failed: requests %, outbox %',
      v_requests, v_outbox;
  end if;
end;
$$;

\echo ''
\echo '--- 5. FIRST WORKER CLAIM ---'

create temporary table recovery_test_claim_1 (
  payload jsonb not null
) on commit drop;

insert into recovery_test_claim_1(payload)
select public.claim_live_runtime_recovery_command_rpc(
  p_worker_id => 'recovery-worker-test-01',
  p_lease_seconds => 300
);

select
  (payload #>> '{request,id}')::uuid as claimed_request_id,
  payload #>> '{request,status}' as request_status,
  (payload #>> '{request,attempt_count}')::integer as attempt_count,
  payload #>> '{request,claimed_by}' as claimed_by,
  payload #>> '{outbox,status}' as outbox_status,
  payload #>> '{attempt,status}' as attempt_status
from recovery_test_claim_1;

do $$
declare
  v_payload jsonb;
begin
  select payload into v_payload from recovery_test_claim_1;

  if v_payload is null
     or v_payload #>> '{request,status}' <> 'running'
     or (v_payload #>> '{request,attempt_count}')::integer <> 1
     or v_payload #>> '{request,claimed_by}' <> 'recovery-worker-test-01'
     or v_payload #>> '{outbox,status}' <> 'claimed'
     or v_payload #>> '{attempt,status}' <> 'started' then
    raise exception 'Unexpected first claim payload: %', v_payload;
  end if;
end;
$$;

\echo ''
\echo '--- 6. FAIL FIRST ATTEMPT AND SCHEDULE RETRY ---'

select
  id,
  recovery_action,
  status,
  attempt_count,
  scheduled_at,
  last_error_code,
  outbox_status,
  recovery_health_state
from public.complete_live_runtime_recovery_command_rpc(
  p_recovery_request_id => (
    select id
    from public.live_runtime_recovery_requests
    where idempotency_key =
      'recovery-functional-test-retry-001'
  ),
  p_worker_id =>
    'recovery-worker-test-01',
  p_succeeded =>
    false,
  p_error_code =>
    'TEST_TRANSIENT_RECOVERY_FAILURE',
  p_error_message =>
    'Synthetic transient worker failure',
  p_error_details =>
    jsonb_build_object(
      'transient', true,
      'retry_expected', true
    )
);

select
  attempt_no,
  status,
  worker_id,
  started_at,
  finished_at,
  next_retry_at,
  error_code
from public.live_runtime_recovery_attempts
where recovery_request_id = (
  select id
  from public.live_runtime_recovery_requests
  where idempotency_key =
    'recovery-functional-test-retry-001'
)
order by attempt_no;

do $$
declare
  v_status text;
  v_attempt_count integer;
  v_attempt_status text;
  v_next_retry_at timestamptz;
begin
  select status, attempt_count
  into v_status, v_attempt_count
  from public.live_runtime_recovery_requests
  where idempotency_key =
    'recovery-functional-test-retry-001';

  select status, next_retry_at
  into v_attempt_status, v_next_retry_at
  from public.live_runtime_recovery_attempts
  where recovery_request_id = (
    select id
    from public.live_runtime_recovery_requests
    where idempotency_key =
      'recovery-functional-test-retry-001'
  )
    and attempt_no = 1;

  if v_status <> 'scheduled'
     or v_attempt_count <> 1
     or v_attempt_status <> 'retry_scheduled'
     or v_next_retry_at is null then
    raise exception
      'Unexpected retry scheduling: request %, count %, attempt %, next %',
      v_status, v_attempt_count, v_attempt_status, v_next_retry_at;
  end if;
end;
$$;

\echo ''
\echo '--- 7. VERIFY BACKOFF BLOCKS EARLY CLAIM ---'

select public.claim_live_runtime_recovery_command_rpc(
  p_worker_id => 'recovery-worker-test-02',
  p_lease_seconds => 300
) is null as blocked_during_backoff;

do $$
declare
  v_claim jsonb;
begin
  v_claim := public.claim_live_runtime_recovery_command_rpc(
    p_worker_id => 'recovery-worker-test-02',
    p_lease_seconds => 300
  );

  if v_claim is not null then
    raise exception
      'Recovery command was claimable during backoff: %',
      v_claim;
  end if;
end;
$$;

\echo ''
\echo '--- 8. FAST-FORWARD BACKOFF ---'

update public.live_runtime_recovery_requests
set scheduled_at = clock_timestamp() - interval '1 second'
where idempotency_key =
  'recovery-functional-test-retry-001';

update public.live_runtime_recovery_outbox
set available_at = clock_timestamp() - interval '1 second'
where command_key =
  'workflow-recovery:recovery-functional-test-retry-001';

\echo ''
\echo '--- 9. SECOND WORKER CLAIM ---'

create temporary table recovery_test_claim_2 (
  payload jsonb not null
) on commit drop;

insert into recovery_test_claim_2(payload)
select public.claim_live_runtime_recovery_command_rpc(
  p_worker_id => 'recovery-worker-test-02',
  p_lease_seconds => 300
);

select
  (payload #>> '{request,id}')::uuid as claimed_request_id,
  payload #>> '{request,status}' as request_status,
  (payload #>> '{request,attempt_count}')::integer as attempt_count,
  payload #>> '{request,claimed_by}' as claimed_by,
  payload #>> '{outbox,status}' as outbox_status,
  payload #>> '{attempt,status}' as attempt_status
from recovery_test_claim_2;

do $$
declare
  v_payload jsonb;
begin
  select payload into v_payload from recovery_test_claim_2;

  if v_payload is null
     or v_payload #>> '{request,status}' <> 'running'
     or (v_payload #>> '{request,attempt_count}')::integer <> 2
     or v_payload #>> '{request,claimed_by}' <> 'recovery-worker-test-02'
     or v_payload #>> '{outbox,status}' <> 'claimed'
     or v_payload #>> '{attempt,status}' <> 'started' then
    raise exception 'Unexpected second claim payload: %', v_payload;
  end if;
end;
$$;

\echo ''
\echo '--- 10. COMPLETE SECOND ATTEMPT SUCCESSFULLY ---'

select
  id,
  workflow_instance_id,
  recovery_action,
  status,
  attempt_count,
  completed_at,
  result_payload,
  outbox_status,
  recovery_health_state
from public.complete_live_runtime_recovery_command_rpc(
  p_recovery_request_id => (
    select id
    from public.live_runtime_recovery_requests
    where idempotency_key =
      'recovery-functional-test-retry-001'
  ),
  p_worker_id =>
    'recovery-worker-test-02',
  p_succeeded =>
    true,
  p_result_payload =>
    jsonb_build_object(
      'recovery_completed', true,
      'worker', 'recovery-worker-test-02',
      'test', 'milestone-7.3.3'
    )
);

\echo ''
\echo '--- 11. FINAL STATE ---'

select
  id,
  recovery_action,
  status,
  max_attempts,
  attempt_count,
  requested_by,
  completed_at,
  last_error_code,
  result_payload,
  outbox_status,
  outbox_delivery_attempts,
  recovery_health_state,
  lease_expired
from public.live_runtime_recovery_status_v
where idempotency_key =
  'recovery-functional-test-retry-001';

select
  attempt_no,
  status,
  worker_id,
  started_at,
  finished_at,
  next_retry_at,
  error_code,
  result_payload
from public.live_runtime_recovery_attempts
where recovery_request_id = (
  select id
  from public.live_runtime_recovery_requests
  where idempotency_key =
    'recovery-functional-test-retry-001'
)
order by attempt_no;

select
  command_type,
  command_key,
  status,
  delivery_attempts,
  delivered_at,
  last_error_code
from public.live_runtime_recovery_outbox
where command_key =
  'workflow-recovery:recovery-functional-test-retry-001';

\echo ''
\echo '--- 12. WORKFLOW DIAGNOSTICS AFTER RETRY COMMAND ---'

select
  workflow_instance_id,
  workflow_key,
  status,
  health_state,
  diagnostic_priority,
  retry_count,
  failure_count,
  last_error_code,
  last_transition_at
from public.live_runtime_workflow_diagnostics_v
where workflow_instance_id =
  '74030000-0000-4000-8000-000000000001'::uuid;

\echo ''
\echo '--- 13. RECOVERY INSPECTOR ---'

select jsonb_pretty(
  public.inspect_live_runtime_recovery_rpc((
    select id
    from public.live_runtime_recovery_requests
    where idempotency_key =
      'recovery-functional-test-retry-001'
  ))
);

\echo ''
\echo '--- 14. RECOVERY TIMELINE ---'

select
  sequence_no,
  event_type,
  workflow_status,
  error_code,
  occurred_at,
  payload
from public.live_runtime_workflow_timeline
where workflow_instance_id =
  '74030000-0000-4000-8000-000000000001'::uuid
order by sequence_no;

\echo ''
\echo '--- 15. FINAL ASSERTIONS ---'

do $$
declare
  v_request_status text;
  v_attempt_count integer;
  v_outbox_status text;
  v_attempt_rows integer;
  v_attempt_1_status text;
  v_attempt_2_status text;
  v_workflow_status text;
  v_inspector jsonb;
begin
  select r.status, r.attempt_count, o.status
  into v_request_status, v_attempt_count, v_outbox_status
  from public.live_runtime_recovery_requests r
  join public.live_runtime_recovery_outbox o
    on o.recovery_request_id = r.id
  where r.idempotency_key =
    'recovery-functional-test-retry-001';

  select count(*)
  into v_attempt_rows
  from public.live_runtime_recovery_attempts
  where recovery_request_id = (
    select id
    from public.live_runtime_recovery_requests
    where idempotency_key =
      'recovery-functional-test-retry-001'
  );

  select status
  into v_attempt_1_status
  from public.live_runtime_recovery_attempts
  where recovery_request_id = (
    select id
    from public.live_runtime_recovery_requests
    where idempotency_key =
      'recovery-functional-test-retry-001'
  )
    and attempt_no = 1;

  select status
  into v_attempt_2_status
  from public.live_runtime_recovery_attempts
  where recovery_request_id = (
    select id
    from public.live_runtime_recovery_requests
    where idempotency_key =
      'recovery-functional-test-retry-001'
  )
    and attempt_no = 2;

  select status
  into v_workflow_status
  from public.live_runtime_workflow_registry
  where workflow_instance_id =
    '74030000-0000-4000-8000-000000000001'::uuid;

  select public.inspect_live_runtime_recovery_rpc(r.id)
  into v_inspector
  from public.live_runtime_recovery_requests r
  where r.idempotency_key =
    'recovery-functional-test-retry-001';

  if v_request_status <> 'completed' then
    raise exception
      'Expected completed request, found %',
      v_request_status;
  end if;

  if v_attempt_count <> 2 or v_attempt_rows <> 2 then
    raise exception
      'Expected two attempts: counter %, rows %',
      v_attempt_count, v_attempt_rows;
  end if;

  if v_attempt_1_status <> 'retry_scheduled'
     or v_attempt_2_status <> 'completed' then
    raise exception
      'Unexpected attempt lifecycle: attempt 1 %, attempt 2 %',
      v_attempt_1_status, v_attempt_2_status;
  end if;

  if v_outbox_status <> 'delivered' then
    raise exception
      'Expected delivered outbox, found %',
      v_outbox_status;
  end if;

  if v_workflow_status <> 'retry_scheduled' then
    raise exception
      'Expected workflow retry_scheduled, found %',
      v_workflow_status;
  end if;

  if v_inspector is null then
    raise exception 'Recovery inspector returned null';
  end if;
end;
$$;

\echo ''
\echo '============================================================'
\echo 'FUNCTIONAL TEST PASSED INSIDE TRANSACTION'
\echo 'ROLLING BACK ALL TEST DATA'
\echo '============================================================'

ROLLBACK;

\echo ''
\echo '--- 16. POST-ROLLBACK VERIFICATION ---'

select
  count(*) as remaining_test_workflows
from public.live_runtime_workflow_registry
where workflow_instance_id =
  '74030000-0000-4000-8000-000000000001'::uuid;

select
  count(*) as remaining_test_recovery_requests
from public.live_runtime_recovery_requests
where idempotency_key =
  'recovery-functional-test-retry-001';

select
  count(*) as remaining_test_outbox_items
from public.live_runtime_recovery_outbox
where command_key =
  'workflow-recovery:recovery-functional-test-retry-001';

do $$
declare
  v_workflows integer;
  v_requests integer;
  v_outbox integer;
begin
  select count(*)
  into v_workflows
  from public.live_runtime_workflow_registry
  where workflow_instance_id =
    '74030000-0000-4000-8000-000000000001'::uuid;

  select count(*)
  into v_requests
  from public.live_runtime_recovery_requests
  where idempotency_key =
    'recovery-functional-test-retry-001';

  select count(*)
  into v_outbox
  from public.live_runtime_recovery_outbox
  where command_key =
    'workflow-recovery:recovery-functional-test-retry-001';

  if v_workflows <> 0
     or v_requests <> 0
     or v_outbox <> 0 then
    raise exception
      'Rollback cleanup failed: workflows %, requests %, outbox %',
      v_workflows, v_requests, v_outbox;
  end if;
end;
$$;

\echo ''
\echo '============================================================'
\echo 'RECOVERY ENGINE E2E TEST COMPLETED SUCCESSFULLY'
\echo '============================================================'
