-- ============================================================================
-- FANTAGOL
-- Migration 094
-- Riapertura controllata della finestra pronostici della Round 1
--
-- Contesto:
--   la Round 1 della lega E2E Certification 001 è stata bloccata artificialmente
--   durante la certificazione E2E, nonostante:
--     - opens_at sia già trascorso;
--     - lock_at coincida con il primo kickoff reale;
--     - il primo kickoff sia ancora futuro;
--     - tutti i 10 match siano nuovamente scheduled e privi di risultato.
--
-- Obiettivo:
--   - riportare la league_round a predictions_open;
--   - riportare i pronostici E2E da locked a submitted;
--   - azzerare esclusivamente locked_at;
--   - preservare valori, versioni, submitted_at, submitted_version e snapshot
--     ufficiale già presenti;
--   - lasciare al normale motore temporale il lock reale al kickoff.
-- ============================================================================

\set ON_ERROR_STOP on
\pset pager off
\timing on

BEGIN;

DO $migration$
DECLARE
  v_league_id uuid := '3fe7ff3e-7b73-4d54-b847-bce6046d96e7'::uuid;
  v_league_round_id uuid := '67ea2bc0-0db4-4faf-8343-397d14a02bd9'::uuid;
  v_fantagol_round_id uuid := '79a05325-b567-416a-bc29-ce9f5b3ad526'::uuid;
  v_prediction_count integer;
  v_match_count integer;
  v_first_kickoff timestamptz;
  v_lock_at timestamptz;
BEGIN
  -- --------------------------------------------------------------------------
  -- 1. Precondizioni rigide sulla lega e sulla giornata
  -- --------------------------------------------------------------------------

  IF NOT EXISTS (
    SELECT 1
    FROM public.leagues l
    WHERE l.id = v_league_id
      AND l.name = 'E2E Certification 001'
      AND l.status = 'active'
  ) THEN
    RAISE EXCEPTION 'MIGRATION_094_TARGET_LEAGUE_NOT_FOUND_OR_NOT_ACTIVE';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.league_rounds lr
    WHERE lr.id = v_league_round_id
      AND lr.league_id = v_league_id
      AND lr.fantagol_round_id = v_fantagol_round_id
      AND lr.league_round_number = 1
      AND lr.enabled = true
      AND lr.status = 'predictions_locked'
  ) THEN
    RAISE EXCEPTION
      'MIGRATION_094_TARGET_LEAGUE_ROUND_NOT_IN_EXPECTED_LOCKED_STATE';
  END IF;

  SELECT fr.lock_at
    INTO v_lock_at
  FROM public.fantagol_rounds fr
  WHERE fr.id = v_fantagol_round_id
    AND fr.sequence = 1;

  IF v_lock_at IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_094_ROUND_LOCK_AT_NOT_FOUND';
  END IF;

  SELECT
    count(*) FILTER (WHERE frm.removed_at IS NULL),
    min(m.kickoff) FILTER (WHERE frm.removed_at IS NULL)
  INTO
    v_match_count,
    v_first_kickoff
  FROM public.fantagol_round_matches frm
  JOIN public.matches m
    ON m.id = frm.match_id
  WHERE frm.fantagol_round_id = v_fantagol_round_id;

  IF v_match_count <> 10 THEN
    RAISE EXCEPTION
      'MIGRATION_094_ACTIVE_MATCH_COUNT_MISMATCH expected=10 actual=%',
      v_match_count;
  END IF;

  IF v_first_kickoff IS NULL OR v_lock_at <> v_first_kickoff THEN
    RAISE EXCEPTION
      'MIGRATION_094_LOCK_AT_DOES_NOT_MATCH_FIRST_KICKOFF lock_at=% first_kickoff=%',
      v_lock_at,
      v_first_kickoff;
  END IF;

  IF clock_timestamp() >= v_lock_at THEN
    RAISE EXCEPTION
      'MIGRATION_094_ABORTED_LOCK_TIME_ALREADY_REACHED lock_at=% now=%',
      v_lock_at,
      clock_timestamp();
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.matches m
    JOIN public.fantagol_round_matches frm
      ON frm.match_id = m.id
    WHERE frm.fantagol_round_id = v_fantagol_round_id
      AND frm.removed_at IS NULL
      AND (
        m.status <> 'scheduled'
        OR m.home_score IS NOT NULL
        OR m.away_score IS NOT NULL
      )
  ) THEN
    RAISE EXCEPTION
      'MIGRATION_094_MATCH_STATE_NOT_CLEAN_AND_SCHEDULED';
  END IF;

  -- --------------------------------------------------------------------------
  -- 2. Precondizioni sui pronostici
  -- --------------------------------------------------------------------------

  SELECT count(*)
    INTO v_prediction_count
  FROM public.predictions p
  WHERE p.league_round_id = v_league_round_id;

  IF v_prediction_count <> 30 THEN
    RAISE EXCEPTION
      'MIGRATION_094_PREDICTION_COUNT_MISMATCH expected=30 actual=%',
      v_prediction_count;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.predictions p
    WHERE p.league_round_id = v_league_round_id
      AND (
        p.status <> 'locked'
        OR p.locked_at IS NULL
        OR p.submitted_at IS NULL
        OR p.submitted_version IS NULL
        OR p.official_submitted_at IS NULL
      )
  ) THEN
    RAISE EXCEPTION
      'MIGRATION_094_PREDICTIONS_NOT_IN_EXPECTED_E2E_LOCKED_STATE';
  END IF;

  -- --------------------------------------------------------------------------
  -- 3. Riapertura controllata
  --
  -- Stato pre-lock corretto per pronostici già inviati:
  --   locked -> submitted
  --
  -- Non vengono modificati:
  --   home_prediction, away_prediction, version, submitted_at,
  --   submitted_version, official_submitted_at.
  -- --------------------------------------------------------------------------

  UPDATE public.predictions p
  SET
    status = 'submitted',
    locked_at = NULL
  WHERE p.league_round_id = v_league_round_id
    AND p.status = 'locked';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'MIGRATION_094_PREDICTION_REOPEN_UPDATED_ZERO_ROWS';
  END IF;

  UPDATE public.league_rounds lr
  SET status = 'predictions_open'
  WHERE lr.id = v_league_round_id
    AND lr.status = 'predictions_locked';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'MIGRATION_094_LEAGUE_ROUND_REOPEN_UPDATED_ZERO_ROWS';
  END IF;

  -- --------------------------------------------------------------------------
  -- 4. Postcondizioni transazionali
  -- --------------------------------------------------------------------------

  IF EXISTS (
    SELECT 1
    FROM public.predictions p
    WHERE p.league_round_id = v_league_round_id
      AND (
        p.status <> 'submitted'
        OR p.locked_at IS NOT NULL
        OR p.submitted_at IS NULL
        OR p.submitted_version IS NULL
        OR p.official_submitted_at IS NULL
      )
  ) THEN
    RAISE EXCEPTION 'MIGRATION_094_PREDICTION_POSTCHECK_FAILED';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.league_rounds lr
    WHERE lr.id = v_league_round_id
      AND lr.status = 'predictions_open'
      AND lr.enabled = true
  ) THEN
    RAISE EXCEPTION 'MIGRATION_094_LEAGUE_ROUND_POSTCHECK_FAILED';
  END IF;
END;
$migration$;

COMMIT;

-- ============================================================================
-- POST-MIGRATION REPORT
-- ============================================================================

\echo ''
\echo '============================================================'
\echo ' MIGRATION 094 - POSTCHECK'
\echo '============================================================'

SELECT
  l.name AS league_name,
  lr.id AS league_round_id,
  lr.league_round_number,
  lr.status AS league_round_status,
  lr.enabled,
  fr.sequence,
  fr.status AS fantagol_round_status,
  fr.opens_at,
  fr.lock_at,
  clock_timestamp() < fr.lock_at AS before_lock,
  (
    lr.enabled
    AND lr.status = 'predictions_open'
    AND clock_timestamp() >= fr.opens_at
    AND clock_timestamp() < fr.lock_at
  ) AS expected_can_edit
FROM public.league_rounds lr
JOIN public.leagues l
  ON l.id = lr.league_id
JOIN public.fantagol_rounds fr
  ON fr.id = lr.fantagol_round_id
WHERE lr.id = '67ea2bc0-0db4-4faf-8343-397d14a02bd9'::uuid;

SELECT
  p.status,
  count(*) AS prediction_rows,
  count(*) FILTER (WHERE p.locked_at IS NULL) AS unlocked_rows,
  count(*) FILTER (WHERE p.submitted_at IS NOT NULL) AS submitted_at_rows,
  count(*) FILTER (WHERE p.submitted_version IS NOT NULL)
    AS submitted_version_rows,
  count(*) FILTER (WHERE p.official_submitted_at IS NOT NULL)
    AS official_submission_rows
FROM public.predictions p
WHERE p.league_round_id =
  '67ea2bc0-0db4-4faf-8343-397d14a02bd9'::uuid
GROUP BY p.status
ORDER BY p.status;

\echo ''
\echo 'MIGRATION 094 COMPLETATA'
