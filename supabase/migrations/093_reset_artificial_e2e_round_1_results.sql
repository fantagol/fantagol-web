-- ============================================================================
-- FANTAGOL
-- Migration 093
-- Reset controllato dei risultati artificiali E2E della Round 1
--
-- Obiettivo:
--   - preservare l'audit storico degli artefatti E2E;
--   - supersedere le certificazioni artificiali ancora attive;
--   - ripristinare i 10 match canonici allo stato pre-partita;
--   - permettere al provider reale di popolare successivamente stato e punteggi;
--   - evitare qualsiasi workaround nel frontend.
--
-- Non vengono eliminati:
--   - calendario e associazioni round-match;
--   - pronostici degli utenti;
--   - snapshot/certificazioni storiche immutabili;
--   - ricevute provider e prove E2E, che restano disponibili per audit.
-- ============================================================================

\set ON_ERROR_STOP on
\pset pager off

BEGIN;

DO $migration$
DECLARE
  v_target_ids uuid[] := ARRAY[
    '092a529a-b688-439a-80ac-ad5dd4bdd70b'::uuid,
    '177aa575-1acb-464b-b1b0-a6e55833408c'::uuid,
    '36a41f22-b012-4a98-a993-e36355710015'::uuid,
    '4448dca7-c334-4945-8c52-71966e60fe92'::uuid,
    '5e34f7c3-676b-4083-b3a2-32c116bbbb25'::uuid,
    'aa9ff4d8-566e-4e9c-96c0-eca9d56f6943'::uuid,
    'b75c8508-5b11-45e5-a660-662adda9f81f'::uuid,
    'be1fdfaf-f3db-45df-8046-c98e17739e7a'::uuid,
    'c1357fbd-8f31-45bb-bd4a-822022089e20'::uuid,
    'e4c1808a-ba6e-41d1-8d25-f7a90604d559'::uuid
  ];
  v_match_count integer;
  v_e2e_cert_count integer;
  v_non_e2e_active_cert_count integer;
  v_cert record;
  v_round_cert record;
BEGIN
  -- --------------------------------------------------------------------------
  -- 1. Precondizioni rigide
  -- --------------------------------------------------------------------------

  SELECT count(*)
    INTO v_match_count
  FROM public.matches m
  WHERE m.id = ANY (v_target_ids);

  IF v_match_count <> 10 THEN
    RAISE EXCEPTION
      'MIGRATION_093_TARGET_MATCH_COUNT_MISMATCH expected=10 actual=%',
      v_match_count;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.matches m
    WHERE m.id = ANY (v_target_ids)
      AND m.kickoff IS NOT NULL
      AND m.kickoff <= clock_timestamp()
  ) THEN
    RAISE EXCEPTION
      'MIGRATION_093_ABORTED_TARGET_MATCH_ALREADY_STARTED';
  END IF;

  SELECT count(*)
    INTO v_e2e_cert_count
  FROM public.match_result_certifications mrc
  WHERE mrc.match_id = ANY (v_target_ids)
    AND mrc.certified_by = 'fantagol-e2e-round-1';

  IF v_e2e_cert_count <> 10 THEN
    RAISE EXCEPTION
      'MIGRATION_093_E2E_CERTIFICATION_COUNT_MISMATCH expected=10 actual=%',
      v_e2e_cert_count;
  END IF;

  SELECT count(*)
    INTO v_non_e2e_active_cert_count
  FROM public.match_result_certifications mrc
  WHERE mrc.match_id = ANY (v_target_ids)
    AND mrc.status = 'official'
    AND mrc.certified_by <> 'fantagol-e2e-round-1';

  IF v_non_e2e_active_cert_count <> 0 THEN
    RAISE EXCEPTION
      'MIGRATION_093_NON_E2E_OFFICIAL_CERTIFICATION_FOUND count=%',
      v_non_e2e_active_cert_count;
  END IF;

  -- --------------------------------------------------------------------------
  -- 2. Supersede delle certificazioni match artificiali
  --
  -- Si usa l'RPC di dominio perché la tabella è protetta da immutabilità.
  -- --------------------------------------------------------------------------

  FOR v_cert IN
    SELECT mrc.id
    FROM public.match_result_certifications mrc
    WHERE mrc.match_id = ANY (v_target_ids)
      AND mrc.certified_by = 'fantagol-e2e-round-1'
      AND mrc.status = 'official'
    ORDER BY mrc.match_id
  LOOP
    PERFORM *
    FROM public.supersede_match_result_certification_rpc(
      v_cert.id,
      'migration_093_reset_artificial_e2e_round_1_results',
      gen_random_uuid()
    );
  END LOOP;

  -- --------------------------------------------------------------------------
  -- 3. Supersede delle certificazioni di round costruite sopra i risultati E2E
  --
  -- I contenuti certificati restano immutabili; viene applicata esclusivamente
  -- la transizione lifecycle ufficiale -> superseded prevista dal guard.
  -- --------------------------------------------------------------------------

  FOR v_round_cert IN
    SELECT DISTINCT rc.id
    FROM public.round_certifications rc
    JOIN public.round_certification_matches rcm
      ON rcm.certification_id = rc.id
    WHERE rcm.match_id = ANY (v_target_ids)
      AND rc.status = 'official'
      AND rc.active = true
  LOOP
    UPDATE public.round_certifications rc
    SET
      status = 'superseded',
      active = false,
      superseded_at = clock_timestamp()
    WHERE rc.id = v_round_cert.id;
  END LOOP;

  -- --------------------------------------------------------------------------
  -- 4. Reset dello stato runtime di readiness/certificazione match
  --
  -- La tabella è una proiezione mutabile; le certificazioni storiche restano
  -- invece conservate e supersedute.
  -- --------------------------------------------------------------------------

  IF to_regclass('public.match_certification_states') IS NOT NULL THEN
    DELETE FROM public.match_certification_states mcs
    WHERE mcs.match_id = ANY (v_target_ids);
  END IF;

  -- --------------------------------------------------------------------------
  -- 5. Reset canonico dei match
  --
  -- I trigger standard aggiornano version e updated_at. L'incremento di
  -- versione è desiderato: il reset è una nuova versione autorevole del match.
  -- --------------------------------------------------------------------------

  UPDATE public.matches m
  SET
    status = 'scheduled',
    home_score = NULL,
    away_score = NULL,
    minute = NULL,
    period = NULL,
    finalised_at = NULL,
    provider_updated_at = NULL
  WHERE m.id = ANY (v_target_ids);

  IF NOT FOUND THEN
    RAISE EXCEPTION 'MIGRATION_093_MATCH_RESET_UPDATED_ZERO_ROWS';
  END IF;

  -- --------------------------------------------------------------------------
  -- 6. Verifiche finali transazionali
  -- --------------------------------------------------------------------------

  IF EXISTS (
    SELECT 1
    FROM public.matches m
    WHERE m.id = ANY (v_target_ids)
      AND (
        m.status <> 'scheduled'
        OR m.home_score IS NOT NULL
        OR m.away_score IS NOT NULL
        OR m.minute IS NOT NULL
        OR m.period IS NOT NULL
        OR m.finalised_at IS NOT NULL
      )
  ) THEN
    RAISE EXCEPTION 'MIGRATION_093_MATCH_RESET_POSTCHECK_FAILED';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.match_result_certifications mrc
    WHERE mrc.match_id = ANY (v_target_ids)
      AND mrc.status = 'official'
  ) THEN
    RAISE EXCEPTION 'MIGRATION_093_ACTIVE_MATCH_CERTIFICATION_REMAINS';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.round_certifications rc
    JOIN public.round_certification_matches rcm
      ON rcm.certification_id = rc.id
    WHERE rcm.match_id = ANY (v_target_ids)
      AND rc.status = 'official'
      AND rc.active = true
  ) THEN
    RAISE EXCEPTION 'MIGRATION_093_ACTIVE_ROUND_CERTIFICATION_REMAINS';
  END IF;
END;
$migration$;

COMMIT;

-- ============================================================================
-- POST-MIGRATION REPORT
-- ============================================================================

\echo ''
\echo '============================================================'
\echo ' MIGRATION 093 - POSTCHECK'
\echo '============================================================'

SELECT
  m.id AS match_id,
  m.kickoff,
  m.status,
  m.home_score,
  m.away_score,
  m.minute,
  m.period,
  m.finalised_at,
  m.provider_updated_at,
  m.version
FROM public.matches m
WHERE m.id = ANY (ARRAY[
  '092a529a-b688-439a-80ac-ad5dd4bdd70b'::uuid,
  '177aa575-1acb-464b-b1b0-a6e55833408c'::uuid,
  '36a41f22-b012-4a98-a993-e36355710015'::uuid,
  '4448dca7-c334-4945-8c52-71966e60fe92'::uuid,
  '5e34f7c3-676b-4083-b3a2-32c116bbbb25'::uuid,
  'aa9ff4d8-566e-4e9c-96c0-eca9d56f6943'::uuid,
  'b75c8508-5b11-45e5-a660-662adda9f81f'::uuid,
  'be1fdfaf-f3db-45df-8046-c98e17739e7a'::uuid,
  'c1357fbd-8f31-45bb-bd4a-822022089e20'::uuid,
  'e4c1808a-ba6e-41d1-8d25-f7a90604d559'::uuid
])
ORDER BY m.id;

SELECT
  mrc.match_id,
  mrc.status,
  mrc.certified_by,
  mrc.certified_at,
  mrc.superseded_at,
  mrc.supersede_reason
FROM public.match_result_certifications mrc
WHERE mrc.match_id = ANY (ARRAY[
  '092a529a-b688-439a-80ac-ad5dd4bdd70b'::uuid,
  '177aa575-1acb-464b-b1b0-a6e55833408c'::uuid,
  '36a41f22-b012-4a98-a993-e36355710015'::uuid,
  '4448dca7-c334-4945-8c52-71966e60fe92'::uuid,
  '5e34f7c3-676b-4083-b3a2-32c116bbbb25'::uuid,
  'aa9ff4d8-566e-4e9c-96c0-eca9d56f6943'::uuid,
  'b75c8508-5b11-45e5-a660-662adda9f81f'::uuid,
  'be1fdfaf-f3db-45df-8046-c98e17739e7a'::uuid,
  'c1357fbd-8f31-45bb-bd4a-822022089e20'::uuid,
  'e4c1808a-ba6e-41d1-8d25-f7a90604d559'::uuid
])
ORDER BY mrc.match_id, mrc.certification_version;

\echo ''
\echo 'MIGRATION 093 COMPLETATA'
