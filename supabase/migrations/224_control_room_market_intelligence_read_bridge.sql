-- ============================================================================
-- FANTAGOL
-- MIGRATION 224
-- CONTROL ROOM MARKET INTELLIGENCE AUTHENTICATED READ BRIDGE
-- ============================================================================
--
-- Purpose
--   Expose persisted BM_INTERPOLATED artifacts to the authenticated Control Room
--   without exposing Market Intelligence tables or internal service-role readers.
--
-- Security
--   - anon denied
--   - authenticated + service_role execute only
--   - underlying Market Intelligence tables remain private
--   - internal Market Intelligence functions remain service-role only
--   - same centralized authenticated read boundary used by Control Room
-- ============================================================================

begin;

-- ============================================================================
-- 1. SINGLE MATCH MARKET READ MODEL
-- ============================================================================

create or replace function public.get_control_room_market_match_rpc(
    p_fantagol_round_id uuid,
    p_match_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
    v_latest record;
    v_movements jsonb;
begin
    if not public.community_read_access_allowed() then
        raise exception using
            message = 'CONTROL_ROOM_MARKET_ACCESS_DENIED',
            errcode = '42501';
    end if;

    if p_fantagol_round_id is null or p_match_id is null then
        return jsonb_build_object(
            'available', false,
            'error_code', 'MARKET_MATCH_ARGUMENT_REQUIRED'
        );
    end if;

    select *
      into v_latest
      from public.get_latest_market_intelligence_match_internal(p_match_id);

    if not found
       or v_latest.fantagol_round_id is distinct from p_fantagol_round_id then
        return jsonb_build_object(
            'available', false,
            'error_code', 'MARKET_MATCH_SNAPSHOT_UNAVAILABLE',
            'fantagol_round_id', p_fantagol_round_id,
            'match_id', p_match_id
        );
    end if;

    select coalesce(
        jsonb_agg(
            jsonb_build_object(
                'movement_id', mv.movement_id,
                'previous_match_snapshot_id', mv.previous_match_snapshot_id,
                'current_match_snapshot_id', mv.current_match_snapshot_id,
                'signal_type', mv.signal_type,
                'signal_key', mv.signal_key,
                'previous_probability', mv.previous_probability,
                'current_probability', mv.current_probability,
                'delta_probability', mv.delta_probability,
                'delta_percentage_points', mv.delta_percentage_points,
                'previous_rank', mv.previous_rank,
                'current_rank', mv.current_rank,
                'rank_delta', mv.rank_delta,
                'movement_magnitude', mv.movement_magnitude,
                'direction', mv.direction,
                'created_at', mv.created_at
            )
            order by mv.created_at asc, mv.movement_id asc
        ),
        '[]'::jsonb
    )
      into v_movements
      from public.get_market_intelligence_match_movements_internal(
          p_match_id,
          256
      ) mv;

    return jsonb_build_object(
        'available', true,
        'fantagol_round_id', v_latest.fantagol_round_id,
        'match_id', v_latest.match_id,
        'snapshot_id', v_latest.snapshot_id,
        'match_snapshot_id', v_latest.match_snapshot_id,
        'captured_at', v_latest.captured_at,
        'snapshot_source', v_latest.snapshot_source,

        'sign', jsonb_build_object(
            'home', v_latest.home_probability,
            'draw', v_latest.draw_probability,
            'away', v_latest.away_probability
        ),

        'totals', jsonb_build_object(
            'over_25', v_latest.over_25_probability,
            'under_25', v_latest.under_25_probability
        ),

        'btts', jsonb_build_object(
            'goal', v_latest.goal_probability,
            'no_goal', v_latest.no_goal_probability
        ),

        'expected_goals', jsonb_build_object(
            'home', v_latest.lambda_home,
            'away', v_latest.lambda_away
        ),

        'confidence', jsonb_build_object(
            'market', v_latest.market_confidence,
            'final', v_latest.final_confidence,
            'model_loss', v_latest.model_loss
        ),

        'primary_outcome', v_latest.primary_outcome,
        'output_payload', v_latest.output_payload,
        'movements', v_movements
    );
end;
$$;

comment on function public.get_control_room_market_match_rpc(uuid, uuid) is
'Authenticated Control Room bridge for the latest persisted BM_INTERPOLATED match snapshot and granular market movements. Does not expose provider credentials or Market Intelligence tables.';

-- ============================================================================
-- 2. ROUND MARKET READ MODEL
-- ============================================================================

create or replace function public.get_control_room_market_round_rpc(
    p_fantagol_round_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
    v_matches jsonb;
    v_match_count integer;
    v_latest_captured_at timestamptz;
begin
    if not public.community_read_access_allowed() then
        raise exception using
            message = 'CONTROL_ROOM_MARKET_ACCESS_DENIED',
            errcode = '42501';
    end if;

    if p_fantagol_round_id is null then
        return jsonb_build_object(
            'available', false,
            'error_code', 'MARKET_ROUND_ARGUMENT_REQUIRED'
        );
    end if;

    with latest as (
        select distinct on (ms.match_id)
            ms.match_id,
            ms.slot_number,
            s.id as snapshot_id,
            ms.id as match_snapshot_id,
            s.captured_at,
            s.snapshot_source,
            ms.home_probability,
            ms.draw_probability,
            ms.away_probability,
            ms.over_25_probability,
            ms.under_25_probability,
            ms.goal_probability,
            ms.no_goal_probability,
            ms.expected_home_goals,
            ms.expected_away_goals,
            ms.market_confidence,
            ms.confidence_score,
            ms.model_loss,
            ms.primary_outcome,
            ms.output_payload
        from public.market_intelligence_match_snapshots ms
        join public.market_intelligence_snapshots s
          on s.id = ms.market_intelligence_snapshot_id
        where s.fantagol_round_id = p_fantagol_round_id
        order by
            ms.match_id,
            s.captured_at desc nulls last,
            s.snapshot_version desc,
            ms.created_at desc
    )
    select
        coalesce(
            jsonb_agg(
                jsonb_build_object(
                    'match_id', l.match_id,
                    'slot_number', l.slot_number,
                    'snapshot_id', l.snapshot_id,
                    'match_snapshot_id', l.match_snapshot_id,
                    'captured_at', l.captured_at,
                    'snapshot_source', l.snapshot_source,
                    'sign', jsonb_build_object(
                        'home', l.home_probability,
                        'draw', l.draw_probability,
                        'away', l.away_probability
                    ),
                    'totals', jsonb_build_object(
                        'over_25', l.over_25_probability,
                        'under_25', l.under_25_probability
                    ),
                    'btts', jsonb_build_object(
                        'goal', l.goal_probability,
                        'no_goal', l.no_goal_probability
                    ),
                    'expected_goals', jsonb_build_object(
                        'home', l.expected_home_goals,
                        'away', l.expected_away_goals
                    ),
                    'confidence', jsonb_build_object(
                        'market', l.market_confidence,
                        'final', l.confidence_score,
                        'model_loss', l.model_loss
                    ),
                    'primary_outcome', l.primary_outcome,
                    'output_payload', l.output_payload
                )
                order by l.slot_number, l.match_id
            ),
            '[]'::jsonb
        ),
        count(*)::integer,
        max(l.captured_at)
      into v_matches, v_match_count, v_latest_captured_at
      from latest l;

    if coalesce(v_match_count, 0) = 0 then
        return jsonb_build_object(
            'available', false,
            'error_code', 'MARKET_ROUND_SNAPSHOT_UNAVAILABLE',
            'fantagol_round_id', p_fantagol_round_id,
            'matches', '[]'::jsonb
        );
    end if;

    return jsonb_build_object(
        'available', true,
        'fantagol_round_id', p_fantagol_round_id,
        'match_count', v_match_count,
        'latest_captured_at', v_latest_captured_at,
        'matches', v_matches
    );
end;
$$;

comment on function public.get_control_room_market_round_rpc(uuid) is
'Authenticated Control Room bridge returning the latest persisted BM_INTERPOLATED snapshot for each match in one FantaGol round.';

-- ============================================================================
-- 3. GRANT CONTRACT
-- ============================================================================

revoke all on function public.get_control_room_market_match_rpc(uuid, uuid)
from public, anon;

revoke all on function public.get_control_room_market_round_rpc(uuid)
from public, anon;

grant execute on function public.get_control_room_market_match_rpc(uuid, uuid)
to authenticated, service_role;

grant execute on function public.get_control_room_market_round_rpc(uuid)
to authenticated, service_role;

-- Internal readers MUST remain closed to browser roles.
revoke all on function public.get_latest_market_intelligence_match_internal(uuid)
from public, anon, authenticated;

revoke all on function public.get_market_intelligence_match_history_internal(uuid, integer)
from public, anon, authenticated;

revoke all on function public.get_market_intelligence_match_movements_internal(uuid, integer)
from public, anon, authenticated;

grant execute on function public.get_latest_market_intelligence_match_internal(uuid)
to service_role;

grant execute on function public.get_market_intelligence_match_history_internal(uuid, integer)
to service_role;

grant execute on function public.get_market_intelligence_match_movements_internal(uuid, integer)
to service_role;

-- ============================================================================
-- 4. INSTALL-TIME CERTIFICATION
-- ============================================================================

do $$
begin
    if to_regprocedure(
        'public.get_control_room_market_match_rpc(uuid,uuid)'
    ) is null then
        raise exception
            'R38B_INSTALL_ASSERTION_FAILED: match bridge missing';
    end if;

    if to_regprocedure(
        'public.get_control_room_market_round_rpc(uuid)'
    ) is null then
        raise exception
            'R38B_INSTALL_ASSERTION_FAILED: round bridge missing';
    end if;

    if not has_function_privilege(
        'authenticated',
        'public.get_control_room_market_match_rpc(uuid,uuid)',
        'EXECUTE'
    ) then
        raise exception
            'R38B_INSTALL_ASSERTION_FAILED: authenticated match execute missing';
    end if;

    if not has_function_privilege(
        'authenticated',
        'public.get_control_room_market_round_rpc(uuid)',
        'EXECUTE'
    ) then
        raise exception
            'R38B_INSTALL_ASSERTION_FAILED: authenticated round execute missing';
    end if;

    if has_function_privilege(
        'anon',
        'public.get_control_room_market_match_rpc(uuid,uuid)',
        'EXECUTE'
    ) then
        raise exception
            'R38B_INSTALL_ASSERTION_FAILED: anon match execute exposed';
    end if;

    if has_function_privilege(
        'anon',
        'public.get_control_room_market_round_rpc(uuid)',
        'EXECUTE'
    ) then
        raise exception
            'R38B_INSTALL_ASSERTION_FAILED: anon round execute exposed';
    end if;

    if has_function_privilege(
        'authenticated',
        'public.get_latest_market_intelligence_match_internal(uuid)',
        'EXECUTE'
    ) then
        raise exception
            'R38B_INSTALL_ASSERTION_FAILED: internal latest reader exposed';
    end if;

    if has_function_privilege(
        'authenticated',
        'public.get_market_intelligence_match_history_internal(uuid,integer)',
        'EXECUTE'
    ) then
        raise exception
            'R38B_INSTALL_ASSERTION_FAILED: internal history reader exposed';
    end if;

    if has_function_privilege(
        'authenticated',
        'public.get_market_intelligence_match_movements_internal(uuid,integer)',
        'EXECUTE'
    ) then
        raise exception
            'R38B_INSTALL_ASSERTION_FAILED: internal movement reader exposed';
    end if;

    raise notice 'R38-B CONTROL ROOM MARKET READ BRIDGE CERTIFIED';
end;
$$;

commit;
