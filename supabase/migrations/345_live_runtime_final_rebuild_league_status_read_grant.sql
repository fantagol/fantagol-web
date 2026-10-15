-- FANTAGOL - MIGRATION 345
-- R29-R17 / R94A FINAL REBUILD ACTIVE LEAGUE ELIGIBILITY
-- Grant the minimal read contract for the production-heartbeat service client.
-- Existing migrations 222 and 317 do not grant SELECT on public.leagues.
-- No RLS, schema, data, or write privilege changes.

BEGIN;

GRANT SELECT (id, status)
ON TABLE public.leagues
TO service_role;

COMMIT;
