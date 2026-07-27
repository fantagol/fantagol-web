-- ============================================================================
-- FANTAGOL
-- MIGRATION 159
-- CREATE LEAGUE V2 PRIVATE START ROUND RUNTIME FIX
--
-- Purpose:
--   - resolve the canonical starting FantaGol round for both private and public
--     leagues created through create_league_v2_rpc;
--   - persist starts_from_fantagol_round_id and first_useful_kickoff_at for
--     private leagues instead of explicitly writing NULL;
--   - allow migration 158 private round materialization to run on INSERT;
--   - backfill active private leagues previously created without a start round;
--   - preserve all existing public-league governance and RPC compatibility.
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 1. REPLACE CREATE_LEAGUE_V2_RPC WITH THE CERTIFIED COMPLETE DEFINITION
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
set search_path to 'public'
as $function$
declare
  v_user_id uuid := auth.uid();
  v_league_id uuid;
  v_invite_code text;
  v_club_id uuid;
  v_admin_member_id uuid;
  v_edition_id uuid;
  v_visibility text := lower(trim(coalesce(league_visibility, '')));
  v_schedule_version integer;
  v_starts_from_fantagol_round_id uuid;
  v_first_useful_kickoff_at timestamptz;
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

  -- The canonical schedule applies to every league visibility. Public leagues
  -- additionally retain optimistic schedule-version verification.
  select
    schedule_version,
    starts_from_fantagol_round_id,
    first_useful_kickoff_at
  into
    v_schedule_version,
    v_starts_from_fantagol_round_id,
    v_first_useful_kickoff_at
  from public.resolve_public_league_schedule_internal(
    v_edition_id,
    now()
  );

  if v_starts_from_fantagol_round_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_START_ROUND_NOT_FOUND';
  end if;

  if v_visibility = 'public'
     and v_schedule_version <> expected_schedule_version then
    raise exception using
      errcode = 'P0001',
      message = 'PUBLIC_LEAGUE_SCHEDULE_CHANGED';
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
    v_starts_from_fantagol_round_id,
    v_first_useful_kickoff_at,
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
    v_starts_from_fantagol_round_id,
    v_first_useful_kickoff_at,
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
'Creates public or private leagues with a canonical starting FantaGol round. Public leagues retain schedule-version and participant-limit governance.';

revoke all
on function public.create_league_v2_rpc(
  text,
  text,
  text,
  integer,
  integer
)
from public, anon;

grant execute
on function public.create_league_v2_rpc(
  text,
  text,
  text,
  integer,
  integer
)
to authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 2. BACKFILL ACTIVE PRIVATE LEAGUES WITHOUT A CANONICAL START ROUND
--
-- Updating starts_from_fantagol_round_id from NULL activates the private-league
-- materialization trigger installed by migration 158.
-- ----------------------------------------------------------------------------

do $backfill$
declare
  v_league record;
  v_schedule_version integer;
  v_start_round_id uuid;
  v_first_kickoff_at timestamptz;
begin
  for v_league in
    select
      l.id,
      l.edition_id
    from public.leagues l
    where l.visibility = 'private'
      and l.starts_from_fantagol_round_id is null
      and l.lifecycle_status not in ('completed', 'archived')
    order by l.created_at, l.id
  loop
    select
      schedule_version,
      starts_from_fantagol_round_id,
      first_useful_kickoff_at
    into
      v_schedule_version,
      v_start_round_id,
      v_first_kickoff_at
    from public.resolve_public_league_schedule_internal(
      v_league.edition_id,
      now()
    );

    if v_start_round_id is null then
      raise exception using
        errcode = 'P0001',
        message =
          'PRIVATE_LEAGUE_START_ROUND_NOT_FOUND:' ||
          v_league.id::text;
    end if;

    update public.leagues
    set
      starts_from_fantagol_round_id = v_start_round_id,
      first_useful_kickoff_at = v_first_kickoff_at
    where id = v_league.id;
  end loop;
end;
$backfill$;

-- ----------------------------------------------------------------------------
-- 3. TRANSACTIONAL CERTIFICATION
-- ----------------------------------------------------------------------------

do $verification$
declare
  v_function_definition text;
  v_private_without_start_round bigint;
  v_private_without_materialized_rounds bigint;
  v_target_league_start_round uuid;
  v_target_league_round_count bigint;
begin
  select pg_get_functiondef(p.oid)
  into v_function_definition
  from pg_proc p
  join pg_namespace n
    on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname = 'create_league_v2_rpc'
    and p.pronargs = 5;

  if v_function_definition is null then
    raise exception
      'CREATE_LEAGUE_V2_RPC_NOT_FOUND';
  end if;

  if position(
    'LEAGUE_START_ROUND_NOT_FOUND'
    in v_function_definition
  ) = 0 then
    raise exception
      'CREATE_LEAGUE_V2_RPC_START_ROUND_GUARD_MISSING';
  end if;

  if position(
    E'v_visibility,\n    v_starts_from_fantagol_round_id,\n    v_first_useful_kickoff_at,'
    in v_function_definition
  ) = 0 then
    raise exception
      'CREATE_LEAGUE_V2_RPC_PRIVATE_RETURN_CONTRACT_MISSING';
  end if;

  if position(
    E'when v_visibility = ''public''\n        then v_starts_from_fantagol_round_id'
    in v_function_definition
  ) > 0 then
    raise exception
      'CREATE_LEAGUE_V2_RPC_PUBLIC_ONLY_START_ROUND_LOGIC_REMAINS';
  end if;

  select count(*)
  into v_private_without_start_round
  from public.leagues l
  where l.visibility = 'private'
    and l.lifecycle_status not in ('completed', 'archived')
    and l.starts_from_fantagol_round_id is null;

  if v_private_without_start_round <> 0 then
    raise exception
      'ACTIVE_PRIVATE_LEAGUES_WITHOUT_START_ROUND: %',
      v_private_without_start_round;
  end if;

  select count(*)
  into v_private_without_materialized_rounds
  from public.leagues l
  where l.visibility = 'private'
    and l.lifecycle_status not in ('completed', 'archived')
    and l.starts_from_fantagol_round_id is not null
    and not exists (
      select 1
      from public.league_rounds lr
      where lr.league_id = l.id
    );

  if v_private_without_materialized_rounds <> 0 then
    raise exception
      'ACTIVE_PRIVATE_LEAGUES_WITHOUT_MATERIALIZED_ROUNDS: %',
      v_private_without_materialized_rounds;
  end if;

  -- Explicit regression verification for the league that exposed the defect.
  select
    l.starts_from_fantagol_round_id,
    count(lr.id)
  into
    v_target_league_start_round,
    v_target_league_round_count
  from public.leagues l
  left join public.league_rounds lr
    on lr.league_id = l.id
  where l.id = '4cfafa4b-9577-4e72-bbc0-fff2cfd35514'::uuid
  group by l.id, l.starts_from_fantagol_round_id;

  if found then
    if v_target_league_start_round is null then
      raise exception
        'NUOVA_158_START_ROUND_BACKFILL_FAILED';
    end if;

    if v_target_league_round_count = 0 then
      raise exception
        'NUOVA_158_ROUND_MATERIALIZATION_FAILED';
    end if;
  end if;

  raise notice
    'FANTAGOL_CREATE_LEAGUE_V2_PRIVATE_START_ROUND_RUNTIME_CERTIFIED';
end;
$verification$;

commit;
