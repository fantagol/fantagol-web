-- FANTAGOL MIGRATION 294
-- 12H POST-ROUND CURRENT-ROUND UX FREEZE
-- Anchor: latest terminal completion across certified publication, full profile fanout, and production-required rewards.
-- Requires active official round certification; LIVE is ineligible. No round/schedule/scoring/recovery mutation.

create or replace function public.get_my_current_league_round_rpc(p_league_id uuid)
returns table(
  league_id uuid,
  league_round_id uuid,
  league_round_number integer,
  league_round_status text,
  fantagol_round_id uuid,
  round_opens_at timestamptz,
  round_lock_at timestamptz,
  round_starts_at timestamptz
)
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_user_id uuid;
begin
  v_user_id := auth.uid();

  if v_user_id is null then
    raise exception using errcode='P0001', message='AUTHENTICATION_REQUIRED';
  end if;

  if p_league_id is null then
    raise exception using errcode='P0001', message='LEAGUE_REQUIRED';
  end if;

  if not exists (
    select 1 from public.league_members lm
    where lm.league_id=p_league_id
      and lm.user_id=v_user_id
      and lm.status='active'
  ) then
    raise exception using errcode='P0001', message='ACTIVE_LEAGUE_MEMBERSHIP_REQUIRED';
  end if;

  return query
  with active_certification as (
    select distinct on (rc.league_round_id)
      rc.id as certification_id,
      rc.league_round_id,
      rc.source_run_id,
      rc.committed_at
    from public.round_certifications rc
    join public.league_rounds lr0 on lr0.id=rc.league_round_id
    where lr0.league_id=p_league_id
      and lr0.enabled
      and lr0.status in ('official','recalculated')
      and rc.status='official'
      and rc.active=true
      and rc.committed_at is not null
    order by rc.league_round_id,rc.certification_version desc,rc.committed_at desc,rc.id desc
  ),
  active_member_expectation as (
    select
      ac.league_round_id,
      count(lm.id)::integer as expected_profile_workflows
    from active_certification ac
    join public.league_rounds lr0 on lr0.id=ac.league_round_id
    left join public.league_members lm
      on lm.league_id=lr0.league_id
     and lm.status='active'
     and lm.user_id is not null
    group by ac.league_round_id
  ),
  publication_terminal as (
    select
      ac.league_round_id,
      count(*) filter (
        where rsp.status='published'
          and rsp.published_at is not null
          and rsp.metadata->>'certification_id'=ac.certification_id::text
      )::integer as publication_count,
      max(rsp.published_at) filter (
        where rsp.status='published'
          and rsp.published_at is not null
          and rsp.metadata->>'certification_id'=ac.certification_id::text
      ) as publication_terminal_at
    from active_certification ac
    left join public.round_simulation_publications rsp
      on rsp.league_round_id=ac.league_round_id
    group by ac.league_round_id,ac.certification_id
  ),
  profile_terminal as (
    select
      ac.league_round_id,
      ame.expected_profile_workflows,
      count(w.id)::integer as profile_workflows,
      count(w.id) filter (
        where w.status='completed'
          and s.status='completed'
          and j.status='completed'
          and j.completed_at is not null
      )::integer as completed_profile_workflows,
      max(greatest(
        coalesce(w.completed_at,'-infinity'::timestamptz),
        coalesce(s.completed_at,'-infinity'::timestamptz),
        coalesce(j.completed_at,'-infinity'::timestamptz),
        coalesce(j.updated_at,'-infinity'::timestamptz)
      )) filter (
        where w.status='completed'
          and s.status='completed'
          and j.status='completed'
          and j.completed_at is not null
      ) as profile_terminal_at
    from active_certification ac
    join active_member_expectation ame
      on ame.league_round_id=ac.league_round_id
    left join public.live_runtime_workflows w
      on w.workflow_type='profile_state_certification'
     and w.metadata->>'source'='round_terminal_game_objectives'
     and w.metadata->>'league_round_id'=ac.league_round_id::text
     and w.metadata->>'round_certification_id'=ac.certification_id::text
    left join public.live_runtime_workflow_steps s
      on s.workflow_id=w.id
     and s.step_key='certify_profile_completion'
    left join public.live_runtime_jobs j
      on j.id=s.job_id
     and j.job_type='certify_achievement_state'
    group by ac.league_round_id,ame.expected_profile_workflows
  ),
  certified_results as (
    select
      ac.league_round_id,
      psrr.id as prediction_result_id,
      psrr.is_exact,
      psrr.is_cantonata,
      psrr.is_grand_slam
    from active_certification ac
    join public.prediction_score_runtime_results psrr
      on psrr.calculation_run_id=ac.source_run_id
     and psrr.league_round_id=ac.league_round_id
    where psrr.result_phase='certified'
      and psrr.provisional=false
      and psrr.included=true
      and psrr.missing=false
      and psrr.void=false
  ),
  production_required_rewards as (
    select x.league_round_id,x.prediction_result_id,x.event_code
    from (
      select
        cr.league_round_id,
        cr.prediction_result_id,
        'PREDICTION_RESULT_EXACT'::text as producer_code,
        'CERTIFIED_EXACT_ACHIEVED'::text as event_code
      from certified_results cr
      where cr.is_exact=true

      union all

      select
        cr.league_round_id,
        cr.prediction_result_id,
        'PREDICTION_RESULT_CANTONATA'::text,
        'CERTIFIED_CANTONATA_ACHIEVED'::text
      from certified_results cr
      where cr.is_cantonata=true

      union all

      select
        cr.league_round_id,
        cr.prediction_result_id,
        'PREDICTION_RESULT_GRAND_SLAM'::text,
        'CERTIFIED_GRAND_SLAM_ACHIEVED'::text
      from certified_results cr
      where cr.is_grand_slam=true
    ) x
    join public.loyalty_event_producers p
      on p.producer_code=x.producer_code
     and p.enabled=true
     and p.test_mode=false
  ),
  reward_terminal as (
    select
      ac.league_round_id,
      count(rrq.prediction_result_id)::integer as expected_rewards,
      count(lre.id)::integer as actual_rewards,
      count(lre.id) filter (
        where lre.event_status='rewarded'
          and lre.processed_at is not null
      )::integer as rewarded,
      count(distinct rc.id) filter (
        where rc.claim_status='settled'
          and rc.settled_at is not null
      )::integer as settled_claims,
      count(distinct rr.id)::integer as revelations,
      greatest(
        max(lre.processed_at),
        max(rc.settled_at),
        max(rr.created_at)
      ) as reward_terminal_at
    from active_certification ac
    left join production_required_rewards rrq
      on rrq.league_round_id=ac.league_round_id
    left join public.loyalty_reward_events lre
      on lre.league_round_id=ac.league_round_id
     and lre.prediction_result_id=rrq.prediction_result_id
     and lre.event_code=rrq.event_code
    left join public.reward_claims rc
      on rc.id=lre.claim_id
    left join public.reward_revelations rr
      on rr.claim_id=lre.claim_id
     and rr.loyalty_reward_event_id=lre.id
    group by ac.league_round_id
  ),
  terminal_round as (
    select
      ac.league_round_id,
      greatest(
        pt.publication_terminal_at,
        pr.profile_terminal_at,
        rt.reward_terminal_at
      ) as freeze_anchor_at
    from active_certification ac
    join publication_terminal pt
      on pt.league_round_id=ac.league_round_id
    join profile_terminal pr
      on pr.league_round_id=ac.league_round_id
    join reward_terminal rt
      on rt.league_round_id=ac.league_round_id
    where pt.publication_count=1
      and pr.expected_profile_workflows>0
      and pr.profile_workflows=pr.expected_profile_workflows
      and pr.completed_profile_workflows=pr.expected_profile_workflows
      and pr.profile_terminal_at is not null
      and rt.actual_rewards=rt.expected_rewards
      and rt.rewarded=rt.expected_rewards
      and rt.settled_claims=rt.expected_rewards
      and rt.revelations=rt.expected_rewards
  ),
  freeze_round as (
    select tr.league_round_id,tr.freeze_anchor_at
    from terminal_round tr
    where tr.freeze_anchor_at is not null
      and clock_timestamp() >= tr.freeze_anchor_at
      and clock_timestamp() < tr.freeze_anchor_at + interval '12 hours'
    order by tr.freeze_anchor_at desc,tr.league_round_id
    limit 1
  ),
  candidates as (
    select lr.*, fr.opens_at, fr.lock_at, fr.starts_at,
      case
        when frz.league_round_id is not null then 0
        when lr.status='predictions_open'
         and clock_timestamp()>=fr.opens_at
         and clock_timestamp()<fr.lock_at then 1
        when lr.status in ('predictions_locked','live','waiting_postponed','final_calculable','scoring') then 2
        when lr.status='scheduled' and fr.starts_at>=clock_timestamp() then 3
        when lr.status='official' then 4
        when lr.status='recalculated' then 5
        else 6
      end as resolver_priority
    from public.league_rounds lr
    join public.fantagol_rounds fr on fr.id=lr.fantagol_round_id
    left join freeze_round frz on frz.league_round_id=lr.id
    where lr.league_id=p_league_id
      and lr.enabled
      and lr.status not in ('archived','cancelled')
  )
  select c.league_id,c.id,c.league_round_number,c.status,c.fantagol_round_id,
         c.opens_at,c.lock_at,c.starts_at
  from candidates c
  order by
    c.resolver_priority,
    case when c.starts_at>=clock_timestamp() then c.starts_at else null end asc nulls last,
    c.starts_at desc,
    c.league_round_number asc
  limit 1;

  if not found then
    raise exception using errcode='P0001', message='CURRENT_LEAGUE_ROUND_NOT_FOUND';
  end if;
end;
$function$;

revoke all on function public.get_my_current_league_round_rpc(uuid) from public;
grant execute on function public.get_my_current_league_round_rpc(uuid) to authenticated;
