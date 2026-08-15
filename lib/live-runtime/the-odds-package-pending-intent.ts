import type { SupabaseClient } from "@supabase/supabase-js";

import type {
  EnqueuedLiveRuntimeJob,
  LiveRuntimeJobStatus,
} from "./job-service";

type TheOddsPackagePendingIntentRpcRow = {
  job_id: string;
  job_status: LiveRuntimeJobStatus;
  inserted: boolean;
  scheduled_at: string;
  attempt_count: number;
  correlation_id: string;
};

export type EnqueueTheOddsPackagePendingIntentInput = {
  fantagolRoundId: string;
  mode: "prematch";
  marketOperatingMode: string;
  marketPolicyReason: string;
  idempotencyKey: string;
  priority: number;
  scheduledAt: string;
  payload: Record<string, unknown>;
  maxAttempts?: number;
  correlationId?: string | null;
  causationId?: string | null;
};

/**
 * Atomically preserves the earliest compatible pristine pending
 * The Odds API PACKAGE intent for a round/policy signature.
 *
 * Exact-key idempotency remains owned by the canonical queue RPC.
 * This boundary adds semantic pending-intent reuse above it.
 */
export async function enqueueTheOddsPackagePendingIntent(
  client: SupabaseClient,
  input: EnqueueTheOddsPackagePendingIntentInput,
): Promise<EnqueuedLiveRuntimeJob> {
  const functionName =
    "enqueue_the_odds_package_pending_intent_rpc";

  const { data, error } =
    await client.rpc(
      functionName,
      {
        p_fantagol_round_id:
          input.fantagolRoundId,
        p_mode:
          input.mode,
        p_market_operating_mode:
          input.marketOperatingMode,
        p_market_policy_reason:
          input.marketPolicyReason,
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
    data[0] as TheOddsPackagePendingIntentRpcRow;

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