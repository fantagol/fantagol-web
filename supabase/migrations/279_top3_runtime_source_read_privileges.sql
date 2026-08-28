-- ============================================================================
-- FANTAGOL MIGRATION 279
-- TOP3 RUNTIME SOURCE READ PRIVILEGES
--
-- Purpose:
--   Allow the internal service-role Top3 runtime to read the three canonical
--   source tables that its V2 materializer requires.
--
-- Security contract:
--   - service_role receives SELECT only.
--   - no INSERT / UPDATE / DELETE is granted on these source tables.
--   - no privilege is granted to anon.
--   - no new privilege is granted to authenticated.
--   - existing Top3 internal-table hardening remains unchanged.
-- ============================================================================

begin;

grant select on table public.league_members to service_role;
grant select on table public.predictions to service_role;
grant select on table public.round_certifications to service_role;

do $migration_279$
begin
  if not has_table_privilege(
    'service_role',
    'public.league_members',
    'SELECT'
  ) then
    raise exception '279_SERVICE_SELECT_LEAGUE_MEMBERS_MISSING';
  end if;

  if not has_table_privilege(
    'service_role',
    'public.predictions',
    'SELECT'
  ) then
    raise exception '279_SERVICE_SELECT_PREDICTIONS_MISSING';
  end if;

  if not has_table_privilege(
    'service_role',
    'public.round_certifications',
    'SELECT'
  ) then
    raise exception '279_SERVICE_SELECT_ROUND_CERTIFICATIONS_MISSING';
  end if;

  if has_table_privilege(
    'service_role',
    'public.league_members',
    'INSERT,UPDATE,DELETE'
  ) then
    raise exception '279_EXCESS_WRITE_LEAGUE_MEMBERS';
  end if;

  if has_table_privilege(
    'service_role',
    'public.predictions',
    'INSERT,UPDATE,DELETE'
  ) then
    raise exception '279_EXCESS_WRITE_PREDICTIONS';
  end if;

  if has_table_privilege(
    'service_role',
    'public.round_certifications',
    'INSERT,UPDATE,DELETE'
  ) then
    raise exception '279_EXCESS_WRITE_ROUND_CERTIFICATIONS';
  end if;

  if has_table_privilege(
    'anon',
    'public.league_members',
    'SELECT'
  ) then
    raise exception '279_ANON_SELECT_LEAGUE_MEMBERS_UNEXPECTED';
  end if;

  if has_table_privilege(
    'anon',
    'public.predictions',
    'SELECT'
  ) then
    raise exception '279_ANON_SELECT_PREDICTIONS_UNEXPECTED';
  end if;

  if has_table_privilege(
    'anon',
    'public.round_certifications',
    'SELECT'
  ) then
    raise exception '279_ANON_SELECT_ROUND_CERTIFICATIONS_UNEXPECTED';
  end if;

  raise notice 'MIGRATION_279_TOP3_SOURCE_READ_PRIVILEGES=PASS';
end
$migration_279$;

commit;