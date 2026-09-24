-- ============================================================================
-- MIGRATION 342
-- Production heartbeat wake-up authority foundation.
--
-- Creates the minimal persistent state and narrow RPC authority required to
-- gate the existing Supabase pg_cron heartbeat before Vercel is invoked.
--
-- IMPORTANT:
--   - does NOT alter cron.job;
--   - does NOT invoke HTTP / pg_net;
--   - does NOT alter provider cadence;
--   - does NOT move Football Data / Market policy into SQL;
--   - keeps direct table access closed to Data API roles;
--   - future wake-up is derived only from already-materialized DB signals,
--     with a conservative generic fallback.
-- ============================================================================

create table if not exists public.live_runtime_heartbeat_state (
  state_key text primary key,
  next_wakeup_at timestamptz not null,
  lease_token uuid null,
  lease_owner text null,
  lease_acquired_at timestamptz null,
  lease_expires_at timestamptz null,
  last_dispatched_at timestamptz null,
  last_completed_at timestamptz null,
  last_failure_at timestamptz null,
  last_reason text null,
  version integer not null default 1,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),

  constraint live_runtime_heartbeat_state_singleton_key_check
    check (state_key = 'production-heartbeat'),

  constraint live_runtime_heartbeat_state_lease_shape_check
    check (
      (
        lease_token is null
        and lease_owner is null
        and lease_acquired_at is null
        and lease_expires_at is null
      )
      or
      (
        lease_token is not null
        and lease_owner is not null
        and length(btrim(lease_owner)) between 3 and 200
        and lease_acquired_at is not null
        and lease_expires_at is not null
        and lease_expires_at > lease_acquired_at
      )
    )
);

comment on table public.live_runtime_heartbeat_state is
  'Singleton production heartbeat wake-up/lease state. Direct Data API mutation is forbidden; canonical access is through narrow SECURITY DEFINER RPC authority.';

-- October 30 Data API posture: explicit grants/revokes live in the same
-- migration that creates the table.
revoke all on table public.live_runtime_heartbeat_state
from public, anon, authenticated, service_role;

insert into public.live_runtime_heartbeat_state (
  state_key,
  next_wakeup_at,
  last_reason
)
values (
  'production-heartbeat',
  clock_timestamp(),
  'bootstrap'
)
on conflict (state_key) do nothing;

create or replace function public.resolve_production_heartbeat_next_wakeup_internal(
  p_now timestamptz default clock_timestamp()
)
returns table (
  next_wakeup_at timestamptz,
  wakeup_reason text
)
language sql
security definer
set search_path = pg_catalog, public
as $function$
  with candidates as (
    select
      min(j.scheduled_at) as due_at,
      'live_runtime_job'::text as reason
    from public.live_runtime_jobs j
    where j.status in ('pending','retry_wait')
      and j.attempt_count < j.max_attempts
      and j.scheduled_at > p_now

    union all

    select
      min(r.expires_at),
      'recovery_expiry'
    from public.prediction_recovery_authorizations r
    where r.status = 'open'
      and r.expires_at is not null
      and r.expires_at > p_now

    union all

    select
      min(c.next_refresh_at),
      'community_refresh'
    from public.community_snapshot_registry c
    where c.next_refresh_at is not null
      and c.next_refresh_at > p_now

    union all

    select
      min(i.available_at),
      'loyalty_inbox'
    from public.loyalty_reward_runtime_inbox i
    where i.processed_at is null
      and i.dead_lettered_at is null
      and i.available_at > p_now

    union all

    select
      min(o.available_at),
      'loyalty_outbox'
    from public.workflow_loyalty_dispatch_outbox o
    where o.dispatched_at is null
      and o.dead_lettered_at is null
      and o.available_at > p_now

    union all

    select v.opens_at, 'round_open'
    from public.current_fantagol_round_view v
    where v.opens_at is not null
      and v.opens_at > p_now

    union all

    select v.lock_at, 'round_lock'
    from public.current_fantagol_round_view v
    where v.lock_at is not null
      and v.lock_at > p_now

    union all

    select v.starts_at, 'round_start'
    from public.current_fantagol_round_view v
    where v.starts_at is not null
      and v.starts_at > p_now

    union all

    select v.ends_at, 'round_end'
    from public.current_fantagol_round_view v
    where v.ends_at is not null
      and v.ends_at > p_now

    union all

    -- Generic fail-safe only. This is deliberately NOT a provider cadence.
    select p_now + interval '15 minutes', 'safety_fallback'
  )
  select c.due_at, c.reason
  from candidates c
  where c.due_at is not null
  order by c.due_at asc, c.reason asc
  limit 1;
$function$;

revoke all on function public.resolve_production_heartbeat_next_wakeup_internal(timestamptz)
from public, anon, authenticated, service_role;

grant execute on function public.resolve_production_heartbeat_next_wakeup_internal(timestamptz)
to postgres;

create or replace function public.claim_production_heartbeat_wakeup_rpc(
  p_worker_id text,
  p_lease_seconds integer default 180
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, extensions
as $function$
declare
  v_now timestamptz := clock_timestamp();
  v_state public.live_runtime_heartbeat_state%rowtype;
  v_token uuid;
  v_reason text;
  v_due_runtime_job boolean;
  v_due_recovery boolean;
  v_due_community boolean;
  v_due_loyalty boolean;
begin
  if nullif(btrim(p_worker_id),'') is null then
    raise exception 'PRODUCTION_HEARTBEAT_WORKER_ID_REQUIRED';
  end if;

  if p_lease_seconds < 30 or p_lease_seconds > 900 then
    raise exception 'PRODUCTION_HEARTBEAT_LEASE_SECONDS_OUT_OF_RANGE';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('production-heartbeat-wakeup-authority', 0)
  );

  select *
  into v_state
  from public.live_runtime_heartbeat_state
  where state_key='production-heartbeat'
  for update;

  if not found then
    raise exception 'PRODUCTION_HEARTBEAT_STATE_MISSING';
  end if;

  if v_state.lease_expires_at is not null
     and v_state.lease_expires_at > v_now then
    return jsonb_build_object(
      'claimed', false,
      'reason', 'lease_active',
      'lease_token', v_state.lease_token,
      'lease_expires_at', v_state.lease_expires_at,
      'next_wakeup_at', v_state.next_wakeup_at
    );
  end if;

  select exists (
    select 1
    from public.live_runtime_jobs j
    where j.status in ('pending','retry_wait')
      and j.attempt_count < j.max_attempts
      and j.scheduled_at <= v_now
  ) into v_due_runtime_job;

  select exists (
    select 1
    from public.prediction_recovery_authorizations r
    where r.status='open'
      and r.expires_at is not null
      and r.expires_at <= v_now
  ) into v_due_recovery;

  select exists (
    select 1
    from public.community_snapshot_registry c
    where c.next_refresh_at is not null
      and c.next_refresh_at <= v_now
  ) into v_due_community;

  select (
    exists (
      select 1
      from public.loyalty_reward_runtime_inbox i
      where i.processed_at is null
        and i.dead_lettered_at is null
        and i.available_at <= v_now
    )
    or
    exists (
      select 1
      from public.workflow_loyalty_dispatch_outbox o
      where o.dispatched_at is null
        and o.dead_lettered_at is null
        and o.available_at <= v_now
    )
  ) into v_due_loyalty;

  v_reason := case
    when v_due_runtime_job then 'due_runtime_job'
    when v_due_recovery then 'due_recovery'
    when v_due_community then 'due_community'
    when v_due_loyalty then 'due_loyalty'
    when v_state.next_wakeup_at <= v_now then 'next_wakeup_at'
    else null
  end;

  if v_reason is null then
    return jsonb_build_object(
      'claimed', false,
      'reason', 'not_due',
      'next_wakeup_at', v_state.next_wakeup_at
    );
  end if;

  v_token := extensions.gen_random_uuid();

  update public.live_runtime_heartbeat_state
  set
    lease_token = v_token,
    lease_owner = btrim(p_worker_id),
    lease_acquired_at = v_now,
    lease_expires_at = v_now + make_interval(secs => p_lease_seconds),
    last_dispatched_at = v_now,
    last_reason = v_reason,
    version = version + 1,
    updated_at = v_now
  where state_key='production-heartbeat';

  return jsonb_build_object(
    'claimed', true,
    'reason', v_reason,
    'lease_token', v_token,
    'lease_expires_at', v_now + make_interval(secs => p_lease_seconds),
    'next_wakeup_at', v_state.next_wakeup_at
  );
end;
$function$;

revoke all on function public.claim_production_heartbeat_wakeup_rpc(text,integer)
from public, anon, authenticated, service_role;

grant execute on function public.claim_production_heartbeat_wakeup_rpc(text,integer)
to postgres;

create or replace function public.finalize_production_heartbeat_wakeup_rpc(
  p_lease_token uuid,
  p_success boolean,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $function$
declare
  v_now timestamptz := clock_timestamp();
  v_state public.live_runtime_heartbeat_state%rowtype;
  v_next timestamptz;
  v_next_reason text;
begin
  if p_lease_token is null then
    raise exception 'PRODUCTION_HEARTBEAT_LEASE_TOKEN_REQUIRED';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('production-heartbeat-wakeup-authority', 0)
  );

  select *
  into v_state
  from public.live_runtime_heartbeat_state
  where state_key='production-heartbeat'
  for update;

  if not found then
    raise exception 'PRODUCTION_HEARTBEAT_STATE_MISSING';
  end if;

  if v_state.lease_token is distinct from p_lease_token then
    raise exception 'PRODUCTION_HEARTBEAT_LEASE_TOKEN_MISMATCH';
  end if;

  if p_success then
    select r.next_wakeup_at, r.wakeup_reason
    into v_next, v_next_reason
    from public.resolve_production_heartbeat_next_wakeup_internal(v_now) r;

    if v_next is null then
      v_next := v_now + interval '15 minutes';
      v_next_reason := 'safety_fallback';
    end if;
  else
    v_next := v_now + interval '1 minute';
    v_next_reason := 'failure_retry';
  end if;

  update public.live_runtime_heartbeat_state
  set
    next_wakeup_at = v_next,
    lease_token = null,
    lease_owner = null,
    lease_acquired_at = null,
    lease_expires_at = null,
    last_completed_at = case when p_success then v_now else last_completed_at end,
    last_failure_at = case when not p_success then v_now else last_failure_at end,
    last_reason = coalesce(nullif(btrim(p_reason),''), v_next_reason),
    version = version + 1,
    updated_at = v_now
  where state_key='production-heartbeat';

  return jsonb_build_object(
    'finalized', true,
    'success', p_success,
    'next_wakeup_at', v_next,
    'next_wakeup_reason', v_next_reason
  );
end;
$function$;

revoke all on function public.finalize_production_heartbeat_wakeup_rpc(uuid,boolean,text)
from public, anon, authenticated;

grant execute on function public.finalize_production_heartbeat_wakeup_rpc(uuid,boolean,text)
to service_role, postgres;

comment on function public.claim_production_heartbeat_wakeup_rpc(text,integer) is
  'Postgres-only production heartbeat wake-up claim/lease authority. Does not invoke HTTP.';

comment on function public.finalize_production_heartbeat_wakeup_rpc(uuid,boolean,text) is
  'Finalizes a claimed production heartbeat, clears its lease and derives the next wake-up from already-materialized DB signals.';

comment on function public.resolve_production_heartbeat_next_wakeup_internal(timestamptz) is
  'Internal wake-up resolver over materialized runtime signals and round boundaries. Contains no provider cadence policy.';
