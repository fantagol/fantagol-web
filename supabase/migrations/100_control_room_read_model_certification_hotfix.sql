-- ============================================================================
-- FANTAGOL
-- MIGRATION 100
-- CONTROL ROOM READ MODEL ACCESS AND CERTIFICATION HOTFIX
-- ============================================================================
--
-- Purpose
--   1. Preserve authenticated-only client access to Control Room read RPCs.
--   2. Permit trusted backend/service-role execution and direct PostgreSQL
--      certification sessions where auth.uid() is legitimately null.
--   3. Centralize the authorization contract in one private helper.
--   4. Recreate and certify every Control Room read RPC without exposing
--      underlying anonymous community tables or views.
--
-- Security contract
--   - anon remains denied;
--   - authenticated JWT sessions remain allowed;
--   - service_role JWT sessions remain allowed;
--   - trusted PostgreSQL administrative sessions are allowed for migrations,
--     diagnostics and certification;
--   - direct table/view grants to anon/authenticated remain unchanged.
-- ============================================================================

begin;

-- ============================================================================
-- 1. CENTRALIZED READ AUTHORIZATION CONTRACT
-- ============================================================================

create or replace function public.community_read_access_allowed()
returns boolean
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $$
    select
        auth.uid() is not null
        or coalesce(current_setting('request.jwt.claim.role', true), '') = 'service_role'
        or session_user in ('postgres', 'supabase_admin')
$$;

comment on function public.community_read_access_allowed() is
'Private authorization helper for Community Intelligence read RPCs. Allows authenticated users, service_role JWT requests, and trusted PostgreSQL administrative certification sessions.';

revoke all on function public.community_read_access_allowed()
from public, anon, authenticated;

grant execute on function public.community_read_access_allowed()
to service_role;

-- ============================================================================
-- 2. CONTROL ROOM OVERVIEW RPC
-- ============================================================================

create or replace function public.get_control_room_overview_rpc(
    p_fantagol_round_id uuid default null
)
returns jsonb
language plpgsql
security definer
stable
set search_path = public, auth, pg_temp
as $$
declare
    v_round_id uuid;
    v_payload jsonb;
begin
    if not public.community_read_access_allowed() then
        raise exception using
            message = 'COMMUNITY_ACCESS_DENIED',
            errcode = '42501';
    end if;

    v_round_id := p_fantagol_round_id;

    if v_round_id is null then
        select csr.fantagol_round_id
          into v_round_id
          from public.community_snapshot_registry csr
          join public.community_snapshots cs
            on cs.id = csr.current_snapshot_id
          join public.fantagol_rounds fr
            on fr.id = csr.fantagol_round_id
         where fr.active = true
           and cs.status in ('ready', 'frozen')
         order by
             case
                 when fr.status in (
                     'predictions_open',
                     'predictions_locked',
                     'live',
                     'partial_finished'
                 ) then 0
                 else 1
             end,
             fr.starts_at desc nulls last,
             cs.built_at desc
         limit 1;
    end if;

    if v_round_id is null then
        return jsonb_build_object(
            'available', false,
            'error_code', 'COMMUNITY_ROUND_NOT_FOUND'
        );
    end if;

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

    return coalesce(
        v_payload,
        jsonb_build_object(
            'available', false,
            'error_code', 'COMMUNITY_SNAPSHOT_UNAVAILABLE'
        )
    );
end;
$$;

comment on function public.get_control_room_overview_rpc(uuid) is
'Returns the anonymous Community Intelligence overview and ordered match read models for a FantaGol round.';

-- ============================================================================
-- 3. CONTROL ROOM MATCH RPC
-- ============================================================================

create or replace function public.get_control_room_match_rpc(
    p_fantagol_round_id uuid,
    p_match_id uuid
)
returns jsonb
language plpgsql
security definer
stable
set search_path = public, auth, pg_temp
as $$
declare
    v_payload jsonb;
begin
    if not public.community_read_access_allowed() then
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

    return coalesce(
        v_payload,
        jsonb_build_object(
            'available', false,
            'error_code', 'COMMUNITY_MATCH_SNAPSHOT_UNAVAILABLE'
        )
    );
end;
$$;

comment on function public.get_control_room_match_rpc(uuid, uuid) is
'Returns one anonymous Community Intelligence match read model with exact-score heatmap and trend history.';

-- ============================================================================
-- 4. CONTROL ROOM TREND RPC
-- ============================================================================

create or replace function public.get_control_room_trend_rpc(
    p_fantagol_round_id uuid,
    p_match_id uuid default null,
    p_metric_code text default null
)
returns setof public.control_room_trend_v
language plpgsql
security definer
stable
set search_path = public, auth, pg_temp
as $$
begin
    if not public.community_read_access_allowed() then
        raise exception using
            message = 'COMMUNITY_ACCESS_DENIED',
            errcode = '42501';
    end if;

    return query
    select t.*
      from public.control_room_trend_v t
     where t.fantagol_round_id = p_fantagol_round_id
       and (p_match_id is null or t.match_id = p_match_id)
       and (p_metric_code is null or t.metric_code = p_metric_code)
     order by t.created_at, t.match_id, t.metric_code;
end;
$$;

comment on function public.get_control_room_trend_rpc(uuid, uuid, text) is
'Returns anonymous Community Intelligence trend rows filtered by round, optional match and optional metric.';

-- ============================================================================
-- 5. COMMUNITY SNAPSHOT STATUS RPC
-- ============================================================================

create or replace function public.get_community_snapshot_status_rpc(
    p_fantagol_round_id uuid
)
returns jsonb
language plpgsql
security definer
stable
set search_path = public, auth, pg_temp
as $$
declare
    v_payload jsonb;
begin
    if not public.community_read_access_allowed() then
        raise exception using
            message = 'COMMUNITY_ACCESS_DENIED',
            errcode = '42501';
    end if;

    select jsonb_build_object(
        'available', true,
        'registry', to_jsonb(csr),
        'current_snapshot', to_jsonb(cs),
        'recent_events', (
            select coalesce(
                jsonb_agg(to_jsonb(e) order by e.occurred_at desc),
                '[]'::jsonb
            )
            from (
                select
                    cse.event_type,
                    cse.status,
                    cse.payload,
                    cse.correlation_id,
                    cse.occurred_at
                from public.community_snapshot_events cse
                where cse.fantagol_round_id = p_fantagol_round_id
                order by cse.occurred_at desc
                limit 25
            ) e
        )
    )
      into v_payload
      from public.community_snapshot_registry csr
      left join public.community_snapshots cs
        on cs.id = csr.current_snapshot_id
     where csr.fantagol_round_id = p_fantagol_round_id;

    return coalesce(
        v_payload,
        jsonb_build_object(
            'available', false,
            'error_code', 'COMMUNITY_ROUND_NOT_FOUND'
        )
    );
end;
$$;

comment on function public.get_community_snapshot_status_rpc(uuid) is
'Returns operational registry, current snapshot and recent event status for a Community Intelligence round.';

-- ============================================================================
-- 6. GRANT CONTRACT
-- ============================================================================

revoke all on function public.get_control_room_overview_rpc(uuid)
from public, anon;

revoke all on function public.get_control_room_match_rpc(uuid, uuid)
from public, anon;

revoke all on function public.get_control_room_trend_rpc(uuid, uuid, text)
from public, anon;

revoke all on function public.get_community_snapshot_status_rpc(uuid)
from public, anon;

grant execute on function public.get_control_room_overview_rpc(uuid)
to authenticated, service_role;

grant execute on function public.get_control_room_match_rpc(uuid, uuid)
to authenticated, service_role;

grant execute on function public.get_control_room_trend_rpc(uuid, uuid, text)
to authenticated, service_role;

grant execute on function public.get_community_snapshot_status_rpc(uuid)
to authenticated, service_role;

-- ============================================================================
-- 7. INSTALL-TIME READ MODEL CERTIFICATION
-- ============================================================================

do $$
declare
    v_round_id uuid;
    v_match_id uuid;
    v_overview jsonb;
    v_match jsonb;
    v_status jsonb;
    v_match_count integer;
    v_heatmap_count integer;
begin
    if not public.community_read_access_allowed() then
        raise exception 'COMMUNITY_READ_ACCESS_CERTIFICATION_FAILED';
    end if;

    select csr.fantagol_round_id
      into v_round_id
      from public.community_snapshot_registry csr
      join public.community_snapshots cs
        on cs.id = csr.current_snapshot_id
     where cs.status in ('ready', 'frozen')
     order by cs.built_at desc
     limit 1;

    -- The migration remains installable before the first snapshot exists.
    if v_round_id is null then
        return;
    end if;

    v_overview := public.get_control_room_overview_rpc(v_round_id);

    if coalesce((v_overview ->> 'available')::boolean, false) is not true then
        raise exception
            'CONTROL_ROOM_OVERVIEW_CERTIFICATION_FAILED: %',
            v_overview;
    end if;

    v_match_count := jsonb_array_length(
        coalesce(v_overview -> 'matches', '[]'::jsonb)
    );

    if v_match_count <= 0 then
        raise exception
            'CONTROL_ROOM_OVERVIEW_MATCHES_EMPTY: round=%',
            v_round_id;
    end if;

    select mv.match_id
      into v_match_id
      from public.control_room_match_v mv
     where mv.fantagol_round_id = v_round_id
     order by mv.slot_number
     limit 1;

    if v_match_id is null then
        raise exception
            'CONTROL_ROOM_MATCH_DISCOVERY_FAILED: round=%',
            v_round_id;
    end if;

    v_match := public.get_control_room_match_rpc(v_round_id, v_match_id);

    if coalesce((v_match ->> 'available')::boolean, false) is not true then
        raise exception
            'CONTROL_ROOM_MATCH_CERTIFICATION_FAILED: %',
            v_match;
    end if;

    v_heatmap_count := jsonb_array_length(
        coalesce(v_match -> 'heatmap', '[]'::jsonb)
    );

    if v_heatmap_count <= 0 then
        raise exception
            'CONTROL_ROOM_HEATMAP_EMPTY: round=%, match=%',
            v_round_id,
            v_match_id;
    end if;

    v_status := public.get_community_snapshot_status_rpc(v_round_id);

    if coalesce((v_status ->> 'available')::boolean, false) is not true then
        raise exception
            'COMMUNITY_STATUS_CERTIFICATION_FAILED: %',
            v_status;
    end if;
end;
$$;

commit;
