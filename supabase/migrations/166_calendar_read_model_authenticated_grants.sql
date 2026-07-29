-- ============================================================================
-- FANTAGOL 166 — CALENDAR READ MODEL AUTHENTICATED GRANTS
-- ============================================================================
-- Scope:
--   * expose league calendar read-model tables to authenticated clients
--   * preserve row-level isolation through the existing member-scoped policies
--   * support /leghe/[id]/calendario for private and public leagues
--
-- Security:
--   * no anon grants
--   * no write grants
--   * RLS remains enabled
--   * existing policies remain authoritative
-- ============================================================================

begin;

-- --------------------------------------------------------------------------
-- 1. Structural preconditions.
-- --------------------------------------------------------------------------

do $$
begin
  if to_regclass('public.league_rounds') is null then
    raise exception using
      errcode = 'P0001',
      message = 'CALENDAR_READ_MODEL_LEAGUE_ROUNDS_NOT_FOUND';
  end if;

  if to_regclass('public.league_schedule_versions') is null then
    raise exception using
      errcode = 'P0001',
      message = 'CALENDAR_READ_MODEL_SCHEDULE_VERSIONS_NOT_FOUND';
  end if;

  if to_regclass('public.league_fixtures') is null then
    raise exception using
      errcode = 'P0001',
      message = 'CALENDAR_READ_MODEL_FIXTURES_NOT_FOUND';
  end if;
end;
$$;

-- --------------------------------------------------------------------------
-- 2. RLS preconditions.
-- --------------------------------------------------------------------------

do $$
declare
  v_table text;
  v_rls_enabled boolean;
begin
  foreach v_table in array array[
    'league_rounds',
    'league_schedule_versions',
    'league_fixtures'
  ]
  loop
    select c.relrowsecurity
      into v_rls_enabled
    from pg_catalog.pg_class c
    join pg_catalog.pg_namespace n
      on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname = v_table
      and c.relkind = 'r';

    if coalesce(v_rls_enabled, false) is not true then
      raise exception using
        errcode = 'P0001',
        message = format(
          'CALENDAR_READ_MODEL_RLS_NOT_ENABLED:%s',
          v_table
        );
    end if;
  end loop;
end;
$$;

-- --------------------------------------------------------------------------
-- 3. Member-scoped SELECT policy preconditions.
-- --------------------------------------------------------------------------

do $$
declare
  v_table text;
  v_policy_count integer;
begin
  foreach v_table in array array[
    'league_rounds',
    'league_schedule_versions',
    'league_fixtures'
  ]
  loop
    select count(*)::integer
      into v_policy_count
    from pg_catalog.pg_policies
    where schemaname = 'public'
      and tablename = v_table
      and cmd = 'SELECT'
      and (
        roles is null
        or roles && array['authenticated', 'public']::name[]
      );

    if v_policy_count = 0 then
      raise exception using
        errcode = 'P0001',
        message = format(
          'CALENDAR_READ_MODEL_SELECT_POLICY_NOT_FOUND:%s',
          v_table
        );
    end if;
  end loop;
end;
$$;

-- --------------------------------------------------------------------------
-- 4. Least-privilege table grants.
-- --------------------------------------------------------------------------

revoke all
on table
  public.league_rounds,
  public.league_schedule_versions,
  public.league_fixtures
from anon;

grant select
on table
  public.league_rounds,
  public.league_schedule_versions,
  public.league_fixtures
to authenticated;

-- No write privilege is introduced.
revoke insert, update, delete, truncate, references, trigger
on table
  public.league_rounds,
  public.league_schedule_versions,
  public.league_fixtures
from authenticated;

-- --------------------------------------------------------------------------
-- 5. Certification assertions.
-- --------------------------------------------------------------------------

do $$
declare
  v_table text;
begin
  foreach v_table in array array[
    'league_rounds',
    'league_schedule_versions',
    'league_fixtures'
  ]
  loop
    if not has_table_privilege(
      'authenticated',
      format('public.%I', v_table),
      'SELECT'
    ) then
      raise exception using
        errcode = 'P0001',
        message = format(
          'CALENDAR_READ_MODEL_AUTHENTICATED_SELECT_GRANT_FAILED:%s',
          v_table
        );
    end if;

    if has_table_privilege(
      'anon',
      format('public.%I', v_table),
      'SELECT'
    ) then
      raise exception using
        errcode = 'P0001',
        message = format(
          'CALENDAR_READ_MODEL_ANON_SELECT_GRANT_PRESENT:%s',
          v_table
        );
    end if;

    if has_table_privilege(
      'authenticated',
      format('public.%I', v_table),
      'INSERT,UPDATE,DELETE'
    ) then
      raise exception using
        errcode = 'P0001',
        message = format(
          'CALENDAR_READ_MODEL_UNEXPECTED_WRITE_GRANT:%s',
          v_table
        );
    end if;
  end loop;
end;
$$;

commit;

select
  table_name,
  has_table_privilege(
    'authenticated',
    format('public.%I', table_name),
    'SELECT'
  ) as authenticated_select,
  has_table_privilege(
    'anon',
    format('public.%I', table_name),
    'SELECT'
  ) as anon_select,
  has_table_privilege(
    'authenticated',
    format('public.%I', table_name),
    'INSERT'
  ) as authenticated_insert,
  has_table_privilege(
    'authenticated',
    format('public.%I', table_name),
    'UPDATE'
  ) as authenticated_update,
  has_table_privilege(
    'authenticated',
    format('public.%I', table_name),
    'DELETE'
  ) as authenticated_delete
from (
  values
    ('league_rounds'::text),
    ('league_schedule_versions'::text),
    ('league_fixtures'::text)
) as target(table_name)
order by table_name;

select
  schemaname,
  tablename,
  policyname,
  roles,
  cmd
from pg_catalog.pg_policies
where schemaname = 'public'
  and tablename in (
    'league_rounds',
    'league_schedule_versions',
    'league_fixtures'
  )
order by tablename, policyname;

select 'CALENDAR_READ_MODEL_AUTHENTICATED_GRANTS_PASS' as result;