-- =====================================================================
-- FANTAGOL - MIGRATION 293
-- HEAD-TO-HEAD FORFEIT AUTHORITY
-- Fantacalcio + One-to-One + Standings
--
-- Contract:
--   VALID vs VALID       => NORMAL
--   VALID vs MISSING     => 3-0 forfeit win for VALID
--   MISSING vs VALID     => 0-3 forfeit loss for MISSING
--   MISSING vs MISSING   => DOUBLE FORFEIT:
--                            HOME 0-3 LOSS
--                            AWAY 0-3 LOSS
--                            0 competition points each
--                            no draw / no winner
--
-- Punti Puri is deliberately out of scope.
-- Scoring components, Fantacalcio row contributions and One-to-One
-- mini-challenge arithmetic are not modified by this migration.
-- =====================================================================

begin;
CREATE OR REPLACE FUNCTION public.build_fantacalcio_preview_simulation_rpc(p_source_simulation_id uuid, p_simulation_engine_version text DEFAULT 'round-simulation-v1-fantacalcio-v1'::text, p_created_by_member_id uuid DEFAULT NULL::uuid, p_correlation_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(simulation_id uuid, source_simulation_id uuid, league_round_id uuid, calculation_run_id uuid, simulation_version integer, simulation_status text, builder_status text, fixture_count integer, complete_fixture_count integer, pending_fixture_count integer, input_hash text, output_hash text, simulation_hash text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_source public.round_simulations%rowtype;
  v_existing public.round_simulations%rowtype;
  v_round public.league_rounds%rowtype;
  v_run public.round_calculation_runs%rowtype;
  v_simulation public.round_simulations%rowtype;
  v_builder public.round_simulation_builder_runs%rowtype;
  v_profile public.league_scoring_profiles%rowtype;

  v_schedule_id uuid;
  v_schedule_version integer;
  v_rules jsonb;
  v_simulation_version integer;
  v_fixture_count integer;
  v_complete_fixture_count integer;
  v_pending_fixture_count integer;
  v_correlation_id uuid;

  v_input_manifest jsonb;
  v_fixtures jsonb;
  v_member_results jsonb;
  v_fantacalcio_preview jsonb;
  v_digital_twin jsonb;

  v_input_hash text;
  v_builder_output_hash text;
  v_output_hash text;
  v_simulation_hash text;
begin
  if p_source_simulation_id is null then
    raise exception using errcode = 'P0001', message = 'SOURCE_SIMULATION_REQUIRED';
  end if;

  if nullif(btrim(p_simulation_engine_version), '') is null then
    raise exception using errcode = 'P0001', message = 'SIMULATION_ENGINE_VERSION_REQUIRED';
  end if;

  select rs.* into v_source
  from public.round_simulations rs
  where rs.id = p_source_simulation_id;

  if not found then
    raise exception using errcode = 'P0001', message = 'SOURCE_SIMULATION_NOT_FOUND';
  end if;

  if not (v_source.digital_twin ? 'points_preview') then
    raise exception using errcode = 'P0001', message = 'POINTS_PREVIEW_REQUIRED';
  end if;

  select lr.* into v_round
  from public.league_rounds lr
  where lr.id = v_source.league_round_id;

  if not found then
    raise exception using errcode = 'P0001', message = 'LEAGUE_ROUND_NOT_FOUND';
  end if;

  select rcr.* into v_run
  from public.round_calculation_runs rcr
  where rcr.id = v_source.calculation_run_id;

  if not found then
    raise exception using errcode = 'P0001', message = 'CALCULATION_RUN_NOT_FOUND';
  end if;

  if p_created_by_member_id is not null and not exists (
    select 1
    from public.league_members lm
    where lm.id = p_created_by_member_id
      and lm.league_id = v_round.league_id
      and lm.status = 'active'
  ) then
    raise exception using errcode = 'P0001', message = 'CREATOR_MEMBERSHIP_INVALID';
  end if;

  select lsv.id, lsv.version
  into v_schedule_id, v_schedule_version
  from public.league_schedule_versions lsv
  join public.league_fixtures lf on lf.schedule_version_id = lsv.id
  where lf.league_round_id = v_round.id
    and lsv.active = true
  order by lsv.version desc
  limit 1;

  if v_schedule_id is null then
    raise exception using errcode = 'P0001', message = 'ACTIVE_LEAGUE_SCHEDULE_NOT_FOUND';
  end if;

  select lsp.* into v_profile
  from public.league_scoring_profiles lsp
  where lsp.id = v_run.scoring_profile_id;

  if not found then
    raise exception using errcode = 'P0001', message = 'SCORING_PROFILE_NOT_FOUND';
  end if;

  v_rules := jsonb_build_object(
    'schema_version', 2,
    'attack_exact_multiplier', coalesce((v_profile.fantacalcio_rules ->> 'attack_exact_multiplier')::numeric, 2),
    'attack_opposite_sign_multiplier', coalesce((v_profile.fantacalcio_rules ->> 'attack_opposite_sign_multiplier')::numeric, 2),
    'attack_cantonata_multiplier', coalesce((v_profile.fantacalcio_rules ->> 'attack_cantonata_multiplier')::numeric, 2),
    'attack_surprise_multiplier', coalesce((v_profile.fantacalcio_rules ->> 'attack_surprise_multiplier')::numeric, 2),
    'defence_malus_divisor', coalesce((v_profile.fantacalcio_rules ->> 'defence_malus_divisor')::numeric, 2),
    'goal_profile', coalesce(
      v_profile.fantacalcio_rules -> 'goal_profile',
      jsonb_build_object(
        'profile_version', 1,
        'type', 'constant_threshold',
        'base_points', 23,
        'step_points', 10,
        'base_goals', 0
      )
    )
  );

  if (v_rules ->> 'attack_exact_multiplier')::numeric <= 0
     or (v_rules ->> 'attack_surprise_multiplier')::numeric <= 0
     or (v_rules ->> 'attack_opposite_sign_multiplier')::numeric <= 0
     or (v_rules ->> 'attack_cantonata_multiplier')::numeric <= 0
     or (v_rules ->> 'defence_malus_divisor')::numeric <= 0 then
    raise exception using errcode = 'P0001', message = 'FANTACALCIO_RULES_INVALID';
  end if;

  select rs.* into v_existing
  from public.round_simulations rs
  where rs.league_round_id = v_round.id
    and rs.calculation_run_id = v_run.id
    and rs.engine_version = p_simulation_engine_version
  limit 1;

  if found then
    if v_existing.status in ('preview_ready', 'awaiting_certification', 'certified')
       and v_existing.digital_twin ? 'fantacalcio_preview' then
      return query
      select
        v_existing.id,
        p_source_simulation_id,
        v_existing.league_round_id,
        v_existing.calculation_run_id,
        v_existing.simulation_version,
        v_existing.status,
        coalesce((
          select sbr.status
          from public.round_simulation_builder_runs sbr
          where sbr.simulation_id = v_existing.id
            and sbr.builder_name = 'FantacalcioPreviewBuilder'
          limit 1
        ), 'completed'),
        coalesce(jsonb_array_length(v_existing.digital_twin #> '{fantacalcio_preview,fixtures}'), 0),
        coalesce((v_existing.digital_twin #>> '{fantacalcio_preview,complete_fixture_count}')::integer, 0),
        coalesce((v_existing.digital_twin #>> '{fantacalcio_preview,pending_fixture_count}')::integer, 0),
        v_existing.input_hash,
        v_existing.output_hash,
        v_existing.simulation_hash;
      return;
    end if;

    raise exception using
      errcode = 'P0001',
      message = 'FANTACALCIO_SIMULATION_EXISTING_NOT_REUSABLE',
      detail = v_existing.status;
  end if;

  perform pg_advisory_xact_lock(hashtextextended(v_round.id::text || ':fantacalcio-preview', 0));

  select rs.* into v_existing
  from public.round_simulations rs
  where rs.league_round_id = v_round.id
    and rs.calculation_run_id = v_run.id
    and rs.engine_version = p_simulation_engine_version
  limit 1;

  if found then
    if v_existing.status in ('preview_ready', 'awaiting_certification', 'certified')
       and v_existing.digital_twin ? 'fantacalcio_preview' then
      return query
      select
        v_existing.id,
        p_source_simulation_id,
        v_existing.league_round_id,
        v_existing.calculation_run_id,
        v_existing.simulation_version,
        v_existing.status,
        'completed'::text,
        coalesce(jsonb_array_length(v_existing.digital_twin #> '{fantacalcio_preview,fixtures}'), 0),
        coalesce((v_existing.digital_twin #>> '{fantacalcio_preview,complete_fixture_count}')::integer, 0),
        coalesce((v_existing.digital_twin #>> '{fantacalcio_preview,pending_fixture_count}')::integer, 0),
        v_existing.input_hash,
        v_existing.output_hash,
        v_existing.simulation_hash;
      return;
    end if;

    raise exception using
      errcode = 'P0001',
      message = 'FANTACALCIO_SIMULATION_EXISTING_NOT_REUSABLE',
      detail = v_existing.status;
  end if;

  if exists (
    select 1
    from public.round_simulations rs
    where rs.league_round_id = v_round.id
      and rs.publishable = true
      and rs.status in ('awaiting_certification', 'certified')
      and rs.id <> v_source.id
  ) then
    raise exception using errcode = 'P0001', message = 'CURRENT_SIMULATION_NOT_REPLACEABLE';
  end if;

  select count(*)::integer
  into v_fixture_count
  from public.league_fixtures lf
  where lf.league_round_id = v_round.id
    and lf.schedule_version_id = v_schedule_id
    and lf.mode = 'fantacalcio';

  if v_fixture_count = 0 then
    raise exception using errcode = 'P0001', message = 'FANTACALCIO_FIXTURES_EMPTY';
  end if;

  select coalesce(max(rs.simulation_version), 0) + 1
  into v_simulation_version
  from public.round_simulations rs
  where rs.league_round_id = v_round.id;

  v_correlation_id := coalesce(p_correlation_id, v_source.correlation_id, gen_random_uuid());

  v_input_manifest := jsonb_build_object(
    'schema_version', 1,
    'simulation_engine', 'RoundSimulationEngine',
    'simulation_engine_version', p_simulation_engine_version,
    'builder_name', 'FantacalcioPreviewBuilder',
    'builder_version', 'fantacalcio-preview-v1-row-contributions-v1',
    'source_simulation_id', v_source.id,
    'source_simulation_version', v_source.simulation_version,
    'source_simulation_hash', v_source.simulation_hash,
    'league_round_id', v_round.id,
    'schedule_version_id', v_schedule_id,
    'schedule_version', v_schedule_version,
    'calculation_run_id', v_run.id,
    'scoring_profile_id', v_profile.id,
    'scoring_profile_version', v_profile.version,
    'fantacalcio_rules', v_rules
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
    simulation_id, league_round_id, calculation_run_id, event_type, payload,
    correlation_id, actor_member_id
  )
  values (
    v_simulation.id, v_round.id, v_run.id, 'RoundSimulationBuilding',
    jsonb_build_object(
      'simulation_version', v_simulation_version,
      'engine_version', p_simulation_engine_version,
      'source_simulation_id', v_source.id,
      'builder', 'FantacalcioPreviewBuilder'
    ),
    v_correlation_id, p_created_by_member_id
  );

  insert into public.round_simulation_builder_runs (
    simulation_id, builder_name, builder_version, builder_order, required, status,
    started_at, completed_at, input_hash, output_hash, metadata
  )
  values (
    v_simulation.id,
    'PointsPreviewBuilder',
    'inherited',
    1,
    true,
    'completed',
    v_source.created_at,
    coalesce(v_source.completed_at, v_source.created_at),
    v_source.input_hash,
    coalesce((
      select sbr.output_hash
      from public.round_simulation_builder_runs sbr
      where sbr.simulation_id = v_source.id
        and sbr.builder_name = 'PointsPreviewBuilder'
      limit 1
    ), public.compute_jsonb_sha256(v_source.digital_twin -> 'points_preview')),
    jsonb_build_object('inherited', true, 'source_simulation_id', v_source.id)
  );

  insert into public.round_simulation_builder_runs (
    simulation_id, builder_name, builder_version, builder_order, required, status,
    started_at, input_hash, metadata
  )
  values (
    v_simulation.id,
    'FantacalcioPreviewBuilder',
    'fantacalcio-preview-v1-row-contributions-v1',
    2,
    true,
    'running',
    clock_timestamp(),
    v_input_hash,
    jsonb_build_object(
      'source_simulation_id', v_source.id,
      'fixture_count', v_fixture_count,
      'schedule_version_id', v_schedule_id,
      'schedule_version', v_schedule_version,
      'goal_profile', v_rules -> 'goal_profile'
    )
  )
  returning * into v_builder;

  with fixture_members as (
    select lf.id as fixture_id, lf.home_member_id as league_member_id, 'home'::text as fixture_side
    from public.league_fixtures lf
    where lf.league_round_id = v_round.id
      and lf.schedule_version_id = v_schedule_id
      and lf.mode = 'fantacalcio'
      and not lf.is_bye

    union all

    select lf.id, lf.away_member_id, 'away'::text
    from public.league_fixtures lf
    where lf.league_round_id = v_round.id
      and lf.schedule_version_id = v_schedule_id
      and lf.mode = 'fantacalcio'
      and not lf.is_bye
      and lf.away_member_id is not null
  ), official_strategies as (
    select
      s.league_fixture_id as fixture_id,
      s.league_member_id,
      s.id as strategy_id,
      s.submitted_version as strategy_version,
      sv.payload
    from public.strategies s
    join public.strategy_versions sv
      on sv.strategy_id = s.id
     and sv.version = s.submitted_version
    join public.league_fixtures lf
      on lf.id = s.league_fixture_id
    where s.league_round_id = v_round.id
      and lf.schedule_version_id = v_schedule_id
      and lf.mode = 'fantacalcio'
      and s.submitted_version is not null
      and s.status in ('submitted', 'locked')
      and sv.status in ('submitted', 'locked')
      and jsonb_typeof(sv.payload -> 'allocations') = 'array'
  ), allocation_rows as (
    select
      os.fixture_id,
      os.league_member_id,
      os.strategy_id,
      os.strategy_version,
      a.match_id,
      a.department
    from official_strategies os
    cross join lateral (
      select
        (x ->> 'match_id')::uuid as match_id,
        x ->> 'department' as department
      from jsonb_array_elements(os.payload -> 'allocations') x
      where x ? 'match_id'
        and x ? 'department'
    ) a
  ), strategy_validation as (
    select
      os.fixture_id,
      os.league_member_id,
      os.strategy_id,
      os.strategy_version,
      count(ar.match_id)::integer as allocation_count,
      count(distinct ar.match_id)::integer as distinct_match_count,
      count(*) filter (where ar.department = 'attack')::integer as attack_count,
      count(*) filter (where ar.department = 'defense')::integer as defense_count,
      bool_and(ar.department in ('attack', 'defense')) as departments_valid,
      (
        count(ar.match_id) = 10
        and count(distinct ar.match_id) = 10
        and count(*) filter (where ar.department = 'attack') = 5
        and count(*) filter (where ar.department = 'defense') = 5
        and bool_and(ar.department in ('attack', 'defense'))
      ) as strategy_valid
    from official_strategies os
    left join allocation_rows ar
      on ar.fixture_id = os.fixture_id
     and ar.league_member_id = os.league_member_id
    group by os.fixture_id, os.league_member_id, os.strategy_id, os.strategy_version
  ), contribution_rows as (
    select
      fm.fixture_id,
      fm.league_member_id,
      fm.fixture_side,
      sv.strategy_id,
      sv.strategy_version,
      coalesce(sv.strategy_valid, false) as strategy_valid,
      ar.match_id,
      ar.department,
      psrr.provisional,
      case
        when not coalesce(sv.strategy_valid, false) then null
        when ar.department = 'attack' then
          (
            psrr.base_total
            + psrr.exact_points * ((v_rules ->> 'attack_exact_multiplier')::numeric - 1)
            + psrr.surprise_points * ((v_rules ->> 'attack_surprise_multiplier')::numeric - 1)
            + psrr.opposite_sign_points * ((v_rules ->> 'attack_opposite_sign_multiplier')::numeric - 1)
            + psrr.cantonata_points * ((v_rules ->> 'attack_cantonata_multiplier')::numeric - 1)
          )::numeric(12,2)
        when ar.department = 'defense' then
          (
            psrr.base_total
            - psrr.opposite_sign_points
            - psrr.cantonata_points
            + psrr.opposite_sign_points / (v_rules ->> 'defence_malus_divisor')::numeric
            + psrr.cantonata_points / (v_rules ->> 'defence_malus_divisor')::numeric
          )::numeric(12,2)
        else 0::numeric(12,2)
      end as contribution_points
    from fixture_members fm
    left join strategy_validation sv
      on sv.fixture_id = fm.fixture_id
     and sv.league_member_id = fm.league_member_id
    left join allocation_rows ar
      on ar.fixture_id = fm.fixture_id
     and ar.league_member_id = fm.league_member_id
    left join public.prediction_score_runtime_results psrr
      on psrr.calculation_run_id = v_run.id
     and psrr.league_member_id = fm.league_member_id
     and psrr.match_id = ar.match_id
  ), member_scores as (
    select
      cr.fixture_id,
      cr.league_member_id,
      cr.fixture_side,
      cr.strategy_id,
      cr.strategy_version,
      cr.strategy_valid,
      case
        when cr.strategy_valid then sum(cr.contribution_points)::numeric(12,2)
        else null
      end as fantacalcio_points,
      case
        when cr.strategy_valid then bool_or(cr.provisional)
        else true
      end as provisional,
      case
        when cr.strategy_valid then
          coalesce(
            jsonb_agg(
              jsonb_build_object(
                'match_id', cr.match_id,
                'department', cr.department,
                'points', cr.contribution_points,
                'provisional', coalesce(cr.provisional, true)
              )
              order by
                case when cr.department = 'attack' then 1 when cr.department = 'defense' then 2 else 3 end,
                cr.match_id
            ) filter (where cr.match_id is not null),
            '[]'::jsonb
          )
        else '[]'::jsonb
      end as contributions
    from contribution_rows cr
    group by
      cr.fixture_id,
      cr.league_member_id,
      cr.fixture_side,
      cr.strategy_id,
      cr.strategy_version,
      cr.strategy_valid
  ), scored_members as (
    select
      ms.*,
      case
        when ms.strategy_valid and ms.fantacalcio_points is not null then
          public.convert_fantacalcio_points_to_goals(ms.fantacalcio_points, v_rules)
        else null
      end as goals
    from member_scores ms
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'fixture_id', sm.fixture_id,
        'league_member_id', sm.league_member_id,
        'fixture_side', sm.fixture_side,
        'strategy_id', sm.strategy_id,
        'strategy_version', sm.strategy_version,
        'strategy_valid', sm.strategy_valid,
        'points', sm.fantacalcio_points,
        'goals', sm.goals,
        'provisional', sm.provisional,
        'contributions', sm.contributions
      )
      order by sm.fixture_id, sm.fixture_side
    ),
    '[]'::jsonb
  )
  into v_member_results
  from scored_members sm;

  with member_rows as (
    select
      (x ->> 'fixture_id')::uuid as fixture_id,
      x ->> 'fixture_side' as fixture_side,
      (x ->> 'league_member_id')::uuid as league_member_id,
      nullif(x ->> 'strategy_id', '')::uuid as strategy_id,
      nullif(x ->> 'strategy_version', '')::integer as strategy_version,
      coalesce((x ->> 'strategy_valid')::boolean, false) as strategy_valid,
      nullif(x ->> 'points', '')::numeric as points,
      nullif(x ->> 'goals', '')::integer as goals,
      coalesce((x ->> 'provisional')::boolean, true) as provisional,
      coalesce(x -> 'contributions', '[]'::jsonb) as contributions
    from jsonb_array_elements(v_member_results) x
  ), fixture_rows as (
    select
      lf.id as fixture_id,
      lf.cycle_number,
      lf.leg_number,
      lf.pairing_round_number,
      lf.home_member_id,
      lf.away_member_id,
      lf.is_bye,
      hm.display_name as home_display_name,
      am.display_name as away_display_name,
      h.strategy_id as home_strategy_id,
      h.strategy_version as home_strategy_version,
      h.strategy_valid as home_strategy_valid,
      h.points as home_points,
      h.goals as home_goals,
      h.contributions as home_contributions,
      a.strategy_id as away_strategy_id,
      a.strategy_version as away_strategy_version,
      a.strategy_valid as away_strategy_valid,
      a.points as away_points,
      a.goals as away_goals,
      a.contributions as away_contributions,
      coalesce(h.provisional, true) or coalesce(a.provisional, true) as provisional,
      case
        when lf.is_bye then 'bye'
        when coalesce(h.strategy_valid, false)
         and coalesce(a.strategy_valid, false)
         and h.goals is not null
         and a.goals is not null then 'ready'
        else 'strategy_incomplete'
      end as fixture_phase
    from public.league_fixtures lf
    join public.league_members hm on hm.id = lf.home_member_id
    left join public.league_members am on am.id = lf.away_member_id
    left join member_rows h
      on h.fixture_id = lf.id
     and h.fixture_side = 'home'
    left join member_rows a
      on a.fixture_id = lf.id
     and a.fixture_side = 'away'
    where lf.league_round_id = v_round.id
      and lf.schedule_version_id = v_schedule_id
      and lf.mode = 'fantacalcio'
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'fixture_id', fr.fixture_id,
        'schedule_version_id', v_schedule_id,
        'schedule_version', v_schedule_version,
        'mode', 'fantacalcio',
        'status', case
          when fr.fixture_phase = 'ready' then 'complete'
          when fr.fixture_phase = 'bye' then 'bye'
          else 'pending'
        end,
        'cycle_number', fr.cycle_number,
        'leg_number', fr.leg_number,
        'pairing_round_number', fr.pairing_round_number,
        'is_bye', fr.is_bye,
        'fixture_phase', fr.fixture_phase,
        'provisional', fr.provisional,
        'home', jsonb_build_object(
          'member_id', fr.home_member_id,
          'display_name', fr.home_display_name,
          'strategy_id', fr.home_strategy_id,
          'strategy_version', fr.home_strategy_version,
          'strategy_valid', coalesce(fr.home_strategy_valid, false),
          'points', fr.home_points,
          'goals', fr.home_goals,
          'contributions', coalesce(fr.home_contributions, '[]'::jsonb)
        ),
        'away', case
          when fr.away_member_id is null then null
          else jsonb_build_object(
            'member_id', fr.away_member_id,
            'display_name', fr.away_display_name,
            'strategy_id', fr.away_strategy_id,
            'strategy_version', fr.away_strategy_version,
            'strategy_valid', coalesce(fr.away_strategy_valid, false),
            'points', fr.away_points,
            'goals', fr.away_goals,
            'contributions', coalesce(fr.away_contributions, '[]'::jsonb)
          )
        end,
        'result', case
          when fr.fixture_phase <> 'ready' then null
          else jsonb_build_object(
            'home_goals', fr.home_goals,
            'away_goals', fr.away_goals,
            'goal_difference', fr.home_goals - fr.away_goals,
            'winner', case
              when fr.home_goals > fr.away_goals then 'home'
              when fr.home_goals < fr.away_goals then 'away'
              else 'draw'
            end
          )
        end
      )
      order by fr.pairing_round_number, fr.fixture_id
    ),
    '[]'::jsonb
  )
  into v_fixtures
  from fixture_rows fr;

  select
    count(*) filter (where x ->> 'fixture_phase' in ('ready', 'bye'))::integer,
    count(*) filter (where x ->> 'fixture_phase' = 'strategy_incomplete')::integer
  into v_complete_fixture_count, v_pending_fixture_count
  from jsonb_array_elements(v_fixtures) x;

  -- R53: Head-to-head participation authority.
  -- Scoring/contribution rows remain untouched. This layer governs only
  -- the competitive fixture result after strategy validity is known.
  select coalesce(
    jsonb_agg(
      case
        when coalesce((f #>> '{home,strategy_valid}')::boolean, false)
         and coalesce((f #>> '{away,strategy_valid}')::boolean, false)
        then
          f || jsonb_build_object(
            'result',
            (case when jsonb_typeof(f -> 'result') = 'object' then f -> 'result' else '{}'::jsonb end)
              || jsonb_build_object('authority', 'normal')
          )

        when coalesce((f #>> '{home,strategy_valid}')::boolean, false)
         and not coalesce((f #>> '{away,strategy_valid}')::boolean, false)
        then
          f
          || jsonb_build_object(
               'status', 'complete',
               'fixture_phase', 'forfeit',
               'home', coalesce(f -> 'home', '{}'::jsonb)
                 || jsonb_build_object('goals', 3),
               'away', coalesce(f -> 'away', '{}'::jsonb)
                 || jsonb_build_object('goals', 0),
               'result', (case when jsonb_typeof(f -> 'result') = 'object' then f -> 'result' else '{}'::jsonb end)
                 || jsonb_build_object(
                      'authority', 'single_forfeit',
                      'winner', 'home',
                      'home_goals', 3,
                      'away_goals', 0
                    ),
               'forfeit', jsonb_build_object(
                 'type', 'single',
                 'winner', 'home',
                 'home_score', '3-0',
                 'away_score', '0-3'
               )
             )

        when not coalesce((f #>> '{home,strategy_valid}')::boolean, false)
         and coalesce((f #>> '{away,strategy_valid}')::boolean, false)
        then
          f
          || jsonb_build_object(
               'status', 'complete',
               'fixture_phase', 'forfeit',
               'home', coalesce(f -> 'home', '{}'::jsonb)
                 || jsonb_build_object('goals', 0),
               'away', coalesce(f -> 'away', '{}'::jsonb)
                 || jsonb_build_object('goals', 3),
               'result', (case when jsonb_typeof(f -> 'result') = 'object' then f -> 'result' else '{}'::jsonb end)
                 || jsonb_build_object(
                      'authority', 'single_forfeit',
                      'winner', 'away',
                      'home_goals', 0,
                      'away_goals', 3
                    ),
               'forfeit', jsonb_build_object(
                 'type', 'single',
                 'winner', 'away',
                 'home_score', '0-3',
                 'away_score', '3-0'
               )
             )

        else
          f
          || jsonb_build_object(
               'status', 'complete',
               'fixture_phase', 'double_forfeit',
               'result', (case when jsonb_typeof(f -> 'result') = 'object' then f -> 'result' else '{}'::jsonb end)
                 || jsonb_build_object(
                      'authority', 'double_forfeit',
                      'winner', null
                    ),
               'forfeit', jsonb_build_object(
                 'type', 'double',
                 'winner', null,
                 'home_score', '0-3',
                 'away_score', '0-3',
                 'home_outcome', 'loss',
                 'away_outcome', 'loss'
               )
             )
      end
      order by ord
    ),
    '[]'::jsonb
  )
  into v_fixtures
  from jsonb_array_elements(coalesce(v_fixtures, '[]'::jsonb))
       with ordinality as q(f, ord);


  -- R53: recompute builder readiness after forfeit materialization.
  -- Forfeit fixtures are competitively complete; scoring rows remain untouched.
  select
    count(*) filter (
      where x ->> 'fixture_phase' in ('ready', 'bye', 'forfeit', 'double_forfeit')
    )::integer,
    count(*) filter (
      where x ->> 'fixture_phase' = 'strategy_incomplete'
    )::integer
  into v_complete_fixture_count, v_pending_fixture_count
  from jsonb_array_elements(coalesce(v_fixtures, '[]'::jsonb)) x;v_fantacalcio_preview := jsonb_build_object(
    'schema_version', 2,
    'builder', 'FantacalcioPreviewBuilder',
    'builder_version', 'fantacalcio-preview-v1-row-contributions-v1',
    'source_simulation_id', v_source.id,
    'scoring_profile_id', v_profile.id,
    'scoring_profile_version', v_profile.version,
    'goal_profile', v_rules -> 'goal_profile',
    'schedule_version_id', v_schedule_id,
    'schedule_version', v_schedule_version,
    'fixture_count', v_fixture_count,
    'complete_fixture_count', v_complete_fixture_count,
    'pending_fixture_count', v_pending_fixture_count,
    'fixtures', v_fixtures
  );

  v_builder_output_hash := public.compute_jsonb_sha256(v_fantacalcio_preview);

  v_digital_twin := jsonb_set(
    v_source.digital_twin,
    '{fantacalcio_preview}',
    v_fantacalcio_preview,
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
      'fantacalcio_preview_hash', v_builder_output_hash,
      'fantacalcio_rules_schema_version', 2,
      'fantacalcio_preview_schema_version', 2,
      'goal_profile_version', 1
    ),
    true
  );

  v_output_hash := public.compute_jsonb_sha256(v_digital_twin);
  v_simulation_hash := encode(
    extensions.digest(v_input_hash || ':' || v_output_hash, 'sha256'),
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
      'row_contributions_materialized', true
    )
  where sbr.id = v_builder.id
  returning * into v_builder;

  insert into public.round_simulation_events (
    simulation_id, league_round_id, calculation_run_id, event_type, payload,
    correlation_id, causation_id, actor_member_id
  )
  values (
    v_simulation.id, v_round.id, v_run.id, 'SimulationBuilderCompleted',
    jsonb_build_object(
      'builder_name', v_builder.builder_name,
      'builder_version', v_builder.builder_version,
      'builder_output_hash', v_builder_output_hash,
      'fixture_count', v_fixture_count,
      'complete_fixture_count', v_complete_fixture_count,
      'pending_fixture_count', v_pending_fixture_count,
      'row_contributions_materialized', true
    ),
    v_correlation_id, v_builder.id, p_created_by_member_id
  );

  update public.round_simulations rs
  set
    status = 'preview_invalidated',
    publishable = false,
    invalidated_at = clock_timestamp(),
    invalidation_reason = 'superseded_by_fantacalcio_preview'
  where rs.id = v_source.id
    and rs.publishable = true
    and rs.status = 'preview_ready';

  update public.round_simulations rs
  set
    status = 'preview_ready',
    publishable = true,
    completed_at = clock_timestamp(),
    digital_twin = v_digital_twin,
    output_hash = v_output_hash,
    simulation_hash = v_simulation_hash
  where rs.id = v_simulation.id
  returning * into v_simulation;

  insert into public.round_simulation_events (
    simulation_id, league_round_id, calculation_run_id, event_type, payload,
    correlation_id, actor_member_id
  )
  values (
    v_simulation.id, v_round.id, v_run.id, 'RoundSimulationReady',
    jsonb_build_object(
      'simulation_version', v_simulation.simulation_version,
      'engine_version', v_simulation.engine_version,
      'simulation_hash', v_simulation.simulation_hash
    ),
    v_correlation_id, p_created_by_member_id
  );

  return query
  select
    v_simulation.id,
    p_source_simulation_id,
    v_simulation.league_round_id,
    v_simulation.calculation_run_id,
    v_simulation.simulation_version,
    v_simulation.status,
    v_builder.status,
    v_fixture_count,
    v_complete_fixture_count,
    v_pending_fixture_count,
    v_simulation.input_hash,
    v_simulation.output_hash,
    v_simulation.simulation_hash;

exception
  when others then
    if v_builder.id is not null then
      update public.round_simulation_builder_runs
      set
        status = 'failed',
        completed_at = clock_timestamp()
      where id = v_builder.id;
    end if;

    raise;
end;
$function$;

CREATE OR REPLACE FUNCTION public.build_one_to_one_preview_simulation_rpc(p_source_simulation_id uuid, p_simulation_engine_version text DEFAULT 'round-simulation-v1-one-to-one-v1'::text, p_created_by_member_id uuid DEFAULT NULL::uuid, p_correlation_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(simulation_id uuid, source_simulation_id uuid, league_round_id uuid, calculation_run_id uuid, simulation_version integer, simulation_status text, builder_status text, fixture_count integer, complete_fixture_count integer, pending_fixture_count integer, mini_challenge_count integer, input_hash text, output_hash text, simulation_hash text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
      'round-simulation-version:' || v_round.id::text,
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
      'home_strategy_valid', v_home_valid,
      'away_strategy_valid', v_away_valid,
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

  -- R53: Head-to-head participation authority.
  -- Mini-challenge matrices remain normal-mode evidence only. Forfeit
  -- fixtures carry an explicit competition score and do not manufacture
  -- mini-challenge wins.
  select coalesce(
    jsonb_agg(
      case
        when coalesce((f ->> 'home_strategy_valid')::boolean, false)
         and coalesce((f ->> 'away_strategy_valid')::boolean, false)
        then
          f || jsonb_build_object(
            'aggregate',
            coalesce(f -> 'aggregate', '{}'::jsonb)
              || jsonb_build_object('authority', 'normal')
          )

        when coalesce((f ->> 'home_strategy_valid')::boolean, false)
         and not coalesce((f ->> 'away_strategy_valid')::boolean, false)
        then
          f
          || jsonb_build_object(
               'status', 'complete',
               'fixture_phase', 'forfeit',
               'aggregate', jsonb_build_object(
                 'authority', 'single_forfeit',
                 'winner', 'home',
                 'home_wins', 0,
                 'away_wins', 0,
                 'draws', 0,
                 'home_score', 3,
                 'away_score', 0
               ),
               'forfeit', jsonb_build_object(
                 'type', 'single',
                 'winner', 'home',
                 'home_score', '3-0',
                 'away_score', '0-3'
               )
             )

        when not coalesce((f ->> 'home_strategy_valid')::boolean, false)
         and coalesce((f ->> 'away_strategy_valid')::boolean, false)
        then
          f
          || jsonb_build_object(
               'status', 'complete',
               'fixture_phase', 'forfeit',
               'aggregate', jsonb_build_object(
                 'authority', 'single_forfeit',
                 'winner', 'away',
                 'home_wins', 0,
                 'away_wins', 0,
                 'draws', 0,
                 'home_score', 0,
                 'away_score', 3
               ),
               'forfeit', jsonb_build_object(
                 'type', 'single',
                 'winner', 'away',
                 'home_score', '0-3',
                 'away_score', '3-0'
               )
             )

        else
          f
          || jsonb_build_object(
               'status', 'complete',
               'fixture_phase', 'double_forfeit',
               'aggregate', jsonb_build_object(
                 'authority', 'double_forfeit',
                 'winner', null,
                 'home_wins', 0,
                 'away_wins', 0,
                 'draws', 0,
                 'home_score', null,
                 'away_score', null
               ),
               'forfeit', jsonb_build_object(
                 'type', 'double',
                 'winner', null,
                 'home_score', '0-3',
                 'away_score', '0-3',
                 'home_outcome', 'loss',
                 'away_outcome', 'loss'
               )
             )
      end
      order by ord
    ),
    '[]'::jsonb
  )
  into v_fixtures
  from jsonb_array_elements(coalesce(v_fixtures, '[]'::jsonb))
       with ordinality as q(f, ord);


  -- R53: recompute builder readiness after forfeit materialization.
  -- mini_challenge_count deliberately remains unchanged: a 3-0 forfeit is
  -- fixture-level authority and does not fabricate mini-challenge results.
  select
    count(*) filter (
      where x ->> 'fixture_phase' in ('ready', 'bye', 'forfeit', 'double_forfeit')
    )::integer,
    count(*) filter (
      where x ->> 'fixture_phase' = 'strategy_incomplete'
    )::integer
  into v_complete_fixture_count, v_pending_fixture_count
  from jsonb_array_elements(coalesce(v_fixtures, '[]'::jsonb)) x;v_one_to_one_preview := jsonb_build_object(
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

CREATE OR REPLACE FUNCTION public.build_standings_preview_simulation_rpc(p_source_simulation_id uuid, p_simulation_engine_version text DEFAULT 'round-simulation-v1-standings-v1'::text, p_created_by_member_id uuid DEFAULT NULL::uuid, p_correlation_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(simulation_id uuid, source_simulation_id uuid, league_round_id uuid, calculation_run_id uuid, simulation_version integer, simulation_status text, builder_status text, member_count integer, mode_count integer, input_hash text, output_hash text, simulation_hash text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_source public.round_simulations%rowtype;
  v_points_source public.round_simulations%rowtype;
  v_fantacalcio_source public.round_simulations%rowtype;
  v_one_to_one_source public.round_simulations%rowtype;
  v_existing public.round_simulations%rowtype;
  v_simulation public.round_simulations%rowtype;
  v_builder public.round_simulation_builder_runs%rowtype;
  v_run public.round_calculation_runs%rowtype;
  v_round public.league_rounds%rowtype;

  v_simulation_version integer;
  v_member_count integer := 0;
  v_mode_count integer := 0;
  v_correlation_id uuid;

  v_points_preview jsonb;
  v_fantacalcio_preview jsonb;
  v_one_to_one_preview jsonb;
  v_standings_preview jsonb;
  v_digital_twin jsonb;
  v_input_manifest jsonb;

  v_input_hash text;
  v_builder_output_hash text;
  v_output_hash text;
  v_simulation_hash text;
  v_generated_at timestamptz := clock_timestamp();
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
     or v_source.simulation_hash is null then
    raise exception using
      errcode = 'P0001',
      message = 'SOURCE_SIMULATION_NOT_READY',
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

  -- Resolve the authoritative Points Preview and the latest sibling mode
  -- branches generated from the same Calculation Run. This is the merge point
  -- for the parallel Fantacalcio and One-to-One Simulation branches.
  select rs.*
  into v_points_source
  from public.round_simulations rs
  where rs.league_round_id = v_round.id
    and rs.calculation_run_id = v_run.id
    and rs.status in (
      'preview_ready',
      'preview_invalidated',
      'awaiting_certification',
      'certified'
    )
    and rs.digital_twin ? 'points_preview'
  order by
    case
      when not (rs.digital_twin ? 'fantacalcio_preview')
       and not (rs.digital_twin ? 'one_to_one_preview') then 0
      else 1
    end,
    rs.simulation_version desc
  limit 1;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'POINTS_PREVIEW_SOURCE_NOT_FOUND';
  end if;

  select rs.*
  into v_fantacalcio_source
  from public.round_simulations rs
  where rs.league_round_id = v_round.id
    and rs.calculation_run_id = v_run.id
    and rs.status in (
      'preview_ready',
      'preview_invalidated',
      'awaiting_certification',
      'certified'
    )
    and rs.digital_twin ? 'fantacalcio_preview'
  order by rs.simulation_version desc
  limit 1;

  select rs.*
  into v_one_to_one_source
  from public.round_simulations rs
  where rs.league_round_id = v_round.id
    and rs.calculation_run_id = v_run.id
    and rs.status in (
      'preview_ready',
      'preview_invalidated',
      'awaiting_certification',
      'certified'
    )
    and rs.digital_twin ? 'one_to_one_preview'
  order by rs.simulation_version desc
  limit 1;

  v_points_preview := v_points_source.digital_twin -> 'points_preview';
  v_fantacalcio_preview := case
    when v_fantacalcio_source.id is null then null
    else v_fantacalcio_source.digital_twin -> 'fantacalcio_preview'
  end;
  v_one_to_one_preview := case
    when v_one_to_one_source.id is null then null
    else v_one_to_one_source.digital_twin -> 'one_to_one_preview'
  end;

  if v_points_preview is null then
    raise exception using
      errcode = 'P0001',
      message = 'SOURCE_POINTS_PREVIEW_NOT_READY';
  end if;

  select count(*)::integer
  into v_member_count
  from jsonb_array_elements(
    coalesce(v_points_preview -> 'members', '[]'::jsonb)
  );

  if v_member_count = 0 then
    raise exception using
      errcode = 'P0001',
      message = 'STANDINGS_MEMBERS_EMPTY';
  end if;

  v_mode_count := 1
    + case when v_fantacalcio_preview is null then 0 else 1 end
    + case when v_one_to_one_preview is null then 0 else 1 end;

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
       and v_existing.digital_twin ? 'standings_preview' then
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
              and sbr.builder_name = 'StandingsPreviewBuilder'
            limit 1
          ),
          'completed'
        ),
        coalesce(
          (v_existing.digital_twin #>> '{standings_preview,member_count}')::integer,
          v_member_count
        ),
        coalesce(
          (v_existing.digital_twin #>> '{standings_preview,mode_count}')::integer,
          v_mode_count
        ),
        v_existing.input_hash,
        v_existing.output_hash,
        v_existing.simulation_hash;
      return;
    end if;

    raise exception using
      errcode = 'P0001',
      message = 'STANDINGS_SIMULATION_EXISTING_NOT_REUSABLE',
      detail = v_existing.status;
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(
      'round-simulation-version:' || v_round.id::text,
      0
    )
  );

  -- Recheck after the transaction lock.
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
       and v_existing.digital_twin ? 'standings_preview' then
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
          (v_existing.digital_twin #>> '{standings_preview,member_count}')::integer,
          v_member_count
        ),
        coalesce(
          (v_existing.digital_twin #>> '{standings_preview,mode_count}')::integer,
          v_mode_count
        ),
        v_existing.input_hash,
        v_existing.output_hash,
        v_existing.simulation_hash;
      return;
    end if;

    raise exception using
      errcode = 'P0001',
      message = 'STANDINGS_SIMULATION_EXISTING_NOT_REUSABLE',
      detail = v_existing.status;
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
    'builder_name', 'StandingsPreviewBuilder',
    'builder_version', 'standings-preview-v1',
    'requested_source_simulation_id', v_source.id,
    'points_source_simulation_id', v_points_source.id,
    'points_source_simulation_hash', v_points_source.simulation_hash,
    'fantacalcio_source_simulation_id', v_fantacalcio_source.id,
    'fantacalcio_source_simulation_hash', v_fantacalcio_source.simulation_hash,
    'one_to_one_source_simulation_id', v_one_to_one_source.id,
    'one_to_one_source_simulation_hash', v_one_to_one_source.simulation_hash,
    'league_round_id', v_round.id,
    'league_id', v_round.league_id,
    'calculation_run_id', v_run.id,
    'calculation_run_version', v_run.run_version,
    'ledger_baseline_hash', public.compute_jsonb_sha256(
      coalesce(
        (
          select jsonb_agg(
            jsonb_build_object(
              'league_member_id', lrl.league_member_id,
              'mode', lrl.mode,
              'points_delta', lrl.points_delta,
              'standings_delta', lrl.standings_delta,
              'certification_id', lrl.certification_id,
              'league_round_id', lrl.league_round_id
            )
            order by lrl.mode, lrl.league_member_id, lrl.created_at, lrl.id
          )
          from public.league_ranking_ledger lrl
          where lrl.league_id = v_round.league_id
            and lrl.active = true
            and lrl.league_round_id <> v_round.id
        ),
        '[]'::jsonb
      )
    ),
    'points_preview_hash', public.compute_jsonb_sha256(v_points_preview),
    'fantacalcio_preview_hash', case
      when v_fantacalcio_preview is null then null
      else public.compute_jsonb_sha256(v_fantacalcio_preview)
    end,
    'one_to_one_preview_hash', case
      when v_one_to_one_preview is null then null
      else public.compute_jsonb_sha256(v_one_to_one_preview)
    end
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
      'builder', 'StandingsPreviewBuilder'
    ),
    v_correlation_id,
    p_created_by_member_id
  );

  -- Inherit the completed Builder registry entries from the sibling branches.
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
    v_points_source.created_at,
    coalesce(v_points_source.completed_at, v_points_source.created_at),
    v_points_source.input_hash,
    coalesce(
      (
        select sbr.output_hash
        from public.round_simulation_builder_runs sbr
        where sbr.simulation_id = v_points_source.id
          and sbr.builder_name = 'PointsPreviewBuilder'
        limit 1
      ),
      public.compute_jsonb_sha256(v_points_preview)
    ),
    jsonb_build_object(
      'inherited', true,
      'source_simulation_id', v_points_source.id
    )
  );

  if v_fantacalcio_preview is not null then
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
      'FantacalcioPreviewBuilder',
      'fantacalcio-preview-v1',
      2,
      false,
      'completed',
      v_fantacalcio_source.created_at,
      coalesce(
        v_fantacalcio_source.completed_at,
        v_fantacalcio_source.created_at
      ),
      v_fantacalcio_source.input_hash,
      coalesce(
        (
          select sbr.output_hash
          from public.round_simulation_builder_runs sbr
          where sbr.simulation_id = v_fantacalcio_source.id
            and sbr.builder_name = 'FantacalcioPreviewBuilder'
          limit 1
        ),
        public.compute_jsonb_sha256(v_fantacalcio_preview)
      ),
      jsonb_build_object(
        'inherited', true,
        'source_simulation_id', v_fantacalcio_source.id
      )
    );
  end if;

  if v_one_to_one_preview is not null then
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
      'OneToOnePreviewBuilder',
      'one-to-one-preview-v1',
      3,
      false,
      'completed',
      v_one_to_one_source.created_at,
      coalesce(
        v_one_to_one_source.completed_at,
        v_one_to_one_source.created_at
      ),
      v_one_to_one_source.input_hash,
      coalesce(
        (
          select sbr.output_hash
          from public.round_simulation_builder_runs sbr
          where sbr.simulation_id = v_one_to_one_source.id
            and sbr.builder_name = 'OneToOnePreviewBuilder'
          limit 1
        ),
        public.compute_jsonb_sha256(v_one_to_one_preview)
      ),
      jsonb_build_object(
        'inherited', true,
        'source_simulation_id', v_one_to_one_source.id
      )
    );
  end if;

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
    'StandingsPreviewBuilder',
    'standings-preview-v1',
    4,
    true,
    'running',
    clock_timestamp(),
    v_input_hash,
    jsonb_build_object(
      'requested_source_simulation_id', v_source.id,
      'points_source_simulation_id', v_points_source.id,
      'fantacalcio_source_simulation_id', v_fantacalcio_source.id,
      'one_to_one_source_simulation_id', v_one_to_one_source.id,
      'member_count', v_member_count,
      'mode_count', v_mode_count
    )
  )
  returning * into v_builder;

  -- Build all three mode rankings. Ledger entries from the current round are
  -- excluded so a recalculation preview never double-counts a prior official
  -- certification for the same League Round.
  with
  point_members as (
    select
      (m ->> 'league_member_id')::uuid as league_member_id,
      lm.display_name as display_name,
      coalesce((m ->> 'pure_points')::numeric, 0)::numeric(10,2)
        as pure_round_points,
      coalesce((m ->> 'exact_count')::integer, 0) as exact_count,
      coalesce((m ->> 'bonus_count')::integer, 0) as bonus_count,
      coalesce((m ->> 'malus_count')::integer, 0) as malus_count,
      coalesce(m ->> 'score_phase', 'waiting') as score_phase
    from jsonb_array_elements(
      coalesce(v_points_preview -> 'members', '[]'::jsonb)
    ) m
    join public.league_members lm
      on lm.id = (m ->> 'league_member_id')::uuid
     and lm.league_id = v_round.league_id
     and lm.status = 'active'
  ),
  ledger_baseline as (
    select
      lrl.league_member_id,
      lrl.mode,
      sum(lrl.points_delta)::numeric(10,2) as baseline_points,
      count(*)::integer as ledger_entry_count,
      max(lrl.certification_id::text)::uuid as latest_certification_id
    from public.league_ranking_ledger lrl
    where lrl.league_id = v_round.league_id
      and lrl.active = true
      and lrl.league_round_id <> v_round.id
    group by lrl.league_member_id, lrl.mode
  ),
  fantacalcio_deltas as (
    select
      x.league_member_id,
      sum(x.competition_points)::numeric(10,2) as round_points,
      sum(x.wins)::integer as wins,
      sum(x.draws)::integer as draws,
      sum(x.losses)::integer as losses,
      sum(x.goals_for)::integer as goals_for,
      sum(x.goals_against)::integer as goals_against,
      bool_or(x.pending) as pending
    from (
      select
        nullif(f #>> '{home,member_id}', '')::uuid as league_member_id,
        case
          when f ->> 'fixture_phase' = 'bye' then 0
          when f ->> 'fixture_phase' not in ('ready', 'forfeit') then 0
          when f #>> '{result,winner}' = 'home' then 3
          when f #>> '{result,winner}' = 'draw' then 1
          else 0
        end::numeric as competition_points,
        case when f ->> 'fixture_phase' in ('ready', 'forfeit')
               and f #>> '{result,winner}' = 'home' then 1 else 0 end as wins,
        case when f ->> 'fixture_phase' in ('ready', 'forfeit')
               and f #>> '{result,winner}' = 'draw' then 1 else 0 end as draws,
        case when ((f ->> 'fixture_phase' in ('ready', 'forfeit') and f #>> '{result,winner}' = 'away') or f #>> '{result,authority}' = 'double_forfeit') then 1 else 0 end as losses,
        case when f #>> '{result,authority}' = 'double_forfeit' then 0 else coalesce((f #>> '{result,home_goals}')::integer, 0) end as goals_for,
        case when f #>> '{result,authority}' = 'double_forfeit' then 3 else coalesce((f #>> '{result,away_goals}')::integer, 0) end as goals_against,
        f ->> 'fixture_phase' not in ('ready', 'bye', 'forfeit', 'double_forfeit') as pending
      from jsonb_array_elements(
        coalesce(v_fantacalcio_preview -> 'fixtures', '[]'::jsonb)
      ) f
      where nullif(f #>> '{home,member_id}', '') is not null

      union all

      select
        nullif(f #>> '{away,member_id}', '')::uuid as league_member_id,
        case
          when f ->> 'fixture_phase' not in ('ready', 'forfeit') then 0
          when f #>> '{result,winner}' = 'away' then 3
          when f #>> '{result,winner}' = 'draw' then 1
          else 0
        end::numeric as competition_points,
        case when f ->> 'fixture_phase' in ('ready', 'forfeit')
               and f #>> '{result,winner}' = 'away' then 1 else 0 end as wins,
        case when f ->> 'fixture_phase' in ('ready', 'forfeit')
               and f #>> '{result,winner}' = 'draw' then 1 else 0 end as draws,
        case when ((f ->> 'fixture_phase' in ('ready', 'forfeit') and f #>> '{result,winner}' = 'home') or f #>> '{result,authority}' = 'double_forfeit') then 1 else 0 end as losses,
        case when f #>> '{result,authority}' = 'double_forfeit' then 0 else coalesce((f #>> '{result,away_goals}')::integer, 0) end as goals_for,
        case when f #>> '{result,authority}' = 'double_forfeit' then 3 else coalesce((f #>> '{result,home_goals}')::integer, 0) end as goals_against,
        f ->> 'fixture_phase' not in ('ready', 'forfeit', 'double_forfeit') as pending
      from jsonb_array_elements(
        coalesce(v_fantacalcio_preview -> 'fixtures', '[]'::jsonb)
      ) f
      where nullif(f #>> '{away,member_id}', '') is not null
    ) x
    group by x.league_member_id
  ),
  one_to_one_deltas as (
    select
      x.league_member_id,
      sum(x.competition_points)::numeric(10,2) as round_points,
      sum(x.wins)::integer as wins,
      sum(x.draws)::integer as draws,
      sum(x.losses)::integer as losses,
      sum(x.mini_wins)::integer as mini_wins,
      sum(x.mini_draws)::integer as mini_draws,
      sum(x.mini_losses)::integer as mini_losses,
      bool_or(x.pending) as pending
    from (
      select
        nullif(f ->> 'home_member_id', '')::uuid as league_member_id,
        case
          when f ->> 'fixture_phase' = 'bye' then 0
          when f ->> 'fixture_phase' not in ('ready', 'forfeit') then 0
          when f #>> '{aggregate,winner}' = 'home' then 3
          when f #>> '{aggregate,winner}' = 'draw' then 1
          else 0
        end::numeric as competition_points,
        case when f ->> 'fixture_phase' in ('ready', 'forfeit')
               and f #>> '{aggregate,winner}' = 'home' then 1 else 0 end as wins,
        case when f ->> 'fixture_phase' in ('ready', 'forfeit')
               and f #>> '{aggregate,winner}' = 'draw' then 1 else 0 end as draws,
        case when ((f ->> 'fixture_phase' in ('ready', 'forfeit') and f #>> '{aggregate,winner}' = 'away') or f #>> '{aggregate,authority}' = 'double_forfeit') then 1 else 0 end as losses,
        coalesce((f #>> '{aggregate,home_wins}')::integer, 0) as mini_wins,
        coalesce((f #>> '{aggregate,draws}')::integer, 0) as mini_draws,
        coalesce((f #>> '{aggregate,away_wins}')::integer, 0) as mini_losses,
        f ->> 'fixture_phase' not in ('ready', 'bye', 'forfeit', 'double_forfeit') as pending
      from jsonb_array_elements(
        coalesce(v_one_to_one_preview -> 'fixtures', '[]'::jsonb)
      ) f
      where nullif(f ->> 'home_member_id', '') is not null

      union all

      select
        nullif(f ->> 'away_member_id', '')::uuid as league_member_id,
        case
          when f ->> 'fixture_phase' not in ('ready', 'forfeit') then 0
          when f #>> '{aggregate,winner}' = 'away' then 3
          when f #>> '{aggregate,winner}' = 'draw' then 1
          else 0
        end::numeric as competition_points,
        case when f ->> 'fixture_phase' in ('ready', 'forfeit')
               and f #>> '{aggregate,winner}' = 'away' then 1 else 0 end as wins,
        case when f ->> 'fixture_phase' in ('ready', 'forfeit')
               and f #>> '{aggregate,winner}' = 'draw' then 1 else 0 end as draws,
        case when ((f ->> 'fixture_phase' in ('ready', 'forfeit') and f #>> '{aggregate,winner}' = 'home') or f #>> '{aggregate,authority}' = 'double_forfeit') then 1 else 0 end as losses,
        coalesce((f #>> '{aggregate,away_wins}')::integer, 0) as mini_wins,
        coalesce((f #>> '{aggregate,draws}')::integer, 0) as mini_draws,
        coalesce((f #>> '{aggregate,home_wins}')::integer, 0) as mini_losses,
        f ->> 'fixture_phase' not in ('ready', 'forfeit', 'double_forfeit') as pending
      from jsonb_array_elements(
        coalesce(v_one_to_one_preview -> 'fixtures', '[]'::jsonb)
      ) f
      where nullif(f ->> 'away_member_id', '') is not null
    ) x
    group by x.league_member_id
  ),
  mode_rows as (
    select
      pm.league_member_id,
      pm.display_name,
      'pure_points'::text as mode,
      coalesce(lb.baseline_points, 0)::numeric(10,2) as baseline_points,
      pm.pure_round_points::numeric(10,2) as round_points,
      (
        coalesce(lb.baseline_points, 0) + pm.pure_round_points
      )::numeric(10,2) as projected_points,
      coalesce(lb.ledger_entry_count, 0) as ledger_entry_count,
      lb.latest_certification_id,
      pm.exact_count,
      pm.bonus_count,
      pm.malus_count,
      pm.score_phase,
      false as pending,
      jsonb_build_object(
        'exact_count', pm.exact_count,
        'bonus_count', pm.bonus_count,
        'malus_count', pm.malus_count
      ) as round_stats
    from point_members pm
    left join ledger_baseline lb
      on lb.league_member_id = pm.league_member_id
     and lb.mode = 'pure_points'

    union all

    select
      pm.league_member_id,
      pm.display_name,
      'fantacalcio'::text as mode,
      coalesce(lb.baseline_points, 0)::numeric(10,2) as baseline_points,
      coalesce(fd.round_points, 0)::numeric(10,2) as round_points,
      (
        coalesce(lb.baseline_points, 0) + coalesce(fd.round_points, 0)
      )::numeric(10,2) as projected_points,
      coalesce(lb.ledger_entry_count, 0) as ledger_entry_count,
      lb.latest_certification_id,
      pm.exact_count,
      pm.bonus_count,
      pm.malus_count,
      pm.score_phase,
      coalesce(fd.pending, v_fantacalcio_preview is null) as pending,
      jsonb_build_object(
        'wins', coalesce(fd.wins, 0),
        'draws', coalesce(fd.draws, 0),
        'losses', coalesce(fd.losses, 0),
        'goals_for', coalesce(fd.goals_for, 0),
        'goals_against', coalesce(fd.goals_against, 0),
        'goal_difference',
          coalesce(fd.goals_for, 0) - coalesce(fd.goals_against, 0)
      ) as round_stats
    from point_members pm
    left join ledger_baseline lb
      on lb.league_member_id = pm.league_member_id
     and lb.mode = 'fantacalcio'
    left join fantacalcio_deltas fd
      on fd.league_member_id = pm.league_member_id
    where v_fantacalcio_preview is not null

    union all

    select
      pm.league_member_id,
      pm.display_name,
      'one_to_one'::text as mode,
      coalesce(lb.baseline_points, 0)::numeric(10,2) as baseline_points,
      coalesce(od.round_points, 0)::numeric(10,2) as round_points,
      (
        coalesce(lb.baseline_points, 0) + coalesce(od.round_points, 0)
      )::numeric(10,2) as projected_points,
      coalesce(lb.ledger_entry_count, 0) as ledger_entry_count,
      lb.latest_certification_id,
      pm.exact_count,
      pm.bonus_count,
      pm.malus_count,
      pm.score_phase,
      coalesce(od.pending, v_one_to_one_preview is null) as pending,
      jsonb_build_object(
        'wins', coalesce(od.wins, 0),
        'draws', coalesce(od.draws, 0),
        'losses', coalesce(od.losses, 0),
        'mini_wins', coalesce(od.mini_wins, 0),
        'mini_draws', coalesce(od.mini_draws, 0),
        'mini_losses', coalesce(od.mini_losses, 0),
        'mini_difference',
          coalesce(od.mini_wins, 0) - coalesce(od.mini_losses, 0)
      ) as round_stats
    from point_members pm
    left join ledger_baseline lb
      on lb.league_member_id = pm.league_member_id
     and lb.mode = 'one_to_one'
    left join one_to_one_deltas od
      on od.league_member_id = pm.league_member_id
    where v_one_to_one_preview is not null
  ),
  ranked_rows as (
    select
      mr.*,
      dense_rank() over (
        partition by mr.mode
        order by
          mr.projected_points desc,
          case when mr.mode = 'pure_points' then mr.exact_count else 0 end desc,
          case when mr.mode = 'pure_points' then mr.bonus_count else 0 end desc,
          mr.round_points desc
      )::integer as position_preview,
      dense_rank() over (
        partition by mr.mode
        order by
          mr.baseline_points desc,
          mr.league_member_id
      )::integer as baseline_position
    from mode_rows mr
  ),
  mode_payloads as (
    select
      rr.mode,
      jsonb_build_object(
        'mode', rr.mode,
        'preview', true,
        'baseline_source', 'league_ranking_ledger',
        'round_source', case rr.mode
          when 'pure_points' then 'points_preview'
          when 'fantacalcio' then 'fantacalcio_preview'
          when 'one_to_one' then 'one_to_one_preview'
        end,
        'member_count', count(*)::integer,
        'pending_member_count', count(*) filter (where rr.pending)::integer,
        'ranking', jsonb_agg(
          jsonb_build_object(
            'league_member_id', rr.league_member_id,
            'display_name', rr.display_name,
            'position_preview', rr.position_preview,
            'baseline_position', rr.baseline_position,
            'movement_preview', rr.baseline_position - rr.position_preview,
            'baseline_points', rr.baseline_points,
            'round_points', rr.round_points,
            'projected_points', rr.projected_points,
            'pending', rr.pending,
            'score_phase', rr.score_phase,
            'round_stats', rr.round_stats,
            'baseline_reference', jsonb_build_object(
              'ledger_entry_count', rr.ledger_entry_count,
              'latest_certification_id', rr.latest_certification_id
            ),
            'tiebreaker_preview', jsonb_build_object(
              'policy', case rr.mode
                when 'pure_points' then
                  'projected_points_exact_bonus_round_points'
                else
                  'projected_competition_points_round_points'
              end,
              'preview_only', true,
              'deterministic_fallback', 'league_member_id'
            )
          )
          order by rr.position_preview, rr.league_member_id
        )
      ) as payload
    from ranked_rows rr
    group by rr.mode
  )
  select jsonb_build_object(
    'schema_version', 1,
    'builder', 'StandingsPreviewBuilder',
    'builder_version', 'standings-preview-v1',
    'source_simulation_id', v_source.id,
    'points_source_simulation_id', v_points_source.id,
    'fantacalcio_source_simulation_id', v_fantacalcio_source.id,
    'one_to_one_source_simulation_id', v_one_to_one_source.id,
    'generated_at', v_generated_at,
    'preview', true,
    'official', false,
    'member_count', v_member_count,
    'mode_count', v_mode_count,
    'modes', coalesce(
      (
        select jsonb_object_agg(mp.mode, mp.payload order by mp.mode)
        from mode_payloads mp
      ),
      '{}'::jsonb
    )
  )
  into v_standings_preview;

  v_builder_output_hash := public.compute_jsonb_sha256(v_standings_preview);

  -- Start with the authoritative Points Preview Digital Twin and merge the two
  -- optional parallel branches before appending Standings Preview.
  v_digital_twin := v_points_source.digital_twin;

  if v_fantacalcio_preview is not null then
    v_digital_twin := jsonb_set(
      v_digital_twin,
      '{fantacalcio_preview}',
      v_fantacalcio_preview,
      true
    );
  end if;

  if v_one_to_one_preview is not null then
    v_digital_twin := jsonb_set(
      v_digital_twin,
      '{one_to_one_preview}',
      v_one_to_one_preview,
      true
    );
  end if;

  v_digital_twin := jsonb_set(
    v_digital_twin,
    '{standings_preview}',
    v_standings_preview,
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
      'points_source_simulation_id', v_points_source.id,
      'points_source_simulation_hash', v_points_source.simulation_hash,
      'fantacalcio_source_simulation_id', v_fantacalcio_source.id,
      'fantacalcio_source_simulation_hash',
        v_fantacalcio_source.simulation_hash,
      'one_to_one_source_simulation_id', v_one_to_one_source.id,
      'one_to_one_source_simulation_hash',
        v_one_to_one_source.simulation_hash,
      'standings_preview_hash', v_builder_output_hash,
      'standings_schema_version', 1,
      'generated_at', v_generated_at,
      'preview', true
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
      'member_count', v_member_count,
      'mode_count', v_mode_count,
      'standings_preview_hash', v_builder_output_hash
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
      'member_count', v_member_count,
      'mode_count', v_mode_count
    ),
    v_correlation_id,
    v_builder.id,
    p_created_by_member_id
  );

  -- Only the merged Standings artifact is publishable. All replaceable sibling
  -- previews for the same Calculation Run are retained but superseded.
  update public.round_simulations rs
  set
    status = 'preview_invalidated',
    publishable = false,
    invalidated_at = coalesce(rs.invalidated_at, clock_timestamp()),
    invalidation_reason = 'superseded_by_standings_preview'
  where rs.league_round_id = v_round.id
    and rs.calculation_run_id = v_run.id
    and rs.id <> v_simulation.id
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
      'publishable', true,
      'branch', 'merged_standings',
      'builders_completed', (
        select jsonb_agg(sbr.builder_name order by sbr.builder_order)
        from public.round_simulation_builder_runs sbr
        where sbr.simulation_id = v_simulation.id
          and sbr.status = 'completed'
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
    v_member_count,
    v_mode_count,
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
commit;
