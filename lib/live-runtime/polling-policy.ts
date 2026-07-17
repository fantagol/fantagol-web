import type { NormalizedMatchStatus } from "../providers/types/normalized";
import { LiveRuntimeError } from "./errors";
import type {
  PollingPolicyDecision,
  PollingPolicyInput,
} from "./types";

const LIVE_STATUSES = new Set<NormalizedMatchStatus>([
  "live_first_half",
  "live_second_half",
  "extra_time",
  "penalties",
]);

const TERMINAL_STATUSES = new Set<NormalizedMatchStatus>([
  "finished",
  "awarded",
  "cancelled",
  "abandoned",
]);

const HOUR = 60 * 60;
const DAY = 24 * HOUR;

function secondsUntil(kickoffAt: string, now: Date): number {
  const kickoff = new Date(kickoffAt);

  if (Number.isNaN(kickoff.getTime())) {
    throw new LiveRuntimeError({
      code: "LIVE_RUNTIME_INVALID_DATE",
      message: `Invalid kickoffAt: ${kickoffAt}`,
      details: { kickoffAt },
    });
  }

  return Math.floor((kickoff.getTime() - now.getTime()) / 1000);
}

export function decidePollingPolicy(
  input: PollingPolicyInput,
): PollingPolicyDecision {
  if (input.roundCertified) {
    return {
      band: "stopped",
      intervalSeconds: null,
      shouldPoll: false,
      reason: "round_certified",
    };
  }

  if (LIVE_STATUSES.has(input.status)) {
    return {
      band: "live",
      intervalSeconds: 15,
      shouldPoll: true,
      reason: "match_live",
    };
  }

  if (input.status === "halftime") {
    return {
      band: "halftime",
      intervalSeconds: 25,
      shouldPoll: true,
      reason: "match_halftime",
    };
  }

  if (TERMINAL_STATUSES.has(input.status)) {
    if (!input.postLiveStable) {
      return {
        band: "post_live_stabilizing",
        intervalSeconds: 30,
        shouldPoll: true,
        reason: "awaiting_provider_stability",
      };
    }

    return {
      band: "post_live_stable",
      intervalSeconds: 300,
      shouldPoll: true,
      reason: "post_live_stable",
    };
  }

  if (input.status === "postponed") {
    return {
      band: "day_ahead",
      intervalSeconds: 1800,
      shouldPoll: true,
      reason: "postponed_match_monitoring",
    };
  }

  const now = input.now ?? new Date();
  const untilKickoff = secondsUntil(input.kickoffAt, now);

  if (untilKickoff <= 15 * 60) {
    return {
      band: "imminent",
      intervalSeconds: 60,
      shouldPoll: true,
      reason: "kickoff_within_15_minutes",
    };
  }

  if (untilKickoff <= 2 * HOUR) {
    return {
      band: "approaching",
      intervalSeconds: 300,
      shouldPoll: true,
      reason: "kickoff_within_2_hours",
    };
  }

  if (untilKickoff <= DAY) {
    return {
      band: "day_ahead",
      intervalSeconds: 1800,
      shouldPoll: true,
      reason: "kickoff_within_24_hours",
    };
  }

  return {
    band: "dormant",
    intervalSeconds: 6 * HOUR,
    shouldPoll: true,
    reason: "kickoff_more_than_24_hours_away",
  };
}
