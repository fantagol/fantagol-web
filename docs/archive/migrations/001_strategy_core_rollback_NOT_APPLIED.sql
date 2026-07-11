-- FANTAGOL MIGRATION 001 ROLLBACK
-- Use only if migration 001 must be fully reverted.

begin;

drop function if exists public.save_one_to_one_matrix_rpc(uuid, uuid[], uuid[]);
drop function if exists public.save_fantacalcio_strategy_rpc(uuid, uuid, uuid[], uuid[]);
drop function if exists public.is_matchday_open(uuid);
drop function if exists public.is_active_league_member(uuid, uuid);

drop table if exists public.one_to_one_matrix_entries cascade;
drop table if exists public.fantacalcio_allocations cascade;
drop table if exists public.league_fixtures cascade;
drop table if exists public.league_modes cascade;

drop trigger if exists set_matchdays_updated_at on public.matchdays;
drop trigger if exists set_matches_updated_at on public.matches;
drop function if exists public.set_updated_at();

drop index if exists public.matches_matchday_kickoff_idx;
drop index if exists public.matches_provider_external_unique_idx;
drop index if exists public.predictions_league_match_idx;
drop index if exists public.predictions_user_match_idx;

alter table public.predictions
  drop constraint if exists predictions_status_check,
  drop column if exists status,
  drop column if exists submitted_at,
  drop column if exists locked_at,
  drop column if exists version;

alter table public.matches
  drop constraint if exists matches_minute_check,
  drop column if exists provider_name,
  drop column if exists provider_match_id,
  drop column if exists minute,
  drop column if exists live_updated_at,
  drop column if exists result_version,
  drop column if exists updated_at;

alter table public.matchdays
  drop constraint if exists matchdays_status_check,
  drop column if exists lock_at,
  drop column if exists status,
  drop column if exists official_at,
  drop column if exists updated_at;

commit;
