-- ============================================================================
-- FANTAGOL
-- MIGRATION 249
-- CANONICAL LIVE TRANSITION AUTHORITY
--
-- R40-R11A
--
-- Purpose:
--
-- Materialize the missing canonical lifecycle edge:
--
--     predictions_locked -> live
--
-- for the FantaGol Round and every enabled League Round once real provider
-- state proves that at least one required official match is actually live.
--
-- first_official_score_at is independent from live entry:
--
-- - a 0-0 match may be legitimately live;
-- - therefore live status MUST NOT require a goal;
-- - first_official_score_at is materialized only from an accepted,
--   meaningful MATCH_SCORE_CHANGED receipt belonging to the official
--   Match Set and occurring no earlier than round.starts_at.
--
-- Safety:
--
-- - service-role only
-- - advisory transaction lock
-- - idempotent
-- - fail closed without provider live evidence
-- - never regresses later lifecycle states
-- - never mutates predictions
-- - never enqueues jobs
-- ============================================================================

begin;


-- ============================================================================
-- 1. LIVE TRANSITION AUTHORITY
-- ============================================================================

create or replace function public.advance_round_live_internal(
    p_fantagol_round_id uuid
)
returns table (
    fantagol_round_id uuid,
    round_advanced boolean,
    league_rounds_advanced integer,
    league_rounds_already_live_or_later integer,
    first_official_score_at timestamptz,
    live_evidence_match_id uuid
)
language plpgsql
security definer
set search_path to public, pg_temp
as $function$
declare
    v_round public.fantagol_rounds%rowtype;

    v_live_match_id uuid;
    v_first_score_at timestamptz;

    v_advanced integer := 0;
    v_already integer := 0;

    v_round_advanced boolean := false;
    v_now timestamptz := clock_timestamp();
begin

    if p_fantagol_round_id is null then
        raise exception using
            errcode = 'P0001',
            message = 'FANTAGOL_ROUND_REQUIRED';
    end if;


    -- One lifecycle transition authority per global round.
    perform pg_advisory_xact_lock(
        hashtextextended(
            'round-live-transition:' ||
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


    /*
     * Terminal / later lifecycle states are idempotent no-ops.
     *
     * Do not regress:
     * live -> predictions_locked
     * partial_finished -> live
     * final_* -> live
     */
    if v_round.status in (
        'live',
        'partial_finished',
        'waiting_postponed',
        'final_calculable',
        'final_official',
        'recalculated',
        'cancelled'
    ) then

        select count(*)::integer
        into v_already
        from public.league_rounds lr
        where lr.fantagol_round_id =
              p_fantagol_round_id
          and lr.enabled
          and lr.status in (
              'live',
              'waiting_postponed',
              'final_calculable',
              'scoring',
              'official',
              'recalculated',
              'archived',
              'cancelled'
          );

        select min(r.provider_updated_at)
        into v_first_score_at
        from public.live_match_update_receipts r
        join public.fantagol_round_matches frm
          on frm.match_id = r.match_id
         and frm.fantagol_round_id =
             p_fantagol_round_id
         and frm.removed_at is null
         and frm.required
        where r.processing_status = 'accepted'
          and r.meaningful_change = true
          and r.change_type = 'MATCH_SCORE_CHANGED'
          and r.provider_updated_at >=
              v_round.starts_at;

        return query
        select
            p_fantagol_round_id,
            false,
            0,
            v_already,
            v_first_score_at,
            null::uuid;

        return;
    end if;


    /*
     * The only legal entry edge implemented here is:
     *
     * predictions_locked -> live
     *
     * Opening / locking remain owned by their certified authorities.
     */
    if v_round.status <> 'predictions_locked' then
        return query
        select
            p_fantagol_round_id,
            false,
            0,
            0,
            null::timestamptz,
            null::uuid;

        return;
    end if;


    /*
     * Fail closed before the canonical round start.
     *
     * This is only a temporal guard.
     * starts_at alone NEVER proves live state.
     */
    if v_now < v_round.starts_at then
        return query
        select
            p_fantagol_round_id,
            false,
            0,
            0,
            null::timestamptz,
            null::uuid;

        return;
    end if;


    /*
     * Canonical live evidence.
     *
     * We require one active + required official Match Set member whose
     * persisted provider state is explicitly live.
     *
     * Scheduled + kickoff-in-the-past is NOT sufficient.
     */
    select m.id
    into v_live_match_id
    from public.fantagol_round_matches frm
    join public.matches m
      on m.id = frm.match_id
    where frm.fantagol_round_id =
          p_fantagol_round_id
      and frm.removed_at is null
      and frm.required
      and (
           m.status like 'live_%'
        or m.status in (
            'live',
            'in_progress',
            'halftime',
            'extra_time',
            'penalties'
        )
      )
    order by
        m.provider_updated_at asc nulls last,
        m.kickoff asc,
        m.id
    limit 1;

    if v_live_match_id is null then
        return query
        select
            p_fantagol_round_id,
            false,
            0,
            0,
            null::timestamptz,
            null::uuid;

        return;
    end if;


    /*
     * Score authority is intentionally independent from live-state authority.
     *
     * Only accepted provider score-change receipts after round start qualify.
     * Historical/synthetic pre-round receipts are excluded.
     */
    select min(r.provider_updated_at)
    into v_first_score_at
    from public.live_match_update_receipts r
    join public.fantagol_round_matches frm
      on frm.match_id = r.match_id
     and frm.fantagol_round_id =
         p_fantagol_round_id
     and frm.removed_at is null
     and frm.required
    where r.processing_status = 'accepted'
      and r.meaningful_change = true
      and r.change_type = 'MATCH_SCORE_CHANGED'
      and r.provider_updated_at >=
          v_round.starts_at;


    /*
     * Advance every enabled league round that is still precisely locked.
     *
     * Preserve League Round specific later states.
     */
    update public.league_rounds lr
    set
        status = 'live',

        first_official_score_at =
            coalesce(
                lr.first_official_score_at,
                v_first_score_at
            ),

        updated_at = v_now,

        version = lr.version + 1

    where lr.fantagol_round_id =
          p_fantagol_round_id
      and lr.enabled
      and lr.status = 'predictions_locked';

    get diagnostics v_advanced = row_count;


    select count(*)::integer
    into v_already
    from public.league_rounds lr
    where lr.fantagol_round_id =
          p_fantagol_round_id
      and lr.enabled
      and lr.status in (
          'live',
          'waiting_postponed',
          'final_calculable',
          'scoring',
          'official',
          'recalculated',
          'archived',
          'cancelled'
      );


    /*
     * Global round becomes live only after provider live evidence exists.
     */
    update public.fantagol_rounds fr
    set
        status = 'live',
        updated_at = v_now
    where fr.id = p_fantagol_round_id
      and fr.status = 'predictions_locked';

    v_round_advanced := found;


    /*
     * Postcondition:
     *
     * no enabled League Round may remain predictions_locked once the global
     * round has successfully entered live.
     */
    if v_round_advanced
       and exists (
          select 1
          from public.league_rounds lr
          where lr.fantagol_round_id =
                p_fantagol_round_id
            and lr.enabled
            and lr.status =
                'predictions_locked'
       )
    then
        raise exception using
            errcode = 'P0001',
            message = 'LIVE_TRANSITION_INCOMPLETE';
    end if;


    return query
    select
        p_fantagol_round_id,
        v_round_advanced,
        v_advanced,
        v_already,
        v_first_score_at,
        v_live_match_id;
end;
$function$;


-- ============================================================================
-- 2. SECURITY
-- ============================================================================

revoke all
on function public.advance_round_live_internal(uuid)
from public;

revoke all
on function public.advance_round_live_internal(uuid)
from anon;

revoke all
on function public.advance_round_live_internal(uuid)
from authenticated;

grant execute
on function public.advance_round_live_internal(uuid)
to service_role;


comment on function public.advance_round_live_internal(uuid) is
'Canonical service-role lifecycle authority for predictions_locked -> live. Requires persisted provider live evidence from a required official Match Set member. Independently materializes League Round first_official_score_at from the earliest accepted meaningful MATCH_SCORE_CHANGED receipt at or after round.starts_at. Idempotent and advisory-lock serialized.';


-- ============================================================================
-- 3. INSTALLATION VERIFICATION
-- ============================================================================

do $verification$
declare
    v_definition text;
begin

    select pg_get_functiondef(p.oid)
    into v_definition
    from pg_proc p
    join pg_namespace n
      on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname =
          'advance_round_live_internal'
    limit 1;

    if v_definition is null then
        raise exception
            'LIVE_TRANSITION_AUTHORITY_MISSING';
    end if;

    if position(
        'round-live-transition:'
        in v_definition
    ) = 0 then
        raise exception
            'LIVE_TRANSITION_ADVISORY_LOCK_MISSING';
    end if;

    if position(
        'predictions_locked'
        in v_definition
    ) = 0
       or position(
           'status = ''live'''
           in v_definition
       ) = 0
    then
        raise exception
            'LIVE_TRANSITION_EDGE_MISSING';
    end if;

    if position(
        'MATCH_SCORE_CHANGED'
        in v_definition
    ) = 0
       or position(
           'first_official_score_at'
           in v_definition
       ) = 0
    then
        raise exception
            'LIVE_SCORE_AUTHORITY_MISSING';
    end if;

    if position(
        'frm.required'
        in v_definition
    ) = 0
       or position(
           'frm.removed_at is null'
           in lower(v_definition)
       ) = 0
    then
        raise exception
            'LIVE_OFFICIAL_MATCH_SET_FILTER_MISSING';
    end if;

    if position(
        'provider_updated_at >='
        in v_definition
    ) = 0 then
        raise exception
            'LIVE_SCORE_TEMPORAL_GUARD_MISSING';
    end if;

end;
$verification$;

commit;