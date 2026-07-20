-- FantaGol
-- Migration 072: Maintenance Scheduler Engine
-- Purpose: deterministic, disabled-by-default scheduling and non-executable dispatch planning
-- Dependencies: 067, 068, 069, 070, 071

begin;

create extension if not exists pgcrypto;

create table if not exists public.maintenance_scheduler_profiles (
  id uuid primary key default gen_random_uuid(),
  profile_key text not null,
  profile_version integer not null default 1,
  display_name text not null,
  description text,
  enabled boolean not null default false,
  automatic_dispatch_enabled boolean not null default false,
  default_timezone text not null default 'UTC',
  maximum_dispatches_per_tick integer not null default 100,
  minimum_tick_interval interval not null default interval '5 minutes',
  scheduler_config jsonb not null default '{}'::jsonb,
  created_by uuid,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  retired_at timestamptz,
  constraint maintenance_scheduler_profiles_key_check check (btrim(profile_key) <> ''),
  constraint maintenance_scheduler_profiles_version_check check (profile_version > 0),
  constraint maintenance_scheduler_profiles_name_check check (btrim(display_name) <> ''),
  constraint maintenance_scheduler_profiles_dispatch_guard check (automatic_dispatch_enabled = false),
  constraint maintenance_scheduler_profiles_max_dispatch_check check (maximum_dispatches_per_tick between 1 and 10000),
  constraint maintenance_scheduler_profiles_tick_interval_check check (minimum_tick_interval >= interval '1 minute'),
  constraint maintenance_scheduler_profiles_unique unique (profile_key, profile_version)
);

create index if not exists maintenance_scheduler_profiles_active_idx
  on public.maintenance_scheduler_profiles (enabled, profile_key)
  where retired_at is null;

create trigger maintenance_scheduler_profiles_set_updated_at
before update on public.maintenance_scheduler_profiles
for each row execute function public.set_maintenance_updated_at();

comment on table public.maintenance_scheduler_profiles is
'Disabled-by-default scheduler profiles. Automatic dispatch is structurally prohibited.';

create table if not exists public.maintenance_schedules (
  id uuid primary key default gen_random_uuid(),
  scheduler_profile_id uuid not null references public.maintenance_scheduler_profiles(id),
  schedule_key text not null,
  schedule_version integer not null default 1,
  target_engine text not null,
  target_profile_key text not null,
  enabled boolean not null default false,
  cadence_interval interval not null,
  initial_delay interval not null default interval '0 seconds',
  jitter_interval interval not null default interval '0 seconds',
  backoff_interval interval not null default interval '15 minutes',
  maximum_backoff_interval interval not null default interval '6 hours',
  priority smallint not null default 100,
  request_template jsonb not null default '{}'::jsonb,
  last_due_at timestamptz,
  next_due_at timestamptz,
  created_by uuid,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  retired_at timestamptz,
  constraint maintenance_schedules_key_check check (btrim(schedule_key) <> ''),
  constraint maintenance_schedules_version_check check (schedule_version > 0),
  constraint maintenance_schedules_engine_check check (target_engine in ('maintenance','retention','reconciliation','health_monitor')),
  constraint maintenance_schedules_target_profile_check check (btrim(target_profile_key) <> ''),
  constraint maintenance_schedules_cadence_check check (cadence_interval >= interval '5 minutes'),
  constraint maintenance_schedules_delay_check check (initial_delay >= interval '0 seconds'),
  constraint maintenance_schedules_jitter_check check (jitter_interval >= interval '0 seconds'),
  constraint maintenance_schedules_backoff_check check (backoff_interval >= interval '1 minute'),
  constraint maintenance_schedules_max_backoff_check check (maximum_backoff_interval >= backoff_interval),
  constraint maintenance_schedules_priority_check check (priority between 1 and 1000),
  constraint maintenance_schedules_unique unique (scheduler_profile_id, schedule_key, schedule_version)
);

create index if not exists maintenance_schedules_due_idx
  on public.maintenance_schedules (enabled, next_due_at, priority, schedule_key)
  where retired_at is null;

create index if not exists maintenance_schedules_engine_idx
  on public.maintenance_schedules (target_engine, target_profile_key);

create trigger maintenance_schedules_set_updated_at
before update on public.maintenance_schedules
for each row execute function public.set_maintenance_updated_at();

comment on table public.maintenance_schedules is
'Deterministic cadence definitions for maintenance-related engines.';

create table if not exists public.maintenance_scheduler_ticks (
  id uuid primary key default gen_random_uuid(),
  scheduler_profile_id uuid not null references public.maintenance_scheduler_profiles(id),
  profile_key text not null,
  profile_version integer not null,
  status text not null default 'requested',
  idempotency_key text not null,
  requested_by uuid,
  requested_at timestamptz not null default clock_timestamp(),
  evaluation_at timestamptz,
  completed_at timestamptz,
  due_schedule_count integer not null default 0,
  dispatch_count integer not null default 0,
  skipped_count integer not null default 0,
  truncated boolean not null default false,
  tick_hash text,
  request_payload jsonb not null default '{}'::jsonb,
  scheduler_snapshot jsonb not null default '{}'::jsonb,
  error_code text,
  error_message text,
  error_details jsonb,
  correlation_id uuid,
  causation_id uuid,
  created_at timestamptz not null default clock_timestamp(),
  constraint maintenance_scheduler_ticks_status_check check (status in ('requested','evaluating','completed','failed','cancelled')),
  constraint maintenance_scheduler_ticks_profile_check check (btrim(profile_key) <> '' and profile_version > 0),
  constraint maintenance_scheduler_ticks_idempotency_check check (btrim(idempotency_key) <> ''),
  constraint maintenance_scheduler_ticks_counts_check check (due_schedule_count >= 0 and dispatch_count >= 0 and skipped_count >= 0),
  constraint maintenance_scheduler_ticks_hash_check check (tick_hash is null or tick_hash ~ '^[0-9a-f]{64}$'),
  constraint maintenance_scheduler_ticks_unique unique (profile_key, idempotency_key)
);

create index if not exists maintenance_scheduler_ticks_status_idx
  on public.maintenance_scheduler_ticks (status, requested_at desc);
create index if not exists maintenance_scheduler_ticks_profile_idx
  on public.maintenance_scheduler_ticks (profile_key, requested_at desc);

comment on table public.maintenance_scheduler_ticks is
'Immutable scheduler evaluation ledger after completion or failure.';

create table if not exists public.maintenance_scheduler_dispatches (
  id uuid primary key default gen_random_uuid(),
  scheduler_tick_id uuid not null references public.maintenance_scheduler_ticks(id) on delete cascade,
  schedule_id uuid not null references public.maintenance_schedules(id),
  dispatch_key text not null,
  target_engine text not null,
  target_profile_key text not null,
  due_at timestamptz not null,
  proposed_at timestamptz not null default clock_timestamp(),
  status text not null default 'proposed',
  priority smallint not null,
  dispatch_enabled boolean not null default false,
  target_request_payload jsonb not null default '{}'::jsonb,
  reason text not null,
  skip_code text,
  skip_details jsonb,
  dispatch_hash text not null,
  created_at timestamptz not null default clock_timestamp(),
  constraint maintenance_scheduler_dispatches_key_check check (btrim(dispatch_key) <> ''),
  constraint maintenance_scheduler_dispatches_engine_check check (target_engine in ('maintenance','retention','reconciliation','health_monitor')),
  constraint maintenance_scheduler_dispatches_profile_check check (btrim(target_profile_key) <> ''),
  constraint maintenance_scheduler_dispatches_status_check check (status in ('proposed','skipped','acknowledged')),
  constraint maintenance_scheduler_dispatches_priority_check check (priority between 1 and 1000),
  constraint maintenance_scheduler_dispatches_execution_guard check (dispatch_enabled = false),
  constraint maintenance_scheduler_dispatches_reason_check check (btrim(reason) <> ''),
  constraint maintenance_scheduler_dispatches_hash_check check (dispatch_hash ~ '^[0-9a-f]{64}$'),
  constraint maintenance_scheduler_dispatches_unique unique (scheduler_tick_id, dispatch_key)
);

create index if not exists maintenance_scheduler_dispatches_tick_idx
  on public.maintenance_scheduler_dispatches (scheduler_tick_id, priority, due_at);
create index if not exists maintenance_scheduler_dispatches_attention_idx
  on public.maintenance_scheduler_dispatches (status, target_engine, due_at);

comment on table public.maintenance_scheduler_dispatches is
'Non-executable dispatch proposal ledger. dispatch_enabled is structurally forced to false.';

create or replace function public.protect_maintenance_scheduler_tick_core()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  if old.status in ('completed','failed','cancelled') then
    raise exception using errcode = '55000', message = 'terminal scheduler ticks are immutable';
  end if;

  if new.id <> old.id
     or new.scheduler_profile_id <> old.scheduler_profile_id
     or new.profile_key <> old.profile_key
     or new.profile_version <> old.profile_version
     or new.idempotency_key <> old.idempotency_key
     or new.requested_by is distinct from old.requested_by
     or new.requested_at <> old.requested_at
     or new.request_payload <> old.request_payload
     or new.correlation_id is distinct from old.correlation_id
     or new.causation_id is distinct from old.causation_id
     or new.created_at <> old.created_at then
    raise exception using errcode = '55000', message = 'scheduler tick identity is immutable';
  end if;

  return new;
end;
$$;

create trigger maintenance_scheduler_ticks_protect_core
before update on public.maintenance_scheduler_ticks
for each row execute function public.protect_maintenance_scheduler_tick_core();

create or replace function public.protect_maintenance_scheduler_dispatch()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  if tg_op = 'DELETE' then
    raise exception using errcode = '55000', message = 'scheduler dispatches are immutable';
  end if;

  if new.scheduler_tick_id <> old.scheduler_tick_id
     or new.schedule_id <> old.schedule_id
     or new.dispatch_key <> old.dispatch_key
     or new.target_engine <> old.target_engine
     or new.target_profile_key <> old.target_profile_key
     or new.due_at <> old.due_at
     or new.proposed_at <> old.proposed_at
     or new.priority <> old.priority
     or new.dispatch_enabled <> old.dispatch_enabled
     or new.target_request_payload <> old.target_request_payload
     or new.reason <> old.reason
     or new.dispatch_hash <> old.dispatch_hash
     or new.created_at <> old.created_at then
    raise exception using errcode = '55000', message = 'scheduler dispatch core is immutable';
  end if;

  return new;
end;
$$;

create trigger maintenance_scheduler_dispatches_protect_update
before update on public.maintenance_scheduler_dispatches
for each row execute function public.protect_maintenance_scheduler_dispatch();
create trigger maintenance_scheduler_dispatches_protect_delete
before delete on public.maintenance_scheduler_dispatches
for each row execute function public.protect_maintenance_scheduler_dispatch();

create or replace function public.request_maintenance_scheduler_tick_rpc(
  p_profile_key text,
  p_idempotency_key text,
  p_requested_by uuid default null,
  p_request_payload jsonb default '{}'::jsonb,
  p_correlation_id uuid default null,
  p_causation_id uuid default null
)
returns public.maintenance_scheduler_ticks
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_profile public.maintenance_scheduler_profiles%rowtype;
  v_tick public.maintenance_scheduler_ticks%rowtype;
begin
  if p_profile_key is null or btrim(p_profile_key) = '' then
    raise exception using errcode = '22023', message = 'profile_key is required';
  end if;
  if p_idempotency_key is null or btrim(p_idempotency_key) = '' then
    raise exception using errcode = '22023', message = 'idempotency_key is required';
  end if;

  select * into v_profile
  from public.maintenance_scheduler_profiles
  where profile_key = btrim(p_profile_key)
    and retired_at is null
  order by profile_version desc
  limit 1;

  if not found then
    raise exception using errcode = 'P0002', message = 'scheduler profile not found';
  end if;

  insert into public.maintenance_scheduler_ticks (
    scheduler_profile_id, profile_key, profile_version, idempotency_key,
    requested_by, request_payload, correlation_id, causation_id
  ) values (
    v_profile.id, v_profile.profile_key, v_profile.profile_version, btrim(p_idempotency_key),
    p_requested_by, coalesce(p_request_payload, '{}'::jsonb), p_correlation_id, p_causation_id
  )
  on conflict (profile_key, idempotency_key) do update
    set idempotency_key = excluded.idempotency_key
  returning * into v_tick;

  return v_tick;
end;
$$;

comment on function public.request_maintenance_scheduler_tick_rpc(text,text,uuid,jsonb,uuid,uuid) is
'Creates or returns an idempotent scheduler tick request. Does not dispatch work.';

create or replace function public.build_maintenance_scheduler_tick_rpc(
  p_scheduler_tick_id uuid,
  p_evaluation_at timestamptz default clock_timestamp()
)
returns public.maintenance_scheduler_ticks
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_tick public.maintenance_scheduler_ticks%rowtype;
  v_profile public.maintenance_scheduler_profiles%rowtype;
  v_due_count integer := 0;
  v_dispatch_count integer := 0;
  v_skipped_count integer := 0;
  v_truncated boolean := false;
  v_snapshot jsonb;
  v_hash text;
begin
  select * into v_tick
  from public.maintenance_scheduler_ticks
  where id = p_scheduler_tick_id
  for update;

  if not found then
    raise exception using errcode = 'P0002', message = 'scheduler tick not found';
  end if;

  if v_tick.status in ('completed','failed','cancelled') then
    return v_tick;
  end if;

  select * into v_profile
  from public.maintenance_scheduler_profiles
  where id = v_tick.scheduler_profile_id;

  update public.maintenance_scheduler_ticks
  set status = 'evaluating', evaluation_at = coalesce(p_evaluation_at, clock_timestamp())
  where id = v_tick.id;

  with due as (
    select s.*,
           row_number() over (order by s.priority, s.next_due_at nulls first, s.schedule_key) as rn
    from public.maintenance_schedules s
    where s.scheduler_profile_id = v_profile.id
      and s.enabled
      and s.retired_at is null
      and coalesce(s.next_due_at, s.created_at + s.initial_delay) <= coalesce(p_evaluation_at, clock_timestamp())
  ), inserted as (
    insert into public.maintenance_scheduler_dispatches (
      scheduler_tick_id, schedule_id, dispatch_key, target_engine, target_profile_key,
      due_at, status, priority, dispatch_enabled, target_request_payload, reason, dispatch_hash
    )
    select
      v_tick.id,
      d.id,
      d.schedule_key || ':' || to_char(coalesce(d.next_due_at, d.created_at + d.initial_delay) at time zone 'UTC', 'YYYYMMDDHH24MISSUS'),
      d.target_engine,
      d.target_profile_key,
      coalesce(d.next_due_at, d.created_at + d.initial_delay),
      case when d.rn <= v_profile.maximum_dispatches_per_tick then 'proposed' else 'skipped' end,
      d.priority,
      false,
      d.request_template || jsonb_build_object(
        'scheduler_tick_id', v_tick.id,
        'schedule_id', d.id,
        'schedule_key', d.schedule_key,
        'target_profile_key', d.target_profile_key,
        'due_at', coalesce(d.next_due_at, d.created_at + d.initial_delay),
        'dispatch_enabled', false
      ),
      case when d.rn <= v_profile.maximum_dispatches_per_tick
        then 'due schedule evaluated; dispatch requires an external explicit command'
        else 'tick dispatch limit reached'
      end,
      encode(digest(concat_ws('|', v_tick.id::text, d.id::text, d.schedule_key,
        coalesce(d.next_due_at, d.created_at + d.initial_delay)::text, d.target_engine,
        d.target_profile_key, 'dispatch_enabled=false'), 'sha256'), 'hex')
    from due d
    on conflict (scheduler_tick_id, dispatch_key) do nothing
    returning status
  )
  select
    (select count(*) from due),
    count(*) filter (where status = 'proposed'),
    count(*) filter (where status = 'skipped')
  into v_due_count, v_dispatch_count, v_skipped_count
  from inserted;

  v_truncated := v_due_count > v_profile.maximum_dispatches_per_tick;

  v_snapshot := jsonb_build_object(
    'profile_key', v_profile.profile_key,
    'profile_version', v_profile.profile_version,
    'profile_enabled', v_profile.enabled,
    'automatic_dispatch_enabled', v_profile.automatic_dispatch_enabled,
    'evaluation_at', coalesce(p_evaluation_at, clock_timestamp()),
    'due_schedule_count', v_due_count,
    'dispatch_count', v_dispatch_count,
    'skipped_count', v_skipped_count,
    'truncated', v_truncated,
    'dispatches', coalesce((
      select jsonb_agg(jsonb_build_object(
        'dispatch_id', d.id,
        'dispatch_key', d.dispatch_key,
        'target_engine', d.target_engine,
        'target_profile_key', d.target_profile_key,
        'due_at', d.due_at,
        'status', d.status,
        'dispatch_enabled', d.dispatch_enabled
      ) order by d.priority, d.due_at, d.dispatch_key)
      from public.maintenance_scheduler_dispatches d
      where d.scheduler_tick_id = v_tick.id
    ), '[]'::jsonb)
  );

  v_hash := encode(digest(v_snapshot::text, 'sha256'), 'hex');

  update public.maintenance_scheduler_ticks
  set status = 'completed',
      completed_at = clock_timestamp(),
      due_schedule_count = v_due_count,
      dispatch_count = v_dispatch_count,
      skipped_count = v_skipped_count,
      truncated = v_truncated,
      scheduler_snapshot = v_snapshot,
      tick_hash = v_hash
  where id = v_tick.id
  returning * into v_tick;

  return v_tick;
exception when others then
  update public.maintenance_scheduler_ticks
  set status = 'failed',
      completed_at = clock_timestamp(),
      error_code = sqlstate,
      error_message = sqlerrm,
      error_details = jsonb_build_object('function','build_maintenance_scheduler_tick_rpc')
  where id = p_scheduler_tick_id
    and status not in ('completed','failed','cancelled');
  raise;
end;
$$;

comment on function public.build_maintenance_scheduler_tick_rpc(uuid,timestamptz) is
'Evaluates due schedules and materializes non-executable dispatch proposals.';

create or replace function public.acknowledge_maintenance_scheduler_dispatch_rpc(
  p_dispatch_id uuid,
  p_acknowledged_by uuid,
  p_note text default null
)
returns public.maintenance_scheduler_dispatches
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_dispatch public.maintenance_scheduler_dispatches%rowtype;
begin
  update public.maintenance_scheduler_dispatches
  set status = 'acknowledged',
      skip_details = coalesce(skip_details, '{}'::jsonb) || jsonb_build_object(
        'acknowledged_by', p_acknowledged_by,
        'acknowledged_at', clock_timestamp(),
        'note', p_note
      )
  where id = p_dispatch_id
    and status in ('proposed','skipped')
  returning * into v_dispatch;

  if not found then
    raise exception using errcode = 'P0002', message = 'acknowledgeable scheduler dispatch not found';
  end if;

  return v_dispatch;
end;
$$;

create or replace function public.recalculate_maintenance_schedule_due_rpc(
  p_schedule_id uuid,
  p_reference_at timestamptz default clock_timestamp()
)
returns public.maintenance_schedules
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_schedule public.maintenance_schedules%rowtype;
  v_base timestamptz;
begin
  select * into v_schedule
  from public.maintenance_schedules
  where id = p_schedule_id
  for update;

  if not found then
    raise exception using errcode = 'P0002', message = 'maintenance schedule not found';
  end if;

  v_base := greatest(coalesce(v_schedule.last_due_at, v_schedule.created_at + v_schedule.initial_delay),
                     coalesce(p_reference_at, clock_timestamp()));

  update public.maintenance_schedules
  set last_due_at = coalesce(next_due_at, created_at + initial_delay),
      next_due_at = v_base + cadence_interval
  where id = p_schedule_id
  returning * into v_schedule;

  return v_schedule;
end;
$$;

create or replace function public.cancel_maintenance_scheduler_tick_rpc(
  p_scheduler_tick_id uuid,
  p_reason text
)
returns public.maintenance_scheduler_ticks
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_tick public.maintenance_scheduler_ticks%rowtype;
begin
  if p_reason is null or btrim(p_reason) = '' then
    raise exception using errcode = '22023', message = 'cancellation reason is required';
  end if;

  update public.maintenance_scheduler_ticks
  set status = 'cancelled',
      completed_at = clock_timestamp(),
      error_code = 'CANCELLED',
      error_message = btrim(p_reason)
  where id = p_scheduler_tick_id
    and status in ('requested','evaluating')
  returning * into v_tick;

  if not found then
    raise exception using errcode = 'P0002', message = 'cancellable scheduler tick not found';
  end if;

  return v_tick;
end;
$$;

create or replace view public.maintenance_scheduler_tick_status_v1 as
select
  t.id as scheduler_tick_id,
  t.scheduler_profile_id,
  t.profile_key,
  t.profile_version,
  p.display_name as profile_display_name,
  p.enabled as profile_enabled,
  p.automatic_dispatch_enabled,
  t.status,
  t.idempotency_key,
  t.requested_by,
  t.requested_at,
  t.evaluation_at,
  t.completed_at,
  t.due_schedule_count,
  t.dispatch_count,
  t.skipped_count,
  t.truncated,
  t.tick_hash,
  t.request_payload,
  t.scheduler_snapshot,
  t.error_code,
  t.error_message,
  t.error_details,
  t.correlation_id,
  t.causation_id,
  t.created_at
from public.maintenance_scheduler_ticks t
join public.maintenance_scheduler_profiles p on p.id = t.scheduler_profile_id;

create or replace view public.maintenance_scheduler_attention_v1 as
select
  d.id as scheduler_dispatch_id,
  d.scheduler_tick_id,
  d.schedule_id,
  s.schedule_key,
  d.dispatch_key,
  d.target_engine,
  d.target_profile_key,
  d.due_at,
  d.proposed_at,
  d.status,
  d.priority,
  d.dispatch_enabled,
  d.target_request_payload,
  d.reason,
  d.skip_code,
  d.skip_details,
  d.dispatch_hash,
  d.created_at,
  t.profile_key as scheduler_profile_key,
  t.profile_version as scheduler_profile_version,
  t.status as scheduler_tick_status,
  t.requested_at as tick_requested_at,
  case
    when d.dispatch_enabled then 'critical'
    when d.status = 'proposed' and d.due_at < clock_timestamp() - interval '1 hour' then 'high'
    when d.status = 'proposed' then 'medium'
    when d.status = 'skipped' then 'low'
    else 'info'
  end as attention_level,
  greatest(d.due_at, d.proposed_at) as attention_reference_at
from public.maintenance_scheduler_dispatches d
join public.maintenance_scheduler_ticks t on t.id = d.scheduler_tick_id
join public.maintenance_schedules s on s.id = d.schedule_id
where d.status in ('proposed','skipped') or d.dispatch_enabled;

alter table public.maintenance_scheduler_profiles enable row level security;
alter table public.maintenance_schedules enable row level security;
alter table public.maintenance_scheduler_ticks enable row level security;
alter table public.maintenance_scheduler_dispatches enable row level security;

create policy maintenance_scheduler_profiles_service_role_all
on public.maintenance_scheduler_profiles for all to service_role using (true) with check (true);
create policy maintenance_schedules_service_role_all
on public.maintenance_schedules for all to service_role using (true) with check (true);
create policy maintenance_scheduler_ticks_service_role_all
on public.maintenance_scheduler_ticks for all to service_role using (true) with check (true);
create policy maintenance_scheduler_dispatches_service_role_all
on public.maintenance_scheduler_dispatches for all to service_role using (true) with check (true);

revoke all on public.maintenance_scheduler_profiles from public, anon, authenticated;
revoke all on public.maintenance_schedules from public, anon, authenticated;
revoke all on public.maintenance_scheduler_ticks from public, anon, authenticated;
revoke all on public.maintenance_scheduler_dispatches from public, anon, authenticated;

grant select, insert, update, delete on public.maintenance_scheduler_profiles to service_role;
grant select, insert, update, delete on public.maintenance_schedules to service_role;
grant select, insert, update on public.maintenance_scheduler_ticks to service_role;
grant select, insert, update on public.maintenance_scheduler_dispatches to service_role;

revoke all on public.maintenance_scheduler_tick_status_v1 from public, anon, authenticated, service_role;
revoke all on public.maintenance_scheduler_attention_v1 from public, anon, authenticated, service_role;
grant select on public.maintenance_scheduler_tick_status_v1 to service_role;
grant select on public.maintenance_scheduler_attention_v1 to service_role;

revoke all on function public.protect_maintenance_scheduler_tick_core() from public;
revoke all on function public.protect_maintenance_scheduler_dispatch() from public;
revoke all on function public.request_maintenance_scheduler_tick_rpc(text,text,uuid,jsonb,uuid,uuid) from public, anon, authenticated;
revoke all on function public.build_maintenance_scheduler_tick_rpc(uuid,timestamptz) from public, anon, authenticated;
revoke all on function public.acknowledge_maintenance_scheduler_dispatch_rpc(uuid,uuid,text) from public, anon, authenticated;
revoke all on function public.recalculate_maintenance_schedule_due_rpc(uuid,timestamptz) from public, anon, authenticated;
revoke all on function public.cancel_maintenance_scheduler_tick_rpc(uuid,text) from public, anon, authenticated;

grant execute on function public.request_maintenance_scheduler_tick_rpc(text,text,uuid,jsonb,uuid,uuid) to service_role;
grant execute on function public.build_maintenance_scheduler_tick_rpc(uuid,timestamptz) to service_role;
grant execute on function public.acknowledge_maintenance_scheduler_dispatch_rpc(uuid,uuid,text) to service_role;
grant execute on function public.recalculate_maintenance_schedule_due_rpc(uuid,timestamptz) to service_role;
grant execute on function public.cancel_maintenance_scheduler_tick_rpc(uuid,text) to service_role;

insert into public.maintenance_scheduler_profiles (
  profile_key, profile_version, display_name, description,
  enabled, automatic_dispatch_enabled, default_timezone,
  maximum_dispatches_per_tick, minimum_tick_interval, scheduler_config
) values (
  'maintenance-runtime-core', 1, 'Maintenance Runtime Core',
  'Disabled-by-default scheduler for maintenance, retention, reconciliation and health monitoring.',
  false, false, 'UTC', 100, interval '5 minutes',
  jsonb_build_object(
    'target_engines', jsonb_build_array('maintenance','retention','reconciliation','health_monitor'),
    'automatic_dispatch_enabled', false,
    'dispatch_mode', 'proposal_only'
  )
)
on conflict (profile_key, profile_version) do nothing;

insert into public.maintenance_schedules (
  scheduler_profile_id, schedule_key, schedule_version, target_engine,
  target_profile_key, enabled, cadence_interval, initial_delay,
  backoff_interval, maximum_backoff_interval, priority, request_template, next_due_at
)
select p.id, v.schedule_key, 1, v.target_engine, v.target_profile_key,
       false, v.cadence_interval, interval '0 seconds', interval '15 minutes', interval '6 hours',
       v.priority, v.request_template, null
from public.maintenance_scheduler_profiles p
cross join (values
  ('retention-planner-core', 'retention', 'runtime-retention-core', interval '24 hours', 300::smallint, '{"planner_only":true}'::jsonb),
  ('runtime-reconciliation-core', 'reconciliation', 'runtime-core', interval '30 minutes', 100::smallint, '{"scan_mode":"observation_only"}'::jsonb),
  ('health-monitor-core', 'health_monitor', 'runtime-health-core', interval '15 minutes', 50::smallint, '{"monitor_mode":"observation_only"}'::jsonb)
) as v(schedule_key,target_engine,target_profile_key,cadence_interval,priority,request_template)
where p.profile_key = 'maintenance-runtime-core'
  and p.profile_version = 1
on conflict (scheduler_profile_id, schedule_key, schedule_version) do nothing;

do $$
begin
  if to_regprocedure('public.request_retention_plan_rpc(text,text,uuid,interval,integer,jsonb,uuid,uuid)') is null then
    raise exception 'dependency missing: request_retention_plan_rpc';
  end if;
  if to_regprocedure('public.request_runtime_reconciliation_scan_rpc(text,text,uuid,uuid,jsonb,uuid,uuid)') is null then
    raise exception 'dependency missing: request_runtime_reconciliation_scan_rpc';
  end if;
  if to_regprocedure('public.request_health_monitor_run_rpc(text,text,uuid,jsonb,uuid,uuid)') is null then
    raise exception 'dependency missing: request_health_monitor_run_rpc';
  end if;
  if exists (select 1 from public.maintenance_scheduler_profiles where automatic_dispatch_enabled) then
    raise exception 'automatic dispatch invariant violated';
  end if;
  if exists (select 1 from public.maintenance_scheduler_dispatches where dispatch_enabled) then
    raise exception 'dispatch execution invariant violated';
  end if;
end;
$$;

commit;
