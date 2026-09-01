-- FANTAGOL MIGRATION 296
-- Match certification receipt identity convergence repair.
--
-- Scope:
--   * preserve exact provider_updated_at receipt binding as primary authority;
--   * add a conservative terminal fallback only when exact identity is absent;
--   * fallback requires one provider, one external match identity, one accepted
--     meaningful MATCH_FINISHED receipt, and exact canonical final-score parity;
--   * no odds acquisition/freeze authority is added;
--   * no match/result/score mutation is performed;
--   * workflow recovery/re-dispatch remains runtime orchestration responsibility.

create or replace function public.resolve_match_certification_receipt_internal(
  p_match_id uuid
)
returns public.live_match_update_receipts
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $function$
declare
  v_match public.matches%rowtype;
  v_receipt public.live_match_update_receipts%rowtype;
  v_candidate_count integer := 0;
  v_provider_count integer := 0;
  v_external_count integer := 0;
begin
  if p_match_id is null then
    return null;
  end if;

  select m.*
    into v_match
  from public.matches m
  where m.id = p_match_id;

  if not found then
    return null;
  end if;

  -- Primary authority remains the historical exact provider timestamp contract.
  select r.*
    into v_receipt
  from public.live_match_update_receipts r
  where r.match_id = p_match_id
    and r.provider_updated_at = v_match.provider_updated_at
  order by r.received_at desc, r.created_at desc, r.id desc
  limit 1;

  if v_receipt.id is not null then
    return v_receipt;
  end if;

  -- Conservative fallback is permitted only for a terminal canonical Match.
  if lower(coalesce(v_match.status, '')) not in ('finished', 'awarded')
     or v_match.home_score is null
     or v_match.away_score is null then
    return null;
  end if;

  -- A fallback is allowed only when the Match has one provider identity
  -- and one provider external-match identity across its persisted receipts.
  select
    count(distinct r.provider_id),
    count(distinct r.external_match_id)
  into
    v_provider_count,
    v_external_count
  from public.live_match_update_receipts r
  where r.match_id = p_match_id;

  if v_provider_count <> 1 or v_external_count <> 1 then
    return null;
  end if;

  -- The authoritative fallback must be the unique accepted terminal-change
  -- receipt whose terminal payload exactly matches the canonical final score.
  select count(*)
    into v_candidate_count
  from public.live_match_update_receipts r
  where r.match_id = p_match_id
    and r.processing_status = 'accepted'
    and r.meaningful_change = true
    and r.change_type = 'MATCH_FINISHED'
    and lower(coalesce(r.normalized_payload->>'status', '')) in ('finished', 'awarded')
    and nullif(r.normalized_payload->>'home_score', '')::integer = v_match.home_score
    and nullif(r.normalized_payload->>'away_score', '')::integer = v_match.away_score;

  if v_candidate_count <> 1 then
    return null;
  end if;

  select r.*
    into v_receipt
  from public.live_match_update_receipts r
  where r.match_id = p_match_id
    and r.processing_status = 'accepted'
    and r.meaningful_change = true
    and r.change_type = 'MATCH_FINISHED'
    and lower(coalesce(r.normalized_payload->>'status', '')) in ('finished', 'awarded')
    and nullif(r.normalized_payload->>'home_score', '')::integer = v_match.home_score
    and nullif(r.normalized_payload->>'away_score', '')::integer = v_match.away_score
  order by r.received_at desc, r.created_at desc, r.id desc
  limit 1;

  return v_receipt;
end;
$function$;

CREATE OR REPLACE FUNCTION public.evaluate_match_certification_readiness_rpc(p_match_id uuid, p_stability_window_seconds integer DEFAULT 300, p_require_official_odds boolean DEFAULT true, p_correlation_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(match_id uuid, certification_state text, source_match_version integer, is_ready boolean, stable_since timestamp with time zone, ready_at timestamp with time zone, blocking_code text, active_certification_id uuid, details jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_match public.matches%rowtype;
  v_state public.match_certification_states%rowtype;
  v_receipt public.live_match_update_receipts%rowtype;
  v_odds public.official_match_odds_snapshots%rowtype;
  v_now timestamptz := clock_timestamp();
  v_stable_since timestamptz;
  v_ready_at timestamptz;
  v_state_name text;
  v_blocking_code text;
  v_blocking_details jsonb := '{}'::jsonb;
  v_details jsonb;
  v_is_ready boolean := false;
begin
  if p_match_id is null then
    raise exception using errcode = '22004', message = 'MATCH_ID_REQUIRED';
  end if;

  if p_stability_window_seconds is null
     or p_stability_window_seconds < 0
     or p_stability_window_seconds > 86400 then
    raise exception using errcode = '22023', message = 'INVALID_STABILITY_WINDOW';
  end if;

  select m.*
    into v_match
  from public.matches m
  where m.id = p_match_id
  for update;

  if not found then
    raise exception using errcode = 'P0002', message = 'MATCH_NOT_FOUND';
  end if;

    v_receipt := public.resolve_match_certification_receipt_internal(p_match_id);

   v_odds :=
     public.get_active_official_match_odds_snapshot_internal(
       p_match_id
     );

   if p_require_official_odds and v_odds.id is not null then
     perform
       public.assert_real_official_odds_source_internal(
         p_match_id,
         v_odds.odds_market_snapshot_id
       );
   end if;

  select s.*
    into v_state
  from public.match_certification_states s
  where s.match_id = p_match_id
  for update;

  if not found then
    insert into public.match_certification_states (
      match_id,
      state,
      source_match_version,
      observed_match_status,
      observed_home_score,
      observed_away_score,
      observed_provider_updated_at,
      observed_finalised_at,
      stability_window_seconds,
      require_official_odds,
      correlation_id
    ) values (
      p_match_id,
      'pending',
      v_match.version,
      v_match.status,
      v_match.home_score,
      v_match.away_score,
      v_match.provider_updated_at,
      v_match.finalised_at,
      p_stability_window_seconds,
      p_require_official_odds,
      p_correlation_id
    )
    returning * into v_state;
  end if;

  -- A new Match version restarts stability unless an already active certificate
  -- proves this exact source version has already been certified.
  if v_state.source_match_version <> v_match.version
     or v_state.observed_match_status is distinct from v_match.status
     or v_state.observed_home_score is distinct from v_match.home_score
     or v_state.observed_away_score is distinct from v_match.away_score
     or v_state.observed_provider_updated_at is distinct from v_match.provider_updated_at then
    v_state.stable_since := null;
    v_state.ready_at := null;
    v_state.certification_started_at := null;
    v_state.blocked_at := null;
    v_state.blocking_code := null;
    v_state.blocking_details := '{}'::jsonb;
  end if;

  if lower(coalesce(v_match.status, '')) not in ('finished', 'awarded') then
    v_state_name := 'not_ready';
    v_blocking_code := 'MATCH_NOT_FINAL';
    v_blocking_details := jsonb_build_object('match_status', v_match.status);

  elsif v_match.home_score is null or v_match.away_score is null then
    v_state_name := 'blocked';
    v_blocking_code := 'FINAL_SCORE_MISSING';
    v_blocking_details := jsonb_build_object(
      'home_score', v_match.home_score,
      'away_score', v_match.away_score
    );

  elsif v_match.home_score < 0 or v_match.away_score < 0 then
    v_state_name := 'blocked';
    v_blocking_code := 'FINAL_SCORE_INVALID';

  elsif v_match.provider_updated_at is null then
    v_state_name := 'blocked';
    v_blocking_code := 'PROVIDER_UPDATED_AT_MISSING';

  elsif v_receipt.id is null then
    v_state_name := 'blocked';
    v_blocking_code := 'MATCH_UPDATE_RECEIPT_MISSING';
    v_blocking_details := jsonb_build_object(
      'provider_updated_at', v_match.provider_updated_at,
      'source_match_version', v_match.version
    );

  elsif p_require_official_odds and v_odds.id is null then
    v_state_name := 'not_ready';
    v_blocking_code := 'OFFICIAL_ODDS_SNAPSHOT_MISSING';

  else
    v_stable_since := coalesce(
      case
        when v_state.source_match_version = v_match.version
         and v_state.observed_match_status is not distinct from v_match.status
         and v_state.observed_home_score is not distinct from v_match.home_score
         and v_state.observed_away_score is not distinct from v_match.away_score
         and v_state.observed_provider_updated_at is not distinct from v_match.provider_updated_at
        then v_state.stable_since
      end,
      greatest(
        coalesce(v_match.finalised_at, '-infinity'::timestamptz),
        coalesce(v_match.provider_updated_at, '-infinity'::timestamptz),
        v_now
      )
    );

    v_ready_at := v_stable_since + make_interval(secs => p_stability_window_seconds);

    if v_now < v_ready_at then
      v_state_name := 'stabilizing';
      v_blocking_code := 'STABILITY_WINDOW_OPEN';
      v_blocking_details := jsonb_build_object(
        'seconds_remaining', greatest(
          0,
          ceil(extract(epoch from (v_ready_at - v_now)))::integer
        )
      );
    else
      v_state_name := 'ready';
      v_blocking_code := null;
      v_blocking_details := '{}'::jsonb;
      v_is_ready := true;
    end if;
  end if;

  if v_state_name = 'blocked' then
    v_state.blocked_at := coalesce(v_state.blocked_at, v_now);
  else
    v_state.blocked_at := null;
  end if;

  if v_state_name not in ('stabilizing', 'ready') then
    v_stable_since := null;
    v_ready_at := null;
  end if;

  v_details := jsonb_build_object(
    'evaluated_at', v_now,
    'match_status', v_match.status,
    'home_score', v_match.home_score,
    'away_score', v_match.away_score,
    'provider_updated_at', v_match.provider_updated_at,
    'finalised_at', v_match.finalised_at,
    'source_match_version', v_match.version,
    'source_receipt_id', v_receipt.id,
    'official_odds_snapshot_id', v_odds.id,
    'official_odds_required', p_require_official_odds,
    'stability_window_seconds', p_stability_window_seconds,
    'stable_since', v_stable_since,
    'ready_at', v_ready_at
  );

  update public.match_certification_states s
  set state = v_state_name,
      source_match_version = v_match.version,
      observed_match_status = v_match.status,
      observed_home_score = v_match.home_score,
      observed_away_score = v_match.away_score,
      observed_provider_updated_at = v_match.provider_updated_at,
      observed_finalised_at = v_match.finalised_at,
      readiness_evaluated_at = v_now,
      stable_since = v_stable_since,
      ready_at = v_ready_at,
      certification_started_at = case
        when v_state_name = 'certifying' then s.certification_started_at
        else null
      end,
      blocked_at = case when v_state_name = 'blocked' then v_state.blocked_at else null end,
      stability_window_seconds = p_stability_window_seconds,
      require_official_odds = p_require_official_odds,
      blocking_code = v_blocking_code,
      blocking_details = v_blocking_details,
      readiness_details = v_details,
      correlation_id = coalesce(p_correlation_id, s.correlation_id)
  where s.match_id = p_match_id
  returning s.* into v_state;

  return query
  select
    p_match_id,
    v_state.state,
    v_state.source_match_version,
    v_is_ready,
    v_state.stable_since,
    v_state.ready_at,
    v_state.blocking_code,
    v_state.active_certification_id,
    v_state.readiness_details || jsonb_build_object(
      'blocking_details', v_state.blocking_details
    );
end;
$function$;

CREATE OR REPLACE FUNCTION public.certify_match_result_rpc(p_match_id uuid, p_stability_window_seconds integer DEFAULT 300, p_require_official_odds boolean DEFAULT true, p_engine_version text DEFAULT 'match-result-certification-v1'::text, p_policy_version text DEFAULT 'match-result-certification-policy-v1'::text, p_certified_by text DEFAULT 'system'::text, p_correlation_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(certification_id uuid, match_id uuid, certification_version integer, certification_status text, certification_hash text, source_match_version integer, created boolean, superseded_certification_id uuid)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_readiness record;
  v_match public.matches%rowtype;
  v_state public.match_certification_states%rowtype;
  v_receipt public.live_match_update_receipts%rowtype;
  v_odds public.official_match_odds_snapshots%rowtype;
  v_existing public.match_result_certifications%rowtype;
  v_new public.match_result_certifications%rowtype;
  v_superseded_id uuid;
  v_next_version integer;
  v_input_snapshot jsonb;
  v_result_snapshot jsonb;
  v_evidence_snapshot jsonb;
  v_input_hash text;
  v_result_hash text;
  v_certification_hash text;
begin
  if p_match_id is null then
    raise exception using errcode = '22004', message = 'MATCH_ID_REQUIRED';
  end if;

  if btrim(coalesce(p_engine_version, '')) = '' then
    raise exception using errcode = '22023', message = 'ENGINE_VERSION_REQUIRED';
  end if;

  if btrim(coalesce(p_policy_version, '')) = '' then
    raise exception using errcode = '22023', message = 'POLICY_VERSION_REQUIRED';
  end if;

  if btrim(coalesce(p_certified_by, '')) = '' then
    raise exception using errcode = '22023', message = 'CERTIFIED_BY_REQUIRED';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_match_id::text, 53001));

  select *
    into v_readiness
  from public.evaluate_match_certification_readiness_rpc(
    p_match_id,
    p_stability_window_seconds,
    p_require_official_odds,
    p_correlation_id
  );

  if not coalesce(v_readiness.is_ready, false) then
    raise exception using
      errcode = 'P0001',
      message = 'MATCH_NOT_READY_FOR_CERTIFICATION',
      detail = coalesce(v_readiness.blocking_code, 'UNKNOWN');
  end if;

  select m.* into v_match
  from public.matches m
  where m.id = p_match_id
  for update;

  select s.* into v_state
  from public.match_certification_states s
  where s.match_id = p_match_id
  for update;

    v_receipt := public.resolve_match_certification_receipt_internal(p_match_id);

   v_odds :=
     public.get_active_official_match_odds_snapshot_internal(
       p_match_id
     );

   if p_require_official_odds and v_odds.id is not null then
     perform
       public.assert_real_official_odds_source_internal(
         p_match_id,
         v_odds.odds_market_snapshot_id
       );
   end if;

  if v_receipt.id is null then
    raise exception using errcode = 'P0001', message = 'MATCH_UPDATE_RECEIPT_MISSING';
  end if;

  if p_require_official_odds and v_odds.id is null then
    raise exception using errcode = 'P0001', message = 'OFFICIAL_ODDS_SNAPSHOT_MISSING';
  end if;

  update public.match_certification_states s
  set state = 'certifying',
      certification_started_at = clock_timestamp(),
      blocking_code = null,
      blocking_details = '{}'::jsonb,
      correlation_id = coalesce(p_correlation_id, s.correlation_id)
  where s.match_id = p_match_id
  returning s.* into v_state;

  v_input_snapshot := jsonb_build_object(
    'schema_version', 1,
    'match_id', v_match.id,
    'source_match_version', v_match.version,
    'match_status', v_match.status,
    'home_score', v_match.home_score,
    'away_score', v_match.away_score,
    'provider_updated_at', v_match.provider_updated_at,
    'match_finalised_at', v_match.finalised_at,
    'source_receipt_id', v_receipt.id,
    'provider_id', v_receipt.provider_id,
    'provider_payload_hash', v_receipt.payload_hash,
    'official_odds_snapshot_id', v_odds.id,
    'official_odds_hash', v_odds.official_hash,
    'stability_window_seconds', p_stability_window_seconds,
    'stable_since', v_state.stable_since,
    'engine_version', p_engine_version,
    'policy_version', p_policy_version
  );

  v_result_snapshot := jsonb_build_object(
    'match_id', v_match.id,
    'match_status', v_match.status,
    'home_score', v_match.home_score,
    'away_score', v_match.away_score,
    'result_sign', public.derive_score_sign(v_match.home_score, v_match.away_score),
    'over_under_2_5', public.derive_over_under_2_5(v_match.home_score, v_match.away_score),
    'goal_no_goal', public.derive_goal_no_goal(v_match.home_score, v_match.away_score)
  );

  v_evidence_snapshot := jsonb_build_object(
    'receipt', jsonb_build_object(
      'id', v_receipt.id,
      'provider_id', v_receipt.provider_id,
      'external_match_id', v_receipt.external_match_id,
      'provider_updated_at', v_receipt.provider_updated_at,
      'received_at', v_receipt.received_at,
      'payload_hash', v_receipt.payload_hash,
      'change_type', v_receipt.change_type
    ),
    'official_odds', case
      when v_odds.id is null then null
      else jsonb_build_object(
        'id', v_odds.id,
        'odds_market_snapshot_id', v_odds.odds_market_snapshot_id,
        'frozen_at', v_odds.frozen_at,
        'freeze_reason', v_odds.freeze_reason,
        'policy_version', v_odds.policy_version,
        'official_hash', v_odds.official_hash
      )
    end,
    'readiness', v_state.readiness_details
  );

  v_input_hash := public.compute_jsonb_sha256(v_input_snapshot);
  v_result_hash := public.compute_jsonb_sha256(v_result_snapshot);
  v_certification_hash := public.compute_jsonb_sha256(
    jsonb_build_object(
      'match_id', v_match.id,
      'source_match_version', v_match.version,
      'input_hash', v_input_hash,
      'result_hash', v_result_hash,
      'engine_version', p_engine_version,
      'policy_version', p_policy_version,
      'schema_version', 1
    )
  );

  select c.* into v_existing
  from public.match_result_certifications c
  where c.match_id = p_match_id
    and c.status = 'official'
  for update;

  if found
     and v_existing.source_match_version = v_match.version
     and v_existing.certification_hash = v_certification_hash then
    update public.match_certification_states s
    set state = 'certified',
        active_certification_id = v_existing.id,
        last_certification_version = v_existing.certification_version,
        certified_at = v_existing.certified_at,
        certification_started_at = null,
        blocking_code = null,
        blocking_details = '{}'::jsonb
    where s.match_id = p_match_id;

    return query
    select
      v_existing.id,
      v_existing.match_id,
      v_existing.certification_version,
      v_existing.status,
      v_existing.certification_hash,
      v_existing.source_match_version,
      false,
      null::uuid;
    return;
  end if;

  if found then
    v_superseded_id := v_existing.id;

    update public.match_result_certifications c
    set status = 'superseded',
        superseded_at = clock_timestamp(),
        supersede_reason = 'new_canonical_match_version_certified'
    where c.id = v_existing.id;
  end if;

  select coalesce(max(c.certification_version), 0) + 1
    into v_next_version
  from public.match_result_certifications c
  where c.match_id = p_match_id;

  insert into public.match_result_certifications (
    match_id,
    certification_version,
    status,
    source_match_version,
    source_receipt_id,
    official_odds_snapshot_id,
    match_status,
    home_score,
    away_score,
    result_sign,
    over_under_2_5,
    goal_no_goal,
    provider_id,
    provider_updated_at,
    provider_payload_hash,
    match_finalised_at,
    stability_window_seconds,
    stable_since,
    snapshot_schema_version,
    engine_version,
    policy_version,
    input_snapshot,
    result_snapshot,
    evidence_snapshot,
    input_hash,
    result_hash,
    certification_hash,
    certified_by,
    correlation_id
  ) values (
    p_match_id,
    v_next_version,
    'official',
    v_match.version,
    v_receipt.id,
    v_odds.id,
    v_match.status,
    v_match.home_score,
    v_match.away_score,
    public.derive_score_sign(v_match.home_score, v_match.away_score),
    public.derive_over_under_2_5(v_match.home_score, v_match.away_score),
    public.derive_goal_no_goal(v_match.home_score, v_match.away_score),
    v_receipt.provider_id,
    v_match.provider_updated_at,
    v_receipt.payload_hash,
    v_match.finalised_at,
    p_stability_window_seconds,
    v_state.stable_since,
    1,
    p_engine_version,
    p_policy_version,
    v_input_snapshot,
    v_result_snapshot,
    v_evidence_snapshot,
    v_input_hash,
    v_result_hash,
    v_certification_hash,
    p_certified_by,
    p_correlation_id
  )
  returning * into v_new;

  if v_superseded_id is not null then
    update public.match_result_certifications c
    set superseded_by_certification_id = v_new.id
    where c.id = v_superseded_id;
  end if;

  update public.match_certification_states s
  set state = 'certified',
      active_certification_id = v_new.id,
      last_certification_version = v_new.certification_version,
      certified_at = v_new.certified_at,
      certification_started_at = null,
      blocking_code = null,
      blocking_details = '{}'::jsonb,
      readiness_details = s.readiness_details || jsonb_build_object(
        'certification_id', v_new.id,
        'certification_version', v_new.certification_version,
        'certification_hash', v_new.certification_hash
      )
  where s.match_id = p_match_id;

  return query
  select
    v_new.id,
    v_new.match_id,
    v_new.certification_version,
    v_new.status,
    v_new.certification_hash,
    v_new.source_match_version,
    true,
    v_superseded_id;
end;
$function$;