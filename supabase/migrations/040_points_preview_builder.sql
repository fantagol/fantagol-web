-- ============================================================================
-- FANTAGOL
-- Migration 040: Points Preview Builder
--
-- Scope:
--   - first operational Round Simulation builder;
--   - deterministic Points Preview composition from Prediction Resolution
--     runtime outputs;
--   - creation of a versioned Digital Twin;
--   - builder execution registry and simulation lifecycle events;
--   - authenticated member read RPC for the latest Points Preview.
--
-- Out of scope:
--   - prediction scoring or recalculation;
--   - Fantacalcio strategic preview;
--   - One-to-One matrix preview;
--   - standings preview;
--   - publication registry writes;
--   - Live State Engine orchestration;
--   - certification commit and ledger updates.
--
-- Architectural rule:
--   The Points Preview Builder only composes authoritative artifacts produced
--   by the Prediction Resolution Engine. It never recalculates score rules.
-- ============================================================================

begin;

-- ============================================================================
-- 1. POINTS PREVIEW SIMULATION BUILDER
-- ============================================================================

create or replace function public.build_points_preview_simulation_rpc(
  p_calculation_run_id uuid,
  p_simulation_engine_version text default 'round-simulation-v1',
  p_created_by_member_id uuid default null,
  p_correlation_id uuid default null
)
returns table (
  simulation_id uuid,
  league_round_id uuid,
  calculation_run_id uuid,
  simulation_version integer,
  simulation_status text,
  builder_status text,
  member_count integer,
  match_count integer,
  prediction_result_count integer,
  input_hash text,
  output_hash text,
  simulation_hash text
)
language plpgsql
security definer
set search_path to public, pg_temp
as $function$
declare
  v_run public.round_calculation_runs%rowtype;
  v_round public.league_rounds%rowtype;
  v_existing public.round_simulations%rowtype;
  v_simulation public.round_simulations%rowtype;
  v_builder public.round_simulation_builder_runs%rowtype;

  v_simulation_version integer;
  v_member_count integer;
  v_match_count integer;
  v_prediction_result_count integer;

  v_started_match_count integer;
  v_live_match_count integer;
  v_finished_match_count integer;
  v_pending_match_count integer;
  v_certified_match_count integer;
  v_progress_percent numeric(7,2);
  v_simulation_phase text;

  v_generated_at timestamptz;
  v_input_manifest jsonb;
  v_round_view jsonb;
  v_matches jsonb;
  v_members jsonb;
  v_points_members jsonb;
  v_prediction_results jsonb;
  v_points_preview jsonb;
  v_digital_twin jsonb;

  v_input_hash text;
  v_points_output_hash text;
  v_output_hash text;
  v_simulation_hash text;
  v_correlation_id uuid;
  v_conflicting_status text;
begin
  if p_calculation_run_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'CALCULATION_RUN_REQUIRED';
  end if;

  if nullif(btrim(p_simulation_engine_version), '') is null then
    raise exception using
      errcode = 'P0001',
      message = 'SIMULATION_ENGINE_VERSION_REQUIRED';
  end if;

  select rcr.*
  into v_run
  from public.round_calculation_runs rcr
  where rcr.id = p_calculation_run_id;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'CALCULATION_RUN_NOT_FOUND';
  end if;

  if v_run.status not in ('preview_ready', 'committed') then
    raise exception using
      errcode = 'P0001',
      message = 'CALCULATION_RUN_NOT_READY',
      detail = v_run.status;
  end if;

  if v_run.input_hash is null
     or v_run.output_hash is null
     or v_run.preview_hash is null then
    raise exception using
      errcode = 'P0001',
      message = 'CALCULATION_RUN_HASHES_MISSING';
  end if;

  select lr.*
  into v_round
  from public.league_rounds lr
  where lr.id = v_run.league_round_id;

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

  if p_created_by_member_id is not null
     and not exists (
       select 1
       from public.league_members lm
       where lm.id = p_created_by_member_id
         and lm.league_id = v_round.league_id
         and lm.status = 'active'
     ) then
    raise exception using
      errcode = 'P0001',
      message = 'CREATOR_MEMBERSHIP_INVALID';
  end if;

  select count(*)::integer,
         count(distinct psrr.league_member_id)::integer,
         count(distinct psrr.match_id)::integer
  into v_prediction_result_count, v_member_count, v_match_count
  from public.prediction_score_runtime_results psrr
  where psrr.calculation_run_id = v_run.id;

  if v_prediction_result_count = 0 then
    raise exception using
      errcode = 'P0001',
      message = 'PREDICTION_RUNTIME_RESULTS_EMPTY';
  end if;

  -- Idempotent fast path.
  select rs.*
  into v_existing
  from public.round_simulations rs
  where rs.league_round_id = v_round.id
    and rs.calculation_run_id = v_run.id
    and rs.engine_version = p_simulation_engine_version
  limit 1;

  if found then
    if v_existing.status in (
      'preview_ready',
      'awaiting_certification',
      'certified'
    ) then
      return query
      select
        v_existing.id,
        v_existing.league_round_id,
        v_existing.calculation_run_id,
        v_existing.simulation_version,
        v_existing.status,
        coalesce(
          (
            select sbr.status
            from public.round_simulation_builder_runs sbr
            where sbr.simulation_id = v_existing.id
              and sbr.builder_name = 'PointsPreviewBuilder'
            limit 1
          ),
          'completed'
        ),
        coalesce(
          (v_existing.digital_twin #>> '{round,member_count}')::integer,
          v_member_count
        ),
        coalesce(
          (v_existing.digital_twin #>> '{round,match_count}')::integer,
          v_match_count
        ),
        coalesce(
          (v_existing.digital_twin #>> '{round,prediction_result_count}')::integer,
          v_prediction_result_count
        ),
        v_existing.input_hash,
        v_existing.output_hash,
        v_existing.simulation_hash;
      return;
    end if;

    raise exception using
      errcode = 'P0001',
      message = 'ROUND_SIMULATION_EXISTING_NOT_REUSABLE',
      detail = v_existing.status;
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(
      'points-preview-simulation:' || v_round.id::text,
      0
    )
  );

  -- Repeat the idempotency check after acquiring the transaction lock.
  select rs.*
  into v_existing
  from public.round_simulations rs
  where rs.league_round_id = v_round.id
    and rs.calculation_run_id = v_run.id
    and rs.engine_version = p_simulation_engine_version
  limit 1;

  if found then
    if v_existing.status in (
      'preview_ready',
      'awaiting_certification',
      'certified'
    ) then
      return query
      select
        v_existing.id,
        v_existing.league_round_id,
        v_existing.calculation_run_id,
        v_existing.simulation_version,
        v_existing.status,
        coalesce(
          (
            select sbr.status
            from public.round_simulation_builder_runs sbr
            where sbr.simulation_id = v_existing.id
              and sbr.builder_name = 'PointsPreviewBuilder'
            limit 1
          ),
          'completed'
        ),
        coalesce(
          (v_existing.digital_twin #>> '{round,member_count}')::integer,
          v_member_count
        ),
        coalesce(
          (v_existing.digital_twin #>> '{round,match_count}')::integer,
          v_match_count
        ),
        coalesce(
          (v_existing.digital_twin #>> '{round,prediction_result_count}')::integer,
          v_prediction_result_count
        ),
        v_existing.input_hash,
        v_existing.output_hash,
        v_existing.simulation_hash;
      return;
    end if;

    raise exception using
      errcode = 'P0001',
      message = 'ROUND_SIMULATION_EXISTING_NOT_REUSABLE',
      detail = v_existing.status;
  end if;

  select rs.status
  into v_conflicting_status
  from public.round_simulations rs
  where rs.league_round_id = v_round.id
    and rs.publishable = true
    and rs.status in ('awaiting_certification', 'certified')
  limit 1;

  if v_conflicting_status is not null then
    raise exception using
      errcode = 'P0001',
      message = 'CURRENT_SIMULATION_NOT_REPLACEABLE',
      detail = v_conflicting_status;
  end if;

  select coalesce(max(rs.simulation_version), 0) + 1
  into v_simulation_version
  from public.round_simulations rs
  where rs.league_round_id = v_round.id;

  v_generated_at := coalesce(v_run.completed_at, v_run.created_at);
  v_correlation_id := coalesce(p_correlation_id, gen_random_uuid());

  v_input_manifest := jsonb_build_object(
    'schema_version', 1,
    'simulation_engine', 'RoundSimulationEngine',
    'simulation_engine_version', p_simulation_engine_version,
    'builder_name', 'PointsPreviewBuilder',
    'builder_version', 'points-preview-v1',
    'league_round_id', v_round.id,
    'league_round_version', v_round.version,
    'calculation_run_id', v_run.id,
    'calculation_run_version', v_run.run_version,
    'resolution_engine_version', v_run.engine_version,
    'resolution_schema_version', v_run.snapshot_schema_version,
    'resolution_input_hash', v_run.input_hash,
    'resolution_output_hash', v_run.output_hash,
    'resolution_preview_hash', v_run.preview_hash,
    'match_set_version', v_run.match_set_version,
    'scoring_profile_id', v_run.scoring_profile_id,
    'scoring_profile_version', v_run.scoring_profile_version
  );

  v_input_hash := public.compute_jsonb_sha256(v_input_manifest);

  insert into public.round_simulations (
    league_round_id,
    calculation_run_id,
    simulation_version,
    engine_version,
    snapshot_schema_version,
    status,
    preview,
    publishable,
    digital_twin,
    input_hash,
    correlation_id,
    created_by_member_id
  )
  values (
    v_round.id,
    v_run.id,
    v_simulation_version,
    p_simulation_engine_version,
    1,
    'building',
    true,
    false,
    '{}'::jsonb,
    v_input_hash,
    v_correlation_id,
    p_created_by_member_id
  )
  returning * into v_simulation;

  insert into public.round_simulation_events (
    simulation_id,
    league_round_id,
    calculation_run_id,
    event_type,
    payload,
    correlation_id,
    actor_member_id
  )
  values (
    v_simulation.id,
    v_round.id,
    v_run.id,
    'RoundSimulationBuilding',
    jsonb_build_object(
      'simulation_version', v_simulation_version,
      'engine_version', p_simulation_engine_version,
      'builder', 'PointsPreviewBuilder'
    ),
    v_correlation_id,
    p_created_by_member_id
  );

  insert into public.round_simulation_builder_runs (
    simulation_id,
    builder_name,
    builder_version,
    builder_order,
    required,
    status,
    started_at,
    input_hash,
    metadata
  )
  values (
    v_simulation.id,
    'PointsPreviewBuilder',
    'points-preview-v1',
    1,
    true,
    'running',
    clock_timestamp(),
    v_input_hash,
    jsonb_build_object(
      'calculation_run_id', v_run.id,
      'prediction_result_count', v_prediction_result_count
    )
  )
  returning * into v_builder;

  -- Match progress is calculated once per distinct match, never multiplied by
  -- the number of League Members.
  select
    count(*) filter (
      where x.result_phase in ('live', 'post_live', 'certified')
    )::integer,
    count(*) filter (where x.result_phase = 'live')::integer,
    count(*) filter (
      where x.result_phase in ('post_live', 'certified')
    )::integer,
    count(*) filter (where x.result_phase = 'pre_live')::integer,
    count(*) filter (where x.result_phase = 'certified')::integer
  into
    v_started_match_count,
    v_live_match_count,
    v_finished_match_count,
    v_pending_match_count,
    v_certified_match_count
  from (
    select distinct on (psrr.match_id)
      psrr.match_id,
      psrr.result_phase
    from public.prediction_score_runtime_results psrr
    where psrr.calculation_run_id = v_run.id
    order by psrr.match_id, psrr.calculated_at desc, psrr.id
  ) x;

  v_progress_percent := case
    when v_match_count = 0 then 0
    else round(
      (v_finished_match_count::numeric / v_match_count::numeric) * 100,
      2
    )
  end;

  v_simulation_phase := case
    when v_certified_match_count = v_match_count and v_match_count > 0
      then 'certified'
    when v_live_match_count > 0
      then 'live'
    when v_finished_match_count > 0 and v_pending_match_count > 0
      then 'partially_post_live'
    when v_finished_match_count = v_match_count and v_match_count > 0
      then 'post_live'
    else 'pre_live'
  end;

  v_round_view := jsonb_build_object(
    'league_round_id', v_round.id,
    'league_id', v_round.league_id,
    'fantagol_round_id', v_round.fantagol_round_id,
    'league_round_number', v_round.league_round_number,
    'league_round_status', v_round.status,
    'league_round_version', v_round.version,
    'simulation_phase', v_simulation_phase,
    'match_count', v_match_count,
    'member_count', v_member_count,
    'prediction_result_count', v_prediction_result_count,
    'started_match_count', v_started_match_count,
    'live_match_count', v_live_match_count,
    'finished_match_count', v_finished_match_count,
    'pending_match_count', v_pending_match_count,
    'certified_match_count', v_certified_match_count,
    'progress_percent', v_progress_percent
  );

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'match_id', x.match_id,
        'slot_number', x.slot_number,
        'kickoff', x.kickoff,
        'status', x.match_status,
        'result_phase', x.result_phase,
        'minute', x.minute,
        'period', x.period,
        'home_team', jsonb_build_object(
          'team_id', x.home_team_id,
          'name', x.home_team_name,
          'short_name', x.home_team_short_name,
          'logo_url', x.home_team_logo_url,
          'crest_reference', x.home_team_crest_reference
        ),
        'away_team', jsonb_build_object(
          'team_id', x.away_team_id,
          'name', x.away_team_name,
          'short_name', x.away_team_short_name,
          'logo_url', x.away_team_logo_url,
          'crest_reference', x.away_team_crest_reference
        ),
        'score', jsonb_build_object(
          'home', x.home_score,
          'away', x.away_score
        ),
        'included', x.included,
        'member_results_count', x.member_results_count
      )
      order by x.slot_number, x.match_id
    ),
    '[]'::jsonb
  )
  into v_matches
  from (
    select
      psrr.match_id,
      min((psrr.details ->> 'slot_number')::integer) as slot_number,
      m.kickoff,
      min(psrr.match_status) as match_status,
      min(psrr.result_phase) as result_phase,
      m.minute,
      m.period,
      m.home_team_id,
      ht.name as home_team_name,
      ht.short_name as home_team_short_name,
      ht.logo_url as home_team_logo_url,
      ht.crest_reference as home_team_crest_reference,
      m.away_team_id,
      at.name as away_team_name,
      at.short_name as away_team_short_name,
      at.logo_url as away_team_logo_url,
      at.crest_reference as away_team_crest_reference,
      min(psrr.home_score) as home_score,
      min(psrr.away_score) as away_score,
      bool_and(psrr.included) as included,
      count(*)::integer as member_results_count
    from public.prediction_score_runtime_results psrr
    join public.matches m
      on m.id = psrr.match_id
    join public.teams ht
      on ht.id = m.home_team_id
    join public.teams at
      on at.id = m.away_team_id
    where psrr.calculation_run_id = v_run.id
    group by
      psrr.match_id,
      m.kickoff,
      m.minute,
      m.period,
      m.home_team_id,
      ht.name,
      ht.short_name,
      ht.logo_url,
      ht.crest_reference,
      m.away_team_id,
      at.name,
      at.short_name,
      at.logo_url,
      at.crest_reference
  ) x;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'league_member_id', x.league_member_id,
        'display_name', x.display_name,
        'role', x.role,
        'avatar_url', x.avatar_url,
        'club_id', x.club_id,
        'kit', jsonb_build_object(
          'primary_color', x.kit_primary_color,
          'secondary_color', x.kit_secondary_color,
          'pattern', x.kit_pattern
        ),
        'round_points', x.pure_points,
        'exact_count', x.exact_count,
        'bonus_count', x.bonus_count,
        'malus_count', x.malus_count,
        'missing_count', x.missing_count,
        'void_count', x.void_count,
        'resolved_match_count', x.resolved_match_count,
        'pending_match_count', x.pending_match_count,
        'score_phase', x.score_phase
      )
      order by x.league_member_id
    ),
    '[]'::jsonb
  )
  into v_members
  from (
    select
      psrr.league_member_id,
      lm.display_name,
      lm.role,
      lm.avatar_url,
      lm.club_id,
      lm.kit_primary_color,
      lm.kit_secondary_color,
      lm.kit_pattern,
      sum(psrr.base_total)::numeric(10,2) as pure_points,
      count(*) filter (where psrr.is_exact)::integer as exact_count,
      (
        count(*) filter (where psrr.is_surprise)
        + count(*) filter (where psrr.is_goal_show)
        + count(*) filter (where psrr.is_grand_slam)
      )::integer as bonus_count,
      (
        count(*) filter (where psrr.is_opposite_sign)
        + count(*) filter (where psrr.is_cantonata)
      )::integer as malus_count,
      count(*) filter (where psrr.missing)::integer as missing_count,
      count(*) filter (where psrr.void)::integer as void_count,
      count(*) filter (
        where psrr.included
          and psrr.result_phase in ('live', 'post_live', 'certified')
      )::integer as resolved_match_count,
      count(*) filter (
        where psrr.included
          and psrr.result_phase = 'pre_live'
      )::integer as pending_match_count,
      case
        when bool_or(psrr.result_phase = 'live') then 'provisional'
        when bool_and(psrr.result_phase = 'pre_live') then 'waiting'
        when bool_and(psrr.result_phase = 'certified') then 'locked'
        else 'stable_pending_round'
      end as score_phase
    from public.prediction_score_runtime_results psrr
    join public.league_members lm
      on lm.id = psrr.league_member_id
    where psrr.calculation_run_id = v_run.id
    group by
      psrr.league_member_id,
      lm.display_name,
      lm.role,
      lm.avatar_url,
      lm.club_id,
      lm.kit_primary_color,
      lm.kit_secondary_color,
      lm.kit_pattern
  ) x;

  select coalesce(
    jsonb_agg(
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
        'bonus_count', x.bonus_count,
        'malus_count', x.malus_count,
        'missing_count', x.missing_count,
        'void_count', x.void_count,
        'included_match_count', x.included_match_count,
        'resolved_match_count', x.resolved_match_count,
        'pending_match_count', x.pending_match_count,
        'provisional', x.provisional
      )
      order by x.league_member_id
    ),
    '[]'::jsonb
  )
  into v_points_members
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
      (
        count(*) filter (where psrr.is_surprise)
        + count(*) filter (where psrr.is_goal_show)
        + count(*) filter (where psrr.is_grand_slam)
      )::integer as bonus_count,
      (
        count(*) filter (where psrr.is_opposite_sign)
        + count(*) filter (where psrr.is_cantonata)
      )::integer as malus_count,
      count(*) filter (where psrr.missing)::integer as missing_count,
      count(*) filter (where psrr.void)::integer as void_count,
      count(*) filter (where psrr.included)::integer as included_match_count,
      count(*) filter (
        where psrr.included
          and psrr.result_phase in ('live', 'post_live', 'certified')
      )::integer as resolved_match_count,
      count(*) filter (
        where psrr.included
          and psrr.result_phase = 'pre_live'
      )::integer as pending_match_count,
      bool_or(psrr.provisional) as provisional
    from public.prediction_score_runtime_results psrr
    where psrr.calculation_run_id = v_run.id
    group by psrr.league_member_id
  ) x;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'league_member_id', psrr.league_member_id,
        'match_id', psrr.match_id,
        'slot_number', (psrr.details ->> 'slot_number')::integer,
        'prediction_id', psrr.prediction_id,
        'prediction_version', psrr.prediction_version,
        'match_status', psrr.match_status,
        'result_phase', psrr.result_phase,
        'provisional', psrr.provisional,
        'included', psrr.included,
        'missing', psrr.missing,
        'void', psrr.void,
        'home_prediction', psrr.home_prediction,
        'away_prediction', psrr.away_prediction,
        'home_score', psrr.home_score,
        'away_score', psrr.away_score,
        'predicted_sign', psrr.predicted_sign,
        'real_sign', psrr.real_sign,
        'predicted_over_under', psrr.predicted_over_under,
        'real_over_under', psrr.real_over_under,
        'predicted_goal_no_goal', psrr.predicted_goal_no_goal,
        'real_goal_no_goal', psrr.real_goal_no_goal,
        'is_exact', psrr.is_exact,
        'is_sign', psrr.is_sign,
        'is_over_under', psrr.is_over_under,
        'is_goal_no_goal', psrr.is_goal_no_goal,
        'surprise_candidate', psrr.surprise_candidate,
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
        'base_total', psrr.base_total,
        'calculated_at', psrr.calculated_at
      )
      order by
        psrr.league_member_id,
        (psrr.details ->> 'slot_number')::integer,
        psrr.match_id
    ),
    '[]'::jsonb
  )
  into v_prediction_results
  from public.prediction_score_runtime_results psrr
  where psrr.calculation_run_id = v_run.id;

  v_points_preview := jsonb_build_object(
    'schema_version', 1,
    'builder', 'PointsPreviewBuilder',
    'builder_version', 'points-preview-v1',
    'members', v_points_members,
    'prediction_results', v_prediction_results
  );

  v_points_output_hash := public.compute_jsonb_sha256(v_points_preview);

  v_digital_twin := jsonb_build_object(
    'schema_version', 1,
    'manifest', jsonb_build_object(
      'engine', 'RoundSimulationEngine',
      'engine_version', p_simulation_engine_version,
      'simulation_id', v_simulation.id,
      'simulation_version', v_simulation_version,
      'league_round_id', v_round.id,
      'calculation_run_id', v_run.id,
      'calculation_run_version', v_run.run_version,
      'resolution_engine_version', v_run.engine_version,
      'match_set_version', v_run.match_set_version,
      'scoring_profile_id', v_run.scoring_profile_id,
      'scoring_profile_version', v_run.scoring_profile_version,
      'preview', true,
      'generated_at', v_generated_at,
      'input_hash', v_input_hash,
      'resolution_input_hash', v_run.input_hash,
      'resolution_output_hash', v_run.output_hash,
      'resolution_preview_hash', v_run.preview_hash,
      'points_preview_hash', v_points_output_hash
    ),
    'round', v_round_view,
    'matches', v_matches,
    'members', v_members,
    'points_preview', v_points_preview
  );

  v_output_hash := public.compute_jsonb_sha256(v_digital_twin);
  v_simulation_hash := encode(
    extensions.digest(
      v_input_hash || ':' || v_output_hash,
      'sha256'
    ),
    'hex'
  );

  update public.round_simulation_builder_runs sbr
  set
    status = 'completed',
    completed_at = clock_timestamp(),
    output_hash = v_points_output_hash,
    metadata = sbr.metadata || jsonb_build_object(
      'member_count', v_member_count,
      'match_count', v_match_count,
      'prediction_result_count', v_prediction_result_count
    )
  where sbr.id = v_builder.id
  returning * into v_builder;

  insert into public.round_simulation_events (
    simulation_id,
    league_round_id,
    calculation_run_id,
    event_type,
    payload,
    correlation_id,
    causation_id,
    actor_member_id
  )
  values (
    v_simulation.id,
    v_round.id,
    v_run.id,
    'SimulationBuilderCompleted',
    jsonb_build_object(
      'builder_name', v_builder.builder_name,
      'builder_version', v_builder.builder_version,
      'builder_output_hash', v_points_output_hash
    ),
    v_correlation_id,
    v_builder.id,
    p_created_by_member_id
  );

  -- Supersede only a replaceable preview. Certified or awaiting-certification
  -- artifacts were rejected before the new simulation was created.
  update public.round_simulations rs
  set
    status = 'preview_invalidated',
    publishable = false,
    invalidated_at = clock_timestamp(),
    invalidation_reason = 'superseded_by_newer_points_preview'
  where rs.league_round_id = v_round.id
    and rs.id <> v_simulation.id
    and rs.publishable = true
    and rs.status = 'preview_ready';

  update public.round_simulations rs
  set
    status = 'preview_ready',
    preview = true,
    publishable = true,
    digital_twin = v_digital_twin,
    input_hash = v_input_hash,
    output_hash = v_output_hash,
    simulation_hash = v_simulation_hash,
    completed_at = clock_timestamp(),
    failed_at = null,
    failure_details = null
  where rs.id = v_simulation.id
  returning * into v_simulation;

  insert into public.round_simulation_events (
    simulation_id,
    league_round_id,
    calculation_run_id,
    event_type,
    payload,
    correlation_id,
    actor_member_id
  )
  values (
    v_simulation.id,
    v_round.id,
    v_run.id,
    'RoundSimulationReady',
    jsonb_build_object(
      'simulation_version', v_simulation.simulation_version,
      'simulation_hash', v_simulation.simulation_hash,
      'member_count', v_member_count,
      'match_count', v_match_count,
      'prediction_result_count', v_prediction_result_count
    ),
    v_correlation_id,
    p_created_by_member_id
  );

  return query
  select
    v_simulation.id,
    v_simulation.league_round_id,
    v_simulation.calculation_run_id,
    v_simulation.simulation_version,
    v_simulation.status,
    v_builder.status,
    v_member_count,
    v_match_count,
    v_prediction_result_count,
    v_simulation.input_hash,
    v_simulation.output_hash,
    v_simulation.simulation_hash;
end;
$function$;

-- ============================================================================
-- 2. AUTHENTICATED MEMBER READ MODEL
-- ============================================================================

create or replace function public.get_my_points_preview_rpc(
  p_league_round_id uuid
)
returns table (
  simulation_id uuid,
  simulation_version integer,
  simulation_status text,
  simulation_hash text,
  manifest jsonb,
  round_view jsonb,
  matches jsonb,
  member_view jsonb,
  points_preview jsonb
)
language plpgsql
stable
security definer
set search_path to public, pg_temp
as $function$
declare
  v_user_id uuid;
  v_member_id uuid;
  v_simulation public.round_simulations%rowtype;
  v_member_view jsonb;
  v_points_member jsonb;
  v_member_prediction_results jsonb;
begin
  v_user_id := auth.uid();

  if v_user_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'AUTHENTICATION_REQUIRED';
  end if;

  if p_league_round_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_ROUND_REQUIRED';
  end if;

  select lm.id
  into v_member_id
  from public.league_rounds lr
  join public.league_members lm
    on lm.league_id = lr.league_id
  where lr.id = p_league_round_id
    and lm.user_id = v_user_id
    and lm.status = 'active'
  limit 1;

  if v_member_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'ACTIVE_LEAGUE_MEMBERSHIP_REQUIRED';
  end if;

  select rs.*
  into v_simulation
  from public.round_simulations rs
  where rs.league_round_id = p_league_round_id
    and rs.publishable = true
    and rs.status in ('preview_ready', 'awaiting_certification', 'certified')
  order by rs.simulation_version desc
  limit 1;

  if not found then
    return;
  end if;

  select value
  into v_member_view
  from jsonb_array_elements(
    coalesce(v_simulation.digital_twin -> 'members', '[]'::jsonb)
  ) value
  where value ->> 'league_member_id' = v_member_id::text
  limit 1;

  select value
  into v_points_member
  from jsonb_array_elements(
    coalesce(
      v_simulation.digital_twin #> '{points_preview,members}',
      '[]'::jsonb
    )
  ) value
  where value ->> 'league_member_id' = v_member_id::text
  limit 1;

  select coalesce(jsonb_agg(value), '[]'::jsonb)
  into v_member_prediction_results
  from jsonb_array_elements(
    coalesce(
      v_simulation.digital_twin #> '{points_preview,prediction_results}',
      '[]'::jsonb
    )
  ) value
  where value ->> 'league_member_id' = v_member_id::text;

  return query
  select
    v_simulation.id,
    v_simulation.simulation_version,
    v_simulation.status,
    v_simulation.simulation_hash,
    v_simulation.digital_twin -> 'manifest',
    v_simulation.digital_twin -> 'round',
    v_simulation.digital_twin -> 'matches',
    coalesce(v_member_view, '{}'::jsonb),
    jsonb_build_object(
      'schema_version', coalesce(
        (v_simulation.digital_twin #>> '{points_preview,schema_version}')::integer,
        1
      ),
      'builder', v_simulation.digital_twin #>> '{points_preview,builder}',
      'builder_version',
        v_simulation.digital_twin #>> '{points_preview,builder_version}',
      'member', coalesce(v_points_member, '{}'::jsonb),
      'prediction_results', v_member_prediction_results
    );
end;
$function$;

-- ============================================================================
-- 3. GRANTS
-- ============================================================================

revoke all on function public.build_points_preview_simulation_rpc(
  uuid,
  text,
  uuid,
  uuid
) from public;

revoke all on function public.build_points_preview_simulation_rpc(
  uuid,
  text,
  uuid,
  uuid
) from anon;

revoke all on function public.build_points_preview_simulation_rpc(
  uuid,
  text,
  uuid,
  uuid
) from authenticated;

grant execute on function public.build_points_preview_simulation_rpc(
  uuid,
  text,
  uuid,
  uuid
) to service_role;

revoke all on function public.get_my_points_preview_rpc(uuid)
  from public;

revoke all on function public.get_my_points_preview_rpc(uuid)
  from anon;

revoke all on function public.get_my_points_preview_rpc(uuid)
  from service_role;

grant execute on function public.get_my_points_preview_rpc(uuid)
  to authenticated;

-- ============================================================================
-- 4. COMMENTS
-- ============================================================================

comment on function public.build_points_preview_simulation_rpc(
  uuid,
  text,
  uuid,
  uuid
) is
'Builds the first immutable Round Simulation Digital Twin by composing one ready Prediction Resolution Calculation Run. It aggregates authoritative runtime results and never recalculates scoring rules. Service-role only.';

comment on function public.get_my_points_preview_rpc(uuid) is
'Returns the authenticated League Member latest Points Preview, including the shared round and match views but only that member own aggregate and prediction-result rows.';

commit;
