-- ============================================================================
-- FANTAGOL
-- Migration 054: Round Certification Command Engine
--
-- Scope:
--   - deterministic readiness evaluation for one League Round;
--   - validation that every included Match has one active global Match Result
--     Certification;
--   - atomic commit of an existing Calculation Run and completed UI Simulation;
--   - immutable Round Certification archive population;
--   - certified Match, Prediction and Member Result snapshots;
--   - official Ranking Ledger activation;
--   - controlled supersession of a previous active Round Certification;
--   - transition of the League Round and Round Simulation to official state.
--
-- Architectural boundary:
--   - the Runtime rebuilds the deterministic Calculation/Simulation pipeline;
--   - this migration never polls providers and never rebuilds previews;
--   - PostgreSQL owns the final atomic certification commit.
-- ============================================================================

begin;

create extension if not exists pgcrypto;

-- ============================================================================
-- 1. ROUND CERTIFICATION READINESS
-- ============================================================================

create or replace function public.evaluate_round_certification_readiness_rpc(
  p_league_round_id uuid,
  p_calculation_run_id uuid default null,
  p_ui_simulation_id uuid default null
)
returns table (
  league_round_id uuid,
  round_status text,
  source_round_version integer,
  match_set_version integer,
  required_match_count integer,
  included_match_count integer,
  excluded_match_count integer,
  certified_match_count integer,
  blocking_match_count integer,
  calculation_run_id uuid,
  calculation_status text,
  ui_simulation_id uuid,
  ui_simulation_status text,
  is_ready boolean,
  blocking_code text,
  blocking_details jsonb
)
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $function$
declare
  v_round public.league_rounds%rowtype;
  v_run public.round_calculation_runs%rowtype;
  v_simulation public.round_simulations%rowtype;

  v_required_match_count integer := 0;
  v_included_match_count integer := 0;
  v_excluded_match_count integer := 0;
  v_certified_match_count integer := 0;
  v_blocking_match_count integer := 0;
  v_match_set_version integer := 1;

  v_active_member_count integer := 0;
  v_expected_runtime_row_count integer := 0;
  v_runtime_row_count integer := 0;
  v_runtime_included_row_count integer := 0;
  v_runtime_provisional_count integer := 0;
  v_runtime_uncertified_count integer := 0;
  v_runtime_unexpected_match_count integer := 0;
  v_runtime_context_mismatch_count integer := 0;

  v_is_ready boolean := false;
  v_blocking_code text;
  v_blocking_details jsonb := '{}'::jsonb;
begin
  if p_league_round_id is null then
    raise exception using
      errcode = '22004',
      message = 'LEAGUE_ROUND_ID_REQUIRED';
  end if;

  select lr.*
  into v_round
  from public.league_rounds lr
  where lr.id = p_league_round_id;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_ROUND_NOT_FOUND';
  end if;

  select
    count(*)::integer,
    count(*) filter (
      where coalesce(lrmd.decision, 'included') <> 'excluded'
    )::integer,
    count(*) filter (
      where coalesce(lrmd.decision, 'included') = 'excluded'
    )::integer,
    coalesce(max(lrmd.version), 1)::integer
  into
    v_required_match_count,
    v_included_match_count,
    v_excluded_match_count,
    v_match_set_version
  from public.fantagol_round_matches frm
  left join public.league_round_match_decisions lrmd
    on lrmd.league_round_id = v_round.id
   and lrmd.match_id = frm.match_id
  where frm.fantagol_round_id = v_round.fantagol_round_id
    and frm.removed_at is null
    and frm.required = true;

  select count(*)::integer
  into v_certified_match_count
  from public.fantagol_round_matches frm
  left join public.league_round_match_decisions lrmd
    on lrmd.league_round_id = v_round.id
   and lrmd.match_id = frm.match_id
  where frm.fantagol_round_id = v_round.fantagol_round_id
    and frm.removed_at is null
    and frm.required = true
    and coalesce(lrmd.decision, 'included') <> 'excluded'
    and exists (
      select 1
      from public.match_result_certifications mrc
      where mrc.match_id = frm.match_id
        and mrc.status = 'official'
    );

  v_blocking_match_count :=
    greatest(v_included_match_count - v_certified_match_count, 0);

  select count(*)::integer
  into v_active_member_count
  from public.league_members lm
  where lm.league_id = v_round.league_id
    and lm.status = 'active';

  if p_calculation_run_id is not null then
    select rcr.*
    into v_run
    from public.round_calculation_runs rcr
    where rcr.id = p_calculation_run_id
      and rcr.league_round_id = v_round.id;
  else
    select rcr.*
    into v_run
    from public.round_calculation_runs rcr
    where rcr.league_round_id = v_round.id
      and rcr.status in ('preview_ready', 'committed')
    order by rcr.run_version desc
    limit 1;
  end if;

  if p_ui_simulation_id is not null then
    select rs.*
    into v_simulation
    from public.round_simulations rs
    where rs.id = p_ui_simulation_id
      and rs.league_round_id = v_round.id;
  elsif v_run.id is not null then
    select rs.*
    into v_simulation
    from public.round_simulations rs
    where rs.league_round_id = v_round.id
      and rs.calculation_run_id = v_run.id
      and rs.digital_twin ? 'ui_snapshot'
      and rs.status in (
        'preview_ready',
        'awaiting_certification',
        'certified'
      )
    order by rs.simulation_version desc
    limit 1;
  end if;

  if v_run.id is not null then
    v_expected_runtime_row_count :=
      v_active_member_count * v_required_match_count;

    select
      count(*)::integer,
      count(*) filter (where psrr.included)::integer,
      count(*) filter (
        where psrr.included
          and psrr.provisional
      )::integer,
      count(*) filter (
        where psrr.included
          and psrr.result_phase <> 'certified'
      )::integer,
      count(*) filter (
        where not exists (
          select 1
          from public.fantagol_round_matches frm
          where frm.fantagol_round_id = v_round.fantagol_round_id
            and frm.removed_at is null
            and frm.required = true
            and frm.match_id = psrr.match_id
        )
      )::integer,
      count(*) filter (
        where psrr.league_round_id <> v_round.id
           or psrr.scoring_profile_id <> v_run.scoring_profile_id
           or psrr.scoring_profile_version <> v_run.scoring_profile_version
           or psrr.engine_version <> v_run.engine_version
      )::integer
    into
      v_runtime_row_count,
      v_runtime_included_row_count,
      v_runtime_provisional_count,
      v_runtime_uncertified_count,
      v_runtime_unexpected_match_count,
      v_runtime_context_mismatch_count
    from public.prediction_score_runtime_results psrr
    where psrr.calculation_run_id = v_run.id;
  end if;

  if not v_round.enabled then
    v_blocking_code := 'LEAGUE_ROUND_DISABLED';

  elsif v_round.status = 'cancelled' then
    v_blocking_code := 'LEAGUE_ROUND_CANCELLED';

  elsif v_round.status not in (
    'final_calculable',
    'scoring',
    'official',
    'recalculated'
  ) then
    v_blocking_code := 'LEAGUE_ROUND_NOT_FINAL_CALCULABLE';

  elsif v_required_match_count = 0 then
    v_blocking_code := 'ROUND_MATCH_SET_EMPTY';

  elsif v_included_match_count = 0 then
    v_blocking_code := 'ROUND_INCLUDED_MATCH_SET_EMPTY';

  elsif v_blocking_match_count > 0 then
    v_blocking_code := 'MATCH_CERTIFICATIONS_INCOMPLETE';
    select jsonb_build_object(
      'blocking_matches',
      coalesce(
        jsonb_agg(
          jsonb_build_object(
            'match_id', frm.match_id,
            'slot_number', frm.slot_number,
            'decision', coalesce(lrmd.decision, 'included')
          )
          order by frm.slot_number, frm.match_id
        ),
        '[]'::jsonb
      )
    )
    into v_blocking_details
    from public.fantagol_round_matches frm
    left join public.league_round_match_decisions lrmd
      on lrmd.league_round_id = v_round.id
     and lrmd.match_id = frm.match_id
    where frm.fantagol_round_id = v_round.fantagol_round_id
      and frm.removed_at is null
      and frm.required = true
      and coalesce(lrmd.decision, 'included') <> 'excluded'
      and not exists (
        select 1
        from public.match_result_certifications mrc
        where mrc.match_id = frm.match_id
          and mrc.status = 'official'
      );

  elsif v_run.id is null then
    v_blocking_code := 'CALCULATION_RUN_NOT_FOUND';

  elsif v_run.status not in ('preview_ready', 'committed') then
    v_blocking_code := 'CALCULATION_RUN_NOT_READY';

  elsif v_run.input_hash is null
     or v_run.output_hash is null
     or v_run.preview_hash is null then
    v_blocking_code := 'CALCULATION_RUN_HASHES_INCOMPLETE';

  elsif v_active_member_count = 0 then
    v_blocking_code := 'LEAGUE_ACTIVE_MEMBER_SET_EMPTY';

  elsif v_runtime_row_count = 0 then
    v_blocking_code := 'CALCULATION_RUNTIME_RESULTS_EMPTY';

  elsif v_runtime_row_count <> v_expected_runtime_row_count then
    v_blocking_code := 'CALCULATION_RUNTIME_RESULTS_INCOMPLETE';
    v_blocking_details := jsonb_build_object(
      'expected_runtime_row_count', v_expected_runtime_row_count,
      'runtime_row_count', v_runtime_row_count
    );

  elsif v_runtime_included_row_count
        <> (v_active_member_count * v_included_match_count) then
    v_blocking_code := 'CALCULATION_INCLUDED_RUNTIME_RESULTS_INCOMPLETE';
    v_blocking_details := jsonb_build_object(
      'expected_included_runtime_row_count',
        v_active_member_count * v_included_match_count,
      'runtime_included_row_count', v_runtime_included_row_count
    );

  elsif v_runtime_provisional_count > 0 then
    v_blocking_code := 'CALCULATION_RUNTIME_RESULTS_PROVISIONAL';

  elsif v_runtime_uncertified_count > 0 then
    v_blocking_code := 'CALCULATION_RUNTIME_RESULTS_NOT_CERTIFIED';

  elsif v_runtime_unexpected_match_count > 0 then
    v_blocking_code := 'CALCULATION_RUNTIME_RESULTS_MATCH_SET_MISMATCH';

  elsif v_runtime_context_mismatch_count > 0 then
    v_blocking_code := 'CALCULATION_RUNTIME_RESULTS_CONTEXT_MISMATCH';

  elsif v_run.match_set_version <> v_match_set_version then
    v_blocking_code := 'CALCULATION_RUN_MATCH_SET_STALE';
    v_blocking_details := jsonb_build_object(
      'run_match_set_version', v_run.match_set_version,
      'current_match_set_version', v_match_set_version
    );

  elsif v_simulation.id is null then
    v_blocking_code := 'UI_SIMULATION_NOT_FOUND';

  elsif v_simulation.calculation_run_id <> v_run.id then
    v_blocking_code := 'UI_SIMULATION_RUN_MISMATCH';

  elsif v_simulation.status not in (
    'preview_ready',
    'awaiting_certification',
    'certified'
  ) then
    v_blocking_code := 'UI_SIMULATION_NOT_READY';

  elsif not (v_simulation.digital_twin ? 'points_preview')
     or not (v_simulation.digital_twin ? 'standings_preview')
     or not (v_simulation.digital_twin ? 'ui_snapshot') then
    v_blocking_code := 'UI_SIMULATION_DIGITAL_TWIN_INCOMPLETE';

  elsif v_simulation.input_hash is null
     or v_simulation.output_hash is null
     or v_simulation.simulation_hash is null then
    v_blocking_code := 'UI_SIMULATION_HASHES_INCOMPLETE';

  else
    v_is_ready := true;
  end if;

  if v_blocking_details = '{}'::jsonb then
    v_blocking_details := jsonb_build_object(
      'required_match_count', v_required_match_count,
      'included_match_count', v_included_match_count,
      'excluded_match_count', v_excluded_match_count,
      'certified_match_count', v_certified_match_count,
      'blocking_match_count', v_blocking_match_count,
      'active_member_count', v_active_member_count,
      'expected_runtime_row_count', v_expected_runtime_row_count,
      'runtime_row_count', v_runtime_row_count,
      'runtime_included_row_count', v_runtime_included_row_count,
      'runtime_provisional_count', v_runtime_provisional_count,
      'runtime_uncertified_count', v_runtime_uncertified_count,
      'runtime_unexpected_match_count', v_runtime_unexpected_match_count,
      'runtime_context_mismatch_count', v_runtime_context_mismatch_count,
      'calculation_run_version', v_run.run_version,
      'ui_simulation_version', v_simulation.simulation_version
    );
  else
    v_blocking_details := v_blocking_details || jsonb_build_object(
      'required_match_count', v_required_match_count,
      'included_match_count', v_included_match_count,
      'excluded_match_count', v_excluded_match_count,
      'certified_match_count', v_certified_match_count,
      'blocking_match_count', v_blocking_match_count,
      'active_member_count', v_active_member_count,
      'expected_runtime_row_count', v_expected_runtime_row_count,
      'runtime_row_count', v_runtime_row_count,
      'runtime_included_row_count', v_runtime_included_row_count,
      'runtime_provisional_count', v_runtime_provisional_count,
      'runtime_uncertified_count', v_runtime_uncertified_count,
      'runtime_unexpected_match_count', v_runtime_unexpected_match_count,
      'runtime_context_mismatch_count', v_runtime_context_mismatch_count,
      'calculation_run_version', v_run.run_version,
      'ui_simulation_version', v_simulation.simulation_version
    );
  end if;

  return query
  select
    v_round.id,
    v_round.status,
    v_round.version,
    v_match_set_version,
    v_required_match_count,
    v_included_match_count,
    v_excluded_match_count,
    v_certified_match_count,
    v_blocking_match_count,
    v_run.id,
    v_run.status,
    v_simulation.id,
    v_simulation.status,
    v_is_ready,
    v_blocking_code,
    v_blocking_details;
end;
$function$;

-- ============================================================================
-- 2. ATOMIC ROUND CERTIFICATION COMMAND
-- ============================================================================

create or replace function public.certify_round_rpc(
  p_league_round_id uuid,
  p_calculation_run_id uuid,
  p_ui_simulation_id uuid,
  p_engine_version text default 'round-certification-v1',
  p_reason text default 'automatic official round certification',
  p_committed_by_member_id uuid default null,
  p_correlation_id uuid default null
)
returns table (
  certification_id uuid,
  league_round_id uuid,
  certification_version integer,
  certification_status text,
  calculation_run_id uuid,
  ui_simulation_id uuid,
  certification_hash text,
  ledger_version integer,
  created boolean,
  superseded_certification_id uuid
)
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $function$
declare
  v_readiness record;
  v_round public.league_rounds%rowtype;
  v_run public.round_calculation_runs%rowtype;
  v_simulation public.round_simulations%rowtype;
  v_previous public.round_certifications%rowtype;
  v_existing public.round_certifications%rowtype;
  v_certification public.round_certifications%rowtype;

  v_next_version integer;
  v_ledger_version integer;
  v_certification_hash text;
  v_certification_manifest jsonb;
  v_input_snapshot jsonb;
  v_output_snapshot jsonb;
  v_input_hash text;
  v_output_hash text;
  v_standings_snapshot jsonb;
  v_ledger_row_count integer := 0;
  v_expected_ledger_row_count integer := 0;
  v_invalid_ledger_row_count integer := 0;
  v_now timestamptz := clock_timestamp();
  v_created boolean := false;
begin
  if p_league_round_id is null
     or p_calculation_run_id is null
     or p_ui_simulation_id is null then
    raise exception using
      errcode = '22004',
      message = 'ROUND_CERTIFICATION_IDENTIFIERS_REQUIRED';
  end if;

  if nullif(btrim(p_engine_version), '') is null then
    raise exception using
      errcode = '22023',
      message = 'ROUND_CERTIFICATION_ENGINE_VERSION_REQUIRED';
  end if;

  if nullif(btrim(p_reason), '') is null then
    raise exception using
      errcode = '22023',
      message = 'ROUND_CERTIFICATION_REASON_REQUIRED';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(
      'round-certification:' || p_league_round_id::text,
      0
    )
  );

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

  if p_committed_by_member_id is not null
     and not exists (
       select 1
       from public.league_members lm
       where lm.id = p_committed_by_member_id
         and lm.league_id = v_round.league_id
         and lm.status = 'active'
     ) then
    raise exception using
      errcode = 'P0001',
      message = 'COMMITTER_MEMBERSHIP_INVALID';
  end if;

  select *
  into v_readiness
  from public.evaluate_round_certification_readiness_rpc(
    p_league_round_id,
    p_calculation_run_id,
    p_ui_simulation_id
  );

  if not coalesce(v_readiness.is_ready, false) then
    raise exception using
      errcode = 'P0001',
      message = 'ROUND_CERTIFICATION_NOT_READY',
      detail = coalesce(v_readiness.blocking_code, 'UNKNOWN'),
      hint = coalesce(v_readiness.blocking_details, '{}'::jsonb)::text;
  end if;

  select rcr.*
  into v_run
  from public.round_calculation_runs rcr
  where rcr.id = p_calculation_run_id
    and rcr.league_round_id = p_league_round_id
  for update;

  select rs.*
  into v_simulation
  from public.round_simulations rs
  where rs.id = p_ui_simulation_id
    and rs.league_round_id = p_league_round_id
    and rs.calculation_run_id = p_calculation_run_id
  for update;

  -- Idempotent fast path for an already committed Calculation Run.
  if v_run.committed_certification_id is not null then
    select rc.*
    into v_existing
    from public.round_certifications rc
    where rc.id = v_run.committed_certification_id;

    if found
       and v_existing.status = 'official'
       and v_existing.active = true
       and v_simulation.certification_id = v_existing.id
       and v_simulation.status = 'certified' then
      return query
      select
        v_existing.id,
        v_existing.league_round_id,
        v_existing.certification_version,
        v_existing.status,
        v_run.id,
        v_simulation.id,
        v_existing.certification_hash,
        coalesce(v_simulation.ledger_version, 1),
        false,
        v_existing.previous_certification_id;
      return;
    end if;

    raise exception using
      errcode = 'P0001',
      message = 'CALCULATION_RUN_ALREADY_COMMITTED_INCONSISTENTLY';
  end if;

  select rc.*
  into v_previous
  from public.round_certifications rc
  where rc.league_round_id = p_league_round_id
    and rc.active = true
    and rc.status = 'official'
  order by rc.certification_version desc
  limit 1
  for update;

  select coalesce(max(rc.certification_version), 0) + 1
  into v_next_version
  from public.round_certifications rc
  where rc.league_round_id = p_league_round_id;

  v_ledger_version := v_next_version;

  v_standings_snapshot :=
    coalesce(
      v_simulation.digital_twin -> 'standings_preview',
      '{}'::jsonb
    );

  if jsonb_typeof(v_standings_snapshot) <> 'object'
     or jsonb_typeof(v_standings_snapshot -> 'modes') <> 'object'
     or jsonb_object_length(v_standings_snapshot -> 'modes') = 0 then
    raise exception using
      errcode = 'P0001',
      message = 'STANDINGS_SNAPSHOT_MODES_INVALID';
  end if;

  select
    coalesce(sum(
      case
        when jsonb_typeof(mode_entry.value -> 'ranking') = 'array'
          then jsonb_array_length(mode_entry.value -> 'ranking')
        else 0
      end
    ), 0)::integer,
    count(*) filter (
      where jsonb_typeof(mode_entry.value -> 'ranking') <> 'array'
         or jsonb_array_length(mode_entry.value -> 'ranking')
            <> (
              select count(*)
              from public.league_members lm
              where lm.league_id = v_round.league_id
                and lm.status = 'active'
            )
    )::integer
  into
    v_expected_ledger_row_count,
    v_invalid_ledger_row_count
  from jsonb_each(v_standings_snapshot -> 'modes') as mode_entry(key, value)
  where mode_entry.key in ('pure_points', 'fantacalcio', 'one_to_one');

  if v_invalid_ledger_row_count > 0
     or v_expected_ledger_row_count = 0 then
    raise exception using
      errcode = 'P0001',
      message = 'STANDINGS_SNAPSHOT_RANKING_INVALID';
  end if;

  if exists (
    select 1
    from jsonb_each(v_standings_snapshot -> 'modes') as mode_entry(key, value)
    cross join lateral jsonb_array_elements(
      mode_entry.value -> 'ranking'
    ) ranking_row
    left join public.league_members lm
      on lm.id = case
        when coalesce(ranking_row ->> 'league_member_id', '') ~*
             '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
          then (ranking_row ->> 'league_member_id')::uuid
        else null
      end
     and lm.league_id = v_round.league_id
     and lm.status = 'active'
    where mode_entry.key in ('pure_points', 'fantacalcio', 'one_to_one')
      and (
        lm.id is null
        or ranking_row ->> 'round_points' is null
      )
  ) then
    raise exception using
      errcode = 'P0001',
      message = 'STANDINGS_SNAPSHOT_MEMBER_OR_POINTS_INVALID';
  end if;

  if exists (
    select 1
    from (
      select
        mode_entry.key,
        ranking_row ->> 'league_member_id' as league_member_id,
        count(*) as row_count
      from jsonb_each(v_standings_snapshot -> 'modes') as mode_entry(key, value)
      cross join lateral jsonb_array_elements(
        mode_entry.value -> 'ranking'
      ) ranking_row
      where mode_entry.key in ('pure_points', 'fantacalcio', 'one_to_one')
      group by mode_entry.key, ranking_row ->> 'league_member_id'
      having count(*) <> 1
    ) duplicates
  ) then
    raise exception using
      errcode = 'P0001',
      message = 'STANDINGS_SNAPSHOT_DUPLICATE_MEMBER';
  end if;

  v_certification_manifest := jsonb_build_object(
    'schema_version', 1,
    'league_round_id', v_round.id,
    'league_round_version', v_round.version,
    'certification_version', v_next_version,
    'previous_certification_id', v_previous.id,
    'calculation_run_id', v_run.id,
    'calculation_run_version', v_run.run_version,
    'calculation_input_hash', v_run.input_hash,
    'calculation_output_hash', v_run.output_hash,
    'calculation_preview_hash', v_run.preview_hash,
    'ui_simulation_id', v_simulation.id,
    'ui_simulation_version', v_simulation.simulation_version,
    'ui_simulation_input_hash', v_simulation.input_hash,
    'ui_simulation_output_hash', v_simulation.output_hash,
    'ui_simulation_hash', v_simulation.simulation_hash,
    'match_set_version', v_run.match_set_version,
    'scoring_profile_id', v_run.scoring_profile_id,
    'scoring_profile_version', v_run.scoring_profile_version,
    'resolution_engine_version', v_run.engine_version,
    'round_certification_engine_version', p_engine_version
  );

  v_input_snapshot :=
    v_run.input_snapshot || jsonb_build_object(
      'round_certification_manifest',
      v_certification_manifest
    );

  v_output_snapshot :=
    v_run.output_snapshot || jsonb_build_object(
      'ui_simulation_id', v_simulation.id,
      'ui_simulation_hash', v_simulation.simulation_hash,
      'digital_twin', v_simulation.digital_twin
    );

  v_input_hash := public.compute_jsonb_sha256(v_input_snapshot);
  v_output_hash := public.compute_jsonb_sha256(v_output_snapshot);

  v_certification_hash := public.compute_certification_hash(
    v_round.id,
    v_next_version,
    1,
    v_input_snapshot,
    v_output_snapshot,
    v_standings_snapshot,
    p_engine_version,
    v_run.match_set_version,
    v_run.scoring_profile_version
  );

  select rc.*
  into v_existing
  from public.round_certifications rc
  where rc.source_run_id = v_run.id
  limit 1;

  if found then
    raise exception using
      errcode = 'P0001',
      message = 'ROUND_CERTIFICATION_SOURCE_RUN_ALREADY_ARCHIVED_INCONSISTENTLY';
  end if;

  -- The old official certification and its ledger become historical.
  if v_previous.id is not null then
    update public.league_ranking_ledger lrl
    set active = false
    where lrl.certification_id = v_previous.id
      and lrl.active = true;

    update public.round_certifications rc
    set
      status = 'superseded',
      active = false,
      superseded_at = v_now
    where rc.id = v_previous.id;
  end if;

  insert into public.round_certifications (
    league_round_id,
    source_run_id,
    certification_version,
    previous_certification_id,
    status,
    active,
    match_set_version,
    scoring_profile_id,
    scoring_profile_version,
    engine_version,
    snapshot_schema_version,
    input_snapshot,
    output_snapshot,
    standings_snapshot,
    input_hash,
    output_hash,
    certification_hash,
    committed_by_member_id,
    reason,
    committed_at,
    created_at
  )
  values (
    v_round.id,
    v_run.id,
    v_next_version,
    v_previous.id,
    'official',
    true,
    v_run.match_set_version,
    v_run.scoring_profile_id,
    v_run.scoring_profile_version,
    p_engine_version,
    1,
    v_input_snapshot,
    v_output_snapshot,
    v_standings_snapshot,
    v_input_hash,
    v_output_hash,
    v_certification_hash,
    p_committed_by_member_id,
    btrim(p_reason),
    v_now,
    v_now
  )
  returning * into v_certification;

  v_created := true;

  -- --------------------------------------------------------------------------
  -- Certified Match inputs use the globally active Match Result Certification
  -- as the immutable evidence source.
  -- --------------------------------------------------------------------------

  insert into public.round_certification_matches (
    certification_id,
    match_id,
    slot_number,
    included,
    exclusion_reason,
    kickoff,
    match_status,
    home_score,
    away_score,
    provider_updated_at,
    source_snapshot
  )
  select
    v_certification.id,
    frm.match_id,
    frm.slot_number,
    coalesce(lrmd.decision, 'included') <> 'excluded',
    case
      when coalesce(lrmd.decision, 'included') = 'excluded'
        then coalesce(nullif(btrim(lrmd.reason), ''), 'excluded')
      else null
    end,
    coalesce(lrmd.current_kickoff, m.kickoff),
    case
      when coalesce(lrmd.decision, 'included') = 'excluded'
        then m.status
      else mrc.match_status
    end,
    case
      when coalesce(lrmd.decision, 'included') = 'excluded'
        then m.home_score
      else mrc.home_score
    end,
    case
      when coalesce(lrmd.decision, 'included') = 'excluded'
        then m.away_score
      else mrc.away_score
    end,
    coalesce(mrc.provider_updated_at, m.provider_updated_at),
    jsonb_build_object(
      'match_set_entry', jsonb_build_object(
        'fantagol_round_match_id', frm.id,
        'slot_number', frm.slot_number,
        'required', frm.required,
        'decision', coalesce(lrmd.decision, 'included'),
        'decision_version', lrmd.version
      ),
      'match_result_certification', case
        when mrc.id is null then null
        else jsonb_build_object(
          'certification_id', mrc.id,
          'certification_version', mrc.certification_version,
          'source_match_version', mrc.source_match_version,
          'certification_hash', mrc.certification_hash,
          'result_snapshot', mrc.result_snapshot,
          'evidence_snapshot', mrc.evidence_snapshot
        )
      end
    )
  from public.fantagol_round_matches frm
  join public.matches m
    on m.id = frm.match_id
  left join public.league_round_match_decisions lrmd
    on lrmd.league_round_id = v_round.id
   and lrmd.match_id = frm.match_id
  left join public.match_result_certifications mrc
    on mrc.match_id = frm.match_id
   and mrc.status = 'official'
  where frm.fantagol_round_id = v_round.fantagol_round_id
    and frm.removed_at is null
    and frm.required = true
  order by frm.slot_number, frm.match_id;

  -- --------------------------------------------------------------------------
  -- Certified Prediction inputs are copied from the exact runtime rows used by
  -- the committed Calculation Run. Missing predictions remain explicit NULLs.
  -- --------------------------------------------------------------------------

  insert into public.round_certification_predictions (
    certification_id,
    prediction_id,
    prediction_version,
    league_member_id,
    match_id,
    home_prediction,
    away_prediction,
    prediction_status,
    source,
    snapshot
  )
  select
    v_certification.id,
    psrr.prediction_id,
    psrr.prediction_version,
    psrr.league_member_id,
    psrr.match_id,
    psrr.home_prediction,
    psrr.away_prediction,
    case
      when psrr.missing then 'missing'
      when psrr.void then 'void'
      else 'official'
    end,
    'prediction_score_runtime_results',
    jsonb_build_object(
      'calculation_run_id', psrr.calculation_run_id,
      'result_phase', psrr.result_phase,
      'provisional', psrr.provisional,
      'included', psrr.included,
      'missing', psrr.missing,
      'void', psrr.void,
      'scoring_profile_id', psrr.scoring_profile_id,
      'scoring_profile_version', psrr.scoring_profile_version,
      'engine_version', psrr.engine_version,
      'details', psrr.details
    )
  from public.prediction_score_runtime_results psrr
  where psrr.calculation_run_id = v_run.id
  order by psrr.league_member_id, psrr.match_id;

  -- --------------------------------------------------------------------------
  -- Certified Points Pure member results.
  -- --------------------------------------------------------------------------

  insert into public.round_certification_results (
    certification_id,
    league_member_id,
    pure_points,
    exact_count,
    sign_count,
    over_under_count,
    goal_no_goal_count,
    surprise_count,
    goal_show_count,
    grand_slam_count,
    cantonata_count,
    opposite_sign_count,
    details,
    result_hash
  )
  select
    v_certification.id,
    psrr.league_member_id,
    coalesce(sum(psrr.base_total), 0)::numeric(10,2),
    count(*) filter (where psrr.is_exact)::integer,
    count(*) filter (where psrr.is_sign)::integer,
    count(*) filter (where psrr.is_over_under)::integer,
    count(*) filter (where psrr.is_goal_no_goal)::integer,
    count(*) filter (where psrr.is_surprise)::integer,
    count(*) filter (where psrr.is_goal_show)::integer,
    count(*) filter (where psrr.is_grand_slam)::integer,
    count(*) filter (where psrr.is_cantonata)::integer,
    count(*) filter (where psrr.is_opposite_sign)::integer,
    jsonb_build_object(
      'calculation_run_id', v_run.id,
      'member_prediction_results', jsonb_agg(
        jsonb_build_object(
          'match_id', psrr.match_id,
          'prediction_id', psrr.prediction_id,
          'prediction_version', psrr.prediction_version,
          'included', psrr.included,
          'missing', psrr.missing,
          'void', psrr.void,
          'base_total', psrr.base_total,
          'details', psrr.details
        )
        order by psrr.match_id
      )
    ),
    public.compute_jsonb_sha256(
      jsonb_build_object(
        'league_round_id', v_round.id,
        'calculation_run_id', v_run.id,
        'league_member_id', psrr.league_member_id,
        'pure_points', coalesce(sum(psrr.base_total), 0),
        'exact_count', count(*) filter (where psrr.is_exact),
        'sign_count', count(*) filter (where psrr.is_sign),
        'over_under_count', count(*) filter (where psrr.is_over_under),
        'goal_no_goal_count', count(*) filter (where psrr.is_goal_no_goal),
        'surprise_count', count(*) filter (where psrr.is_surprise),
        'goal_show_count', count(*) filter (where psrr.is_goal_show),
        'grand_slam_count', count(*) filter (where psrr.is_grand_slam),
        'cantonata_count', count(*) filter (where psrr.is_cantonata),
        'opposite_sign_count', count(*) filter (where psrr.is_opposite_sign)
      )
    )
  from public.prediction_score_runtime_results psrr
  where psrr.calculation_run_id = v_run.id
  group by psrr.league_member_id
  order by psrr.league_member_id;

  -- --------------------------------------------------------------------------
  -- Official Ranking Ledger. Each mode ranking row becomes one immutable delta.
  -- The Standings Preview already contains the deterministic current-round
  -- contribution and baseline-aware projected position.
  -- --------------------------------------------------------------------------

  insert into public.league_ranking_ledger (
    league_id,
    league_round_id,
    league_member_id,
    certification_id,
    mode,
    points_delta,
    standings_delta,
    active
  )
  select
    v_round.league_id,
    v_round.id,
    (ranking_row ->> 'league_member_id')::uuid,
    v_certification.id,
    mode_entry.key,
    coalesce(
      (ranking_row ->> 'round_points')::numeric,
      0
    )::numeric(10,2),
    ranking_row || jsonb_build_object(
      'ledger_version', v_ledger_version,
      'certification_id', v_certification.id,
      'official', true,
      'preview', false
    ),
    true
  from jsonb_each(
    coalesce(
      v_standings_snapshot -> 'modes',
      '{}'::jsonb
    )
  ) as mode_entry(key, value)
  cross join lateral jsonb_array_elements(
    coalesce(mode_entry.value -> 'ranking', '[]'::jsonb)
  ) as ranking_row
  where mode_entry.key in ('pure_points', 'fantacalcio', 'one_to_one');

  get diagnostics v_ledger_row_count = row_count;

  if v_ledger_row_count <> v_expected_ledger_row_count then
    raise exception using
      errcode = 'P0001',
      message = 'OFFICIAL_LEDGER_ROW_COUNT_MISMATCH',
      detail = jsonb_build_object(
        'expected', v_expected_ledger_row_count,
        'inserted', v_ledger_row_count
      )::text;
  end if;

  -- Mark the authoritative runtime artifacts as committed and certified.
  update public.round_calculation_runs rcr
  set
    status = 'committed',
    committed_certification_id = v_certification.id,
    standings_snapshot = v_standings_snapshot,
    completed_at = coalesce(rcr.completed_at, v_now),
    failed_at = null,
    failure_details = null
  where rcr.id = v_run.id;

  if v_simulation.status = 'preview_ready' then
    update public.round_simulations rs
    set status = 'awaiting_certification'
    where rs.id = v_simulation.id;
  end if;

  update public.round_simulations rs
  set
    status = 'certified',
    preview = false,
    publishable = true,
    certification_id = v_certification.id,
    ledger_version = v_ledger_version,
    certified_at = v_now
  where rs.id = v_simulation.id;

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
    'RoundSimulationCertified',
    jsonb_build_object(
      'certification_id', v_certification.id,
      'certification_version', v_certification.certification_version,
      'certification_hash', v_certification.certification_hash,
      'ledger_version', v_ledger_version,
      'previous_certification_id', v_previous.id
    ),
    p_correlation_id,
    p_committed_by_member_id
  );

  update public.league_rounds lr
  set status = case
    when v_previous.id is null then 'official'
    else 'recalculated'
  end
  where lr.id = v_round.id;

  return query
  select
    v_certification.id,
    v_certification.league_round_id,
    v_certification.certification_version,
    v_certification.status,
    v_run.id,
    v_simulation.id,
    v_certification.certification_hash,
    v_ledger_version,
    v_created,
    v_previous.id;
end;
$function$;

-- ============================================================================
-- 3. ACTIVE ROUND CERTIFICATION READ RPC
-- ============================================================================

create or replace function public.get_active_round_certification_rpc(
  p_league_round_id uuid
)
returns table (
  certification_id uuid,
  league_round_id uuid,
  source_run_id uuid,
  certification_version integer,
  certification_status text,
  certification_hash text,
  match_set_version integer,
  scoring_profile_id uuid,
  scoring_profile_version integer,
  engine_version text,
  committed_at timestamptz,
  standings_snapshot jsonb
)
language sql
stable
security definer
set search_path = public, pg_temp
as $function$
  select
    rc.id,
    rc.league_round_id,
    rc.source_run_id,
    rc.certification_version,
    rc.status,
    rc.certification_hash,
    rc.match_set_version,
    rc.scoring_profile_id,
    rc.scoring_profile_version,
    rc.engine_version,
    rc.committed_at,
    rc.standings_snapshot
  from public.round_certifications rc
  where rc.league_round_id = p_league_round_id
    and rc.status = 'official'
    and rc.active = true
  order by rc.certification_version desc
  limit 1;
$function$;

-- ============================================================================
-- 4. PRIVILEGES
-- ============================================================================

revoke all on function public.evaluate_round_certification_readiness_rpc(
  uuid, uuid, uuid
) from public, anon, authenticated;

grant execute on function public.evaluate_round_certification_readiness_rpc(
  uuid, uuid, uuid
) to service_role;

revoke all on function public.certify_round_rpc(
  uuid, uuid, uuid, text, text, uuid, uuid
) from public, anon, authenticated;

grant execute on function public.certify_round_rpc(
  uuid, uuid, uuid, text, text, uuid, uuid
) to service_role;

revoke all on function public.get_active_round_certification_rpc(
  uuid
) from public, anon;

grant execute on function public.get_active_round_certification_rpc(
  uuid
) to authenticated, service_role;

-- ============================================================================
-- 5. DOCUMENTATION
-- ============================================================================

comment on function public.evaluate_round_certification_readiness_rpc(
  uuid, uuid, uuid
) is
'Evaluates whether one League Round, Calculation Run and completed UI Simulation are ready for atomic official certification. Every included Match must have one active global Match Result Certification. Service-role only.';

comment on function public.certify_round_rpc(
  uuid, uuid, uuid, text, text, uuid, uuid
) is
'Atomically commits an existing deterministic Calculation Run and UI Simulation into the immutable Round Certification archive, certified inputs/results, official Ranking Ledger and League Round lifecycle. Idempotent for an already coherent committed run. Service-role only.';

comment on function public.get_active_round_certification_rpc(
  uuid
) is
'Returns the currently active immutable Round Certification for a League Round.';

commit;
