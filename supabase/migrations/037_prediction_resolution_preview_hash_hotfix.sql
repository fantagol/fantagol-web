-- ============================================================================
-- FANTAGOL
-- Migration 037: Prediction Resolution Preview Hash Hotfix
--
-- Fix:
--   pgcrypto is installed in the extensions schema.
--   Qualify digest() explicitly inside the SECURITY DEFINER RPC.
-- ============================================================================

begin;

create or replace function public.build_points_pure_calculation_run_rpc(
  p_league_round_id uuid,
  p_surprise_candidates jsonb default '{}'::jsonb,
  p_engine_version text default 'prediction-resolution-v1',
  p_created_by_member_id uuid default null
)
returns table (
  calculation_run_id uuid,
  league_round_id uuid,
  run_version integer,
  calculation_status text,
  member_count integer,
  match_count integer,
  result_count integer,
  input_hash text,
  output_hash text
)
language plpgsql
security definer
set search_path to public, pg_temp
as $function$
declare
  v_round public.league_rounds%rowtype;
  v_fantagol_round public.fantagol_rounds%rowtype;
  v_profile public.league_scoring_profiles%rowtype;
  v_run public.round_calculation_runs%rowtype;

  v_run_version integer;
  v_match_set_version integer;
  v_member_count integer;
  v_match_count integer;
  v_result_count integer;

  v_input_snapshot jsonb;
  v_output_snapshot jsonb;
  v_input_hash text;
  v_output_hash text;
  v_preview_hash text;

  v_member record;
  v_match record;
  v_prediction record;
  v_score jsonb;

  v_decision text;
  v_included boolean;
  v_missing boolean;
  v_void boolean;
  v_prediction_sign text;
  v_surprise_candidate boolean;
  v_phase text;
begin
  if p_league_round_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_ROUND_REQUIRED';
  end if;

  if nullif(btrim(p_engine_version), '') is null then
    raise exception using
      errcode = 'P0001',
      message = 'ENGINE_VERSION_REQUIRED';
  end if;

  if p_surprise_candidates is null
     or jsonb_typeof(p_surprise_candidates) <> 'object' then
    raise exception using
      errcode = 'P0001',
      message = 'SURPRISE_CANDIDATES_INVALID';
  end if;

  select lr.*
  into v_round
  from public.league_rounds lr
  where lr.id = p_league_round_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_ROUND_NOT_FOUND';
  end if;

  if not v_round.enabled then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_ROUND_DISABLED';
  end if;

  if v_round.status in ('scheduled', 'predictions_open', 'cancelled', 'archived') then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_ROUND_NOT_CALCULABLE';
  end if;

  select fr.*
  into v_fantagol_round
  from public.fantagol_rounds fr
  where fr.id = v_round.fantagol_round_id;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'FANTAGOL_ROUND_NOT_FOUND';
  end if;

  select lsp.*
  into v_profile
  from public.league_scoring_profiles lsp
  where lsp.league_id = v_round.league_id
    and lsp.active = true
  order by lsp.version desc
  limit 1;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'ACTIVE_SCORING_PROFILE_NOT_FOUND';
  end if;

  v_match_set_version :=
    coalesce(v_fantagol_round.official_match_set_version, 1);

  perform pg_advisory_xact_lock(
    hashtextextended('points-pure-run:' || p_league_round_id::text, 0)
  );

  select coalesce(max(rcr.run_version), 0) + 1
  into v_run_version
  from public.round_calculation_runs rcr
  where rcr.league_round_id = p_league_round_id;

  select count(*)::integer
  into v_member_count
  from public.league_members lm
  where lm.league_id = v_round.league_id
    and lm.status = 'active';

  select count(*)::integer
  into v_match_count
  from public.fantagol_round_matches frm
  where frm.fantagol_round_id = v_round.fantagol_round_id
    and frm.removed_at is null;

  if v_member_count = 0 then
    raise exception using
      errcode = 'P0001',
      message = 'NO_ACTIVE_LEAGUE_MEMBERS';
  end if;

  if v_match_count = 0 then
    raise exception using
      errcode = 'P0001',
      message = 'ROUND_MATCH_SET_EMPTY';
  end if;

  v_input_snapshot := jsonb_build_object(
    'schema_version', 1,
    'engine_version', p_engine_version,
    'league_id', v_round.league_id,
    'league_round_id', v_round.id,
    'league_round_version', v_round.version,
    'fantagol_round_id', v_round.fantagol_round_id,
    'fantagol_round_version', v_fantagol_round.version,
    'match_set_version', v_match_set_version,
    'scoring_profile_id', v_profile.id,
    'scoring_profile_version', v_profile.version,
    'surprise_candidates', p_surprise_candidates
  );

  insert into public.round_calculation_runs (
    league_round_id,
    run_version,
    status,
    match_set_version,
    scoring_profile_id,
    scoring_profile_version,
    engine_version,
    snapshot_schema_version,
    input_snapshot,
    output_snapshot,
    standings_snapshot,
    created_by_member_id
  )
  values (
    v_round.id,
    v_run_version,
    'building',
    v_match_set_version,
    v_profile.id,
    v_profile.version,
    p_engine_version,
    1,
    v_input_snapshot,
    '{}'::jsonb,
    '{}'::jsonb,
    p_created_by_member_id
  )
  returning * into v_run;

  for v_member in
    select lm.id as league_member_id
    from public.league_members lm
    where lm.league_id = v_round.league_id
      and lm.status = 'active'
    order by lm.id
  loop
    for v_match in
      select
        frm.match_id,
        frm.slot_number,
        m.status as match_status,
        m.home_score,
        m.away_score,
        m.version as match_version,
        m.provider_updated_at,
        m.finalised_at
      from public.fantagol_round_matches frm
      join public.matches m
        on m.id = frm.match_id
      where frm.fantagol_round_id = v_round.fantagol_round_id
        and frm.removed_at is null
      order by frm.slot_number
    loop
      select coalesce(lrmd.decision, 'included')
      into v_decision
      from public.league_round_match_decisions lrmd
      where lrmd.league_round_id = v_round.id
        and lrmd.match_id = v_match.match_id;

      v_decision := coalesce(v_decision, 'included');
      v_included := v_decision in ('included', 'postponed_reopened');

      select
        p.id as prediction_id,
        p.submitted_version as prediction_version,
        p.status as current_prediction_status,
        pv.status as snapshot_status,
        pv.source as snapshot_source,
        pv.home_prediction,
        pv.away_prediction
      into v_prediction
      from public.predictions p
      join public.prediction_versions pv
        on pv.prediction_id = p.id
       and pv.version = p.submitted_version
      where p.league_round_id = v_round.id
        and p.league_member_id = v_member.league_member_id
        and p.match_id = v_match.match_id
        and p.submitted_version is not null
      limit 1;

      v_missing := not found;
      v_void := false;

      if not v_missing then
        v_void :=
          v_prediction.current_prediction_status = 'void'
          or v_prediction.snapshot_status = 'void';

        v_prediction_sign := public.derive_score_sign(
          v_prediction.home_prediction,
          v_prediction.away_prediction
        );

        v_surprise_candidate :=
          coalesce(
            (p_surprise_candidates -> v_match.match_id::text)
              ? v_prediction_sign,
            false
          );
      else
        v_prediction_sign := null;
        v_surprise_candidate := false;
      end if;

      v_score := public.calculate_prediction_score(
        v_profile.id,
        case when v_missing then null else v_prediction.home_prediction end,
        case when v_missing then null else v_prediction.away_prediction end,
        v_match.home_score,
        v_match.away_score,
        v_match.match_status,
        v_surprise_candidate,
        v_included,
        v_missing,
        v_void,
        false
      );

      v_phase := v_score ->> 'result_phase';

      insert into public.prediction_score_runtime_results (
        calculation_run_id,
        league_round_id,
        league_member_id,
        match_id,
        prediction_id,
        prediction_version,

        match_status,
        result_phase,
        provisional,
        included,
        missing,
        void,

        home_prediction,
        away_prediction,
        home_score,
        away_score,

        predicted_sign,
        real_sign,
        predicted_over_under,
        real_over_under,
        predicted_goal_no_goal,
        real_goal_no_goal,

        is_exact,
        is_sign,
        is_over_under,
        is_goal_no_goal,

        surprise_candidate,
        is_surprise,
        is_goal_show,
        is_grand_slam,
        is_opposite_sign,
        is_cantonata,

        exact_points,
        sign_points,
        over_under_points,
        goal_no_goal_points,
        surprise_points,
        goal_show_points,
        grand_slam_points,
        opposite_sign_points,
        cantonata_points,
        base_total,

        scoring_profile_id,
        scoring_profile_version,
        engine_version,
        calculated_at,
        details
      )
      values (
        v_run.id,
        v_round.id,
        v_member.league_member_id,
        v_match.match_id,
        case when v_missing then null else v_prediction.prediction_id end,
        case when v_missing then null else v_prediction.prediction_version end,

        v_match.match_status,
        v_phase,
        (v_score ->> 'provisional')::boolean,
        v_included,
        v_missing,
        v_void,

        case when v_missing then null else v_prediction.home_prediction end,
        case when v_missing then null else v_prediction.away_prediction end,
        v_match.home_score,
        v_match.away_score,

        v_score ->> 'predicted_sign',
        v_score ->> 'real_sign',
        v_score ->> 'predicted_over_under',
        v_score ->> 'real_over_under',
        v_score ->> 'predicted_goal_no_goal',
        v_score ->> 'real_goal_no_goal',

        coalesce((v_score ->> 'is_exact')::boolean, false),
        coalesce((v_score ->> 'is_sign')::boolean, false),
        coalesce((v_score ->> 'is_over_under')::boolean, false),
        coalesce((v_score ->> 'is_goal_no_goal')::boolean, false),

        v_surprise_candidate,
        coalesce((v_score ->> 'is_surprise')::boolean, false),
        coalesce((v_score ->> 'is_goal_show')::boolean, false),
        coalesce((v_score ->> 'is_grand_slam')::boolean, false),
        coalesce((v_score ->> 'is_opposite_sign')::boolean, false),
        coalesce((v_score ->> 'is_cantonata')::boolean, false),

        coalesce((v_score ->> 'exact_points')::numeric, 0),
        coalesce((v_score ->> 'sign_points')::numeric, 0),
        coalesce((v_score ->> 'over_under_points')::numeric, 0),
        coalesce((v_score ->> 'goal_no_goal_points')::numeric, 0),
        coalesce((v_score ->> 'surprise_points')::numeric, 0),
        coalesce((v_score ->> 'goal_show_points')::numeric, 0),
        coalesce((v_score ->> 'grand_slam_points')::numeric, 0),
        coalesce((v_score ->> 'opposite_sign_points')::numeric, 0),
        coalesce((v_score ->> 'cantonata_points')::numeric, 0),
        coalesce((v_score ->> 'base_total')::numeric, 0),

        v_profile.id,
        v_profile.version,
        p_engine_version,
        clock_timestamp(),

        jsonb_build_object(
          'slot_number', v_match.slot_number,
          'match_version', v_match.match_version,
          'provider_updated_at', v_match.provider_updated_at,
          'finalised_at', v_match.finalised_at,
          'league_match_decision', v_decision,
          'prediction_snapshot_status',
            case when v_missing then null else v_prediction.snapshot_status end,
          'prediction_snapshot_source',
            case when v_missing then null else v_prediction.snapshot_source end
        )
      );
    end loop;
  end loop;

  select count(*)::integer
  into v_result_count
  from public.prediction_score_runtime_results psrr
  where psrr.calculation_run_id = v_run.id;

  -- Freeze every effective input used by the deterministic calculation.
  select v_input_snapshot || jsonb_build_object(
    'inputs',
    coalesce(
      jsonb_agg(
        jsonb_build_object(
          'league_member_id', psrr.league_member_id,
          'match_id', psrr.match_id,
          'slot_number', (psrr.details ->> 'slot_number')::integer,
          'match_status', psrr.match_status,
          'match_version', (psrr.details ->> 'match_version')::integer,
          'provider_updated_at', psrr.details -> 'provider_updated_at',
          'finalised_at', psrr.details -> 'finalised_at',
          'league_match_decision', psrr.details ->> 'league_match_decision',
          'included', psrr.included,
          'home_score', psrr.home_score,
          'away_score', psrr.away_score,
          'prediction_id', psrr.prediction_id,
          'prediction_version', psrr.prediction_version,
          'prediction_snapshot_status',
            psrr.details ->> 'prediction_snapshot_status',
          'prediction_snapshot_source',
            psrr.details ->> 'prediction_snapshot_source',
          'home_prediction', psrr.home_prediction,
          'away_prediction', psrr.away_prediction,
          'missing', psrr.missing,
          'void', psrr.void,
          'surprise_candidate', psrr.surprise_candidate
        )
        order by
          psrr.league_member_id,
          (psrr.details ->> 'slot_number')::integer
      ),
      '[]'::jsonb
    )
  )
  into v_input_snapshot
  from public.prediction_score_runtime_results psrr
  where psrr.calculation_run_id = v_run.id;

  select jsonb_build_object(
    'schema_version', 1,
    'engine_version', p_engine_version,
    'league_round_id', v_round.id,
    'members',
      coalesce(
        (
          select jsonb_agg(
            jsonb_build_object(
              'league_member_id', x.league_member_id,
              'pure_points', x.pure_points,
              'exact_count', x.exact_count,
              'sign_count', x.sign_count,
              'over_under_count', x.over_under_count,
              'goal_no_goal_count', x.goal_no_goal_count,
              'surprise_count', x.surprise_count,
              'goal_show_count', x.goal_show_count,
              'grand_slam_count', x.grand_slam_count,
              'opposite_sign_count', x.opposite_sign_count,
              'cantonata_count', x.cantonata_count,
              'missing_count', x.missing_count,
              'void_count', x.void_count,
              'included_match_count', x.included_match_count,
              'resolved_match_count', x.resolved_match_count,
              'pending_match_count', x.pending_match_count
            )
            order by x.league_member_id
          )
          from (
            select
              psrr.league_member_id,
              sum(psrr.base_total)::numeric(10,2) as pure_points,
              count(*) filter (where psrr.is_exact)::integer as exact_count,
              count(*) filter (where psrr.is_sign)::integer as sign_count,
              count(*) filter (where psrr.is_over_under)::integer as over_under_count,
              count(*) filter (where psrr.is_goal_no_goal)::integer as goal_no_goal_count,
              count(*) filter (where psrr.is_surprise)::integer as surprise_count,
              count(*) filter (where psrr.is_goal_show)::integer as goal_show_count,
              count(*) filter (where psrr.is_grand_slam)::integer as grand_slam_count,
              count(*) filter (where psrr.is_opposite_sign)::integer
                as opposite_sign_count,
              count(*) filter (where psrr.is_cantonata)::integer as cantonata_count,
              count(*) filter (where psrr.missing)::integer as missing_count,
              count(*) filter (where psrr.void)::integer as void_count,
              count(*) filter (where psrr.included)::integer as included_match_count,
              count(*) filter (
                where psrr.result_phase in ('live', 'post_live', 'certified')
                  and psrr.included
              )::integer as resolved_match_count,
              count(*) filter (
                where psrr.result_phase = 'pre_live'
                  and psrr.included
              )::integer as pending_match_count
            from public.prediction_score_runtime_results psrr
            where psrr.calculation_run_id = v_run.id
            group by psrr.league_member_id
          ) x
        ),
        '[]'::jsonb
      ),
    'prediction_results',
      coalesce(
        (
          select jsonb_agg(
            jsonb_build_object(
              'league_member_id', psrr.league_member_id,
              'match_id', psrr.match_id,
              'slot_number', (psrr.details ->> 'slot_number')::integer,
              'prediction_id', psrr.prediction_id,
              'prediction_version', psrr.prediction_version,
              'result_phase', psrr.result_phase,
              'provisional', psrr.provisional,
              'included', psrr.included,
              'missing', psrr.missing,
              'void', psrr.void,
              'surprise_candidate', psrr.surprise_candidate,
              'is_exact', psrr.is_exact,
              'is_sign', psrr.is_sign,
              'is_over_under', psrr.is_over_under,
              'is_goal_no_goal', psrr.is_goal_no_goal,
              'is_surprise', psrr.is_surprise,
              'is_goal_show', psrr.is_goal_show,
              'is_grand_slam', psrr.is_grand_slam,
              'is_opposite_sign', psrr.is_opposite_sign,
              'is_cantonata', psrr.is_cantonata,
              'exact_points', psrr.exact_points,
              'sign_points', psrr.sign_points,
              'over_under_points', psrr.over_under_points,
              'goal_no_goal_points', psrr.goal_no_goal_points,
              'surprise_points', psrr.surprise_points,
              'goal_show_points', psrr.goal_show_points,
              'grand_slam_points', psrr.grand_slam_points,
              'opposite_sign_points', psrr.opposite_sign_points,
              'cantonata_points', psrr.cantonata_points,
              'base_total', psrr.base_total
            )
            order by
              psrr.league_member_id,
              (psrr.details ->> 'slot_number')::integer
          )
          from public.prediction_score_runtime_results psrr
          where psrr.calculation_run_id = v_run.id
        ),
        '[]'::jsonb
      )
  )
  into v_output_snapshot;

  v_input_hash := public.compute_jsonb_sha256(v_input_snapshot);
  v_output_hash := public.compute_jsonb_sha256(v_output_snapshot);
  v_preview_hash := encode(
    extensions.digest(
      v_input_hash || ':' || v_output_hash,
      'sha256'
    ),
    'hex'
  );

  update public.round_calculation_runs rcr
  set
    status = 'preview_ready',
    input_snapshot = v_input_snapshot,
    output_snapshot = v_output_snapshot,
    standings_snapshot = '{}'::jsonb,
    input_hash = v_input_hash,
    output_hash = v_output_hash,
    preview_hash = v_preview_hash,
    completed_at = clock_timestamp(),
    failed_at = null,
    failure_details = null
  where rcr.id = v_run.id
  returning * into v_run;

  return query
  select
    v_run.id,
    v_run.league_round_id,
    v_run.run_version,
    v_run.status,
    v_member_count,
    v_match_count,
    v_result_count,
    v_run.input_hash,
    v_run.output_hash;

exception
  when others then
    if v_run.id is not null then
      update public.round_calculation_runs rcr
      set
        status = 'failed',
        failed_at = clock_timestamp(),
        failure_details = jsonb_build_object(
          'sqlstate', sqlstate,
          'message', sqlerrm
        )
      where rcr.id = v_run.id;
    end if;

    raise;
end;
$function$;

comment on function public.build_points_pure_calculation_run_rpc(
  uuid,
  jsonb,
  text,
  uuid
) is
'Builds a versioned Points Pure preview from official submitted prediction versions, current match results, match decisions, scoring profile and Surprise candidate input. Preview hash uses extensions.digest explicitly. Service-role only.';

revoke all on function public.build_points_pure_calculation_run_rpc(
  uuid,
  jsonb,
  text,
  uuid
) from public;

revoke all on function public.build_points_pure_calculation_run_rpc(
  uuid,
  jsonb,
  text,
  uuid
) from anon;

revoke all on function public.build_points_pure_calculation_run_rpc(
  uuid,
  jsonb,
  text,
  uuid
) from authenticated;

grant execute on function public.build_points_pure_calculation_run_rpc(
  uuid,
  jsonb,
  text,
  uuid
) to service_role;

commit;
