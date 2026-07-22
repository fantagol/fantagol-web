-- ============================================================================
-- FANTAGOL — MIGRATION 096
-- Statistics Engine Foundation
-- ============================================================================

begin;

create index if not exists round_certifications_statistics_lookup_idx
  on public.round_certifications (league_round_id, active, status, source_run_id);

create index if not exists round_certification_results_statistics_lookup_idx
  on public.round_certification_results (certification_id, league_member_id);

create index if not exists prediction_score_runtime_statistics_lookup_idx
  on public.prediction_score_runtime_results
  (calculation_run_id, league_round_id, league_member_id, match_id);

drop function if exists public.get_league_member_statistics_rpc(uuid);

create function public.get_league_member_statistics_rpc(target_league_id uuid)
returns table (
  member_id uuid,
  club_name text,
  real_name text,
  avatar_url text,
  kit_template text,
  kit_primary_color text,
  kit_secondary_color text,
  kit_third_color text,
  kit_logo_mode text,
  kit_crest_position text,
  stars_count integer,
  total_points numeric,
  exact_count bigint,
  surprise_count bigint,
  goal_show_count bigint,
  grand_slam_count bigint,
  cantonata_count bigint,
  opposite_sign_count bigint,
  average_points numeric,
  best_round numeric,
  worst_round numeric,
  official_round_count bigint,
  best_team text,
  best_team_rate numeric,
  worst_team text,
  worst_team_rate numeric
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $function$
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'AUTHENTICATION_REQUIRED';
  end if;

  if not exists (
    select 1 from public.league_members lm
    where lm.league_id = target_league_id
      and lm.user_id = auth.uid()
      and lm.status = 'active'
  ) then
    raise exception using errcode = '42501', message = 'LEAGUE_MEMBERSHIP_REQUIRED';
  end if;

  return query
  with active_certifications as (
    select rc.id as certification_id, rc.league_round_id, rc.source_run_id
    from public.round_certifications rc
    join public.league_rounds lr on lr.id = rc.league_round_id
    where lr.league_id = target_league_id
      and rc.active = true
      and rc.status = 'official'
  ),
  member_rounds as (
    select rcr.league_member_id, lr.league_round_number, rcr.pure_points,
           rcr.exact_count, rcr.surprise_count, rcr.goal_show_count,
           rcr.grand_slam_count, rcr.cantonata_count, rcr.opposite_sign_count
    from active_certifications ac
    join public.round_certification_results rcr on rcr.certification_id = ac.certification_id
    join public.league_rounds lr on lr.id = ac.league_round_id
  ),
  member_totals as (
    select mr.league_member_id,
           coalesce(sum(mr.pure_points), 0::numeric) as total_points,
           coalesce(sum(mr.exact_count), 0)::bigint as exact_count,
           coalesce(sum(mr.surprise_count), 0)::bigint as surprise_count,
           coalesce(sum(mr.goal_show_count), 0)::bigint as goal_show_count,
           coalesce(sum(mr.grand_slam_count), 0)::bigint as grand_slam_count,
           coalesce(sum(mr.cantonata_count), 0)::bigint as cantonata_count,
           coalesce(sum(mr.opposite_sign_count), 0)::bigint as opposite_sign_count,
           coalesce(round(avg(mr.pure_points), 2), 0::numeric) as average_points,
           coalesce(max(mr.pure_points), 0::numeric) as best_round,
           coalesce(min(mr.pure_points), 0::numeric) as worst_round,
           count(*)::bigint as official_round_count
    from member_rounds mr
    group by mr.league_member_id
  ),
  certified_prediction_rows as (
    select psrr.league_member_id, psrr.match_id, psrr.base_total,
           psrr.is_sign, psrr.is_over_under, psrr.is_goal_no_goal
    from active_certifications ac
    join public.prediction_score_runtime_results psrr
      on psrr.calculation_run_id = ac.source_run_id
     and psrr.league_round_id = ac.league_round_id
    where psrr.included = true and psrr.missing = false and psrr.void = false
  ),
  team_rows as (
    select cpr.league_member_id, td.team_id, td.team_name,
           cpr.base_total, cpr.is_sign, cpr.is_over_under, cpr.is_goal_no_goal
    from certified_prediction_rows cpr
    join public.matches m on m.id = cpr.match_id
    cross join lateral (
      values
        (m.home_team_id, (select t.name from public.teams t where t.id = m.home_team_id)),
        (m.away_team_id, (select t.name from public.teams t where t.id = m.away_team_id))
    ) td(team_id, team_name)
  ),
  team_aggregates as (
    select tr.league_member_id, tr.team_id, tr.team_name,
           count(*)::bigint as matches_count,
           coalesce(sum(tr.base_total), 0::numeric) as points,
           round(100::numeric * (
             count(*) filter (where tr.is_sign)
             + count(*) filter (where tr.is_over_under)
             + count(*) filter (where tr.is_goal_no_goal)
           )::numeric / nullif((count(*) * 3)::numeric, 0), 2) as accuracy
    from team_rows tr
    group by tr.league_member_id, tr.team_id, tr.team_name
  ),
  best_team as (
    select distinct on (ta.league_member_id) ta.league_member_id, ta.team_name, ta.accuracy
    from team_aggregates ta
    order by ta.league_member_id, ta.accuracy desc, ta.points desc, ta.matches_count desc, ta.team_name asc
  ),
  worst_team as (
    select distinct on (ta.league_member_id) ta.league_member_id, ta.team_name, ta.accuracy
    from team_aggregates ta
    order by ta.league_member_id, ta.accuracy asc, ta.points asc, ta.matches_count desc, ta.team_name asc
  )
  select lm.id,
         coalesce(c.name, lm.display_name, 'Club FantaGol')::text,
         c.real_name,
         coalesce(c.crest_url, lm.avatar_url),
         coalesce(c.kit_template, 'solid')::text,
         coalesce(c.kit_primary_color, lm.kit_primary_color, '#FFFFFF')::text,
         coalesce(c.kit_secondary_color, lm.kit_secondary_color, '#A6E824')::text,
         coalesce(c.kit_third_color, '#FFFFFF')::text,
         coalesce(c.kit_logo_mode, 'center_horizontal')::text,
         coalesce(c.kit_crest_position, 'left_chest')::text,
         coalesce(c.stars_count, 0)::integer,
         coalesce(mt.total_points, 0::numeric),
         coalesce(mt.exact_count, 0::bigint),
         coalesce(mt.surprise_count, 0::bigint),
         coalesce(mt.goal_show_count, 0::bigint),
         coalesce(mt.grand_slam_count, 0::bigint),
         coalesce(mt.cantonata_count, 0::bigint),
         coalesce(mt.opposite_sign_count, 0::bigint),
         coalesce(mt.average_points, 0::numeric),
         coalesce(mt.best_round, 0::numeric),
         coalesce(mt.worst_round, 0::numeric),
         coalesce(mt.official_round_count, 0::bigint),
         coalesce(bt.team_name, '—')::text,
         coalesce(bt.accuracy, 0::numeric),
         coalesce(wt.team_name, '—')::text,
         coalesce(wt.accuracy, 0::numeric)
  from public.league_members lm
  left join public.clubs c on c.id = lm.club_id
  left join member_totals mt on mt.league_member_id = lm.id
  left join best_team bt on bt.league_member_id = lm.id
  left join worst_team wt on wt.league_member_id = lm.id
  where lm.league_id = target_league_id and lm.status = 'active'
  order by coalesce(mt.total_points, 0::numeric) desc,
           coalesce(mt.exact_count, 0::bigint) desc,
           lm.joined_at asc, lm.id asc;
end;
$function$;

revoke all on function public.get_league_member_statistics_rpc(uuid) from public;
grant execute on function public.get_league_member_statistics_rpc(uuid) to authenticated;

drop function if exists public.get_member_deep_statistics_rpc(uuid, uuid);

create function public.get_member_deep_statistics_rpc(target_league_id uuid, target_member_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $function$
declare result_payload jsonb;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'AUTHENTICATION_REQUIRED';
  end if;

  if not exists (
    select 1 from public.league_members lm
    where lm.league_id = target_league_id
      and lm.user_id = auth.uid()
      and lm.status = 'active'
  ) then
    raise exception using errcode = '42501', message = 'LEAGUE_MEMBERSHIP_REQUIRED';
  end if;

  if not exists (
    select 1 from public.league_members lm
    where lm.id = target_member_id
      and lm.league_id = target_league_id
      and lm.status = 'active'
  ) then
    raise exception using errcode = 'P0002', message = 'LEAGUE_MEMBER_NOT_FOUND';
  end if;

  with active_certifications as (
    select rc.id as certification_id, rc.league_round_id, rc.source_run_id
    from public.round_certifications rc
    join public.league_rounds lr on lr.id = rc.league_round_id
    where lr.league_id = target_league_id and rc.active = true and rc.status = 'official'
  ),
  member_rounds as (
    select lr.league_round_number as round_number, rcr.*
    from active_certifications ac
    join public.league_rounds lr on lr.id = ac.league_round_id
    join public.round_certification_results rcr
      on rcr.certification_id = ac.certification_id
     and rcr.league_member_id = target_member_id
  ),
  certified_prediction_rows as (
    select psrr.*, m.home_team_id, m.away_team_id
    from active_certifications ac
    join public.prediction_score_runtime_results psrr
      on psrr.calculation_run_id = ac.source_run_id
     and psrr.league_round_id = ac.league_round_id
     and psrr.league_member_id = target_member_id
    join public.matches m on m.id = psrr.match_id
    where psrr.included = true and psrr.missing = false and psrr.void = false
  ),
  team_rows as (
    select td.team_id, td.team_name, td.venue,
           cpr.base_total, cpr.is_exact, cpr.is_sign, cpr.is_over_under,
           cpr.is_goal_no_goal, cpr.is_surprise, cpr.is_cantonata
    from certified_prediction_rows cpr
    cross join lateral (
      values
        (cpr.home_team_id, (select t.name from public.teams t where t.id = cpr.home_team_id), 'home'::text),
        (cpr.away_team_id, (select t.name from public.teams t where t.id = cpr.away_team_id), 'away'::text)
    ) td(team_id, team_name, venue)
  ),
  team_aggregates as (
    select tr.team_id, tr.team_name,
           count(*)::bigint as matches,
           coalesce(sum(tr.base_total), 0::numeric) as points,
           round(100::numeric * (
             count(*) filter (where tr.is_sign)
             + count(*) filter (where tr.is_over_under)
             + count(*) filter (where tr.is_goal_no_goal)
           )::numeric / nullif((count(*) * 3)::numeric, 0), 2) as accuracy,
           count(*) filter (where tr.is_exact)::bigint as exact,
           count(*) filter (where tr.is_sign)::bigint as sign,
           count(*) filter (where tr.is_over_under)::bigint as over_under,
           count(*) filter (where tr.is_goal_no_goal)::bigint as goal_no_goal,
           count(*) filter (where tr.is_surprise)::bigint as surprise,
           count(*) filter (where tr.is_cantonata)::bigint as bad,
           round(100::numeric * (
             count(*) filter (where tr.venue='home' and tr.is_sign)
             + count(*) filter (where tr.venue='home' and tr.is_over_under)
             + count(*) filter (where tr.venue='home' and tr.is_goal_no_goal)
           )::numeric / nullif((count(*) filter (where tr.venue='home') * 3)::numeric, 0), 2) as home_accuracy,
           round(100::numeric * (
             count(*) filter (where tr.venue='away' and tr.is_sign)
             + count(*) filter (where tr.venue='away' and tr.is_over_under)
             + count(*) filter (where tr.venue='away' and tr.is_goal_no_goal)
           )::numeric / nullif((count(*) filter (where tr.venue='away') * 3)::numeric, 0), 2) as away_accuracy,
           count(*) filter (where tr.venue='home' and tr.is_exact)::bigint as home_exact,
           count(*) filter (where tr.venue='away' and tr.is_exact)::bigint as away_exact,
           coalesce(sum(tr.base_total) filter (where tr.venue='home'), 0::numeric) as home_points,
           coalesce(sum(tr.base_total) filter (where tr.venue='away'), 0::numeric) as away_points
    from team_rows tr
    group by tr.team_id, tr.team_name
  ),
  ordered_team_stats as (
    select ta.*,
           case
             when ta.matches < 4 then 'stable'
             when ta.home_accuracy > ta.away_accuracy + 5 then 'up'
             when ta.away_accuracy > ta.home_accuracy + 5 then 'down'
             else 'stable'
           end as trend
    from team_aggregates ta
  ),
  summary as (
    select coalesce(sum(mr.pure_points),0::numeric) as total_points,
           coalesce(round(avg(mr.pure_points),2),0::numeric) as average_points,
           coalesce(sum(mr.exact_count),0)::bigint as exact,
           coalesce(sum(mr.surprise_count),0)::bigint as surprise,
           coalesce(sum(mr.goal_show_count),0)::bigint as show,
           coalesce(sum(mr.grand_slam_count),0)::bigint as slam,
           coalesce(sum(mr.cantonata_count),0)::bigint as bad,
           coalesce(sum(mr.opposite_sign_count),0)::bigint as opposite,
           count(*)::bigint as official_round_count
    from member_rounds mr
  ),
  split_metrics as (
    select count(*)::bigint as evaluated_predictions,
           round(100::numeric * count(*) filter (where cpr.is_sign)::numeric / nullif(count(*)::numeric,0),2) as sign_accuracy,
           round(100::numeric * count(*) filter (where cpr.is_over_under)::numeric / nullif(count(*)::numeric,0),2) as over_under_accuracy,
           round(100::numeric * count(*) filter (where cpr.is_goal_no_goal)::numeric / nullif(count(*)::numeric,0),2) as goal_no_goal_accuracy,
           count(*) filter (where cpr.is_exact and cpr.real_sign='1')::bigint as home_exact,
           count(*) filter (where cpr.is_exact and cpr.real_sign='2')::bigint as away_exact,
           count(*) filter (where cpr.surprise_candidate)::bigint as surprise_candidates,
           round(100::numeric * count(*) filter (where cpr.surprise_candidate and cpr.is_sign)::numeric /
                 nullif(count(*) filter (where cpr.surprise_candidate)::numeric,0),2) as underdog_accuracy,
           round(100::numeric * count(*) filter (where not cpr.surprise_candidate and cpr.is_sign)::numeric /
                 nullif(count(*) filter (where not cpr.surprise_candidate)::numeric,0),2) as standard_accuracy
    from certified_prediction_rows cpr
  ),
  member_identity as (
    select lm.id,
           coalesce(c.name,lm.display_name,'Club FantaGol')::text as club_name,
           coalesce(c.real_name,lm.display_name,'')::text as real_name,
           coalesce(c.kit_template,'solid')::text as kit_template,
           coalesce(c.kit_primary_color,lm.kit_primary_color,'#FFFFFF')::text as kit_primary_color,
           coalesce(c.kit_secondary_color,lm.kit_secondary_color,'#A6E824')::text as kit_secondary_color,
           coalesce(c.kit_third_color,'#FFFFFF')::text as kit_third_color,
           coalesce(c.kit_logo_mode,'center_horizontal')::text as kit_logo_mode,
           coalesce(c.kit_crest_position,'left_chest')::text as kit_crest_position,
           coalesce(c.stars_count,0)::integer as stars_count
    from public.league_members lm
    left join public.clubs c on c.id = lm.club_id
    where lm.id = target_member_id and lm.league_id = target_league_id
  )
  select jsonb_build_object(
    'member', jsonb_build_object(
      'id',mi.id,'clubName',mi.club_name,'realName',mi.real_name,
      'kitTemplate',mi.kit_template,'kitPrimaryColor',mi.kit_primary_color,
      'kitSecondaryColor',mi.kit_secondary_color,'kitThirdColor',mi.kit_third_color,
      'kitLogoMode',mi.kit_logo_mode,'kitCrestPosition',mi.kit_crest_position,
      'starsCount',mi.stars_count,'totalPoints',s.total_points,
      'averagePoints',s.average_points,'exact',s.exact,'surprise',s.surprise,
      'show',s.show,'slam',s.slam,'bad',s.bad,'opposite',s.opposite,
      'officialRoundCount',s.official_round_count
    ),
    'roundTrend', coalesce((select jsonb_agg(jsonb_build_object(
      'round',mr.round_number,'points',mr.pure_points,'exact',mr.exact_count,'bad',mr.cantonata_count
    ) order by mr.round_number) from member_rounds mr),'[]'::jsonb),
    'teamStats', coalesce((select jsonb_agg(jsonb_build_object(
      'team',ots.team_name,'matches',ots.matches,'points',ots.points,'accuracy',coalesce(ots.accuracy,0),
      'exact',ots.exact,'sign',ots.sign,'overUnder',ots.over_under,'goalNoGoal',ots.goal_no_goal,
      'surprise',ots.surprise,'bad',ots.bad,'homeAccuracy',coalesce(ots.home_accuracy,0),
      'awayAccuracy',coalesce(ots.away_accuracy,0),'homeExact',ots.home_exact,
      'awayExact',ots.away_exact,'homePoints',ots.home_points,'awayPoints',ots.away_points,
      'trend',ots.trend
    ) order by ots.accuracy desc nulls last, ots.points desc, ots.team_name) from ordered_team_stats ots),'[]'::jsonb),
    'bestTeam', coalesce((select jsonb_build_object(
      'team',ots.team_name,'matches',ots.matches,'points',ots.points,'accuracy',coalesce(ots.accuracy,0),
      'exact',ots.exact,'sign',ots.sign,'overUnder',ots.over_under,'goalNoGoal',ots.goal_no_goal,
      'surprise',ots.surprise,'bad',ots.bad,'homeAccuracy',coalesce(ots.home_accuracy,0),
      'awayAccuracy',coalesce(ots.away_accuracy,0),'homeExact',ots.home_exact,'awayExact',ots.away_exact,
      'homePoints',ots.home_points,'awayPoints',ots.away_points,'trend',ots.trend
    ) from ordered_team_stats ots order by ots.accuracy desc nulls last, ots.points desc, ots.team_name limit 1),
    jsonb_build_object('team','—','matches',0,'points',0,'accuracy',0,'exact',0,'sign',0,'overUnder',0,'goalNoGoal',0,'surprise',0,'bad',0,'homeAccuracy',0,'awayAccuracy',0,'homeExact',0,'awayExact',0,'homePoints',0,'awayPoints',0,'trend','stable')),
    'worstTeam', coalesce((select jsonb_build_object(
      'team',ots.team_name,'matches',ots.matches,'points',ots.points,'accuracy',coalesce(ots.accuracy,0),
      'exact',ots.exact,'sign',ots.sign,'overUnder',ots.over_under,'goalNoGoal',ots.goal_no_goal,
      'surprise',ots.surprise,'bad',ots.bad,'homeAccuracy',coalesce(ots.home_accuracy,0),
      'awayAccuracy',coalesce(ots.away_accuracy,0),'homeExact',ots.home_exact,'awayExact',ots.away_exact,
      'homePoints',ots.home_points,'awayPoints',ots.away_points,'trend',ots.trend
    ) from ordered_team_stats ots order by ots.accuracy asc nulls last, ots.points asc, ots.team_name limit 1),
    jsonb_build_object('team','—','matches',0,'points',0,'accuracy',0,'exact',0,'sign',0,'overUnder',0,'goalNoGoal',0,'surprise',0,'bad',0,'homeAccuracy',0,'awayAccuracy',0,'homeExact',0,'awayExact',0,'homePoints',0,'awayPoints',0,'trend','stable')),
    'splits', jsonb_build_object(
      'signAccuracy',coalesce(sm.sign_accuracy,0),'overUnderAccuracy',coalesce(sm.over_under_accuracy,0),
      'goalNoGoalAccuracy',coalesce(sm.goal_no_goal_accuracy,0),'homeExact',coalesce(sm.home_exact,0),
      'awayExact',coalesce(sm.away_exact,0),'underdogAccuracy',coalesce(sm.underdog_accuracy,0),
      'standardAccuracy',coalesce(sm.standard_accuracy,0),'evaluatedPredictions',coalesce(sm.evaluated_predictions,0),
      'surpriseCandidates',coalesce(sm.surprise_candidates,0),'officialRounds',s.official_round_count
    )
  ) into result_payload
  from member_identity mi cross join summary s cross join split_metrics sm;

  return result_payload;
end;
$function$;

revoke all on function public.get_member_deep_statistics_rpc(uuid, uuid) from public;
grant execute on function public.get_member_deep_statistics_rpc(uuid, uuid) to authenticated;

comment on function public.get_league_member_statistics_rpc(uuid) is
  'Returns certified aggregate statistics for every active member of a league. Members with no official rounds receive zero-valued statistics.';

comment on function public.get_member_deep_statistics_rpc(uuid, uuid) is
  'Returns certified deep statistics for one active league member, including round trend, per-team performance and real scoring splits.';

commit;
