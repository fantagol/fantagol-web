-- FANTAGOL MIGRATION 306
-- Tuttoilcalcio primary-LIVE temporal state machine.
--
-- R36/R37 authority:
-- - top-level minute is a display anchor, not phase authority;
-- - first-half stoppage may report 46..49 while event stream is still active;
-- - HT is inferred only after TWO consecutive frozen event-stream transitions
--   after regulation threshold, preventing one quiet minute from becoming HT;
-- - minute NULL never regresses an accepted phase;
-- - HALFTIME exits only when event activity resumes;
-- - match_ended / terminal source is END_PENDING and absorbing;
-- - score remains non-monotonic to allow VAR/provider corrections;
-- - minute-only changes never fan out simulations/publications.
--
-- Football-Data remains FINAL/certification authority.

create or replace function public.classify_tutto_primary_temporal_state_internal(
  p_current_phase text,
  p_current_minute integer,
  p_source_phase text,
  p_source_minute integer,
  p_terminal_hint boolean,
  p_has_match_ended boolean,
  p_event_count integer,
  p_max_event_id bigint,
  p_prev_event_count integer,
  p_prev_max_event_id bigint,
  p_prev2_event_count integer,
  p_prev2_max_event_id bigint
)
returns table(
  effective_phase text,
  effective_minute integer
)
language plpgsql
immutable
security invoker
set search_path = public, pg_temp
as $function$
declare
  v_current_phase text := coalesce(p_current_phase, 'PRE_MATCH');
  v_events_advanced boolean;
  v_prev_events_advanced boolean;
  v_after_regulation boolean;
begin
  if p_source_phase not in ('PRE_MATCH','FIRST_HALF','HALFTIME','SECOND_HALF','END_PENDING') then
    raise exception 'LIVE_PRIMARY_INVALID_PHASE:%', p_source_phase;
  end if;

  -- Terminal authority is monotonic and absorbing.
  if v_current_phase = 'END_PENDING'
     or coalesce(p_terminal_hint, false)
     or coalesce(p_has_match_ended, false)
     or p_source_phase = 'END_PENDING' then
    effective_phase := 'END_PENDING';
    effective_minute := coalesce(p_current_minute, p_source_minute);
    return next;
    return;
  end if;

  v_events_advanced :=
    p_prev_event_count is null
    or p_event_count > p_prev_event_count
    or (
      p_max_event_id is not null
      and p_prev_max_event_id is not null
      and p_max_event_id > p_prev_max_event_id
    );

  v_prev_events_advanced :=
    p_prev2_event_count is null
    or p_prev_event_count > p_prev2_event_count
    or (
      p_prev_max_event_id is not null
      and p_prev2_max_event_id is not null
      and p_prev_max_event_id > p_prev2_max_event_id
    );

  v_after_regulation :=
    greatest(
      coalesce(p_current_minute, 0),
      coalesce(p_source_minute, 0)
    ) >= 46;

  -- Explicit provider HT remains admissible if Tutto ever starts emitting it.
  if p_source_phase = 'HALFTIME' then
    effective_phase := 'HALFTIME';
    effective_minute := coalesce(p_current_minute, p_source_minute);
    return next;
    return;
  end if;

  -- Once SECOND_HALF is accepted, NULL or stale minute cannot regress phase.
  if v_current_phase = 'SECOND_HALF' then
    effective_phase := 'SECOND_HALF';
    effective_minute :=
      case
        when p_source_minute is null then p_current_minute
        when p_current_minute is null then p_source_minute
        else greatest(p_current_minute, p_source_minute)
      end;
    return next;
    return;
  end if;

  -- During HT, a minute value alone is not enough to resume play.
  -- Event activity must actually restart.
  if v_current_phase = 'HALFTIME' then
    if v_events_advanced and coalesce(p_source_minute, 0) >= 46 then
      effective_phase := 'SECOND_HALF';
      effective_minute := p_source_minute;
    else
      effective_phase := 'HALFTIME';
      effective_minute := p_current_minute;
    end if;
    return next;
    return;
  end if;

  if p_source_phase = 'PRE_MATCH' and v_current_phase = 'PRE_MATCH' then
    effective_phase := 'PRE_MATCH';
    effective_minute := null;
    return next;
    return;
  end if;

  -- FIRST HALF:
  -- Active events keep FIRST_HALF authoritative even when Tutto's top-level
  -- minute has already crossed 45 and is effectively wall-clock-like.
  --
  -- HT requires two consecutive frozen event transitions:
  --   current vs previous frozen
  --   previous vs previous-2 frozen
  -- after regulation threshold.
  if v_after_regulation
     and p_prev_event_count is not null
     and p_prev2_event_count is not null
     and not v_events_advanced
     and not v_prev_events_advanced then
    effective_phase := 'HALFTIME';
    effective_minute := p_current_minute;
    return next;
    return;
  end if;

  effective_phase := 'FIRST_HALF';

  -- First frozen candidate is not yet HT. Do not let a spuriously advancing
  -- provider minute move the visible anchor while the event stream is frozen.
  if v_after_regulation
     and p_prev_event_count is not null
     and not v_events_advanced then
    effective_minute := coalesce(p_current_minute, p_source_minute);
  elsif p_source_minute is null then
    effective_minute := p_current_minute;
  else
    effective_minute := p_source_minute;
  end if;

  return next;
end;
$function$;

revoke all on function public.classify_tutto_primary_temporal_state_internal(
  text, integer, text, integer, boolean, boolean,
  integer, bigint, integer, bigint, integer, bigint
) from public, anon, authenticated;

grant execute on function public.classify_tutto_primary_temporal_state_internal(
  text, integer, text, integer, boolean, boolean,
  integer, bigint, integer, bigint, integer, bigint
) to service_role;


create or replace function public.record_primary_live_observation_v3_internal(
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
  effective_away_score integer,
  changed_fields text[]
)
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_observation_id uuid;
  v_current public.live_match_authority_states%rowtype;
  v_had_current boolean := false;
  v_effective_phase text;
  v_effective_minute integer;
  v_next_version bigint;
  v_changed_fields text[] := array[]::text[];

  v_event_count integer := 0;
  v_max_event_id bigint;
  v_prev_event_count integer;
  v_prev_max_event_id bigint;
  v_prev2_event_count integer;
  v_prev2_max_event_id bigint;
  v_has_match_ended boolean := false;
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

  select *
  into v_current
  from public.live_match_authority_states s
  where s.match_id = p_match_id
  for update;

  v_had_current := found;

  if jsonb_typeof(coalesce(p_payload->'events', '[]'::jsonb)) = 'array' then
    v_event_count := jsonb_array_length(coalesce(p_payload->'events', '[]'::jsonb));

    select max(
      case
        when (e.value->>'id') ~ '^[0-9]+$'
          then (e.value->>'id')::bigint
        else null
      end
    )
    into v_max_event_id
    from jsonb_array_elements(coalesce(p_payload->'events', '[]'::jsonb)) e(value);

    select exists (
      select 1
      from jsonb_array_elements(coalesce(p_payload->'events', '[]'::jsonb)) e(value)
      where lower(coalesce(e.value->>'type','')) = 'match_ended'
    )
    into v_has_match_ended;
  end if;

  -- Read the two preceding immutable Tutto observations under the same lock.
  with prev as (
    select
      o.payload,
      row_number() over (
        order by o.observed_at desc, o.created_at desc, o.id desc
      ) as rn
    from public.live_match_observations o
    where o.match_id = p_match_id
      and o.source = 'tuttoilcalcio'
      and not (
        o.observed_at = p_observed_at
        and o.payload_hash = p_payload_hash
      )
      and o.observed_at <= p_observed_at
    order by o.observed_at desc, o.created_at desc, o.id desc
    limit 2
  ),
  stats as (
    select
      rn,
      case
        when jsonb_typeof(coalesce(payload->'events','[]'::jsonb)) = 'array'
          then jsonb_array_length(coalesce(payload->'events','[]'::jsonb))
        else 0
      end as event_count,
      (
        select max(
          case
            when (e.value->>'id') ~ '^[0-9]+$'
              then (e.value->>'id')::bigint
            else null
          end
        )
        from jsonb_array_elements(
          case
            when jsonb_typeof(coalesce(payload->'events','[]'::jsonb)) = 'array'
              then coalesce(payload->'events','[]'::jsonb)
            else '[]'::jsonb
          end
        ) e(value)
      ) as max_event_id
    from prev
  )
  select
    max(event_count) filter (where rn = 1),
    max(max_event_id) filter (where rn = 1),
    max(event_count) filter (where rn = 2),
    max(max_event_id) filter (where rn = 2)
  into
    v_prev_event_count,
    v_prev_max_event_id,
    v_prev2_event_count,
    v_prev2_max_event_id
  from stats;

  select c.effective_phase, c.effective_minute
  into v_effective_phase, v_effective_minute
  from public.classify_tutto_primary_temporal_state_internal(
    case when v_had_current then v_current.phase else null end,
    case when v_had_current then v_current.minute else null end,
    p_phase,
    p_minute,
    coalesce(p_terminal_hint, false),
    v_has_match_ended,
    v_event_count,
    v_max_event_id,
    v_prev_event_count,
    v_prev_max_event_id,
    v_prev2_event_count,
    v_prev2_max_event_id
  ) c;

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
    coalesce(p_terminal_hint, false) or v_has_match_ended,
    p_payload_hash,
    coalesce(p_payload, '{}'::jsonb),
    p_correlation_id
  )
  on conflict (match_id, source, observed_at, payload_hash)
  do update set
    received_at = excluded.received_at
  returning id into v_observation_id;

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

revoke all on function public.record_primary_live_observation_v3_internal(
  uuid, text, timestamptz, text, text, integer, integer, integer,
  boolean, text, jsonb, uuid
) from public, anon, authenticated;

grant execute on function public.record_primary_live_observation_v3_internal(
  uuid, text, timestamptz, text, text, integer, integer, integer,
  boolean, text, jsonb, uuid
) to service_role;

comment on function public.record_primary_live_observation_v3_internal(
  uuid, text, timestamptz, text, text, integer, integer, integer,
  boolean, text, jsonb, uuid
) is
'R114-R5 M306: atomic Tutto primary-LIVE temporal authority. HT from confirmed event-stream freeze; restart from renewed event activity; END_PENDING absorbing; minute-only changes do not fan out.';
