begin;

-- ============================================================================
-- FANTAGOL - MIGRATION 256
-- FINAL CALCULABLE TRANSITION AUTHORITY
--
-- Canonical lifecycle edge:
--
--   live
--     |
--     | all required official Match Set members are
--     | result-terminal and finalised
--     v
--   final_calculable
--
-- Properties:
-- - service-role only
-- - transaction/advisory-lock protected
-- - idempotent
-- - fail closed
-- - no scoring
-- - no certification
-- - no job enqueue
-- - no publication
-- ============================================================================

create or replace function public.advance_round_final_calculable_internal(
    p_fantagol_round_id uuid
)
returns table (
    fantagol_round_id uuid,
    round_advanced boolean,
    league_rounds_advanced integer,
    league_rounds_already_final_or_later integer,
    required_match_count integer,
    result_terminal_match_count integer,
    blocking_match_count integer,
    last_finalised_at timestamptz
)
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
    v_round public.fantagol_rounds%rowtype;

    v_required_match_count integer := 0;
    v_result_terminal_match_count integer := 0;
    v_blocking_match_count integer := 0;

    v_last_finalised_at timestamptz := null;

    v_round_advanced boolean := false;
    v_league_rounds_advanced integer := 0;
    v_league_rounds_already_final_or_later integer := 0;
    v_remaining_live_league_rounds integer := 0;
begin
    if p_fantagol_round_id is null then
        raise exception using
            errcode = 'P0001',
            message = 'FANTAGOL_ROUND_ID_REQUIRED';
    end if;

    perform pg_advisory_xact_lock(
        hashtextextended(
            'round-final-calculable:' ||
            p_fantagol_round_id::text,
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

    select
        count(*)::integer,
        count(*) filter (
            where
                m.status in ('finished', 'awarded')
                and m.finalised_at is not null
        )::integer,
        count(*) filter (
            where not (
                m.status in ('finished', 'awarded')
                and m.finalised_at is not null
            )
        )::integer,
        max(m.finalised_at)
    into
        v_required_match_count,
        v_result_terminal_match_count,
        v_blocking_match_count,
        v_last_finalised_at
    from public.fantagol_round_matches frm
    join public.matches m
      on m.id = frm.match_id
    where frm.fantagol_round_id = p_fantagol_round_id
      and frm.required = true
      and frm.removed_at is null;

    if v_required_match_count = 0 then
        raise exception using
            errcode = 'P0001',
            message = 'ROUND_REQUIRED_MATCH_SET_EMPTY';
    end if;

    /*
     * Idempotent success path.
     *
     * Once the global round has advanced beyond LIVE this authority
     * never moves it backward.
     */
    if v_round.status in (
        'final_calculable',
        'final_official',
        'recalculated'
    ) then

        select count(*)::integer
        into v_league_rounds_already_final_or_later
        from public.league_rounds lr
        where lr.fantagol_round_id = p_fantagol_round_id
          and lr.enabled = true
          and lr.status in (
              'final_calculable',
              'scoring',
              'official',
              'recalculated',
              'archived'
          );

        return query
        select
            p_fantagol_round_id,
            false,
            0,
            v_league_rounds_already_final_or_later,
            v_required_match_count,
            v_result_terminal_match_count,
            v_blocking_match_count,
            v_last_finalised_at;

        return;
    end if;

    /*
     * Fail closed for any lifecycle state other than LIVE.
     *
     * In particular:
     * predictions_locked cannot jump directly to final_calculable.
     */
    if v_round.status <> 'live' then
        return query
        select
            p_fantagol_round_id,
            false,
            0,
            0,
            v_required_match_count,
            v_result_terminal_match_count,
            v_blocking_match_count,
            v_last_finalised_at;

        return;
    end if;

    /*
     * Terminality authority.
     *
     * Postponed/cancelled/non-finalised matches deliberately block this
     * edge. Their governance must resolve them before official scoring.
     */
    if
        v_blocking_match_count > 0
        or
        v_result_terminal_match_count
            <> v_required_match_count
    then
        return query
        select
            p_fantagol_round_id,
            false,
            0,
            0,
            v_required_match_count,
            v_result_terminal_match_count,
            v_blocking_match_count,
            v_last_finalised_at;

        return;
    end if;

    update public.fantagol_rounds fr
    set status = 'final_calculable'
    where fr.id = p_fantagol_round_id
      and fr.status = 'live';

    v_round_advanced :=
        found;

    update public.league_rounds lr
    set status = 'final_calculable'
    where lr.fantagol_round_id = p_fantagol_round_id
      and lr.enabled = true
      and lr.status = 'live';

    get diagnostics
        v_league_rounds_advanced =
            row_count;

    select count(*)::integer
    into v_league_rounds_already_final_or_later
    from public.league_rounds lr
    where lr.fantagol_round_id = p_fantagol_round_id
      and lr.enabled = true
      and lr.status in (
          'final_calculable',
          'scoring',
          'official',
          'recalculated',
          'archived'
      );

    select count(*)::integer
    into v_remaining_live_league_rounds
    from public.league_rounds lr
    where lr.fantagol_round_id = p_fantagol_round_id
      and lr.enabled = true
      and lr.status = 'live';

    if v_remaining_live_league_rounds <> 0 then
        raise exception using
            errcode = 'P0001',
            message = 'FINAL_CALCULABLE_TRANSITION_INCOMPLETE',
            detail = jsonb_build_object(
                'fantagol_round_id',
                    p_fantagol_round_id,
                'remaining_live_league_rounds',
                    v_remaining_live_league_rounds,
                'required_match_count',
                    v_required_match_count,
                'result_terminal_match_count',
                    v_result_terminal_match_count
            )::text;
    end if;

    return query
    select
        p_fantagol_round_id,
        v_round_advanced,
        v_league_rounds_advanced,
        v_league_rounds_already_final_or_later,
        v_required_match_count,
        v_result_terminal_match_count,
        v_blocking_match_count,
        v_last_finalised_at;
end;
$function$;


revoke all
on function public.advance_round_final_calculable_internal(uuid)
from public;

revoke all
on function public.advance_round_final_calculable_internal(uuid)
from anon;

revoke all
on function public.advance_round_final_calculable_internal(uuid)
from authenticated;

grant execute
on function public.advance_round_final_calculable_internal(uuid)
to service_role;


comment on function
public.advance_round_final_calculable_internal(uuid)
is
'Canonical service-role lifecycle authority for live -> final_calculable. Advances only when every required active official Match Set member is finished/awarded and finalised. Idempotent and fail-closed; performs no scoring, certification, enqueue, claim or publication.';


commit;