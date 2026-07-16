-- ============================================================================
-- FANTAGOL
-- Migration 047: UI Snapshot Builder
--
-- Scope:
-- - consume a completed Standings Preview Simulation;
-- - transform certified domain phases into presentation-ready UI states;
-- - build round, match, prediction, member and mode UI views;
-- - preserve append-only Round Simulation history and deterministic hashes;
-- - expose an authenticated member read RPC.
--
-- Out of scope:
-- - scoring or strategy calculation;
-- - standings calculation;
-- - writes to league_ranking_ledger or round_certifications;
-- - provider polling or realtime publication;
-- - client-side domain reconstruction.
-- ============================================================================

begin;

-- ============================================================================
-- 1. UI SNAPSHOT SIMULATION BUILDER
-- ============================================================================

create or replace function public.build_ui_snapshot_simulation_rpc(
  p_source_simulation_id uuid,
  p_simulation_engine_version text default 'round-simulation-v1-ui-v1',
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
  match_count integer,
  member_count integer,
  mode_count integer,
  prediction_ui_count integer,
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

  v_simulation_version integer;
  v_match_count integer := 0;
  v_member_count integer := 0;
  v_mode_count integer := 0;
  v_prediction_ui_count integer := 0;
  v_correlation_id uuid;

  v_round_ui jsonb;
  v_matches_ui jsonb;
  v_predictions_ui jsonb;
  v_members_ui jsonb;
  v_modes_ui jsonb;
  v_ui_snapshot jsonb;
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
     or v_source.simulation_hash is null
     or not (v_source.digital_twin ? 'points_preview')
     or not (v_source.digital_twin ? 'standings_preview') then
    raise exception using
      errcode = 'P0001',
      message = 'SOURCE_STANDINGS_PREVIEW_NOT_READY',
      detail = v_source.status;
  end if;

  if v_source.digital_twin ? 'ui_snapshot' then
    raise exception using
      errcode = 'P0001',
      message = 'SOURCE_UI_SNAPSHOT_ALREADY_PRESENT';
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

  select count(*)::integer
  into v_match_count
  from jsonb_array_elements(
    coalesce(v_source.digital_twin -> 'matches', '[]'::jsonb)
  );

  select count(*)::integer
  into v_member_count
  from jsonb_array_elements(
    coalesce(v_source.digital_twin -> 'members', '[]'::jsonb)
  );

  select count(*)::integer
  into v_mode_count
  from jsonb_object_keys(
    coalesce(
      v_source.digital_twin #> '{standings_preview,modes}',
      '{}'::jsonb
    )
  );

  select count(*)::integer
  into v_prediction_ui_count
  from jsonb_array_elements(
    coalesce(
      v_source.digital_twin #> '{points_preview,prediction_results}',
      '[]'::jsonb
    )
  );

  if v_match_count = 0 then
    raise exception using
      errcode = 'P0001',
      message = 'UI_MATCHES_EMPTY';
  end if;

  if v_member_count = 0 then
    raise exception using
      errcode = 'P0001',
      message = 'UI_MEMBERS_EMPTY';
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
       and v_existing.digital_twin ? 'ui_snapshot' then
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
              and sbr.builder_name = 'UISnapshotBuilder'
            limit 1
          ),
          'completed'
        ),
        coalesce(
          (v_existing.digital_twin #>> '{ui_snapshot,match_count}')::integer,
          v_match_count
        ),
        coalesce(
          (v_existing.digital_twin #>> '{ui_snapshot,member_count}')::integer,
          v_member_count
        ),
        coalesce(
          (v_existing.digital_twin #>> '{ui_snapshot,mode_count}')::integer,
          v_mode_count
        ),
        coalesce(
          (v_existing.digital_twin #>> '{ui_snapshot,prediction_ui_count}')::integer,
          v_prediction_ui_count
        ),
        v_existing.input_hash,
        v_existing.output_hash,
        v_existing.simulation_hash;
      return;
    end if;

    raise exception using
      errcode = 'P0001',
      message = 'UI_SIMULATION_EXISTING_NOT_REUSABLE',
      detail = v_existing.status;
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(
      'ui-snapshot-simulation:' || v_round.id::text,
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
       and v_existing.digital_twin ? 'ui_snapshot' then
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
          (v_existing.digital_twin #>> '{ui_snapshot,match_count}')::integer,
          v_match_count
        ),
        coalesce(
          (v_existing.digital_twin #>> '{ui_snapshot,member_count}')::integer,
          v_member_count
        ),
        coalesce(
          (v_existing.digital_twin #>> '{ui_snapshot,mode_count}')::integer,
          v_mode_count
        ),
        coalesce(
          (v_existing.digital_twin #>> '{ui_snapshot,prediction_ui_count}')::integer,
          v_prediction_ui_count
        ),
        v_existing.input_hash,
        v_existing.output_hash,
        v_existing.simulation_hash;
      return;
    end if;

    raise exception using
      errcode = 'P0001',
      message = 'UI_SIMULATION_EXISTING_NOT_REUSABLE',
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
    'builder_name', 'UISnapshotBuilder',
    'builder_version', 'ui-snapshot-v1',
    'source_simulation_id', v_source.id,
    'source_simulation_version', v_source.simulation_version,
    'source_simulation_hash', v_source.simulation_hash,
    'league_round_id', v_round.id,
    'league_id', v_round.league_id,
    'calculation_run_id', v_run.id,
    'calculation_run_version', v_run.run_version,
    'points_preview_hash', public.compute_jsonb_sha256(
      v_source.digital_twin -> 'points_preview'
    ),
    'fantacalcio_preview_hash', case
      when v_source.digital_twin ? 'fantacalcio_preview' then
        public.compute_jsonb_sha256(
          v_source.digital_twin -> 'fantacalcio_preview'
        )
      else null
    end,
    'one_to_one_preview_hash', case
      when v_source.digital_twin ? 'one_to_one_preview' then
        public.compute_jsonb_sha256(
          v_source.digital_twin -> 'one_to_one_preview'
        )
      else null
    end,
    'standings_preview_hash', public.compute_jsonb_sha256(
      v_source.digital_twin -> 'standings_preview'
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
      'builder', 'UISnapshotBuilder'
    ),
    v_correlation_id,
    p_created_by_member_id
  );

  -- Inherit all completed Builder registry entries from the source Simulation.
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
  select
    v_simulation.id,
    sbr.builder_name,
    sbr.builder_version,
    sbr.builder_order,
    sbr.required,
    'completed',
    sbr.started_at,
    sbr.completed_at,
    sbr.input_hash,
    sbr.output_hash,
    coalesce(sbr.metadata, '{}'::jsonb) || jsonb_build_object(
      'inherited', true,
      'source_simulation_id', v_source.id
    )
  from public.round_simulation_builder_runs sbr
  where sbr.simulation_id = v_source.id
    and sbr.status = 'completed'
  order by sbr.builder_order;

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
    'UISnapshotBuilder',
    'ui-snapshot-v1',
    50,
    true,
    'running',
    clock_timestamp(),
    v_input_hash,
    jsonb_build_object(
      'source_simulation_id', v_source.id,
      'match_count', v_match_count,
      'member_count', v_member_count,
      'mode_count', v_mode_count,
      'prediction_ui_count', v_prediction_ui_count
    )
  )
  returning * into v_builder;

  -- Round presentation state. Domain values are consumed, never recomputed.
  v_round_ui := jsonb_build_object(
    'league_round_id', v_round.id,
    'domain_status', coalesce(
      v_source.digital_twin #>> '{round,status}',
      v_round.status
    ),
    'phase', case
      when coalesce(v_source.digital_twin #>> '{round,status}', v_round.status)
        in ('final_official', 'recalculated', 'archived') then 'certified'
      when coalesce(v_source.digital_twin #>> '{round,status}', v_round.status)
        in ('live', 'partial_finished', 'waiting_postponed') then 'live'
      when coalesce(v_source.digital_twin #>> '{round,status}', v_round.status)
        in ('final_calculable', 'scoring', 'official') then 'post_live'
      else 'pre_live'
    end,
    'visual_state', case
      when coalesce(v_source.digital_twin #>> '{round,status}', v_round.status)
        in ('final_official', 'recalculated', 'archived') then 'acquired'
      when coalesce(v_source.digital_twin #>> '{round,status}', v_round.status)
        in ('live', 'partial_finished', 'waiting_postponed') then 'live'
      when coalesce(v_source.digital_twin #>> '{round,status}', v_round.status)
        in ('final_calculable', 'scoring', 'official') then 'acquired'
      else 'dormant'
    end,
    'animation_state', case
      when coalesce(v_source.digital_twin #>> '{round,status}', v_round.status)
        in ('live', 'partial_finished') then 'soft_pulse'
      else 'none'
    end,
    'preview', true
  );

  -- Match presentation states.
  with match_rows as (
    select
      m,
      coalesce(m ->> 'status', 'scheduled') as match_status,
      coalesce(m ->> 'result_phase', 'pre_live') as result_phase
    from jsonb_array_elements(
      coalesce(v_source.digital_twin -> 'matches', '[]'::jsonb)
    ) m
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'match_id', mr.m ->> 'match_id',
        'slot_number', mr.m -> 'slot_number',
        'domain_status', mr.match_status,
        'result_phase', mr.result_phase,
        'match_phase', case
          when mr.match_status = 'postponed' then 'postponed'
          when mr.match_status in ('cancelled', 'abandoned') then 'void'
          when mr.result_phase = 'certified' then 'certified'
          when mr.result_phase = 'post_live' then 'post_live'
          when mr.result_phase = 'live' then 'live'
          else 'pre_live'
        end,
        'visual_state', case
          when mr.match_status = 'postponed' then 'postponed'
          when mr.match_status in ('cancelled', 'abandoned') then 'void'
          when mr.result_phase = 'certified' then 'acquired'
          when mr.result_phase = 'post_live' then 'acquired'
          when mr.result_phase = 'live' then 'live'
          else 'dormant'
        end,
        'animation_state', case
          when mr.result_phase = 'live' then 'soft_pulse'
          else 'none'
        end,
        'score_state', case
          when mr.match_status in ('cancelled', 'abandoned') then 'void'
          when mr.result_phase = 'certified' then 'locked'
          when mr.result_phase = 'post_live' then 'stable_pending_round'
          when mr.result_phase = 'live' then 'provisional'
          else 'waiting'
        end,
        'minute', mr.m -> 'minute',
        'period', mr.m -> 'period',
        'preview', true
      )
      order by
        coalesce((mr.m ->> 'slot_number')::integer, 2147483647),
        mr.m ->> 'match_id'
    ),
    '[]'::jsonb
  )
  into v_matches_ui
  from match_rows mr;

  -- Prediction/icon presentation states for every member and match.
  with prediction_rows as (
    select
      p,
      coalesce(p ->> 'match_status', 'scheduled') as match_status,
      coalesce(p ->> 'result_phase', 'pre_live') as result_phase,
      coalesce((p ->> 'void')::boolean, false) as is_void
    from jsonb_array_elements(
      coalesce(
        v_source.digital_twin #> '{points_preview,prediction_results}',
        '[]'::jsonb
      )
    ) p
  ), normalized as (
    select
      pr.*,
      case
        when pr.is_void or pr.match_status in ('cancelled', 'abandoned') then 'void'
        when pr.match_status = 'postponed' then 'postponed'
        when pr.result_phase = 'certified' then 'certified'
        when pr.result_phase = 'post_live' then 'post_live'
        when pr.result_phase = 'live' then 'live'
        else 'pre_live'
      end as ui_phase
    from prediction_rows pr
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'league_member_id', n.p ->> 'league_member_id',
        'match_id', n.p ->> 'match_id',
        'slot_number', n.p -> 'slot_number',
        'prediction_id', n.p ->> 'prediction_id',
        'match_phase', n.ui_phase,
        'score_phase', case
          when n.ui_phase = 'void' then 'void'
          when n.ui_phase = 'certified' then 'locked'
          when n.ui_phase = 'post_live' then 'stable_pending_round'
          when n.ui_phase = 'live' then 'provisional'
          else 'waiting'
        end,
        'animation_state', case
          when n.ui_phase = 'live' then 'soft_pulse'
          else 'none'
        end,
        'provisional', coalesce((n.p ->> 'provisional')::boolean, true),
        'included', coalesce((n.p ->> 'included')::boolean, false),
        'missing', coalesce((n.p ->> 'missing')::boolean, false),
        'void', n.is_void,
        'base_total', n.p -> 'base_total',
        'icons', jsonb_build_object(
          'exact', case
            when n.ui_phase in ('void', 'postponed') then 'off'
            when n.ui_phase = 'pre_live' then 'off'
            when n.ui_phase = 'live' and coalesce((n.p ->> 'is_exact')::boolean, false) then 'live_active'
            when n.ui_phase = 'live' then 'live_inactive'
            when n.ui_phase = 'post_live' and coalesce((n.p ->> 'is_exact')::boolean, false) then 'on'
            when n.ui_phase = 'post_live' then 'off'
            when coalesce((n.p ->> 'is_exact')::boolean, false) then 'on'
            else 'off'
          end,
          'sign', case
            when n.ui_phase in ('void', 'postponed') then 'off'
            when n.ui_phase = 'pre_live' then 'off'
            when n.ui_phase = 'live' and coalesce((n.p ->> 'is_sign')::boolean, false) then 'live_active'
            when n.ui_phase = 'live' then 'live_inactive'
            when n.ui_phase = 'post_live' and coalesce((n.p ->> 'is_sign')::boolean, false) then 'on'
            when n.ui_phase = 'post_live' then 'off'
            when coalesce((n.p ->> 'is_sign')::boolean, false) then 'on'
            else 'off'
          end,
          'over_under', case
            when n.ui_phase in ('void', 'postponed') then 'off'
            when n.ui_phase = 'pre_live' then 'off'
            when n.ui_phase = 'live' and coalesce((n.p ->> 'is_over_under')::boolean, false) then 'live_active'
            when n.ui_phase = 'live' then 'live_inactive'
            when n.ui_phase = 'post_live' and coalesce((n.p ->> 'is_over_under')::boolean, false) then 'on'
            when n.ui_phase = 'post_live' then 'off'
            when coalesce((n.p ->> 'is_over_under')::boolean, false) then 'on'
            else 'off'
          end,
          'goal_no_goal', case
            when n.ui_phase in ('void', 'postponed') then 'off'
            when n.ui_phase = 'pre_live' then 'off'
            when n.ui_phase = 'live' and coalesce((n.p ->> 'is_goal_no_goal')::boolean, false) then 'live_active'
            when n.ui_phase = 'live' then 'live_inactive'
            when n.ui_phase = 'post_live' and coalesce((n.p ->> 'is_goal_no_goal')::boolean, false) then 'on'
            when n.ui_phase = 'post_live' then 'off'
            when coalesce((n.p ->> 'is_goal_no_goal')::boolean, false) then 'on'
            else 'off'
          end,
          'surprise', case
            when n.ui_phase = 'pre_live'
             and coalesce((n.p ->> 'surprise_candidate')::boolean, false) then 'candidate'
            when n.ui_phase in ('void', 'postponed', 'pre_live') then 'off'
            when n.ui_phase = 'live' and coalesce((n.p ->> 'is_surprise')::boolean, false) then 'live_active'
            when n.ui_phase = 'live' then 'live_inactive'
            when n.ui_phase = 'post_live' and coalesce((n.p ->> 'is_surprise')::boolean, false) then 'on'
            when n.ui_phase = 'post_live' then 'off'
            when coalesce((n.p ->> 'is_surprise')::boolean, false) then 'on'
            else 'off'
          end,
          'goal_show', case
            when n.ui_phase in ('void', 'postponed', 'pre_live') then 'off'
            when n.ui_phase = 'live' and coalesce((n.p ->> 'is_goal_show')::boolean, false) then 'live_active'
            when n.ui_phase = 'live' then 'live_inactive'
            when n.ui_phase = 'post_live' and coalesce((n.p ->> 'is_goal_show')::boolean, false) then 'on'
            when n.ui_phase = 'post_live' then 'off'
            when coalesce((n.p ->> 'is_goal_show')::boolean, false) then 'on'
            else 'off'
          end,
          'grand_slam', case
            when n.ui_phase in ('void', 'postponed', 'pre_live') then 'off'
            when n.ui_phase = 'live' and coalesce((n.p ->> 'is_grand_slam')::boolean, false) then 'live_active'
            when n.ui_phase = 'live' then 'live_inactive'
            when n.ui_phase = 'post_live' and coalesce((n.p ->> 'is_grand_slam')::boolean, false) then 'on'
            when n.ui_phase = 'post_live' then 'off'
            when coalesce((n.p ->> 'is_grand_slam')::boolean, false) then 'on'
            else 'off'
          end,
          'opposite_sign', case
            when n.ui_phase in ('void', 'postponed', 'pre_live') then 'off'
            when n.ui_phase = 'live' and coalesce((n.p ->> 'is_opposite_sign')::boolean, false) then 'live_active'
            when n.ui_phase = 'live' then 'live_inactive'
            when n.ui_phase = 'post_live' and coalesce((n.p ->> 'is_opposite_sign')::boolean, false) then 'on'
            when n.ui_phase = 'post_live' then 'off'
            when coalesce((n.p ->> 'is_opposite_sign')::boolean, false) then 'on'
            else 'off'
          end,
          'cantonata', case
            when n.ui_phase in ('void', 'postponed', 'pre_live') then 'off'
            when n.ui_phase = 'live' and coalesce((n.p ->> 'is_cantonata')::boolean, false) then 'live_active'
            when n.ui_phase = 'live' then 'live_inactive'
            when n.ui_phase = 'post_live' and coalesce((n.p ->> 'is_cantonata')::boolean, false) then 'on'
            when n.ui_phase = 'post_live' then 'off'
            when coalesce((n.p ->> 'is_cantonata')::boolean, false) then 'on'
            else 'off'
          end
        )
      )
      order by
        n.p ->> 'league_member_id',
        coalesce((n.p ->> 'slot_number')::integer, 2147483647),
        n.p ->> 'match_id'
    ),
    '[]'::jsonb
  )
  into v_predictions_ui
  from normalized n;

  -- Member presentation states consume the existing score_phase.
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'league_member_id', m ->> 'league_member_id',
        'display_name', m ->> 'display_name',
        'score_phase', coalesce(m ->> 'score_phase', 'waiting'),
        'visual_state', case coalesce(m ->> 'score_phase', 'waiting')
          when 'locked' then 'acquired'
          when 'final_pending_commit' then 'acquired'
          when 'stable_pending_round' then 'acquired'
          when 'provisional' then 'live'
          when 'void' then 'void'
          else 'dormant'
        end,
        'animation_state', 'none',
        'round_points', m -> 'round_points',
        'preview', true
      )
      order by m ->> 'league_member_id'
    ),
    '[]'::jsonb
  )
  into v_members_ui
  from jsonb_array_elements(
    coalesce(v_source.digital_twin -> 'members', '[]'::jsonb)
  ) m;

  -- Mode presentation state; fixture content remains authoritative in its
  -- respective Preview branch and is referenced rather than recalculated.
  select jsonb_build_object(
    'pure_points', jsonb_build_object(
      'available', v_source.digital_twin #> '{standings_preview,modes,pure_points}' is not null,
      'phase', 'preview',
      'ranking_count', jsonb_array_length(
        coalesce(
          v_source.digital_twin #> '{standings_preview,modes,pure_points,ranking}',
          '[]'::jsonb
        )
      ),
      'animation_state', 'none'
    ),
    'fantacalcio', jsonb_build_object(
      'available', v_source.digital_twin ? 'fantacalcio_preview',
      'phase', 'preview',
      'fixture_count', jsonb_array_length(
        coalesce(
          v_source.digital_twin #> '{fantacalcio_preview,fixtures}',
          '[]'::jsonb
        )
      ),
      'ranking_count', jsonb_array_length(
        coalesce(
          v_source.digital_twin #> '{standings_preview,modes,fantacalcio,ranking}',
          '[]'::jsonb
        )
      ),
      'animation_state', 'none'
    ),
    'one_to_one', jsonb_build_object(
      'available', v_source.digital_twin ? 'one_to_one_preview',
      'phase', 'preview',
      'fixture_count', jsonb_array_length(
        coalesce(
          v_source.digital_twin #> '{one_to_one_preview,fixtures}',
          '[]'::jsonb
        )
      ),
      'ranking_count', jsonb_array_length(
        coalesce(
          v_source.digital_twin #> '{standings_preview,modes,one_to_one,ranking}',
          '[]'::jsonb
        )
      ),
      'animation_state', 'none'
    )
  )
  into v_modes_ui;

  v_ui_snapshot := jsonb_build_object(
    'schema_version', 1,
    'builder', 'UISnapshotBuilder',
    'builder_version', 'ui-snapshot-v1',
    'source_simulation_id', v_source.id,
    'generated_at', v_generated_at,
    'preview', true,
    'match_count', v_match_count,
    'member_count', v_member_count,
    'mode_count', v_mode_count,
    'prediction_ui_count', v_prediction_ui_count,
    'round_ui', v_round_ui,
    'matches_ui', v_matches_ui,
    'predictions_ui', v_predictions_ui,
    'members_ui', v_members_ui,
    'modes_ui', v_modes_ui
  );

  v_builder_output_hash := public.compute_jsonb_sha256(v_ui_snapshot);

  v_digital_twin := jsonb_set(
    v_source.digital_twin,
    '{ui_snapshot}',
    v_ui_snapshot,
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
      'ui_snapshot_hash', v_builder_output_hash,
      'ui_schema_version', 1,
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
      'match_count', v_match_count,
      'member_count', v_member_count,
      'mode_count', v_mode_count,
      'prediction_ui_count', v_prediction_ui_count,
      'ui_snapshot_hash', v_builder_output_hash
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
      'match_count', v_match_count,
      'member_count', v_member_count,
      'mode_count', v_mode_count,
      'prediction_ui_count', v_prediction_ui_count
    ),
    v_correlation_id,
    v_builder.id,
    p_created_by_member_id
  );

  update public.round_simulations rs
  set
    status = 'preview_invalidated',
    publishable = false,
    invalidated_at = coalesce(rs.invalidated_at, clock_timestamp()),
    invalidation_reason = 'superseded_by_ui_snapshot'
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
      'branch', 'ui_snapshot',
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
    v_match_count,
    v_member_count,
    v_mode_count,
    v_prediction_ui_count,
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

create or replace function public.get_my_ui_snapshot_rpc(
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
  ui_snapshot jsonb
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
  v_member_ui jsonb;
  v_member_predictions_ui jsonb;
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
    and rs.digital_twin ? 'ui_snapshot'
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

  select value
  into v_member_ui
  from jsonb_array_elements(
    coalesce(
      v_simulation.digital_twin #> '{ui_snapshot,members_ui}',
      '[]'::jsonb
    )
  ) value
  where value ->> 'league_member_id' = v_member_id::text
  limit 1;

  select coalesce(jsonb_agg(value order by (value ->> 'slot_number')::integer), '[]'::jsonb)
  into v_member_predictions_ui
  from jsonb_array_elements(
    coalesce(
      v_simulation.digital_twin #> '{ui_snapshot,predictions_ui}',
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
    coalesce(v_member_view, '{}'::jsonb),
    jsonb_build_object(
      'schema_version', coalesce(
        (v_simulation.digital_twin #>>
          '{ui_snapshot,schema_version}')::integer,
        1
      ),
      'builder', v_simulation.digital_twin #>>
        '{ui_snapshot,builder}',
      'builder_version', v_simulation.digital_twin #>>
        '{ui_snapshot,builder_version}',
      'generated_at', v_simulation.digital_twin #>
        '{ui_snapshot,generated_at}',
      'round_ui', v_simulation.digital_twin #>
        '{ui_snapshot,round_ui}',
      'matches_ui', v_simulation.digital_twin #>
        '{ui_snapshot,matches_ui}',
      'member_ui', coalesce(v_member_ui, '{}'::jsonb),
      'predictions_ui', v_member_predictions_ui,
      'modes_ui', v_simulation.digital_twin #>
        '{ui_snapshot,modes_ui}',
      'preview', true
    );
end;
$function$;

-- ============================================================================
-- 3. GRANTS
-- ============================================================================

revoke all on function public.build_ui_snapshot_simulation_rpc(
  uuid,
  text,
  uuid,
  uuid
) from public;
revoke all on function public.build_ui_snapshot_simulation_rpc(
  uuid,
  text,
  uuid,
  uuid
) from anon;
revoke all on function public.build_ui_snapshot_simulation_rpc(
  uuid,
  text,
  uuid,
  uuid
) from authenticated;
grant execute on function public.build_ui_snapshot_simulation_rpc(
  uuid,
  text,
  uuid,
  uuid
) to service_role;

revoke all on function public.get_my_ui_snapshot_rpc(uuid)
  from public;
revoke all on function public.get_my_ui_snapshot_rpc(uuid)
  from anon;
revoke all on function public.get_my_ui_snapshot_rpc(uuid)
  from service_role;
grant execute on function public.get_my_ui_snapshot_rpc(uuid)
  to authenticated;

-- ============================================================================
-- 4. COMMENTS
-- ============================================================================

comment on function public.build_ui_snapshot_simulation_rpc(
  uuid,
  text,
  uuid,
  uuid
) is
'Builds an immutable presentation-ready UI Snapshot from a completed Standings Preview Simulation. It maps domain phases to round, match, score, icon, animation, member and mode UI states without recalculating scores, strategies or standings. Service-role only.';

comment on function public.get_my_ui_snapshot_rpc(uuid) is
'Returns the authenticated League Member latest UI Snapshot with shared round, match and mode presentation states plus only the caller own member and prediction UI rows.';

commit;
