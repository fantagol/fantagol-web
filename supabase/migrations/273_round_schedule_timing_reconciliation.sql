-- ============================================================
-- FANTAGOL - MIGRATION 273
-- ROUND SCHEDULE TIMING RECONCILIATION
--
-- Structural authority:
-- whenever canonical Match kickoff scheduling changes before
-- prediction lock, derive FantaGol Round timing from the complete
-- required active Match Set.
--
-- starts_at = earliest required active Match kickoff
-- lock_at   = earliest required active Match kickoff
-- ends_at   = latest required active Match kickoff
--
-- No historical/live lock rewrite.
-- ============================================================

create or replace function public.reconcile_fantagol_round_timing_internal(
    p_fantagol_round_id uuid
)
returns table (
    applied boolean,
    reason text,
    fantagol_round_id uuid,
    round_status text,
    previous_lock_at timestamptz,
    current_lock_at timestamptz,
    previous_starts_at timestamptz,
    current_starts_at timestamptz,
    previous_ends_at timestamptz,
    current_ends_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
declare
    v_round public.fantagol_rounds%rowtype;
    v_first_kickoff timestamptz;
    v_last_kickoff timestamptz;
    v_previous_lock_at timestamptz;
    v_previous_starts_at timestamptz;
    v_previous_ends_at timestamptz;
begin
    if p_fantagol_round_id is null then
        raise exception
            'ROUND_TIMING_ROUND_ID_REQUIRED';
    end if;

    perform pg_advisory_xact_lock(
        hashtextextended(
            'fantagol_round_timing:' ||
            p_fantagol_round_id::text,
            0
        )
    );

    select fr.*
    into v_round
    from public.fantagol_rounds fr
    where fr.id = p_fantagol_round_id
      and fr.active = true
    for update;

    if not found then
        raise exception
            'ROUND_TIMING_ROUND_NOT_FOUND:%',
            p_fantagol_round_id;
    end if;

    v_previous_lock_at := v_round.lock_at;
    v_previous_starts_at := v_round.starts_at;
    v_previous_ends_at := v_round.ends_at;

    /*
     * Prediction lock is immutable after the round leaves its
     * editable pre-live lifecycle.
     */
    if v_round.status not in (
        'scheduled',
        'predictions_open'
    ) then
        return query
        select
            false,
            'round_status_not_reconcilable'::text,
            v_round.id,
            v_round.status,
            v_previous_lock_at,
            v_round.lock_at,
            v_previous_starts_at,
            v_round.starts_at,
            v_previous_ends_at,
            v_round.ends_at;

        return;
    end if;

    select
        min(m.kickoff),
        max(m.kickoff)
    into
        v_first_kickoff,
        v_last_kickoff
    from public.fantagol_round_matches frm
    join public.matches m
      on m.id = frm.match_id
    where frm.fantagol_round_id =
            p_fantagol_round_id
      and frm.required = true
      and frm.removed_at is null
      and m.active = true;

    if v_first_kickoff is null
       or v_last_kickoff is null then
        raise exception
            'ROUND_TIMING_REQUIRED_MATCH_SET_EMPTY:%',
            p_fantagol_round_id;
    end if;

    if v_round.opens_at >= v_first_kickoff then
        raise exception
            'ROUND_TIMING_OPENING_NOT_BEFORE_FIRST_KICKOFF:%:%:%',
            p_fantagol_round_id,
            v_round.opens_at,
            v_first_kickoff;
    end if;

    if
        v_round.lock_at is not distinct from
            v_first_kickoff
        and
        v_round.starts_at is not distinct from
            v_first_kickoff
        and
        v_round.ends_at is not distinct from
            v_last_kickoff
    then
        return query
        select
            false,
            'already_aligned'::text,
            v_round.id,
            v_round.status,
            v_previous_lock_at,
            v_round.lock_at,
            v_previous_starts_at,
            v_round.starts_at,
            v_previous_ends_at,
            v_round.ends_at;

        return;
    end if;

    update public.fantagol_rounds
    set
        lock_at = v_first_kickoff,
        starts_at = v_first_kickoff,
        ends_at = v_last_kickoff,
        updated_at = now(),
        version = version + 1
    where id = p_fantagol_round_id;

    return query
    select
        true,
        'round_timing_reconciled'::text,
        v_round.id,
        v_round.status,
        v_previous_lock_at,
        v_first_kickoff,
        v_previous_starts_at,
        v_first_kickoff,
        v_previous_ends_at,
        v_last_kickoff;
end;
$$;

revoke all
on function public.reconcile_fantagol_round_timing_internal(uuid)
from public;

comment on function
public.reconcile_fantagol_round_timing_internal(uuid)
is
'Canonical pre-live FantaGol Round timing reconciliation from the complete required active Match Set. Idempotent and fail-closed outside scheduled/predictions_open.';
