-- FANTAGOL MIGRATION 350 - FUTURE ROUND OPEN WAKEUP AUTHORITY
-- Supersedes only the round_open candidate in the M342 resolver.
-- M342/M343 stay immutable; cron and lease authority unchanged.
-- Promote/apply only after separate certification and explicit approval.
DO $m350_preflight$
BEGIN
  IF to_regprocedure('public.resolve_production_heartbeat_next_wakeup_internal(timestamptz)') IS NULL THEN
    RAISE EXCEPTION 'M350_RESOLVER_MISSING';
  END IF;
  IF position(
    'from public.current_fantagol_round_view v'
    IN pg_get_functiondef('public.resolve_production_heartbeat_next_wakeup_internal(timestamptz)'::regprocedure)
  ) = 0 THEN
    RAISE EXCEPTION 'M350_EXPECTED_PREVIOUS_RESOLVER_NOT_FOUND';
  END IF;
END;
$m350_preflight$;

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

    select r.opens_at, 'round_open'
    from public.fantagol_rounds r
    where r.active = true
      and r.status in ('scheduled', 'predictions_open')
      and r.opens_at is not null
      and r.opens_at > p_now

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
DO $m350_postcondition$
BEGIN
  IF position(
    'from public.fantagol_rounds r'
    IN pg_get_functiondef('public.resolve_production_heartbeat_next_wakeup_internal(timestamptz)'::regprocedure)
  ) = 0 THEN
    RAISE EXCEPTION 'M350_FUTURE_ROUND_OPEN_MISSING';
  END IF;
END;
$m350_postcondition$;
