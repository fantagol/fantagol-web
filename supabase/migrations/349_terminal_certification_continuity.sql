-- FANTAGOL R41-M18 / MIGRATION 349 CANDIDATE ONLY
-- Requires migrations 347 and 348.
-- Does not create new rebuild jobs for completed or blocked intents.
-- Emits actionable review for completed final rebuilds whose corresponding
-- calculation run lacks active official certification after 15 minutes AND
-- has no in-flight readiness/certification job. This is a signal, not replay.
-- Priority: never starve newly terminal rounds behind unresolved old reviews.

CREATE OR REPLACE FUNCTION public.sweep_terminal_round_reconciliation_rpc(
    p_max_rounds integer DEFAULT 2,
    p_target_round_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $fn$
DECLARE
    v_round record;
    v_lr record;
    v_enqueued record;
    v_job public.live_runtime_jobs%ROWTYPE;
    v_recovery jsonb;
    v_key text;
    v_job_count integer;
    v_blocked_count integer;
    v_review_count integer;
    v_has_final_certification boolean;
    v_evaluated integer := 0;
    v_failures integer := 0;
    v_results jsonb := '[]'::jsonb;
    v_outcome text;
BEGIN
    IF p_max_rounds IS NULL OR p_max_rounds NOT BETWEEN 1 AND 2 THEN
        RAISE EXCEPTION 'TERMINAL_SWEEP_INVALID_LIMIT';
    END IF;

    -- Candidates: newly terminal certified rounds, or rounds with an existing
    -- R41-M11 intent that still requires reconciliation. Do not sweep all history.
    FOR v_round IN
        SELECT fr.id, fr.status
        FROM public.fantagol_rounds fr
        WHERE (p_target_round_id IS NULL OR fr.id = p_target_round_id)
          AND fr.active IS TRUE
          AND fr.ends_at IS NOT NULL AND fr.ends_at <= clock_timestamp()
          AND (
              (
                  fr.status = 'predictions_locked'
                  AND fr.target_match_count > 0
                  AND (SELECT count(*) FROM public.fantagol_round_matches frm
                       WHERE frm.fantagol_round_id = fr.id
                         AND frm.required IS TRUE AND frm.removed_at IS NULL)
                       = fr.target_match_count
                  AND NOT EXISTS (
                      SELECT 1 FROM public.fantagol_round_matches frm
                      LEFT JOIN public.matches m ON m.id = frm.match_id
                      LEFT JOIN public.match_certification_states mcs ON mcs.match_id = frm.match_id
                      LEFT JOIN public.match_result_certifications mc ON mc.id = mcs.active_certification_id
                      WHERE frm.fantagol_round_id = fr.id
                        AND frm.required IS TRUE AND frm.removed_at IS NULL
                        AND NOT (
                            m.status IN ('finished','awarded')
                            AND m.finalised_at IS NOT NULL
                            AND mc.id IS NOT NULL AND mc.status = 'official'
                            AND mc.source_match_version = m.version
                            AND mc.home_score IS NOT DISTINCT FROM m.home_score
                            AND mc.away_score IS NOT DISTINCT FROM m.away_score
                            AND mc.match_finalised_at IS NOT DISTINCT FROM m.finalised_at
                        )
                  )
                  AND EXISTS (
                      SELECT 1 FROM public.league_rounds lr JOIN public.leagues l ON l.id=lr.league_id
                      WHERE lr.fantagol_round_id = fr.id AND lr.enabled IS TRUE
                        AND l.status='active' AND lr.status='predictions_locked'
                  )
              )
              OR (
                  fr.status='final_calculable'
                  AND EXISTS (
                      SELECT 1 FROM public.terminal_final_rebuild_intents i
                      LEFT JOIN public.live_runtime_jobs j ON j.id = i.job_id
                      WHERE i.fantagol_round_id=fr.id
                        AND (
                            i.delivery_state IN ('pending','blocked')
                            OR j.id IS NULL
                            OR j.status IN ('failed','cancelled','dead_letter')
                            OR (
                                j.status='completed'
                                AND j.completed_at <= clock_timestamp() - interval '15 minutes'
                                AND NOT EXISTS (
                                    SELECT 1 FROM public.round_certifications rc
                                    WHERE rc.league_round_id=i.league_round_id
                                      AND rc.active IS TRUE AND rc.status='official'
                                      AND rc.source_run_id::text=j.result->>'calculation_run_id'
                                )
                                AND NOT EXISTS (
                                    SELECT 1 FROM public.live_runtime_jobs followup
                                    WHERE followup.scope_type='league_round'
                                      AND followup.scope_id=i.league_round_id
                                      AND followup.job_type IN (
                                          'evaluate_round_certification_readiness',
                                          'certify_round'
                                      )
                                      AND followup.status IN (
                                          'pending','retry_wait','claimed','running'
                                      )
                                )
                            )
                        )
                  )
              )
          )
        ORDER BY CASE WHEN fr.status='predictions_locked' THEN 0 ELSE 1 END,
                 fr.ends_at, fr.id
        LIMIT p_max_rounds
    LOOP
        v_evaluated := v_evaluated + 1;
        BEGIN
            -- Shared per-round lock with migration 347, so jobs and transitions
            -- cannot race against a second sweep transaction.
            PERFORM pg_advisory_xact_lock(
                hashtextextended('terminal-official-recovery:' || v_round.id::text, 0)
            );
            IF v_round.status = 'predictions_locked' THEN
                v_recovery := public.recover_official_terminal_round_internal(v_round.id);
                IF v_recovery->>'outcome' NOT IN ('advanced','already_advanced') THEN
                    RAISE EXCEPTION 'TERMINAL_SWEEP_UNEXPECTED_RECOVERY';
                END IF;
            END IF;

            v_job_count := 0;
            v_blocked_count := 0;
            v_review_count := 0;
            FOR v_lr IN
                SELECT lr.id, lr.version
                FROM public.league_rounds lr
                JOIN public.leagues l ON l.id = lr.league_id
                WHERE lr.fantagol_round_id = v_round.id
                  AND lr.enabled IS TRUE AND l.status='active'
                  AND lr.status='final_calculable'
                ORDER BY lr.id
            LOOP
                v_key := 'live:final-calculable:rebuild-league-round:' ||
                         v_lr.id::text || ':v' || v_lr.version::text;
                INSERT INTO public.terminal_final_rebuild_intents (
                    fantagol_round_id, league_round_id, league_round_version,
                    idempotency_key
                ) VALUES (v_round.id, v_lr.id, v_lr.version, v_key)
                ON CONFLICT (league_round_id, league_round_version) DO NOTHING;

                SELECT j.* INTO v_job
                FROM public.live_runtime_jobs j
                WHERE j.idempotency_key = v_key;

                IF FOUND AND v_job.status IN ('failed','cancelled','dead_letter') THEN
                    UPDATE public.terminal_final_rebuild_intents i
                    SET delivery_state='blocked', job_id=v_job.id,
                        last_job_status=v_job.status,
                        last_error='TERMINAL_REBUILD_JOB_REQUIRES_EXPLICIT_REVIEW',
                        updated_at=clock_timestamp()
                    WHERE i.league_round_id=v_lr.id AND i.league_round_version=v_lr.version;
                    v_blocked_count := v_blocked_count + 1;
                    CONTINUE;
                END IF;

                -- Job completed is not certification. Do not enqueue or replay.
                -- Only diagnose the exact calculation run produced by this job.
                IF FOUND AND v_job.status='completed' THEN
                    SELECT EXISTS (
                        SELECT 1 FROM public.round_certifications rc
                        WHERE rc.league_round_id=v_lr.id
                          AND rc.active IS TRUE AND rc.status='official'
                          AND rc.source_run_id::text = v_job.result->>'calculation_run_id'
                    ) INTO v_has_final_certification;
                    IF NOT v_has_final_certification
                       AND v_job.completed_at <= clock_timestamp() - interval '15 minutes'
                       AND NOT EXISTS (
                           SELECT 1 FROM public.live_runtime_jobs followup
                           WHERE followup.scope_type='league_round'
                             AND followup.scope_id=v_lr.id
                             AND followup.job_type IN (
                                 'evaluate_round_certification_readiness','certify_round'
                             )
                             AND followup.status IN (
                                 'pending','retry_wait','claimed','running'
                             )
                       ) THEN
                        v_review_count := v_review_count + 1;
                    END IF;
                END IF;

                IF NOT FOUND THEN
                    SELECT * INTO STRICT v_enqueued
                    FROM public.enqueue_live_runtime_job_rpc(
                        p_job_type => 'rebuild_league_round',
                        p_scope_type => 'league_round',
                        p_scope_id => v_lr.id,
                        p_idempotency_key => v_key,
                        p_priority => 30,
                        p_payload => jsonb_build_object(
                            'fantagol_round_id', v_round.id,
                            'league_round_id', v_lr.id,
                            'league_round_version', v_lr.version,
                            'lifecycle_reason', 'final_calculable',
                            'publication_channel', 'realtime',
                            'round_certification_reason', 'automatic official round certification'
                        )
                    );
                    IF v_enqueued.job_status NOT IN ('pending','retry_wait','claimed','running','completed') THEN
                        RAISE EXCEPTION 'TERMINAL_SWEEP_ENQUEUE_RETURNED_UNSAFE_STATUS';
                    END IF;
                    v_job.id := v_enqueued.job_id;
                    v_job.status := v_enqueued.job_status;
                END IF;
                UPDATE public.terminal_final_rebuild_intents i
                SET delivery_state='enqueued', job_id=v_job.id,
                    last_job_status=v_job.status, last_error=NULL,
                    updated_at=clock_timestamp()
                WHERE i.league_round_id=v_lr.id AND i.league_round_version=v_lr.version;
                v_job_count := v_job_count + 1;
            END LOOP;
            IF v_job_count + v_blocked_count + v_review_count = 0 THEN
                RAISE EXCEPTION 'TERMINAL_SWEEP_NO_ACTIVE_FINAL_TARGETS';
            END IF;
            v_outcome := CASE
                WHEN v_blocked_count > 0 THEN 'blocked_job_review'
                WHEN v_review_count > 0 THEN 'certification_review_required'
                ELSE 'durably_enqueued'
            END;
            v_results := v_results || jsonb_build_array(jsonb_build_object(
                'round_id',v_round.id,'outcome',v_outcome,
                'canonical_jobs_present',v_job_count,'blocked_jobs',v_blocked_count,
                'certification_review_count',v_review_count
            ));
        EXCEPTION WHEN OTHERS THEN
            -- PL/pgSQL exception blocks roll back this round's lifecycle and
            -- enqueue changes together, without aborting other eligible rounds.
            v_failures := v_failures + 1;
            v_results := v_results || jsonb_build_array(jsonb_build_object(
                'round_id',v_round.id,'outcome','failed','error',SQLERRM
            ));
        END;
    END LOOP;
    RETURN jsonb_build_object('evaluated',v_evaluated,
        'failures',v_failures,'results',v_results);
END;
$fn$;
REVOKE ALL ON FUNCTION public.sweep_terminal_round_reconciliation_rpc(integer,uuid)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.sweep_terminal_round_reconciliation_rpc(integer,uuid)
    TO service_role;
COMMENT ON FUNCTION public.sweep_terminal_round_reconciliation_rpc(integer,uuid) IS
    'Bounded R79/R41 terminal recovery, persistent blocked/review signals; final certification requires matching calculation run. No auto-replay.';
