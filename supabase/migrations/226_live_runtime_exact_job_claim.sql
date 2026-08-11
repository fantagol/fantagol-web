begin;

create or replace function public.claim_live_runtime_job_by_id_internal(
  p_job_id uuid,
  p_worker_id text
)
returns table(
  job_id uuid,
  job_type text,
  job_status text,
  priority integer,
  scope_type text,
  scope_id uuid,
  scheduled_at timestamptz,
  attempt_count integer,
  max_attempts integer,
  correlation_id uuid,
  causation_id uuid,
  payload jsonb
)
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
begin
  if p_job_id is null then
    raise exception 'LIVE_RUNTIME_JOB_ID_REQUIRED';
  end if;

  if p_worker_id is null or btrim(p_worker_id) = '' then
    raise exception 'LIVE_RUNTIME_WORKER_ID_REQUIRED';
  end if;

  return query
  with candidate as (
    select j.id
    from public.live_runtime_jobs j
    where j.id = p_job_id
      and j.status in ('pending','retry_wait')
      and j.scheduled_at <= now()
      and j.attempt_count < j.max_attempts
    for update skip locked
  ),
  claimed as (
    update public.live_runtime_jobs j
    set
      status = 'claimed',
      claimed_at = now(),
      claimed_by = p_worker_id,
      attempt_count = j.attempt_count + 1,
      updated_at = now()
    from candidate c
    where j.id = c.id
    returning
      j.id,
      j.job_type,
      j.status,
      j.priority,
      j.scope_type,
      j.scope_id,
      j.scheduled_at,
      j.attempt_count,
      j.max_attempts,
      j.correlation_id,
      j.causation_id,
      j.payload
  )
  select
    c.id as job_id,
    c.job_type,
    c.status as job_status,
    c.priority,
    c.scope_type,
    c.scope_id,
    c.scheduled_at,
    c.attempt_count,
    c.max_attempts,
    c.correlation_id,
    c.causation_id,
    c.payload
  from claimed c;
end
$function$;

comment on function public.claim_live_runtime_job_by_id_internal(uuid,text)
is 'Service-role-only exact Live Runtime job claim. Claims only the requested job id and never falls through to another queued job.';

revoke all
on function public.claim_live_runtime_job_by_id_internal(uuid,text)
from public;

revoke all
on function public.claim_live_runtime_job_by_id_internal(uuid,text)
from anon;

revoke all
on function public.claim_live_runtime_job_by_id_internal(uuid,text)
from authenticated;

grant execute
on function public.claim_live_runtime_job_by_id_internal(uuid,text)
to service_role;

commit;