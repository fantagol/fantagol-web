-- FANTAGOL R41-M11 / MIGRATION 348 CANDIDATE ONLY
-- Requires migration 347: recover_official_terminal_round_internal(uuid).
-- One transaction owns both lifecycle recovery and durable canonical job enqueue.
-- R79 TypeScript MUST NOT independently enqueue outcomes from this RPC.
-- No synthetic LIVE state. No official publication/achievements here.

CREATE TABLE IF NOT EXISTS public.terminal_final_rebuild_intents (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    fantagol_round_id uuid NOT NULL REFERENCES public.fantagol_rounds(id),
    league_round_id uuid NOT NULL REFERENCES public.league_rounds(id),
    league_round_version bigint NOT NULL,
    idempotency_key text NOT NULL UNIQUE,
    job_id uuid NULL REFERENCES public.live_runtime_jobs(id),
    delivery_state text NOT NULL DEFAULT 'pending'
       CHECK (delivery_state IN ('pending','enqueued','blocked')),
    last_job_status text NULL,
    last_error text NULL,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT terminal_final_rebuild_intents_round_version_uq
      UNIQUE (league_round_id, league_round_version)
);
CREATE INDEX IF NOT EXISTS terminal_final_rebuild_intents_round_idx
    ON public.terminal_final_rebuild_intents(fantagol_round_id, delivery_state);
ALTER TABLE public.terminal_final_rebuild_intents ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.terminal_final_rebuild_intents FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.terminal_final_rebuild_intents FROM service_role;
GRANT SELECT ON public.terminal_final_rebuild_intents TO service_role;

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
                      WHERE i.fantagol_round_id=fr.id AND i.delivery_state<>'blocked'
                        AND (i.delivery_state='pending' OR j.id IS NULL
                             OR j.status IN ('failed','cancelled','dead_letter'))
                  )
              )
          )
        ORDER BY fr.ends_at, fr.id
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
            IF v_job_count + v_blocked_count = 0 THEN
                RAISE EXCEPTION 'TERMINAL_SWEEP_NO_ACTIVE_FINAL_TARGETS';
            END IF;
            v_outcome := CASE WHEN v_blocked_count > 0 THEN 'blocked_job_review'
                              ELSE 'durably_enqueued' END;
            v_results := v_results || jsonb_build_array(jsonb_build_object(
                'round_id',v_round.id,'outcome',v_outcome,
                'canonical_jobs_present',v_job_count,'blocked_jobs',v_blocked_count
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
    'Bounded R79/R41 official terminal recovery, atomic intents + canonical queue; returns durably_enqueued (never advanced) to prevent duplicate JS enqueue.';
