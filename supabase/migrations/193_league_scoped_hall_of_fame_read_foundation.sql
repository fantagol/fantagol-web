-- FANTAGOL
-- Migration 193
-- League-scoped Hall of Fame read foundation.
--
-- Mission:
--   - establish per-mode title counters on the league-scoped profile;
--   - expose a dedicated authenticated Hall of Fame read contract;
--   - preserve legacy aggregate total_titles without inventing a historical
--     per-mode distribution that the previous schema did not store.
--
-- Historical backfill:
--   The legacy clubs model persisted only stars_count and total_titles.
--   Therefore all mode-specific counters start at zero. This is intentional
--   and avoids fabricating historical attribution.

alter table public.league_member_profiles
  add column if not exists fantacalcio_titles integer not null default 0,
  add column if not exists one_to_one_titles integer not null default 0,
  add column if not exists punti_puri_titles integer not null default 0;

alter table public.league_member_profiles
  drop constraint if exists league_member_profiles_fantacalcio_titles_nonnegative;

alter table public.league_member_profiles
  add constraint league_member_profiles_fantacalcio_titles_nonnegative
  check (fantacalcio_titles >= 0);

alter table public.league_member_profiles
  drop constraint if exists league_member_profiles_one_to_one_titles_nonnegative;

alter table public.league_member_profiles
  add constraint league_member_profiles_one_to_one_titles_nonnegative
  check (one_to_one_titles >= 0);

alter table public.league_member_profiles
  drop constraint if exists league_member_profiles_punti_puri_titles_nonnegative;

alter table public.league_member_profiles
  add constraint league_member_profiles_punti_puri_titles_nonnegative
  check (punti_puri_titles >= 0);

comment on column
public.league_member_profiles.fantacalcio_titles is
  'Number of league-scoped Fantacalcio titles attributed to this League Member profile.';

comment on column
public.league_member_profiles.one_to_one_titles is
  'Number of league-scoped One-to-One titles attributed to this League Member profile.';

comment on column
public.league_member_profiles.punti_puri_titles is
  'Number of league-scoped Punti Puri titles attributed to this League Member profile.';

create or replace function
public.get_my_league_hall_of_fame_rpc(
  target_league_id uuid
)
returns table (
  league_member_profile_id uuid,
  league_member_id uuid,
  league_id uuid,
  display_name text,
  club_name text,
  stars_count integer,
  total_titles integer,
  fantacalcio_titles integer,
  one_to_one_titles integer,
  punti_puri_titles integer,
  profile_version integer,
  profile_updated_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
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
    and lm.status in ('active', 'suspended')
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

  if not exists (
    select 1
    from public.league_member_profiles lmp
    where lmp.league_member_id = v_membership_id
  ) then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_IDENTITY_PROFILE_NOT_FOUND';
  end if;

  return query
  select
    lmp.id,
    lm.id,
    lm.league_id,
    lmp.display_name,
    lmp.club_name,
    lmp.stars_count,
    lmp.total_titles,
    lmp.fantacalcio_titles,
    lmp.one_to_one_titles,
    lmp.punti_puri_titles,
    lmp.profile_version,
    lmp.updated_at
  from public.league_members lm
  join public.league_member_profiles lmp
    on lmp.league_member_id = lm.id
  where lm.id = v_membership_id;
end;
$function$;

revoke all
on function public.get_my_league_hall_of_fame_rpc(uuid)
from public, anon, authenticated;

grant execute
on function public.get_my_league_hall_of_fame_rpc(uuid)
to authenticated, service_role;

comment on function
public.get_my_league_hall_of_fame_rpc(uuid) is
  'Returns the authenticated member Hall of Fame counters for one league-scoped identity.';

do $certification$
begin
  if not exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'league_member_profiles'
      and column_name = 'fantacalcio_titles'
      and data_type = 'integer'
      and is_nullable = 'NO'
  ) then
    raise exception
      'HALL_OF_FAME_FANTACALCIO_COLUMN_MISSING';
  end if;

  if not exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'league_member_profiles'
      and column_name = 'one_to_one_titles'
      and data_type = 'integer'
      and is_nullable = 'NO'
  ) then
    raise exception
      'HALL_OF_FAME_ONE_TO_ONE_COLUMN_MISSING';
  end if;

  if not exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'league_member_profiles'
      and column_name = 'punti_puri_titles'
      and data_type = 'integer'
      and is_nullable = 'NO'
  ) then
    raise exception
      'HALL_OF_FAME_PUNTI_PURI_COLUMN_MISSING';
  end if;

  if to_regprocedure(
    'public.get_my_league_hall_of_fame_rpc(uuid)'
  ) is null then
    raise exception
      'HALL_OF_FAME_READ_RPC_MISSING';
  end if;

  if exists (
    select 1
    from public.league_member_profiles lmp
    where lmp.fantacalcio_titles < 0
       or lmp.one_to_one_titles < 0
       or lmp.punti_puri_titles < 0
  ) then
    raise exception
      'HALL_OF_FAME_NEGATIVE_COUNTER_DETECTED';
  end if;
end;
$certification$;

select
  case
    when to_regprocedure(
      'public.get_my_league_hall_of_fame_rpc(uuid)'
    ) is not null
    and not exists (
      select 1
      from public.league_member_profiles lmp
      where lmp.fantacalcio_titles < 0
         or lmp.one_to_one_titles < 0
         or lmp.punti_puri_titles < 0
    )
      then 'PASS'
    else 'FAIL'
  end as league_scoped_hall_of_fame_read_foundation_certification;
