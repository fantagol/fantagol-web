-- FANTAGOL MIGRATION 351 - ordinary live closure and 12-hour handoff
-- SOURCE: R41-R5J-R26-R11; verified original SHA256 5AD104BA131A218FEC2AE6579EF0A83C59412E2C6DED6B625B4B19CE813E16AD
-- RELEASE CANDIDATE ONLY: NO AUTOMATIC EXECUTION / NO PRODUCTION APPROVAL
-- SQL LOGIC BELOW IS BYTE-IDENTICAL TO ORIGINAL R11 STARTING AT LINE 5.

-- No scoring, classification, awards, reward, recovery, or postponed RPC changes.

CREATE TABLE IF NOT EXISTS public.round_ordinary_live_closures (
  fantagol_round_id uuid PRIMARY KEY REFERENCES public.fantagol_rounds(id),
  last_eligible_ft_at timestamptz NOT NULL,
  handoff_at timestamptz NOT NULL,
  required_match_count integer NOT NULL CHECK (required_match_count > 0),
  finished_match_count integer NOT NULL CHECK (finished_match_count > 0),
  postponed_match_count integer NOT NULL CHECK (postponed_match_count >= 0),
  evidence_snapshot jsonb NOT NULL CHECK (jsonb_typeof(evidence_snapshot) = 'array'),
  recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT ordinary_live_count_check CHECK (
    required_match_count = finished_match_count + postponed_match_count
  ),
  CONSTRAINT ordinary_live_anchor_recorded_check CHECK (last_eligible_ft_at <= recorded_at)
);

-- The materialized anchor must not change even when a delayed match is recovered.
CREATE OR REPLACE FUNCTION public.guard_round_ordinary_live_closure_immutable()
RETURNS trigger LANGUAGE plpgsql SET search_path = public, pg_temp AS $fn$
BEGIN
  RAISE EXCEPTION 'ORDINARY_LIVE_CLOSURE_WRITE_ONCE';
END;
$fn$;

DROP TRIGGER IF EXISTS round_ordinary_live_closure_immutable
ON public.round_ordinary_live_closures;
CREATE TRIGGER round_ordinary_live_closure_immutable
BEFORE UPDATE OR DELETE ON public.round_ordinary_live_closures
FOR EACH ROW EXECUTE FUNCTION public.guard_round_ordinary_live_closure_immutable();

-- This RPC is the only intended materialization entry point.
-- Caller must be a trusted service_role background worker, not a browser request.
CREATE OR REPLACE FUNCTION public.record_round_ordinary_live_closure_internal(
  p_fantagol_round_id uuid
)
RETURNS TABLE (
  closure_round_id uuid,
  was_inserted boolean,
  recorded_anchor_at timestamptz,
  recorded_handoff_at timestamptz,
  outcome text
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $fn$
DECLARE
  v_round public.fantagol_rounds%rowtype;
  v_total integer;
  v_finished integer;
  v_postponed integer;
  v_other integer;
  v_unanchored integer;
  v_last_ft timestamptz;
  v_snapshot jsonb;
  v_record public.round_ordinary_live_closures%rowtype;
  v_inserted boolean := false;
BEGIN
  IF p_fantagol_round_id IS NULL THEN
    RAISE EXCEPTION 'ORDINARY_LIVE_ROUND_ID_REQUIRED';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(
    'ordinary-live-closure:' || p_fantagol_round_id::text, 0
  ));

  SELECT * INTO v_record FROM public.round_ordinary_live_closures
  WHERE fantagol_round_id = p_fantagol_round_id;
  IF FOUND THEN
    RETURN QUERY SELECT v_record.fantagol_round_id, false,
      v_record.last_eligible_ft_at, v_record.handoff_at, 'ALREADY_RECORDED'::text;
    RETURN;
  END IF;

  SELECT * INTO v_round FROM public.fantagol_rounds
  WHERE id = p_fantagol_round_id AND active IS TRUE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ORDINARY_LIVE_ACTIVE_ROUND_NOT_FOUND'; END IF;

  -- Never close a round that has not entered its scheduled match window.
  IF v_round.starts_at IS NULL OR clock_timestamp() < v_round.starts_at THEN
    RETURN QUERY SELECT p_fantagol_round_id, false, NULL::timestamptz,
      NULL::timestamptz, 'ROUND_NOT_STARTED'::text;
    RETURN;
  END IF;

  SELECT
    count(*)::integer,
    count(*) FILTER (WHERE m.status IN ('finished','awarded'))::integer,
    count(*) FILTER (WHERE m.status = 'postponed')::integer,
    count(*) FILTER (WHERE m.status IS NULL OR m.status NOT IN ('finished','awarded','postponed'))::integer,
    count(*) FILTER (WHERE m.status IN ('finished','awarded') AND m.finalised_at IS NULL)::integer,
    max(m.finalised_at) FILTER (WHERE m.status IN ('finished','awarded')),
    jsonb_agg(jsonb_build_object(
      'match_id', m.id,
      'match_status', m.status,
      'kickoff', m.kickoff,
      'finalised_at', m.finalised_at,
      'provider_updated_at', m.provider_updated_at
    ) ORDER BY frm.slot_number, m.id)
  INTO v_total, v_finished, v_postponed, v_other, v_unanchored, v_last_ft, v_snapshot
  FROM public.fantagol_round_matches frm
  JOIN public.matches m ON m.id = frm.match_id
  WHERE frm.fantagol_round_id = p_fantagol_round_id
    AND frm.required IS TRUE AND frm.removed_at IS NULL;

  IF v_total = 0 OR v_finished = 0 OR v_other > 0
     OR v_unanchored > 0 OR v_last_ft IS NULL
     OR v_total <> v_finished + v_postponed THEN
    RETURN QUERY SELECT p_fantagol_round_id, false, NULL::timestamptz,
      NULL::timestamptz, 'NOT_ELIGIBLE'::text;
    RETURN;
  END IF;

  IF v_last_ft > clock_timestamp() THEN
    RETURN QUERY SELECT p_fantagol_round_id, false, NULL::timestamptz,
      NULL::timestamptz, 'FUTURE_FT_BLOCKED'::text;
    RETURN;
  END IF;

  INSERT INTO public.round_ordinary_live_closures (
    fantagol_round_id, last_eligible_ft_at, handoff_at, required_match_count,
    finished_match_count, postponed_match_count, evidence_snapshot
  ) VALUES (
    p_fantagol_round_id, v_last_ft, v_last_ft + interval '12 hours', v_total,
    v_finished, v_postponed, v_snapshot
  ) ON CONFLICT (fantagol_round_id) DO NOTHING
  RETURNING * INTO v_record;

  v_inserted := FOUND;
  IF NOT v_inserted THEN
    SELECT * INTO v_record FROM public.round_ordinary_live_closures
    WHERE fantagol_round_id = p_fantagol_round_id;
  END IF;

  RETURN QUERY SELECT v_record.fantagol_round_id, v_inserted,
    v_record.last_eligible_ft_at, v_record.handoff_at,
    CASE WHEN v_inserted THEN 'RECORDED' ELSE 'ALREADY_RECORDED' END::text;
END;
$fn$;

REVOKE ALL ON TABLE public.round_ordinary_live_closures FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.record_round_ordinary_live_closure_internal(uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.record_round_ordinary_live_closure_internal(uuid)
  TO service_role;
GRANT SELECT ON TABLE public.round_ordinary_live_closures TO service_role;
GRANT SELECT ON TABLE public.round_ordinary_live_closures TO authenticated;
ALTER TABLE public.round_ordinary_live_closures ENABLE ROW LEVEL SECURITY;
CREATE POLICY round_ordinary_live_closures_read_authenticated
ON public.round_ordinary_live_closures FOR SELECT TO authenticated
USING (EXISTS (SELECT 1 FROM public.league_rounds lr JOIN public.league_members lm ON lm.league_id=lr.league_id
  WHERE lr.fantagol_round_id=round_ordinary_live_closures.fantagol_round_id
    AND lr.enabled AND lm.user_id=auth.uid() AND lm.status='active'));

CREATE OR REPLACE FUNCTION public.get_my_current_league_round_rpc(p_league_id uuid)
 RETURNS TABLE(league_id uuid, league_round_id uuid, league_round_number integer, league_round_status text, fantagol_round_id uuid, round_opens_at timestamp with time zone, round_lock_at timestamp with time zone, round_starts_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
    select 1
    from public.league_members lm
    where lm.league_id=p_league_id
      and lm.user_id=v_user_id
      and lm.status='active'
  ) then
    raise exception using errcode='P0001', message='ACTIVE_LEAGUE_MEMBERSHIP_REQUIRED';
  end if;

  return query
  -- R26-R11: a completed match set must protect G9 immediately, even if the
  -- async closure recorder has not yet materialized its durable row.
  -- The computed fallback is a READ-ONLY projection. The recorder alone writes
  -- the immutable closure. This is NOT evidence that finalised_at equals FT.
  with closure_round as (
    select lr.id as league_round_id,
           coalesce(c.handoff_at, eligible.last_ft + interval '12 hours') as handoff_at
    from public.league_rounds lr
    join public.fantagol_rounds fr on fr.id = lr.fantagol_round_id
    left join public.round_ordinary_live_closures c
      on c.fantagol_round_id = lr.fantagol_round_id
    left join lateral (
      select
        max(m.finalised_at) filter (where m.status in ('finished','awarded')) as last_ft,
        count(*)::integer as total,
        count(*) filter (where m.status in ('finished','awarded'))::integer as finished,
        count(*) filter (where m.status = 'postponed')::integer as postponed,
        count(*) filter (where m.status is null or m.status not in ('finished','awarded','postponed'))::integer as other,
        count(*) filter (where m.status in ('finished','awarded') and m.finalised_at is null)::integer as missing_anchor
      from public.fantagol_round_matches frm
      join public.matches m on m.id = frm.match_id
      where frm.fantagol_round_id = lr.fantagol_round_id
        and frm.required is true and frm.removed_at is null
    ) eligible on c.fantagol_round_id is null
    where lr.league_id = p_league_id
      and lr.enabled = true
      and (
        c.fantagol_round_id is not null
        or (
          fr.starts_at is not null and fr.starts_at <= clock_timestamp()
          and eligible.total > 0 and eligible.finished > 0
          and eligible.other = 0 and eligible.missing_anchor = 0
          and eligible.total = eligible.finished + eligible.postponed
          and eligible.last_ft is not null
          and eligible.last_ft <= clock_timestamp()
        )
      )
  ),
  freeze_round as (
    select cr.league_round_id, cr.handoff_at
    from closure_round cr
    where clock_timestamp() < cr.handoff_at
    order by cr.handoff_at desc, cr.league_round_id
    limit 1
  ),
  candidates as (
    select
      lr.*,
      fr.opens_at,
      fr.lock_at,
      fr.starts_at,
      case
        -- A single ordinary LIVE freeze supersedes every next-round open.
        when frz.league_round_id is not null then 0
        -- Expired prior rounds cannot reappear because rewards certify late.
        when closed.league_round_id is not null then 9
        -- Any older unresolved round is historical once a newer closure exists.
        -- It must never resurrect ahead of the next prediction window.
        when exists (
          select 1 from public.league_rounds newer_lr
          join public.round_ordinary_live_closures newer_closure
            on newer_closure.fantagol_round_id = newer_lr.fantagol_round_id
          where newer_lr.league_id = lr.league_id
            and newer_lr.enabled
            and newer_lr.league_round_number > lr.league_round_number
        ) then 9
        -- The unfinished operational round owns the shared Giornata page.
        when lr.status in ('predictions_locked','live','waiting_postponed','final_calculable','scoring') then 1
        when lr.status='predictions_open'
          and clock_timestamp()>=fr.opens_at
          and clock_timestamp()<fr.lock_at then 2
        when lr.status='scheduled' and fr.starts_at>=clock_timestamp() then 3
        when lr.status='official' then 4
        when lr.status='recalculated' then 5
        else 6
      end as resolver_priority
    from public.league_rounds lr
    join public.fantagol_rounds fr on fr.id=lr.fantagol_round_id
    left join freeze_round frz on frz.league_round_id=lr.id
    left join closure_round closed on closed.league_round_id=lr.id
    where lr.league_id=p_league_id
      and lr.enabled
      and lr.status not in ('archived','cancelled')
  )
  select
    c.league_id,
    c.id,
    c.league_round_number,
    c.status,
    c.fantagol_round_id,
    c.opens_at,
    c.lock_at,
    c.starts_at
  from candidates c
  order by
    c.resolver_priority,
    case when c.starts_at>=clock_timestamp() then c.starts_at else null end asc nulls last,
    c.starts_at desc,
    c.league_round_number desc
  limit 1;

  if not found then
    raise exception using errcode='P0001', message='CURRENT_LEAGUE_ROUND_NOT_FOUND';
  end if;
end;
$function$;

CREATE OR REPLACE FUNCTION public.assert_current_operational_round_internal(p_league_round_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $r26$
DECLARE
  v_league_id uuid;
  v_current uuid;
BEGIN
  SELECT lr.league_id INTO v_league_id FROM public.league_rounds lr
  WHERE lr.id = p_league_round_id AND lr.enabled;
  IF v_league_id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='LEAGUE_ROUND_NOT_FOUND';
  END IF;
  SELECT r.league_round_id INTO v_current
  FROM public.get_my_current_league_round_rpc(v_league_id) AS r;
  IF v_current IS DISTINCT FROM p_league_round_id THEN
    RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='ROUND_NOT_CURRENTLY_OPERATIONAL';
  END IF;
END;
$r26$;
REVOKE ALL ON FUNCTION public.assert_current_operational_round_internal(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.assert_current_operational_round_internal(uuid) TO authenticated;

create or replace function public.save_prediction_draft_rpc(
  p_league_round_id uuid,
  p_match_id uuid,
  p_home_prediction integer,
  p_away_prediction integer
)
returns table (
  prediction_id uuid,
  league_round_id uuid,
  league_member_id uuid,
  match_id uuid,
  home_prediction integer,
  away_prediction integer,
  prediction_status text,
  prediction_version integer,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path to public, pg_temp
as $function$
declare
  v_user_id uuid;
  v_league_id uuid;
  v_fantagol_round_id uuid;
  v_league_round_status text;
  v_league_round_enabled boolean;
  v_round_opens_at timestamptz;
  v_round_lock_at timestamptz;
  v_member_id uuid;
  v_prediction public.predictions%rowtype;
  v_previous_status text;
  v_previous_version integer;
  v_operation text;
  v_now timestamptz := clock_timestamp();
begin
  v_user_id := auth.uid();

  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTHENTICATION_REQUIRED';
  end if;

  if p_league_round_id is null or p_match_id is null then
    raise exception using errcode = 'P0001', message = 'PREDICTION_TARGET_REQUIRED';
  end if;

  if p_home_prediction is null or p_away_prediction is null
     or p_home_prediction < 0 or p_home_prediction > 9
     or p_away_prediction < 0 or p_away_prediction > 9 then
    raise exception using errcode = 'P0001', message = 'PREDICTION_SCORE_INVALID';
  end if;

  select lr.league_id, lr.fantagol_round_id, lr.status, lr.enabled,
         fr.opens_at, fr.lock_at
  into v_league_id, v_fantagol_round_id, v_league_round_status,
       v_league_round_enabled, v_round_opens_at, v_round_lock_at
  from public.league_rounds lr
  join public.fantagol_rounds fr on fr.id = lr.fantagol_round_id
  where lr.id = p_league_round_id
  for update of lr;

  if not found then
    raise exception using errcode = 'P0001', message = 'LEAGUE_ROUND_NOT_FOUND';
  end if;

  if not v_league_round_enabled then
    raise exception using errcode = 'P0001', message = 'LEAGUE_ROUND_DISABLED';
  end if;

  if v_league_round_status <> 'predictions_open' or v_now < v_round_opens_at then
    raise exception using errcode = 'P0001', message = 'PREDICTION_WINDOW_NOT_OPEN';
  end if;

  if v_now >= v_round_lock_at then
    raise exception using errcode = 'P0001', message = 'PREDICTION_WINDOW_CLOSED';
  end if;

  select lm.id
  into v_member_id
  from public.league_members lm
  where lm.league_id = v_league_id
    and lm.user_id = v_user_id
    and lm.status = 'active'
  limit 1;

  if v_member_id is null then
    raise exception using errcode = 'P0001', message = 'ACTIVE_LEAGUE_MEMBERSHIP_REQUIRED';
  end if;

  if not exists (
    select 1
    from public.fantagol_round_matches frm
    where frm.fantagol_round_id = v_fantagol_round_id
      and frm.match_id = p_match_id
      and frm.removed_at is null
  ) then
    raise exception using errcode = 'P0001', message = 'MATCH_NOT_IN_LEAGUE_ROUND';
  end if;

  PERFORM public.assert_current_operational_round_internal(p_league_round_id);
  perform pg_advisory_xact_lock(
    hashtextextended(
      p_league_round_id::text || ':' || v_member_id::text || ':' || p_match_id::text,
      0
    )
  );

  select p.*
  into v_prediction
  from public.predictions p
  where p.league_round_id = p_league_round_id
    and p.league_member_id = v_member_id
    and p.match_id = p_match_id
  for update;

  if found then
    if v_prediction.status in ('locked', 'void') then
      raise exception using errcode = 'P0001', message = 'PREDICTION_NOT_EDITABLE';
    end if;

    if v_prediction.home_prediction = p_home_prediction
       and v_prediction.away_prediction = p_away_prediction then
      return query
      select v_prediction.id, v_prediction.league_round_id,
             v_prediction.league_member_id, v_prediction.match_id,
             v_prediction.home_prediction, v_prediction.away_prediction,
             v_prediction.status, v_prediction.version, v_prediction.updated_at;
      return;
    end if;

    v_previous_status := v_prediction.status;
    v_previous_version := v_prediction.version;
    v_operation := 'update';

    update public.predictions p
    set
      home_prediction = p_home_prediction,
      away_prediction = p_away_prediction,
      status = 'draft',
      submitted_at = null,
      updated_at = v_now,
      version = p.version + 1
    where p.id = v_prediction.id
    returning p.* into v_prediction;
  else
    v_previous_status := null;
    v_previous_version := null;
    v_operation := 'insert';

    insert into public.predictions (
      league_id, user_id, match_id, home_prediction, away_prediction,
      league_round_id, league_member_id, status, submitted_at, locked_at,
      source, version, created_at, updated_at, submitted_version,
      official_submitted_at
    )
    values (
      v_league_id, v_user_id, p_match_id, p_home_prediction, p_away_prediction,
      p_league_round_id, v_member_id, 'draft', null, null,
      'standard', 1, v_now, v_now, null, null
    )
    returning * into v_prediction;
  end if;

  insert into public.prediction_versions (
    prediction_id, version, home_prediction, away_prediction, status, source,
    changed_by_user_id, changed_by_member_id, changed_at, metadata
  )
  values (
    v_prediction.id, v_prediction.version, v_prediction.home_prediction,
    v_prediction.away_prediction, v_prediction.status, v_prediction.source,
    v_user_id, v_member_id, v_now,
    jsonb_build_object(
      'command', 'SavePredictionDraft',
      'reason', 'workspace_save',
      'operation', v_operation,
      'league_id', v_league_id,
      'league_round_id', p_league_round_id,
      'match_id', p_match_id,
      'previous_status', v_previous_status,
      'new_status', v_prediction.status,
      'previous_version', v_previous_version,
      'new_version', v_prediction.version,
      'official_submitted_version', v_prediction.submitted_version
    )
  );

  return query
  select v_prediction.id, v_prediction.league_round_id,
         v_prediction.league_member_id, v_prediction.match_id,
         v_prediction.home_prediction, v_prediction.away_prediction,
         v_prediction.status, v_prediction.version, v_prediction.updated_at;
end;
$function$;

create or replace function public.submit_round_predictions_rpc(
  p_league_round_id uuid
)
returns table (
  league_round_id uuid,
  league_member_id uuid,
  required_prediction_count integer,
  submitted_prediction_count integer,
  already_submitted boolean,
  submitted_at timestamptz
)
language plpgsql
security definer
set search_path to public, pg_temp
as $function$
declare
  v_user_id uuid;
  v_league_id uuid;
  v_fantagol_round_id uuid;
  v_round_status text;
  v_round_enabled boolean;
  v_opens_at timestamptz;
  v_lock_at timestamptz;
  v_member_id uuid;
  v_required_count integer;
  v_present_count integer;
  v_invalid_count integer;
  v_unconfirmed_count integer;
  v_submitted_at timestamptz;
  v_now timestamptz := clock_timestamp();
begin
  v_user_id := auth.uid();

  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTHENTICATION_REQUIRED';
  end if;

  select lr.league_id, lr.fantagol_round_id, lr.status, lr.enabled,
         fr.opens_at, fr.lock_at
  into v_league_id, v_fantagol_round_id, v_round_status, v_round_enabled,
       v_opens_at, v_lock_at
  from public.league_rounds lr
  join public.fantagol_rounds fr on fr.id = lr.fantagol_round_id
  where lr.id = p_league_round_id
  for update of lr;

  if not found then
    raise exception using errcode = 'P0001', message = 'LEAGUE_ROUND_NOT_FOUND';
  end if;

  if not v_round_enabled then
    raise exception using errcode = 'P0001', message = 'LEAGUE_ROUND_DISABLED';
  end if;

  if v_round_status <> 'predictions_open' or v_now < v_opens_at then
    raise exception using errcode = 'P0001', message = 'PREDICTION_WINDOW_NOT_OPEN';
  end if;

  if v_now >= v_lock_at then
    raise exception using errcode = 'P0001', message = 'PREDICTION_WINDOW_CLOSED';
  end if;

  select lm.id into v_member_id
  from public.league_members lm
  where lm.league_id = v_league_id
    and lm.user_id = v_user_id
    and lm.status = 'active'
  limit 1;

  if v_member_id is null then
    raise exception using errcode = 'P0001', message = 'ACTIVE_LEAGUE_MEMBERSHIP_REQUIRED';
  end if;

  PERFORM public.assert_current_operational_round_internal(p_league_round_id);
  perform pg_advisory_xact_lock(
    hashtextextended('submit:' || p_league_round_id::text || ':' || v_member_id::text, 0)
  );

  select count(*)::integer into v_required_count
  from public.fantagol_round_matches frm
  where frm.fantagol_round_id = v_fantagol_round_id
    and frm.removed_at is null
    and frm.required;

  perform 1
  from public.predictions p
  where p.league_round_id = p_league_round_id
    and p.league_member_id = v_member_id
  for update;

  select
    count(*) filter (where frm.match_id is not null)::integer,
    count(*) filter (
      where frm.match_id is null or p.status in ('locked', 'void')
    )::integer,
    count(*) filter (
      where p.submitted_version is null
         or p.submitted_version <> p.version
         or p.status <> 'submitted'
    )::integer
  into v_present_count, v_invalid_count, v_unconfirmed_count
  from public.predictions p
  left join public.fantagol_round_matches frm
    on frm.fantagol_round_id = v_fantagol_round_id
   and frm.match_id = p.match_id
   and frm.removed_at is null
   and frm.required
  where p.league_round_id = p_league_round_id
    and p.league_member_id = v_member_id;

  if v_invalid_count > 0 then
    raise exception using errcode = 'P0001', message = 'ROUND_PREDICTION_SET_INVALID';
  end if;

  if v_present_count <> v_required_count then
    raise exception using
      errcode = 'P0001',
      message = 'ROUND_PREDICTIONS_INCOMPLETE',
      detail = format('required=%s present=%s', v_required_count, v_present_count);
  end if;

  if v_unconfirmed_count = 0 then
    select min(p.official_submitted_at)
    into v_submitted_at
    from public.predictions p
    where p.league_round_id = p_league_round_id
      and p.league_member_id = v_member_id;

    return query
    select p_league_round_id, v_member_id, v_required_count,
           v_required_count, true, v_submitted_at;
    return;
  end if;

  with changed as (
    update public.predictions p
    set
      status = 'submitted',
      submitted_at = v_now,
      official_submitted_at = v_now,
      updated_at = v_now,
      version = p.version + 1,
      submitted_version = p.version + 1
    where p.league_round_id = p_league_round_id
      and p.league_member_id = v_member_id
    returning p.*
  )
  insert into public.prediction_versions (
    prediction_id, version, home_prediction, away_prediction, status, source,
    changed_by_user_id, changed_by_member_id, changed_at, metadata
  )
  select
    c.id, c.version, c.home_prediction, c.away_prediction, c.status, c.source,
    v_user_id, v_member_id, v_now,
    jsonb_build_object(
      'command', 'SubmitRoundPredictions',
      'reason', case when c.submitted_version = 2 then 'initial_submit' else 'resubmit' end,
      'operation', 'official_snapshot',
      'league_id', v_league_id,
      'league_round_id', p_league_round_id,
      'match_id', c.match_id,
      'new_status', 'submitted',
      'official_submitted_version', c.submitted_version
    )
  from changed c;

  return query
  select p_league_round_id, v_member_id, v_required_count,
         v_required_count, false, v_now;
end;
$function$;

create or replace function public.save_strategy_draft_rpc(
  p_league_round_id uuid,
  p_mode text,
  p_payload jsonb
)
returns table (
  strategy_id uuid,
  league_fixture_id uuid,
  mode text,
  workspace_version integer,
  strategy_status text,
  submitted_version integer,
  has_unconfirmed_changes boolean,
  saved_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_now timestamptz := now();

  v_user_id uuid := auth.uid();
  v_league_id uuid;
  v_member_id uuid;

  v_round_status text;
  v_round_opens_at timestamptz;
  v_round_lock_at timestamptz;
  v_match_set_version integer;

  v_fixture_id uuid;
  v_fixture_is_bye boolean;

  v_strategy public.strategies%rowtype;
  v_next_version integer;
begin
  if v_user_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'USER_NOT_AUTHENTICATED';
  end if;

  if p_league_round_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_ROUND_REQUIRED';
  end if;

  if p_mode is null or p_mode not in ('fantacalcio', 'one_to_one') then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_MODE_INVALID';
  end if;

  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_PAYLOAD_INVALID';
  end if;

  if jsonb_typeof(p_payload -> 'schema_version') <> 'number'
     or (p_payload ->> 'schema_version')::integer <> 1 then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_PAYLOAD_SCHEMA_VERSION_INVALID';
  end if;

  -- Drafts may be incomplete, but present containers must use the canonical type.
  if p_mode = 'fantacalcio'
     and p_payload ? 'allocations'
     and jsonb_typeof(p_payload -> 'allocations') <> 'array' then
    raise exception using
      errcode = 'P0001',
      message = 'FANTACALCIO_STRATEGY_STRUCTURE_INVALID';
  end if;

  if p_mode = 'one_to_one'
     and p_payload ? 'pairings'
     and jsonb_typeof(p_payload -> 'pairings') <> 'array' then
    raise exception using
      errcode = 'P0001',
      message = 'ONE_TO_ONE_MATRIX_STRUCTURE_INVALID';
  end if;

  select
    lr.league_id,
    lr.status,
    fr.opens_at,
    fr.lock_at,
    fr.official_match_set_version
  into
    v_league_id,
    v_round_status,
    v_round_opens_at,
    v_round_lock_at,
    v_match_set_version
  from public.league_rounds lr
  join public.fantagol_rounds fr
    on fr.id = lr.fantagol_round_id
  where lr.id = p_league_round_id
    and lr.enabled = true
  for update of lr;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_ROUND_NOT_FOUND';
  end if;

  if v_match_set_version is null then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_OFFICIAL_MATCH_SET_NOT_FOUND';
  end if;

  if v_round_status <> 'predictions_open'
     or v_now < v_round_opens_at
     or v_now >= v_round_lock_at then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_WINDOW_CLOSED';
  end if;

  select lm.id
  into v_member_id
  from public.league_members lm
  where lm.league_id = v_league_id
    and lm.user_id = v_user_id
    and lm.status = 'active'
  limit 1;

  if v_member_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_ACTIVE_MEMBERSHIP_REQUIRED';
  end if;

  PERFORM public.assert_current_operational_round_internal(p_league_round_id);
  perform pg_advisory_xact_lock(
    hashtextextended(
      'strategy-save:'
      || p_league_round_id::text
      || ':'
      || v_member_id::text
      || ':'
      || p_mode,
      0
    )
  );

  select
    lf.id,
    lf.is_bye
  into
    v_fixture_id,
    v_fixture_is_bye
  from public.league_fixtures lf
  join public.league_schedule_versions lsv
    on lsv.id = lf.schedule_version_id
   and lsv.active = true
  where lf.league_id = v_league_id
    and lf.league_round_id = p_league_round_id
    and lf.mode = p_mode
    and (
      lf.home_member_id = v_member_id
      or lf.away_member_id = v_member_id
    );

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_ACTIVE_FIXTURE_NOT_FOUND';
  end if;

  if v_fixture_is_bye then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_NOT_REQUIRED_FOR_BYE';
  end if;

  select s.*
  into v_strategy
  from public.strategies s
  where s.league_fixture_id = v_fixture_id
    and s.league_member_id = v_member_id
  for update;

  if found then
    if v_strategy.status in ('locked', 'void') then
      raise exception using
        errcode = 'P0001',
        message = 'STRATEGY_NOT_EDITABLE';
    end if;

    v_next_version := v_strategy.version + 1;

    update public.strategies s
    set
      status = 'draft',
      source = 'standard',
      version = v_next_version
    where s.id = v_strategy.id
    returning s.*
    into v_strategy;
  else
    insert into public.strategies (
      league_id,
      league_round_id,
      league_member_id,
      user_id,
      league_fixture_id,
      status,
      source,
      version
    )
    values (
      v_league_id,
      p_league_round_id,
      v_member_id,
      v_user_id,
      v_fixture_id,
      'draft',
      'standard',
      1
    )
    returning *
    into v_strategy;

    v_next_version := 1;
  end if;

  insert into public.strategy_versions (
    strategy_id,
    version,
    payload,
    status,
    source,
    changed_by_user_id,
    changed_by_member_id,
    changed_at,
    metadata
  )
  values (
    v_strategy.id,
    v_next_version,
    p_payload,
    'draft',
    'standard',
    v_user_id,
    v_member_id,
    v_now,
    jsonb_build_object(
      'operation', 'workspace_save',
      'mode', p_mode,
      'schema_version', 1,
      'match_set_version', v_match_set_version,
      'league_round_id', p_league_round_id,
      'league_fixture_id', v_fixture_id,
      'official_submitted_version', v_strategy.submitted_version
    )
  );

  return query
  select
    v_strategy.id,
    v_fixture_id,
    p_mode,
    v_next_version,
    'draft'::text,
    v_strategy.submitted_version,
    (
      v_strategy.submitted_version is not null
      and v_strategy.submitted_version <> v_next_version
    ),
    v_now;
end;
$function$;

create or replace function public.submit_strategy_rpc(
  p_league_round_id uuid,
  p_mode text
)
returns table (
  strategy_id uuid,
  league_fixture_id uuid,
  mode text,
  workspace_version integer,
  submitted_version integer,
  official_submitted_at timestamptz,
  already_submitted boolean,
  has_unconfirmed_changes boolean
)
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_now timestamptz := now();
  v_user_id uuid := auth.uid();

  v_league_id uuid;
  v_member_id uuid;
  v_round_status text;
  v_round_opens_at timestamptz;
  v_round_lock_at timestamptz;
  v_match_set_version integer;

  v_fixture_id uuid;
  v_fixture_mode text;
  v_fixture_is_bye boolean;

  v_strategy public.strategies%rowtype;
  v_workspace_payload jsonb;
  v_payload_schema_version integer;
  v_new_submitted_version integer;
begin
  if v_user_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'USER_NOT_AUTHENTICATED';
  end if;

  if p_league_round_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_ROUND_REQUIRED';
  end if;

  if p_mode is null or p_mode not in ('fantacalcio', 'one_to_one') then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_MODE_INVALID';
  end if;

  select
    lr.league_id,
    lr.status,
    fr.opens_at,
    fr.lock_at,
    fr.official_match_set_version
  into
    v_league_id,
    v_round_status,
    v_round_opens_at,
    v_round_lock_at,
    v_match_set_version
  from public.league_rounds lr
  join public.fantagol_rounds fr
    on fr.id = lr.fantagol_round_id
  where lr.id = p_league_round_id
    and lr.enabled = true
  for update of lr;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_ROUND_NOT_FOUND';
  end if;

  if v_match_set_version is null then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_OFFICIAL_MATCH_SET_NOT_FOUND';
  end if;

  if v_round_status <> 'predictions_open'
     or v_now < v_round_opens_at
     or v_now >= v_round_lock_at then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_WINDOW_CLOSED';
  end if;

  select lm.id
  into v_member_id
  from public.league_members lm
  where lm.league_id = v_league_id
    and lm.user_id = v_user_id
    and lm.status = 'active'
  limit 1;

  if v_member_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_ACTIVE_MEMBERSHIP_REQUIRED';
  end if;

  PERFORM public.assert_current_operational_round_internal(p_league_round_id);
  perform pg_advisory_xact_lock(
    hashtextextended(
      'strategy-submit:'
      || p_league_round_id::text
      || ':'
      || v_member_id::text
      || ':'
      || p_mode,
      0
    )
  );

  select
    lf.id,
    lf.mode,
    lf.is_bye
  into
    v_fixture_id,
    v_fixture_mode,
    v_fixture_is_bye
  from public.league_fixtures lf
  join public.league_schedule_versions lsv
    on lsv.id = lf.schedule_version_id
   and lsv.active = true
  where lf.league_id = v_league_id
    and lf.league_round_id = p_league_round_id
    and lf.mode = p_mode
    and (
      lf.home_member_id = v_member_id
      or lf.away_member_id = v_member_id
    );

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_ACTIVE_FIXTURE_NOT_FOUND';
  end if;

  if v_fixture_is_bye then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_NOT_REQUIRED_FOR_BYE';
  end if;

  select s.*
  into v_strategy
  from public.strategies s
  where s.league_fixture_id = v_fixture_id
    and s.league_member_id = v_member_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_WORKSPACE_NOT_FOUND';
  end if;

  if v_strategy.status in ('locked', 'void') then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_NOT_SUBMITTABLE';
  end if;

  if v_strategy.submitted_version is not null
     and v_strategy.submitted_version = v_strategy.version
     and v_strategy.status = 'submitted' then
    return query
    select
      v_strategy.id,
      v_fixture_id,
      v_fixture_mode,
      v_strategy.version,
      v_strategy.submitted_version,
      v_strategy.official_submitted_at,
      true,
      false;
    return;
  end if;

  select sv.payload
  into v_workspace_payload
  from public.strategy_versions sv
  where sv.strategy_id = v_strategy.id
    and sv.version = v_strategy.version;

  if v_workspace_payload is null then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_WORKSPACE_VERSION_NOT_FOUND';
  end if;

  perform public.validate_strategy_submission_payload(
    v_fixture_mode,
    v_workspace_payload,
    p_league_round_id
  );

  v_payload_schema_version := (v_workspace_payload ->> 'schema_version')::integer;
  v_new_submitted_version := v_strategy.version + 1;

  insert into public.strategy_versions (
    strategy_id,
    version,
    payload,
    status,
    source,
    changed_by_user_id,
    changed_by_member_id,
    changed_at,
    metadata
  )
  values (
    v_strategy.id,
    v_new_submitted_version,
    v_workspace_payload,
    'submitted',
    v_strategy.source,
    v_user_id,
    v_member_id,
    v_now,
    jsonb_build_object(
      'operation',
      case
        when v_strategy.submitted_version is null then 'initial_submit'
        else 'resubmit'
      end,
      'mode', v_fixture_mode,
      'schema_version', v_payload_schema_version,
      'match_set_version', v_match_set_version,
      'workspace_source_version', v_strategy.version,
      'official_submitted_version', v_new_submitted_version,
      'league_round_id', p_league_round_id,
      'league_fixture_id', v_fixture_id
    )
  );

  update public.strategies s
  set
    status = 'submitted',
    version = v_new_submitted_version,
    submitted_version = v_new_submitted_version,
    submitted_at = v_now,
    official_submitted_at = v_now
  where s.id = v_strategy.id
  returning s.*
  into v_strategy;

  return query
  select
    v_strategy.id,
    v_fixture_id,
    v_fixture_mode,
    v_strategy.version,
    v_strategy.submitted_version,
    v_strategy.official_submitted_at,
    false,
    false;
end;
$function$;

-- Historical rows remain readable; only can_edit and prediction_window_state are gated.

CREATE OR REPLACE FUNCTION public.get_my_round_predictions_rpc(
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
  v_r26_current_round_id uuid;
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

  SELECT current_round.league_round_id INTO v_r26_current_round_id
  FROM public.get_my_current_league_round_rpc(v_league_id) AS current_round;
  v_window := case
    when v_r26_current_round_id IS DISTINCT FROM p_league_round_id then 'closed'
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
    (v_r26_current_round_id = p_league_round_id)
    and
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