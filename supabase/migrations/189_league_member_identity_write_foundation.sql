-- FANTAGOL
-- Migration 189
-- League-Scoped Competitive Identity Write Foundation.
--
-- Adds versioned, league-scoped writes for:
--   - competitive identity
--   - avatar / crest configuration
--   - kit configuration
--
-- This migration does not modify:
--   - clubs
--   - league_members legacy identity fields
--   - legacy profile RPCs
--   - frontend behavior

create or replace function public.update_my_league_identity_rpc(
  target_league_id uuid,
  expected_profile_version integer,

  new_display_name text,
  new_club_name text,
  new_real_name text,
  new_motto text,

  new_avatar_url text,
  new_crest_url text,
  new_avatar_zoom numeric,
  new_avatar_x integer,
  new_avatar_y integer
)
returns table (
  league_member_profile_id uuid,
  league_member_id uuid,
  league_id uuid,

  display_name text,
  club_name text,
  real_name text,
  motto text,

  avatar_url text,
  crest_url text,
  avatar_zoom numeric,
  avatar_x integer,
  avatar_y integer,

  profile_version integer,
  profile_updated_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_user_id uuid := auth.uid();

  v_membership public.league_members%rowtype;
  v_profile public.league_member_profiles%rowtype;

  v_normalized_display_name text;
  v_normalized_club_name text;
  v_normalized_real_name text;
  v_normalized_motto text;
  v_normalized_avatar_url text;
  v_normalized_crest_url text;

  v_display_name_changed boolean;
  v_avatar_changed boolean;
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

  if expected_profile_version is null
     or expected_profile_version <= 0 then
    raise exception using
      errcode = 'P0001',
      message = 'EXPECTED_PROFILE_VERSION_REQUIRED';
  end if;

  v_normalized_display_name :=
    nullif(trim(new_display_name), '');

  v_normalized_club_name :=
    nullif(trim(new_club_name), '');

  v_normalized_real_name :=
    nullif(trim(new_real_name), '');

  v_normalized_motto :=
    nullif(trim(new_motto), '');

  v_normalized_avatar_url :=
    nullif(trim(new_avatar_url), '');

  v_normalized_crest_url :=
    nullif(trim(new_crest_url), '');

  if v_normalized_display_name is null then
    raise exception using
      errcode = 'P0001',
      message = 'DISPLAY_NAME_REQUIRED';
  end if;

  if length(v_normalized_display_name) > 60 then
    raise exception using
      errcode = 'P0001',
      message = 'DISPLAY_NAME_TOO_LONG';
  end if;

  if v_normalized_club_name is null then
    raise exception using
      errcode = 'P0001',
      message = 'CLUB_NAME_REQUIRED';
  end if;

  if length(v_normalized_club_name) > 80 then
    raise exception using
      errcode = 'P0001',
      message = 'CLUB_NAME_TOO_LONG';
  end if;

  if v_normalized_real_name is not null
     and length(v_normalized_real_name) > 120 then
    raise exception using
      errcode = 'P0001',
      message = 'REAL_NAME_TOO_LONG';
  end if;

  if v_normalized_motto is not null
     and length(v_normalized_motto) > 160 then
    raise exception using
      errcode = 'P0001',
      message = 'MOTTO_TOO_LONG';
  end if;

  if new_avatar_zoom is null
     or new_avatar_zoom < 0.5
     or new_avatar_zoom > 4 then
    raise exception using
      errcode = 'P0001',
      message = 'INVALID_AVATAR_ZOOM';
  end if;

  if new_avatar_x is null
     or new_avatar_x < -100
     or new_avatar_x > 100 then
    raise exception using
      errcode = 'P0001',
      message = 'INVALID_AVATAR_X';
  end if;

  if new_avatar_y is null
     or new_avatar_y < -100
     or new_avatar_y > 100 then
    raise exception using
      errcode = 'P0001',
      message = 'INVALID_AVATAR_Y';
  end if;

  select lm.*
  into v_membership
  from public.league_members lm
  where lm.league_id = target_league_id
    and lm.user_id = v_user_id
    and lm.status = 'active'
  order by lm.joined_at, lm.id
  limit 1
  for update;

  if v_membership.id is null then
    raise exception using
      errcode = 'P0001',
      message = 'ACTIVE_LEAGUE_MEMBERSHIP_REQUIRED';
  end if;

  perform public.ensure_league_member_profile_internal(
    v_membership.id,
    'league_member_legacy'
  );

  select lmp.*
  into v_profile
  from public.league_member_profiles lmp
  where lmp.league_member_id = v_membership.id
  for update;

  if v_profile.id is null then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_IDENTITY_PROFILE_NOT_FOUND';
  end if;

  if v_profile.profile_version <> expected_profile_version then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_IDENTITY_VERSION_CONFLICT',
      detail =
        jsonb_build_object(
          'expected_profile_version',
          expected_profile_version,
          'current_profile_version',
          v_profile.profile_version
        )::text;
  end if;

  v_display_name_changed :=
    v_profile.display_name is distinct from
      v_normalized_display_name;

  v_avatar_changed :=
    v_profile.avatar_url is distinct from v_normalized_avatar_url
    or v_profile.crest_url is distinct from v_normalized_crest_url
    or v_profile.avatar_zoom is distinct from new_avatar_zoom
    or v_profile.avatar_x is distinct from new_avatar_x
    or v_profile.avatar_y is distinct from new_avatar_y;

  update public.league_member_profiles lmp
  set
    display_name = v_normalized_display_name,
    club_name = v_normalized_club_name,
    real_name = v_normalized_real_name,
    motto = v_normalized_motto,

    avatar_url = v_normalized_avatar_url,
    crest_url = v_normalized_crest_url,
    avatar_zoom = new_avatar_zoom,
    avatar_x = new_avatar_x,
    avatar_y = new_avatar_y,

    profile_version = lmp.profile_version + 1
  where lmp.id = v_profile.id
    and lmp.profile_version = expected_profile_version
  returning lmp.*
  into v_profile;

  if v_profile.id is null then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_IDENTITY_VERSION_CONFLICT';
  end if;

  insert into public.league_identity_events (
    league_id,
    league_member_id,
    profile_id,

    event_type,
    event_version,

    actor_user_id,
    actor_member_id,

    previous_version,
    new_version,

    payload
  )
  values (
    v_membership.league_id,
    v_membership.id,
    v_profile.id,

    'identity_updated',
    1,

    v_user_id,
    v_membership.id,

    expected_profile_version,
    v_profile.profile_version,

    jsonb_build_object(
      'display_name_changed',
      v_display_name_changed,

      'club_name',
      v_normalized_club_name,

      'real_name_present',
      v_normalized_real_name is not null,

      'motto_present',
      v_normalized_motto is not null,

      'avatar_changed',
      v_avatar_changed
    )
  );

  if v_avatar_changed then
    insert into public.league_identity_events (
      league_id,
      league_member_id,
      profile_id,

      event_type,
      event_version,

      actor_user_id,
      actor_member_id,

      previous_version,
      new_version,

      payload
    )
    values (
      v_membership.league_id,
      v_membership.id,
      v_profile.id,

      'avatar_updated',
      1,

      v_user_id,
      v_membership.id,

      expected_profile_version,
      v_profile.profile_version,

      jsonb_build_object(
        'avatar_url_present',
        v_normalized_avatar_url is not null,

        'crest_url_present',
        v_normalized_crest_url is not null,

        'avatar_zoom',
        new_avatar_zoom,

        'avatar_x',
        new_avatar_x,

        'avatar_y',
        new_avatar_y
      )
    );
  end if;

  return query
  select
    identity.league_member_profile_id,
    identity.league_member_id,
    identity.league_id,

    identity.display_name,
    identity.club_name,
    identity.real_name,
    identity.motto,

    identity.avatar_url,
    identity.crest_url,
    identity.avatar_zoom,
    identity.avatar_x,
    identity.avatar_y,

    identity.profile_version,
    identity.profile_updated_at
  from public.league_member_identity_v1 identity
  where identity.league_member_id = v_membership.id;
end;
$function$;

create or replace function public.update_my_league_kit_rpc(
  target_league_id uuid,
  expected_profile_version integer,

  new_kit_template text,
  new_kit_primary_color text,
  new_kit_secondary_color text,
  new_kit_third_color text,
  new_kit_logo_mode text,
  new_kit_crest_position text
)
returns table (
  league_member_profile_id uuid,
  league_member_id uuid,
  league_id uuid,

  kit_template text,
  kit_primary_color text,
  kit_secondary_color text,
  kit_third_color text,
  kit_logo_mode text,
  kit_crest_position text,

  profile_version integer,
  profile_updated_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_user_id uuid := auth.uid();

  v_membership public.league_members%rowtype;
  v_profile public.league_member_profiles%rowtype;

  v_kit_template text;
  v_primary_color text;
  v_secondary_color text;
  v_third_color text;
  v_logo_mode text;
  v_crest_position text;
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

  if expected_profile_version is null
     or expected_profile_version <= 0 then
    raise exception using
      errcode = 'P0001',
      message = 'EXPECTED_PROFILE_VERSION_REQUIRED';
  end if;

  v_kit_template :=
    nullif(trim(new_kit_template), '');

  v_primary_color :=
    upper(nullif(trim(new_kit_primary_color), ''));

  v_secondary_color :=
    upper(nullif(trim(new_kit_secondary_color), ''));

  v_third_color :=
    upper(nullif(trim(new_kit_third_color), ''));

  v_logo_mode :=
    nullif(trim(new_kit_logo_mode), '');

  v_crest_position :=
    nullif(trim(new_kit_crest_position), '');

  if v_kit_template is null then
    raise exception using
      errcode = 'P0001',
      message = 'KIT_TEMPLATE_REQUIRED';
  end if;

  if v_primary_color is null
     or v_primary_color !~ '^#[0-9A-F]{6}$' then
    raise exception using
      errcode = 'P0001',
      message = 'INVALID_PRIMARY_COLOR';
  end if;

  if v_secondary_color is null
     or v_secondary_color !~ '^#[0-9A-F]{6}$' then
    raise exception using
      errcode = 'P0001',
      message = 'INVALID_SECONDARY_COLOR';
  end if;

  if v_third_color is null
     or v_third_color !~ '^#[0-9A-F]{6}$' then
    raise exception using
      errcode = 'P0001',
      message = 'INVALID_THIRD_COLOR';
  end if;

  if v_logo_mode is null then
    raise exception using
      errcode = 'P0001',
      message = 'KIT_LOGO_MODE_REQUIRED';
  end if;

  if v_crest_position is null then
    raise exception using
      errcode = 'P0001',
      message = 'KIT_CREST_POSITION_REQUIRED';
  end if;

  select lm.*
  into v_membership
  from public.league_members lm
  where lm.league_id = target_league_id
    and lm.user_id = v_user_id
    and lm.status = 'active'
  order by lm.joined_at, lm.id
  limit 1
  for update;

  if v_membership.id is null then
    raise exception using
      errcode = 'P0001',
      message = 'ACTIVE_LEAGUE_MEMBERSHIP_REQUIRED';
  end if;

  perform public.ensure_league_member_profile_internal(
    v_membership.id,
    'league_member_legacy'
  );

  select lmp.*
  into v_profile
  from public.league_member_profiles lmp
  where lmp.league_member_id = v_membership.id
  for update;

  if v_profile.id is null then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_IDENTITY_PROFILE_NOT_FOUND';
  end if;

  if v_profile.profile_version <> expected_profile_version then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_IDENTITY_VERSION_CONFLICT',
      detail =
        jsonb_build_object(
          'expected_profile_version',
          expected_profile_version,
          'current_profile_version',
          v_profile.profile_version
        )::text;
  end if;

  update public.league_member_profiles lmp
  set
    kit_template = v_kit_template,
    kit_primary_color = v_primary_color,
    kit_secondary_color = v_secondary_color,
    kit_third_color = v_third_color,
    kit_logo_mode = v_logo_mode,
    kit_crest_position = v_crest_position,

    profile_version = lmp.profile_version + 1
  where lmp.id = v_profile.id
    and lmp.profile_version = expected_profile_version
  returning lmp.*
  into v_profile;

  if v_profile.id is null then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_IDENTITY_VERSION_CONFLICT';
  end if;

  insert into public.league_identity_events (
    league_id,
    league_member_id,
    profile_id,

    event_type,
    event_version,

    actor_user_id,
    actor_member_id,

    previous_version,
    new_version,

    payload
  )
  values (
    v_membership.league_id,
    v_membership.id,
    v_profile.id,

    'kit_updated',
    1,

    v_user_id,
    v_membership.id,

    expected_profile_version,
    v_profile.profile_version,

    jsonb_build_object(
      'kit_template',
      v_kit_template,

      'kit_primary_color',
      v_primary_color,

      'kit_secondary_color',
      v_secondary_color,

      'kit_third_color',
      v_third_color,

      'kit_logo_mode',
      v_logo_mode,

      'kit_crest_position',
      v_crest_position
    )
  );

  return query
  select
    identity.league_member_profile_id,
    identity.league_member_id,
    identity.league_id,

    identity.kit_template,
    identity.kit_primary_color,
    identity.kit_secondary_color,
    identity.kit_third_color,
    identity.kit_logo_mode,
    identity.kit_crest_position,

    identity.profile_version,
    identity.profile_updated_at
  from public.league_member_identity_v1 identity
  where identity.league_member_id = v_membership.id;
end;
$function$;

revoke all
on function public.update_my_league_identity_rpc(
  uuid,
  integer,
  text,
  text,
  text,
  text,
  text,
  text,
  numeric,
  integer,
  integer
)
from public, anon;

grant execute
on function public.update_my_league_identity_rpc(
  uuid,
  integer,
  text,
  text,
  text,
  text,
  text,
  text,
  numeric,
  integer,
  integer
)
to authenticated;

revoke all
on function public.update_my_league_kit_rpc(
  uuid,
  integer,
  text,
  text,
  text,
  text,
  text,
  text
)
from public, anon;

grant execute
on function public.update_my_league_kit_rpc(
  uuid,
  integer,
  text,
  text,
  text,
  text,
  text,
  text
)
to authenticated;

comment on function public.update_my_league_identity_rpc(
  uuid,
  integer,
  text,
  text,
  text,
  text,
  text,
  text,
  numeric,
  integer,
  integer
) is
  'Versioned update of the authenticated member competitive identity in one league only.';

comment on function public.update_my_league_kit_rpc(
  uuid,
  integer,
  text,
  text,
  text,
  text,
  text,
  text
) is
  'Versioned update of the authenticated member kit configuration in one league only.';

select
  case
    when to_regprocedure(
      'public.update_my_league_identity_rpc(uuid,integer,text,text,text,text,text,text,numeric,integer,integer)'
    ) is not null
     and to_regprocedure(
       'public.update_my_league_kit_rpc(uuid,integer,text,text,text,text,text,text)'
     ) is not null
      then 'PASS'
    else 'FAIL'
  end as league_identity_write_foundation_certification;
