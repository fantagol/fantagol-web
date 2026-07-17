-- ============================================================================
-- FANTAGOL
-- Migration 050: Live Runtime Publication Ambiguity Hotfix
--
-- Qualifies UPDATE target columns inside publish_live_state_snapshot_rpc
-- to avoid collisions with RETURNS TABLE output names such as
-- league_round_id, simulation_id, channel and published_at.
-- ============================================================================

begin;

create or replace function public.publish_live_state_snapshot_rpc(
  p_live_state_snapshot_id uuid,
  p_channel text default 'realtime',
  p_metadata jsonb default '{}'::jsonb
)
returns table (
  publication_id uuid,
  live_state_snapshot_id uuid,
  league_round_id uuid,
  simulation_id uuid,
  publication_version integer,
  channel text,
  publication_status text,
  simulation_version integer,
  simulation_hash text,
  published_at timestamptz
)
language plpgsql
security definer
set search_path to public, pg_temp
as $function$
declare
  v_snapshot public.live_state_snapshots%rowtype;
  v_simulation public.round_simulations%rowtype;
  v_existing_publication public.round_simulation_publications%rowtype;
  v_publication public.round_simulation_publications%rowtype;
  v_previous_snapshot_id uuid;
  v_publication_version integer;
  v_published_at timestamptz := clock_timestamp();
begin
  if p_channel not in ('web', 'android', 'internal', 'realtime') then
    raise exception using
      errcode = 'P0001',
      message = 'LIVE_PUBLICATION_CHANNEL_INVALID';
  end if;

  select ls.*
  into v_snapshot
  from public.live_state_snapshots ls
  where ls.id = p_live_state_snapshot_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'LIVE_STATE_SNAPSHOT_NOT_FOUND';
  end if;

  if v_snapshot.status not in ('ready', 'published') then
    raise exception using
      errcode = 'P0001',
      message = 'LIVE_STATE_SNAPSHOT_NOT_PUBLISHABLE',
      detail = v_snapshot.status;
  end if;

  select rs.*
  into v_simulation
  from public.round_simulations rs
  where rs.id = v_snapshot.simulation_id;

  if not found
     or v_simulation.status not in (
       'preview_ready',
       'awaiting_certification',
       'certified'
     )
     or not v_simulation.publishable
     or v_simulation.simulation_hash is null then
    raise exception using
      errcode = 'P0001',
      message = 'LIVE_SOURCE_SIMULATION_NOT_PUBLISHABLE';
  end if;

  select rsp.*
  into v_existing_publication
  from public.round_simulation_publications rsp
  where rsp.simulation_id = v_simulation.id
    and rsp.channel = p_channel
  limit 1;

  if found then
    return query
    select
      v_existing_publication.id,
      v_snapshot.id,
      v_existing_publication.league_round_id,
      v_existing_publication.simulation_id,
      v_existing_publication.publication_version,
      v_existing_publication.channel,
      v_existing_publication.status,
      v_existing_publication.simulation_version,
      v_existing_publication.simulation_hash,
      v_existing_publication.published_at;
    return;
  end if;

  perform pg_advisory_xact_lock(
    hashtext(
      'live-publication:'
      || v_snapshot.league_round_id::text
      || ':'
      || p_channel
    )
  );

  select
    (rsp.metadata ->> 'live_state_snapshot_id')::uuid
  into v_previous_snapshot_id
  from public.round_simulation_publications rsp
  where rsp.league_round_id = v_snapshot.league_round_id
    and rsp.channel = p_channel
    and rsp.status = 'published'
  limit 1;

  update public.round_simulation_publications as rsp_current
  set
    status = 'superseded',
    superseded_at = v_published_at
  where rsp_current.league_round_id = v_snapshot.league_round_id
    and rsp_current.channel = p_channel
    and rsp_current.status = 'published';

  if v_previous_snapshot_id is not null
     and v_previous_snapshot_id <> v_snapshot.id
     and not exists (
       select 1
       from public.round_simulation_publications rsp
       where rsp.status = 'published'
         and (rsp.metadata ->> 'live_state_snapshot_id')::uuid
           = v_previous_snapshot_id
     ) then
    update public.live_state_snapshots as ls_previous
    set
      status = 'superseded',
      superseded_at = v_published_at
    where ls_previous.id = v_previous_snapshot_id
      and ls_previous.status = 'published';
  end if;

  select coalesce(max(rsp.publication_version), 0) + 1
  into v_publication_version
  from public.round_simulation_publications rsp
  where rsp.league_round_id = v_snapshot.league_round_id
    and rsp.channel = p_channel;

  insert into public.round_simulation_publications (
    simulation_id,
    league_round_id,
    publication_version,
    channel,
    status,
    simulation_version,
    simulation_hash,
    published_at,
    metadata
  )
  values (
    v_simulation.id,
    v_snapshot.league_round_id,
    v_publication_version,
    p_channel,
    'published',
    v_simulation.simulation_version,
    v_simulation.simulation_hash,
    v_published_at,
    coalesce(p_metadata, '{}'::jsonb)
      || jsonb_build_object(
        'live_state_snapshot_id', v_snapshot.id,
        'live_state_version', v_snapshot.live_state_version,
        'live_state_snapshot_hash', v_snapshot.snapshot_hash,
        'live_engine_version', v_snapshot.engine_version
      )
  )
  returning *
  into v_publication;

  update public.live_state_snapshots as ls_current
  set
    status = 'published',
    primary_publication_id = coalesce(
      ls_current.primary_publication_id,
      v_publication.id
    ),
    published_at = coalesce(
      ls_current.published_at,
      v_published_at
    )
  where ls_current.id = v_snapshot.id;

  insert into public.round_simulation_events (
    simulation_id,
    league_round_id,
    calculation_run_id,
    event_type,
    event_version,
    payload,
    correlation_id,
    occurred_at
  )
  values (
    v_simulation.id,
    v_simulation.league_round_id,
    v_simulation.calculation_run_id,
    'SimulationPublished',
    1,
    jsonb_build_object(
      'publication_id', v_publication.id,
      'publication_version', v_publication.publication_version,
      'channel', v_publication.channel,
      'live_state_snapshot_id', v_snapshot.id,
      'live_state_version', v_snapshot.live_state_version
    ),
    v_snapshot.correlation_id,
    v_published_at
  );

  return query
  select
    v_publication.id,
    v_snapshot.id,
    v_publication.league_round_id,
    v_publication.simulation_id,
    v_publication.publication_version,
    v_publication.channel,
    v_publication.status,
    v_publication.simulation_version,
    v_publication.simulation_hash,
    v_publication.published_at;
end;
$function$;

revoke all on function public.publish_live_state_snapshot_rpc(
  uuid,
  text,
  jsonb
) from public;

revoke all on function public.publish_live_state_snapshot_rpc(
  uuid,
  text,
  jsonb
) from anon;

revoke all on function public.publish_live_state_snapshot_rpc(
  uuid,
  text,
  jsonb
) from authenticated;

grant execute on function public.publish_live_state_snapshot_rpc(
  uuid,
  text,
  jsonb
) to service_role;

comment on function public.publish_live_state_snapshot_rpc(
  uuid,
  text,
  jsonb
) is
'Publishes a ready Live State Snapshot through the existing round_simulation_publications registry, superseding the previous channel publication atomically. Service-role only.';

commit;
