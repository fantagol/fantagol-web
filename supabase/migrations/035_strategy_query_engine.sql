-- Migration 035: Strategy Query Engine
-- Purpose:
--   - expose one authenticated read model for Strategy UI and application services;
--   - resolve the active fixture for the requested League Round and mode;
--   - return current workspace, official snapshot and locked payloads;
--   - avoid direct client reads from strategies / strategy_versions;
--   - expose stable state flags for autosave, submit, resubmit and lock UI.
--
-- No table privileges are widened by this migration.

begin;

create or replace function public.get_my_strategy_status_rpc(
  p_league_round_id uuid,
  p_mode text
)
returns table (
  league_round_id uuid,
  league_fixture_id uuid,
  mode text,
  league_member_id uuid,
  opponent_member_id uuid,
  is_home boolean,
  is_bye boolean,

  strategy_exists boolean,
  strategy_id uuid,
  strategy_status text,

  workspace_version integer,
  workspace_payload jsonb,

  submitted_version integer,
  official_payload jsonb,
  official_submitted_at timestamptz,

  locked_version integer,
  locked_payload jsonb,
  locked_at timestamptz,

  has_official_snapshot boolean,
  has_unconfirmed_changes boolean,
  is_editable boolean,
  is_submittable boolean,
  is_locked boolean,

  payload_schema_version integer,
  match_set_version integer
)
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_user_id uuid := auth.uid();

  v_league_id uuid;
  v_member_id uuid;
  v_round_status text;
  v_round_opens_at timestamptz;
  v_round_lock_at timestamptz;
  v_match_set_version integer;
  v_now timestamptz := now();

  v_fixture_id uuid;
  v_home_member_id uuid;
  v_away_member_id uuid;
  v_is_bye boolean;
  v_opponent_member_id uuid;
  v_is_home boolean;

  v_strategy public.strategies%rowtype;

  v_workspace_payload jsonb;
  v_official_payload jsonb;
  v_locked_payload jsonb;
  v_locked_version integer;

  v_schema_version integer;
begin
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

  select
    lr.league_id,
    lr.status,
    fr.opens_at,
    fr.lock_at,
    fr.official_match_set_version
  into
    v_league_id,
    v_round_status,
    v_round_opens_at,
    v_round_lock_at,
    v_match_set_version
  from public.league_rounds lr
  join public.fantagol_rounds fr
    on fr.id = lr.fantagol_round_id
  where lr.id = p_league_round_id
    and lr.enabled = true;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'STRATEGY_ROUND_NOT_FOUND';
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
      message = 'STRATEGY_ACTIVE_MEMBERSHIP_REQUIRED';
  end if;

  select
    lf.id,
    lf.home_member_id,
    lf.away_member_id,
    lf.is_bye
  into
    v_fixture_id,
    v_home_member_id,
    v_away_member_id,
    v_is_bye
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

  v_is_home := v_home_member_id = v_member_id;

  if v_is_home then
    v_opponent_member_id := v_away_member_id;
  else
    v_opponent_member_id := v_home_member_id;
  end if;

  select s.*
  into v_strategy
  from public.strategies s
  where s.league_fixture_id = v_fixture_id
    and s.league_member_id = v_member_id;

  if not found then
    return query
    select
      p_league_round_id,
      v_fixture_id,
      p_mode,
      v_member_id,
      v_opponent_member_id,
      v_is_home,
      v_is_bye,

      false,
      null::uuid,
      null::text,

      null::integer,
      null::jsonb,

      null::integer,
      null::jsonb,
      null::timestamptz,

      null::integer,
      null::jsonb,
      null::timestamptz,

      false,
      false,
      (
        v_is_bye is false
        and v_round_status = 'predictions_open'
        and v_now >= v_round_opens_at
        and v_now < v_round_lock_at
      ),
      false,
      false,

      null::integer,
      v_match_set_version;
    return;
  end if;

  select sv.payload
  into v_workspace_payload
  from public.strategy_versions sv
  where sv.strategy_id = v_strategy.id
    and sv.version = v_strategy.version;

  if v_strategy.submitted_version is not null then
    select sv.payload
    into v_official_payload
    from public.strategy_versions sv
    where sv.strategy_id = v_strategy.id
      and sv.version = v_strategy.submitted_version;
  end if;

  select
    sv.version,
    sv.payload
  into
    v_locked_version,
    v_locked_payload
  from public.strategy_versions sv
  where sv.strategy_id = v_strategy.id
    and sv.status = 'locked'
  order by sv.version desc
  limit 1;

  v_schema_version :=
    case
      when jsonb_typeof(v_workspace_payload -> 'schema_version') = 'number'
      then (v_workspace_payload ->> 'schema_version')::integer
      else null
    end;

  return query
  select
    p_league_round_id,
    v_fixture_id,
    p_mode,
    v_member_id,
    v_opponent_member_id,
    v_is_home,
    v_is_bye,

    true,
    v_strategy.id,
    v_strategy.status,

    v_strategy.version,
    v_workspace_payload,

    v_strategy.submitted_version,
    v_official_payload,
    v_strategy.official_submitted_at,

    v_locked_version,
    v_locked_payload,
    v_strategy.locked_at,

    (v_strategy.submitted_version is not null),
    (
      v_strategy.submitted_version is not null
      and v_strategy.version <> v_strategy.submitted_version
      and v_strategy.status = 'draft'
    ),
    (
      v_is_bye is false
      and v_strategy.status not in ('locked', 'void')
      and v_round_status = 'predictions_open'
      and v_now >= v_round_opens_at
      and v_now < v_round_lock_at
    ),
    (
      v_is_bye is false
      and v_strategy.status not in ('locked', 'void')
      and v_round_status = 'predictions_open'
      and v_now >= v_round_opens_at
      and v_now < v_round_lock_at
      and v_workspace_payload is not null
    ),
    (v_strategy.status = 'locked'),

    v_schema_version,
    v_match_set_version;
end;
$function$;

comment on function public.get_my_strategy_status_rpc(uuid, text)
is 'Returns the authenticated member Strategy read model for one League Round and mode, including workspace, official and locked payloads plus UI lifecycle flags.';

revoke all on function public.get_my_strategy_status_rpc(uuid, text)
  from public;
revoke all on function public.get_my_strategy_status_rpc(uuid, text)
  from anon;
revoke all on function public.get_my_strategy_status_rpc(uuid, text)
  from service_role;
grant execute on function public.get_my_strategy_status_rpc(uuid, text)
  to authenticated;

commit;
