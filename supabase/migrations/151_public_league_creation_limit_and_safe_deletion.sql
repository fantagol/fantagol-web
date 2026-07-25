-- ============================================================================
-- FANTAGOL
-- MIGRATION 151
-- PUBLIC LEAGUE CREATION LIMIT AND SAFE PERMANENT DELETION
--
-- Milestone 12.9.5.7
--
-- Policy:
--   - one authenticated active admin may have at most two public leagues in
--     draft/open/locked lifecycle states;
--   - a public league may be permanently deleted only while its active admin
--     is the sole active member;
--   - private-league deletion behavior remains unchanged.
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 1. PUBLIC LEAGUE CREATION LIMIT
-- ----------------------------------------------------------------------------

create or replace function public.create_league_v2_rpc(
  league_name text,
  member_display_name text,
  league_visibility text,
  expected_schedule_version integer default 1,
  public_max_participants integer default 8
)
returns table(
  league_id uuid,
  invite_code text,
  visibility text,
  starts_from_fantagol_round_id uuid,
  first_useful_kickoff_at timestamptz,
  automatic_join_close_at timestamptz,
  inactivity_evaluation_round_id uuid,
  inactivity_evaluation_at timestamptz
)
language plpgsql
security definer
set search_path to public
as $function$
declare
  v_user_id uuid := auth.uid();
  v_league_id uuid;
  v_invite_code text;
  v_club_id uuid;
  v_admin_member_id uuid;
  v_edition_id uuid;
  v_visibility text := lower(trim(coalesce(league_visibility, '')));
  v_schedule record;
  v_max_participants integer;
begin
  if v_user_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'AUTH_REQUIRED';
  end if;

  if nullif(trim(league_name), '') is null then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_NAME_REQUIRED';
  end if;

  if nullif(trim(member_display_name), '') is null then
    raise exception using
      errcode = 'P0001',
      message = 'DISPLAY_NAME_REQUIRED';
  end if;

  if v_visibility not in ('private', 'public') then
    raise exception using
      errcode = 'P0001',
      message = 'INVALID_LEAGUE_VISIBILITY';
  end if;

  if v_visibility = 'public' then
    perform pg_advisory_xact_lock(
      hashtextextended(v_user_id::text, 151)
    );

    if (
      select count(*)
      from public.leagues l
      join public.league_members lm
        on lm.league_id = l.id
       and lm.user_id = v_user_id
       and lm.role = 'admin'
       and lm.status = 'active'
      where l.visibility = 'public'
        and l.lifecycle_status in ('draft', 'open', 'locked')
    ) >= 2 then
      raise exception using
        errcode = 'P0001',
        message = 'PUBLIC_LEAGUE_ACTIVE_LIMIT_REACHED';
    end if;
  end if;

  if expected_schedule_version is null
     or expected_schedule_version <> 1 then
    raise exception using
      errcode = 'P0001',
      message = 'PUBLIC_LEAGUE_SCHEDULE_CHANGED';
  end if;

  if v_visibility = 'public' then
    v_max_participants := coalesce(public_max_participants, 8);

    if v_max_participants < 2
       or v_max_participants > 20 then
      raise exception using
        errcode = 'P0001',
        message = 'PUBLIC_LEAGUE_INVALID_MAX_PARTICIPANTS';
    end if;
  else
    v_max_participants := null;
  end if;

  select ce.id
  into v_edition_id
  from public.competition_editions ce
  join public.competitions c
    on c.id = ce.competition_id
  where ce.active = true
    and ce.status in ('scheduled', 'active')
    and c.enabled = true
  order by
    case ce.status
      when 'active' then 0
      else 1
    end,
    ce.starts_at,
    ce.created_at,
    ce.id
  limit 1;

  if v_edition_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'NO_ACTIVE_COMPETITION_EDITION';
  end if;

  if v_visibility = 'public' then
    select *
    into v_schedule
    from public.resolve_public_league_schedule_internal(
      v_edition_id,
      now()
    );

    if v_schedule.schedule_version <> expected_schedule_version then
      raise exception using
        errcode = 'P0001',
        message = 'PUBLIC_LEAGUE_SCHEDULE_CHANGED';
    end if;
  end if;

  select c.id
  into v_club_id
  from public.clubs c
  where c.owner_id = v_user_id
  order by
    c.created_at,
    c.id
  limit 1;

  if v_club_id is null then
    insert into public.clubs (
      owner_id,
      name
    )
    values (
      v_user_id,
      'FantaGol Club'
    )
    returning id into v_club_id;
  end if;

  loop
    v_invite_code :=
      'FG-' ||
      upper(
        substring(
          md5(
            random()::text ||
            clock_timestamp()::text
          ),
          1,
          6
        )
      );

    exit when not exists (
      select 1
      from public.leagues l
      where l.invite_code = v_invite_code
    );
  end loop;

  insert into public.leagues (
    name,
    owner_id,
    invite_code,
    status,
    edition_id,
    lifecycle_status,
    roster_status,
    vice_required,
    visibility,
    starts_from_fantagol_round_id,
    first_useful_kickoff_at,
    automatic_join_close_at,
    inactivity_evaluation_round_id,
    inactivity_evaluation_at,
    public_schedule_version,
    max_participants,
    public_registrations_open
  )
  values (
    trim(league_name),
    v_user_id,
    v_invite_code,
    'active',
    v_edition_id,
    'open',
    'open',
    true,
    v_visibility,
    case
      when v_visibility = 'public'
        then v_schedule.starts_from_fantagol_round_id
      else null
    end,
    case
      when v_visibility = 'public'
        then v_schedule.first_useful_kickoff_at
      else null
    end,
    null,
    null,
    null,
    1,
    case
      when v_visibility = 'public'
        then v_max_participants
      else null
    end,
    case
      when v_visibility = 'public'
        then true
      else null
    end
  )
  returning id into v_league_id;

  insert into public.league_members (
    league_id,
    user_id,
    club_id,
    display_name,
    role,
    status
  )
  values (
    v_league_id,
    v_user_id,
    v_club_id,
    trim(member_display_name),
    'admin',
    'active'
  )
  returning id into v_admin_member_id;

  update public.profiles
  set last_active_league_id = v_league_id
  where id = v_user_id;

  perform public.write_league_admin_event(
    v_league_id,
    v_admin_member_id,
    v_user_id,
    'member',
    'league_created',
    v_admin_member_id,
    null,
    jsonb_build_object(
      'edition_id',
      v_edition_id,
      'initial_role',
      'admin',
      'lifecycle_status',
      'open',
      'roster_status',
      'open',
      'visibility',
      v_visibility,
      'public_schedule_version',
      1,
      'max_participants',
      v_max_participants,
      'public_registrations_open',
      case
        when v_visibility = 'public' then true
        else null
      end,
      'join_policy',
      'admin_lock_only',
      'automatic_join_close_enabled',
      false,
      'inactivity_cleanup_enabled',
      false
    )
  );

  return query
  select
    v_league_id,
    v_invite_code,
    v_visibility,
    case
      when v_visibility = 'public'
        then v_schedule.starts_from_fantagol_round_id
      else null
    end,
    case
      when v_visibility = 'public'
        then v_schedule.first_useful_kickoff_at
      else null
    end,
    null::timestamptz,
    null::uuid,
    null::timestamptz;
end;
$function$;

comment on function public.create_league_v2_rpc(
  text,
  text,
  text,
  integer,
  integer
)
is
'Creates private or public leagues. Public creation is limited to two draft/open/locked leagues per active admin and remains capacity-aware under the certified schedule contract.';

-- ----------------------------------------------------------------------------
-- 2. SAFE PUBLIC LEAGUE PERMANENT DELETION
-- ----------------------------------------------------------------------------

create or replace function public.delete_league_permanently_rpc(
  p_league_id uuid,
  p_confirmation_name text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_user_id uuid := auth.uid();
  v_league public.leagues%rowtype;
  v_admin_member_id uuid;

  v_members_count bigint := 0;
  v_rounds_count bigint := 0;
  v_fixtures_count bigint := 0;
  v_predictions_count bigint := 0;
  v_strategies_count bigint := 0;
  v_strategy_versions_count bigint := 0;
begin
  if v_user_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'AUTH_REQUIRED';
  end if;

  select *
  into v_league
  from public.leagues
  where id = p_league_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_NOT_FOUND';
  end if;

  v_admin_member_id :=
    public.get_active_admin_member_id(
      p_league_id,
      v_user_id
    );

  if v_admin_member_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'ACTIVE_ADMIN_REQUIRED';
  end if;

  if p_confirmation_name is null
     or btrim(p_confirmation_name) <> v_league.name
  then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_NAME_CONFIRMATION_MISMATCH';
  end if;

  if v_league.visibility = 'public' then
    select count(*)
    into v_members_count
    from public.league_members
    where league_id = p_league_id
      and status = 'active';

    if v_members_count > 1 then
      raise exception using
        errcode = 'P0001',
        message = 'PUBLIC_LEAGUE_DELETE_REQUIRES_SOLE_ADMIN';
    end if;
  end if;

  select count(*)
  into v_members_count
  from public.league_members
  where league_id = p_league_id;

  select count(*)
  into v_rounds_count
  from public.league_rounds
  where league_id = p_league_id;

  select count(*)
  into v_fixtures_count
  from public.league_fixtures
  where league_id = p_league_id;

  select count(*)
  into v_predictions_count
  from public.predictions
  where league_id = p_league_id;

  select count(*)
  into v_strategies_count
  from public.strategies
  where league_id = p_league_id;

  select count(*)
  into v_strategy_versions_count
  from public.strategy_versions sv
  join public.strategies s
    on s.id = sv.strategy_id
  where s.league_id = p_league_id;

  update public.profiles
  set last_active_league_id = null
  where last_active_league_id = p_league_id;

  /*
   * Strategy versions reference league members through
   * changed_by_member_id with ON DELETE SET NULL.
   *
   * Deleting league_members first would therefore issue an UPDATE
   * against the immutable strategy_versions table.
   *
   * Remove the versions explicitly before the league cascade.
   */
  perform set_config(
    'fantagol.allow_strategy_version_delete',
    'on',
    true
  );

  delete from public.strategy_versions sv
  using public.strategies s
  where sv.strategy_id = s.id
    and s.league_id = p_league_id;

  delete from public.leagues
  where id = p_league_id;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_DELETE_FAILED';
  end if;

  return jsonb_build_object(
    'deleted', true,
    'league_id', p_league_id,
    'league_name', v_league.name,
    'members_removed', v_members_count,
    'rounds_removed', v_rounds_count,
    'fixtures_removed', v_fixtures_count,
    'predictions_removed', v_predictions_count,
    'strategies_removed', v_strategies_count,
    'strategy_versions_removed', v_strategy_versions_count
  );
end;
$function$;

revoke all
on function public.delete_league_permanently_rpc(uuid, text)
from public;

revoke all
on function public.delete_league_permanently_rpc(uuid, text)
from anon;

revoke all
on function public.delete_league_permanently_rpc(uuid, text)
from service_role;

grant execute
on function public.delete_league_permanently_rpc(uuid, text)
to authenticated;

comment on function public.delete_league_permanently_rpc(uuid, text)
is
'Permanently deletes a league and its dependent graph. Public leagues require the active admin to be the sole active member. Private-league behavior is unchanged.';

-- ----------------------------------------------------------------------------
-- 3. CONTRACT CERTIFICATION
-- ----------------------------------------------------------------------------

do $verification$
declare
  v_create_definition text;
  v_delete_definition text;
begin
  select pg_get_functiondef(
    'public.create_league_v2_rpc(text,text,text,integer,integer)'::regprocedure
  )
  into v_create_definition;

  select pg_get_functiondef(
    'public.delete_league_permanently_rpc(uuid,text)'::regprocedure
  )
  into v_delete_definition;

  if position('PUBLIC_LEAGUE_ACTIVE_LIMIT_REACHED' in v_create_definition) = 0 then
    raise exception 'PUBLIC_LEAGUE_ACTIVE_LIMIT_GUARD_MISSING';
  end if;

  if position('pg_advisory_xact_lock' in v_create_definition) = 0 then
    raise exception 'PUBLIC_LEAGUE_CREATION_CONCURRENCY_GUARD_MISSING';
  end if;

  if position('PUBLIC_LEAGUE_DELETE_REQUIRES_SOLE_ADMIN' in v_delete_definition) = 0 then
    raise exception 'PUBLIC_LEAGUE_DELETE_SOLE_ADMIN_GUARD_MISSING';
  end if;
end;
$verification$;

commit;
