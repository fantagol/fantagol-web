-- ============================================================================
-- FANTAGOL 015 - CURRENT LEAGUE MEMBERS READ RPC
-- Application Game Foundation / League Members Read Model
-- ============================================================================

begin;

create or replace function public.get_current_league_members_rpc(
  target_league_id uuid default null
)
returns table (
  membership_id uuid,
  league_id uuid,
  user_id uuid,
  display_name text,
  role text,
  status text,
  joined_at timestamptz,
  club_id uuid,
  club_name text,
  real_name text,
  crest_url text,
  kit_template text,
  kit_primary_color text,
  kit_secondary_color text,
  kit_third_color text,
  kit_logo_mode text,
  kit_crest_position text,
  stars_count integer
)
language plpgsql
stable
security definer
set search_path to public
as $function$
declare
  v_user_id uuid := auth.uid();
  v_league_id uuid;
begin
  if v_user_id is null then
    raise exception 'USER_NOT_AUTHENTICATED';
  end if;

  if target_league_id is not null then
    v_league_id := target_league_id;
  else
    select p.last_active_league_id
    into v_league_id
    from public.profiles p
    where p.id = v_user_id;
  end if;

  if v_league_id is null then
    raise exception 'ACTIVE_LEAGUE_NOT_FOUND';
  end if;

  if not exists (
    select 1
    from public.league_members current_member
    where current_member.league_id = v_league_id
      and current_member.user_id = v_user_id
      and current_member.status = 'active'
  ) then
    raise exception 'LEAGUE_MEMBERSHIP_REQUIRED';
  end if;

  return query
  select
    lm.id as membership_id,
    lm.league_id,
    lm.user_id,
    lm.display_name,
    lm.role,
    lm.status,
    lm.joined_at,
    c.id as club_id,
    coalesce(c.name, lm.display_name, 'Club FantaGol') as club_name,
    c.real_name,
    c.crest_url,
    coalesce(c.kit_template, 'solid') as kit_template,
    coalesce(c.kit_primary_color, '#FFFFFF') as kit_primary_color,
    coalesce(c.kit_secondary_color, '#A6E824') as kit_secondary_color,
    coalesce(c.kit_third_color, '#FFFFFF') as kit_third_color,
    coalesce(c.kit_logo_mode, 'center_horizontal') as kit_logo_mode,
    coalesce(c.kit_crest_position, 'left_chest') as kit_crest_position,
    coalesce(c.stars_count, 0) as stars_count
  from public.league_members lm
  left join public.clubs c
    on c.id = lm.club_id
  where lm.league_id = v_league_id
  order by
    case lm.role
      when 'admin' then 1
      when 'vice' then 2
      else 3
    end,
    lm.joined_at,
    lm.id;
end;
$function$;

revoke all on function public.get_current_league_members_rpc(uuid)
from public, anon;

grant execute on function public.get_current_league_members_rpc(uuid)
to authenticated;

insert into public.competition_audit_log (
  actor_id,
  action,
  aggregate_type,
  aggregate_id,
  before_json,
  after_json,
  reason,
  correlation_id
)
values (
  null,
  'current_league_members_read_rpc_installed',
  'competition_edition',
  '00000000-0000-4000-8000-000000000201'::uuid,
  null,
  jsonb_build_object(
    'rpc', 'get_current_league_members_rpc',
    'authenticated_only', true,
    'active_membership_required', true
  ),
  'Install authenticated league members read model',
  null
);

commit;
