-- FANTAGOL — ONE-TO-ONE PREVIEW PARTICIPANT CONTRACT HOTFIX
-- Migration: 045_one_to_one_preview_participant_contract_hotfix.sql
-- Purpose: expose canonical participant member/user identifiers at fixture root
--          while preserving the existing nested home/away presentation nodes.

begin;

create or replace function public.build_one_to_one_preview_simulation_rpc(
  p_source_simulation_id uuid,
  p_simulation_engine_version text default 'round-simulation-v1-one-to-one-v1',
  p_created_by_member_id uuid default null,
  p_correlation_id uuid default null
)
returns table (
  simulation_id uuid,
  source_simulation_id uuid,
  league_round_id uuid,
  calculation_run_id uuid,
  simulation_version integer,
  simulation_status text,
  builder_status text,
  fixture_count integer,
  complete_fixture_count integer,
  pending_fixture_count integer,
  mini_challenge_count integer,
  input_hash text,
  output_hash text,
  simulation_hash text
)
language plpgsql
security definer
set search_path to public, pg_temp
as $function$
declare
  v_source public.round_simulations%rowtype;
  v_existing public.round_simulations%rowtype;
  v_simulation public.round_simulations%rowtype;
  v_builder public.round_simulation_builder_runs%rowtype;
  v_run public.round_calculation_runs%rowtype;
  v_round public.league_rounds%rowtype;
  v_profile public.league_scoring_profiles%rowtype;

  v_schedule_id uuid;
  v_schedule_version integer;
  v_rules jsonb;
  v_simulation_version integer;
  v_fixture_count integer := 0;
  v_complete_fixture_count integer := 0;
  v_pending_fixture_count integer := 0;
  v_mini_challenge_count integer := 0;
  v_correlation_id uuid;

  v_input_manifest jsonb;
  v_fixtures jsonb := '[]'::jsonb;
  v_one_to_one_preview jsonb;
  v_digital_twin jsonb;

  v_input_hash text;
  v_builder_output_hash text;
  v_output_hash text;
  v_simulation_hash text;

  v_fixture record;
  v_home_strategy_id uuid;
  v_home_strategy_version integer;
  v_home_strategy_payload jsonb;
  v_away_strategy_id uuid;
  v_away_strategy_version integer;
  v_away_strategy_payload jsonb;
  v_home_valid boolean;
  v_away_valid boolean;
  v_home_matrix jsonb;
  v_away_matrix jsonb;
  v_home_mini jsonb;
  v_away_mini jsonb;
  v_home_wins integer;
  v_away_wins integer;
  v_draws integer;
  v_matrix_home_wins integer;
  v_matrix_away_wins integer;
  v_matrix_draws integer;
  v_fixture_phase text;
  v_fixture_status text;
  v_fixture_json jsonb;
  v_provisional boolean;
  v_home_provisional boolean;
  v_away_provisional boolean;
begin
  if p_source_simulation_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'SOURCE_SIMULATION_REQUIRED';
  end if;

  if nullif(btrim(p_simulation_engine_version), '') is null then
    raise exception using
      errcode = 'P0001',
      message = 'SIMULATION_ENGINE_VERSION_REQUIRED';
  end if;

  select rs.*
  into v_source
  from public.round_simulations rs
  where rs.id = p_source_simulation_id;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'SOURCE_SIMULATION_NOT_FOUND';
  end if;

  if v_source.status not in (
       'preview_ready',
       'preview_invalidated',
       'awaiting_certification',
       'certified'
     )
     or not (v_source.digital_twin ? 'points_preview')
     or v_source.digital_twin ? 'one_to_one_preview'
     or v_source.simulation_hash is null then
    raise exception using
      errcode = 'P0001',
      message = 'SOURCE_POINTS_PREVIEW_NOT_READY',
      detail = v_source.status;
  end if;

  select rcr.*
  into v_run
  from public.round_calculation_runs rcr
  where rcr.id = v_source.calculation_run_id;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'CALCULATION_RUN_NOT_FOUND';
  end if;

  select lr.*
  into v_round
  from public.league_rounds lr
  where lr.id = v_source.league_round_id;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_ROUND_NOT_FOUND';
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

  select lsv.id, lsv.version
  into v_schedule_id, v_schedule_version
  from public.league_schedule_versions lsv
  join public.league_fixtures lf
    on lf.schedule_version_id = lsv.id
  where lf.league_round_id = v_round.id
    and lf.mode = 'one_to_one'
    and lsv.active = true
  order by lsv.version desc
  limit 1;

  if v_schedule_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'ACTIVE_ONE_TO_ONE_SCHEDULE_NOT_FOUND';
  end if;

  select lsp.*
  into v_profile
  from public.league_scoring_profiles lsp
  where lsp.id = v_run.scoring_profile_id;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'SCORING_PROFILE_NOT_FOUND';
  end if;

  -- Historical Calculation Runs may reference rules schema v1. Compose the
  -- frozen v2 contract deterministically without mutating their profile.
  v_rules := jsonb_build_object(
    'schema_version', 2,
    'match_count', coalesce(
      (v_profile.one_to_one_rules ->> 'match_count')::integer,
      10
    ),
    'matrix_count', 2,
    'pairings_per_matrix', 10,
    'pairing_matrix', coalesce(
      v_profile.one_to_one_rules ->> 'pairing_matrix',
      '10x10'
    ),
    'mini_challenge', jsonb_build_object(
      'score_source', 'base_total',
      'comparison', 'higher_wins',
      'equal_result', 'draw'
    ),
    'aggregate_result', jsonb_build_object(
      'source', 'total_mini_wins',
      'comparison', 'higher_wins',
      'equal_result', 'draw'
    )
  );

  if (v_rules ->> 'match_count')::integer <> 10
     or (v_rules ->> 'matrix_count')::integer <> 2
     or (v_rules ->> 'pairings_per_matrix')::integer <> 10 then
    raise exception using
      errcode = 'P0001',
      message = 'ONE_TO_ONE_RULES_INVALID';
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
       )
       and v_existing.digital_twin ? 'one_to_one_preview' then
      return query
      select
        v_existing.id,
        p_source_simulation_id,
        v_existing.league_round_id,
        v_existing.calculation_run_id,
        v_existing.simulation_version,
        v_existing.status,
        coalesce(
          (
            select sbr.status
            from public.round_simulation_builder_runs sbr
            where sbr.simulation_id = v_existing.id
              and sbr.builder_name = 'OneToOnePreviewBuilder'
            limit 1
          ),
          'completed'
        ),
        coalesce(
          jsonb_array_length(
            v_existing.digital_twin #> '{one_to_one_preview,fixtures}'
          ),
          0
        ),
        coalesce(
          (v_existing.digital_twin #>> '{one_to_one_preview,complete_fixture_count}')::integer,
          0
        ),
        coalesce(
          (v_existing.digital_twin #>> '{one_to_one_preview,pending_fixture_count}')::integer,
          0
        ),
        coalesce(
          (v_existing.digital_twin #>> '{one_to_one_preview,mini_challenge_count}')::integer,
          0
        ),
        v_existing.input_hash,
        v_existing.output_hash,
        v_existing.simulation_hash;
      return;
    end if;

    raise exception using
      errcode = 'P0001',
      message = 'ONE_TO_ONE_SIMULATION_EXISTING_NOT_REUSABLE',
      detail = v_existing.status;
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(
      'one-to-one-preview-simulation:' || v_round.id::text,
      0
    )
  );

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
       )
       and v_existing.digital_twin ? 'one_to_one_preview' then
      return query
      select
        v_existing.id,
        p_source_simulation_id,
        v_existing.league_round_id,
        v_existing.calculation_run_id,
        v_existing.simulation_version,
        v_existing.status,
        'completed'::text,
        coalesce(
          jsonb_array_length(
            v_existing.digital_twin #> '{one_to_one_preview,fixtures}'
          ),
          0
        ),
        coalesce(
          (v_existing.digital_twin #>> '{one_to_one_preview,complete_fixture_count}')::integer,
          0
        ),
        coalesce(
          (v_existing.digital_twin #>> '{one_to_one_preview,pending_fixture_count}')::integer,
          0
        ),
        coalesce(
          (v_existing.digital_twin #>> '{one_to_one_preview,mini_challenge_count}')::integer,
          0
        ),
        v_existing.input_hash,
        v_existing.output_hash,
        v_existing.simulation_hash;
      return;
    end if;

    raise exception using
      errcode = 'P0001',
      message = 'ONE_TO_ONE_SIMULATION_EXISTING_NOT_REUSABLE',
      detail = v_existing.status;
  end if;

  select count(*)::integer
  into v_fixture_count
  from public.league_fixtures lf
  where lf.league_round_id = v_round.id
    and lf.schedule_version_id = v_schedule_id
    and lf.mode = 'one_to_one';

  if v_fixture_count = 0 then
    raise exception using
      errcode = 'P0001',
      message = 'ONE_TO_ONE_FIXTURES_EMPTY';
  end if;

  select coalesce(max(rs.simulation_version), 0) + 1
  into v_simulation_version
  from public.round_simulations rs
  where rs.league_round_id = v_round.id;

  v_correlation_id := coalesce(
    p_correlation_id,
    v_source.correlation_id,
    gen_random_uuid()
  );

  v_input_manifest := jsonb_build_object(
    'schema_version', 1,
    'simulation_engine', 'RoundSimulationEngine',
    'simulation_engine_version', p_simulation_engine_version,
    'builder_name', 'OneToOnePreviewBuilder',
    'builder_version', 'one-to-one-preview-v1',
    'source_simulation_id', v_source.id,
    'source_simulation_version', v_source.simulation_version,
    'source_simulation_hash', v_source.simulation_hash,
    'league_round_id', v_round.id,
    'schedule_version_id', v_schedule_id,
    'schedule_version', v_schedule_version,
    'calculation_run_id', v_run.id,
    'scoring_profile_id', v_profile.id,
    'scoring_profile_version', v_profile.version,
    'one_to_one_rules', v_rules,
    'strategies', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'fixture_id', s.league_fixture_id,
            'league_member_id', s.league_member_id,
            'strategy_id', s.id,
            'strategy_version', s.submitted_version,
            'payload', sv.payload
          )
          order by s.league_fixture_id, s.league_member_id
        )
        from public.strategies s
        join public.strategy_versions sv
          on sv.strategy_id = s.id
         and sv.version = s.submitted_version
        join public.league_fixtures lf
          on lf.id = s.league_fixture_id
        where s.league_round_id = v_round.id
          and lf.schedule_version_id = v_schedule_id
          and lf.mode = 'one_to_one'
          and s.submitted_version is not null
          and s.status in ('submitted', 'locked')
          and sv.status in ('submitted', 'locked')
      ),
      '[]'::jsonb
    )
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
      'source_simulation_id', v_source.id,
      'builder', 'OneToOnePreviewBuilder'
    ),
    v_correlation_id,
    p_created_by_member_id
  );

  -- Register the inherited Points Preview dependency.
  insert into public.round_simulation_builder_runs (
    simulation_id,
    builder_name,
    builder_version,
    builder_order,
    required,
    status,
    started_at,
    completed_at,
    input_hash,
    output_hash,
    metadata
  )
  values (
    v_simulation.id,
    'PointsPreviewBuilder',
    'points-preview-v1',
    1,
    true,
    'completed',
    v_source.created_at,
    coalesce(v_source.completed_at, v_source.created_at),
    v_source.input_hash,
    coalesce(
      (
        select sbr.output_hash
        from public.round_simulation_builder_runs sbr
        where sbr.simulation_id = v_source.id
          and sbr.builder_name = 'PointsPreviewBuilder'
        limit 1
      ),
      public.compute_jsonb_sha256(v_source.digital_twin -> 'points_preview')
    ),
    jsonb_build_object(
      'inherited', true,
      'source_simulation_id', v_source.id
    )
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
    'OneToOnePreviewBuilder',
    'one-to-one-preview-v1',
    2,
    true,
    'running',
    clock_timestamp(),
    v_input_hash,
    jsonb_build_object(
      'source_simulation_id', v_source.id,
      'fixture_count', v_fixture_count,
      'schedule_version_id', v_schedule_id,
      'schedule_version', v_schedule_version
    )
  )
  returning * into v_builder;

  -- Build each active One-to-One fixture independently.
  for v_fixture in
    select
      lf.*,
      hm.user_id as home_user_id,
      hm.display_name as home_display_name,
      am.user_id as away_user_id,
      am.display_name as away_display_name
    from public.league_fixtures lf
    join public.league_members hm
      on hm.id = lf.home_member_id
    left join public.league_members am
      on am.id = lf.away_member_id
    where lf.league_round_id = v_round.id
      and lf.schedule_version_id = v_schedule_id
      and lf.mode = 'one_to_one'
    order by lf.pairing_round_number, lf.id
  loop
    v_home_matrix := null;
    v_away_matrix := null;
    v_home_mini := '[]'::jsonb;
    v_away_mini := '[]'::jsonb;
    v_home_wins := 0;
    v_away_wins := 0;
    v_draws := 0;
    v_provisional := true;

    if v_fixture.is_bye then
      v_fixture_phase := 'bye';
      v_fixture_status := 'bye';
    else
      v_home_strategy_id := null;
      v_home_strategy_version := null;
      v_home_strategy_payload := null;
      v_away_strategy_id := null;
      v_away_strategy_version := null;
      v_away_strategy_payload := null;

      select
        s.id,
        s.submitted_version,
        sv.payload
      into
        v_home_strategy_id,
        v_home_strategy_version,
        v_home_strategy_payload
      from public.strategies s
      join public.strategy_versions sv
        on sv.strategy_id = s.id
       and sv.version = s.submitted_version
      where s.league_fixture_id = v_fixture.id
        and s.league_member_id = v_fixture.home_member_id
        and s.submitted_version is not null
        and s.status in ('submitted', 'locked')
        and sv.status in ('submitted', 'locked')
      limit 1;

      v_home_valid := v_home_strategy_id is not null
        and public.validate_one_to_one_strategy_payload(
        v_home_strategy_payload,
        v_run.id,
        v_fixture.home_member_id,
        v_fixture.away_member_id
      );

      select
        s.id,
        s.submitted_version,
        sv.payload
      into
        v_away_strategy_id,
        v_away_strategy_version,
        v_away_strategy_payload
      from public.strategies s
      join public.strategy_versions sv
        on sv.strategy_id = s.id
       and sv.version = s.submitted_version
      where s.league_fixture_id = v_fixture.id
        and s.league_member_id = v_fixture.away_member_id
        and s.submitted_version is not null
        and s.status in ('submitted', 'locked')
        and sv.status in ('submitted', 'locked')
      limit 1;

      v_away_valid := v_away_strategy_id is not null
        and public.validate_one_to_one_strategy_payload(
        v_away_strategy_payload,
        v_run.id,
        v_fixture.away_member_id,
        v_fixture.home_member_id
      );

      if v_home_valid and v_away_valid then
        -- Matrix selected by the home member.
        with pairing_rows as (
          select
            (x ->> 'position')::integer as position,
            (x ->> 'own_match_id')::uuid as own_match_id,
            (x ->> 'opponent_match_id')::uuid as opponent_match_id
          from jsonb_array_elements(v_home_strategy_payload -> 'pairings') x
        ), scored as (
          select
            pr.*,
            own.base_total as own_points,
            opponent.base_total as opponent_points,
            own.provisional or opponent.provisional as provisional,
            case
              when own.base_total > opponent.base_total then 'home_win'
              when own.base_total < opponent.base_total then 'away_win'
              else 'draw'
            end as result
          from pairing_rows pr
          join public.prediction_score_runtime_results own
            on own.calculation_run_id = v_run.id
           and own.league_member_id = v_fixture.home_member_id
           and own.match_id = pr.own_match_id
          join public.prediction_score_runtime_results opponent
            on opponent.calculation_run_id = v_run.id
           and opponent.league_member_id = v_fixture.away_member_id
           and opponent.match_id = pr.opponent_match_id
        )
        select
          coalesce(
            jsonb_agg(
              jsonb_build_object(
                'position', s.position,
                'own_match_id', s.own_match_id,
                'opponent_match_id', s.opponent_match_id,
                'result', s.result
              )
              order by s.position
            ),
            '[]'::jsonb
          ),
          count(*) filter (where s.result = 'home_win')::integer,
          count(*) filter (where s.result = 'away_win')::integer,
          count(*) filter (where s.result = 'draw')::integer,
          coalesce(bool_or(s.provisional), true)
        into
          v_home_mini,
          v_matrix_home_wins,
          v_matrix_away_wins,
          v_matrix_draws,
          v_home_provisional
        from scored s;

        v_home_wins := v_home_wins + v_matrix_home_wins;
        v_away_wins := v_away_wins + v_matrix_away_wins;
        v_draws := v_draws + v_matrix_draws;

        v_home_matrix := jsonb_build_object(
          'owner_member_id', v_fixture.home_member_id,
          'strategy_id', v_home_strategy_id,
          'strategy_version', v_home_strategy_version,
          'mini_challenges', v_home_mini,
          'home_wins', v_matrix_home_wins,
          'draws', v_matrix_draws,
          'away_wins', v_matrix_away_wins
        );

        -- Matrix selected by the away member. Results are normalized to the
        -- fixture perspective: an away own-score win becomes away_win.
        with pairing_rows as (
          select
            (x ->> 'position')::integer as position,
            (x ->> 'own_match_id')::uuid as own_match_id,
            (x ->> 'opponent_match_id')::uuid as opponent_match_id
          from jsonb_array_elements(v_away_strategy_payload -> 'pairings') x
        ), scored as (
          select
            pr.*,
            own.base_total as own_points,
            opponent.base_total as opponent_points,
            own.provisional or opponent.provisional as provisional,
            case
              when own.base_total > opponent.base_total then 'away_win'
              when own.base_total < opponent.base_total then 'home_win'
              else 'draw'
            end as result
          from pairing_rows pr
          join public.prediction_score_runtime_results own
            on own.calculation_run_id = v_run.id
           and own.league_member_id = v_fixture.away_member_id
           and own.match_id = pr.own_match_id
          join public.prediction_score_runtime_results opponent
            on opponent.calculation_run_id = v_run.id
           and opponent.league_member_id = v_fixture.home_member_id
           and opponent.match_id = pr.opponent_match_id
        )
        select
          coalesce(
            jsonb_agg(
              jsonb_build_object(
                'position', s.position,
                'own_match_id', s.own_match_id,
                'opponent_match_id', s.opponent_match_id,
                'result', s.result
              )
              order by s.position
            ),
            '[]'::jsonb
          ),
          count(*) filter (where s.result = 'home_win')::integer,
          count(*) filter (where s.result = 'away_win')::integer,
          count(*) filter (where s.result = 'draw')::integer,
          coalesce(bool_or(s.provisional), true)
        into
          v_away_mini,
          v_matrix_home_wins,
          v_matrix_away_wins,
          v_matrix_draws,
          v_away_provisional
        from scored s;

        v_home_wins := v_home_wins + v_matrix_home_wins;
        v_away_wins := v_away_wins + v_matrix_away_wins;
        v_draws := v_draws + v_matrix_draws;

        v_provisional := coalesce(v_home_provisional, true)
          or coalesce(v_away_provisional, true);

        v_away_matrix := jsonb_build_object(
          'owner_member_id', v_fixture.away_member_id,
          'strategy_id', v_away_strategy_id,
          'strategy_version', v_away_strategy_version,
          'mini_challenges', v_away_mini,
          'home_wins', v_matrix_home_wins,
          'draws', v_matrix_draws,
          'away_wins', v_matrix_away_wins
        );

        v_fixture_phase := 'ready';
        v_fixture_status := 'complete';
        v_mini_challenge_count := v_mini_challenge_count + 20;
        v_complete_fixture_count := v_complete_fixture_count + 1;
      else
        v_fixture_phase := 'strategy_incomplete';
        v_fixture_status := 'pending';
        v_pending_fixture_count := v_pending_fixture_count + 1;
      end if;
    end if;

    if v_fixture.is_bye then
      v_complete_fixture_count := v_complete_fixture_count + 1;
    end if;

    v_fixture_json := jsonb_build_object(
      'fixture_id', v_fixture.id,
      'schedule_version_id', v_schedule_id,
      'schedule_version', v_schedule_version,
      'mode', 'one_to_one',
      'status', v_fixture_status,
      'fixture_phase', v_fixture_phase,
      'cycle_number', v_fixture.cycle_number,
      'leg_number', v_fixture.leg_number,
      'pairing_round_number', v_fixture.pairing_round_number,
      'is_bye', v_fixture.is_bye,
      'provisional', v_provisional,
      'home_member_id', v_fixture.home_member_id,
      'away_member_id', v_fixture.away_member_id,
      'home_user_id', v_fixture.home_user_id,
      'away_user_id', v_fixture.away_user_id,
      'home', jsonb_build_object(
        'member_id', v_fixture.home_member_id,
        'display_name', v_fixture.home_display_name
      ),
      'away', case
        when v_fixture.away_member_id is null then null
        else jsonb_build_object(
          'member_id', v_fixture.away_member_id,
          'display_name', v_fixture.away_display_name
        )
      end,
      'matrix_home', v_home_matrix,
      'matrix_away', v_away_matrix,
      'aggregate', case
        when v_fixture_phase <> 'ready' then null
        else jsonb_build_object(
          'home_wins', v_home_wins,
          'draws', v_draws,
          'away_wins', v_away_wins,
          'winner', case
            when v_home_wins > v_away_wins then 'home'
            when v_home_wins < v_away_wins then 'away'
            else 'draw'
          end
        )
      end
    );

    v_fixtures := v_fixtures || jsonb_build_array(v_fixture_json);
  end loop;

  v_one_to_one_preview := jsonb_build_object(
    'schema_version', 1,
    'builder', 'OneToOnePreviewBuilder',
    'builder_version', 'one-to-one-preview-v1',
    'source_simulation_id', v_source.id,
    'schedule_version_id', v_schedule_id,
    'schedule_version', v_schedule_version,
    'scoring_profile_id', v_profile.id,
    'scoring_profile_version', v_profile.version,
    'rules', v_rules,
    'fixture_count', v_fixture_count,
    'complete_fixture_count', v_complete_fixture_count,
    'pending_fixture_count', v_pending_fixture_count,
    'mini_challenge_count', v_mini_challenge_count,
    'fixtures', v_fixtures
  );

  v_builder_output_hash := public.compute_jsonb_sha256(v_one_to_one_preview);

  v_digital_twin := jsonb_set(
    v_source.digital_twin,
    '{one_to_one_preview}',
    v_one_to_one_preview,
    true
  );

  v_digital_twin := jsonb_set(
    v_digital_twin,
    '{manifest}',
    (v_digital_twin -> 'manifest') || jsonb_build_object(
      'engine_version', p_simulation_engine_version,
      'simulation_id', v_simulation.id,
      'simulation_version', v_simulation_version,
      'source_simulation_id', v_source.id,
      'source_simulation_hash', v_source.simulation_hash,
      'one_to_one_preview_hash', v_builder_output_hash,
      'one_to_one_rules_schema_version', 2
    ),
    true
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
    output_hash = v_builder_output_hash,
    metadata = sbr.metadata || jsonb_build_object(
      'complete_fixture_count', v_complete_fixture_count,
      'pending_fixture_count', v_pending_fixture_count,
      'mini_challenge_count', v_mini_challenge_count
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
      'builder_output_hash', v_builder_output_hash,
      'fixture_count', v_fixture_count,
      'complete_fixture_count', v_complete_fixture_count,
      'pending_fixture_count', v_pending_fixture_count,
      'mini_challenge_count', v_mini_challenge_count
    ),
    v_correlation_id,
    v_builder.id,
    p_created_by_member_id
  );

  -- Parallel branch: do not invalidate or replace the Fantacalcio branch.
  -- This artifact remains non-publishable until Standings Preview merges both
  -- mode branches into one current Digital Twin.
  update public.round_simulations rs
  set
    status = 'preview_ready',
    preview = true,
    publishable = false,
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
      'publishable', false,
      'branch', 'one_to_one',
      'builders_completed', jsonb_build_array(
        'PointsPreviewBuilder',
        'OneToOnePreviewBuilder'
      )
    ),
    v_correlation_id,
    p_created_by_member_id
  );

  return query
  select
    v_simulation.id,
    v_source.id,
    v_simulation.league_round_id,
    v_simulation.calculation_run_id,
    v_simulation.simulation_version,
    v_simulation.status,
    v_builder.status,
    v_fixture_count,
    v_complete_fixture_count,
    v_pending_fixture_count,
    v_mini_challenge_count,
    v_simulation.input_hash,
    v_simulation.output_hash,
    v_simulation.simulation_hash;

exception
  when others then
    if v_builder.id is not null then
      update public.round_simulation_builder_runs sbr
      set
        status = 'failed',
        completed_at = clock_timestamp(),
        error_code = sqlstate,
        error_message = sqlerrm
      where sbr.id = v_builder.id;
    end if;

    if v_simulation.id is not null then
      update public.round_simulations rs
      set
        status = 'failed',
        publishable = false,
        failed_at = clock_timestamp(),
        failure_details = jsonb_build_object(
          'sqlstate', sqlstate,
          'message', sqlerrm,
          'source_simulation_id', p_source_simulation_id
        )
      where rs.id = v_simulation.id
        and rs.status = 'building';
    end if;

    raise;
end;
$function$;

-- ============================================================================
-- 4. AUTHENTICATED MEMBER READ RPC
-- ============================================================================


comment on function public.build_one_to_one_preview_simulation_rpc(uuid, text, uuid, uuid) is
  'Builds the immutable parallel One-to-One Preview branch and exposes canonical home/away member and user identifiers at fixture root, alongside the existing nested presentation nodes. Service-role only.';

revoke all on function public.build_one_to_one_preview_simulation_rpc(uuid, text, uuid, uuid) from public;
revoke all on function public.build_one_to_one_preview_simulation_rpc(uuid, text, uuid, uuid) from anon;
revoke all on function public.build_one_to_one_preview_simulation_rpc(uuid, text, uuid, uuid) from authenticated;
grant execute on function public.build_one_to_one_preview_simulation_rpc(uuid, text, uuid, uuid) to service_role;

commit;
