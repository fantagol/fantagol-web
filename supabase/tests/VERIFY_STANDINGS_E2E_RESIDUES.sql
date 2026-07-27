-- FANTAGOL
-- VERIFICA SOLA LETTURA DEI RESIDUI E2E NELLE CLASSIFICHE DINAMICHE
-- Non modifica e non elimina alcun dato.

\set ON_ERROR_STOP on
\timing on

\echo ''
\echo '=== 1. LEGHE DISPONIBILI ==='

SELECT
    l.id AS league_id,
    l.name AS league_name,
    l.status AS league_status,
    l.created_at
FROM public.leagues AS l
ORDER BY l.created_at DESC NULLS LAST, l.name;

\echo ''
\echo '=== 2. GIORNATE DELLE LEGHE E STATO CORRENTE ==='

SELECT
    l.id AS league_id,
    l.name AS league_name,
    lr.id AS league_round_id,
    lr.round_number,
    lr.status AS league_round_status,
    lr.created_at,
    lr.updated_at
FROM public.league_rounds AS lr
JOIN public.leagues AS l
  ON l.id = lr.league_id
ORDER BY
    l.created_at DESC NULLS LAST,
    lr.round_number DESC NULLS LAST;

\echo ''
\echo '=== 3. STRUTTURA DELLE TABELLE DI SIMULAZIONE PRESENTI ==='

SELECT
    table_schema,
    table_name
FROM information_schema.tables
WHERE table_schema = 'public'
  AND (
      table_name ILIKE '%simulation%'
      OR table_name ILIKE '%standing%'
      OR table_name ILIKE '%ledger%'
      OR table_name ILIKE '%calculation_run%'
  )
ORDER BY table_name;

\echo ''
\echo '=== 4. COLONNE DELLE TABELLE DI SIMULAZIONE / CLASSIFICA ==='

SELECT
    table_name,
    ordinal_position,
    column_name,
    data_type,
    is_nullable
FROM information_schema.columns
WHERE table_schema = 'public'
  AND (
      table_name ILIKE '%simulation%'
      OR table_name ILIKE '%standing%'
      OR table_name ILIKE '%ledger%'
      OR table_name ILIKE '%calculation_run%'
  )
ORDER BY table_name, ordinal_position;

\echo ''
\echo '=== 5. ROUND SIMULATIONS ==='

DO $$
BEGIN
    IF to_regclass('public.round_simulations') IS NULL THEN
        RAISE NOTICE 'Tabella public.round_simulations non presente.';
        RETURN;
    END IF;
END
$$;

SELECT
    to_jsonb(rs) AS round_simulation_row
FROM public.round_simulations AS rs
ORDER BY
    COALESCE(
        NULLIF(to_jsonb(rs)->>'created_at', '')::timestamptz,
        '-infinity'::timestamptz
    ) DESC
LIMIT 100;

\echo ''
\echo '=== 6. EVENTI DELLE ROUND SIMULATIONS ==='

DO $$
BEGIN
    IF to_regclass('public.round_simulation_events') IS NULL THEN
        RAISE NOTICE 'Tabella public.round_simulation_events non presente.';
        RETURN;
    END IF;
END
$$;

SELECT
    to_jsonb(rse) AS round_simulation_event_row
FROM public.round_simulation_events AS rse
ORDER BY
    COALESCE(
        NULLIF(to_jsonb(rse)->>'created_at', '')::timestamptz,
        '-infinity'::timestamptz
    ) DESC
LIMIT 200;

\echo ''
\echo '=== 7. CALCULATION RUNS ==='

DO $$
BEGIN
    IF to_regclass('public.calculation_runs') IS NULL THEN
        RAISE NOTICE 'Tabella public.calculation_runs non presente.';
        RETURN;
    END IF;
END
$$;

SELECT
    to_jsonb(cr) AS calculation_run_row
FROM public.calculation_runs AS cr
ORDER BY
    COALESCE(
        NULLIF(to_jsonb(cr)->>'created_at', '')::timestamptz,
        '-infinity'::timestamptz
    ) DESC
LIMIT 100;

\echo ''
\echo '=== 8. RICERCA DI PAYLOAD CON RISULTATI 3-1 O DATI E2E ==='

DO $audit$
DECLARE
    item record;
    sql_text text;
    matched_count bigint;
BEGIN
    FOR item IN
        SELECT DISTINCT
            c.table_schema,
            c.table_name
        FROM information_schema.columns AS c
        WHERE c.table_schema = 'public'
          AND (
              c.table_name ILIKE '%simulation%'
              OR c.table_name ILIKE '%standing%'
              OR c.table_name ILIKE '%ledger%'
              OR c.table_name ILIKE '%calculation_run%'
          )
    LOOP
        sql_text := format(
            $query$
            SELECT count(*)
            FROM %I.%I AS source_row
            WHERE to_jsonb(source_row)::text ILIKE '%%e2e%%'
               OR to_jsonb(source_row)::text ILIKE '%%"goals_for": 3%%'
               OR to_jsonb(source_row)::text ILIKE '%%"goals_against": 1%%'
               OR to_jsonb(source_row)::text ILIKE '%%"projected_points": 3%%'
            $query$,
            item.table_schema,
            item.table_name
        );

        BEGIN
            EXECUTE sql_text INTO matched_count;

            IF matched_count > 0 THEN
                RAISE NOTICE
                    'Possibili residui: %.% -> % righe',
                    item.table_schema,
                    item.table_name,
                    matched_count;
            END IF;
        EXCEPTION
            WHEN OTHERS THEN
                RAISE NOTICE
                    'Tabella %.% non verificabile: %',
                    item.table_schema,
                    item.table_name,
                    SQLERRM;
        END;
    END LOOP;
END
$audit$;

\echo ''
\echo '=== 9. FUNZIONE READ MODEL CLASSIFICHE ==='

SELECT
    p.oid::regprocedure AS function_signature,
    pg_get_functiondef(p.oid) AS function_definition
FROM pg_proc AS p
JOIN pg_namespace AS n
  ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname = 'get_my_standings_preview_rpc';

\echo ''
\echo '=== VERIFICA COMPLETATA: NESSUN DATO MODIFICATO ==='
