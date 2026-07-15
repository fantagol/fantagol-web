-- Migration 030: Strategy Draft Command Engine
-- Purpose:
--   - add the first user-facing Strategy command;
--   - resolve the authenticated member's fixture from the active schedule;
--   - create or update the private Strategy workspace;
--   - append one immutable strategy_versions row for every successful save;
--   - preserve any previously submitted official snapshot until explicit resubmission.
--
-- Mode-specific payload completeness is intentionally NOT validated here.
-- Draft payloads may be partial while the user builds the Strategy workspace.

begin;

create or replace function public.save_strategy_draft_rpc(
  p_league_round_id uuid,
  p_mode text,
  p_payload jsonb
)
returns table (
  strategy_id uuid,
  league_fixture_id uuid,
  mode text,
  workspace_version integer,
  strategy_status text,
  submitted_version integer,
  has_unconfirmed_changes boolean,
  saved_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_now timestamptz := now();

  v_user_id uuid := auth.uid();
  v_league_id uuid;
  v_member_id uuid;

  v_round_status text;
  v_round_opens_at timestamptz;
  v_round_lock_at timestamptz;

  v_fixture_id uuid;
  v_fixture_is_bye boolean;

  v_strategy public.strategies%rowtype;
  v_next_version integer;
begin
  -- ----------------------------------------------------------
  -- Authentication and input validation
  -- ----------------------------------------------------------

  if v_user_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'USER_NOT_AUTHENTICATED';
  end if;

  if p_league_round_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_ROUND_REQUIRED';
  end if;

  if p_mode is null or p_mode not in ('fantacalcio', 'one_to_one') then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_MODE_INVALID';
  end if;

  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_PAYLOAD_INVALID';
  end if;

  -- ----------------------------------------------------------
  -- Resolve and lock the League Round lifecycle
  -- ----------------------------------------------------------

  select
    lr.league_id,
    lr.status,
    fr.opens_at,
    fr.lock_at
  into
    v_league_id,
    v_round_status,
    v_round_opens_at,
    v_round_lock_at
  from public.league_rounds lr
  join public.fantagol_rounds fr
    on fr.id = lr.fantagol_round_id
  where lr.id = p_league_round_id
    and lr.enabled = true
  for update of lr;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_ROUND_NOT_FOUND';
  end if;

  if v_round_status <> 'predictions_open'
     or v_now < v_round_opens_at
     or v_now >= v_round_lock_at then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_WINDOW_CLOSED';
  end if;

  -- ----------------------------------------------------------
  -- Resolve the authenticated active League Member
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
      message = 'STRATEGY_ACTIVE_MEMBERSHIP_REQUIRED';
  end if;

  -- Serialize saves for the same user, round and mode.
  perform pg_advisory_xact_lock(
    hashtextextended(
      'strategy-save:'
      || p_league_round_id::text
      || ':'
      || v_member_id::text
      || ':'
      || p_mode,
      0
    )
  );

  -- ----------------------------------------------------------
  -- Resolve the single fixture from the active schedule
  -- ----------------------------------------------------------

  select
    lf.id,
    lf.is_bye
  into
    v_fixture_id,
    v_fixture_is_bye
  from public.league_fixtures lf
  join public.league_schedule_versions lsv
    on lsv.id = lf.schedule_version_id
   and lsv.active = true
  where lf.league_id = v_league_id
    and lf.league_round_id = p_league_round_id
    and lf.mode = p_mode
    and (
      lf.home_member_id = v_member_id
      or lf.away_member_id = v_member_id
    );

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_ACTIVE_FIXTURE_NOT_FOUND';
  end if;

  if v_fixture_is_bye then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_NOT_REQUIRED_FOR_BYE';
  end if;

  -- ----------------------------------------------------------
  -- Load and lock an existing Strategy aggregate, if present
  -- ----------------------------------------------------------

  select s.*
  into v_strategy
  from public.strategies s
  where s.league_fixture_id = v_fixture_id
    and s.league_member_id = v_member_id
  for update;

  if found then
    if v_strategy.status in ('locked', 'void') then
      raise exception using
        errcode = 'P0001',
        message = 'STRATEGY_NOT_EDITABLE';
    end if;

    v_next_version := v_strategy.version + 1;

    update public.strategies s
    set
      status = 'draft',
      source = 'standard',
      version = v_next_version
    where s.id = v_strategy.id
    returning s.*
    into v_strategy;
  else
    insert into public.strategies (
      league_id,
      league_round_id,
      league_member_id,
      user_id,
      league_fixture_id,
      status,
      source,
      version
    )
    values (
      v_league_id,
      p_league_round_id,
      v_member_id,
      v_user_id,
      v_fixture_id,
      'draft',
      'standard',
      1
    )
    returning *
    into v_strategy;

    v_next_version := 1;
  end if;

  -- ----------------------------------------------------------
  -- Append the immutable workspace state
  -- ----------------------------------------------------------

  insert into public.strategy_versions (
    strategy_id,
    version,
    payload,
    status,
    source,
    changed_by_user_id,
    changed_by_member_id,
    changed_at,
    metadata
  )
  values (
    v_strategy.id,
    v_next_version,
    p_payload,
    'draft',
    'standard',
    v_user_id,
    v_member_id,
    v_now,
    jsonb_build_object(
      'operation', 'workspace_save',
      'mode', p_mode,
      'league_round_id', p_league_round_id,
      'league_fixture_id', v_fixture_id,
      'official_submitted_version', v_strategy.submitted_version
    )
  );

  return query
  select
    v_strategy.id,
    v_fixture_id,
    p_mode,
    v_next_version,
    'draft'::text,
    v_strategy.submitted_version,
    (
      v_strategy.submitted_version is not null
      and v_strategy.submitted_version <> v_next_version
    ),
    v_now;
end;
$function$;

comment on function public.save_strategy_draft_rpc(uuid, text, jsonb)
is 'Autosaves one private Strategy workspace for the authenticated member and active fixture. Every save appends an immutable version; prior official snapshots remain unchanged until explicit resubmission.';

revoke all on function public.save_strategy_draft_rpc(uuid, text, jsonb)
  from public;
revoke all on function public.save_strategy_draft_rpc(uuid, text, jsonb)
  from anon;
revoke all on function public.save_strategy_draft_rpc(uuid, text, jsonb)
  from service_role;
grant execute on function public.save_strategy_draft_rpc(uuid, text, jsonb)
  to authenticated;

commit;
