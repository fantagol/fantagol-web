-- FANTAGOL
-- ROUND SCORE SOURCE DIAGNOSTIC v1
--
-- Scopo:
-- 1. mostrare la definizione reale di get_my_round_predictions_rpc;
-- 2. individuare tutte le tabelle pubbliche che contengono i match della
--    giornata test e campi riconducibili a stato/risultato;
-- 3. verificare da quale sorgente arrivano status='finished' e i punteggi.
--
-- Script diagnostico: non modifica dati permanenti.
-- Esecuzione psql:
--   \i supabase/tests/ROUND_SCORE_SOURCE_DIAGNOSTIC_v1.sql

\set ON_ERROR_STOP on
\pset pager off

\echo ''
\echo '============================================================'
\echo ' FANTAGOL - ROUND SCORE SOURCE DIAGNOSTIC v1'
\echo '============================================================'

BEGIN;

\echo ''
\echo '=== 1. DEFINIZIONE RPC get_my_round_predictions_rpc ==='

SELECT
  n.nspname AS schema_name,
  p.proname AS function_name,
  pg_get_function_identity_arguments(p.oid) AS identity_arguments,
  pg_get_function_result(p.oid) AS return_type,
  pg_get_functiondef(p.oid) AS function_definition
FROM pg_proc p
JOIN pg_namespace n
  ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname = 'get_my_round_predictions_rpc'
ORDER BY p.oid;

\echo ''
\echo '=== 2. COLONNE CANDIDATE NELLO SCHEMA PUBLIC ==='

SELECT
  c.table_schema,
  c.table_name,
  string_agg(c.column_name, ', ' ORDER BY c.ordinal_position) AS relevant_columns
FROM information_schema.columns c
WHERE c.table_schema = 'public'
  AND c.column_name IN (
    'id',
    'match_id',
    'fixture_id',
    'provider_match_id',
    'external_match_id',
    'status',
    'match_status',
    'home_score',
    'away_score',
    'score_home',
    'score_away',
    'kickoff',
    'kickoff_at',
    'starts_at',
    'source',
    'provider',
    'is_official',
    'certified_at'
  )
GROUP BY c.table_schema, c.table_name
HAVING bool_or(c.column_name IN ('match_id', 'fixture_id', 'provider_match_id', 'external_match_id', 'id'))
   AND (
     bool_or(c.column_name IN ('home_score', 'away_score', 'score_home', 'score_away'))
     OR bool_or(c.column_name IN ('status', 'match_status'))
   )
ORDER BY c.table_name;

\echo ''
\echo '=== 3. RICERCA DINAMICA DEI 10 MATCH IN TUTTE LE TABELLE CANDIDATE ==='

CREATE TEMP TABLE fantagol_score_source_audit (
  source_schema text NOT NULL,
  source_table text NOT NULL,
  identifier_column text NOT NULL,
  row_data jsonb NOT NULL
) ON COMMIT DROP;

DO $audit$
DECLARE
  candidate record;
  identifier_column text;
  sql_statement text;
  target_ids uuid[] := ARRAY[
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
BEGIN
  FOR candidate IN
    SELECT DISTINCT
      c.table_schema,
      c.table_name
    FROM information_schema.columns c
    WHERE c.table_schema = 'public'
      AND c.table_name NOT LIKE 'pg_%'
      AND EXISTS (
        SELECT 1
        FROM information_schema.columns idc
        WHERE idc.table_schema = c.table_schema
          AND idc.table_name = c.table_name
          AND idc.column_name IN (
            'match_id',
            'fixture_id',
            'provider_match_id',
            'external_match_id',
            'id'
          )
      )
      AND EXISTS (
        SELECT 1
        FROM information_schema.columns sc
        WHERE sc.table_schema = c.table_schema
          AND sc.table_name = c.table_name
          AND sc.column_name IN (
            'status',
            'match_status',
            'home_score',
            'away_score',
            'score_home',
            'score_away'
          )
      )
    ORDER BY c.table_schema, c.table_name
  LOOP
    SELECT x.column_name
    INTO identifier_column
    FROM (
      SELECT
        ic.column_name,
        CASE ic.column_name
          WHEN 'match_id' THEN 1
          WHEN 'fixture_id' THEN 2
          WHEN 'provider_match_id' THEN 3
          WHEN 'external_match_id' THEN 4
          WHEN 'id' THEN 5
          ELSE 99
        END AS priority
      FROM information_schema.columns ic
      WHERE ic.table_schema = candidate.table_schema
        AND ic.table_name = candidate.table_name
        AND ic.column_name IN (
          'match_id',
          'fixture_id',
          'provider_match_id',
          'external_match_id',
          'id'
        )
        AND ic.data_type = 'uuid'
    ) x
    ORDER BY x.priority
    LIMIT 1;

    IF identifier_column IS NULL THEN
      CONTINUE;
    END IF;

    sql_statement := format(
      'INSERT INTO fantagol_score_source_audit
         (source_schema, source_table, identifier_column, row_data)
       SELECT %L, %L, %L, to_jsonb(t)
       FROM %I.%I t
       WHERE t.%I = ANY ($1)',
      candidate.table_schema,
      candidate.table_name,
      identifier_column,
      candidate.table_schema,
      candidate.table_name,
      identifier_column
    );

    BEGIN
      EXECUTE sql_statement USING target_ids;
    EXCEPTION
      WHEN insufficient_privilege THEN
        RAISE NOTICE 'Tabella %.% non leggibile dal ruolo corrente',
          candidate.table_schema,
          candidate.table_name;
      WHEN OTHERS THEN
        RAISE NOTICE 'Tabella %.% saltata: %',
          candidate.table_schema,
          candidate.table_name,
          SQLERRM;
    END;

    identifier_column := NULL;
  END LOOP;
END;
$audit$;

SELECT
  source_schema,
  source_table,
  identifier_column,
  COALESCE(
    row_data ->> 'match_id',
    row_data ->> 'fixture_id',
    row_data ->> 'provider_match_id',
    row_data ->> 'external_match_id',
    row_data ->> 'id'
  ) AS matched_identifier,
  COALESCE(row_data ->> 'match_status', row_data ->> 'status') AS status,
  COALESCE(row_data ->> 'home_score', row_data ->> 'score_home') AS home_score,
  COALESCE(row_data ->> 'away_score', row_data ->> 'score_away') AS away_score,
  COALESCE(
    row_data ->> 'kickoff',
    row_data ->> 'kickoff_at',
    row_data ->> 'starts_at'
  ) AS kickoff,
  COALESCE(row_data ->> 'provider', row_data ->> 'source') AS provider_or_source,
  row_data
FROM fantagol_score_source_audit
ORDER BY source_table, matched_identifier;

\echo ''
\echo '=== 4. TRIGGER SULLE TABELLE CHE CONTENGONO I MATCH ==='

SELECT DISTINCT
  a.source_schema,
  a.source_table,
  t.tgname AS trigger_name,
  pg_get_triggerdef(t.oid, true) AS trigger_definition
FROM fantagol_score_source_audit a
JOIN pg_class cls
  ON cls.relname = a.source_table
JOIN pg_namespace ns
  ON ns.oid = cls.relnamespace
 AND ns.nspname = a.source_schema
JOIN pg_trigger t
  ON t.tgrelid = cls.oid
WHERE NOT t.tgisinternal
ORDER BY a.source_table, t.tgname;

\echo ''
\echo '=== 5. FUNZIONI CHE CITANO home_score / away_score / match_status ==='

SELECT
  n.nspname AS schema_name,
  p.proname AS function_name,
  pg_get_function_identity_arguments(p.oid) AS identity_arguments
FROM pg_proc p
JOIN pg_namespace n
  ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND (
    pg_get_functiondef(p.oid) ILIKE '%home_score%'
    OR pg_get_functiondef(p.oid) ILIKE '%away_score%'
    OR pg_get_functiondef(p.oid) ILIKE '%match_status%'
  )
ORDER BY p.proname;

ROLLBACK;

\echo ''
\echo '============================================================'
\echo ' DIAGNOSTICA COMPLETATA - NESSUN DATO PERMANENTE MODIFICATO'
\echo '============================================================'
