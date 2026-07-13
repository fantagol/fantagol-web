-- ============================================================
-- FANTAGOL — MIGRATION 019
-- Prediction Command Engine — Submit Round Predictions
-- ============================================================
-- Scope:
--   1. Submit the authenticated member's complete prediction set.
--   2. Validate membership, lifecycle, time window and completeness.
--   3. Move all draft predictions to submitted atomically.
--   4. Persist immutable prediction_versions rows for changed records.
--   5. Keep retries idempotent when the round is already submitted.
-- ============================================================

begin;

create or replace function public.submit_round_predictions_rpc(
  p_league_round_id uuid
)
returns table (
  league_round_id uuid,
  league_member_id uuid,
  required_prediction_count integer,
  submitted_prediction_count integer,
  already_submitted boolean,
  submitted_at timestamptz
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
  v_required_count integer;
  v_prediction_count integer;
  v_invalid_count integer;
  v_draft_count integer;
  v_submitted_count integer;
  v_existing_submitted_at timestamptz;
  v_now timestamptz := clock_timestamp();
begin
  v_user_id := auth.uid();

  if v_user_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'AUTHENTICATION_REQUIRED';
  end if;

  if p_league_round_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_ROUND_REQUIRED';
  end if;

  -- Lock the lifecycle row so submit cannot race with round lock.
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

  -- Serialize all submissions for the same member and round.
  perform pg_advisory_xact_lock(
    hashtextextended(
      'submit:' || p_league_round_id::text || ':' || v_member_id::text,
      0
    )
  );

  select count(*)::integer
  into v_required_count
  from public.fantagol_round_matches frm
  where frm.fantagol_round_id = v_fantagol_round_id
    and frm.removed_at is null
    and frm.required;

  if v_required_count <= 0 then
    raise exception using
      errcode = 'P0001',
      message = 'ROUND_MATCH_SET_EMPTY';
  end if;

  -- Lock all current predictions for this member and round.
  perform 1
  from public.predictions p
  where p.league_round_id = p_league_round_id
    and p.league_member_id = v_member_id
  for update;

  select
    count(*) filter (
      where frm.match_id is not null
        and p.status in ('draft', 'submitted')
    )::integer,
    count(*) filter (
      where frm.match_id is null
         or p.status not in ('draft', 'submitted')
    )::integer,
    count(*) filter (where p.status = 'draft')::integer,
    count(*) filter (where p.status = 'submitted')::integer,
    min(p.submitted_at) filter (where p.status = 'submitted')
  into
    v_prediction_count,
    v_invalid_count,
    v_draft_count,
    v_submitted_count,
    v_existing_submitted_at
  from public.predictions p
  left join public.fantagol_round_matches frm
    on frm.fantagol_round_id = v_fantagol_round_id
   and frm.match_id = p.match_id
   and frm.removed_at is null
   and frm.required
  where p.league_round_id = p_league_round_id
    and p.league_member_id = v_member_id;

  if v_invalid_count > 0 then
    raise exception using
      errcode = 'P0001',
      message = 'ROUND_PREDICTION_SET_INVALID';
  end if;

  if v_prediction_count <> v_required_count then
    raise exception using
      errcode = 'P0001',
      message = 'ROUND_PREDICTIONS_INCOMPLETE',
      detail = format(
        'required=%s present=%s missing=%s',
        v_required_count,
        v_prediction_count,
        greatest(v_required_count - v_prediction_count, 0)
      );
  end if;

  -- Idempotent retry: all required predictions are already submitted.
  if v_draft_count = 0 and v_submitted_count = v_required_count then
    return query
    select
      p_league_round_id,
      v_member_id,
      v_required_count,
      v_submitted_count,
      true,
      v_existing_submitted_at;
    return;
  end if;

  -- Change only draft rows. Already-submitted rows remain untouched.
  with changed as (
    update public.predictions p
    set
      status = 'submitted',
      submitted_at = coalesce(p.submitted_at, v_now),
      updated_at = v_now,
      version = p.version + 1
    where p.league_round_id = p_league_round_id
      and p.league_member_id = v_member_id
      and p.status = 'draft'
    returning p.*
  )
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
  select
    c.id,
    c.version,
    c.home_prediction,
    c.away_prediction,
    c.status,
    c.source,
    v_user_id,
    v_member_id,
    v_now,
    jsonb_build_object(
      'command', 'SubmitRoundPredictions',
      'reason', 'submit',
      'operation', 'status_transition',
      'league_id', v_league_id,
      'league_round_id', p_league_round_id,
      'match_id', c.match_id,
      'new_status', 'submitted'
    )
  from changed c;

  select count(*)::integer, min(p.submitted_at)
  into v_submitted_count, v_existing_submitted_at
  from public.predictions p
  where p.league_round_id = p_league_round_id
    and p.league_member_id = v_member_id
    and p.status = 'submitted';

  if v_submitted_count <> v_required_count then
    raise exception using
      errcode = 'P0001',
      message = 'ROUND_SUBMISSION_INVARIANT_FAILED';
  end if;

  return query
  select
    p_league_round_id,
    v_member_id,
    v_required_count,
    v_submitted_count,
    false,
    v_existing_submitted_at;
end;
$function$;

comment on function public.submit_round_predictions_rpc(uuid)
is 'Atomically validates and submits the authenticated member complete prediction set for one League Round, with immutable version history and idempotent retries.';

revoke all on function public.submit_round_predictions_rpc(uuid) from public;
grant execute on function public.submit_round_predictions_rpc(uuid) to authenticated;

commit;
