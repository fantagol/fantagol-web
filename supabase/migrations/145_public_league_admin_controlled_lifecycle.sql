-- ============================================================================
-- FANTAGOL
-- MIGRATION 145
-- PUBLIC LEAGUE ADMIN-CONTROLLED LIFECYCLE
--
-- Milestone 12.9.3
--
-- Season policy 2026/27:
--   - public leagues remain active for the competition edition;
--   - public registrations remain open until the league admin locks the roster;
--   - no automatic registration deadline;
--   - no inactivity evaluation deadline;
--   - no automatic archival or deletion;
--   - after admin lock, public leagues follow the canonical private lifecycle.
--
-- Compatibility:
--   - legacy schedule columns remain available;
--   - legacy RPC return columns remain available;
--   - automatic lifecycle values are always returned and persisted as null.
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 1. NORMALIZE EXISTING PUBLIC LEAGUES
-- ----------------------------------------------------------------------------

update public.leagues
set
  automatic_join_close_at = null,
  inactivity_evaluation_round_id = null,
  inactivity_evaluation_at = null
where visibility = 'public'
  and (
    automatic_join_close_at is not null
    or inactivity_evaluation_round_id is not null
    or inactivity_evaluation_at is not null
  );

-- ----------------------------------------------------------------------------
-- 2. ADMIN-CONTROLLED PUBLIC LEAGUE CREATION CONTRACT
-- ----------------------------------------------------------------------------

create or replace function public.create_league_v2_rpc(
  league_name text,
  member_display_name text,
  league_visibility text,
  expected_schedule_version integer default 1
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
    public_schedule_version
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
    1
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
  integer
)
is
'Creates private and public leagues using the canonical admin-controlled lifecycle. Public leagues retain schedule resolution but have no automatic registration deadline or inactivity cleanup policy.';

-- ----------------------------------------------------------------------------
-- 3. COLUMN POLICY DOCUMENTATION
-- ----------------------------------------------------------------------------

comment on column public.leagues.automatic_join_close_at
is
'Compatibility field. For the 2026/27 admin-controlled lifecycle this value must remain null; registrations close only when the league admin locks the roster.';

comment on column public.leagues.inactivity_evaluation_round_id
is
'Compatibility field. For the 2026/27 admin-controlled lifecycle this value must remain null; public leagues are not evaluated for automatic inactivity cleanup.';

comment on column public.leagues.inactivity_evaluation_at
is
'Compatibility field. For the 2026/27 admin-controlled lifecycle this value must remain null; public leagues remain available for the competition edition.';

-- ----------------------------------------------------------------------------
-- 4. PRIVILEGES
-- ----------------------------------------------------------------------------

revoke all on function public.create_league_v2_rpc(
  text,
  text,
  text,
  integer
) from public;

revoke all on function public.create_league_v2_rpc(
  text,
  text,
  text,
  integer
) from anon;

grant execute on function public.create_league_v2_rpc(
  text,
  text,
  text,
  integer
) to authenticated;

grant execute on function public.create_league_v2_rpc(
  text,
  text,
  text,
  integer
) to service_role;

-- ----------------------------------------------------------------------------
-- 5. MIGRATION CERTIFICATION
-- ----------------------------------------------------------------------------

do $verification$
declare
  v_function_definition text;
  v_invalid_public_leagues integer;
begin
  select pg_get_functiondef(p.oid)
  into v_function_definition
  from pg_proc p
  join pg_namespace n
    on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname = 'create_league_v2_rpc'
    and p.proargtypes = '25 25 25 23'::oidvector;

  if v_function_definition is null then
    raise exception
      'PUBLIC_LEAGUE_ADMIN_CONTROLLED_CREATION_RPC_MISSING';
  end if;

  if position(
    '''join_policy'','
    in v_function_definition
  ) = 0
  or position(
    '''admin_lock_only'''
    in v_function_definition
  ) = 0 then
    raise exception
      'PUBLIC_LEAGUE_ADMIN_LOCK_POLICY_MARKER_MISSING';
  end if;


  select count(*)
  into v_invalid_public_leagues
  from public.leagues l
  where l.visibility = 'public'
    and (
      l.automatic_join_close_at is not null
      or l.inactivity_evaluation_round_id is not null
      or l.inactivity_evaluation_at is not null
    );

  if v_invalid_public_leagues <> 0 then
    raise exception
      'PUBLIC_LEAGUE_AUTOMATIC_LIFECYCLE_VALUES_REMAIN: %',
      v_invalid_public_leagues;
  end if;

  if not has_function_privilege(
    'authenticated',
    'public.create_league_v2_rpc(text,text,text,integer)',
    'EXECUTE'
  ) then
    raise exception
      'PUBLIC_LEAGUE_CREATION_AUTHENTICATED_GRANT_MISSING';
  end if;

  if has_function_privilege(
    'anon',
    'public.create_league_v2_rpc(text,text,text,integer)',
    'EXECUTE'
  ) then
    raise exception
      'PUBLIC_LEAGUE_CREATION_ANON_EXECUTE_NOT_REVOKED';
  end if;

  raise notice
    'PUBLIC_LEAGUE_ADMIN_CONTROLLED_LIFECYCLE_OK';
end;
$verification$;

commit;