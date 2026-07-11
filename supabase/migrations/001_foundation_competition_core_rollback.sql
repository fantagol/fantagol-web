-- ============================================================
-- FANTAGOL ROLLBACK 001 — FOUNDATION COMPETITION CORE (RC2)
--
-- WARNING:
--   Run only if the forward migration must be reverted before
--   later engines start depending on the new schema.
--
-- Preserves all original legacy tables and columns.
-- Removes only objects introduced by migration 001.
-- ============================================================

begin;

-- ------------------------------------------------------------
-- 1. VIEWS
-- ------------------------------------------------------------

drop view if exists public.competition_calendar_view;
drop view if exists public.upcoming_matches_view;
drop view if exists public.round_match_set_view;
drop view if exists public.current_fantagol_round_view;
drop view if exists public.competition_edition_overview_view;
drop view if exists public.active_competitions_view;

-- ------------------------------------------------------------
-- 2. TRIGGERS ON LEGACY TABLES
-- ------------------------------------------------------------

drop trigger if exists sync_official_match_set_version on public.match_set_versions;
drop trigger if exists protect_match_set_version_immutability on public.match_set_versions;
drop trigger if exists validate_match_set_version_write on public.match_set_versions;
drop trigger if exists validate_fantagol_round_match_write on public.fantagol_round_matches;
drop trigger if exists protect_fantagol_round_match_after_lock on public.fantagol_round_matches;

drop trigger if exists validate_fantagol_round_scope on public.fantagol_rounds;
drop trigger if exists validate_match_competition_scope on public.matches;
drop trigger if exists validate_provider_round_scope on public.provider_rounds;

drop trigger if exists increment_matches_version on public.matches;
drop trigger if exists set_matches_updated_at on public.matches;

drop trigger if exists increment_teams_version on public.teams;
drop trigger if exists set_teams_updated_at on public.teams;

-- ------------------------------------------------------------
-- 3. NEW TABLES (REVERSE FK ORDER)
-- ------------------------------------------------------------

drop table if exists public.competition_audit_log cascade;
drop table if exists public.team_aliases cascade;
drop table if exists public.match_set_versions cascade;
drop table if exists public.fantagol_round_matches cascade;
drop table if exists public.fantagol_rounds cascade;
drop table if exists public.provider_rounds cascade;
drop table if exists public.provider_entity_maps cascade;
drop table if exists public.data_providers cascade;
drop table if exists public.competition_teams cascade;
drop table if exists public.competition_stages cascade;
drop table if exists public.competition_editions cascade;
drop table if exists public.competitions cascade;
drop table if exists public.sports cascade;

-- ------------------------------------------------------------
-- 4. LEGACY MATCH EXTENSION
-- ------------------------------------------------------------

alter table public.matches
  drop constraint if exists matches_finished_score_required_check,
  drop constraint if exists matches_version_positive_check,
  drop constraint if exists matches_away_score_nonnegative_check,
  drop constraint if exists matches_home_score_nonnegative_check,
  drop constraint if exists matches_minute_range_check,
  drop constraint if exists matches_teams_different_check,
  drop constraint if exists matches_provider_round_id_fkey,
  drop constraint if exists matches_stage_id_fkey,
  drop constraint if exists matches_edition_id_fkey;

drop index if exists public.matches_live_idx;
drop index if exists public.matches_active_idx;
drop index if exists public.matches_status_idx;
drop index if exists public.matches_kickoff_idx;
drop index if exists public.matches_provider_round_idx;
drop index if exists public.matches_stage_idx;
drop index if exists public.matches_edition_idx;

alter table public.matches
  drop column if exists version,
  drop column if exists updated_at,
  drop column if exists active,
  drop column if exists finalised_at,
  drop column if exists provider_updated_at,
  drop column if exists period,
  drop column if exists minute,
  drop column if exists venue_name,
  drop column if exists provider_round_id,
  drop column if exists stage_id,
  drop column if exists edition_id;

-- ------------------------------------------------------------
-- 5. LEGACY TEAM EXTENSION
-- ------------------------------------------------------------

alter table public.teams
  drop constraint if exists teams_version_positive_check,
  drop constraint if exists teams_team_type_check,
  drop constraint if exists teams_sport_id_fkey;

drop index if exists public.teams_active_idx;
drop index if exists public.teams_country_idx;
drop index if exists public.teams_type_idx;
drop index if exists public.teams_sport_idx;

alter table public.teams
  drop column if exists version,
  drop column if exists updated_at,
  drop column if exists active,
  drop column if exists crest_reference,
  drop column if exists federation_code,
  drop column if exists country_code,
  drop column if exists code,
  drop column if exists team_type,
  drop column if exists sport_id;

-- ------------------------------------------------------------
-- 6. FUNCTIONS INTRODUCED BY MIGRATION 001
-- ------------------------------------------------------------

drop function if exists public.validate_fantagol_round_structure(uuid);
drop function if exists public.compute_round_capabilities(uuid);
drop function if exists public.compute_round_lock_at(uuid);
drop function if exists public.get_round_match_count(uuid);
drop function if exists public.sync_official_match_set_version();
drop function if exists public.protect_match_set_version_immutability();
drop function if exists public.validate_match_set_version_write();
drop function if exists public.validate_fantagol_round_match_write();
drop function if exists public.protect_fantagol_round_match_after_lock();
drop function if exists public.validate_fantagol_round_scope();
drop function if exists public.validate_match_competition_scope();
drop function if exists public.validate_provider_round_scope();
drop function if exists public.increment_row_version();
drop function if exists public.set_updated_at();

commit;
