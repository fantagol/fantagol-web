-- FANTAGOL
-- Migration 154
-- League Destruction Engine Foundation
--
-- Purpose
--   Allow an active administrator to permanently delete an eligible league,
--   including private leagues that already contain predictions, calculations,
--   simulations and certified results.
--
-- Design
--   * Preserve all existing RESTRICT foreign keys.
--   * Preserve the stricter public-league deletion policy.
--   * Execute explicit, ordered and atomic aggregate destruction.
--   * Keep the internal destruction primitive unavailable to API roles.

begin;

create or replace function public.destroy_league_aggregate_internal(
  p_league_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_league_name text;

  v_strategy_versions_removed bigint := 0;
  v_admin_activity_evaluations_removed bigint := 0;
  v_ranking_ledger_entries_removed bigint := 0;
  v_recovery_authorizations_removed bigint := 0;
  v_live_state_snapshots_removed bigint := 0;
  v_simulation_events_removed bigint := 0;
  v_certification_predictions_removed bigint := 0;
  v_certification_results_removed bigint := 0;
  v_runtime_results_removed bigint := 0;
  v_simulations_removed bigint := 0;
  v_certifications_removed bigint := 0;
  v_calculation_runs_removed bigint := 0;
  v_predictions_removed bigint := 0;
  v_strategies_removed bigint := 0;
  v_fixtures_removed bigint := 0;
  v_scoring_profiles_removed bigint := 0;
  v_league_removed bigint := 0;
begin
  if p_league_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_ID_REQUIRED';
  end if;

  select l.name
  into v_league_name
  from public.leagues l
  where l.id = p_league_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_NOT_FOUND';
  end if;

  -- Serialize destructive operations for the same league inside the transaction.
  perform pg_advisory_xact_lock(hashtextextended(p_league_id::text, 154));

  -- Remove stale active-league pointers before deleting the aggregate.
  update public.profiles
  set last_active_league_id = null
  where last_active_league_id = p_league_id;

  -- strategy_versions is immutable in normal runtime and must be explicitly
  -- unlocked for the controlled destruction transaction.
  perform set_config(
    'fantagol.allow_strategy_version_delete',
    'on',
    true
  );

  delete from public.strategy_versions sv
  using public.strategies s
  where sv.strategy_id = s.id
    and s.league_id = p_league_id;
  get diagnostics v_strategy_versions_removed = row_count;

  -- Certification and governance leaves.
  delete from public.league_admin_activity_evaluations laae
  where laae.league_id = p_league_id;
  get diagnostics v_admin_activity_evaluations_removed = row_count;

  delete from public.league_ranking_ledger lrl
  where lrl.league_id = p_league_id;
  get diagnostics v_ranking_ledger_entries_removed = row_count;

  delete from public.prediction_recovery_authorizations pra
  where pra.league_id = p_league_id;
  get diagnostics v_recovery_authorizations_removed = row_count;

  -- Live-state and simulation leaves must disappear before simulations.
  delete from public.live_state_snapshots lss
  using public.league_rounds lr
  where lss.league_round_id = lr.id
    and lr.league_id = p_league_id;
  get diagnostics v_live_state_snapshots_removed = row_count;

  delete from public.round_simulation_events rse
  using public.league_rounds lr
  where rse.league_round_id = lr.id
    and lr.league_id = p_league_id;
  get diagnostics v_simulation_events_removed = row_count;

  -- Immutable certification projections must disappear before certifications.
  delete from public.round_certification_predictions rcp
  using public.round_certifications rc,
        public.league_rounds lr
  where rcp.certification_id = rc.id
    and rc.league_round_id = lr.id
    and lr.league_id = p_league_id;
  get diagnostics v_certification_predictions_removed = row_count;

  delete from public.round_certification_results rcr
  using public.round_certifications rc,
        public.league_rounds lr
  where rcr.certification_id = rc.id
    and rc.league_round_id = lr.id
    and lr.league_id = p_league_id;
  get diagnostics v_certification_results_removed = row_count;

  -- Runtime scoring results hold RESTRICT references to league members and
  -- scoring profiles. Remove them before either parent family.
  delete from public.prediction_score_runtime_results psrr
  using public.league_rounds lr
  where psrr.league_round_id = lr.id
    and lr.league_id = p_league_id;
  get diagnostics v_runtime_results_removed = row_count;

  -- Simulations reference calculation runs with RESTRICT.
  delete from public.round_simulations rs
  using public.league_rounds lr
  where rs.league_round_id = lr.id
    and lr.league_id = p_league_id;
  get diagnostics v_simulations_removed = row_count;

  -- Certifications reference calculation runs with RESTRICT. Deleting the
  -- certification also clears nullable committed/certification links through
  -- their existing SET NULL contracts.
  delete from public.round_certifications rc
  using public.league_rounds lr
  where rc.league_round_id = lr.id
    and lr.league_id = p_league_id;
  get diagnostics v_certifications_removed = row_count;

  delete from public.round_calculation_runs rcr
  using public.league_rounds lr
  where rcr.league_round_id = lr.id
    and lr.league_id = p_league_id;
  get diagnostics v_calculation_runs_removed = row_count;

  -- Gameplay projections referencing members through RESTRICT.
  delete from public.predictions p
  where p.league_id = p_league_id;
  get diagnostics v_predictions_removed = row_count;

  delete from public.strategies s
  where s.league_id = p_league_id;
  get diagnostics v_strategies_removed = row_count;

  delete from public.league_fixtures lf
  where lf.league_id = p_league_id;
  get diagnostics v_fixtures_removed = row_count;

  -- Profiles reference both league rounds and runtime/certification families.
  delete from public.league_scoring_profiles lsp
  where lsp.league_id = p_league_id;
  get diagnostics v_scoring_profiles_removed = row_count;

  -- The remaining aggregate is now safe for its declared cascades.
  delete from public.leagues l
  where l.id = p_league_id;
  get diagnostics v_league_removed = row_count;

  if v_league_removed <> 1 then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_DELETE_FAILED';
  end if;

  return jsonb_build_object(
    'deleted', true,
    'league_id', p_league_id,
    'league_name', v_league_name,
    'destruction_engine_version', '154.1',
    'removed', jsonb_build_object(
      'strategy_versions', v_strategy_versions_removed,
      'admin_activity_evaluations', v_admin_activity_evaluations_removed,
      'ranking_ledger_entries', v_ranking_ledger_entries_removed,
      'recovery_authorizations', v_recovery_authorizations_removed,
      'live_state_snapshots', v_live_state_snapshots_removed,
      'simulation_events', v_simulation_events_removed,
      'certification_predictions', v_certification_predictions_removed,
      'certification_results', v_certification_results_removed,
      'prediction_score_runtime_results', v_runtime_results_removed,
      'round_simulations', v_simulations_removed,
      'round_certifications', v_certifications_removed,
      'round_calculation_runs', v_calculation_runs_removed,
      'predictions', v_predictions_removed,
      'strategies', v_strategies_removed,
      'league_fixtures', v_fixtures_removed,
      'league_scoring_profiles', v_scoring_profiles_removed,
      'leagues', v_league_removed
    )
  );
end;
$function$;

revoke all on function public.destroy_league_aggregate_internal(uuid) from public;
revoke all on function public.destroy_league_aggregate_internal(uuid) from anon;
revoke all on function public.destroy_league_aggregate_internal(uuid) from authenticated;
revoke all on function public.destroy_league_aggregate_internal(uuid) from service_role;

create or replace function public.delete_league_permanently_rpc(
  p_league_id uuid,
  p_confirmation_name text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_user_id uuid := auth.uid();
  v_league public.leagues%rowtype;
  v_admin_member_id uuid;
  v_historical_non_admin_members_count bigint := 0;
  v_started_rounds_count bigint := 0;
begin
  if v_user_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'AUTH_REQUIRED';
  end if;

  select *
  into v_league
  from public.leagues
  where id = p_league_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_NOT_FOUND';
  end if;

  v_admin_member_id := public.get_active_admin_member_id(
    p_league_id,
    v_user_id
  );

  if v_admin_member_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'ACTIVE_ADMIN_REQUIRED';
  end if;

  if p_confirmation_name is null
     or btrim(p_confirmation_name) <> v_league.name
  then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_NAME_CONFIRMATION_MISMATCH';
  end if;

  -- Public competitions preserve their stricter governance contract.
  -- Private leagues intentionally remain deletable after gameplay has begun.
  if v_league.visibility = 'public' then
    select count(*)
    into v_historical_non_admin_members_count
    from public.league_members lm
    where lm.league_id = p_league_id
      and lm.id <> v_admin_member_id;

    if v_historical_non_admin_members_count > 0 then
      raise exception using
        errcode = 'P0001',
        message = 'PUBLIC_LEAGUE_DELETE_REQUIRES_NO_HISTORICAL_PARTICIPANTS';
    end if;

    select count(*)
    into v_started_rounds_count
    from public.league_rounds lr
    where lr.league_id = p_league_id
      and lr.first_official_score_at is not null;

    if v_league.started_at is not null
       or v_league.first_useful_kickoff_at is not null
       or v_started_rounds_count > 0
    then
      raise exception using
        errcode = 'P0001',
        message = 'PUBLIC_LEAGUE_DELETE_FORBIDDEN_AFTER_COMPETITION_START';
    end if;
  end if;

  return public.destroy_league_aggregate_internal(p_league_id);
end;
$function$;

revoke all on function public.delete_league_permanently_rpc(uuid, text) from public;
revoke all on function public.delete_league_permanently_rpc(uuid, text) from anon;
grant execute on function public.delete_league_permanently_rpc(uuid, text) to authenticated;
grant execute on function public.delete_league_permanently_rpc(uuid, text) to service_role;

comment on function public.destroy_league_aggregate_internal(uuid) is
  'Internal atomic League Destruction Engine. Explicitly removes protected league-owned runtime, certification, simulation and gameplay data before deleting the league aggregate.';

comment on function public.delete_league_permanently_rpc(uuid, text) is
  'Admin-authorized permanent league deletion. Private leagues may be destroyed after gameplay; public leagues retain historical-participant and competition-start protections.';

commit;
