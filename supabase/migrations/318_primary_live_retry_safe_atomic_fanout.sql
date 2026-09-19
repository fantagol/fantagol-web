-- ============================================================================
-- FANTAGOL - MIGRATION 318
-- PRIMARY-LIVE RETRY-SAFE ATOMIC OBSERVATION + FANOUT
--
-- Root cause closed:
-- the previous runtime committed the Tutto authority observation before
-- PostgREST admission / rebuild enqueue. A downstream failure could therefore
-- consume changed_fields; a retry would see the already-applied state and
-- complete with changed_fields=[] and no rebuild.
--
-- Contract:
-- record observation, classify change, resolve rebuildable league rounds, and
-- enqueue primary-live rebuild jobs in one PostgreSQL transaction boundary.
-- Any error rolls back the observation and authority mutation as well.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.record_primary_live_observation_fanout_v1_internal(
  p_match_id uuid,
  p_source_fixture_id text,
  p_observed_at timestamptz,
  p_source_status text,
  p_phase text,
  p_minute integer,
  p_home_score integer,
  p_away_score integer,
  p_terminal_hint boolean,
  p_payload_hash text,
  p_payload jsonb DEFAULT '{}'::jsonb,
  p_league_round_ids uuid[] DEFAULT '{}'::uuid[],
  p_fantagol_round_id uuid DEFAULT NULL,
  p_correlation_id uuid DEFAULT NULL,
  p_causation_id uuid DEFAULT NULL
)
RETURNS TABLE(
  observation_id uuid,
  authority_state_version bigint,
  effective_phase text,
  effective_minute integer,
  effective_home_score integer,
  effective_away_score integer,
  changed_fields text[],
  meaningful_change boolean,
  primary_live_rebuild_job_count integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_record record;
  v_authority public.live_match_authority_states%rowtype;
  v_input_count integer := 0;
  v_resolved_count integer := 0;
  v_rebuild_count integer := 0;
  v_enqueue_count integer := 0;
  v_league_round_id uuid;
BEGIN
  SELECT *
  INTO STRICT v_record
  FROM public.record_primary_live_observation_v3_internal(
    p_match_id,
    p_source_fixture_id,
    p_observed_at,
    p_source_status,
    p_phase,
    p_minute,
    p_home_score,
    p_away_score,
    p_terminal_hint,
    p_payload_hash,
    p_payload,
    p_correlation_id
  );

  SELECT *
  INTO STRICT v_authority
  FROM public.live_match_authority_states
  WHERE match_id = p_match_id;

  observation_id := v_record.observation_id;
  authority_state_version := v_record.authority_state_version;
  effective_phase := v_record.effective_phase;
  effective_minute := v_record.effective_minute;
  effective_home_score := v_record.effective_home_score;
  effective_away_score := v_record.effective_away_score;
  changed_fields := coalesce(v_record.changed_fields, '{}'::text[]);

  meaningful_change :=
    v_authority.authority = 'primary_live'
    AND v_authority.source = 'tuttoilcalcio'
    AND v_authority.phase <> 'PRE_MATCH'
    AND cardinality(changed_fields) > 0;

  IF meaningful_change THEN
    SELECT count(*)
    INTO v_input_count
    FROM (
      SELECT DISTINCT unnest(coalesce(p_league_round_ids, '{}'::uuid[])) AS id
    ) input_scope;

    SELECT count(*)
    INTO v_resolved_count
    FROM (
      SELECT DISTINCT lr.id
      FROM public.league_rounds lr
      JOIN (
        SELECT DISTINCT unnest(coalesce(p_league_round_ids, '{}'::uuid[])) AS id
      ) input_scope
        ON input_scope.id = lr.id
    ) resolved_scope;

    IF v_resolved_count <> v_input_count THEN
      RAISE EXCEPTION
        'PRIMARY_LIVE_LEAGUE_ROUND_SCOPE_INCOMPLETE:%:%',
        v_resolved_count,
        v_input_count;
    END IF;

    FOR v_league_round_id IN
      SELECT DISTINCT lr.id
      FROM public.league_rounds lr
      JOIN (
        SELECT DISTINCT unnest(coalesce(p_league_round_ids, '{}'::uuid[])) AS id
      ) input_scope
        ON input_scope.id = lr.id
      WHERE lr.enabled
        AND lr.status NOT IN (
          'scheduled',
          'predictions_open',
          'cancelled',
          'archived'
        )
        AND EXISTS (
          SELECT 1
          FROM public.league_schedule_versions lsv
          WHERE lsv.league_id = lr.league_id
            AND lsv.active
            AND EXISTS (
              SELECT 1
              FROM public.league_fixtures lf
              WHERE lf.schedule_version_id = lsv.id
                AND lf.league_round_id = lr.id
                AND lf.mode = 'fantacalcio'
            )
            AND EXISTS (
              SELECT 1
              FROM public.league_fixtures lf
              WHERE lf.schedule_version_id = lsv.id
                AND lf.league_round_id = lr.id
                AND lf.mode = 'one_to_one'
            )
        )
      ORDER BY lr.id
    LOOP
      SELECT count(*)
      INTO v_enqueue_count
      FROM public.enqueue_primary_live_rebuild_job_rpc(
        v_league_round_id,
        observation_id,
        authority_state_version,
        p_match_id,
        p_fantagol_round_id,
        changed_fields,
        p_correlation_id,
        p_causation_id
      );

      IF v_enqueue_count <> 1 THEN
        RAISE EXCEPTION
          'PRIMARY_LIVE_REBUILD_ENQUEUE_RESULT_INVALID:%:%',
          v_league_round_id,
          v_enqueue_count;
      END IF;

      v_rebuild_count := v_rebuild_count + 1;
    END LOOP;
  END IF;

  primary_live_rebuild_job_count := v_rebuild_count;

  RETURN NEXT;
END;
$function$;

REVOKE ALL ON FUNCTION public.record_primary_live_observation_fanout_v1_internal(
  uuid, text, timestamptz, text, text, integer, integer, integer, boolean,
  text, jsonb, uuid[], uuid, uuid, uuid
) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.record_primary_live_observation_fanout_v1_internal(
  uuid, text, timestamptz, text, text, integer, integer, integer, boolean,
  text, jsonb, uuid[], uuid, uuid, uuid
) TO service_role;

COMMENT ON FUNCTION public.record_primary_live_observation_fanout_v1_internal(
  uuid, text, timestamptz, text, text, integer, integer, integer, boolean,
  text, jsonb, uuid[], uuid, uuid, uuid
) IS
'Retry-safe Tutto primary-live boundary: records/classifies the observation and atomically enqueues rebuilds for eligible league rounds. Any downstream error rolls back the observation/authority mutation.';

COMMIT;