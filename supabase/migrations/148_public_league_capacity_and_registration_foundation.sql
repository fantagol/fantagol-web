-- ============================================================================
-- FANTAGOL
-- MIGRATION 148
-- PUBLIC LEAGUE CAPACITY AND REGISTRATION FOUNDATION
--
-- Milestone 12.9.5.1
--
-- Purpose:
--   - introduce a finite administrator-selected capacity for public leagues;
--   - use 8 participants as the canonical initial capacity;
--   - allow values between 2 and 20;
--   - separate manual public registration state from roster_status;
--   - preserve the existing BYE and competitive schedule architecture.
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 1. PUBLIC LEAGUE CAPACITY AND REGISTRATION COLUMNS
-- ----------------------------------------------------------------------------

alter table public.leagues
  add column if not exists max_participants integer,
  add column if not exists public_registrations_open boolean;

comment on column public.leagues.max_participants
is
'Maximum number of active members accepted by a public league. Public leagues require a value between 2 and 20. Private leagues leave this field null.';

comment on column public.leagues.public_registrations_open
is
'Administrator-controlled public registration switch. It is independent from roster_status and is used only by public leagues.';

-- ----------------------------------------------------------------------------
-- 2. BACKFILL EXISTING LEAGUES
-- ----------------------------------------------------------------------------

update public.leagues
set
  max_participants = 8,
  public_registrations_open =
    case
      when roster_status = 'open'
        and lifecycle_status not in ('completed', 'archived')
        and status = 'active'
      then true
      else false
    end
where visibility = 'public'
  and (
    max_participants is null
    or public_registrations_open is null
  );

update public.leagues
set
  max_participants = null,
  public_registrations_open = null
where visibility <> 'public'
  and (
    max_participants is not null
    or public_registrations_open is not null
  );

-- ----------------------------------------------------------------------------
-- 3. PUBLIC-ONLY DATA CONTRACT
-- ----------------------------------------------------------------------------

alter table public.leagues
  drop constraint if exists leagues_public_capacity_contract_check;

alter table public.leagues
  add constraint leagues_public_capacity_contract_check
  check (
    (
      visibility = 'public'
      and max_participants between 2 and 20
      and public_registrations_open is not null
    )
    or
    (
      visibility <> 'public'
      and max_participants is null
      and public_registrations_open is null
    )
  );

comment on constraint leagues_public_capacity_contract_check
on public.leagues
is
'Public leagues require a finite capacity between 2 and 20 and an explicit administrator-controlled registration state. Private leagues do not use these fields.';

-- ----------------------------------------------------------------------------
-- 4. LOOKUP INDEX FOR OPEN PUBLIC LEAGUES
-- ----------------------------------------------------------------------------

create index if not exists leagues_public_registration_catalog_idx
on public.leagues (
  public_registrations_open,
  created_at desc,
  id
)
where visibility = 'public'
  and status = 'active'
  and lifecycle_status not in ('completed', 'archived');

-- ----------------------------------------------------------------------------
-- 5. PROTECT CAPACITY AGAINST EXISTING ACTIVE MEMBERS
-- ----------------------------------------------------------------------------

create or replace function public.enforce_public_league_capacity_update()
returns trigger
language plpgsql
security definer
set search_path to public
as $function$
declare
  v_active_member_count integer;
begin
  if new.visibility <> 'public' then
    return new;
  end if;

  if new.max_participants is null
     or new.max_participants < 2
     or new.max_participants > 20 then
    raise exception using
      errcode = 'P0001',
      message = 'PUBLIC_LEAGUE_INVALID_MAX_PARTICIPANTS';
  end if;

  if tg_op = 'UPDATE'
     and new.max_participants is distinct from old.max_participants then
    select count(*)::integer
    into v_active_member_count
    from public.league_members lm
    where lm.league_id = new.id
      and lm.status = 'active';

    if new.max_participants < v_active_member_count then
      raise exception using
        errcode = 'P0001',
        message = 'PUBLIC_LEAGUE_CAPACITY_BELOW_ACTIVE_MEMBERS';
    end if;
  end if;

  return new;
end;
$function$;

drop trigger if exists
  leagues_enforce_public_capacity_update_trigger
on public.leagues;

create trigger leagues_enforce_public_capacity_update_trigger
before insert or update of
  visibility,
  max_participants
on public.leagues
for each row
execute function public.enforce_public_league_capacity_update();

comment on function public.enforce_public_league_capacity_update()
is
'Rejects invalid public league capacities and prevents an administrator from reducing capacity below the current number of active members.';

revoke all
on function public.enforce_public_league_capacity_update()
from public;

revoke all
on function public.enforce_public_league_capacity_update()
from anon;

revoke all
on function public.enforce_public_league_capacity_update()
from authenticated;

-- ----------------------------------------------------------------------------
-- 6. CERTIFICATION
-- ----------------------------------------------------------------------------

do $verification$
declare
  v_invalid_public_leagues bigint;
  v_invalid_private_leagues bigint;
  v_constraint_definition text;
begin
  select count(*)
  into v_invalid_public_leagues
  from public.leagues l
  where l.visibility = 'public'
    and (
      l.max_participants is null
      or l.max_participants < 2
      or l.max_participants > 20
      or l.public_registrations_open is null
    );

  if v_invalid_public_leagues <> 0 then
    raise exception
      'INVALID_PUBLIC_LEAGUE_CAPACITY_ROWS: %',
      v_invalid_public_leagues;
  end if;

  select count(*)
  into v_invalid_private_leagues
  from public.leagues l
  where l.visibility <> 'public'
    and (
      l.max_participants is not null
      or l.public_registrations_open is not null
    );

  if v_invalid_private_leagues <> 0 then
    raise exception
      'PRIVATE_LEAGUES_WITH_PUBLIC_CAPACITY_STATE: %',
      v_invalid_private_leagues;
  end if;

  select pg_get_constraintdef(c.oid)
  into v_constraint_definition
  from pg_constraint c
  where c.conrelid = 'public.leagues'::regclass
    and c.conname = 'leagues_public_capacity_contract_check';

  if v_constraint_definition is null then
    raise exception
      'PUBLIC_LEAGUE_CAPACITY_CONSTRAINT_MISSING';
  end if;

  if not exists (
    select 1
    from pg_trigger t
    where t.tgrelid = 'public.leagues'::regclass
      and t.tgname = 'leagues_enforce_public_capacity_update_trigger'
      and not t.tgisinternal
  ) then
    raise exception
      'PUBLIC_LEAGUE_CAPACITY_TRIGGER_MISSING';
  end if;

  raise notice
    'PUBLIC_LEAGUE_CAPACITY_AND_REGISTRATION_FOUNDATION_OK';
end;
$verification$;

commit;