begin;

-- ============================================================================
-- FANTAGOL
-- MIGRATION 278
-- TOP3 INTERNAL AUTHORITY PRIVILEGE HARDENING
--
-- Migration 277 intentionally enabled RLS and exposed no anon/authenticated
-- policies, but tables created by postgres inherited public-schema default
-- privileges that do not match this internal-runtime contract.
--
-- Authority:
--   - anon/authenticated: no table privileges;
--   - service_role: SELECT + INSERT only;
--   - postgres ownership remains unchanged;
--   - RLS remains enabled.
-- ============================================================================

revoke all privileges
on table
  public.community_top3_cohort_members,
  public.community_top3_expert_snapshots
from anon, authenticated, service_role;

grant select, insert
on table
  public.community_top3_cohort_members,
  public.community_top3_expert_snapshots
to service_role;

do $$
declare
  v_table text;
begin
  foreach v_table in array array[
    'public.community_top3_cohort_members',
    'public.community_top3_expert_snapshots'
  ]
  loop
    if has_table_privilege(
      'anon',
      v_table,
      'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER'
    ) then
      raise exception
        'MIGRATION_278_ANON_PRIVILEGE_REMAINS:%',
        v_table;
    end if;

    if has_table_privilege(
      'authenticated',
      v_table,
      'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER'
    ) then
      raise exception
        'MIGRATION_278_AUTHENTICATED_PRIVILEGE_REMAINS:%',
        v_table;
    end if;

    if not has_table_privilege(
      'service_role',
      v_table,
      'SELECT'
    ) then
      raise exception
        'MIGRATION_278_SERVICE_SELECT_MISSING:%',
        v_table;
    end if;

    if not has_table_privilege(
      'service_role',
      v_table,
      'INSERT'
    ) then
      raise exception
        'MIGRATION_278_SERVICE_INSERT_MISSING:%',
        v_table;
    end if;

    if has_table_privilege(
      'service_role',
      v_table,
      'UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER'
    ) then
      raise exception
        'MIGRATION_278_SERVICE_EXCESS_PRIVILEGE:%',
        v_table;
    end if;
  end loop;
end;
$$;

commit;