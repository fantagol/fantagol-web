-- ============================================================================
-- FANTAGOL MIGRATION 305
-- PRIMARY LIVE ATOMIC CHANGE CLASSIFICATION
-- R114-R5
--
-- Purpose:
--   Move Tuttoilcalcio meaningful-change classification into the same
--   serialized database transaction that records the primary-live authority.
--
-- Guarantees:
--   * classification occurs under the existing per-match advisory xact lock;
--   * phase monotonicity is preserved;
--   * score corrections remain non-monotonic by design;
--   * minute-only changes do not trigger meaningful fanout;
--   * equivalent concurrent observations see the already-updated authority
--     after waiting on the advisory lock and therefore return no changed_fields;
--   * official Football-Data final/certification authority is untouched.
--
-- Security contract copied from record_primary_live_observation_internal:
--   SECURITY DEFINER
--   search_path = public, pg_temp
--   EXECUTE: postgres + service_role only
-- ============================================================================

create or replace function public.record_primary_live_observation_v2_internal(
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
  p_correlation_id uuid default null::uuid
)
returns table(
  observation_id uuid,
  authority_state_version bigint,
  effective_phase text,
  effective_minute integer,
  effective_home_score integer,
  effective_away_score integer,
  changed_fields text[]
)
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_observation_id uuid;
  v_current public.live_match_authority_states%rowtype;
  v_had_current boolean := false;
  v_effective_phase text;
  v_effective_minute integer;
  v_next_version bigint;
  v_changed_fields text[] := array[]::text[];
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

  perform pg_advisory_xact_lock(
    hashtextextended('fantagol:live-primary:' || p_match_id::text, 0)
  );

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

  v_had_current := found;

  -- Phase is monotonic/protected. Score is intentionally NOT monotonic:
  -- VAR and provider corrections may move score both forward and backward.
  if v_had_current
     and public.live_phase_rank_internal(p_phase)
         < public.live_phase_rank_internal(v_current.phase) then
    v_effective_phase := v_current.phase;
    v_effective_minute := v_current.minute;
  else
    v_effective_phase := p_phase;
    v_effective_minute := p_minute;
  end if;

  -- Meaningful LIVE fanout classification is atomic with authority mutation.
  -- Minute is deliberately excluded: minute-only observations update authority
  -- but do not rebuild simulations/publications.
  if not v_had_current
     or v_current.authority is distinct from 'primary_live'
     or v_current.source is distinct from 'tuttoilcalcio' then
    v_changed_fields := array_append(v_changed_fields, 'authority');
  end if;

  if not v_had_current
     or v_current.phase is distinct from v_effective_phase then
    v_changed_fields := array_append(v_changed_fields, 'phase');
  end if;

  if not v_had_current
     or v_current.home_score is distinct from p_home_score then
    v_changed_fields := array_append(v_changed_fields, 'home_score');
  end if;

  if not v_had_current
     or v_current.away_score is distinct from p_away_score then
    v_changed_fields := array_append(v_changed_fields, 'away_score');
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
    p_away_score,
    v_changed_fields;
end;
$function$;

alter function public.record_primary_live_observation_v2_internal(
  uuid,text,timestamptz,text,text,integer,integer,integer,boolean,text,jsonb,uuid
) owner to postgres;

revoke all on function public.record_primary_live_observation_v2_internal(
  uuid,text,timestamptz,text,text,integer,integer,integer,boolean,text,jsonb,uuid
) from public;

revoke all on function public.record_primary_live_observation_v2_internal(
  uuid,text,timestamptz,text,text,integer,integer,integer,boolean,text,jsonb,uuid
) from anon;

revoke all on function public.record_primary_live_observation_v2_internal(
  uuid,text,timestamptz,text,text,integer,integer,integer,boolean,text,jsonb,uuid
) from authenticated;

grant execute on function public.record_primary_live_observation_v2_internal(
  uuid,text,timestamptz,text,text,integer,integer,integer,boolean,text,jsonb,uuid
) to service_role;
