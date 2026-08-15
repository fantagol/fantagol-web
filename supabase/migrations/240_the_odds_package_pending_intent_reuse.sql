-- FantaGol R39-E6-G2-D1-B
--
-- The Odds API PACKAGE semantic pending-intent reuse.
--
-- The canonical enqueue_live_runtime_job_rpc remains untouched.
-- This specialized boundary prevents heartbeat-time drift from
-- creating multiple equivalent pending PACKAGE poll_batch jobs.

create or replace function public.enqueue_the_odds_package_pending_intent_rpc(
    p_fantagol_round_id uuid,
    p_mode text,
    p_market_operating_mode text,
    p_market_policy_reason text,
    p_idempotency_key text,
    p_priority integer,
    p_scheduled_at timestamptz,
    p_payload jsonb,
    p_max_attempts integer default 5,
    p_correlation_id uuid default null,
    p_causation_id uuid default null
)
returns table (
    job_id uuid,
    job_status text,
    inserted boolean,
    scheduled_at timestamptz,
    attempt_count integer,
    correlation_id uuid
)
language plpgsql
security definer
set search_path = public
as $$
declare
    v_lock_key bigint;
begin
    if p_mode <> 'prematch' then
        raise exception
            'THE_ODDS_PACKAGE_PENDING_INTENT_INVALID_MODE:%',
            p_mode;
    end if;

    if nullif(btrim(p_market_operating_mode), '') is null then
        raise exception
            'THE_ODDS_PACKAGE_PENDING_INTENT_OPERATING_MODE_REQUIRED';
    end if;

    if nullif(btrim(p_market_policy_reason), '') is null then
        raise exception
            'THE_ODDS_PACKAGE_PENDING_INTENT_POLICY_REASON_REQUIRED';
    end if;

    /*
     * Serialize this semantic PACKAGE intent only:
     *
     * round
     * + provider=the_odds_api
     * + mode=prematch
     * + snapshot_source=PACKAGE
     * + operating mode
     * + policy reason
     */
    v_lock_key :=
        hashtextextended(
            concat_ws(
                '|',
                'the_odds_api',
                p_fantagol_round_id::text,
                p_mode,
                'PACKAGE',
                p_market_operating_mode,
                p_market_policy_reason
            ),
            0
        );

    perform pg_advisory_xact_lock(v_lock_key);

    /*
     * Preserve the earliest pristine compatible pending PACKAGE.
     * Repeated heartbeats must neither create another job nor move
     * the existing intent forward in time.
     */
    return query
    select
        j.id,
        j.status,
        false,
        j.scheduled_at,
        j.attempt_count,
        j.correlation_id
    from public.live_runtime_jobs j
    where
        j.job_type = 'poll_batch'
        and j.scope_type = 'fantagol_round'
        and j.scope_id = p_fantagol_round_id
        and j.status = 'pending'
        and j.claimed_at is null
        and j.claimed_by is null
        and j.attempt_count = 0
        and j.completed_at is null
        and j.failed_at is null
        and j.cancelled_at is null
        and j.payload ->> 'provider_code' = 'the_odds_api'
        and j.payload ->> 'mode' = p_mode
        and j.payload ->> 'market_snapshot_source' = 'PACKAGE'
        and j.payload ->> 'market_operating_mode' =
            p_market_operating_mode
        and j.payload ->> 'market_policy_reason' =
            p_market_policy_reason
    order by
        j.scheduled_at asc,
        j.created_at asc,
        j.id asc
    limit 1;

    if found then
        return;
    end if;

    /*
     * No compatible pristine pending PACKAGE exists.
     * Delegate insertion and exact-key idempotency to the
     * already-certified canonical queue boundary.
     */
    return query
    select
        e.job_id,
        e.job_status,
        e.inserted,
        e.scheduled_at,
        e.attempt_count,
        e.correlation_id
    from public.enqueue_live_runtime_job_rpc(
        p_job_type =>
            'poll_batch',
        p_scope_type =>
            'fantagol_round',
        p_scope_id =>
            p_fantagol_round_id,
        p_idempotency_key =>
            p_idempotency_key,
        p_priority =>
            p_priority,
        p_scheduled_at =>
            p_scheduled_at,
        p_payload =>
            coalesce(p_payload, '{}'::jsonb),
        p_max_attempts =>
            p_max_attempts,
        p_correlation_id =>
            p_correlation_id,
        p_causation_id =>
            p_causation_id
    ) e;
end;
$$;

revoke all
on function public.enqueue_the_odds_package_pending_intent_rpc(
    uuid,
    text,
    text,
    text,
    text,
    integer,
    timestamptz,
    jsonb,
    integer,
    uuid,
    uuid
)
from public;

grant execute
on function public.enqueue_the_odds_package_pending_intent_rpc(
    uuid,
    text,
    text,
    text,
    text,
    integer,
    timestamptz,
    jsonb,
    integer,
    uuid,
    uuid
)
to service_role;