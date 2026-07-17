import type {
  LiveRuntimeChangeDetection,
  LiveRuntimeChangeType,
  RuntimeNormalizedMatchUpdate,
  RuntimePersistedMatchState,
} from "./types";

const FINISHED_STATUSES = new Set([
  "finished",
]);

function sameScore(
  previous: RuntimePersistedMatchState,
  current: RuntimeNormalizedMatchUpdate,
): boolean {
  return (
    previous.homeScore === current.homeScore &&
    previous.awayScore === current.awayScore
  );
}

function determinePrimaryChange(
  previous: RuntimePersistedMatchState,
  current: RuntimeNormalizedMatchUpdate,
): LiveRuntimeChangeType {
  if (current.status === "awarded" && previous.status !== "awarded") {
    return "MATCH_AWARDED";
  }

  if (current.status === "cancelled" && previous.status !== "cancelled") {
    return "MATCH_CANCELLED";
  }

  if (current.status === "postponed" && previous.status !== "postponed") {
    return "MATCH_POSTPONED";
  }

  if (
    FINISHED_STATUSES.has(current.status) &&
    !FINISHED_STATUSES.has(previous.status)
  ) {
    return "MATCH_FINISHED";
  }

  if (!sameScore(previous, current)) {
    return "MATCH_SCORE_CHANGED";
  }

  if (previous.kickoffAt !== current.kickoffAt) {
    return "MATCH_KICKOFF_CHANGED";
  }

  if (previous.status !== current.status) {
    return "MATCH_STATE_CHANGED";
  }

  return "NO_CHANGE";
}

/**
 * Detects only changes that matter to persistence and simulation rebuilds.
 * Minute/period/provider timestamp changes are reported in changedFields but
 * do not independently trigger a rebuild when score, status and kickoff are
 * unchanged.
 */
export function detectLiveMatchChange(
  previous: RuntimePersistedMatchState | null,
  current: RuntimeNormalizedMatchUpdate,
): LiveRuntimeChangeDetection {
  if (!previous) {
    return {
      meaningfulChange: true,
      changeType: "MATCH_STATE_CHANGED",
      changedFields: [
        "status",
        "score",
        "kickoffAt",
        "minute",
        "period",
        "providerUpdatedAt",
      ],
      previous: null,
      current,
    };
  }

  const changedFields: LiveRuntimeChangeDetection["changedFields"] = [];

  if (previous.status !== current.status) {
    changedFields.push("status");
  }

  if (!sameScore(previous, current)) {
    changedFields.push("score");
  }

  if (previous.kickoffAt !== current.kickoffAt) {
    changedFields.push("kickoffAt");
  }

  if (previous.minute !== current.minute) {
    changedFields.push("minute");
  }

  if (previous.period !== current.period) {
    changedFields.push("period");
  }

  if (previous.providerUpdatedAt !== current.providerUpdatedAt) {
    changedFields.push("providerUpdatedAt");
  }

  const changeType = determinePrimaryChange(previous, current);

  return {
    meaningfulChange: changeType !== "NO_CHANGE",
    changeType,
    changedFields,
    previous,
    current,
  };
}
