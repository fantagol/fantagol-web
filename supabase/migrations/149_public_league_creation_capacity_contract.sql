-- ============================================================================
-- FANTAGOL
-- MIGRATION 149
-- PUBLIC LEAGUE CREATION CAPACITY CONTRACT
--
-- Milestone 12.9.5.2
--
-- Purpose:
--   - extend create_league_v2_rpc with public league capacity;
--   - preserve backward compatibility through a default value of 8;
--   - validate public capacity between 2 and 20;
--   - initialize public registrations as open;
--   - keep private league capacity fields null;
--   - preserve the existing schedule and administrative lifecycle contracts.
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 1. REMOVE PREVIOUS FOUR-PARAMETER SIGNATURE
-- ----------------------------------------------------------------------------

drop function if exists public.create_league_v2_rpc(
  text,
  text,
  text,
  integer
);

-- ----------------------------------------------------------------------------
-- 2. CREATE CAPACITY-AWARE LEAGUE CREATION RPC
-- ----------------------------------------------------------------------------

create function public.create_league_v2_rpc(
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
'Creates private or public leagues. Public leagues accept a finite capacity between 2 and 20, default to 8 participants, start with registrations open, and use the current certified public schedule contract.';

-- ----------------------------------------------------------------------------
-- 3. ACCESS CONTRACT
-- ----------------------------------------------------------------------------

revoke all
on function public.create_league_v2_rpc(
  text,
  text,
  text,
  integer,
  integer
)
from public;

revoke all
on function public.create_league_v2_rpc(
  text,
  text,
  text,
  integer,
  integer
)
from anon;

grant execute
on function public.create_league_v2_rpc(
  text,
  text,
  text,
  integer,
  integer
)
to authenticated;

grant execute
on function public.create_league_v2_rpc(
  text,
  text,
  text,
  integer,
  integer
)
to service_role;

-- ----------------------------------------------------------------------------
-- 4. CERTIFICATION
-- ----------------------------------------------------------------------------

do $verification$
declare
  v_new_signature regprocedure;
  v_old_signature regprocedure;
  v_function_definition text;
begin
  v_new_signature :=
    to_regprocedure(
      'public.create_league_v2_rpc(text,text,text,integer,integer)'
    );

  if v_new_signature is null then
    raise exception
      'PUBLIC_LEAGUE_CAPACITY_CREATE_RPC_MISSING';
  end if;

  v_old_signature :=
    to_regprocedure(
      'public.create_league_v2_rpc(text,text,text,integer)'
    );

  if v_old_signature is not null then
    raise exception
      'LEGACY_CREATE_LEAGUE_RPC_SIGNATURE_STILL_PRESENT';
  end if;

  select pg_get_functiondef(v_new_signature::oid)
  into v_function_definition;

  if position(
    'public_max_participants integer DEFAULT 8'
    in v_function_definition
  ) = 0 then
    raise exception
      'PUBLIC_LEAGUE_CAPACITY_DEFAULT_CONTRACT_MISSING';
  end if;

  if position(
    'PUBLIC_LEAGUE_INVALID_MAX_PARTICIPANTS'
    in v_function_definition
  ) = 0 then
    raise exception
      'PUBLIC_LEAGUE_CAPACITY_VALIDATION_MISSING';
  end if;

  if position(
    'public_registrations_open'
    in v_function_definition
  ) = 0 then
    raise exception
      'PUBLIC_LEAGUE_INITIAL_REGISTRATION_STATE_MISSING';
  end if;

  if not has_function_privilege(
    'authenticated',
    'public.create_league_v2_rpc(text,text,text,integer,integer)',
    'EXECUTE'
  ) then
    raise exception
      'AUTHENTICATED_CREATE_LEAGUE_RPC_EXECUTE_MISSING';
  end if;

  raise notice
    'PUBLIC_LEAGUE_CREATION_CAPACITY_CONTRACT_OK';
end;
$verification$;

commit;