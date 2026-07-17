-- FANTAGOL LIVE RUNTIME
-- Migration 052: canonical Match refresh engine

create or replace function public.refresh_live_match_state_rpc(
  p_match_id uuid,
  p_normalized_update jsonb
)
returns table (
  match_id uuid,
  applied boolean,
  stale boolean,
  previous_version integer,
  current_version integer,
  provider_updated_at timestamptz,
  match_status text,
  home_score integer,
  away_score integer,
  minute integer,
  period text
)
language plpgsql
security definer
set search_path to public, pg_temp
as $function$
declare
  v_match public.matches%rowtype;
  v_provider_updated_at timestamptz;
  v_kickoff timestamptz;
  v_status text;
  v_home_score integer;
  v_away_score integer;
  v_minute integer;
  v_period text;
  v_previous_version integer;
begin
  if p_match_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'LIVE_REFRESH_MATCH_ID_REQUIRED';
  end if;

  if p_normalized_update is null
     or jsonb_typeof(p_normalized_update) <> 'object' then
    raise exception using
      errcode = 'P0001',
      message = 'LIVE_REFRESH_NORMALIZED_UPDATE_REQUIRED';
  end if;

  begin
    v_provider_updated_at :=
      nullif(p_normalized_update ->> 'provider_updated_at', '')::timestamptz;
    v_kickoff :=
      nullif(p_normalized_update ->> 'kickoff_at', '')::timestamptz;
    v_status :=
      nullif(btrim(p_normalized_update ->> 'status'), '');
    v_home_score :=
      nullif(p_normalized_update ->> 'home_score', '')::integer;
    v_away_score :=
      nullif(p_normalized_update ->> 'away_score', '')::integer;
    v_minute :=
      nullif(p_normalized_update ->> 'minute', '')::integer;
    v_period :=
      nullif(btrim(p_normalized_update ->> 'period'), '');
  exception
    when invalid_text_representation or datetime_field_overflow then
      raise exception using
        errcode = 'P0001',
        message = 'LIVE_REFRESH_INVALID_NORMALIZED_UPDATE';
  end;

  if v_provider_updated_at is null then
    raise exception using
      errcode = 'P0001',
      message = 'LIVE_REFRESH_PROVIDER_UPDATED_AT_REQUIRED';
  end if;

  if v_status is null then
    raise exception using
      errcode = 'P0001',
      message = 'LIVE_REFRESH_STATUS_REQUIRED';
  end if;

  if (v_home_score is null) <> (v_away_score is null) then
    raise exception using
      errcode = 'P0001',
      message = 'LIVE_REFRESH_SCORE_PAIR_INVALID';
  end if;

  select m.*
  into v_match
  from public.matches m
  where m.id = p_match_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'LIVE_REFRESH_MATCH_NOT_FOUND';
  end if;

  v_previous_version := coalesce(v_match.version, 0);

  if v_match.provider_updated_at is not null
     and v_provider_updated_at < v_match.provider_updated_at then
    return query
    select
      v_match.id,
      false,
      true,
      v_previous_version,
      v_previous_version,
      v_match.provider_updated_at,
      v_match.status,
      v_match.home_score,
      v_match.away_score,
      v_match.minute,
      v_match.period;
    return;
  end if;

  -- Worker retries must not create artificial Match versions.
  if v_provider_updated_at is not distinct from v_match.provider_updated_at
     and coalesce(v_kickoff, v_match.kickoff) is not distinct from v_match.kickoff
     and v_status is not distinct from v_match.status
     and v_home_score is not distinct from v_match.home_score
     and v_away_score is not distinct from v_match.away_score
     and v_minute is not distinct from v_match.minute
     and v_period is not distinct from v_match.period then
    return query
    select
      v_match.id,
      false,
      false,
      v_previous_version,
      v_previous_version,
      v_match.provider_updated_at,
      v_match.status,
      v_match.home_score,
      v_match.away_score,
      v_match.minute,
      v_match.period;
    return;
  end if;

  update public.matches m
  set
    kickoff = coalesce(v_kickoff, m.kickoff),
    status = v_status,
    home_score = v_home_score,
    away_score = v_away_score,
    minute = v_minute,
    period = v_period,
    provider_updated_at = v_provider_updated_at,
    finalised_at = case
      when v_status in ('finished', 'awarded')
        then coalesce(m.finalised_at, v_provider_updated_at, clock_timestamp())
      else null
    end
  where m.id = p_match_id
  returning m.*
  into v_match;

  -- updated_at and version are maintained by the existing Match triggers.
  return query
  select
    v_match.id,
    true,
    false,
    v_previous_version,
    coalesce(v_match.version, 0),
    v_match.provider_updated_at,
    v_match.status,
    v_match.home_score,
    v_match.away_score,
    v_match.minute,
    v_match.period;
end;
$function$;

revoke all on function public.refresh_live_match_state_rpc(uuid, jsonb)
from public;

revoke all on function public.refresh_live_match_state_rpc(uuid, jsonb)
from anon;

revoke all on function public.refresh_live_match_state_rpc(uuid, jsonb)
from authenticated;

grant execute on function public.refresh_live_match_state_rpc(uuid, jsonb)
to service_role;

comment on function public.refresh_live_match_state_rpc(uuid, jsonb) is
'Atomically applies one normalized provider update to canonical Match state, preserves finalisation semantics, rejects stale events and remains idempotent across worker retries. Match version and updated_at are maintained by existing triggers. Service-role only.';
