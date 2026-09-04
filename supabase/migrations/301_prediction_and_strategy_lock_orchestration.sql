-- ============================================================================
-- FANTAGOL MIGRATION 301
-- Prediction + Strategy Lock Orchestration
--
-- Purpose:
--   Keep advance_prediction_lock_internal(uuid) as the sole heartbeat boundary,
--   while making strategy locking part of the same atomic lock transition.
--
-- Certified sequence for each enabled League Round still predictions_open:
--   1. lock_round_predictions_rpc(uuid)
--   2. lock_round_strategies_rpc(uuid)
--
-- Strategy default materialization remains owned by lock_round_strategies_rpc.
-- No new job type, no separate heartbeat call, no pre-lock materialization.
-- ============================================================================

create or replace function public.advance_prediction_lock_internal(
    p_fantagol_round_id uuid
)
returns table(
    fantagol_round_id uuid,
    round_locked boolean,
    league_rounds_locked integer,
    league_rounds_already_closed integer
)
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
    v_round public.fantagol_rounds%rowtype;
    v_league_round record;

    v_locked integer := 0;
    v_closed integer := 0;
begin
    if p_fantagol_round_id is null then
        raise exception using
            errcode = 'P0001',
            message = 'FANTAGOL_ROUND_REQUIRED';
    end if;

    perform pg_advisory_xact_lock(
        hashtextextended(
            'prediction-lock:' || p_fantagol_round_id::text,
            0
        )
    );

    select fr.*
    into v_round
    from public.fantagol_rounds fr
    where fr.id = p_fantagol_round_id
    for update;

    if not found then
        raise exception using
            errcode = 'P0001',
            message = 'FANTAGOL_ROUND_NOT_FOUND';
    end if;

    if v_round.status in (
        'predictions_locked',
        'live',
        'partial_finished',
        'waiting_postponed',
        'final_calculable',
        'final_official',
        'recalculated',
        'cancelled'
    ) then
        select count(*)::integer
        into v_closed
        from public.league_rounds lr
        where lr.fantagol_round_id = p_fantagol_round_id
          and lr.enabled
          and lr.status <> 'predictions_open';

        return query
        select
            p_fantagol_round_id,
            false,
            0,
            v_closed;

        return;
    end if;

    if v_round.status <> 'predictions_open' then
        return query
        select
            p_fantagol_round_id,
            false,
            0,
            0;

        return;
    end if;

    if clock_timestamp() < v_round.lock_at then
        return query
        select
            p_fantagol_round_id,
            false,
            0,
            0;

        return;
    end if;

    /*
     * Atomic League Round lock sequence.
     *
     * Prediction lock stabilizes official prediction state first.
     * Strategy lock then materializes eligible defaults and locks strategies
     * against that stabilized official prediction state.
     *
     * Both commands execute inside this same transaction. Any failure in the
     * strategy lock aborts the global advancement and prevents a partial
     * prediction-only transition.
     */
    for v_league_round in
        select
            lr.id,
            lr.status
        from public.league_rounds lr
        where lr.fantagol_round_id = p_fantagol_round_id
          and lr.enabled
        order by lr.id
        for update
    loop
        if v_league_round.status = 'predictions_open' then
            perform *
            from public.lock_round_predictions_rpc(
                v_league_round.id
            );

            perform *
            from public.lock_round_strategies_rpc(
                v_league_round.id
            );

            v_locked := v_locked + 1;
        else
            v_closed := v_closed + 1;
        end if;
    end loop;

    if exists (
        select 1
        from public.league_rounds lr
        where lr.fantagol_round_id = p_fantagol_round_id
          and lr.enabled
          and lr.status = 'predictions_open'
    ) then
        raise exception using
            errcode = 'P0001',
            message = 'PREDICTION_LOCK_INCOMPLETE';
    end if;

    update public.fantagol_rounds fr
    set
        status = 'predictions_locked',
        updated_at = clock_timestamp()
    where fr.id = p_fantagol_round_id
      and fr.status = 'predictions_open';

    if not found then
        raise exception using
            errcode = 'P0001',
            message = 'FANTAGOL_ROUND_LOCK_TRANSITION_FAILED';
    end if;

    return query
    select
        p_fantagol_round_id,
        true,
        v_locked,
        v_closed;
end;
$function$;

comment on function public.advance_prediction_lock_internal(uuid) is
'Canonical service-only prediction + strategy lock advancement authority. After lock_at, atomically locks predictions first and strategies second for every enabled League Round, then advances the FantaGol Round to predictions_locked. Idempotent and advisory-lock protected.';