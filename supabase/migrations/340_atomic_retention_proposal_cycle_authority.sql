-- ============================================================================
-- MIGRATION 340
-- Atomic retention proposal-cycle authority.
--
-- Serializes the canonical retention-planner-core proposal cycle:
--   request scheduler tick -> build proposal -> advance schedule due time.
--
-- The cycle is proposal-only:
--   * dispatch_enabled remains false by scheduler structural constraint;
--   * no retention plan is requested or built;
--   * no approval is performed;
--   * no retention execution is performed;
--   * no data deletion is performed.
--
-- Idempotency is derived from the canonical schedule due timestamp.
-- A transaction-scoped advisory lock plus schedule row lock serialize the
-- whole cycle and prevent duplicate proposal/progression under concurrency.
-- ============================================================================

create or replace function public.run_retention_proposal_cycle_rpc(
  p_requested_by uuid default null,
  p_request_payload jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $function$
declare
  v_reference_at timestamptz := clock_timestamp();
  v_schedule public.maintenance_schedules%rowtype;
  v_tick public.maintenance_scheduler_ticks%rowtype;
  v_dispatch public.maintenance_scheduler_dispatches%rowtype;
  v_advanced public.maintenance_schedules%rowtype;
  v_due_at timestamptz;
  v_idempotency_key text;
begin
  if jsonb_typeof(coalesce(p_request_payload, '{}'::jsonb)) <> 'object' then
    raise exception using
      errcode = '22023',
      message = 'RETENTION_PROPOSAL_CYCLE_REQUEST_PAYLOAD_INVALID';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(
      'maintenance-retention-proposal-cycle:retention-planner-core',
      0
    )
  );

  select s.*
    into v_schedule
  from public.maintenance_schedules s
  join public.maintenance_scheduler_profiles sp
    on sp.id = s.scheduler_profile_id
  where s.schedule_key = 'retention-planner-core'
    and s.target_engine = 'retention'
    and s.target_profile_key = 'runtime-retention-core'
    and s.enabled = true
    and s.retired_at is null
    and sp.profile_key = 'maintenance-runtime-core'
    and sp.retired_at is null
  order by s.schedule_version desc
  limit 1
  for update of s;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'RETENTION_PROPOSAL_SCHEDULE_NOT_FOUND';
  end if;

  if coalesce((v_schedule.request_template ->> 'planner_only')::boolean, false)
       is distinct from true then
    raise exception using
      errcode = '55000',
      message = 'RETENTION_PROPOSAL_SCHEDULE_NOT_PLANNER_ONLY';
  end if;

  v_due_at := coalesce(
    v_schedule.next_due_at,
    v_schedule.created_at + v_schedule.initial_delay
  );

  if v_due_at > v_reference_at then
    return jsonb_build_object(
      'handled', true,
      'due', false,
      'proposal_created', false,
      'schedule_id', v_schedule.id,
      'schedule_key', v_schedule.schedule_key,
      'due_at', v_due_at,
      'next_due_at', v_schedule.next_due_at,
      'reference_at', v_reference_at
    );
  end if;

  v_idempotency_key :=
    'retention-planner-core:' ||
    to_char(
      v_due_at at time zone 'UTC',
      'YYYYMMDDHH24MISSUS'
    );

  v_tick := public.request_maintenance_scheduler_tick_rpc(
    'maintenance-runtime-core',
    v_idempotency_key,
    p_requested_by,
    coalesce(p_request_payload, '{}'::jsonb)
      || jsonb_build_object(
           'authority', 'run_retention_proposal_cycle_rpc',
           'schedule_id', v_schedule.id,
           'schedule_key', v_schedule.schedule_key,
           'due_at', v_due_at,
           'planner_only', true
         ),
    null,
    null
  );

  v_tick := public.build_maintenance_scheduler_tick_rpc(
    v_tick.id,
    v_reference_at
  );

  if v_tick.status <> 'completed'
     or v_tick.due_schedule_count <> 1
     or v_tick.dispatch_count <> 1 then
    raise exception using
      errcode = '55000',
      message = 'RETENTION_PROPOSAL_TICK_CONTRACT_VIOLATION',
      detail = jsonb_build_object(
        'tick_id', v_tick.id,
        'status', v_tick.status,
        'due_schedule_count', v_tick.due_schedule_count,
        'dispatch_count', v_tick.dispatch_count
      )::text;
  end if;

  select d.*
    into v_dispatch
  from public.maintenance_scheduler_dispatches d
  where d.scheduler_tick_id = v_tick.id
    and d.schedule_id = v_schedule.id
    and d.target_engine = 'retention'
    and d.target_profile_key = 'runtime-retention-core'
    and d.status = 'proposed'
    and d.dispatch_enabled = false
    and d.due_at = v_due_at;

  if not found then
    raise exception using
      errcode = '55000',
      message = 'RETENTION_PROPOSAL_DISPATCH_CONTRACT_VIOLATION';
  end if;

  v_advanced := public.recalculate_maintenance_schedule_due_rpc(
    v_schedule.id,
    v_reference_at
  );

  if v_advanced.last_due_at is distinct from v_due_at
     or v_advanced.next_due_at <= v_due_at
     or v_advanced.next_due_at <= v_reference_at then
    raise exception using
      errcode = '55000',
      message = 'RETENTION_PROPOSAL_SCHEDULE_PROGRESSION_INVALID';
  end if;

  return jsonb_build_object(
    'handled', true,
    'due', true,
    'proposal_created', true,
    'schedule_id', v_schedule.id,
    'schedule_key', v_schedule.schedule_key,
    'due_at', v_due_at,
    'tick_id', v_tick.id,
    'tick_idempotency_key', v_idempotency_key,
    'dispatch_id', v_dispatch.id,
    'dispatch_enabled', v_dispatch.dispatch_enabled,
    'last_due_at', v_advanced.last_due_at,
    'next_due_at', v_advanced.next_due_at,
    'reference_at', v_reference_at
  );
end;
$function$;

revoke all
on function public.run_retention_proposal_cycle_rpc(uuid,jsonb)
from public;

revoke execute
on function public.run_retention_proposal_cycle_rpc(uuid,jsonb)
from anon, authenticated;

grant execute
on function public.run_retention_proposal_cycle_rpc(uuid,jsonb)
to service_role, postgres;