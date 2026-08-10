export type MarketRoundPhase =
  | "waiting"
  | "collecting"
  | "opening_grace"
  | "open"
  | "stopped";

export type MarketAdvancedWindow =
  | "early"
  | "final"
  | null;

export type SurpriseReferenceAction =
  | "await_opening"
  | "await_fresh_snapshot"
  | "select_fresh_snapshot"
  | "select_fallback_candidate"
  | "already_ready"
  | "stopped";

export type MarketRoundPollingPolicyInput = {
  now: Date;

  /**
   * Earliest point at which candidate snapshots for this round may be
   * collected. Normally resolved from the completion of the previous
   * FantaGol Round.
   */
  collectionStartsAt: string;

  /**
   * Canonical prediction opening target.
   * Predictions remain closed until Surprise Reference is READY.
   */
  opensAt: string;

  /**
   * First kickoff of the entire FantaGol Round.
   * All bookmaker acquisition stops here.
   */
  firstKickoffAt: string;

  lastPackageSnapshotAt?: string | null;

  earlyAdvancedCompleted?: boolean;
  finalAdvancedCompleted?: boolean;

  surpriseReferenceReady?: boolean;

  /**
   * True when a complete package snapshot exists with collected_at
   * >= opensAt.
   */
  freshSnapshotAvailable?: boolean;

  /**
   * True when a complete valid candidate exists from before opensAt.
   */
  fallbackCandidateAvailable?: boolean;
};

export type MarketRoundPollingPolicyDecision = {
  phase: MarketRoundPhase;

  shouldPoll: boolean;

  /**
   * One sport-level h2h + totals acquisition.
   * Maximum cadence: one every 24 hours.
   */
  packageSnapshotDue: boolean;

  /**
   * Additional event-level refinement window.
   *
   * early = once between 48h and 6h before first kickoff
   * final = once during final 6h
   */
  advancedWindow: MarketAdvancedWindow;

  surpriseAction: SurpriseReferenceAction;

  fallbackEligible: boolean;

  secondsUntilFirstKickoff: number;

  reason: string;
};

const HOUR = 60 * 60;
const DAY = 24 * HOUR;

function parseDate(
  value: string,
  label: string,
): Date {
  const result = new Date(value);

  if (Number.isNaN(result.getTime())) {
    throw new Error(
      `Invalid ${label}: ${value}`,
    );
  }

  return result;
}

function secondsBetween(
  future: Date,
  now: Date,
): number {
  return Math.floor(
    (future.getTime() - now.getTime()) / 1000,
  );
}

function packageIsDue(
  now: Date,
  lastPackageSnapshotAt?: string | null,
): boolean {
  if (!lastPackageSnapshotAt) {
    return true;
  }

  const last =
    parseDate(
      lastPackageSnapshotAt,
      "lastPackageSnapshotAt",
    );

  return (
    now.getTime() - last.getTime() >=
    DAY * 1000
  );
}

export function decideMarketRoundPollingPolicy(
  input: MarketRoundPollingPolicyInput,
): MarketRoundPollingPolicyDecision {
  const now = input.now;

  const collectionStartsAt =
    parseDate(
      input.collectionStartsAt,
      "collectionStartsAt",
    );

  const opensAt =
    parseDate(
      input.opensAt,
      "opensAt",
    );

  const firstKickoffAt =
    parseDate(
      input.firstKickoffAt,
      "firstKickoffAt",
    );

  const secondsUntilFirstKickoff =
    secondsBetween(
      firstKickoffAt,
      now,
    );

  // --------------------------------------------------------------
  // HARD FREEZE
  // --------------------------------------------------------------

  if (secondsUntilFirstKickoff <= 0) {
    return {
      phase: "stopped",
      shouldPoll: false,
      packageSnapshotDue: false,
      advancedWindow: null,
      surpriseAction:
        input.surpriseReferenceReady
          ? "already_ready"
          : "stopped",
      fallbackEligible: false,
      secondsUntilFirstKickoff,
      reason: "first_round_kickoff_reached",
    };
  }

  // --------------------------------------------------------------
  // BEFORE MARKET COLLECTION WINDOW
  // --------------------------------------------------------------

  if (now < collectionStartsAt) {
    return {
      phase: "waiting",
      shouldPoll: false,
      packageSnapshotDue: false,
      advancedWindow: null,
      surpriseAction: "await_opening",
      fallbackEligible: false,
      secondsUntilFirstKickoff,
      reason: "market_collection_not_started",
    };
  }

  const packageSnapshotDue =
    packageIsDue(
      now,
      input.lastPackageSnapshotAt,
    );

  // --------------------------------------------------------------
  // ADVANCED MARKET WINDOWS
  // --------------------------------------------------------------

  let advancedWindow:
    MarketAdvancedWindow = null;

  if (
    secondsUntilFirstKickoff <=
      6 * HOUR &&
    !input.finalAdvancedCompleted
  ) {
    advancedWindow = "final";
  } else if (
    secondsUntilFirstKickoff <=
      48 * HOUR &&
    secondsUntilFirstKickoff >
      6 * HOUR &&
    !input.earlyAdvancedCompleted
  ) {
    advancedWindow = "early";
  }

  // --------------------------------------------------------------
  // BEFORE OPENING TARGET
  // --------------------------------------------------------------

  if (now < opensAt) {
    return {
      phase: "collecting",
      shouldPoll:
        packageSnapshotDue ||
        advancedWindow !== null,
      packageSnapshotDue,
      advancedWindow,
      surpriseAction: "await_opening",
      fallbackEligible: false,
      secondsUntilFirstKickoff,
      reason: "pre_opening_market_collection",
    };
  }

  // --------------------------------------------------------------
  // SURPRISE ALREADY CERTIFIED
  // --------------------------------------------------------------

  if (input.surpriseReferenceReady) {
    return {
      phase: "open",
      shouldPoll:
        packageSnapshotDue ||
        advancedWindow !== null,
      packageSnapshotDue,
      advancedWindow,
      surpriseAction: "already_ready",
      fallbackEligible: false,
      secondsUntilFirstKickoff,
      reason: "market_intelligence_after_opening",
    };
  }

  // --------------------------------------------------------------
  // OPENING GRACE
  //
  // First 24h after opensAt:
  // prefer a NEW complete snapshot.
  // --------------------------------------------------------------

  const openingAgeSeconds =
    Math.floor(
      (now.getTime() -
        opensAt.getTime()) /
        1000,
    );

  const fallbackEligible =
    openingAgeSeconds >= DAY;

  if (input.freshSnapshotAvailable) {
    return {
      phase: "opening_grace",
      shouldPoll: false,
      packageSnapshotDue: false,
      advancedWindow: null,
      surpriseAction:
        "select_fresh_snapshot",
      fallbackEligible,
      secondsUntilFirstKickoff,
      reason:
        "fresh_surprise_reference_available",
    };
  }

  // --------------------------------------------------------------
  // FALLBACK AFTER ONE FULL DAY
  // --------------------------------------------------------------

  if (
    fallbackEligible &&
    input.fallbackCandidateAvailable
  ) {
    return {
      phase: "opening_grace",
      shouldPoll: false,
      packageSnapshotDue: false,
      advancedWindow: null,
      surpriseAction:
        "select_fallback_candidate",
      fallbackEligible: true,
      secondsUntilFirstKickoff,
      reason:
        "opening_grace_expired_use_candidate",
    };
  }

  // --------------------------------------------------------------
  // STILL WAITING FOR FRESH ODDS
  // --------------------------------------------------------------

  return {
    phase: "opening_grace",
    shouldPoll: packageSnapshotDue,
    packageSnapshotDue,
    advancedWindow: null,
    surpriseAction:
      "await_fresh_snapshot",
    fallbackEligible,
    secondsUntilFirstKickoff,
    reason:
      fallbackEligible
        ? "fresh_snapshot_missing_no_candidate"
        : "opening_grace_waiting_fresh_snapshot",
  };
}