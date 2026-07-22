-- ============================================================================
-- FANTAGOL
-- ROUND 1 PREDICTION WINDOW DIAGNOSTIC v2 v2
--
-- Scopo:
--   verificare perché la prima giornata risulta "locked" nonostante il kickoff
--   sia ancora futuro e stabilire se sia sufficiente riportare la league_round
--   a predictions_open.
--
-- Script esclusivamente diagnostico: non modifica alcun dato.
-- ============================================================================

\set ON_ERROR_STOP on
\pset pager off
\timing on

BEGIN TRANSACTION READ ONLY;

\echo ''
\echo '============================================================'
\echo ' FANTAGOL - ROUND 1 PREDICTION WINDOW DIAGNOSTIC v2'
\echo '============================================================'

\echo ''
\echo '=== 1. CLOCK DATABASE ==='

SELECT
  clock_timestamp() AS database_now,
  current_setting('TimeZone') AS database_timezone;

\echo ''
\echo '=== 2. FANTAGOL ROUND 1 ==='

SELECT
  fr.id AS fantagol_round_id,
  fr.sequence,
  fr.status AS fantagol_round_status,
  fr.opens_at,
  fr.lock_at,
  clock_timestamp() >= fr.opens_at AS already_open,
  clock_timestamp() < fr.lock_at AS before_lock,
  CASE
    WHEN clock_timestamp() < fr.opens_at THEN 'not_open'
    WHEN clock_timestamp() >= fr.lock_at THEN 'closed_by_time'
    ELSE 'inside_prediction_window'
  END AS time_window_state
FROM public.fantagol_rounds fr
WHERE fr.sequence = 1
ORDER BY fr.created_at DESC NULLS LAST, fr.id;

\echo ''
\echo '=== 3. LEAGUE ROUNDS COLLEGATI ALLA GIORNATA 1 ==='

SELECT
  l.id AS league_id,
  l.name AS league_name,
  l.status AS league_status,
  lr.id AS league_round_id,
  lr.league_round_number,
  lr.status AS league_round_status,
  lr.enabled,
  fr.id AS fantagol_round_id,
  fr.status AS fantagol_round_status,
  fr.opens_at,
  fr.lock_at,
  CASE
    WHEN NOT lr.enabled THEN 'disabled'
    WHEN lr.status IN (
      'predictions_locked',
      'live',
      'waiting_postponed',
      'final_calculable',
      'scoring',
      'official',
      'recalculated',
      'archived'
    ) THEN 'closed_by_league_round_status'
    WHEN lr.status = 'cancelled' THEN 'cancelled'
    WHEN clock_timestamp() < fr.opens_at THEN 'not_open'
    WHEN clock_timestamp() >= fr.lock_at THEN 'closed_by_time'
    WHEN lr.status = 'predictions_open' THEN 'open'
    ELSE 'scheduled'
  END AS rpc_prediction_window_state,
  (
    lr.enabled
    AND lr.status = 'predictions_open'
    AND clock_timestamp() >= fr.opens_at
    AND clock_timestamp() < fr.lock_at
  ) AS rpc_can_edit
FROM public.league_rounds lr
JOIN public.leagues l
  ON l.id = lr.league_id
JOIN public.fantagol_rounds fr
  ON fr.id = lr.fantagol_round_id
WHERE lr.league_round_number = 1
ORDER BY l.name, lr.id;

\echo ''
\echo '=== 4. MATCH DELLA GIORNATA 1 E PRIMO KICKOFF ==='

SELECT
  fr.id AS fantagol_round_id,
  fr.sequence,
  count(*) FILTER (
    WHERE frm.removed_at IS NULL
  ) AS active_match_count,
  min(m.kickoff) FILTER (
    WHERE frm.removed_at IS NULL
  ) AS first_kickoff,
  max(m.kickoff) FILTER (
    WHERE frm.removed_at IS NULL
  ) AS last_kickoff,
  bool_and(
    m.status = 'scheduled'
    AND m.home_score IS NULL
    AND m.away_score IS NULL
  ) FILTER (
    WHERE frm.removed_at IS NULL
  ) AS all_matches_clean_and_scheduled
FROM public.fantagol_rounds fr
JOIN public.fantagol_round_matches frm
  ON frm.fantagol_round_id = fr.id
JOIN public.matches m
  ON m.id = frm.match_id
WHERE fr.sequence = 1
GROUP BY fr.id, fr.sequence
ORDER BY fr.id;

\echo ''
\echo '=== 5. CONFRONTO LOCK_AT / PRIMO KICKOFF ==='

WITH round_times AS (
  SELECT
    fr.id AS fantagol_round_id,
    fr.opens_at,
    fr.lock_at,
    min(m.kickoff) FILTER (
      WHERE frm.removed_at IS NULL
    ) AS first_kickoff
  FROM public.fantagol_rounds fr
  JOIN public.fantagol_round_matches frm
    ON frm.fantagol_round_id = fr.id
  JOIN public.matches m
    ON m.id = frm.match_id
  WHERE fr.sequence = 1
  GROUP BY fr.id, fr.opens_at, fr.lock_at
)
SELECT
  fantagol_round_id,
  opens_at,
  lock_at,
  first_kickoff,
  lock_at = first_kickoff AS lock_exactly_at_first_kickoff,
  extract(epoch FROM (first_kickoff - lock_at))::bigint
    AS seconds_between_lock_and_first_kickoff
FROM round_times
ORDER BY fantagol_round_id;

\echo ''
\echo '=== 6. PRONOSTICI ESISTENTI PER LE LEAGUE ROUND 1 ==='

SELECT
  l.name AS league_name,
  lr.id AS league_round_id,
  lr.status AS league_round_status,
  count(p.id) AS prediction_rows,
  count(*) FILTER (WHERE p.status = 'draft') AS draft_rows,
  count(*) FILTER (WHERE p.status = 'submitted') AS submitted_rows,
  count(*) FILTER (WHERE p.status = 'locked') AS locked_rows,
  count(*) FILTER (WHERE p.submitted_version IS NOT NULL)
    AS rows_with_official_submission
FROM public.league_rounds lr
JOIN public.leagues l
  ON l.id = lr.league_id
LEFT JOIN public.predictions p
  ON p.league_round_id = lr.id
WHERE lr.league_round_number = 1
GROUP BY l.name, lr.id, lr.status
ORDER BY l.name, lr.id;

\echo ''
\echo '=== 7. DIAGNOSI AUTOMATICA ==='

WITH state AS (
  SELECT
    l.name AS league_name,
    lr.id AS league_round_id,
    lr.status AS league_round_status,
    lr.enabled,
    fr.opens_at,
    fr.lock_at,
    min(m.kickoff) FILTER (
      WHERE frm.removed_at IS NULL
    ) AS first_kickoff
  FROM public.league_rounds lr
  JOIN public.leagues l
    ON l.id = lr.league_id
  JOIN public.fantagol_rounds fr
    ON fr.id = lr.fantagol_round_id
  LEFT JOIN public.fantagol_round_matches frm
    ON frm.fantagol_round_id = fr.id
   AND frm.removed_at IS NULL
  LEFT JOIN public.matches m
    ON m.id = frm.match_id
  WHERE lr.league_round_number = 1
  GROUP BY
    l.name,
    lr.id,
    lr.status,
    lr.enabled,
    fr.opens_at,
    fr.lock_at
)
SELECT
  league_name,
  league_round_id,
  league_round_status,
  enabled,
  opens_at,
  lock_at,
  first_kickoff,
  CASE
    WHEN NOT enabled THEN
      'ROUND_DISABLED'
    WHEN clock_timestamp() < opens_at THEN
      'CORRECT_NOT_YET_OPEN'
    WHEN clock_timestamp() >= lock_at THEN
      'CORRECTLY_CLOSED_BY_TIME'
    WHEN league_round_status = 'predictions_open' THEN
      'CORRECTLY_OPEN'
    WHEN league_round_status = 'predictions_locked' THEN
      'INCONSISTENT_LOCKED_BEFORE_LOCK_AT'
    ELSE
      'REVIEW_STATUS_' || league_round_status
  END AS diagnosis
FROM state
ORDER BY league_name, league_round_id;

ROLLBACK;

\echo ''
\echo '============================================================'
\echo ' DIAGNOSTIC COMPLETATO - NESSUN DATO MODIFICATO'
\echo '============================================================'
