-- ============================================================================
-- MIGRATION 323
-- Controlled cancellation authority for stale superseded poll_batch jobs.
--
-- Purpose:
--   Provide a narrow, auditable terminal transition for a stale in-flight
--   poll_batch that has already been superseded by newer completed poll_batch
--   work for the same FantaGol round.
--
-- Safety contract:
--   - job_type must be poll_batch
--   - scope_type must be fantagol_round
--   - current status must be claimed or running
--   - job must be non-exhausted
--   - job must be stale for at least 15 minutes
--   - no workflow step may reference the job
--   - FantaGol round must already be terminal-like:
--       final_calculable / official / recalculated
--   - at least one newer completed same-scope poll_batch must exist
--   - cancellation reason is persisted in result metadata
--   - no dead-letter row is created
--   - no trigger bypass / no direct caller update path
--
-- Non-goals:
--   - not a generic runtime-job cancellation API
--   - does not cancel pending/retry_wait jobs
--   - does not cancel workflow-linked jobs
--   - does not cancel exhausted jobs
-- ============================================================================

create or replace function public.cancel_stale_superseded_poll_batch_internal(
  p_job_id uuid,
  p_reason text default 'STALE_SUPERSEDED_POLL_BATCH'
)
returns table(
  job_id uuid,
  job_status text,
  cancelled_at timestamptz,
  superseding_completed_job_id uuid
)
language plpgsql
security definer
set search_path to 'public', 'pg_catalog'
as $function$
declare
  v_job public.live_runtime_jobs%rowtype;
  v_round public.fantagol_rounds%rowtype;
  v_successor public.live_runtime_jobs%rowtype;
  v_now timestamptz := clock_timestamp();
begin
  if p_job_id is null then
    raise exception using
      errcode = '22004',
      message = 'STALE_SUPERSEDED_POLL_BATCH_JOB_ID_REQUIRED';
  end if;

  if p_reason is null or length(btrim(p_reason)) = 0 then
    raise exception using
      errcode = '22023',
      message = 'STALE_SUPERSEDED_POLL_BATCH_REASON_REQUIRED';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('stale-superseded-poll-batch:' || p_job_id::text, 0)
  );

  select *
  into v_job
  from public.live_runtime_jobs
  where id = p_job_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'STALE_SUPERSEDED_POLL_BATCH_JOB_NOT_FOUND';
  end if;

  if v_job.job_type <> 'poll_batch'
     or v_job.scope_type <> 'fantagol_round' then
    raise exception using
      errcode = '55000',
      message = 'STALE_SUPERSEDED_POLL_BATCH_SCOPE_MISMATCH';
  end if;

  if v_job.status not in ('claimed', 'running') then
    raise exception using
      errcode = '55000',
      message = 'STALE_SUPERSEDED_POLL_BATCH_NOT_IN_FLIGHT';
  end if;

  if v_job.attempt_count >= v_job.max_attempts then
    raise exception using
      errcode = '55000',
      message = 'STALE_SUPERSEDED_POLL_BATCH_EXHAUSTED_USE_FAILURE_AUTHORITY';
  end if;

  if v_job.updated_at >= v_now - interval '15 minutes' then
    raise exception using
      errcode = '55000',
      message = 'STALE_SUPERSEDED_POLL_BATCH_NOT_STALE';
  end if;

  if exists (
    select 1
    from public.live_runtime_workflow_steps s
    where s.job_id = v_job.id
  ) then
    raise exception using
      errcode = '55000',
      message = 'STALE_SUPERSEDED_POLL_BATCH_WORKFLOW_LINK_PRESENT';
  end if;

  select *
  into v_round
  from public.fantagol_rounds fr
  where fr.id = v_job.scope_id;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'STALE_SUPERSEDED_POLL_BATCH_ROUND_NOT_FOUND';
  end if;

  if v_round.status not in ('final_calculable', 'official', 'recalculated') then
    raise exception using
      errcode = '55000',
      message = 'STALE_SUPERSEDED_POLL_BATCH_ROUND_NOT_TERMINAL_LIKE';
  end if;

  select j.*
  into v_successor
  from public.live_runtime_jobs j
  where j.id <> v_job.id
    and j.job_type = v_job.job_type
    and j.scope_type = v_job.scope_type
    and j.scope_id = v_job.scope_id
    and j.created_at > v_job.created_at
    and j.status = 'completed'
    and j.completed_at is not null
  order by j.completed_at desc, j.created_at desc, j.id desc
  limit 1;

  if not found then
    raise exception using
      errcode = '55000',
      message = 'STALE_SUPERSEDED_POLL_BATCH_NO_COMPLETED_SUCCESSOR';
  end if;

  update public.live_runtime_jobs j
  set
    status = 'cancelled',
    cancelled_at = v_now,
    updated_at = v_now,
    result = coalesce(j.result, '{}'::jsonb) || jsonb_build_object(
      'cancel_reason', btrim(p_reason),
      'cancel_authority', 'cancel_stale_superseded_poll_batch_internal',
      'cancelled_stale_job_id', v_job.id,
      'superseding_completed_job_id', v_successor.id,
      'superseding_completed_at', v_successor.completed_at,
      'cancelled_at', v_now
    )
  where j.id = v_job.id;

  return query
  select
    v_job.id,
    'cancelled'::text,
    v_now,
    v_successor.id;
end;
$function$;

revoke all on function public.cancel_stale_superseded_poll_batch_internal(uuid,text)
from public;
