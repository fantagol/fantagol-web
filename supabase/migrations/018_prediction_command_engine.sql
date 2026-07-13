-- ============================================================
-- FANTAGOL — MIGRATION 018
-- Prediction Command Engine — Save Prediction Draft
-- ============================================================
-- Scope:
--   1. Create the first transactional Prediction Engine command.
--   2. Validate authentication, membership, round lifecycle and match set.
--   3. Insert or update one prediction draft.
--   4. Persist an immutable prediction_versions row atomically.
--
-- This migration intentionally does not add new tables or triggers.
-- Version history is written by controlled command RPCs.
-- ============================================================

begin;

create or replace function public.save_prediction_draft_rpc(
  p_league_round_id uuid,
  p_match_id uuid,
  p_home_prediction integer,
  p_away_prediction integer
)
returns table (
  prediction_id uuid,
  league_round_id uuid,
  league_member_id uuid,
  match_id uuid,
  home_prediction integer,
  away_prediction integer,
  prediction_status text,
  prediction_version integer,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path to public, pg_temp
as $function$
declare
  v_user_id uuid;
  v_league_id uuid;
  v_fantagol_round_id uuid;
  v_league_round_status text;
  v_league_round_enabled boolean;
  v_round_opens_at timestamptz;
  v_round_lock_at timestamptz;
  v_member_id uuid;
  v_prediction public.predictions%rowtype;
  v_now timestamptz := clock_timestamp();
begin
  -- ----------------------------------------------------------
  -- Authentication and input validation
  -- ----------------------------------------------------------
  v_user_id := auth.uid();

  if v_user_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'AUTHENTICATION_REQUIRED';
  end if;

  if p_league_round_id is null or p_match_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'PREDICTION_TARGET_REQUIRED';
  end if;

  if p_home_prediction is null or p_away_prediction is null
     or p_home_prediction < 0 or p_home_prediction > 9
     or p_away_prediction < 0 or p_away_prediction > 9 then
    raise exception using
      errcode = 'P0001',
      message = 'PREDICTION_SCORE_INVALID';
  end if;

  -- ----------------------------------------------------------
  -- Resolve and lock the League Round lifecycle row
  -- ----------------------------------------------------------
  select
    lr.league_id,
    lr.fantagol_round_id,
    lr.status,
    lr.enabled,
    fr.opens_at,
    fr.lock_at
  into
    v_league_id,
    v_fantagol_round_id,
    v_league_round_status,
    v_league_round_enabled,
    v_round_opens_at,
    v_round_lock_at
  from public.league_rounds lr
  join public.fantagol_rounds fr
    on fr.id = lr.fantagol_round_id
  where lr.id = p_league_round_id
  for update of lr;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_ROUND_NOT_FOUND';
  end if;

  if not v_league_round_enabled then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_ROUND_DISABLED';
  end if;

  if v_league_round_status <> 'predictions_open' then
    raise exception using
      errcode = 'P0001',
      message = 'PREDICTION_WINDOW_NOT_OPEN';
  end if;

  if v_now < v_round_opens_at then
    raise exception using
      errcode = 'P0001',
      message = 'PREDICTION_WINDOW_NOT_OPEN';
  end if;

  if v_now >= v_round_lock_at then
    raise exception using
      errcode = 'P0001',
      message = 'PREDICTION_WINDOW_CLOSED';
  end if;

  -- ----------------------------------------------------------
  -- Resolve active membership from auth.uid(); never trust a
  -- member id supplied by the client.
  -- ----------------------------------------------------------
  select lm.id
  into v_member_id
  from public.league_members lm
  where lm.league_id = v_league_id
    and lm.user_id = v_user_id
    and lm.status = 'active'
  limit 1;

  if v_member_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'ACTIVE_LEAGUE_MEMBERSHIP_REQUIRED';
  end if;

  -- ----------------------------------------------------------
  -- The match must belong to the official active Match Set of
  -- the FantaGol Round connected to this League Round.
  -- ----------------------------------------------------------
  if not exists (
    select 1
    from public.fantagol_round_matches frm
    where frm.fantagol_round_id = v_fantagol_round_id
      and frm.match_id = p_match_id
      and frm.removed_at is null
  ) then
    raise exception using
      errcode = 'P0001',
      message = 'MATCH_NOT_IN_LEAGUE_ROUND';
  end if;

  -- Serialize writes for the same member/round/match, including
  -- the first insert where no row exists yet.
  perform pg_advisory_xact_lock(
    hashtextextended(
      p_league_round_id::text || ':' || v_member_id::text || ':' || p_match_id::text,
      0
    )
  );

  select p.*
  into v_prediction
  from public.predictions p
  where p.league_round_id = p_league_round_id
    and p.league_member_id = v_member_id
    and p.match_id = p_match_id
  for update;

  if found then
    if v_prediction.status in ('locked', 'void') then
      raise exception using
        errcode = 'P0001',
        message = 'PREDICTION_NOT_EDITABLE';
    end if;

    -- Idempotent retry: equal values produce no new version.
    if v_prediction.home_prediction = p_home_prediction
       and v_prediction.away_prediction = p_away_prediction then
      return query
      select
        v_prediction.id,
        v_prediction.league_round_id,
        v_prediction.league_member_id,
        v_prediction.match_id,
        v_prediction.home_prediction,
        v_prediction.away_prediction,
        v_prediction.status,
        v_prediction.version,
        v_prediction.updated_at;
      return;
    end if;

    update public.predictions p
    set
      home_prediction = p_home_prediction,
      away_prediction = p_away_prediction,
      updated_at = v_now,
      version = p.version + 1
    where p.id = v_prediction.id
    returning p.* into v_prediction;
  else
    insert into public.predictions (
      league_id,
      user_id,
      match_id,
      home_prediction,
      away_prediction,
      league_round_id,
      league_member_id,
      status,
      submitted_at,
      locked_at,
      source,
      version,
      created_at,
      updated_at
    )
    values (
      v_league_id,
      v_user_id,
      p_match_id,
      p_home_prediction,
      p_away_prediction,
      p_league_round_id,
      v_member_id,
      'draft',
      null,
      null,
      'standard',
      1,
      v_now,
      v_now
    )
    returning * into v_prediction;
  end if;

  -- Immutable history row written in the same transaction.
  insert into public.prediction_versions (
    prediction_id,
    version,
    home_prediction,
    away_prediction,
    status,
    source,
    changed_by_user_id,
    changed_by_member_id,
    changed_at,
    metadata
  )
  values (
    v_prediction.id,
    v_prediction.version,
    v_prediction.home_prediction,
    v_prediction.away_prediction,
    v_prediction.status,
    v_prediction.source,
    v_user_id,
    v_member_id,
    v_now,
    jsonb_build_object(
      'command', 'SavePredictionDraft',
      'reason', 'draft_save',
      'league_id', v_league_id,
      'league_round_id', p_league_round_id,
      'match_id', p_match_id
    )
  );

  return query
  select
    v_prediction.id,
    v_prediction.league_round_id,
    v_prediction.league_member_id,
    v_prediction.match_id,
    v_prediction.home_prediction,
    v_prediction.away_prediction,
    v_prediction.status,
    v_prediction.version,
    v_prediction.updated_at;
end;
$function$;

comment on function public.save_prediction_draft_rpc(uuid, uuid, integer, integer)
is 'Atomically inserts or updates one prediction before round lock and persists its immutable version history.';

revoke all on function public.save_prediction_draft_rpc(uuid, uuid, integer, integer) from public;
grant execute on function public.save_prediction_draft_rpc(uuid, uuid, integer, integer) to authenticated;

commit;
