-- ============================================================================
-- FANTAGOL
-- Migration 287: Round Predictions Live Clock Anchor Projection
-- ============================================================================
--
-- Purpose:
-- - keep Football-Data / canonical Match status as phase authority;
-- - preserve matches.minute as provider-owned canonical minute;
-- - expose DISPLAY-only phase anchors to the dashboard;
-- - never write a synthetic minute into public.matches.
--
-- R43 lineage:
-- - migration 258 proved receipt-derived halftime/restart anchors;
-- - migration 261 removed the abandoned wrapper RPC experiment;
-- - this migration restores only the anchor derivation inside the current
--   canonical get_my_round_predictions_rpc authority.
-- ============================================================================

begin;

create or replace function public.resolve_dashboard_live_clock_anchor_internal(
  p_match_id uuid
)
returns table (
  live_half integer,
  live_phase_started_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $function$
declare
  v_status text;
  v_kickoff timestamptz;
  v_half_time_at timestamptz;
  v_restart_at timestamptz;
begin
  select
    lower(coalesce(m.status, '')),
    m.kickoff
  into
    v_status,
    v_kickoff
  from public.matches m
  where m.id = p_match_id;

  if not found then
    return query
    select null::integer, null::timestamptz;
    return;
  end if;

  select max(r.received_at)
  into v_half_time_at
  from public.live_match_update_receipts r
  where r.match_id = p_match_id
    and r.received_at >= coalesce(
      v_kickoff - interval '5 minutes',
      '-infinity'::timestamptz
    )
    and lower(
      coalesce(
        r.normalized_payload ->> 'status',
        ''
      )
    ) in ('halftime', 'paused');

  if
    v_status = 'halftime'
    or v_status = 'paused'
  then
    return query
    select 1::integer, null::timestamptz;
    return;
  end if;

  if
    v_status like 'live_%'
    or v_status in (
      'live',
      'in_play',
      'extra_time',
      'penalties'
    )
  then
    if v_half_time_at is null then
      return query
      select 1::integer, v_kickoff;
      return;
    end if;

    select min(r.received_at)
    into v_restart_at
    from public.live_match_update_receipts r
    where r.match_id = p_match_id
      and r.received_at > v_half_time_at
      and (
        lower(
          coalesce(
            r.normalized_payload ->> 'status',
            ''
          )
        ) like 'live_%'
        or lower(
          coalesce(
            r.normalized_payload ->> 'status',
            ''
          )
        ) in (
          'live',
          'in_play',
          'extra_time',
          'penalties'
        )
      );

    if v_restart_at is not null then
      return query
      select 2::integer, v_restart_at;
      return;
    end if;

    return query
    select null::integer, null::timestamptz;
    return;
  end if;

  return query
  select null::integer, null::timestamptz;
end;
$function$;

revoke all
on function public.resolve_dashboard_live_clock_anchor_internal(uuid)
from public;

drop function if exists public.get_my_round_predictions_rpc(uuid);

create function public.get_my_round_predictions_rpc(
  p_league_round_id uuid
)
returns table (
  league_round_id uuid,
  league_id uuid,
  league_round_number integer,
  league_round_status text,
  league_round_enabled boolean,
  fantagol_round_id uuid,
  round_opens_at timestamptz,
  round_lock_at timestamptz,
  prediction_window_state text,
  can_edit boolean,
  seconds_to_lock bigint,
  league_member_id uuid,
  slot_number integer,
  required boolean,
  match_id uuid,
  kickoff timestamptz,
  match_status text,
  minute integer,
  live_half integer,
  live_phase_started_at timestamptz,
  home_score integer,
  away_score integer,
  home_team_id uuid,
  home_team_name text,
  home_team_short_name text,
  home_team_logo_url text,
  home_team_crest_reference text,
  away_team_id uuid,
  away_team_name text,
  away_team_short_name text,
  away_team_logo_url text,
  away_team_crest_reference text,
  prediction_id uuid,
  home_prediction integer,
  away_prediction integer,
  prediction_status text,
  prediction_version integer,
  prediction_submitted_at timestamptz,
  prediction_locked_at timestamptz,
  prediction_updated_at timestamptz,
  filled_prediction_count integer,
  required_prediction_count integer,
  is_complete boolean,
  has_official_submission boolean,
  has_unconfirmed_changes boolean,
  official_home_prediction integer,
  official_away_prediction integer,
  official_submitted_at timestamptz
)
language plpgsql
security definer
set search_path to public, pg_temp
as $function$
declare
  v_user_id uuid := auth.uid();
  v_league_id uuid;
  v_fantagol_round_id uuid;
  v_number integer;
  v_status text;
  v_enabled boolean;
  v_opens timestamptz;
  v_lock timestamptz;
  v_member uuid;
  v_now timestamptz := clock_timestamp();
  v_window text;
  v_edit boolean;
  v_seconds bigint;
  v_required integer;
  v_filled integer;
begin
  if v_user_id is null then
    raise exception using errcode='P0001', message='AUTHENTICATION_REQUIRED';
  end if;

  select
    lr.league_id,
    lr.fantagol_round_id,
    lr.league_round_number,
    lr.status,
    lr.enabled,
    fr.opens_at,
    fr.lock_at
  into
    v_league_id,
    v_fantagol_round_id,
    v_number,
    v_status,
    v_enabled,
    v_opens,
    v_lock
  from public.league_rounds lr
  join public.fantagol_rounds fr
    on fr.id = lr.fantagol_round_id
  where lr.id = p_league_round_id;

  if not found then
    raise exception using errcode='P0001', message='LEAGUE_ROUND_NOT_FOUND';
  end if;

  select lm.id
  into v_member
  from public.league_members lm
  where lm.league_id = v_league_id
    and lm.user_id = v_user_id
    and lm.status = 'active'
  limit 1;

  if v_member is null then
    raise exception using errcode='P0001', message='ACTIVE_LEAGUE_MEMBERSHIP_REQUIRED';
  end if;

  v_window := case
    when not v_enabled then 'disabled'
    when v_status in (
      'predictions_locked',
      'live',
      'waiting_postponed',
      'final_calculable',
      'scoring',
      'official',
      'recalculated',
      'archived'
    ) then 'closed'
    when v_status='cancelled' then 'cancelled'
    when v_now < v_opens then 'not_open'
    when v_now >= v_lock then 'closed'
    when v_status='predictions_open' then 'open'
    else 'scheduled'
  end;

  v_edit :=
    v_enabled
    and v_status='predictions_open'
    and v_now>=v_opens
    and v_now<v_lock;

  v_seconds := case
    when v_now<v_lock
      then greatest(
        floor(extract(epoch from (v_lock-v_now)))::bigint,
        0
      )
    else 0
  end;

  select count(*)::integer
  into v_required
  from public.fantagol_round_matches frm_required
  where frm_required.fantagol_round_id = v_fantagol_round_id
    and frm_required.removed_at is null
    and frm_required.required;

  select count(*)::integer
  into v_filled
  from public.predictions p
  join public.fantagol_round_matches frm
    on frm.fantagol_round_id = v_fantagol_round_id
   and frm.match_id = p.match_id
   and frm.removed_at is null
   and frm.required
  where p.league_round_id = p_league_round_id
    and p.league_member_id = v_member
    and p.status in ('draft','submitted','locked');

  return query
  select
    p_league_round_id,
    v_league_id,
    v_number,
    v_status,
    v_enabled,
    v_fantagol_round_id,
    v_opens,
    v_lock,
    v_window,
    v_edit,
    v_seconds,
    v_member,
    frm.slot_number,
    frm.required,
    m.id,
    m.kickoff,
    m.status,
    m.minute,
    clock_anchor.live_half,
    clock_anchor.live_phase_started_at,
    m.home_score,
    m.away_score,
    ht.id,
    ht.name,
    ht.short_name,
    ht.logo_url,
    ht.crest_reference,
    at.id,
    at.name,
    at.short_name,
    at.logo_url,
    at.crest_reference,
    p.id,
    p.home_prediction,
    p.away_prediction,
    coalesce(p.status,'missing'),
    p.version,
    p.submitted_at,
    p.locked_at,
    p.updated_at,
    v_filled,
    v_required,
    (v_required>0 and v_filled=v_required),
    (p.submitted_version is not null),
    (
      p.submitted_version is not null
      and (
        p.version<>p.submitted_version
        or p.status<>'submitted'
      )
    ),
    opv.home_prediction,
    opv.away_prediction,
    p.official_submitted_at
  from public.fantagol_round_matches frm
  join public.matches m
    on m.id = frm.match_id
  join public.teams ht
    on ht.id = m.home_team_id
  join public.teams at
    on at.id = m.away_team_id
  left join public.predictions p
    on p.league_round_id = p_league_round_id
   and p.league_member_id = v_member
   and p.match_id = m.id
  left join public.prediction_versions opv
    on opv.prediction_id = p.id
   and opv.version = p.submitted_version
  left join lateral
    public.resolve_dashboard_live_clock_anchor_internal(m.id)
    as clock_anchor
    on true
  where frm.fantagol_round_id = v_fantagol_round_id
    and frm.removed_at is null
  order by frm.slot_number;
end;
$function$;

comment on function public.get_my_round_predictions_rpc(uuid)
is 'Returns private prediction workspace plus canonical match state and display-only live clock anchors. Synthetic display time is derived client-side; public.matches.minute remains provider-owned.';

revoke all on function public.get_my_round_predictions_rpc(uuid) from public;
revoke all on function public.get_my_round_predictions_rpc(uuid) from anon;
grant execute on function public.get_my_round_predictions_rpc(uuid) to authenticated;

notify pgrst, 'reload schema';

commit;