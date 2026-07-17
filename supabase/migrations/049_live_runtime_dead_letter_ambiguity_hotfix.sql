-- ============================================================================
-- FANTAGOL
-- Migration 049: Live Runtime Dead-Letter Ambiguity Hotfix
--
-- Fixes PL/pgSQL ambiguity between the TABLE-return column `job_id`
-- and `ON CONFLICT (job_id)` inside fail_live_runtime_job_rpc.
-- ============================================================================

begin;

create or replace function public.fail_live_runtime_job_rpc(
  p_job_id uuid,
  p_worker_id text,
  p_error jsonb,
  p_retry_delay_seconds integer default 30
)
returns table (
  job_id uuid,
  job_status text,
  attempt_count integer,
  max_attempts integer,
  scheduled_at timestamptz,
  dead_letter_id uuid
)
language plpgsql
security definer
set search_path to public, pg_temp
as $function$
declare
  v_job public.live_runtime_jobs%rowtype;
  v_dead_letter_id uuid;
  v_terminal boolean;
begin
  if p_error is null or p_error = '{}'::jsonb then
    raise exception using
      errcode = 'P0001',
      message = 'LIVE_JOB_ERROR_REQUIRED';
  end if;

  select j.*
  into v_job
  from public.live_runtime_jobs j
  where j.id = p_job_id
    and j.status in ('claimed', 'running')
    and j.claimed_by = btrim(p_worker_id)
  for update;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'LIVE_JOB_NOT_CLAIMED_BY_WORKER';
  end if;

  v_terminal := v_job.attempt_count >= v_job.max_attempts;

  if v_terminal then
    update public.live_runtime_jobs
    set
      status = 'dead_letter',
      last_error = p_error,
      failed_at = clock_timestamp(),
      updated_at = clock_timestamp()
    where id = v_job.id
    returning *
    into v_job;

    insert into public.live_runtime_dead_letters (
      job_id,
      job_type,
      scope_type,
      scope_id,
      attempt_count,
      correlation_id,
      failure,
      payload
    )
    values (
      v_job.id,
      v_job.job_type,
      v_job.scope_type,
      v_job.scope_id,
      v_job.attempt_count,
      v_job.correlation_id,
      p_error,
      v_job.payload
    )
    on conflict on constraint live_runtime_dead_letters_job_unique
    do nothing
    returning id
    into v_dead_letter_id;

    if v_dead_letter_id is null then
      select dl.id
      into v_dead_letter_id
      from public.live_runtime_dead_letters dl
      where dl.job_id = v_job.id;
    end if;
  else
    update public.live_runtime_jobs
    set
      status = 'retry_wait',
      scheduled_at = clock_timestamp()
        + make_interval(secs => greatest(p_retry_delay_seconds, 0)),
      claimed_at = null,
      claimed_by = null,
      last_error = p_error,
      updated_at = clock_timestamp()
    where id = v_job.id
    returning *
    into v_job;
  end if;

  return query
  select
    v_job.id,
    v_job.status,
    v_job.attempt_count,
    v_job.max_attempts,
    v_job.scheduled_at,
    v_dead_letter_id;
end;
$function$;

revoke all on function public.fail_live_runtime_job_rpc(
  uuid,
  text,
  jsonb,
  integer
) from public;

revoke all on function public.fail_live_runtime_job_rpc(
  uuid,
  text,
  jsonb,
  integer
) from anon;

revoke all on function public.fail_live_runtime_job_rpc(
  uuid,
  text,
  jsonb,
  integer
) from authenticated;

grant execute on function public.fail_live_runtime_job_rpc(
  uuid,
  text,
  jsonb,
  integer
) to service_role;

comment on function public.fail_live_runtime_job_rpc(
  uuid,
  text,
  jsonb,
  integer
) is
'Retries or dead-letters a claimed Live Runtime job according to its attempt budget. Service-role only.';

commit;
