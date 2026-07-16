-- ============================================================================
-- FANTAGOL
-- Migration 046: Standings Preview Builder
--
-- Scope:
-- - merge the latest sibling Simulation branches for the same Calculation Run;
-- - build provisional standings for pure_points, fantacalcio and one_to_one;
-- - combine the active certified Ranking Ledger baseline with current-round deltas;
-- - preserve append-only Round Simulation history and deterministic hashes;
-- - expose an authenticated member read RPC.
--
-- Out of scope:
-- - certification commit;
-- - writes to league_ranking_ledger;
-- - writes to round_certifications.standings_snapshot;
-- - official standings or ledger mutation;
-- - UI presentation-state derivation.
-- ============================================================================

begin;

-- ============================================================================
-- 1. STANDINGS PREVIEW SIMULATION BUILDER
-- ============================================================================

create or replace function public.build_standings_preview_simulation_rpc(
  p_source_simulation_id uuid,
  p_simulation_engine_version text default 'round-simulation-v1-standings-v1',
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
  member_count integer,
  mode_count integer,
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
      'standings-preview-simulation:' || v_round.id::text,
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
      m ->> 'display_name' as display_name,
      coalesce((m ->> 'round_points')::numeric, 0)::numeric(10,2)
        as pure_round_points,
      coalesce((m ->> 'exact_count')::integer, 0) as exact_count,
      coalesce((m ->> 'bonus_count')::integer, 0) as bonus_count,
      coalesce((m ->> 'malus_count')::integer, 0) as malus_count,
      coalesce(m ->> 'score_phase', 'waiting') as score_phase
    from jsonb_array_elements(
      coalesce(v_points_preview -> 'members', '[]'::jsonb)
    ) m
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
          when f ->> 'fixture_phase' <> 'ready' then 0
          when f #>> '{result,winner}' = 'home' then 3
          when f #>> '{result,winner}' = 'draw' then 1
          else 0
        end::numeric as competition_points,
        case when f ->> 'fixture_phase' = 'ready'
               and f #>> '{result,winner}' = 'home' then 1 else 0 end as wins,
        case when f ->> 'fixture_phase' = 'ready'
               and f #>> '{result,winner}' = 'draw' then 1 else 0 end as draws,
        case when f ->> 'fixture_phase' = 'ready'
               and f #>> '{result,winner}' = 'away' then 1 else 0 end as losses,
        coalesce((f #>> '{result,home_goals}')::integer, 0) as goals_for,
        coalesce((f #>> '{result,away_goals}')::integer, 0) as goals_against,
        f ->> 'fixture_phase' not in ('ready', 'bye') as pending
      from jsonb_array_elements(
        coalesce(v_fantacalcio_preview -> 'fixtures', '[]'::jsonb)
      ) f
      where nullif(f #>> '{home,member_id}', '') is not null

      union all

      select
        nullif(f #>> '{away,member_id}', '')::uuid as league_member_id,
        case
          when f ->> 'fixture_phase' <> 'ready' then 0
          when f #>> '{result,winner}' = 'away' then 3
          when f #>> '{result,winner}' = 'draw' then 1
          else 0
        end::numeric as competition_points,
        case when f ->> 'fixture_phase' = 'ready'
               and f #>> '{result,winner}' = 'away' then 1 else 0 end as wins,
        case when f ->> 'fixture_phase' = 'ready'
               and f #>> '{result,winner}' = 'draw' then 1 else 0 end as draws,
        case when f ->> 'fixture_phase' = 'ready'
               and f #>> '{result,winner}' = 'home' then 1 else 0 end as losses,
        coalesce((f #>> '{result,away_goals}')::integer, 0) as goals_for,
        coalesce((f #>> '{result,home_goals}')::integer, 0) as goals_against,
        f ->> 'fixture_phase' <> 'ready' as pending
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
          when f ->> 'fixture_phase' <> 'ready' then 0
          when f #>> '{aggregate,winner}' = 'home' then 3
          when f #>> '{aggregate,winner}' = 'draw' then 1
          else 0
        end::numeric as competition_points,
        case when f ->> 'fixture_phase' = 'ready'
               and f #>> '{aggregate,winner}' = 'home' then 1 else 0 end as wins,
        case when f ->> 'fixture_phase' = 'ready'
               and f #>> '{aggregate,winner}' = 'draw' then 1 else 0 end as draws,
        case when f ->> 'fixture_phase' = 'ready'
               and f #>> '{aggregate,winner}' = 'away' then 1 else 0 end as losses,
        coalesce((f #>> '{aggregate,home_wins}')::integer, 0) as mini_wins,
        coalesce((f #>> '{aggregate,draws}')::integer, 0) as mini_draws,
        coalesce((f #>> '{aggregate,away_wins}')::integer, 0) as mini_losses,
        f ->> 'fixture_phase' not in ('ready', 'bye') as pending
      from jsonb_array_elements(
        coalesce(v_one_to_one_preview -> 'fixtures', '[]'::jsonb)
      ) f
      where nullif(f ->> 'home_member_id', '') is not null

      union all

      select
        nullif(f ->> 'away_member_id', '')::uuid as league_member_id,
        case
          when f ->> 'fixture_phase' <> 'ready' then 0
          when f #>> '{aggregate,winner}' = 'away' then 3
          when f #>> '{aggregate,winner}' = 'draw' then 1
          else 0
        end::numeric as competition_points,
        case when f ->> 'fixture_phase' = 'ready'
               and f #>> '{aggregate,winner}' = 'away' then 1 else 0 end as wins,
        case when f ->> 'fixture_phase' = 'ready'
               and f #>> '{aggregate,winner}' = 'draw' then 1 else 0 end as draws,
        case when f ->> 'fixture_phase' = 'ready'
               and f #>> '{aggregate,winner}' = 'home' then 1 else 0 end as losses,
        coalesce((f #>> '{aggregate,away_wins}')::integer, 0) as mini_wins,
        coalesce((f #>> '{aggregate,draws}')::integer, 0) as mini_draws,
        coalesce((f #>> '{aggregate,home_wins}')::integer, 0) as mini_losses,
        f ->> 'fixture_phase' <> 'ready' as pending
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

-- ============================================================================
-- 2. AUTHENTICATED MEMBER READ RPC
-- ============================================================================

create or replace function public.get_my_standings_preview_rpc(
  p_league_round_id uuid
)
returns table (
  simulation_id uuid,
  simulation_version integer,
  simulation_status text,
  simulation_hash text,
  manifest jsonb,
  round_view jsonb,
  member_view jsonb,
  standings_preview jsonb
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
begin
  v_user_id := auth.uid();

  if v_user_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'AUTHENTICATION_REQUIRED';
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
    and rs.status in (
      'preview_ready',
      'awaiting_certification',
      'certified'
    )
    and rs.digital_twin ? 'standings_preview'
  order by
    rs.publishable desc,
    rs.simulation_version desc
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

  return query
  select
    v_simulation.id,
    v_simulation.simulation_version,
    v_simulation.status,
    v_simulation.simulation_hash,
    v_simulation.digital_twin -> 'manifest',
    v_simulation.digital_twin -> 'round',
    coalesce(v_member_view, '{}'::jsonb),
    jsonb_build_object(
      'schema_version', coalesce(
        (v_simulation.digital_twin #>>
          '{standings_preview,schema_version}')::integer,
        1
      ),
      'builder', v_simulation.digital_twin #>>
        '{standings_preview,builder}',
      'builder_version', v_simulation.digital_twin #>>
        '{standings_preview,builder_version}',
      'generated_at', v_simulation.digital_twin #>
        '{standings_preview,generated_at}',
      'preview', true,
      'member', jsonb_build_object(
        'league_member_id', v_member_id,
        'pure_points', coalesce(
          (
            select r
            from jsonb_array_elements(
              coalesce(
                v_simulation.digital_twin #>
                  '{standings_preview,modes,pure_points,ranking}',
                '[]'::jsonb
              )
            ) r
            where r ->> 'league_member_id' = v_member_id::text
            limit 1
          ),
          '{}'::jsonb
        ),
        'fantacalcio', coalesce(
          (
            select r
            from jsonb_array_elements(
              coalesce(
                v_simulation.digital_twin #>
                  '{standings_preview,modes,fantacalcio,ranking}',
                '[]'::jsonb
              )
            ) r
            where r ->> 'league_member_id' = v_member_id::text
            limit 1
          ),
          '{}'::jsonb
        ),
        'one_to_one', coalesce(
          (
            select r
            from jsonb_array_elements(
              coalesce(
                v_simulation.digital_twin #>
                  '{standings_preview,modes,one_to_one,ranking}',
                '[]'::jsonb
              )
            ) r
            where r ->> 'league_member_id' = v_member_id::text
            limit 1
          ),
          '{}'::jsonb
        )
      ),
      'modes', v_simulation.digital_twin #> '{standings_preview,modes}'
    );
end;
$function$;

-- ============================================================================
-- 3. GRANTS
-- ============================================================================

revoke all on function public.build_standings_preview_simulation_rpc(
  uuid,
  text,
  uuid,
  uuid
) from public;
revoke all on function public.build_standings_preview_simulation_rpc(
  uuid,
  text,
  uuid,
  uuid
) from anon;
revoke all on function public.build_standings_preview_simulation_rpc(
  uuid,
  text,
  uuid,
  uuid
) from authenticated;
grant execute on function public.build_standings_preview_simulation_rpc(
  uuid,
  text,
  uuid,
  uuid
) to service_role;

revoke all on function public.get_my_standings_preview_rpc(uuid)
  from public;
revoke all on function public.get_my_standings_preview_rpc(uuid)
  from anon;
revoke all on function public.get_my_standings_preview_rpc(uuid)
  from service_role;
grant execute on function public.get_my_standings_preview_rpc(uuid)
  to authenticated;

-- ============================================================================
-- 4. COMMENTS
-- ============================================================================

comment on function public.build_standings_preview_simulation_rpc(
  uuid,
  text,
  uuid,
  uuid
) is
'Builds the immutable merged Standings Preview by combining the authoritative Points Preview, the latest sibling Fantacalcio and One-to-One branches for the same Calculation Run, and the active certified Ranking Ledger baseline. It never writes certifications or ledger rows. Service-role only.';

comment on function public.get_my_standings_preview_rpc(uuid) is
'Returns the authenticated League Member latest merged Standings Preview, including all provisional mode rankings and the caller own projected positions without exposing or mutating official ledger state.';

commit;
