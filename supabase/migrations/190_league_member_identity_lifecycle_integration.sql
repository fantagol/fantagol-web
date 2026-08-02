-- FANTAGOL
-- Migration 190
-- League-Scoped Identity Membership Lifecycle Integration.
--
-- Enforces the invariant:
-- every newly created or reactivated league membership receives
-- one autonomous competitive identity profile in the same transaction.
--
-- Covered lifecycle paths:
--   - private/public league creation
--   - invite join
--   - public catalog join
--   - reinstatement/reactivation
--   - future membership insertion/reactivation paths
--
-- Existing RPC definitions remain unchanged.

create or replace function
public.ensure_league_member_identity_lifecycle_trigger()
returns trigger
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_league_visibility text;
  v_bootstrap_source text;
  v_profile_id uuid;
begin
  -- Identity creation is required when a membership becomes active.
  if new.status <> 'active' then
    return new;
  end if;

  -- Avoid unnecessary work for updates that do not represent activation.
  if tg_op = 'UPDATE'
     and old.status is not distinct from new.status
     and exists (
       select 1
       from public.league_member_profiles lmp
       where lmp.league_member_id = new.id
     ) then
    return new;
  end if;

  select l.visibility
  into v_league_visibility
  from public.leagues l
  where l.id = new.league_id;

  if tg_op = 'UPDATE' then
    v_bootstrap_source := 'reinstatement';

  elsif new.role = 'admin' then
    v_bootstrap_source := 'manual_creation';

  elsif v_league_visibility = 'public' then
    v_bootstrap_source := 'public_join';

  else
    v_bootstrap_source := 'invite_join';
  end if;

  v_profile_id :=
    public.ensure_league_member_profile_internal(
      new.id,
      v_bootstrap_source
    );

  if v_profile_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_IDENTITY_LIFECYCLE_PROFILE_NOT_CREATED',
      detail =
        jsonb_build_object(
          'league_member_id', new.id,
          'league_id', new.league_id,
          'operation', tg_op,
          'bootstrap_source', v_bootstrap_source
        )::text;
  end if;

  return new;
end;
$function$;

drop trigger if exists
  ensure_league_member_identity_lifecycle
on public.league_members;

create trigger ensure_league_member_identity_lifecycle
after insert or update of status
on public.league_members
for each row
when (new.status = 'active')
execute function
  public.ensure_league_member_identity_lifecycle_trigger();

-- Close the transition window between migration 187 and migration 190.
-- Beta testers may have created memberships after the original backfill.
do $reconciliation$
declare
  v_membership record;
  v_profile_id uuid;
  v_reconciled_count integer := 0;
begin
  for v_membership in
    select
      lm.id as league_member_id
    from public.league_members lm
    left join public.league_member_profiles lmp
      on lmp.league_member_id = lm.id
    where lmp.id is null
    order by lm.joined_at, lm.id
  loop
    v_profile_id :=
      public.ensure_league_member_profile_internal(
        v_membership.league_member_id,
        'migration'
      );

    if v_profile_id is null then
      raise exception using
        errcode = 'P0001',
        message = 'LEAGUE_IDENTITY_LIFECYCLE_RECONCILIATION_FAILED',
        detail =
          jsonb_build_object(
            'league_member_id',
            v_membership.league_member_id
          )::text;
    end if;

    v_reconciled_count := v_reconciled_count + 1;
  end loop;

  raise notice
    'LEAGUE_IDENTITY_LIFECYCLE_RECONCILED_COUNT=%',
    v_reconciled_count;
end;
$reconciliation$;

revoke all
on function
  public.ensure_league_member_identity_lifecycle_trigger()
from public, anon, authenticated;

comment on function
public.ensure_league_member_identity_lifecycle_trigger() is
  'Guarantees one autonomous league-scoped identity profile whenever a membership is inserted or reactivated.';

do $certification$
declare
  v_missing_profile_count bigint;
  v_duplicate_profile_count bigint;
  v_trigger_count bigint;
begin
  select count(*)
  into v_missing_profile_count
  from public.league_members lm
  left join public.league_member_profiles lmp
    on lmp.league_member_id = lm.id
  where lmp.id is null;

  select count(*)
  into v_duplicate_profile_count
  from (
    select
      lmp.league_member_id
    from public.league_member_profiles lmp
    group by lmp.league_member_id
    having count(*) > 1
  ) duplicates;

  select count(*)
  into v_trigger_count
  from pg_trigger t
  where t.tgrelid = 'public.league_members'::regclass
    and t.tgname =
      'ensure_league_member_identity_lifecycle'
    and not t.tgisinternal;

  if v_missing_profile_count <> 0 then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_IDENTITY_LIFECYCLE_MISSING_PROFILES',
      detail =
        jsonb_build_object(
          'missing_profile_count',
          v_missing_profile_count
        )::text;
  end if;

  if v_duplicate_profile_count <> 0 then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_IDENTITY_LIFECYCLE_DUPLICATE_PROFILES',
      detail =
        jsonb_build_object(
          'duplicate_profile_count',
          v_duplicate_profile_count
        )::text;
  end if;

  if v_trigger_count <> 1 then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_IDENTITY_LIFECYCLE_TRIGGER_INVALID',
      detail =
        jsonb_build_object(
          'trigger_count',
          v_trigger_count
        )::text;
  end if;
end;
$certification$;

select
  case
    when to_regprocedure(
      'public.ensure_league_member_identity_lifecycle_trigger()'
    ) is not null
     and exists (
       select 1
       from pg_trigger t
       where t.tgrelid =
         'public.league_members'::regclass
         and t.tgname =
           'ensure_league_member_identity_lifecycle'
         and not t.tgisinternal
     )
     and not exists (
       select 1
       from public.league_members lm
       left join public.league_member_profiles lmp
         on lmp.league_member_id = lm.id
       where lmp.id is null
     )
      then 'PASS'
    else 'FAIL'
  end as league_identity_lifecycle_integration_certification;
