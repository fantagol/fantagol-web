import type { NormalizedMatchStatus } from "../providers/types/normalized";
import type { PollingPolicyDecision } from "./types";

export type MarketPollingPolicyInput = {
  status: NormalizedMatchStatus;
  kickoffAt: string;
  now?: Date;
  roundCertified?: boolean;
};

/**
 * Compatibility safety policy.
 *
 * The Odds API must no longer be scheduled by the match-level live
 * polling scheduler. Market acquisition is governed at FantaGol Round
 * level by market-round-polling-policy.ts.
 *
 * Keeping this function allows scheduler.ts to retain its provider
 * branch without accidentally creating event-level Odds polling jobs.
 */
export function decideMarketPollingPolicy(
  _input: MarketPollingPolicyInput,
): PollingPolicyDecision {
  return {
    band: "stopped",
    intervalSeconds: null,
    shouldPoll: false,
    reason: "market_round_scheduler_required",
  };
}