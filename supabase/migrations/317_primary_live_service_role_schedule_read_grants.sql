-- ============================================================================
-- FANTAGOL - MIGRATION 317
-- PRIMARY-LIVE SERVICE_ROLE SCHEDULE READ GRANTS
--
-- Root cause:
-- primary-live admission reads league_schedule_versions and league_fixtures
-- through the service_role PostgREST client. RLS bypass alone is insufficient;
-- PostgreSQL table-level SELECT privileges are still required.
--
-- Scope:
--   * no schema change
--   * no policy change
--   * no client privilege change
--   * service_role read-only grants only
-- ============================================================================

BEGIN;

GRANT SELECT ON TABLE public.league_schedule_versions TO service_role;
GRANT SELECT ON TABLE public.league_fixtures TO service_role;

COMMIT;