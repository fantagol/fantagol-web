import {
  decideMarketRoundPollingPolicy,
  type MarketRoundPollingPolicyDecision,
  type MarketRoundPollingPolicyInput,
} from "./market-round-polling-policy";

export const ODDS_COMMISSIONING_START_AT =
  "2026-08-10T00:00:00.000Z" as const;

export const ODDS_COMMISSIONING_END_AT =
  "2026-08-17T00:00:00.000Z" as const;

export const ODDS_COMMISSIONING_PACKAGE_INTERVAL_SECONDS =
  24 * 60 * 60;

export type MarketCommissioningMode =
  | "commissioning"
  | "standard";

export type MarketCommissioningPolicyDecision =
  MarketRoundPollingPolicyDecision & {
    operatingMode: MarketCommissioningMode;
    commissioningActive: boolean;
    commissioningEndsAt: string;
  };

function parseIsoString(
  value: string,
  fieldName: string,
): number {
  const parsed = Date.parse(value);

  if (!Number.isFinite(parsed)) {
    throw new Error(
      `Invalid ${fieldName}: ${value}`,
    );
  }

  return parsed;
}

function commissioningPackageDue(input: {
  nowMs: number;
  lastPackageSnapshotAt?: string | null;
}): boolean {
  if (!input.lastPackageSnapshotAt) {
    return true;
  }

  const lastPackageMs = parseIsoString(
    input.lastPackageSnapshotAt,
    "lastPackageSnapshotAt",
  );

  const ageSeconds =
    Math.floor(
      (input.nowMs - lastPackageMs) / 1000,
    );

  return (
    ageSeconds >=
    ODDS_COMMISSIONING_PACKAGE_INTERVAL_SECONDS
  );
}

/**
 * Temporary, bounded commissioning overlay for the first pre-season week.
 *
 * Contract:
 * - active only from 2026-08-10T00:00Z inclusive
 *   until 2026-08-17T00:00Z exclusive;
 * - package acquisition at most once every 24 hours;
 * - advanced/event calls are always suppressed while commissioning is active;
 * - first kickoff remains a hard stop;
 * - outside the bounded window the canonical seasonal policy is returned
 *   unchanged.
 *
 * This function intentionally does NOT alter market-round-polling-policy.ts.
 */
export function decideMarketRoundPollingWithCommissioning(
  input: MarketRoundPollingPolicyInput,
): MarketCommissioningPolicyDecision {
  const standard =
    decideMarketRoundPollingPolicy(input);

  const nowMs = input.now.getTime();

  if (!Number.isFinite(nowMs)) {
    throw new Error(
      `Invalid now: ${input.now.toString()}`,
    );
  }

  const startMs = parseIsoString(
    ODDS_COMMISSIONING_START_AT,
    "commissioningStartAt",
  );

  const endMs = parseIsoString(
    ODDS_COMMISSIONING_END_AT,
    "commissioningEndAt",
  );

  const commissioningActive =
    nowMs >= startMs &&
    nowMs < endMs;

  if (!commissioningActive) {
    return {
      ...standard,
      operatingMode: "standard",
      commissioningActive: false,
      commissioningEndsAt:
        ODDS_COMMISSIONING_END_AT,
    };
  }

  if (
    standard.secondsUntilFirstKickoff <= 0
  ) {
    return {
      ...standard,
      shouldPoll: false,
      packageSnapshotDue: false,
      advancedWindow: null,
      operatingMode: "commissioning",
      commissioningActive: true,
      commissioningEndsAt:
        ODDS_COMMISSIONING_END_AT,
      reason:
        "commissioning_first_round_kickoff_reached",
    };
  }

  const packageSnapshotDue =
    commissioningPackageDue({
      nowMs,
      lastPackageSnapshotAt:
        input.lastPackageSnapshotAt,
    });

  return {
    ...standard,
    shouldPoll: packageSnapshotDue,
    packageSnapshotDue,
    advancedWindow: null,
    operatingMode: "commissioning",
    commissioningActive: true,
    commissioningEndsAt:
      ODDS_COMMISSIONING_END_AT,
    reason: packageSnapshotDue
      ? "commissioning_sparse_package_due"
      : "commissioning_sparse_wait",
  };
}
