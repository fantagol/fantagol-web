-- FANTAGOL
-- Migration 188
-- League-Scoped Identity Read Model Foundation.
--
-- Adds:
--   - canonical internal identity view
--   - authenticated personal identity RPC
--   - league member identity RPC
--   - current league members v2 RPC
--
-- Does not replace legacy RPCs.

create or replace view public.league_member_identity_v1
with (security_invoker = true)
as
select
  lmp.id as league_member_profile_id,
  lmp.league_member_id,

  lm.league_id,
  lm.user_id,
  lm.role as membership_role,
  lm.status as membership_status,
  lm.joined_at,

  lmp.display_name,
  lmp.club_name,
  lmp.real_name,
  lmp.motto,

  lmp.avatar_url,
  lmp.crest_url,
  lmp.avatar_zoom,
  lmp.avatar_x,
  lmp.avatar_y,

  lmp.kit_template,
  lmp.kit_primary_color,
  lmp.kit_secondary_color,
  lmp.kit_third_color,
  lmp.kit_logo_mode,
  lmp.kit_crest_position,

  lmp.stars_count,
  lmp.total_titles,

  lmp.profile_version,
  lmp.bootstrap_source,
  lmp.created_at as profile_created_at,
  lmp.updated_at as profile_updated_at
from public.league_members lm
join public.league_member_profiles lmp
  on lmp.league_member_id = lm.id;

comment on view public.league_member_identity_v1 is
  'Canonical league-scoped competitive identity read model. Internal authority for membership identity.';

revoke all
on public.league_member_identity_v1
from public, anon, authenticated;

create or replace function public.get_my_league_identity_rpc(
  target_league_id uuid
)
returns table (
  league_member_profile_id uuid,
  league_member_id uuid,
  league_id uuid,
  membership_role text,
  membership_status text,
  joined_at timestamptz,

  display_name text,
  club_name text,
  real_name text,
  motto text,

  avatar_url text,
  crest_url text,
  avatar_zoom numeric,
  avatar_x integer,
  avatar_y integer,

  kit_template text,
  kit_primary_color text,
  kit_secondary_color text,
  kit_third_color text,
  kit_logo_mode text,
  kit_crest_position text,

  stars_count integer,
  total_titles integer,

  profile_version integer,
  profile_updated_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_user_id uuid := auth.uid();
  v_membership_id uuid;
begin
  if v_user_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'AUTH_REQUIRED';
  end if;

  if target_league_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_REQUIRED';
  end if;

  select lm.id
  into v_membership_id
  from public.league_members lm
  where lm.league_id = target_league_id
    and lm.user_id = v_user_id
  order by
    case lm.status
      when 'active' then 0
      when 'suspended' then 1
      else 2
    end,
    lm.joined_at,
    lm.id
  limit 1;

  if v_membership_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_MEMBERSHIP_NOT_FOUND';
  end if;

  perform public.ensure_league_member_profile_internal(
    v_membership_id,
    'league_member_legacy'
  );

  return query
  select
    identity.league_member_profile_id,
    identity.league_member_id,
    identity.league_id,
    identity.membership_role,
    identity.membership_status,
    identity.joined_at,

    identity.display_name,
    identity.club_name,
    identity.real_name,
    identity.motto,

    identity.avatar_url,
    identity.crest_url,
    identity.avatar_zoom,
    identity.avatar_x,
    identity.avatar_y,

    identity.kit_template,
    identity.kit_primary_color,
    identity.kit_secondary_color,
    identity.kit_third_color,
    identity.kit_logo_mode,
    identity.kit_crest_position,

    identity.stars_count,
    identity.total_titles,

    identity.profile_version,
    identity.profile_updated_at
  from public.league_member_identity_v1 identity
  where identity.league_member_id = v_membership_id;
end;
$function$;

create or replace function public.get_league_member_identity_rpc(
  target_league_id uuid,
  target_league_member_id uuid
)
returns table (
  league_member_profile_id uuid,
  league_member_id uuid,
  league_id uuid,
  membership_role text,
  membership_status text,
  joined_at timestamptz,

  display_name text,
  club_name text,
  real_name text,
  motto text,

  avatar_url text,
  crest_url text,
  avatar_zoom numeric,
  avatar_x integer,
  avatar_y integer,

  kit_template text,
  kit_primary_color text,
  kit_secondary_color text,
  kit_third_color text,
  kit_logo_mode text,
  kit_crest_position text,

  stars_count integer,
  total_titles integer,

  profile_version integer,
  profile_updated_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_user_id uuid := auth.uid();
  v_requesting_membership_id uuid;
begin
  if v_user_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'AUTH_REQUIRED';
  end if;

  if target_league_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_REQUIRED';
  end if;

  if target_league_member_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_MEMBER_REQUIRED';
  end if;

  select lm.id
  into v_requesting_membership_id
  from public.league_members lm
  where lm.league_id = target_league_id
    and lm.user_id = v_user_id
    and lm.status in ('active', 'suspended')
  limit 1;

  if v_requesting_membership_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_ACCESS_DENIED';
  end if;

  if not exists (
    select 1
    from public.league_members lm
    where lm.id = target_league_member_id
      and lm.league_id = target_league_id
  ) then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_MEMBER_NOT_FOUND';
  end if;

  perform public.ensure_league_member_profile_internal(
    target_league_member_id,
    'league_member_legacy'
  );

  return query
  select
    identity.league_member_profile_id,
    identity.league_member_id,
    identity.league_id,
    identity.membership_role,
    identity.membership_status,
    identity.joined_at,

    identity.display_name,
    identity.club_name,
    identity.real_name,
    identity.motto,

    identity.avatar_url,
    identity.crest_url,
    identity.avatar_zoom,
    identity.avatar_x,
    identity.avatar_y,

    identity.kit_template,
    identity.kit_primary_color,
    identity.kit_secondary_color,
    identity.kit_third_color,
    identity.kit_logo_mode,
    identity.kit_crest_position,

    identity.stars_count,
    identity.total_titles,

    identity.profile_version,
    identity.profile_updated_at
  from public.league_member_identity_v1 identity
  where identity.league_member_id =
    target_league_member_id;
end;
$function$;

create or replace function public.get_current_league_members_v2_rpc(
  target_league_id uuid
)
returns table (
  league_member_profile_id uuid,
  membership_id uuid,
  league_id uuid,
  user_id uuid,
  display_name text,
  club_name text,
  real_name text,
  motto text,
  role text,
  status text,
  joined_at timestamptz,

  avatar_url text,
  crest_url text,
  avatar_zoom numeric,
  avatar_x integer,
  avatar_y integer,

  kit_template text,
  kit_primary_color text,
  kit_secondary_color text,
  kit_third_color text,
  kit_logo_mode text,
  kit_crest_position text,

  stars_count integer,
  total_titles integer,
  profile_version integer
)
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_user_id uuid := auth.uid();
  v_membership record;
begin
  if v_user_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'AUTH_REQUIRED';
  end if;

  if target_league_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_REQUIRED';
  end if;

  if not exists (
    select 1
    from public.league_members lm
    where lm.league_id = target_league_id
      and lm.user_id = v_user_id
      and lm.status in ('active', 'suspended')
  ) then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_ACCESS_DENIED';
  end if;

  for v_membership in
    select lm.id
    from public.league_members lm
    where lm.league_id = target_league_id
    order by lm.joined_at, lm.id
  loop
    perform public.ensure_league_member_profile_internal(
      v_membership.id,
      'league_member_legacy'
    );
  end loop;

  return query
  select
    identity.league_member_profile_id,
    identity.league_member_id,
    identity.league_id,
    identity.user_id,
    identity.display_name,
    identity.club_name,
    identity.real_name,
    identity.motto,
    identity.membership_role,
    identity.membership_status,
    identity.joined_at,

    identity.avatar_url,
    identity.crest_url,
    identity.avatar_zoom,
    identity.avatar_x,
    identity.avatar_y,

    identity.kit_template,
    identity.kit_primary_color,
    identity.kit_secondary_color,
    identity.kit_third_color,
    identity.kit_logo_mode,
    identity.kit_crest_position,

    identity.stars_count,
    identity.total_titles,
    identity.profile_version
  from public.league_member_identity_v1 identity
  where identity.league_id = target_league_id
  order by
    case identity.membership_role
      when 'admin' then 0
      when 'vice' then 1
      else 2
    end,
    identity.joined_at,
    identity.league_member_id;
end;
$function$;

revoke all
on function public.get_my_league_identity_rpc(uuid)
from public, anon;

grant execute
on function public.get_my_league_identity_rpc(uuid)
to authenticated;

revoke all
on function public.get_league_member_identity_rpc(uuid, uuid)
from public, anon;

grant execute
on function public.get_league_member_identity_rpc(uuid, uuid)
to authenticated;

revoke all
on function public.get_current_league_members_v2_rpc(uuid)
from public, anon;

grant execute
on function public.get_current_league_members_v2_rpc(uuid)
to authenticated;

comment on function public.get_my_league_identity_rpc(uuid) is
  'Returns the authenticated user autonomous competitive identity for one league.';

comment on function public.get_league_member_identity_rpc(uuid, uuid) is
  'Returns one league-scoped member identity to an authorized member of the same league.';

comment on function public.get_current_league_members_v2_rpc(uuid) is
  'Returns canonical autonomous identities for all members of one league.';

select
  case
    when to_regclass(
      'public.league_member_identity_v1'
    ) is not null
     and to_regprocedure(
       'public.get_my_league_identity_rpc(uuid)'
     ) is not null
     and to_regprocedure(
       'public.get_league_member_identity_rpc(uuid,uuid)'
     ) is not null
     and to_regprocedure(
       'public.get_current_league_members_v2_rpc(uuid)'
     ) is not null
      then 'PASS'
    else 'FAIL'
  end as league_member_identity_read_model_certification;
