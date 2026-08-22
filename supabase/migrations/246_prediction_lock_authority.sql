-- =====================================================================
-- FANTAGOL
-- Migration 246
-- Canonical prediction-lock advancement authority
--
-- Purpose:
--   Advance one FantaGol Round from predictions_open to
--   predictions_locked after lock_at.
--
-- Rules:
--   - service-only internal authority
--   - idempotent
--   - advisory-lock protected
--   - delegates League Round prediction semantics to the already
--     certified lock_round_predictions_rpc(uuid)
--   - no client-side lock semantics
-- =====================================================================

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

    -- Already beyond the prediction-open phase: idempotent no-op.
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

    -- Do not invent an opening transition here.
    if v_round.status <> 'predictions_open' then
        return query
        select
            p_fantagol_round_id,
            false,
            0,
            0;

        return;
    end if;

    -- Fail closed before canonical lock time.
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
     * Delegate every enabled League Round to the certified lock command.
     * This preserves:
     * - official snapshot restoration
     * - first-complete auto submission
     * - incomplete draft voiding
     * - prediction_versions lineage
     * - League Round transition semantics
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

            v_locked := v_locked + 1;
        else
            v_closed := v_closed + 1;
        end if;
    end loop;

    -- Postcondition: no enabled League Round may remain open.
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

revoke all
on function public.advance_prediction_lock_internal(uuid)
from public;

revoke all
on function public.advance_prediction_lock_internal(uuid)
from anon;

revoke all
on function public.advance_prediction_lock_internal(uuid)
from authenticated;

grant execute
on function public.advance_prediction_lock_internal(uuid)
to service_role;

comment on function public.advance_prediction_lock_internal(uuid) is
'Canonical service-only prediction lock advancement authority. After lock_at, atomically delegates every enabled League Round to lock_round_predictions_rpc and advances the FantaGol Round to predictions_locked. Idempotent and advisory-lock protected.';