/** Non-retriable manual review does not require immediate global heartbeat retry. */
const MANUAL_REVIEW_ONLY = new Set(['terminal_round_rebuild_review_required']);

export function classifyTerminalSweepRetryReasons(reasons: readonly string[]): {
  retryRecommended: boolean;
  reviewReasons: string[];
} {
  return {
    retryRecommended: reasons.some((reason) => !MANUAL_REVIEW_ONLY.has(reason)),
    reviewReasons: reasons.filter((reason) => MANUAL_REVIEW_ONLY.has(reason)),
  };
}