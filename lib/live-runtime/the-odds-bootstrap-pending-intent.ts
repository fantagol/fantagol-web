import type { SupabaseClient } from "@supabase/supabase-js";

import type {
  EnqueuedLiveRuntimeJob,
} from "./job-service";

import {
  enqueueTheOddsPackagePendingIntent,
  type EnqueueTheOddsPackagePendingIntentInput,
} from "./the-odds-package-pending-intent";

export type BuildTheOddsBootstrapPendingIntentInput = {
  fantagolRoundId: string;
  eligibleAt: string;
  competitionCode?: string;
};

export function buildTheOddsBootstrapPendingIntent(
  input: BuildTheOddsBootstrapPendingIntentInput,
): EnqueueTheOddsPackagePendingIntentInput {
  const fantagolRoundId =
    input.fantagolRoundId.trim();

  if (fantagolRoundId === "") {
    throw new Error(
      "THE_ODDS_BOOTSTRAP_PENDING_ROUND_REQUIRED",
    );
  }

  const eligibleAtMs =
    Date.parse(input.eligibleAt);

  if (!Number.isFinite(eligibleAtMs)) {
    throw new Error(
      "THE_ODDS_BOOTSTRAP_PENDING_ELIGIBLE_AT_INVALID",
    );
  }

  const eligibleAt =
    new Date(
      eligibleAtMs,
    ).toISOString();

  const competitionCode =
    input.competitionCode?.trim() ||
    "SA";

  /*
   * Stable semantic identity:
   *
   * the same Round and the same canonical eligibility boundary
   * always produce the same queue idempotency key.
   *
   * Repeated heartbeat executions therefore converge on the
   * existing PACKAGE pending-intent reuse authority.
   */
  const idempotencyKey =
    [
      "the_odds_mapping_bootstrap",
      fantagolRoundId,
      eligibleAt,
    ].join(":");

  return {
    fantagolRoundId,

    mode:
      "prematch",

    /*
     * This value identifies the market lifecycle purpose of the
     * intent. It does not convert the job into an EVENT refinement.
     */
    marketOperatingMode:
      "PACKAGE",

    marketPolicyReason:
      "THE_ODDS_MAPPING_BOOTSTRAP",

    idempotencyKey,

    priority:
      50,

    scheduledAt:
      eligibleAt,

    maxAttempts:
      1,

    payload: {
      provider_code:
        "the_odds_api",

      mode:
        "prematch",

      bootstrap_discovery:
        true,

      fantagol_round_id:
        fantagolRoundId,

      competition_code:
        competitionCode,

      bootstrap_eligible_at:
        eligibleAt,

      market_snapshot_source:
        "PACKAGE",

      market_policy_reason:
        "THE_ODDS_MAPPING_BOOTSTRAP",
    },
  };
}

export async function enqueueTheOddsBootstrapPendingIntent(
  client: SupabaseClient,
  input: BuildTheOddsBootstrapPendingIntentInput,
): Promise<EnqueuedLiveRuntimeJob> {
  return enqueueTheOddsPackagePendingIntent(
    client,
    buildTheOddsBootstrapPendingIntent(
      input,
    ),
  );
}
