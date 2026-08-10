export type RefreshRoundSideEffectDecisionInput = {
  changeType: string;
  matchStatus: string;
  refreshedApplied: boolean;
};

export type RefreshRoundSideEffectDecision = {
  materializePostponed: boolean;
  enqueueRebuild: boolean;
};

/**
 * Determines the side effects that must follow refresh_live_match_state_rpc.
 *
 * Important retry invariant:
 * MATCH_POSTPONED must materialize governance and recover rebuild enqueue
 * even when refreshedApplied is false, because a previous worker attempt
 * may have persisted the Match state before failing during later side effects.
 */
export function resolveRefreshRoundSideEffects(
  input: RefreshRoundSideEffectDecisionInput,
): RefreshRoundSideEffectDecision {
  const materializePostponed =
    input.changeType === "MATCH_POSTPONED" &&
    input.matchStatus === "postponed";

  return {
    materializePostponed,
    enqueueRebuild:
      input.refreshedApplied || materializePostponed,
  };
}