import type { SupabaseClient } from "@supabase/supabase-js";

import type {
  EnqueuedLiveRuntimeJob,
  LiveRuntimeJobStatus,
} from "./job-service";

type FootballDataPendingIntentRpcRow = {
  job_id: string;
  job_status: LiveRuntimeJobStatus;
  inserted: boolean;
  scheduled_at: string;
  attempt_count: number;
  correlation_id: string;
};

export type EnqueueFootballDataPendingIntentInput = {
  fantagolRoundId: string;
  mode: "live" | "prematch";
  pollingBand: string;
  pollingReason: string;
  idempotencyKey: string;
  priority: number;
  scheduledAt: string;
  payload: Record<string, unknown>;
  maxAttempts?: number;
  correlationId?: string | null;
  causationId?: string | null;
};

/**
 * Atomically preserves the earliest compatible pending Football Data
 * aggregate intent for a round/mode/polling-policy signature.
 *
 * Exact-key idempotency remains enforced by the canonical queue.
 * This RPC adds semantic pending-intent reuse above that boundary.
 */
export async function enqueueFootballDataPendingIntent(
  client: SupabaseClient,
  input: EnqueueFootballDataPendingIntentInput,
): Promise<EnqueuedLiveRuntimeJob> {
  const functionName =
    "enqueue_football_data_pending_intent_rpc";

  const { data, error } =
    await client.rpc(
      functionName,
      {
        p_fantagol_round_id:
          input.fantagolRoundId,
        p_mode:
          input.mode,
        p_polling_band:
          input.pollingBand,
        p_polling_reason:
          input.pollingReason,
        p_idempotency_key:
          input.idempotencyKey,
        p_priority:
          input.priority,
        p_scheduled_at:
          input.scheduledAt,
        p_payload:
          input.payload,
        p_max_attempts:
          input.maxAttempts ?? 5,
        p_correlation_id:
          input.correlationId ?? null,
        p_causation_id:
          input.causationId ?? null,
      },
    );

  if (error) {
    throw new Error(
      `${functionName} failed: ${error.message}`,
    );
  }

  if (
    !Array.isArray(data) ||
    data.length !== 1
  ) {
    throw new Error(
      `${functionName} returned an invalid row count`,
    );
  }

  const row =
    data[0] as FootballDataPendingIntentRpcRow;

  return {
    jobId:
      row.job_id,
    jobStatus:
      row.job_status,
    inserted:
      row.inserted,
    scheduledAt:
      row.scheduled_at,
    attemptCount:
      row.attempt_count,
    correlationId:
      row.correlation_id,
  };
}