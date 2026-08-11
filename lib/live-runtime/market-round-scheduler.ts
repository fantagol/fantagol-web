import type { SupabaseClient } from "@supabase/supabase-js";

import {
  enqueueLiveRuntimeJob,
  type EnqueuedLiveRuntimeJob,
} from "./job-service";
import {
  decideMarketRoundPollingWithCommissioning,
  type MarketCommissioningPolicyDecision,
} from "./market-commissioning-policy";
import type {
  MarketRoundPollingPolicyInput,
} from "./market-round-polling-policy";

export type MarketRoundPollingTarget = {
  matchId: string;
  externalMatchId: string;
  slotNumber: number;
  kickoffAt: string;
  status: string;
  leagueRoundIds?: string[];
};

export type ScheduleMarketRoundPollingInput = {
  client: SupabaseClient;
  fantagolRoundId: string;
  targets: MarketRoundPollingTarget[];
  policyInput: MarketRoundPollingPolicyInput;
  correlationId?: string | null;
  causationId?: string | null;
  priority?: number;
};

export type ScheduledMarketRoundPolling = {
  decision: MarketCommissioningPolicyDecision;
  snapshotSource: "PACKAGE" | null;
  scheduledAt: string | null;
  job: EnqueuedLiveRuntimeJob | null;
  reason: string;
};

function toIsoSecond(date: Date): string {
  return new Date(
    Math.floor(date.getTime() / 1000) * 1000,
  ).toISOString();
}

function buildMarketBatchIdempotencyKey(input: {
  fantagolRoundId: string;
  scheduledAt: string;
}): string {
  return [
    "market",
    "poll-batch",
    "the_odds_api",
    input.fantagolRoundId,
    "PACKAGE",
    input.scheduledAt,
  ].join(":");
}

function assertTargets(
  targets: MarketRoundPollingTarget[],
): void {
  if (targets.length === 0) {
    throw new Error(
      "MARKET_ROUND_TARGETS_REQUIRED",
    );
  }

  const matchIds =
    new Set<string>();

  const externalIds =
    new Set<string>();

  const slots =
    new Set<number>();

  for (const target of targets) {
    if (
      !target.matchId ||
      !target.externalMatchId ||
      !Number.isInteger(target.slotNumber) ||
      target.slotNumber <= 0
    ) {
      throw new Error(
        "MARKET_ROUND_TARGET_INVALID",
      );
    }

    if (
      matchIds.has(target.matchId) ||
      externalIds.has(target.externalMatchId) ||
      slots.has(target.slotNumber)
    ) {
      throw new Error(
        "MARKET_ROUND_TARGET_DUPLICATE",
      );
    }

    matchIds.add(target.matchId);
    externalIds.add(target.externalMatchId);
    slots.add(target.slotNumber);
  }
}

/**
 * Dedicated round-level The Odds API scheduler.
 *
 * During the temporary commissioning window this produces at most one
 * PACKAGE poll_batch job every 24h and never schedules ADVANCED/event calls.
 *
 * Outside commissioning the canonical market policy is preserved. This
 * scheduler intentionally handles PACKAGE jobs only; advanced refinement is
 * a distinct event-level path and must never be silently converted into a
 * package request.
 */
export async function scheduleMarketRoundPolling(
  input: ScheduleMarketRoundPollingInput,
): Promise<ScheduledMarketRoundPolling> {
  assertTargets(input.targets);

  const decision =
    decideMarketRoundPollingWithCommissioning(
      input.policyInput,
    );

  if (!decision.shouldPoll) {
    return {
      decision,
      snapshotSource: null,
      scheduledAt: null,
      job: null,
      reason: decision.reason,
    };
  }

  if (!decision.packageSnapshotDue) {
    return {
      decision,
      snapshotSource: null,
      scheduledAt: null,
      job: null,
      reason:
        "market_advanced_requires_event_scheduler",
    };
  }

  const scheduledAt =
    toIsoSecond(
      input.policyInput.now,
    );

  const orderedTargets =
    [...input.targets].sort(
      (a, b) =>
        a.slotNumber - b.slotNumber,
    );

  const job =
    await enqueueLiveRuntimeJob(
      input.client,
      {
        jobType: "poll_batch",
        scopeType: "fantagol_round",
        scopeId:
          input.fantagolRoundId,
        idempotencyKey:
          buildMarketBatchIdempotencyKey({
            fantagolRoundId:
              input.fantagolRoundId,
            scheduledAt,
          }),
        priority:
          input.priority ?? 20,
        maxAttempts:
          decision.commissioningActive
            ? 1
            : 5,
        scheduledAt,
        payload: {
          provider_code:
            "the_odds_api",
          mode:
            "prematch",
          competition_code:
            "SA",
          market_snapshot_source:
            "PACKAGE",
          market_intelligence:
            true,
          market_operating_mode:
            decision.operatingMode,
          market_policy_reason:
            decision.reason,
          commissioning_ends_at:
            decision.commissioningEndsAt,
          match_targets:
            orderedTargets.map(
              (target) => ({
                match_id:
                  target.matchId,
                external_match_id:
                  target.externalMatchId,
                fantagol_round_id:
                  input.fantagolRoundId,
                slot_number:
                  target.slotNumber,
                league_round_ids:
                  target.leagueRoundIds ??
                  [],
                kickoff_at:
                  target.kickoffAt,
                current_status:
                  target.status,
              }),
            ),
        },
        correlationId:
          input.correlationId ?? null,
        causationId:
          input.causationId ?? null,
      },
    );

  return {
    decision,
    snapshotSource: "PACKAGE",
    scheduledAt,
    job,
    reason: decision.reason,
  };
}
