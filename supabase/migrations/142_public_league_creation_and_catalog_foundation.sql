-- ============================================================================
-- FANTAGOL
-- MIGRATION 142
-- PUBLIC LEAGUE CREATION AND CATALOG FOUNDATION
--
-- Milestone 12.5
--
-- Covers:
--   - versioned private/public league creation RPC
--   - protected public league catalog read model
--   - authenticated paginated catalog RPC
--   - authenticated spectator context foundation
--
-- Does not cover yet:
--   - canonical membership join refactor
--   - public join RPC
--   - authenticated invitation continuation
--   - automatic closure or inactivity workflows
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 1. VERSIONED LEAGUE CREATION RPC
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
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;

  if nullif(trim(league_name), '') is null then
    raise exception using errcode = 'P0001', message = 'LEAGUE_NAME_REQUIRED';
  end if;

  if nullif(trim(member_display_name), '') is null then
    raise exception using errcode = 'P0001', message = 'DISPLAY_NAME_REQUIRED';
  end if;

  if v_visibility not in ('private', 'public') then
    raise exception using errcode = 'P0001', message = 'INVALID_LEAGUE_VISIBILITY';
  end if;

  if expected_schedule_version is null or expected_schedule_version <> 1 then
    raise exception using errcode = 'P0001', message = 'PUBLIC_LEAGUE_SCHEDULE_CHANGED';
  end if;

  select ce.id
  into v_edition_id
  from public.competition_editions ce
  join public.competitions c on c.id = ce.competition_id
  where ce.active = true
    and ce.status in ('scheduled', 'active')
    and c.enabled = true
  order by
    case ce.status when 'active' then 0 else 1 end,
    ce.starts_at,
    ce.created_at,
    ce.id
  limit 1;

  if v_edition_id is null then
    raise exception using errcode = 'P0001', message = 'NO_ACTIVE_COMPETITION_EDITION';
  end if;

  if v_visibility = 'public' then
    select *
    into v_schedule
    from public.resolve_public_league_schedule_internal(v_edition_id, now());

    if v_schedule.schedule_version <> expected_schedule_version then
      raise exception using errcode = 'P0001', message = 'PUBLIC_LEAGUE_SCHEDULE_CHANGED';
    end if;
  end if;

  select c.id
  into v_club_id
  from public.clubs c
  where c.owner_id = v_user_id
  order by c.created_at, c.id
  limit 1;

  if v_club_id is null then
    insert into public.clubs (owner_id, name)
    values (v_user_id, 'FantaGol Club')
    returning id into v_club_id;
  end if;

  loop
    v_invite_code :=
      'FG-' || upper(substring(md5(random()::text || clock_timestamp()::text), 1, 6));

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
    case when v_visibility = 'public' then v_schedule.starts_from_fantagol_round_id else null end,
    case when v_visibility = 'public' then v_schedule.first_useful_kickoff_at else null end,
    case when v_visibility = 'public' then v_schedule.automatic_join_close_at else null end,
    case when v_visibility = 'public' then v_schedule.inactivity_evaluation_round_id else null end,
    case when v_visibility = 'public' then v_schedule.inactivity_evaluation_at else null end,
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
      'edition_id', v_edition_id,
      'initial_role', 'admin',
      'lifecycle_status', 'open',
      'roster_status', 'open',
      'visibility', v_visibility,
      'public_schedule_version', 1
    )
  );

  return query
  select
    v_league_id,
    v_invite_code,
    v_visibility,
    case when v_visibility = 'public' then v_schedule.starts_from_fantagol_round_id else null end,
    case when v_visibility = 'public' then v_schedule.first_useful_kickoff_at else null end,
    case when v_visibility = 'public' then v_schedule.automatic_join_close_at else null end,
    case when v_visibility = 'public' then v_schedule.inactivity_evaluation_round_id else null end,
    case when v_visibility = 'public' then v_schedule.inactivity_evaluation_at else null end;
end;
$function$;

comment on function public.create_league_v2_rpc(text, text, text, integer)
is 'Creates a private or public league while preserving the legacy create_league_rpc contract and persisting the authoritative public schedule snapshot.';

-- ----------------------------------------------------------------------------
-- 2. PROTECTED PUBLIC CATALOG READ MODEL
-- ----------------------------------------------------------------------------

create or replace view public.public_league_catalog_v1
with (security_invoker = false)
as
select
  l.id as league_id,
  l.name as league_name,
  l.edition_id,
  coalesce(
    nullif(to_jsonb(ce) ->> 'label', ''),
    nullif(to_jsonb(ce) ->> 'name', ''),
    ce.id::text
  ) as edition_label,
  l.owner_id as admin_user_id,
  admin_member.display_name as admin_display_name,
  coalesce(member_counts.active_member_count, 0)::integer as active_member_count,
  l.roster_status,
  case
    when l.roster_status = 'open' then 'open'
    else 'locked'
  end as join_status,
  l.visibility,
  l.starts_from_fantagol_round_id,
  start_round.name as starts_from_round_name,
  start_round.sequence as starts_from_round_sequence,
  l.first_useful_kickoff_at,
  l.automatic_join_close_at,
  l.lifecycle_status,
  l.status as league_status,
  l.created_at
from public.leagues l
join public.competition_editions ce
  on ce.id = l.edition_id
left join public.fantagol_rounds start_round
  on start_round.id = l.starts_from_fantagol_round_id
left join lateral (
  select lm.display_name
  from public.league_members lm
  where lm.league_id = l.id
    and lm.role = 'admin'
    and lm.status = 'active'
  order by lm.id
  limit 1
) admin_member on true
left join lateral (
  select count(*)::integer as active_member_count
  from public.league_members lm
  where lm.league_id = l.id
    and lm.status = 'active'
) member_counts on true
where l.visibility = 'public'
  and l.status = 'active'
  and l.lifecycle_status not in ('archived')
  and ce.active = true
  and ce.status in ('scheduled', 'active');

comment on view public.public_league_catalog_v1
is 'Protected internal read model for public league catalog and spectator entry. Direct client grants are intentionally denied.';

-- ----------------------------------------------------------------------------
-- 3. AUTHENTICATED PUBLIC CATALOG RPC
-- ----------------------------------------------------------------------------

create or replace function public.get_public_leagues_rpc(
  page_size integer default 30,
  cursor_created_at timestamptz default null,
  cursor_league_id uuid default null,
  roster_filter text default 'all'
)
returns table(
  league_id uuid,
  league_name text,
  edition_id uuid,
  edition_label text,
  admin_display_name text,
  active_member_count integer,
  roster_status text,
  join_status text,
  visibility text,
  starts_from_fantagol_round_id uuid,
  starts_from_round_name text,
  starts_from_round_sequence integer,
  first_useful_kickoff_at timestamptz,
  automatic_join_close_at timestamptz,
  lifecycle_status text,
  league_status text,
  created_at timestamptz,
  viewer_membership_status text,
  viewer_is_member boolean,
  viewer_can_join boolean
)
language plpgsql
stable
security definer
set search_path to public
as $function$
declare
  v_user_id uuid := auth.uid();
  v_page_size integer := coalesce(page_size, 30);
  v_roster_filter text := lower(trim(coalesce(roster_filter, 'all')));
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;

  if v_page_size < 1 or v_page_size > 100 then
    raise exception using errcode = 'P0001', message = 'PUBLIC_LEAGUE_INVALID_PAGE_SIZE';
  end if;

  if v_roster_filter not in ('all', 'open', 'locked') then
    raise exception using errcode = 'P0001', message = 'PUBLIC_LEAGUE_INVALID_ROSTER_FILTER';
  end if;

  if (cursor_created_at is null) <> (cursor_league_id is null) then
    raise exception using errcode = 'P0001', message = 'PUBLIC_LEAGUE_INVALID_CURSOR';
  end if;

  return query
  select
    c.league_id,
    c.league_name,
    c.edition_id,
    c.edition_label,
    c.admin_display_name,
    c.active_member_count,
    c.roster_status,
    c.join_status,
    c.visibility,
    c.starts_from_fantagol_round_id,
    c.starts_from_round_name,
    c.starts_from_round_sequence,
    c.first_useful_kickoff_at,
    c.automatic_join_close_at,
    c.lifecycle_status,
    c.league_status,
    c.created_at,
    viewer_member.status as viewer_membership_status,
    (viewer_member.status = 'active') as viewer_is_member,
    (
      c.roster_status = 'open'
      and viewer_member.id is null
    ) as viewer_can_join
  from public.public_league_catalog_v1 c
  left join public.league_members viewer_member
    on viewer_member.league_id = c.league_id
   and viewer_member.user_id = v_user_id
  where (v_roster_filter = 'all' or c.roster_status = v_roster_filter)
    and (
      cursor_created_at is null
      or (c.created_at, c.league_id) < (cursor_created_at, cursor_league_id)
    )
  order by
    (viewer_member.status = 'active') desc,
    (c.roster_status = 'open') desc,
    c.created_at desc,
    c.league_name asc,
    c.league_id asc
  limit v_page_size;
end;
$function$;

comment on function public.get_public_leagues_rpc(integer, timestamptz, uuid, text)
is 'Returns the authenticated paginated public league catalog without exposing admin auth identifiers or private league data.';

-- ----------------------------------------------------------------------------
-- 4. AUTHENTICATED SPECTATOR CONTEXT FOUNDATION
-- ----------------------------------------------------------------------------

create or replace function public.get_public_league_context_rpc(
  target_league_id uuid
)
returns table(
  league_id uuid,
  league_name text,
  edition_id uuid,
  edition_label text,
  admin_display_name text,
  active_member_count integer,
  roster_status text,
  join_status text,
  visibility text,
  starts_from_fantagol_round_id uuid,
  starts_from_round_name text,
  starts_from_round_sequence integer,
  first_useful_kickoff_at timestamptz,
  automatic_join_close_at timestamptz,
  lifecycle_status text,
  league_status text,
  created_at timestamptz,
  viewer_membership_status text,
  viewer_is_member boolean,
  viewer_can_join boolean,
  active_members jsonb
)
language plpgsql
stable
security definer
set search_path to public
as $function$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;

  if target_league_id is null then
    raise exception using errcode = 'P0001', message = 'PUBLIC_LEAGUE_ID_REQUIRED';
  end if;

  if not exists (
    select 1
    from public.public_league_catalog_v1 c
    where c.league_id = target_league_id
  ) then
    raise exception using errcode = 'P0001', message = 'PUBLIC_LEAGUE_NOT_FOUND';
  end if;

  return query
  select
    c.league_id,
    c.league_name,
    c.edition_id,
    c.edition_label,
    c.admin_display_name,
    c.active_member_count,
    c.roster_status,
    c.join_status,
    c.visibility,
    c.starts_from_fantagol_round_id,
    c.starts_from_round_name,
    c.starts_from_round_sequence,
    c.first_useful_kickoff_at,
    c.automatic_join_close_at,
    c.lifecycle_status,
    c.league_status,
    c.created_at,
    viewer_member.status,
    (viewer_member.status = 'active'),
    (c.roster_status = 'open' and viewer_member.id is null),
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'membership_id', lm.id,
          'display_name', lm.display_name,
          'role', lm.role,
          'club_id', lm.club_id,
          'club_name', club.name
        )
        order by
          case lm.role when 'admin' then 0 when 'vice' then 1 else 2 end,
          lower(lm.display_name),
          lm.id
      )
      from public.league_members lm
      left join public.clubs club on club.id = lm.club_id
      where lm.league_id = c.league_id
        and lm.status = 'active'
    ), '[]'::jsonb)
  from public.public_league_catalog_v1 c
  left join public.league_members viewer_member
    on viewer_member.league_id = c.league_id
   and viewer_member.user_id = v_user_id
  where c.league_id = target_league_id;
end;
$function$;

comment on function public.get_public_league_context_rpc(uuid)
is 'Returns the authenticated base spectator context for one public league, excluding emails, auth identifiers, drafts, future protected predictions, administration internals and commercial data.';

-- ----------------------------------------------------------------------------
-- 5. PRIVILEGES AND PRIVACY BOUNDARY
-- ----------------------------------------------------------------------------

revoke all on public.public_league_catalog_v1 from public;
revoke all on public.public_league_catalog_v1 from anon;
revoke all on public.public_league_catalog_v1 from authenticated;

revoke all on function public.create_league_v2_rpc(text, text, text, integer)
  from public;
revoke all on function public.create_league_v2_rpc(text, text, text, integer)
  from anon;
grant execute on function public.create_league_v2_rpc(text, text, text, integer)
  to authenticated;
grant execute on function public.create_league_v2_rpc(text, text, text, integer)
  to service_role;

revoke all on function public.get_public_leagues_rpc(integer, timestamptz, uuid, text)
  from public;
revoke all on function public.get_public_leagues_rpc(integer, timestamptz, uuid, text)
  from anon;
grant execute on function public.get_public_leagues_rpc(integer, timestamptz, uuid, text)
  to authenticated;
grant execute on function public.get_public_leagues_rpc(integer, timestamptz, uuid, text)
  to service_role;

revoke all on function public.get_public_league_context_rpc(uuid)
  from public;
revoke all on function public.get_public_league_context_rpc(uuid)
  from anon;
grant execute on function public.get_public_league_context_rpc(uuid)
  to authenticated;
grant execute on function public.get_public_league_context_rpc(uuid)
  to service_role;

commit;
