-- ============================================================================
-- FANTAGOL
-- CONTROLLED LEGACY SIMULATION PURGE AUTHORITY
--
-- Purpose:
--   Introduce the narrow authority required to purge legacy
--   preview_invalidated simulation artifacts that have no certified,
--   published, live-state, or latest-version authority.
--
-- Safety contract:
--   * direct DELETE/UPDATE on round_simulation_events remains forbidden;
--   * the append-only exception is accepted only for DELETE, only when the
--     transaction-local maintenance flag is enabled, and only for postgres;
--   * the purge function independently revalidates every simulation;
--   * any simulation with publication/live/certification/latest authority
--     is rejected;
--   * no generic table name or dynamic SQL is accepted;
--   * PUBLIC receives no execute privilege on the purge function.
--
-- R7/R8 transactional canaries certified this exact mechanism before this
-- migration was created.
-- ============================================================================

create or replace function public.guard_round_simulation_append_only()
returns trigger
language plpgsql
set search_path to 'public', 'pg_temp'
as $function$
begin
  if tg_op = 'DELETE'
     and current_user = 'postgres'
     and current_setting(
           'fantagol.allow_round_simulation_event_delete',
           true
         ) = 'on'
  then
    return old;
  end if;

  raise exception using
    errcode = 'P0001',
    message = 'ROUND_SIMULATION_ARTIFACT_APPEND_ONLY';
end;
$function$;

create or replace function public.purge_legacy_round_simulation_internal(
  p_simulation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_sim public.round_simulations%rowtype;
  v_latest_id uuid;
  v_event_count bigint := 0;
  v_builder_count bigint := 0;
  v_sim_count bigint := 0;
begin
  if p_simulation_id is null then
    raise exception using
      errcode = '22023',
      message = 'PURGE_SIMULATION_ID_REQUIRED';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(p_simulation_id::text, 771)
  );

  select *
    into v_sim
  from public.round_simulations
  where id = p_simulation_id
  for update;

  if v_sim.id is null then
    raise exception using
      errcode = 'P0002',
      message = 'PURGE_SIMULATION_NOT_FOUND';
  end if;

  if v_sim.status <> 'preview_invalidated'
     or v_sim.preview is distinct from true
     or v_sim.publishable is distinct from false
     or v_sim.invalidated_at is null
     or v_sim.certification_id is not null
     or v_sim.certified_at is not null
     or v_sim.archived_at is not null
     or v_sim.failed_at is not null
  then
    raise exception using
      errcode = '55000',
      message = 'PURGE_SIMULATION_NOT_ELIGIBLE';
  end if;

  if exists (
    select 1
    from public.live_state_snapshots l
    where l.simulation_id = v_sim.id
  ) then
    raise exception using
      errcode = '55000',
      message = 'PURGE_SIMULATION_LIVE_SNAPSHOT_BLOCKER';
  end if;

  if exists (
    select 1
    from public.round_simulation_publications p
    where p.simulation_id = v_sim.id
  ) then
    raise exception using
      errcode = '55000',
      message = 'PURGE_SIMULATION_PUBLICATION_BLOCKER';
  end if;

  select s.id
    into v_latest_id
  from public.round_simulations s
  where s.league_round_id = v_sim.league_round_id
  order by
    s.simulation_version desc,
    s.created_at desc,
    s.id desc
  limit 1;

  if v_latest_id = v_sim.id then
    raise exception using
      errcode = '55000',
      message = 'PURGE_SIMULATION_LATEST_VERSION_BLOCKER';
  end if;

  perform set_config(
    'fantagol.allow_round_simulation_event_delete',
    'on',
    true
  );

  delete from public.round_simulation_events
  where simulation_id = v_sim.id;

  get diagnostics v_event_count = row_count;

  perform set_config(
    'fantagol.allow_round_simulation_event_delete',
    'off',
    true
  );

  select count(*)
    into v_builder_count
  from public.round_simulation_builder_runs
  where simulation_id = v_sim.id;

  delete from public.round_simulations
  where id = v_sim.id;

  get diagnostics v_sim_count = row_count;

  if v_sim_count <> 1 then
    raise exception using
      errcode = '55000',
      message = 'PURGE_SIMULATION_DELETE_COUNT_INVALID';
  end if;

  return jsonb_build_object(
    'simulation_id', v_sim.id,
    'league_round_id', v_sim.league_round_id,
    'simulation_version', v_sim.simulation_version,
    'deleted_simulations', v_sim_count,
    'deleted_events', v_event_count,
    'builder_rows_expected_cascade', v_builder_count
  );
exception
  when others then
    perform set_config(
      'fantagol.allow_round_simulation_event_delete',
      'off',
      true
    );
    raise;
end;
$function$;

revoke all
on function public.purge_legacy_round_simulation_internal(uuid)
from public;

comment on function public.purge_legacy_round_simulation_internal(uuid)
is
'Controlled maintenance-only purge for legacy preview_invalidated round simulations. '
'Rejects certified, published, live-referenced and latest-version simulations. '
'PUBLIC execute is revoked.';
