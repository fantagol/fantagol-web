-- ================================================================
-- FANTAGOL
-- 257_live_frontend_projection_rpc.sql
--
-- R40-R14E2
-- Canonical post-lock LIVE frontend projection.
--
-- PURPOSE
-- -------
-- Expose already-materialized Digital Twin data to an authenticated
-- active member of the same league after the prediction lock.
--
-- This function:
--   * DOES NOT calculate scores;
--   * DOES NOT build simulations;
--   * DOES NOT modify predictions;
--   * DOES NOT modify strategies;
--   * DOES NOT enqueue jobs;
--   * DOES NOT create snapshots;
--   * DOES NOT publish anything.
--
-- It is a read projection only.
-- ================================================================

create or replace function public.get_league_live_frontend_projection_rpc(
    p_league_round_id uuid
)
returns table(
    simulation_id uuid,
    simulation_version integer,
    simulation_status text,
    simulation_hash text,
    manifest jsonb,
    round_view jsonb,
    matches jsonb,
    members jsonb,
    points_preview jsonb,
    fantacalcio_preview jsonb,
    one_to_one_preview jsonb,
    standings_preview jsonb,
    ui_snapshot jsonb
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $function$
declare
    v_user_id uuid;
    v_member_id uuid;
    v_lock_at timestamptz;
    v_round_enabled boolean;
    v_simulation public.round_simulations%rowtype;
    v_strategies_live jsonb;
begin
    v_user_id := auth.uid();

    if v_user_id is null then
        raise exception using
            errcode = 'P0001',
            message = 'AUTHENTICATION_REQUIRED';
    end if;

    if p_league_round_id is null then
        raise exception using
            errcode = 'P0001',
            message = 'LEAGUE_ROUND_REQUIRED';
    end if;

    select
        fr.lock_at,
        lr.enabled,
        lm.id
    into
        v_lock_at,
        v_round_enabled,
        v_member_id
    from public.league_rounds lr
    join public.fantagol_rounds fr
      on fr.id = lr.fantagol_round_id
    join public.league_members lm
      on lm.league_id = lr.league_id
     and lm.user_id = v_user_id
     and lm.status = 'active'
    where lr.id = p_league_round_id
    limit 1;

    if v_member_id is null then
        raise exception using
            errcode = 'P0001',
            message = 'ACTIVE_LEAGUE_MEMBERSHIP_REQUIRED';
    end if;

    if not coalesce(v_round_enabled, false) then
        raise exception using
            errcode = 'P0001',
            message = 'LEAGUE_ROUND_DISABLED';
    end if;

    if v_lock_at is null or clock_timestamp() < v_lock_at then
        raise exception using
            errcode = 'P0001',
            message = 'LIVE_FRONTEND_PROJECTION_NOT_VISIBLE';
    end if;

    select rs.*
    into v_simulation
    from public.round_simulations rs
    where rs.league_round_id = p_league_round_id
      and rs.publishable = true
      and rs.status in (
          'preview_ready',
          'awaiting_certification',
          'certified'
      )
      and rs.digital_twin ? 'points_preview'
      and rs.digital_twin ? 'fantacalcio_preview'
      and rs.digital_twin ? 'one_to_one_preview'
      and rs.digital_twin ? 'standings_preview'
      and rs.digital_twin ? 'ui_snapshot'
    order by
        rs.simulation_version desc,
        rs.created_at desc
    limit 1;

    if not found then
        return;
    end if;

    select
        coalesce(
            jsonb_agg(
                jsonb_build_object(
                    'strategy_id', s.id,
                    'league_member_id', s.league_member_id,
                    'league_fixture_id', s.league_fixture_id,
                    'mode', lf.mode,
                    'strategy_status', s.status,
                    'strategy_version', s.version,
                    'submitted_version', s.submitted_version,
                    'official_submitted_at', s.official_submitted_at,
                    'locked_at', s.locked_at,
                    'payload', sv.payload
                )
                order by
                    lf.mode,
                    s.league_member_id
            ),
            '[]'::jsonb
        )
    into v_strategies_live
    from public.strategies s
    join public.league_fixtures lf
      on lf.id = s.league_fixture_id
     and lf.league_round_id = s.league_round_id
    join public.strategy_versions sv
      on sv.strategy_id = s.id
     and sv.version = s.submitted_version
    where s.league_round_id = p_league_round_id
      and s.status = 'locked'
      and s.submitted_version is not null
      and lf.mode in (
          'fantacalcio',
          'one_to_one'
      );

    return query
    select
        v_simulation.id,
        v_simulation.simulation_version,
        v_simulation.status,
        v_simulation.simulation_hash,
        coalesce(
            v_simulation.digital_twin -> 'manifest',
            '{}'::jsonb
        ),
        coalesce(
            v_simulation.digital_twin -> 'round',
            '{}'::jsonb
        ),
        coalesce(
            v_simulation.digital_twin -> 'matches',
            '[]'::jsonb
        ),
        coalesce(
            v_simulation.digital_twin -> 'members',
            '[]'::jsonb
        ),
        coalesce(
            v_simulation.digital_twin -> 'points_preview',
            '{}'::jsonb
        ),
        coalesce(
            v_simulation.digital_twin -> 'fantacalcio_preview',
            '{}'::jsonb
        ),
        coalesce(
            v_simulation.digital_twin -> 'one_to_one_preview',
            '{}'::jsonb
        ),
        coalesce(
            v_simulation.digital_twin -> 'standings_preview',
            '{}'::jsonb
        ),
        coalesce(
            v_simulation.digital_twin -> 'ui_snapshot',
            '{}'::jsonb
        )
        ||
        jsonb_build_object(
            'strategies_live',
            coalesce(
                v_strategies_live,
                '[]'::jsonb
            )
        );
end;
$function$;


revoke all
on function public.get_league_live_frontend_projection_rpc(uuid)
from public;

revoke all
on function public.get_league_live_frontend_projection_rpc(uuid)
from anon;

grant execute
on function public.get_league_live_frontend_projection_rpc(uuid)
to authenticated;


comment on function
public.get_league_live_frontend_projection_rpc(uuid)
is
'Authenticated active-league-member read-only projection of the latest publishable post-lock Digital Twin for LIVE frontend materialization. Exposes league-wide Points, Fantacalcio, One-to-One, standings and UI read models only after league_round.lock_at. Performs no calculation, mutation, enqueue, simulation build, snapshot creation or publication.';