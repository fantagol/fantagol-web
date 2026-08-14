-- FantaGol R39-E6-F2-R5-R3
--
-- Football Data semantic pending-intent reuse.
--
-- The canonical enqueue_live_runtime_job_rpc remains untouched.
-- This specialized boundary prevents minute-by-minute heartbeat drift
-- from creating multiple equivalent future Football Data poll_batch jobs.

create or replace function public.enqueue_football_data_pending_intent_rpc(
    p_fantagol_round_id uuid,
    p_mode text,
    p_polling_band text,
    p_polling_reason text,
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
    if p_mode not in ('live', 'prematch') then
        raise exception
            'FOOTBALL_DATA_PENDING_INTENT_INVALID_MODE:%',
            p_mode;
    end if;

    if nullif(btrim(p_polling_band), '') is null then
        raise exception
            'FOOTBALL_DATA_PENDING_INTENT_POLLING_BAND_REQUIRED';
    end if;

    if nullif(btrim(p_polling_reason), '') is null then
        raise exception
            'FOOTBALL_DATA_PENDING_INTENT_POLLING_REASON_REQUIRED';
    end if;

    /*
     * Serialize only this semantic intent:
     *
     * round + provider + mode + polling band + polling reason
     *
     * Different rounds/modes/policies remain independent.
     */
    v_lock_key :=
        hashtextextended(
            concat_ws(
                '|',
                'football_data',
                p_fantagol_round_id::text,
                p_mode,
                p_polling_band,
                p_polling_reason
            ),
            0
        );

    perform pg_advisory_xact_lock(v_lock_key);

    /*
     * Preserve the earliest pristine pending job.
     * A heartbeat must not continually push the intended poll forward.
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
        and j.payload ->> 'provider_code' = 'football_data'
        and j.payload ->> 'mode' = p_mode
        and j.payload ->> 'polling_band' = p_polling_band
        and j.payload ->> 'polling_reason' = p_polling_reason
    order by
        j.scheduled_at asc,
        j.created_at asc,
        j.id asc
    limit 1;

    if found then
        return;
    end if;

    /*
     * No compatible pending intent exists.
     * Delegate the actual insertion/idempotency semantics to the
     * already-certified canonical queue RPC.
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
on function public.enqueue_football_data_pending_intent_rpc(
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
on function public.enqueue_football_data_pending_intent_rpc(
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