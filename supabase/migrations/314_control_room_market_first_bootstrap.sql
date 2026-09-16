-- ============================================================================
-- FANTAGOL MIGRATION 314
-- CONTROL ROOM MARKET-FIRST RPC BOOTSTRAP
--
-- Root cause
--   get_control_room_overview_rpc(NULL) resolved the visible round exclusively
--   through community_snapshot_registry. A canonically opened round therefore
--   stayed invisible until Community Intelligence had materialized a snapshot.
--
-- Certified authority
--   The new round becomes eligible for Control Room only after the canonical
--   prediction-opening transition. That transition is fail-closed on Surprise
--   Reference readiness, which itself is built from the first complete READY
--   Market PACKAGE for the round.
--
-- Repair
--   1. Keep Community read-model views unchanged.
--   2. Resolve the default Control Room round from canonical FantaGol round
--      lifecycle state, never from Community registry.
--   3. Preserve the existing Community payload unchanged when it exists.
--   4. If Community does not exist yet, return a neutral canonical 10-match
--      shell. The existing authenticated Market bridge enriches that shell.
--   5. Apply the same fallback to match detail so Market detail remains usable
--      before Community detail exists.
--
-- No writer/runtime behavior is changed.
-- ============================================================================

begin;

-- ============================================================================
-- 1. OVERVIEW RPC
-- ============================================================================

create or replace function public.get_control_room_overview_rpc(
    p_fantagol_round_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $function$
declare
    v_round_id uuid;
    v_payload jsonb;
    v_round public.fantagol_rounds%rowtype;
    v_market_built_at timestamptz;
    v_market_snapshot_count integer;
    v_match_count integer;
    v_phase text;
    v_matches jsonb;
begin
    if not public.control_room_read_access_allowed() then
        raise exception using
            message = 'COMMUNITY_ACCESS_DENIED',
            errcode = '42501';
    end if;

    v_round_id := p_fantagol_round_id;

    -- Default Control Room authority:
    -- use the current canonical round once it has crossed prediction opening.
    -- If the current view is still a future scheduled round, retain the latest
    -- previously opened/lifecycle-active round.
    if v_round_id is null then
        select cfr.round_id
          into v_round_id
          from public.current_fantagol_round_view cfr
         where cfr.status in (
             'predictions_open',
             'predictions_locked',
             'live',
             'partial_finished',
             'waiting_postponed',
             'final_calculable'
         )
         order by
             cfr.sequence desc,
             cfr.starts_at desc nulls last,
             cfr.round_id
         limit 1;
    end if;

    if v_round_id is null then
        select fr.id
          into v_round_id
          from public.fantagol_rounds fr
         where fr.active = true
           and fr.status in (
               'predictions_open',
               'predictions_locked',
               'live',
               'partial_finished',
               'waiting_postponed',
               'final_calculable'
           )
         order by
             fr.sequence desc,
             fr.starts_at desc nulls last,
             fr.id
         limit 1;
    end if;

    if v_round_id is null then
        return jsonb_build_object(
            'available', false,
            'error_code', 'CONTROL_ROOM_ROUND_NOT_FOUND'
        );
    end if;

    -- Preserve the historical/current Community payload byte-for-byte in shape
    -- whenever Community already exists.
    select jsonb_build_object(
        'available', true,
        'overview', to_jsonb(o),
        'matches', (
            select coalesce(
                jsonb_agg(to_jsonb(mv) order by mv.slot_number),
                '[]'::jsonb
            )
            from public.control_room_match_v mv
            where mv.fantagol_round_id = v_round_id
        )
    )
      into v_payload
      from public.control_room_overview_v o
     where o.fantagol_round_id = v_round_id;

    if v_payload is not null then
        return v_payload;
    end if;

    -- No Community snapshot yet: fail closed unless the round has actually
    -- crossed the canonical market-backed prediction-opening boundary.
    select fr.*
      into v_round
      from public.fantagol_rounds fr
     where fr.id = v_round_id
       and fr.active = true
       and fr.status in (
           'predictions_open',
           'predictions_locked',
           'live',
           'partial_finished',
           'waiting_postponed',
           'final_calculable'
       );

    if not found then
        return jsonb_build_object(
            'available', false,
            'error_code', 'CONTROL_ROOM_ROUND_NOT_OPEN',
            'fantagol_round_id', v_round_id
        );
    end if;

    if public.surprise_reference_ready_internal(v_round_id) is not true then
        return jsonb_build_object(
            'available', false,
            'error_code', 'CONTROL_ROOM_SURPRISE_REFERENCE_NOT_READY',
            'fantagol_round_id', v_round_id
        );
    end if;

    select
        count(*)::integer,
        max(mis.captured_at)
      into
        v_market_snapshot_count,
        v_market_built_at
      from public.market_intelligence_snapshots mis
     where mis.fantagol_round_id = v_round_id
       and mis.status = 'ready'
       and mis.snapshot_source = 'PACKAGE'
       and mis.required_match_count > 0
       and mis.required_match_count = mis.captured_match_count;

    if coalesce(v_market_snapshot_count, 0) <= 0 then
        return jsonb_build_object(
            'available', false,
            'error_code', 'CONTROL_ROOM_MARKET_PACKAGE_NOT_READY',
            'fantagol_round_id', v_round_id
        );
    end if;

    select count(*)::integer
      into v_match_count
      from public.fantagol_round_matches frm
     where frm.fantagol_round_id = v_round_id
       and frm.required = true
       and frm.removed_at is null;

    if coalesce(v_match_count, 0) <= 0 then
        return jsonb_build_object(
            'available', false,
            'error_code', 'CONTROL_ROOM_MATCH_SET_UNAVAILABLE',
            'fantagol_round_id', v_round_id
        );
    end if;

    v_phase :=
        case
            when v_round.status in (
                'predictions_open',
                'predictions_locked'
            ) then 'pre_live'
            when v_round.status in (
                'live',
                'partial_finished',
                'waiting_postponed'
            ) then 'live'
            when v_round.status = 'final_calculable' then 'post_live'
            else 'historical'
        end;

    select coalesce(
        jsonb_agg(
            jsonb_build_object(
                'fantagol_round_id', v_round.id,
                'community_snapshot_id', null,
                'snapshot_version', 0,
                'phase', v_phase,
                'snapshot_status', 'community_pending',
                'built_at', v_market_built_at,

                'match_id', frm.match_id,
                'slot_number', frm.slot_number,
                'kickoff', m.kickoff,
                'match_status', m.status,
                'home_score', m.home_score,
                'away_score', m.away_score,

                'home_team_id', ht.id,
                'home_team_name', ht.name,
                'home_team_short_name', ht.short_name,
                'home_team_logo_url', ht.logo_url,
                'home_team_crest_reference', ht.crest_reference,

                'away_team_id', at.id,
                'away_team_name', at.name,
                'away_team_short_name', at.short_name,
                'away_team_logo_url', at.logo_url,
                'away_team_crest_reference', at.crest_reference,

                'prediction_count', 0,
                'member_count', 0,
                'league_count', 0,

                'home_pick_percent', 0,
                'draw_pick_percent', 0,
                'away_pick_percent', 0,

                'over_2_5_percent', 0,
                'under_2_5_percent', 0,
                'goal_percent', 0,
                'no_goal_percent', 0,

                'avg_home_goals', 0,
                'avg_away_goals', 0,
                'avg_total_goals', 0,

                'consensus_outcome', null,
                'consensus_percent', 0,
                'consensus_index', 0,
                'confidence_index', 0,
                'chaos_index', 0,
                'exact_dispersion_index', 0,

                'sample_quality_status', 'community_pending',
                'sample_quality_score', 0,

                'market_snapshot_id', null,
                'market_available', false,
                'market_context', null,
                'trend_context', '{}'::jsonb,
                'exact_distribution', '[]'::jsonb,
                'insights', '[]'::jsonb
            )
            order by frm.slot_number
        ),
        '[]'::jsonb
    )
      into v_matches
      from public.fantagol_round_matches frm
      join public.matches m
        on m.id = frm.match_id
      join public.teams ht
        on ht.id = m.home_team_id
      join public.teams at
        on at.id = m.away_team_id
     where frm.fantagol_round_id = v_round_id
       and frm.required = true
       and frm.removed_at is null;

    return jsonb_build_object(
        'available', true,
        'overview', jsonb_build_object(
            'fantagol_round_id', v_round.id,
            'community_snapshot_id', null,
            'round_name', v_round.name,
            'round_sequence', v_round.sequence,
            'round_status', v_round.status,
            'phase', v_phase,
            'snapshot_status', 'community_pending',
            'snapshot_version', 0,
            'built_at', v_market_built_at,
            'opens_at', v_round.opens_at,
            'lock_at', v_round.lock_at,
            'starts_at', v_round.starts_at,
            'prediction_count', 0,
            'member_count', 0,
            'league_count', 0,
            'match_count', v_match_count,
            'market_snapshot_count', v_market_snapshot_count,
            'quality_status', 'community_pending',
            'quality_score', 0,
            'minimum_sample_satisfied', false,
            'safest_match', null,
            'most_uncertain_match', null,
            'most_concentrated_exact', null,
            'strongest_trend', null
        ),
        'matches', v_matches
    );
end;
$function$;

comment on function public.get_control_room_overview_rpc(uuid) is
'Control Room overview. Default round authority is canonical FantaGol lifecycle state; Community Intelligence is optional enrichment. Before Community exists, returns a neutral canonical match shell after Surprise Reference and complete READY Market PACKAGE are certified.';


-- ============================================================================
-- 2. MATCH DETAIL RPC
-- ============================================================================

create or replace function public.get_control_room_match_rpc(
    p_fantagol_round_id uuid,
    p_match_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $function$
declare
    v_payload jsonb;
    v_round public.fantagol_rounds%rowtype;
    v_market_built_at timestamptz;
    v_market_snapshot_count integer;
    v_phase text;
    v_match jsonb;
begin
    if not public.control_room_read_access_allowed() then
        raise exception using
            message = 'COMMUNITY_ACCESS_DENIED',
            errcode = '42501';
    end if;

    if p_fantagol_round_id is null or p_match_id is null then
        return jsonb_build_object(
            'available', false,
            'error_code', 'COMMUNITY_MATCH_ARGUMENT_REQUIRED'
        );
    end if;

    -- Preserve the existing Community detail when available.
    select jsonb_build_object(
        'available', true,
        'match', to_jsonb(mv),
        'heatmap', (
            select coalesce(
                jsonb_agg(to_jsonb(h) order by h.rank),
                '[]'::jsonb
            )
            from public.control_room_exact_heatmap_v h
            where h.fantagol_round_id = p_fantagol_round_id
              and h.match_id = p_match_id
        ),
        'trend', (
            select coalesce(
                jsonb_agg(to_jsonb(t) order by t.created_at),
                '[]'::jsonb
            )
            from public.control_room_trend_v t
            where t.fantagol_round_id = p_fantagol_round_id
              and t.match_id = p_match_id
        )
    )
      into v_payload
      from public.control_room_match_v mv
     where mv.fantagol_round_id = p_fantagol_round_id
       and mv.match_id = p_match_id;

    if v_payload is not null then
        return v_payload;
    end if;

    select fr.*
      into v_round
      from public.fantagol_rounds fr
     where fr.id = p_fantagol_round_id
       and fr.active = true
       and fr.status in (
           'predictions_open',
           'predictions_locked',
           'live',
           'partial_finished',
           'waiting_postponed',
           'final_calculable'
       );

    if not found then
        return jsonb_build_object(
            'available', false,
            'error_code', 'CONTROL_ROOM_MATCH_ROUND_NOT_OPEN',
            'fantagol_round_id', p_fantagol_round_id,
            'match_id', p_match_id
        );
    end if;

    if public.surprise_reference_ready_internal(
        p_fantagol_round_id
    ) is not true then
        return jsonb_build_object(
            'available', false,
            'error_code', 'CONTROL_ROOM_SURPRISE_REFERENCE_NOT_READY',
            'fantagol_round_id', p_fantagol_round_id,
            'match_id', p_match_id
        );
    end if;

    select
        count(*)::integer,
        max(mis.captured_at)
      into
        v_market_snapshot_count,
        v_market_built_at
      from public.market_intelligence_snapshots mis
     where mis.fantagol_round_id = p_fantagol_round_id
       and mis.status = 'ready'
       and mis.snapshot_source = 'PACKAGE'
       and mis.required_match_count > 0
       and mis.required_match_count = mis.captured_match_count;

    if coalesce(v_market_snapshot_count, 0) <= 0 then
        return jsonb_build_object(
            'available', false,
            'error_code', 'CONTROL_ROOM_MARKET_PACKAGE_NOT_READY',
            'fantagol_round_id', p_fantagol_round_id,
            'match_id', p_match_id
        );
    end if;

    v_phase :=
        case
            when v_round.status in (
                'predictions_open',
                'predictions_locked'
            ) then 'pre_live'
            when v_round.status in (
                'live',
                'partial_finished',
                'waiting_postponed'
            ) then 'live'
            when v_round.status = 'final_calculable' then 'post_live'
            else 'historical'
        end;

    select jsonb_build_object(
        'fantagol_round_id', v_round.id,
        'community_snapshot_id', null,
        'snapshot_version', 0,
        'phase', v_phase,
        'snapshot_status', 'community_pending',
        'built_at', v_market_built_at,

        'match_id', frm.match_id,
        'slot_number', frm.slot_number,
        'kickoff', m.kickoff,
        'match_status', m.status,
        'home_score', m.home_score,
        'away_score', m.away_score,

        'home_team_id', ht.id,
        'home_team_name', ht.name,
        'home_team_short_name', ht.short_name,
        'home_team_logo_url', ht.logo_url,
        'home_team_crest_reference', ht.crest_reference,

        'away_team_id', at.id,
        'away_team_name', at.name,
        'away_team_short_name', at.short_name,
        'away_team_logo_url', at.logo_url,
        'away_team_crest_reference', at.crest_reference,

        'prediction_count', 0,
        'member_count', 0,
        'league_count', 0,

        'home_pick_percent', 0,
        'draw_pick_percent', 0,
        'away_pick_percent', 0,

        'over_2_5_percent', 0,
        'under_2_5_percent', 0,
        'goal_percent', 0,
        'no_goal_percent', 0,

        'avg_home_goals', 0,
        'avg_away_goals', 0,
        'avg_total_goals', 0,

        'consensus_outcome', null,
        'consensus_percent', 0,
        'consensus_index', 0,
        'confidence_index', 0,
        'chaos_index', 0,
        'exact_dispersion_index', 0,

        'sample_quality_status', 'community_pending',
        'sample_quality_score', 0,

        'market_snapshot_id', null,
        'market_available', false,
        'market_context', null,
        'trend_context', '{}'::jsonb,
        'exact_distribution', '[]'::jsonb,
        'insights', '[]'::jsonb
    )
      into v_match
      from public.fantagol_round_matches frm
      join public.matches m
        on m.id = frm.match_id
      join public.teams ht
        on ht.id = m.home_team_id
      join public.teams at
        on at.id = m.away_team_id
     where frm.fantagol_round_id = p_fantagol_round_id
       and frm.match_id = p_match_id
       and frm.required = true
       and frm.removed_at is null;

    if v_match is null then
        return jsonb_build_object(
            'available', false,
            'error_code', 'CONTROL_ROOM_MATCH_NOT_FOUND',
            'fantagol_round_id', p_fantagol_round_id,
            'match_id', p_match_id
        );
    end if;

    return jsonb_build_object(
        'available', true,
        'match', v_match,
        'heatmap', '[]'::jsonb,
        'trend', '[]'::jsonb
    );
end;
$function$;

comment on function public.get_control_room_match_rpc(uuid, uuid) is
'Control Room match detail. Preserves Community detail when available; otherwise returns a neutral canonical match shell after the market-backed prediction-opening boundary so Market detail remains usable.';


-- ============================================================================
-- 3. SECURITY / INSTALL CONTRACT
-- ============================================================================

do $block$
begin
    if to_regprocedure(
        'public.get_control_room_overview_rpc(uuid)'
    ) is null then
        raise exception 'M314_OVERVIEW_RPC_MISSING';
    end if;

    if to_regprocedure(
        'public.get_control_room_match_rpc(uuid,uuid)'
    ) is null then
        raise exception 'M314_MATCH_RPC_MISSING';
    end if;

    if not has_function_privilege(
        'authenticated',
        'public.get_control_room_overview_rpc(uuid)',
        'EXECUTE'
    ) then
        raise exception 'M314_AUTHENTICATED_OVERVIEW_EXECUTE_MISSING';
    end if;

    if not has_function_privilege(
        'authenticated',
        'public.get_control_room_match_rpc(uuid,uuid)',
        'EXECUTE'
    ) then
        raise exception 'M314_AUTHENTICATED_MATCH_EXECUTE_MISSING';
    end if;

    if has_function_privilege(
        'anon',
        'public.get_control_room_overview_rpc(uuid)',
        'EXECUTE'
    ) then
        raise exception 'M314_ANON_OVERVIEW_EXECUTE_EXPOSED';
    end if;

    if has_function_privilege(
        'anon',
        'public.get_control_room_match_rpc(uuid,uuid)',
        'EXECUTE'
    ) then
        raise exception 'M314_ANON_MATCH_EXECUTE_EXPOSED';
    end if;
end
$block$;

commit;
