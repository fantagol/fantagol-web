export const FOOTBALL_DATA_CANONICAL_POLICY_START =
  new Date(
    "2026-08-16T00:00:00.000Z",
  );

export type FootballDataPollingBand =
  | "bootstrap_dormant"
  | "prematch_gt_72h"
  | "prematch_72h_to_24h"
  | "prematch_24h_to_3h"
  | "prematch_lt_3h"
  | "live";

export type FootballDataPollingDecision = {
  band: FootballDataPollingBand;
  intervalSeconds: number;
  reason: string;
};

/**
 * Canonical Football Data polling cadence.
 *
 * Bootstrap:
 *   until 2026-08-16 UTC -> every 6 hours.
 *
 * Normal weekly policy:
 *   >72h          -> 3 hours
 *   72h..24h      -> 60 minutes
 *   24h..3h       -> 30 minutes
 *   3h..kickoff   -> 10 minutes
 *   live/paused   -> 60 seconds
 *
 * Frequency is per aggregate provider plan, not per Match.
 */
export function resolveFootballDataPollingDecision(
  input: {
    now: Date;
    mode: "live" | "prematch";
    nextKickoffAt?: Date | null;
  },
): FootballDataPollingDecision {
  if (input.mode === "live") {
    return {
      band: "live",
      intervalSeconds: 60,
      reason:
        "aggregate_live_collection",
    };
  }

  if (
    input.now.getTime() <
    FOOTBALL_DATA_CANONICAL_POLICY_START.getTime()
  ) {
    return {
      band:
        "bootstrap_dormant",
      intervalSeconds:
        6 * 60 * 60,
      reason:
        "pre_season_bootstrap_until_2026_08_16",
    };
  }

  if (!input.nextKickoffAt) {
    return {
      band:
        "prematch_gt_72h",
      intervalSeconds:
        3 * 60 * 60,
      reason:
        "no_imminent_kickoff",
    };
  }

  const deltaSeconds =
    (
      input.nextKickoffAt.getTime() -
      input.now.getTime()
    ) / 1000;

  if (
    deltaSeconds >
    72 * 60 * 60
  ) {
    return {
      band:
        "prematch_gt_72h",
      intervalSeconds:
        3 * 60 * 60,
      reason:
        "kickoff_more_than_72_hours_away",
    };
  }

  if (
    deltaSeconds >
    24 * 60 * 60
  ) {
    return {
      band:
        "prematch_72h_to_24h",
      intervalSeconds:
        60 * 60,
      reason:
        "kickoff_within_72_hours",
    };
  }

  if (
    deltaSeconds >
    3 * 60 * 60
  ) {
    return {
      band:
        "prematch_24h_to_3h",
      intervalSeconds:
        30 * 60,
      reason:
        "kickoff_within_24_hours",
    };
  }

  return {
    band:
      "prematch_lt_3h",
    intervalSeconds:
      10 * 60,
    reason:
      deltaSeconds > 0
        ? "kickoff_within_3_hours"
        : "kickoff_reached_awaiting_live_status",
  };
}