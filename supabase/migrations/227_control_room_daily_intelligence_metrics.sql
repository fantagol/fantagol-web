begin;

create or replace function public.get_control_room_daily_intelligence_metrics_rpc(
    p_fantagol_round_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $function$
declare
    v_required_match_count integer := 0;
    v_eligible_member_count integer := 0;
    v_market_quality_score numeric;
    v_market_quality_status text;
    v_market_captured_match_count integer := 0;
    v_market_required_match_count integer := 0;
    v_market_captured_at timestamptz;
begin
    if not public.community_read_access_allowed() then
        raise exception using
            message = 'CONTROL_ROOM_DAILY_INTELLIGENCE_ACCESS_DENIED',
            errcode = '42501';
    end if;

    if p_fantagol_round_id is null then
        return jsonb_build_object(
            'available', false,
            'error_code', 'DAILY_INTELLIGENCE_ROUND_REQUIRED'
        );
    end if;

    select count(*)::integer
      into v_required_match_count
      from public.fantagol_round_matches frm
     where frm.fantagol_round_id = p_fantagol_round_id
       and frm.required
       and frm.removed_at is null;

    /*
      Eligible Community denominator:
      active league members belonging to leagues that have a materialized
      league_round for the requested FantaGol round.

      Count DISTINCT member ids so a member is counted once inside the
      actual league membership universe for this round.
    */
    select count(distinct lm.id)::integer
      into v_eligible_member_count
      from public.league_rounds lr
      join public.leagues l
        on l.id = lr.league_id
      join public.league_members lm
        on lm.league_id = l.id
     where lr.fantagol_round_id = p_fantagol_round_id
       and coalesce(l.status, '') not in ('deleted', 'archived')
       and coalesce(l.lifecycle_status, '') not in ('deleted', 'archived')
       and coalesce(lm.status, '') not in ('removed', 'expelled', 'left', 'deleted');

    select
        s.quality_score,
        s.quality_status,
        s.captured_match_count,
        s.required_match_count,
        s.captured_at
      into
        v_market_quality_score,
        v_market_quality_status,
        v_market_captured_match_count,
        v_market_required_match_count,
        v_market_captured_at
      from public.market_intelligence_snapshots s
     where s.fantagol_round_id = p_fantagol_round_id
       and s.status = 'ready'
     order by
        s.captured_at desc nulls last,
        s.snapshot_version desc
     limit 1;

    return jsonb_build_object(
        'available', true,
        'fantagol_round_id', p_fantagol_round_id,
        'required_match_count', v_required_match_count,
        'eligible_member_count', v_eligible_member_count,
        'market_quality_score', v_market_quality_score,
        'market_quality_status', v_market_quality_status,
        'market_captured_match_count', v_market_captured_match_count,
        'market_required_match_count', v_market_required_match_count,
        'market_captured_at', v_market_captured_at
    );
end;
$function$;

comment on function public.get_control_room_daily_intelligence_metrics_rpc(uuid) is
'Authenticated Control Room daily intelligence bridge exposing only the dynamic eligible Community denominator and latest ready Market Intelligence quality/coverage metadata.';

revoke all on function public.get_control_room_daily_intelligence_metrics_rpc(uuid)
from public;

revoke all on function public.get_control_room_daily_intelligence_metrics_rpc(uuid)
from anon;

grant execute on function public.get_control_room_daily_intelligence_metrics_rpc(uuid)
to authenticated;

grant execute on function public.get_control_room_daily_intelligence_metrics_rpc(uuid)
to service_role;

commit;