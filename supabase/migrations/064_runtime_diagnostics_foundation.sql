-- ============================================================================
-- FANTAGOL
-- Migration 064 — Runtime Diagnostics Foundation
-- Milestone 7.3.2
--
-- Purpose
--   Transform Workflow Observability data into a private, read-only diagnostic
--   platform for operators, without changing Workflow Engine execution.
--
-- Scope
--   - workflow diagnostics
--   - step and job diagnostics
--   - queue health diagnostics
--   - failure diagnostics
--   - publication and snapshot trace inspectors
--   - filtered operational query RPCs
--
-- Security
--   Diagnostic data is private and reserved to service_role.
-- ============================================================================

begin;

-- --------------------------------------------------------------------------
-- 1. Workflow diagnostics
-- --------------------------------------------------------------------------

create or replace view public.live_runtime_workflow_diagnostics_v as
select
  w.*,
  case
    when w.status = 'dead' then 'critical'
    when w.status = 'failed' then 'error'
    when w.status = 'retry_scheduled' then 'warning'
    when w.status = 'waiting' and coalesce(w.waiting_seconds, 0) >= 900 then 'warning'
    when w.status in ('running', 'queued')
      and coalesce(w.idle_seconds, 0) >= 900 then 'warning'
    when w.status = 'completed' then 'healthy'
    when w.status = 'cancelled' then 'neutral'
    else 'active'
  end as health_state,
  case
    when w.status = 'dead' then 100
    when w.status = 'failed' then 90
    when w.status = 'retry_scheduled' then 75
    when w.status = 'waiting' and coalesce(w.waiting_seconds, 0) >= 3600 then 70
    when w.status = 'waiting' and coalesce(w.waiting_seconds, 0) >= 900 then 60
    when w.status in ('running', 'queued')
      and coalesce(w.idle_seconds, 0) >= 3600 then 55
    when w.status in ('running', 'queued')
      and coalesce(w.idle_seconds, 0) >= 900 then 45
    else 0
  end as diagnostic_priority,
  (
    w.status in ('running', 'queued', 'waiting', 'retry_scheduled')
    and coalesce(w.idle_seconds, 0) >= 900
  ) as is_stale,
  (
    w.status = 'waiting'
    and coalesce(w.waiting_seconds, 0) >= 900
  ) as is_waiting_too_long,
  (
    w.status in ('failed', 'dead')
    or w.failure_count > 0
  ) as has_failure,
  (
    w.retry_count > 0
    or w.status = 'retry_scheduled'
  ) as has_retry
from public.live_runtime_workflow_status_v w;

comment on view public.live_runtime_workflow_diagnostics_v
is 'Operational workflow diagnostics with health classification, priority and stale-state detection.';

-- --------------------------------------------------------------------------
-- 2. Step and job diagnostics
-- --------------------------------------------------------------------------

create or replace view public.live_runtime_workflow_step_diagnostics_v as
select
  s.*,
  coalesce(nullif(s.metadata ->> 'queue_key', ''), 'default') as queue_key,
  s.metadata ->> 'worker_id' as worker_id,
  s.metadata ->> 'handler_key' as handler_key,
  case
    when s.status = 'failed' then 'error'
    when s.status = 'retry_scheduled' then 'warning'
    when s.status = 'waiting' and coalesce(s.waiting_seconds, 0) >= 900 then 'warning'
    when s.status in ('running', 'queued')
      and extract(epoch from (clock_timestamp() - s.last_transition_at)) >= 900
      then 'warning'
    when s.status = 'completed' then 'healthy'
    else 'active'
  end as health_state,
  case
    when s.status = 'failed' then 90
    when s.status = 'retry_scheduled' then 75
    when s.status = 'waiting' and coalesce(s.waiting_seconds, 0) >= 3600 then 70
    when s.status = 'waiting' and coalesce(s.waiting_seconds, 0) >= 900 then 60
    when s.status in ('running', 'queued')
      and extract(epoch from (clock_timestamp() - s.last_transition_at)) >= 3600
      then 55
    when s.status in ('running', 'queued')
      and extract(epoch from (clock_timestamp() - s.last_transition_at)) >= 900
      then 45
    else 0
  end as diagnostic_priority,
  extract(epoch from (clock_timestamp() - s.last_transition_at))::bigint
    as idle_seconds,
  (
    s.status in ('running', 'queued', 'waiting', 'retry_scheduled')
    and extract(epoch from (clock_timestamp() - s.last_transition_at)) >= 900
  ) as is_stale
from public.live_runtime_workflow_step_status_v s;

comment on view public.live_runtime_workflow_step_diagnostics_v
is 'Operational step and linked-job diagnostics with queue, worker, handler and stale-state information.';

create or replace view public.live_runtime_job_diagnostics_v as
select
  s.job_id,
  s.workflow_instance_id,
  s.workflow_key,
  s.correlation_id,
  s.step_instance_id,
  s.step_key,
  s.step_name,
  s.step_index,
  s.status,
  s.queue_key,
  s.worker_id,
  s.handler_key,
  s.attempt_count,
  s.retry_count,
  s.created_at,
  s.queued_at,
  s.started_at,
  s.waiting_since,
  s.last_transition_at,
  s.completed_at,
  s.failed_at,
  s.duration_seconds,
  s.waiting_seconds,
  s.idle_seconds,
  s.health_state,
  s.diagnostic_priority,
  s.is_stale,
  s.last_error_code,
  s.last_error_message,
  s.last_error_details,
  s.metadata
from public.live_runtime_workflow_step_diagnostics_v s
where s.job_id is not null;

comment on view public.live_runtime_job_diagnostics_v
is 'Read-only Job Inspector projection derived from workflow steps linked to runtime job identifiers.';

-- --------------------------------------------------------------------------
-- 3. Queue diagnostics
-- --------------------------------------------------------------------------

create or replace view public.live_runtime_queue_diagnostics_v as
select
  s.queue_key,
  count(*) as total_step_count,
  count(*) filter (where s.status = 'queued') as queued_count,
  count(*) filter (where s.status = 'running') as running_count,
  count(*) filter (where s.status = 'waiting') as waiting_count,
  count(*) filter (where s.status = 'retry_scheduled') as retry_scheduled_count,
  count(*) filter (where s.status = 'failed') as failed_count,
  count(*) filter (where s.status = 'completed') as completed_count,
  count(*) filter (where s.is_stale) as stale_count,
  coalesce(sum(s.retry_count), 0)::bigint as total_retry_count,
  min(s.queued_at) filter (where s.status = 'queued') as oldest_queued_at,
  min(s.waiting_since) filter (where s.status = 'waiting') as oldest_waiting_at,
  max(s.last_transition_at) as latest_transition_at,
  case
    when count(*) filter (where s.status = 'failed') > 0 then 'error'
    when count(*) filter (where s.is_stale) > 0 then 'warning'
    when count(*) filter (
      where s.status in ('queued', 'running', 'waiting', 'retry_scheduled')
    ) > 0 then 'active'
    else 'healthy'
  end as health_state
from public.live_runtime_workflow_step_diagnostics_v s
group by s.queue_key;

comment on view public.live_runtime_queue_diagnostics_v
is 'Queue Inspector projection with backlog, active work, retries, failures and stale steps.';

-- --------------------------------------------------------------------------
-- 4. Failure and attention diagnostics
-- --------------------------------------------------------------------------

create or replace view public.live_runtime_failure_diagnostics_v as
select
  'workflow'::text as failure_scope,
  w.workflow_instance_id,
  null::uuid as step_instance_id,
  null::uuid as job_id,
  w.workflow_key,
  w.current_step_key as step_key,
  w.status,
  w.correlation_id,
  w.last_error_code as error_code,
  w.last_error_message as error_message,
  w.last_error_details as error_details,
  w.failure_count,
  w.retry_count,
  w.failed_at,
  w.last_transition_at,
  w.diagnostic_priority,
  w.metadata
from public.live_runtime_workflow_diagnostics_v w
where w.status in ('failed', 'dead')
   or w.failure_count > 0

union all

select
  'step'::text as failure_scope,
  s.workflow_instance_id,
  s.step_instance_id,
  s.job_id,
  s.workflow_key,
  s.step_key,
  s.status,
  s.correlation_id,
  s.last_error_code,
  s.last_error_message,
  s.last_error_details,
  case when s.status = 'failed' then 1 else 0 end::integer as failure_count,
  s.retry_count,
  s.failed_at,
  s.last_transition_at,
  s.diagnostic_priority,
  s.metadata
from public.live_runtime_workflow_step_diagnostics_v s
where s.status = 'failed'
   or s.last_error_code is not null
   or s.last_error_message is not null;

comment on view public.live_runtime_failure_diagnostics_v
is 'Unified workflow and step failure inspector ordered by operational severity.';

-- --------------------------------------------------------------------------
-- 5. Publication and snapshot trace projections
-- --------------------------------------------------------------------------

create or replace view public.live_runtime_publication_diagnostics_v as
select
  w.workflow_instance_id,
  w.workflow_key,
  w.workflow_name,
  w.status,
  w.health_state,
  w.diagnostic_priority,
  w.correlation_id,
  w.causation_id,
  w.parent_workflow_instance_id,
  w.aggregate_type,
  w.aggregate_id,
  w.league_id,
  w.league_round_id,
  w.match_id,
  coalesce(
    nullif(w.metadata ->> 'publication_id', '')::uuid,
    case when w.aggregate_type = 'publication' then w.aggregate_id end
  ) as publication_id,
  w.metadata ->> 'publication_channel' as publication_channel,
  w.metadata ->> 'publication_status' as publication_status,
  w.metadata ->> 'snapshot_type' as snapshot_type,
  nullif(w.metadata ->> 'snapshot_id', '')::uuid as snapshot_id,
  w.created_at,
  w.started_at,
  w.completed_at,
  w.failed_at,
  w.duration_seconds,
  w.retry_count,
  w.failure_count,
  w.last_error_code,
  w.last_error_message,
  w.last_error_details,
  w.metadata
from public.live_runtime_workflow_diagnostics_v w
where w.workflow_key ilike '%publish%'
   or w.workflow_key ilike '%publication%'
   or w.aggregate_type = 'publication'
   or w.metadata ? 'publication_id'
   or w.metadata ? 'publication_channel';

comment on view public.live_runtime_publication_diagnostics_v
is 'Publication Inspector trace projection derived from workflow identity and publication metadata.';

create or replace view public.live_runtime_snapshot_diagnostics_v as
select
  w.workflow_instance_id,
  w.workflow_key,
  w.workflow_name,
  w.status,
  w.health_state,
  w.diagnostic_priority,
  w.correlation_id,
  w.causation_id,
  w.parent_workflow_instance_id,
  w.aggregate_type,
  w.aggregate_id,
  w.league_id,
  w.league_round_id,
  w.match_id,
  coalesce(
    nullif(w.metadata ->> 'snapshot_id', '')::uuid,
    case when w.aggregate_type in ('snapshot', 'live_state_snapshot')
      then w.aggregate_id end
  ) as snapshot_id,
  w.metadata ->> 'snapshot_type' as snapshot_type,
  w.metadata ->> 'snapshot_version' as snapshot_version,
  w.metadata ->> 'snapshot_hash' as snapshot_hash,
  nullif(w.metadata ->> 'publication_id', '')::uuid as publication_id,
  w.metadata ->> 'publication_channel' as publication_channel,
  w.created_at,
  w.started_at,
  w.completed_at,
  w.failed_at,
  w.duration_seconds,
  w.retry_count,
  w.failure_count,
  w.last_error_code,
  w.last_error_message,
  w.last_error_details,
  w.metadata
from public.live_runtime_workflow_diagnostics_v w
where w.workflow_key ilike '%snapshot%'
   or w.aggregate_type in ('snapshot', 'live_state_snapshot')
   or w.metadata ? 'snapshot_id'
   or w.metadata ? 'snapshot_type';

comment on view public.live_runtime_snapshot_diagnostics_v
is 'Snapshot Inspector trace projection derived from workflow identity and snapshot metadata.';

-- --------------------------------------------------------------------------
-- 6. Runtime overview RPC
-- --------------------------------------------------------------------------

create or replace function public.get_live_runtime_diagnostics_overview_rpc()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_catalog
as $$
  select jsonb_build_object(
    'generated_at', clock_timestamp(),
    'workflows', jsonb_build_object(
      'total', count(*),
      'active', count(*) filter (
        where status in ('created', 'queued', 'running', 'waiting', 'retry_scheduled')
      ),
      'completed', count(*) filter (where status = 'completed'),
      'failed', count(*) filter (where status = 'failed'),
      'dead', count(*) filter (where status = 'dead'),
      'stale', count(*) filter (where is_stale),
      'requiring_attention', count(*) filter (where diagnostic_priority > 0)
    ),
    'steps', (
      select jsonb_build_object(
        'total', count(*),
        'active', count(*) filter (
          where status in ('queued', 'running', 'waiting', 'retry_scheduled')
        ),
        'completed', count(*) filter (where status = 'completed'),
        'failed', count(*) filter (where status = 'failed'),
        'stale', count(*) filter (where is_stale),
        'linked_jobs', count(*) filter (where job_id is not null)
      )
      from public.live_runtime_workflow_step_diagnostics_v
    ),
    'queues', coalesce((
      select jsonb_agg(to_jsonb(q) order by q.queue_key)
      from public.live_runtime_queue_diagnostics_v q
    ), '[]'::jsonb),
    'recent_failures', coalesce((
      select jsonb_agg(to_jsonb(f) order by f.diagnostic_priority desc, f.last_transition_at desc)
      from (
        select *
        from public.live_runtime_failure_diagnostics_v
        order by diagnostic_priority desc, last_transition_at desc
        limit 20
      ) f
    ), '[]'::jsonb)
  )
  from public.live_runtime_workflow_diagnostics_v;
$$;

comment on function public.get_live_runtime_diagnostics_overview_rpc()
is 'Returns the global Runtime Diagnostics overview for the Operational Platform.';

-- --------------------------------------------------------------------------
-- 7. Workflow Inspector RPC
-- --------------------------------------------------------------------------

create or replace function public.inspect_live_runtime_workflow_rpc(
  p_workflow_instance_id uuid
)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_catalog
as $$
  select jsonb_build_object(
    'workflow', to_jsonb(w),
    'steps', coalesce((
      select jsonb_agg(to_jsonb(s) order by s.step_index, s.created_at)
      from public.live_runtime_workflow_step_diagnostics_v s
      where s.workflow_instance_id = p_workflow_instance_id
    ), '[]'::jsonb),
    'jobs', coalesce((
      select jsonb_agg(to_jsonb(j) order by j.step_index, j.created_at)
      from public.live_runtime_job_diagnostics_v j
      where j.workflow_instance_id = p_workflow_instance_id
    ), '[]'::jsonb),
    'timeline', coalesce((
      select jsonb_agg(to_jsonb(t) order by t.sequence_no)
      from public.live_runtime_workflow_timeline t
      where t.workflow_instance_id = p_workflow_instance_id
    ), '[]'::jsonb),
    'correlation_chain', coalesce((
      select jsonb_agg(to_jsonb(c) order by c.created_at, c.workflow_instance_id)
      from public.live_runtime_workflow_diagnostics_v c
      where c.correlation_id = w.correlation_id
        and w.correlation_id is not null
    ), '[]'::jsonb),
    'failures', coalesce((
      select jsonb_agg(to_jsonb(f) order by f.diagnostic_priority desc, f.last_transition_at)
      from public.live_runtime_failure_diagnostics_v f
      where f.workflow_instance_id = p_workflow_instance_id
    ), '[]'::jsonb)
  )
  from public.live_runtime_workflow_diagnostics_v w
  where w.workflow_instance_id = p_workflow_instance_id;
$$;

comment on function public.inspect_live_runtime_workflow_rpc(uuid)
is 'Returns the complete Workflow Inspector document including steps, jobs, timeline, correlation and failures.';

-- --------------------------------------------------------------------------
-- 8. Job Inspector RPC
-- --------------------------------------------------------------------------

create or replace function public.inspect_live_runtime_job_rpc(
  p_job_id uuid
)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_catalog
as $$
  select jsonb_build_object(
    'job', to_jsonb(j),
    'workflow', to_jsonb(w),
    'timeline', coalesce((
      select jsonb_agg(to_jsonb(t) order by t.sequence_no)
      from public.live_runtime_workflow_timeline t
      where t.job_id = p_job_id
         or t.step_instance_id = j.step_instance_id
    ), '[]'::jsonb),
    'failures', coalesce((
      select jsonb_agg(to_jsonb(f) order by f.last_transition_at)
      from public.live_runtime_failure_diagnostics_v f
      where f.job_id = p_job_id
         or f.step_instance_id = j.step_instance_id
    ), '[]'::jsonb)
  )
  from public.live_runtime_job_diagnostics_v j
  join public.live_runtime_workflow_diagnostics_v w
    on w.workflow_instance_id = j.workflow_instance_id
  where j.job_id = p_job_id;
$$;

comment on function public.inspect_live_runtime_job_rpc(uuid)
is 'Returns linked workflow, timeline and failures for one runtime job identifier.';

-- --------------------------------------------------------------------------
-- 9. Queue Inspector RPC
-- --------------------------------------------------------------------------

create or replace function public.inspect_live_runtime_queue_rpc(
  p_queue_key text default null,
  p_limit integer default 100
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_catalog
as $$
declare
  v_limit integer := greatest(1, least(coalesce(p_limit, 100), 500));
begin
  return jsonb_build_object(
    'generated_at', clock_timestamp(),
    'queue', case
      when p_queue_key is null then null
      else (
        select to_jsonb(q)
        from public.live_runtime_queue_diagnostics_v q
        where q.queue_key = p_queue_key
      )
    end,
    'queues', coalesce((
      select jsonb_agg(to_jsonb(q) order by q.queue_key)
      from public.live_runtime_queue_diagnostics_v q
      where p_queue_key is null or q.queue_key = p_queue_key
    ), '[]'::jsonb),
    'active_items', coalesce((
      select jsonb_agg(to_jsonb(s) order by s.diagnostic_priority desc, s.last_transition_at)
      from (
        select *
        from public.live_runtime_workflow_step_diagnostics_v
        where status in ('queued', 'running', 'waiting', 'retry_scheduled', 'failed')
          and (p_queue_key is null or queue_key = p_queue_key)
        order by diagnostic_priority desc, last_transition_at
        limit v_limit
      ) s
    ), '[]'::jsonb)
  );
end;
$$;

comment on function public.inspect_live_runtime_queue_rpc(text, integer)
is 'Returns queue health and active or failed work items for the Queue Inspector.';

-- --------------------------------------------------------------------------
-- 10. Publication and Snapshot Inspector RPCs
-- --------------------------------------------------------------------------

create or replace function public.inspect_live_runtime_publication_rpc(
  p_publication_id uuid default null,
  p_workflow_instance_id uuid default null
)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_catalog
as $$
  select jsonb_build_object(
    'publication', to_jsonb(p),
    'workflow', public.inspect_live_runtime_workflow_rpc(p.workflow_instance_id)
  )
  from public.live_runtime_publication_diagnostics_v p
  where (p_publication_id is not null and p.publication_id = p_publication_id)
     or (p_workflow_instance_id is not null and p.workflow_instance_id = p_workflow_instance_id)
  order by p.created_at desc
  limit 1;
$$;

comment on function public.inspect_live_runtime_publication_rpc(uuid, uuid)
is 'Returns publication trace data and its complete Workflow Inspector document.';

create or replace function public.inspect_live_runtime_snapshot_rpc(
  p_snapshot_id uuid default null,
  p_workflow_instance_id uuid default null
)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_catalog
as $$
  select jsonb_build_object(
    'snapshot', to_jsonb(s),
    'workflow', public.inspect_live_runtime_workflow_rpc(s.workflow_instance_id),
    'publication', (
      select to_jsonb(p)
      from public.live_runtime_publication_diagnostics_v p
      where p.correlation_id = s.correlation_id
         or (
           s.publication_id is not null
           and p.publication_id = s.publication_id
         )
      order by p.created_at desc
      limit 1
    )
  )
  from public.live_runtime_snapshot_diagnostics_v s
  where (p_snapshot_id is not null and s.snapshot_id = p_snapshot_id)
     or (p_workflow_instance_id is not null and s.workflow_instance_id = p_workflow_instance_id)
  order by s.created_at desc
  limit 1;
$$;

comment on function public.inspect_live_runtime_snapshot_rpc(uuid, uuid)
is 'Returns snapshot trace data, linked workflow and correlated publication context.';

-- --------------------------------------------------------------------------
-- 11. Filtered workflow diagnostics RPC
-- --------------------------------------------------------------------------

create or replace function public.list_live_runtime_workflow_diagnostics_rpc(
  p_status text default null,
  p_workflow_key text default null,
  p_correlation_id uuid default null,
  p_health_state text default null,
  p_attention_only boolean default false,
  p_limit integer default 100,
  p_offset integer default 0
)
returns setof public.live_runtime_workflow_diagnostics_v
language plpgsql
stable
security definer
set search_path = public, pg_catalog
as $$
declare
  v_limit integer := greatest(1, least(coalesce(p_limit, 100), 500));
  v_offset integer := greatest(0, coalesce(p_offset, 0));
begin
  return query
  select w.*
  from public.live_runtime_workflow_diagnostics_v w
  where (p_status is null or w.status = p_status)
    and (p_workflow_key is null or w.workflow_key = p_workflow_key)
    and (p_correlation_id is null or w.correlation_id = p_correlation_id)
    and (p_health_state is null or w.health_state = p_health_state)
    and (not p_attention_only or w.diagnostic_priority > 0)
  order by
    w.diagnostic_priority desc,
    w.last_transition_at desc,
    w.workflow_instance_id
  limit v_limit
  offset v_offset;
end;
$$;

comment on function public.list_live_runtime_workflow_diagnostics_rpc(
  text, text, uuid, text, boolean, integer, integer
)
is 'Filtered and paginated workflow diagnostic listing for operational tools.';

-- --------------------------------------------------------------------------
-- 12. Security
-- --------------------------------------------------------------------------

revoke all on public.live_runtime_workflow_diagnostics_v
  from public, anon, authenticated;
revoke all on public.live_runtime_workflow_step_diagnostics_v
  from public, anon, authenticated;
revoke all on public.live_runtime_job_diagnostics_v
  from public, anon, authenticated;
revoke all on public.live_runtime_queue_diagnostics_v
  from public, anon, authenticated;
revoke all on public.live_runtime_failure_diagnostics_v
  from public, anon, authenticated;
revoke all on public.live_runtime_publication_diagnostics_v
  from public, anon, authenticated;
revoke all on public.live_runtime_snapshot_diagnostics_v
  from public, anon, authenticated;

revoke all on function public.get_live_runtime_diagnostics_overview_rpc()
  from public, anon, authenticated;
revoke all on function public.inspect_live_runtime_workflow_rpc(uuid)
  from public, anon, authenticated;
revoke all on function public.inspect_live_runtime_job_rpc(uuid)
  from public, anon, authenticated;
revoke all on function public.inspect_live_runtime_queue_rpc(text, integer)
  from public, anon, authenticated;
revoke all on function public.inspect_live_runtime_publication_rpc(uuid, uuid)
  from public, anon, authenticated;
revoke all on function public.inspect_live_runtime_snapshot_rpc(uuid, uuid)
  from public, anon, authenticated;
revoke all on function public.list_live_runtime_workflow_diagnostics_rpc(
  text, text, uuid, text, boolean, integer, integer
) from public, anon, authenticated;

grant select on public.live_runtime_workflow_diagnostics_v to service_role;
grant select on public.live_runtime_workflow_step_diagnostics_v to service_role;
grant select on public.live_runtime_job_diagnostics_v to service_role;
grant select on public.live_runtime_queue_diagnostics_v to service_role;
grant select on public.live_runtime_failure_diagnostics_v to service_role;
grant select on public.live_runtime_publication_diagnostics_v to service_role;
grant select on public.live_runtime_snapshot_diagnostics_v to service_role;

grant execute on function public.get_live_runtime_diagnostics_overview_rpc()
  to service_role;
grant execute on function public.inspect_live_runtime_workflow_rpc(uuid)
  to service_role;
grant execute on function public.inspect_live_runtime_job_rpc(uuid)
  to service_role;
grant execute on function public.inspect_live_runtime_queue_rpc(text, integer)
  to service_role;
grant execute on function public.inspect_live_runtime_publication_rpc(uuid, uuid)
  to service_role;
grant execute on function public.inspect_live_runtime_snapshot_rpc(uuid, uuid)
  to service_role;
grant execute on function public.list_live_runtime_workflow_diagnostics_rpc(
  text, text, uuid, text, boolean, integer, integer
) to service_role;

-- --------------------------------------------------------------------------
-- 13. Migration verification
-- --------------------------------------------------------------------------

do $$
declare
  v_missing text[];
begin
  select array_agg(expected.object_name order by expected.object_name)
  into v_missing
  from (
    values
      ('live_runtime_workflow_diagnostics_v'),
      ('live_runtime_workflow_step_diagnostics_v'),
      ('live_runtime_job_diagnostics_v'),
      ('live_runtime_queue_diagnostics_v'),
      ('live_runtime_failure_diagnostics_v'),
      ('live_runtime_publication_diagnostics_v'),
      ('live_runtime_snapshot_diagnostics_v')
  ) as expected(object_name)
  where to_regclass('public.' || expected.object_name) is null;

  if v_missing is not null then
    raise exception
      'Runtime Diagnostics migration incomplete. Missing objects: %',
      v_missing;
  end if;

  if to_regprocedure(
    'public.get_live_runtime_diagnostics_overview_rpc()'
  ) is null then
    raise exception 'Missing get_live_runtime_diagnostics_overview_rpc()';
  end if;

  if to_regprocedure(
    'public.inspect_live_runtime_workflow_rpc(uuid)'
  ) is null then
    raise exception 'Missing inspect_live_runtime_workflow_rpc(uuid)';
  end if;

  if to_regprocedure(
    'public.inspect_live_runtime_job_rpc(uuid)'
  ) is null then
    raise exception 'Missing inspect_live_runtime_job_rpc(uuid)';
  end if;

  if to_regprocedure(
    'public.inspect_live_runtime_queue_rpc(text,integer)'
  ) is null then
    raise exception 'Missing inspect_live_runtime_queue_rpc(text,integer)';
  end if;

  if to_regprocedure(
    'public.inspect_live_runtime_publication_rpc(uuid,uuid)'
  ) is null then
    raise exception 'Missing inspect_live_runtime_publication_rpc(uuid,uuid)';
  end if;

  if to_regprocedure(
    'public.inspect_live_runtime_snapshot_rpc(uuid,uuid)'
  ) is null then
    raise exception 'Missing inspect_live_runtime_snapshot_rpc(uuid,uuid)';
  end if;
end;
$$;

commit;
