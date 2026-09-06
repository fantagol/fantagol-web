-- FANTAGOL LIVE PRIMARY AUTHORITY FOUNDATION
--
-- Authority contract:
--   PRE-LIVE / OFFICIAL FINAL : football_data canonical pipeline
--   LIVE PRIMARY              : tuttoilcalcio
--   LIVE DEGRADED             : football_data only if primary unavailable
--
-- HARD FIREWALL:
--   This migration MUST NOT write public.matches.
--   This migration MUST NOT write public.live_match_update_receipts.
--   This migration MUST NOT write public.match_result_certifications.

create table if not exists public.live_match_observations (
  id uuid primary key default gen_random_uuid(),
  match_id uuid not null references public.matches(id) on delete cascade,
  source text not null,
  source_fixture_id text,
  observed_at timestamptz not null,
  received_at timestamptz not null default clock_timestamp(),
  source_status text not null,
  phase text not null,
  minute integer,
  home_score integer not null,
  away_score integer not null,
  terminal_hint boolean not null default false,
  payload_hash text not null,
  payload jsonb not null default '{}'::jsonb,
  correlation_id uuid,
  created_at timestamptz not null default clock_timestamp(),

  constraint live_match_observations_source_check
    check (source in ('tuttoilcalcio')),

  constraint live_match_observations_phase_check
    check (phase in (
      'PRE_MATCH',
      'FIRST_HALF',
      'HALFTIME',
      'SECOND_HALF',
      'END_PENDING'
    )),

  constraint live_match_observations_minute_check
    check (minute is null or minute between 0 and 180),

  constraint live_match_observations_score_check
    check (home_score >= 0 and away_score >= 0),

  constraint live_match_observations_identity_unique
    unique (match_id, source, observed_at, payload_hash)
);

create index if not exists live_match_observations_match_observed_idx
  on public.live_match_observations(match_id, observed_at desc, created_at desc);

create index if not exists live_match_observations_source_fixture_idx
  on public.live_match_observations(source, source_fixture_id, observed_at desc);

create table if not exists public.live_match_authority_states (
  match_id uuid primary key references public.matches(id) on delete cascade,
  authority text not null,
  source text not null,
  source_observation_id uuid references public.live_match_observations(id),
  phase text not null,
  minute integer,
  home_score integer not null,
  away_score integer not null,
  observed_at timestamptz not null,
  primary_last_seen_at timestamptz,
  degraded_since timestamptz,
  correlation_id uuid,
  version bigint not null default 1,
  updated_at timestamptz not null default clock_timestamp(),

  constraint live_match_authority_states_authority_check
    check (authority in ('primary_live', 'degraded_live')),

  constraint live_match_authority_states_source_check
    check (source in ('tuttoilcalcio', 'football_data')),

  constraint live_match_authority_states_phase_check
    check (phase in (
      'PRE_MATCH',
      'FIRST_HALF',
      'HALFTIME',
      'SECOND_HALF',
      'END_PENDING'
    )),

  constraint live_match_authority_states_minute_check
    check (minute is null or minute between 0 and 180),

  constraint live_match_authority_states_score_check
    check (home_score >= 0 and away_score >= 0)
);

create index if not exists live_match_authority_states_authority_idx
  on public.live_match_authority_states(authority, updated_at desc);

create or replace function public.live_phase_rank_internal(p_phase text)
returns integer
language sql
immutable
strict
as $$
  select case p_phase
    when 'PRE_MATCH' then 0
    when 'FIRST_HALF' then 10
    when 'HALFTIME' then 20
    when 'SECOND_HALF' then 30
    when 'END_PENDING' then 40
    else -1
  end;
$$;

create or replace function public.record_primary_live_observation_internal(
  p_match_id uuid,
  p_source_fixture_id text,
  p_observed_at timestamptz,
  p_source_status text,
  p_phase text,
  p_minute integer,
  p_home_score integer,
  p_away_score integer,
  p_terminal_hint boolean,
  p_payload_hash text,
  p_payload jsonb default '{}'::jsonb,
  p_correlation_id uuid default null
)
returns table(
  observation_id uuid,
  authority_state_version bigint,
  effective_phase text,
  effective_minute integer,
  effective_home_score integer,
  effective_away_score integer
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_observation_id uuid;
  v_current public.live_match_authority_states%rowtype;
  v_effective_phase text;
  v_effective_minute integer;
  v_next_version bigint;
begin
  if p_phase not in ('PRE_MATCH','FIRST_HALF','HALFTIME','SECOND_HALF','END_PENDING') then
    raise exception 'LIVE_PRIMARY_INVALID_PHASE:%', p_phase;
  end if;

  if p_home_score < 0 or p_away_score < 0 then
    raise exception 'LIVE_PRIMARY_INVALID_SCORE:%-%', p_home_score, p_away_score;
  end if;

  perform 1
  from public.matches m
  where m.id = p_match_id;

  if not found then
    raise exception 'LIVE_PRIMARY_MATCH_NOT_FOUND:%', p_match_id;
  end if;

  perform pg_advisory_xact_lock(hashtextextended('fantagol:live-primary:' || p_match_id::text, 0));

  insert into public.live_match_observations(
    match_id,
    source,
    source_fixture_id,
    observed_at,
    source_status,
    phase,
    minute,
    home_score,
    away_score,
    terminal_hint,
    payload_hash,
    payload,
    correlation_id
  )
  values (
    p_match_id,
    'tuttoilcalcio',
    p_source_fixture_id,
    p_observed_at,
    p_source_status,
    p_phase,
    p_minute,
    p_home_score,
    p_away_score,
    coalesce(p_terminal_hint, false),
    p_payload_hash,
    coalesce(p_payload, '{}'::jsonb),
    p_correlation_id
  )
  on conflict (match_id, source, observed_at, payload_hash)
  do update set
    received_at = excluded.received_at
  returning id into v_observation_id;

  select *
  into v_current
  from public.live_match_authority_states s
  where s.match_id = p_match_id
  for update;

  -- Phase is monotonic/protected. Score is intentionally NOT monotonic:
  -- VAR and provider corrections may move score both forward and backward.
  if found
     and public.live_phase_rank_internal(p_phase)
         < public.live_phase_rank_internal(v_current.phase) then
    v_effective_phase := v_current.phase;
    v_effective_minute := v_current.minute;
  else
    v_effective_phase := p_phase;
    v_effective_minute := p_minute;
  end if;

  v_next_version := coalesce(v_current.version, 0) + 1;

  insert into public.live_match_authority_states(
    match_id,
    authority,
    source,
    source_observation_id,
    phase,
    minute,
    home_score,
    away_score,
    observed_at,
    primary_last_seen_at,
    degraded_since,
    correlation_id,
    version,
    updated_at
  )
  values (
    p_match_id,
    'primary_live',
    'tuttoilcalcio',
    v_observation_id,
    v_effective_phase,
    v_effective_minute,
    p_home_score,
    p_away_score,
    p_observed_at,
    p_observed_at,
    null,
    p_correlation_id,
    v_next_version,
    clock_timestamp()
  )
  on conflict (match_id)
  do update set
    authority = excluded.authority,
    source = excluded.source,
    source_observation_id = excluded.source_observation_id,
    phase = excluded.phase,
    minute = excluded.minute,
    home_score = excluded.home_score,
    away_score = excluded.away_score,
    observed_at = excluded.observed_at,
    primary_last_seen_at = excluded.primary_last_seen_at,
    degraded_since = null,
    correlation_id = excluded.correlation_id,
    version = excluded.version,
    updated_at = excluded.updated_at;

  return query
  select
    v_observation_id,
    v_next_version,
    v_effective_phase,
    v_effective_minute,
    p_home_score,
    p_away_score;
end;
$$;

create or replace function public.activate_football_data_degraded_live_internal(
  p_match_id uuid,
  p_correlation_id uuid default null
)
returns public.live_match_authority_states
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_match public.matches%rowtype;
  v_existing public.live_match_authority_states%rowtype;
  v_phase text;
  v_version bigint;
  v_result public.live_match_authority_states%rowtype;
begin
  perform pg_advisory_xact_lock(hashtextextended('fantagol:live-primary:' || p_match_id::text, 0));

  select *
  into v_match
  from public.matches m
  where m.id = p_match_id;

  if not found then
    raise exception 'LIVE_DEGRADED_MATCH_NOT_FOUND:%', p_match_id;
  end if;

  select *
  into v_existing
  from public.live_match_authority_states s
  where s.match_id = p_match_id
  for update;

  v_phase := case
    when v_match.status in ('halftime','paused') then 'HALFTIME'
    when v_match.status in ('live_second_half') then 'SECOND_HALF'
    when v_match.status in ('live','in_play','live_first_half') then
      case
        when found and public.live_phase_rank_internal(v_existing.phase) >= 30
          then v_existing.phase
        else 'FIRST_HALF'
      end
    else coalesce(v_existing.phase, 'PRE_MATCH')
  end;

  v_version := coalesce(v_existing.version, 0) + 1;

  insert into public.live_match_authority_states(
    match_id,
    authority,
    source,
    source_observation_id,
    phase,
    minute,
    home_score,
    away_score,
    observed_at,
    primary_last_seen_at,
    degraded_since,
    correlation_id,
    version,
    updated_at
  )
  values (
    p_match_id,
    'degraded_live',
    'football_data',
    null,
    v_phase,
    coalesce(v_match.minute, v_existing.minute),
    coalesce(v_match.home_score, v_existing.home_score, 0),
    coalesce(v_match.away_score, v_existing.away_score, 0),
    coalesce(v_match.provider_updated_at, clock_timestamp()),
    v_existing.primary_last_seen_at,
    coalesce(v_existing.degraded_since, clock_timestamp()),
    p_correlation_id,
    v_version,
    clock_timestamp()
  )
  on conflict (match_id)
  do update set
    authority = excluded.authority,
    source = excluded.source,
    source_observation_id = null,
    phase = excluded.phase,
    minute = excluded.minute,
    home_score = excluded.home_score,
    away_score = excluded.away_score,
    observed_at = excluded.observed_at,
    degraded_since = excluded.degraded_since,
    correlation_id = excluded.correlation_id,
    version = excluded.version,
    updated_at = excluded.updated_at
  returning * into v_result;

  return v_result;
end;
$$;

create or replace function public.resolve_live_match_runtime_state_internal(
  p_match_id uuid
)
returns table(
  match_id uuid,
  authority text,
  source text,
  source_observation_id uuid,
  phase text,
  minute integer,
  home_score integer,
  away_score integer,
  observed_at timestamptz,
  version bigint
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select
    s.match_id,
    s.authority,
    s.source,
    s.source_observation_id,
    s.phase,
    s.minute,
    s.home_score,
    s.away_score,
    s.observed_at,
    s.version
  from public.live_match_authority_states s
  where s.match_id = p_match_id;
$$;

alter table public.live_match_observations enable row level security;
alter table public.live_match_authority_states enable row level security;

revoke all on public.live_match_observations from anon, authenticated;
revoke all on public.live_match_authority_states from anon, authenticated;

revoke all on function public.record_primary_live_observation_internal(
  uuid,text,timestamptz,text,text,integer,integer,integer,boolean,text,jsonb,uuid
) from public, anon, authenticated;

revoke all on function public.activate_football_data_degraded_live_internal(uuid,uuid)
  from public, anon, authenticated;

revoke all on function public.resolve_live_match_runtime_state_internal(uuid)
  from public, anon, authenticated;

grant select, insert on public.live_match_observations to service_role;
grant select, insert, update on public.live_match_authority_states to service_role;

grant execute on function public.record_primary_live_observation_internal(
  uuid,text,timestamptz,text,text,integer,integer,integer,boolean,text,jsonb,uuid
) to service_role;

grant execute on function public.activate_football_data_degraded_live_internal(uuid,uuid)
  to service_role;

grant execute on function public.resolve_live_match_runtime_state_internal(uuid)
  to service_role;

comment on table public.live_match_observations is
  'Append-only provider-agnostic LIVE observation evidence. Never official result certification evidence.';

comment on table public.live_match_authority_states is
  'Current provisional LIVE authority projection. Separate from canonical public.matches.';

comment on function public.record_primary_live_observation_internal(
  uuid,text,timestamptz,text,text,integer,integer,integer,boolean,text,jsonb,uuid
) is
  'Records Tuttoilcalcio primary LIVE observation. Phase protected, score VAR-reversible. Does not mutate canonical match state.';

comment on function public.activate_football_data_degraded_live_internal(uuid,uuid) is
  'Emergency degraded LIVE projection from Football-Data canonical state. Does not alter official evidence.';

comment on function public.resolve_live_match_runtime_state_internal(uuid) is
  'Returns current provisional LIVE authority state for scoring/display pipeline.';
