-- ============================================================================
-- FANTAGOL
-- Migration 061: Publication Engine Governance
--
-- Completa il Publication Engine già introdotto dalle migrazioni precedenti.
-- Non ricalcola punteggi e non scrive il Ranking Ledger.
--
-- Responsabilità:
--   * readiness deterministica della pubblicazione ufficiale
--   * manifest e hash di pubblicazione
--   * comando atomico e idempotente di pubblicazione
--   * superseding controllato della pubblicazione corrente
--   * audit tramite round_simulation_events
--   * query layer per UI / Control Room
--   * protezione delle righe di pubblicazione
-- ============================================================================

begin;

-- --------------------------------------------------------------------------
-- 1. Guard di immutabilità e transizione delle pubblicazioni
-- --------------------------------------------------------------------------

create or replace function public.guard_round_simulation_publication_update()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'DELETE' then
    raise exception using
      errcode = 'P0001',
      message = 'ROUND_PUBLICATION_DELETE_FORBIDDEN';
  end if;

  -- Identità, provenienza e contenuto certificato sono append-only.
  if new.id is distinct from old.id
     or new.simulation_id is distinct from old.simulation_id
     or new.league_round_id is distinct from old.league_round_id
     or new.publication_version is distinct from old.publication_version
     or new.channel is distinct from old.channel
     or new.simulation_version is distinct from old.simulation_version
     or new.simulation_hash is distinct from old.simulation_hash
     or new.published_at is distinct from old.published_at
     or new.metadata is distinct from old.metadata then
    raise exception using
      errcode = 'P0001',
      message = 'ROUND_PUBLICATION_IMMUTABLE_FIELDS';
  end if;

  -- Transizioni ammesse:
  -- published -> superseded
  -- published -> withdrawn
  -- nessuna riattivazione di record storici.
  if old.status = 'published'
     and new.status in ('superseded', 'withdrawn') then
    if new.superseded_at is null then
      raise exception using
        errcode = 'P0001',
        message = 'ROUND_PUBLICATION_TERMINAL_TIMESTAMP_REQUIRED';
    end if;

    return new;
  end if;

  if new.status = old.status
     and new.superseded_at is not distinct from old.superseded_at then
    return new;
  end if;

  raise exception using
    errcode = 'P0001',
    message = 'ROUND_PUBLICATION_TRANSITION_INVALID',
    detail = old.status || ' -> ' || new.status;
end;
$$;

comment on function public.guard_round_simulation_publication_update() is
  'Protegge le pubblicazioni come record append-only; consente solo published -> superseded/withdrawn.';

drop trigger if exists round_simulation_publications_governance_guard
  on public.round_simulation_publications;

create trigger round_simulation_publications_governance_guard
before update or delete on public.round_simulation_publications
for each row
execute function public.guard_round_simulation_publication_update();

-- --------------------------------------------------------------------------
-- 2. Readiness della pubblicazione ufficiale
-- --------------------------------------------------------------------------

create or replace function public.validate_round_publication_rpc(
  p_league_round_id uuid,
  p_channel text default 'web'
)
returns table (
  ready boolean,
  readiness_code text,
  readiness_details jsonb,
  league_round_id uuid,
  certification_id uuid,
  simulation_id uuid,
  simulation_version integer,
  simulation_hash text,
  current_publication_id uuid,
  current_publication_version integer
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_round public.league_rounds%rowtype;
  v_certification public.round_certifications%rowtype;
  v_simulation public.round_simulations%rowtype;
  v_current public.round_simulation_publications%rowtype;
  v_missing_components text[] := array[]::text[];
  v_pending_match_count integer := 0;
  v_finished_match_count integer := 0;
  v_match_count integer := 0;
  v_member_allowed boolean := false;
begin
  if p_league_round_id is null then
    raise exception using
      errcode = '22004',
      message = 'LEAGUE_ROUND_ID_REQUIRED';
  end if;

  if p_channel not in ('web', 'android', 'internal', 'realtime') then
    raise exception using
      errcode = 'P0001',
      message = 'ROUND_PUBLICATION_CHANNEL_INVALID';
  end if;

  select lr.*
  into v_round
  from public.league_rounds lr
  where lr.id = p_league_round_id;

  if not found then
    return query
    select false, 'ROUND_NOT_FOUND', '{}'::jsonb,
           p_league_round_id, null::uuid, null::uuid, null::integer,
           null::text, null::uuid, null::integer;
    return;
  end if;

  -- Authenticated può ispezionare solo le proprie leghe.
  -- service_role/postgres non hanno auth.uid() e sono ammessi come runtime.
  if auth.uid() is not null then
    select exists (
      select 1
      from public.league_members lm
      where lm.league_id = v_round.league_id
        and lm.user_id = auth.uid()
        and lm.status = 'active'
    ) into v_member_allowed;

    if not v_member_allowed then
      raise exception using
        errcode = '42501',
        message = 'ROUND_PUBLICATION_ACCESS_DENIED';
    end if;
  end if;

  select rc.*
  into v_certification
  from public.round_certifications rc
  where rc.league_round_id = p_league_round_id
    and rc.active = true
    and rc.status = 'official'
  order by rc.certification_version desc
  limit 1;

  if not found then
    return query
    select false,
           'ACTIVE_CERTIFICATION_MISSING',
           jsonb_build_object('round_status', v_round.status),
           p_league_round_id,
           null::uuid,
           null::uuid,
           null::integer,
           null::text,
           null::uuid,
           null::integer;
    return;
  end if;

  select rs.*
  into v_simulation
  from public.round_simulations rs
  where rs.league_round_id = p_league_round_id
    and rs.certification_id = v_certification.id
    and rs.status = 'certified'
    and rs.preview = false
  order by rs.simulation_version desc
  limit 1;

  if not found then
    return query
    select false,
           'CERTIFIED_SIMULATION_MISSING',
           jsonb_build_object(
             'certification_id', v_certification.id,
             'certification_version', v_certification.certification_version
           ),
           p_league_round_id,
           v_certification.id,
           null::uuid,
           null::integer,
           null::text,
           null::uuid,
           null::integer;
    return;
  end if;

  select rsp.*
  into v_current
  from public.round_simulation_publications rsp
  where rsp.league_round_id = p_league_round_id
    and rsp.channel = p_channel
    and rsp.status = 'published'
  limit 1;

  if v_simulation.simulation_hash is null
     or v_simulation.simulation_hash !~ '^[0-9a-f]{64}$' then
    return query
    select false,
           'CERTIFIED_SIMULATION_HASH_INVALID',
           jsonb_build_object('simulation_id', v_simulation.id),
           p_league_round_id,
           v_certification.id,
           v_simulation.id,
           v_simulation.simulation_version,
           v_simulation.simulation_hash,
           v_current.id,
           v_current.publication_version;
    return;
  end if;

  if not v_simulation.publishable then
    return query
    select false,
           'CERTIFIED_SIMULATION_NOT_PUBLISHABLE',
           jsonb_build_object('simulation_status', v_simulation.status),
           p_league_round_id,
           v_certification.id,
           v_simulation.id,
           v_simulation.simulation_version,
           v_simulation.simulation_hash,
           v_current.id,
           v_current.publication_version;
    return;
  end if;

  -- Il Digital Twin finale deve contenere tutti i layer ufficiali.
  if not (v_simulation.digital_twin ? 'points_preview') then
    v_missing_components := array_append(v_missing_components, 'points_preview');
  end if;
  if not (v_simulation.digital_twin ? 'fantacalcio_preview') then
    v_missing_components := array_append(v_missing_components, 'fantacalcio_preview');
  end if;
  if not (v_simulation.digital_twin ? 'one_to_one_preview') then
    v_missing_components := array_append(v_missing_components, 'one_to_one_preview');
  end if;
  if not (v_simulation.digital_twin ? 'standings_preview') then
    v_missing_components := array_append(v_missing_components, 'standings_preview');
  end if;
  if not (v_simulation.digital_twin ? 'manifest') then
    v_missing_components := array_append(v_missing_components, 'manifest');
  end if;
  if not (v_simulation.digital_twin ? 'round') then
    v_missing_components := array_append(v_missing_components, 'round');
  end if;

  if cardinality(v_missing_components) > 0 then
    return query
    select false,
           'DIGITAL_TWIN_COMPONENTS_MISSING',
           jsonb_build_object('missing_components', to_jsonb(v_missing_components)),
           p_league_round_id,
           v_certification.id,
           v_simulation.id,
           v_simulation.simulation_version,
           v_simulation.simulation_hash,
           v_current.id,
           v_current.publication_version;
    return;
  end if;

  v_pending_match_count := coalesce(
    nullif(v_simulation.digital_twin #>> '{round,pending_match_count}', '')::integer,
    0
  );
  v_finished_match_count := coalesce(
    nullif(v_simulation.digital_twin #>> '{round,finished_match_count}', '')::integer,
    0
  );
  v_match_count := coalesce(
    nullif(v_simulation.digital_twin #>> '{round,match_count}', '')::integer,
    0
  );

  if v_pending_match_count <> 0
     or v_match_count <= 0
     or v_finished_match_count <> v_match_count then
    return query
    select false,
           'ROUND_MATCHES_NOT_FINAL',
           jsonb_build_object(
             'match_count', v_match_count,
             'finished_match_count', v_finished_match_count,
             'pending_match_count', v_pending_match_count
           ),
           p_league_round_id,
           v_certification.id,
           v_simulation.id,
           v_simulation.simulation_version,
           v_simulation.simulation_hash,
           v_current.id,
           v_current.publication_version;
    return;
  end if;

  if v_current.id is not null
     and v_current.simulation_id = v_simulation.id
     and v_current.simulation_hash = v_simulation.simulation_hash then
    return query
    select true,
           'ALREADY_PUBLISHED',
           jsonb_build_object(
             'idempotent', true,
             'publication_status', v_current.status
           ),
           p_league_round_id,
           v_certification.id,
           v_simulation.id,
           v_simulation.simulation_version,
           v_simulation.simulation_hash,
           v_current.id,
           v_current.publication_version;
    return;
  end if;

  return query
  select true,
         'READY',
         jsonb_build_object(
           'certification_version', v_certification.certification_version,
           'certification_hash', v_certification.certification_hash,
           'simulation_status', v_simulation.status,
           'publishable', v_simulation.publishable,
           'match_count', v_match_count,
           'finished_match_count', v_finished_match_count,
           'pending_match_count', v_pending_match_count,
           'will_supersede_publication_id', v_current.id
         ),
         p_league_round_id,
         v_certification.id,
         v_simulation.id,
         v_simulation.simulation_version,
         v_simulation.simulation_hash,
         v_current.id,
         v_current.publication_version;
end;
$$;

comment on function public.validate_round_publication_rpc(uuid, text) is
  'Verifica readiness, certificazione, completezza Digital Twin, hash e stato corrente della pubblicazione.';

-- --------------------------------------------------------------------------
-- 3. Comando atomico e idempotente di pubblicazione ufficiale
-- --------------------------------------------------------------------------

create or replace function public.publish_round_rpc(
  p_league_round_id uuid,
  p_channel text default 'web',
  p_metadata jsonb default '{}'::jsonb,
  p_correlation_id uuid default gen_random_uuid()
)
returns table (
  publication_id uuid,
  league_round_id uuid,
  certification_id uuid,
  simulation_id uuid,
  publication_version integer,
  channel text,
  publication_status text,
  publication_hash text,
  simulation_version integer,
  simulation_hash text,
  published_at timestamptz,
  idempotent boolean
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_readiness record;
  v_certification public.round_certifications%rowtype;
  v_simulation public.round_simulations%rowtype;
  v_existing public.round_simulation_publications%rowtype;
  v_publication public.round_simulation_publications%rowtype;
  v_publication_version integer;
  v_published_at timestamptz := clock_timestamp();
  v_manifest jsonb;
  v_publication_hash text;
begin
  if p_channel not in ('web', 'android', 'internal', 'realtime') then
    raise exception using
      errcode = 'P0001',
      message = 'ROUND_PUBLICATION_CHANNEL_INVALID';
  end if;

  perform pg_advisory_xact_lock(
    hashtext('round-publication:' || p_league_round_id::text || ':' || p_channel)
  );

  select *
  into v_readiness
  from public.validate_round_publication_rpc(p_league_round_id, p_channel);

  if not v_readiness.ready then
    raise exception using
      errcode = 'P0001',
      message = 'ROUND_PUBLICATION_NOT_READY',
      detail = v_readiness.readiness_code,
      hint = coalesce(v_readiness.readiness_details, '{}'::jsonb)::text;
  end if;

  select rc.*
  into strict v_certification
  from public.round_certifications rc
  where rc.id = v_readiness.certification_id
  for share;

  select rs.*
  into strict v_simulation
  from public.round_simulations rs
  where rs.id = v_readiness.simulation_id
  for share;

  select rsp.*
  into v_existing
  from public.round_simulation_publications rsp
  where rsp.simulation_id = v_simulation.id
    and rsp.channel = p_channel
  limit 1;

  if found then
    return query
    select
      v_existing.id,
      v_existing.league_round_id,
      v_certification.id,
      v_existing.simulation_id,
      v_existing.publication_version,
      v_existing.channel,
      v_existing.status,
      v_existing.metadata ->> 'publication_hash',
      v_existing.simulation_version,
      v_existing.simulation_hash,
      v_existing.published_at,
      true;
    return;
  end if;

  select coalesce(max(rsp.publication_version), 0) + 1
  into v_publication_version
  from public.round_simulation_publications rsp
  where rsp.league_round_id = p_league_round_id
    and rsp.channel = p_channel;

  v_manifest := jsonb_build_object(
    'schema_version', 1,
    'engine', 'PublicationEngine',
    'engine_version', 'publication-governance-v1',
    'league_round_id', p_league_round_id,
    'channel', p_channel,
    'publication_version', v_publication_version,
    'certification_id', v_certification.id,
    'certification_version', v_certification.certification_version,
    'certification_hash', v_certification.certification_hash,
    'simulation_id', v_simulation.id,
    'simulation_version', v_simulation.simulation_version,
    'simulation_hash', v_simulation.simulation_hash,
    'simulation_engine_version', v_simulation.engine_version,
    'snapshot_schema_version', v_simulation.snapshot_schema_version,
    'calculation_run_id', v_simulation.calculation_run_id,
    'published_at', v_published_at,
    'correlation_id', coalesce(p_correlation_id, gen_random_uuid())
  );

  v_publication_hash := encode(
    extensions.digest(convert_to(v_manifest::text, 'UTF8'), 'sha256'),
    'hex'
  );

  -- La vecchia pubblicazione corrente diventa storica nella stessa transazione.
  update public.round_simulation_publications rsp
  set
    status = 'superseded',
    superseded_at = v_published_at
  where rsp.league_round_id = p_league_round_id
    and rsp.channel = p_channel
    and rsp.status = 'published';

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
    p_league_round_id,
    v_publication_version,
    p_channel,
    'published',
    v_simulation.simulation_version,
    v_simulation.simulation_hash,
    v_published_at,
    coalesce(p_metadata, '{}'::jsonb)
      || jsonb_build_object(
        'publication_type', 'official_round',
        'publication_manifest', v_manifest,
        'publication_hash', v_publication_hash,
        'certification_id', v_certification.id,
        'certification_hash', v_certification.certification_hash,
        'correlation_id', p_correlation_id
      )
  )
  returning *
  into v_publication;

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
    p_league_round_id,
    v_simulation.calculation_run_id,
    'RoundPublicationCompleted',
    1,
    jsonb_build_object(
      'publication_id', v_publication.id,
      'publication_version', v_publication.publication_version,
      'publication_hash', v_publication_hash,
      'channel', v_publication.channel,
      'certification_id', v_certification.id,
      'certification_version', v_certification.certification_version,
      'certification_hash', v_certification.certification_hash,
      'simulation_version', v_simulation.simulation_version,
      'simulation_hash', v_simulation.simulation_hash
    ),
    p_correlation_id,
    v_published_at
  );

  return query
  select
    v_publication.id,
    v_publication.league_round_id,
    v_certification.id,
    v_publication.simulation_id,
    v_publication.publication_version,
    v_publication.channel,
    v_publication.status,
    v_publication_hash,
    v_publication.simulation_version,
    v_publication.simulation_hash,
    v_publication.published_at,
    false;
end;
$$;

comment on function public.publish_round_rpc(uuid, text, jsonb, uuid) is
  'Pubblica atomicamente la simulazione ufficiale certificata; è idempotente per simulation_id + channel.';

-- --------------------------------------------------------------------------
-- 4. Query layer stato pubblicazione
-- --------------------------------------------------------------------------

create or replace function public.get_round_publication_status_rpc(
  p_league_round_id uuid,
  p_channel text default 'web'
)
returns table (
  league_round_id uuid,
  channel text,
  is_ready boolean,
  readiness_code text,
  readiness_details jsonb,
  is_published boolean,
  publication_id uuid,
  publication_version integer,
  publication_status text,
  publication_hash text,
  certification_id uuid,
  certification_version integer,
  certification_hash text,
  simulation_id uuid,
  simulation_version integer,
  simulation_hash text,
  published_at timestamptz,
  superseded_at timestamptz,
  metadata jsonb
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_readiness record;
  v_publication public.round_simulation_publications%rowtype;
  v_certification public.round_certifications%rowtype;
begin
  select *
  into v_readiness
  from public.validate_round_publication_rpc(p_league_round_id, p_channel);

  select rsp.*
  into v_publication
  from public.round_simulation_publications rsp
  where rsp.league_round_id = p_league_round_id
    and rsp.channel = p_channel
    and rsp.status = 'published'
  limit 1;

  if v_publication.id is not null then
    select rc.*
    into v_certification
    from public.round_certifications rc
    where rc.id = nullif(v_publication.metadata ->> 'certification_id', '')::uuid;
  elsif v_readiness.certification_id is not null then
    select rc.*
    into v_certification
    from public.round_certifications rc
    where rc.id = v_readiness.certification_id;
  end if;

  return query
  select
    p_league_round_id,
    p_channel,
    v_readiness.ready,
    v_readiness.readiness_code,
    v_readiness.readiness_details,
    (v_publication.id is not null),
    v_publication.id,
    v_publication.publication_version,
    v_publication.status,
    v_publication.metadata ->> 'publication_hash',
    v_certification.id,
    v_certification.certification_version,
    v_certification.certification_hash,
    coalesce(v_publication.simulation_id, v_readiness.simulation_id),
    coalesce(v_publication.simulation_version, v_readiness.simulation_version),
    coalesce(v_publication.simulation_hash, v_readiness.simulation_hash),
    v_publication.published_at,
    v_publication.superseded_at,
    coalesce(v_publication.metadata, '{}'::jsonb);
end;
$$;

comment on function public.get_round_publication_status_rpc(uuid, text) is
  'Restituisce readiness e pubblicazione corrente di un round/canale per UI e Control Room.';

-- --------------------------------------------------------------------------
-- 5. Privilegi
-- --------------------------------------------------------------------------

revoke all on function public.validate_round_publication_rpc(uuid, text)
  from public, anon;
revoke all on function public.publish_round_rpc(uuid, text, jsonb, uuid)
  from public, anon, authenticated;
revoke all on function public.get_round_publication_status_rpc(uuid, text)
  from public, anon;

-- Readiness e status sono visibili ai membri autenticati della lega;
-- la funzione applica anche il controllo membership interno.
grant execute on function public.validate_round_publication_rpc(uuid, text)
  to authenticated, service_role;
grant execute on function public.get_round_publication_status_rpc(uuid, text)
  to authenticated, service_role;

-- Il comando di pubblicazione resta esclusivamente runtime/service role.
grant execute on function public.publish_round_rpc(uuid, text, jsonb, uuid)
  to service_role;

commit;
