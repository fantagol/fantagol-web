-- FANTAGOL
-- Migration 186
-- League-Scoped Competitive Identity Foundation.
--
-- Scope:
--   - league_member_profiles
--   - league_identity_events
--   - internal idempotent bootstrap helper
--   - ownership-safe RLS baseline
--
-- This migration is additive:
--   - no legacy data is modified
--   - no backfill is executed
--   - no existing RPC is replaced
--   - no frontend behavior changes

create table public.league_member_profiles (
  id uuid primary key default gen_random_uuid(),

  league_member_id uuid not null
    references public.league_members(id)
    on delete cascade,

  display_name text not null,
  club_name text not null,
  real_name text,
  motto text,

  avatar_url text,
  crest_url text,

  avatar_zoom numeric not null default 1,
  avatar_x integer not null default 0,
  avatar_y integer not null default 0,

  kit_template text not null default 'solid',
  kit_primary_color text not null default '#A6E824',
  kit_secondary_color text not null default '#111417',
  kit_third_color text not null default '#FFFFFF',
  kit_logo_mode text not null default 'center_horizontal',
  kit_crest_position text not null default 'left_chest',

  stars_count integer not null default 0,
  total_titles integer not null default 0,

  profile_version integer not null default 1,

  bootstrap_source text not null default 'platform_default',
  bootstrap_reference_id uuid,
  bootstrap_metadata jsonb not null default '{}'::jsonb,

  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),

  constraint league_member_profiles_member_unique
    unique (league_member_id),

  constraint league_member_profiles_display_name_check
    check (
      length(trim(display_name)) between 1 and 60
    ),

  constraint league_member_profiles_club_name_check
    check (
      length(trim(club_name)) between 1 and 80
    ),

  constraint league_member_profiles_real_name_check
    check (
      real_name is null
      or length(real_name) <= 120
    ),

  constraint league_member_profiles_motto_check
    check (
      motto is null
      or length(motto) <= 160
    ),

  constraint league_member_profiles_avatar_zoom_check
    check (
      avatar_zoom between 0.5 and 4
    ),

  constraint league_member_profiles_avatar_x_check
    check (
      avatar_x between -100 and 100
    ),

  constraint league_member_profiles_avatar_y_check
    check (
      avatar_y between -100 and 100
    ),

  constraint league_member_profiles_primary_color_check
    check (
      kit_primary_color ~ '^#[0-9A-Fa-f]{6}$'
    ),

  constraint league_member_profiles_secondary_color_check
    check (
      kit_secondary_color ~ '^#[0-9A-Fa-f]{6}$'
    ),

  constraint league_member_profiles_third_color_check
    check (
      kit_third_color ~ '^#[0-9A-Fa-f]{6}$'
    ),

  constraint league_member_profiles_stars_count_check
    check (
      stars_count >= 0
    ),

  constraint league_member_profiles_total_titles_check
    check (
      total_titles >= 0
    ),

  constraint league_member_profiles_version_check
    check (
      profile_version > 0
    ),

  constraint league_member_profiles_bootstrap_source_check
    check (
      bootstrap_source in (
        'league_member_legacy',
        'club_legacy',
        'last_league_identity',
        'platform_default',
        'manual_creation',
        'public_join',
        'invite_join',
        'reinstatement',
        'migration'
      )
    )
);

create index league_member_profiles_updated_idx
on public.league_member_profiles (
  updated_at desc,
  league_member_id
);

create table public.league_identity_events (
  id uuid primary key default gen_random_uuid(),

  league_id uuid not null
    references public.leagues(id)
    on delete cascade,

  league_member_id uuid not null
    references public.league_members(id)
    on delete cascade,

  profile_id uuid
    references public.league_member_profiles(id)
    on delete set null,

  event_type text not null,
  event_version integer not null default 1,

  actor_user_id uuid,

  actor_member_id uuid
    references public.league_members(id)
    on delete set null,

  previous_version integer,
  new_version integer,

  payload jsonb not null default '{}'::jsonb,

  correlation_id uuid,
  causation_id uuid,

  occurred_at timestamptz not null default clock_timestamp(),
  created_at timestamptz not null default clock_timestamp(),

  constraint league_identity_events_type_check
    check (
      event_type in (
        'profile_created',
        'profile_bootstrapped',
        'profile_migrated',
        'identity_updated',
        'kit_updated',
        'avatar_updated',
        'legacy_fallback_used',
        'profile_rebuilt',
        'profile_anonymized'
      )
    ),

  constraint league_identity_events_version_check
    check (
      event_version > 0
    ),

  constraint league_identity_events_profile_versions_check
    check (
      previous_version is null
      or new_version is null
      or new_version > previous_version
    )
);

create index league_identity_events_member_time_idx
on public.league_identity_events (
  league_member_id,
  occurred_at desc,
  id
);

create index league_identity_events_league_time_idx
on public.league_identity_events (
  league_id,
  occurred_at desc,
  id
);

create or replace function public.set_league_member_profile_updated_at()
returns trigger
language plpgsql
security definer
set search_path = public
as $function$
begin
  new.updated_at := clock_timestamp();

  return new;
end;
$function$;

create trigger set_league_member_profiles_updated_at
before update
on public.league_member_profiles
for each row
execute function public.set_league_member_profile_updated_at();

create or replace function public.ensure_league_member_profile_internal(
  target_league_member_id uuid,
  requested_bootstrap_source text default 'platform_default'
)
returns uuid
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_membership public.league_members%rowtype;
  v_legacy_club public.clubs%rowtype;

  v_account_avatar_url text;
  v_bootstrap_source text;
  v_profile_id uuid;
begin
  if target_league_member_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_MEMBER_REQUIRED';
  end if;

  v_bootstrap_source :=
    lower(
      coalesce(
        nullif(trim(requested_bootstrap_source), ''),
        'platform_default'
      )
    );

  if v_bootstrap_source not in (
    'league_member_legacy',
    'club_legacy',
    'last_league_identity',
    'platform_default',
    'manual_creation',
    'public_join',
    'invite_join',
    'reinstatement',
    'migration'
  ) then
    raise exception using
      errcode = 'P0001',
      message = 'INVALID_LEAGUE_IDENTITY_BOOTSTRAP_SOURCE';
  end if;

  select lm.*
  into v_membership
  from public.league_members lm
  where lm.id = target_league_member_id
  for update;

  if v_membership.id is null then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_MEMBER_NOT_FOUND';
  end if;

  select lmp.id
  into v_profile_id
  from public.league_member_profiles lmp
  where lmp.league_member_id = v_membership.id;

  if v_profile_id is not null then
    return v_profile_id;
  end if;

  if v_membership.club_id is not null then
    select c.*
    into v_legacy_club
    from public.clubs c
    where c.id = v_membership.club_id;
  end if;

  if v_membership.user_id is not null then
    select p.avatar_url
    into v_account_avatar_url
    from public.profiles p
    where p.id = v_membership.user_id;
  end if;

  insert into public.league_member_profiles (
    league_member_id,

    display_name,
    club_name,
    real_name,
    motto,

    avatar_url,
    crest_url,

    avatar_zoom,
    avatar_x,
    avatar_y,

    kit_template,
    kit_primary_color,
    kit_secondary_color,
    kit_third_color,
    kit_logo_mode,
    kit_crest_position,

    stars_count,
    total_titles,

    profile_version,

    bootstrap_source,
    bootstrap_reference_id,
    bootstrap_metadata
  )
  values (
    v_membership.id,

    coalesce(
      nullif(trim(v_membership.display_name), ''),
      nullif(trim(v_legacy_club.name), ''),
      'Giocatore'
    ),

    coalesce(
      nullif(trim(v_legacy_club.name), ''),
      nullif(trim(v_membership.display_name), ''),
      'FantaGol Club'
    ),

    nullif(trim(v_legacy_club.real_name), ''),
    nullif(trim(v_legacy_club.motto), ''),

    coalesce(
      nullif(trim(v_membership.avatar_url), ''),
      nullif(trim(v_legacy_club.crest_url), ''),
      nullif(trim(v_account_avatar_url), '')
    ),

    nullif(trim(v_legacy_club.crest_url), ''),

    coalesce(v_legacy_club.avatar_zoom, 1),
    coalesce(v_legacy_club.avatar_x, 0),
    coalesce(v_legacy_club.avatar_y, 0),

    coalesce(
      nullif(trim(v_membership.kit_pattern), ''),
      nullif(trim(v_legacy_club.kit_template), ''),
      'solid'
    ),

    coalesce(
      nullif(trim(v_membership.kit_primary_color), ''),
      nullif(trim(v_legacy_club.kit_primary_color), ''),
      '#A6E824'
    ),

    coalesce(
      nullif(trim(v_membership.kit_secondary_color), ''),
      nullif(trim(v_legacy_club.kit_secondary_color), ''),
      '#111417'
    ),

    coalesce(
      nullif(trim(v_legacy_club.kit_third_color), ''),
      '#FFFFFF'
    ),

    coalesce(
      nullif(trim(v_legacy_club.kit_logo_mode), ''),
      'center_horizontal'
    ),

    coalesce(
      nullif(trim(v_legacy_club.kit_crest_position), ''),
      'left_chest'
    ),

    greatest(
      coalesce(v_legacy_club.stars_count, 0),
      0
    ),

    greatest(
      coalesce(v_legacy_club.total_titles, 0),
      0
    ),

    1,

    v_bootstrap_source,
    v_membership.club_id,

    jsonb_build_object(
      'league_id',
      v_membership.league_id,

      'user_id',
      v_membership.user_id,

      'legacy_club_id',
      v_membership.club_id,

      'source_membership_display_name',
      v_membership.display_name
    )
  )
  on conflict (league_member_id)
  do nothing
  returning id
  into v_profile_id;

  if v_profile_id is null then
    select lmp.id
    into v_profile_id
    from public.league_member_profiles lmp
    where lmp.league_member_id = v_membership.id;

    return v_profile_id;
  end if;

  insert into public.league_identity_events (
    league_id,
    league_member_id,
    profile_id,

    event_type,
    event_version,

    actor_user_id,

    previous_version,
    new_version,

    payload
  )
  values (
    v_membership.league_id,
    v_membership.id,
    v_profile_id,

    'profile_bootstrapped',
    1,

    auth.uid(),

    null,
    1,

    jsonb_build_object(
      'bootstrap_source',
      v_bootstrap_source,

      'legacy_club_id',
      v_membership.club_id
    )
  );

  return v_profile_id;
end;
$function$;

alter table public.league_member_profiles
enable row level security;

alter table public.league_identity_events
enable row level security;

create policy league_member_profiles_select_own
on public.league_member_profiles
for select
to authenticated
using (
  exists (
    select 1
    from public.league_members lm
    where lm.id =
      league_member_profiles.league_member_id
      and lm.user_id = auth.uid()
  )
);

revoke all
on table public.league_member_profiles
from public, anon, authenticated;

revoke all
on table public.league_identity_events
from public, anon, authenticated;

grant select
on table public.league_member_profiles
to authenticated;

revoke all
on function public.ensure_league_member_profile_internal(uuid, text)
from public, anon, authenticated;

revoke all
on function public.set_league_member_profile_updated_at()
from public, anon, authenticated;

comment on table public.league_member_profiles is
  'League-scoped competitive identity. One autonomous profile per league membership.';

comment on table public.league_identity_events is
  'Append-only audit stream for league-scoped competitive identity lifecycle.';

comment on function public.ensure_league_member_profile_internal(uuid, text) is
  'Idempotently bootstraps one autonomous identity profile for a league membership. Internal backend use only.';

select
  case
    when to_regclass(
      'public.league_member_profiles'
    ) is not null
     and to_regclass(
       'public.league_identity_events'
     ) is not null
     and to_regprocedure(
       'public.ensure_league_member_profile_internal(uuid,text)'
     ) is not null
     and to_regprocedure(
       'public.set_league_member_profile_updated_at()'
     ) is not null
      then 'PASS'
    else 'FAIL'
  end as league_scoped_identity_foundation_certification;
