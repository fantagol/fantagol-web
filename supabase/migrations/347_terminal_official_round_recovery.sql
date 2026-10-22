-- FANTAGOL R41-M3
-- Terminal official round recovery
-- Certified transactional canary: R41-M2
-- SOURCE ONLY - deployment not authorized

BEGIN;

-- FANTAGOL R41-M2 — CANDIDATE SOURCE ONLY. NOT APPLIED.
-- Install ONLY after migration-number and source-scope review.
-- Terminal, certified-result recovery; does not invent historical LIVE observations.
-- No job enqueue, scoring, match edits, predictions, rewards or publication.
-- Security: service_role ONLY. The heartbeat must NOT invoke this automatically
-- until bounded, durable orchestration and tests are separately approved.
CREATE OR REPLACE FUNCTION public.recover_official_terminal_round_internal(
    p_fantagol_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $fn$
DECLARE
    v_round public.fantagol_rounds%ROWTYPE;
    v_required integer;
    v_distinct integer;
    v_official integer;
    v_target integer;
    v_eligible integer;
    v_blocked_leagues integer;
    v_updated_leagues integer := 0;
    v_updated_global integer := 0;
BEGIN
    IF p_fantagol_round_id IS NULL THEN
        RAISE EXCEPTION 'TERMINAL_RECOVERY_ROUND_ID_REQUIRED';
    END IF;

    PERFORM pg_advisory_xact_lock(
        hashtextextended('terminal-official-recovery:' || p_fantagol_round_id::text, 0)
    );

    SELECT * INTO v_round
    FROM public.fantagol_rounds
    WHERE id = p_fantagol_round_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'TERMINAL_RECOVERY_ROUND_MISSING';
    END IF;

    -- Idempotent only after successful recovery; do not modify later states.
    IF v_round.status IN ('final_calculable', 'final_official', 'recalculated') THEN
        RETURN jsonb_build_object(
            'outcome', 'already_advanced',
            'round_id', p_fantagol_round_id,
            'global_status', v_round.status,
            'updated_league_rounds', 0
        );
    END IF;

    IF v_round.status <> 'predictions_locked'
       OR v_round.active IS DISTINCT FROM TRUE
       OR v_round.ends_at IS NULL
       OR v_round.ends_at > clock_timestamp()
       OR v_round.official_match_set_version IS NULL
       OR v_round.target_match_count IS NULL
       OR v_round.target_match_count < 1
    THEN
        RAISE EXCEPTION 'TERMINAL_RECOVERY_INVALID_ROUND_STATE';
    END IF;

    SELECT count(*)::integer,
           count(DISTINCT frm.match_id)::integer,
           count(*) FILTER (
             WHERE m.status IN ('finished', 'awarded')
               AND m.finalised_at IS NOT NULL
               AND mc.id IS NOT NULL
               AND mc.status = 'official'
               AND mc.source_match_version = m.version
               AND mc.home_score IS NOT DISTINCT FROM m.home_score
               AND mc.away_score IS NOT DISTINCT FROM m.away_score
               AND mc.match_finalised_at IS NOT DISTINCT FROM m.finalised_at
           )::integer
    INTO v_required, v_distinct, v_official
    FROM public.fantagol_round_matches frm
    LEFT JOIN public.matches m ON m.id = frm.match_id
    LEFT JOIN public.match_certification_states mcs ON mcs.match_id = frm.match_id
    LEFT JOIN public.match_result_certifications mc
      ON mc.id = mcs.active_certification_id
    WHERE frm.fantagol_round_id = p_fantagol_round_id
      AND frm.required IS TRUE
      AND frm.removed_at IS NULL;

    v_target := v_round.target_match_count;
    IF v_required <> v_target
       OR v_distinct <> v_target
       OR v_official <> v_target
    THEN
        RAISE EXCEPTION 'TERMINAL_RECOVERY_OFFICIAL_MATCH_SET_INCOMPLETE: expected %, required %, unique %, official %',
          v_target, v_required, v_distinct, v_official;
    END IF;

    -- Only active parent leagues, never deleted/archived leagues even if enabled=true.
    SELECT count(*) FILTER (WHERE lr.status = 'predictions_locked')::integer,
           count(*) FILTER (WHERE lr.status <> 'predictions_locked')::integer
    INTO v_eligible, v_blocked_leagues
    FROM public.league_rounds lr
    JOIN public.leagues l ON l.id = lr.league_id
    WHERE lr.fantagol_round_id = p_fantagol_round_id
      AND lr.enabled IS TRUE
      AND l.status = 'active';

    IF v_eligible = 0 OR v_blocked_leagues <> 0 THEN
        RAISE EXCEPTION 'TERMINAL_RECOVERY_ACTIVE_LEAGUE_SCOPE_UNSAFE: eligible %, other %',
          v_eligible, v_blocked_leagues;
    END IF;

    UPDATE public.league_rounds lr
    SET status = 'final_calculable'
    FROM public.leagues l
    WHERE lr.league_id = l.id
      AND lr.fantagol_round_id = p_fantagol_round_id
      AND lr.enabled IS TRUE
      AND l.status = 'active'
      AND lr.status = 'predictions_locked';
    GET DIAGNOSTICS v_updated_leagues = ROW_COUNT;

    IF v_updated_leagues <> v_eligible THEN
        RAISE EXCEPTION 'TERMINAL_RECOVERY_LEAGUE_UPDATE_MISMATCH';
    END IF;

    UPDATE public.fantagol_rounds
    SET status = 'final_calculable'
    WHERE id = p_fantagol_round_id AND status = 'predictions_locked';
    GET DIAGNOSTICS v_updated_global = ROW_COUNT;

    IF v_updated_global <> 1 THEN
        RAISE EXCEPTION 'TERMINAL_RECOVERY_GLOBAL_UPDATE_MISMATCH';
    END IF;

    RETURN jsonb_build_object(
        'outcome', 'advanced',
        'round_id', p_fantagol_round_id,
        'required', v_required,
        'official', v_official,
        'updated_active_league_rounds', v_updated_leagues,
        'deleted_leagues_touched', 0,
        'jobs_enqueued', 0
    );
END;
$fn$;

REVOKE ALL ON FUNCTION public.recover_official_terminal_round_internal(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.recover_official_terminal_round_internal(uuid) FROM anon;
REVOKE ALL ON FUNCTION public.recover_official_terminal_round_internal(uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.recover_official_terminal_round_internal(uuid) TO service_role;

COMMENT ON FUNCTION public.recover_official_terminal_round_internal(uuid) IS
'Official-only bounded terminal lifecycle recovery for rounds stuck predictions_locked; active parent leagues only; no synthetic live evidence, no jobs, scoring or publication.';

COMMIT;
