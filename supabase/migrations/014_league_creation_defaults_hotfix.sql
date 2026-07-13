-- ============================================================================
-- FANTAGOL 014 - LEAGUE CREATION DEFAULTS HOTFIX
-- Fixes:
--   * missing public.profiles rows for legacy auth users
--   * reliable last_active_league_id initialization from active membership
--   * automatic official scoring profile v1 when the league admin membership exists
-- ============================================================================

begin;

-- --------------------------------------------------------------------------
-- 1. Repair legacy authenticated users that have no public profile.
-- --------------------------------------------------------------------------

insert into public.profiles (
  id,
  email
)
select
  u.id,
  u.email
from auth.users u
where not exists (
  select 1
  from public.profiles p
  where p.id = u.id
)
on conflict (id) do nothing;

-- Initialize last_active_league_id for repaired/existing profiles when an
-- active membership exists and no active league is currently selected.
with latest_active_membership as (
  select distinct on (lm.user_id)
    lm.user_id,
    lm.league_id
  from public.league_members lm
  join public.leagues l
    on l.id = lm.league_id
  where lm.user_id is not null
    and lm.status = 'active'
    and l.status = 'active'
    and l.lifecycle_status <> 'archived'
  order by
    lm.user_id,
    lm.joined_at desc,
    lm.id desc
)
update public.profiles p
set last_active_league_id = lam.league_id
from latest_active_membership lam
where p.id = lam.user_id
  and p.last_active_league_id is null;

-- --------------------------------------------------------------------------
-- 2. Runtime guard for membership creation/reactivation.
--
-- Every active membership guarantees:
--   * a public profile exists;
--   * last_active_league_id points to the joined/rejoined league.
--
-- Every active admin membership additionally guarantees:
--   * league_scoring_profiles version 1 exists.
-- --------------------------------------------------------------------------

create or replace function public.ensure_league_membership_defaults()
returns trigger
language plpgsql
security definer
set search_path to public
as $function$
declare
  v_email text;
begin
  if new.user_id is not null and new.status = 'active' then
    select u.email
    into v_email
    from auth.users u
    where u.id = new.user_id;

    insert into public.profiles (
      id,
      email,
      last_active_league_id
    )
    values (
      new.user_id,
      v_email,
      new.league_id
    )
    on conflict (id) do update
    set
      email = coalesce(excluded.email, public.profiles.email),
      last_active_league_id = excluded.last_active_league_id;
  end if;

  if new.role = 'admin' and new.status = 'active' then
    insert into public.league_scoring_profiles (
      league_id,
      version,
      effective_from_league_round_id,
      created_by_member_id,
      reason,
      active
    )
    values (
      new.league_id,
      1,
      null,
      new.id,
      'Official default scoring profile created with league',
      true
    )
    on conflict (league_id, version) do nothing;
  end if;

  return new;
end;
$function$;

drop trigger if exists ensure_league_membership_defaults
on public.league_members;

create trigger ensure_league_membership_defaults
after insert or update of user_id, role, status
on public.league_members
for each row
execute function public.ensure_league_membership_defaults();

-- --------------------------------------------------------------------------
-- 3. Backfill scoring profile v1 for leagues already created before this fix.
-- --------------------------------------------------------------------------

insert into public.league_scoring_profiles (
  league_id,
  version,
  effective_from_league_round_id,
  created_by_member_id,
  reason,
  active
)
select
  l.id,
  1,
  null,
  admin_member.id,
  'Official default scoring profile backfilled by migration 014',
  true
from public.leagues l
left join lateral (
  select lm.id
  from public.league_members lm
  where lm.league_id = l.id
    and lm.role = 'admin'
    and lm.status = 'active'
  order by lm.joined_at, lm.id
  limit 1
) admin_member on true
where not exists (
  select 1
  from public.league_scoring_profiles lsp
  where lsp.league_id = l.id
    and lsp.version = 1
)
on conflict (league_id, version) do nothing;

-- --------------------------------------------------------------------------
-- 4. Permissions and installation audit.
-- --------------------------------------------------------------------------

revoke all on function public.ensure_league_membership_defaults()
from public, anon, authenticated;

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
  'league_creation_defaults_hotfix_installed',
  'competition_edition',
  '00000000-0000-4000-8000-000000000201'::uuid,
  null,
  jsonb_build_object(
    'profiles_backfilled', true,
    'last_active_league_repaired', true,
    'default_scoring_profile_runtime_guard', true
  ),
  'Repair missing profile initialization and default scoring profile creation',
  null
);

commit;
