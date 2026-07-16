-- ============================================================================
-- FANTAGOL
-- Migration 038: Prediction Score Runtime Service Access Hotfix
--
-- Purpose:
--   Allow trusted backend/service-role workflows to inspect runtime scoring
--   outputs created by the Prediction Resolution Engine.
--
-- Notes:
--   - service_role already has BYPASSRLS;
--   - no policy changes are required;
--   - authenticated users keep SELECT through RLS;
--   - anon and public remain denied.
-- ============================================================================

begin;

grant select
on table public.prediction_score_runtime_results
to service_role;

comment on table public.prediction_score_runtime_results is
'Mutable Prediction Resolution Engine outputs belonging to one Calculation Run. Authenticated members read through RLS; trusted service-role workflows may inspect all runtime outputs. Official history remains in round_certification_* tables.';

commit;
