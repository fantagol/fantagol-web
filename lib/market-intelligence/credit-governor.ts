export const DEFAULT_ODDS_MONTHLY_BUDGET =
  500 as const;

export const MEASURED_PACKAGE_COST =
  2 as const;

export const MEASURED_ADVANCED_EVENT_COST =
  5 as const;

export interface CreditBudgetInput {
  monthlyBudget?: number;

  creditsUsed: number;

  /*
   * Number of future package acquisitions
   * that MUST remain affordable.
   */
  guaranteedPackageCallsRemaining:
    number;

  /*
   * Caller-owned safety reserve.
   * The governor never invents Surprise,
   * operational or emergency reserves.
   */
  safetyReserveCredits:
    number;
}

export interface CreditBudgetState {
  monthlyBudget: number;

  creditsUsed: number;
  creditsRemaining: number;

  packageReserveCredits: number;

  safetyReserveCredits: number;

  protectedCredits: number;

  spendableCredits: number;

  maximumAdvancedCalls: number;
}

export interface AdvancedCandidate {
  eventId: string;

  homeTeam: string;
  awayTeam: string;

  hoursToKickoff: number;

  sign: {
    home: number;
    draw: number;
    away: number;
  };

  marketConfidence: number;

  modelLoss: number;

  movementMagnitude: number;

  lastAdvancedAgeHours:
    number | null;

  hasAdvancedSnapshot:
    boolean;
}

export interface AdvancedPriority {
  eventId: string;

  homeTeam: string;
  awayTeam: string;

  score: number;

  components: {
    uncertainty: number;
    confidenceNeed: number;
    modelFitNeed: number;
    movementNeed: number;
    kickoffUrgency: number;
    freshnessNeed: number;
  };

  reasons: string[];
}

export interface AdvancedAllocation {
  budget:
    CreditBudgetState;

  priorities:
    AdvancedPriority[];

  selected:
    AdvancedPriority[];

  deferred:
    AdvancedPriority[];

  creditsAllocated:
    number;

  creditsLeftAfterAllocation:
    number;
}

function clamp01(
  value: number,
): number {
  return Math.max(
    0,
    Math.min(1, value),
  );
}

export function calculateCreditBudget(
  input:
    CreditBudgetInput,
): CreditBudgetState {
  const monthlyBudget =
    input.monthlyBudget ??
    DEFAULT_ODDS_MONTHLY_BUDGET;

  const creditsUsed =
    Math.max(
      0,
      input.creditsUsed,
    );

  const creditsRemaining =
    Math.max(
      0,
      monthlyBudget -
      creditsUsed,
    );

  const packageReserveCredits =
    Math.max(
      0,
      input
        .guaranteedPackageCallsRemaining,
    ) *
    MEASURED_PACKAGE_COST;

  const safetyReserveCredits =
    Math.max(
      0,
      input.safetyReserveCredits,
    );

  const protectedCredits =
    packageReserveCredits +
    safetyReserveCredits;

  const spendableCredits =
    Math.max(
      0,
      creditsRemaining -
      protectedCredits,
    );

  const maximumAdvancedCalls =
    Math.floor(
      spendableCredits /
      MEASURED_ADVANCED_EVENT_COST,
    );

  return {
    monthlyBudget,

    creditsUsed,
    creditsRemaining,

    packageReserveCredits,

    safetyReserveCredits,

    protectedCredits,

    spendableCredits,

    maximumAdvancedCalls,
  };
}

function signUncertainty(
  candidate:
    AdvancedCandidate,
): number {
  const probabilities = [
    candidate.sign.home,
    candidate.sign.draw,
    candidate.sign.away,
  ]
    .map(clamp01)
    .sort(
      (a, b) =>
        b - a,
    );

  /*
   * Small gap between the first two
   * outcomes means greater uncertainty.
   *
   * gap 0.00 => need 1.00
   * gap 0.50+ => need 0.00
   */
  const topGap =
    probabilities[0] -
    probabilities[1];

  return clamp01(
    1 -
    topGap / 0.5,
  );
}

function modelFitNeed(
  loss: number,
): number {
  if (
    !Number.isFinite(loss) ||
    loss <= 0
  ) {
    return 0;
  }

  /*
   * WP221 showed that ~0.12 is
   * strongly contradictory while
   * healthy fits are around 0.001.
   */
  return clamp01(
    loss / 0.05,
  );
}

function movementNeed(
  magnitude: number,
): number {
  return clamp01(
    magnitude / 0.05,
  );
}

function kickoffUrgency(
  hoursToKickoff: number,
): number {
  if (hoursToKickoff <= 6) {
    return 1;
  }

  if (hoursToKickoff <= 24) {
    return 0.8;
  }

  if (hoursToKickoff <= 48) {
    return 0.6;
  }

  if (hoursToKickoff <= 72) {
    return 0.4;
  }

  if (hoursToKickoff <= 120) {
    return 0.2;
  }

  return 0.05;
}

function freshnessNeed(
  candidate:
    AdvancedCandidate,
): number {
  if (
    !candidate
      .hasAdvancedSnapshot
  ) {
    return 1;
  }

  if (
    candidate
      .lastAdvancedAgeHours ===
    null
  ) {
    return 1;
  }

  return clamp01(
    candidate
      .lastAdvancedAgeHours /
    72,
  );
}

export function scoreAdvancedCandidate(
  candidate:
    AdvancedCandidate,
): AdvancedPriority {
  const uncertainty =
    signUncertainty(candidate);

  const confidenceNeed =
    clamp01(
      1 -
      candidate
        .marketConfidence,
    );

  const fitNeed =
    modelFitNeed(
      candidate.modelLoss,
    );

  const movement =
    movementNeed(
      candidate
        .movementMagnitude,
    );

  const urgency =
    kickoffUrgency(
      candidate.hoursToKickoff,
    );

  const freshness =
    freshnessNeed(
      candidate,
    );

  /*
   * Information-value weighting.
   *
   * Uncertainty dominates.
   * Poor fit and market movement can
   * escalate otherwise ordinary games.
   */
  const score =
    uncertainty * 0.30 +
    confidenceNeed * 0.20 +
    fitNeed * 0.15 +
    movement * 0.15 +
    urgency * 0.10 +
    freshness * 0.10;

  const reasons:
    string[] = [];

  if (uncertainty >= 0.70) {
    reasons.push(
      "HIGH_SIGN_UNCERTAINTY",
    );
  }

  if (confidenceNeed >= 0.20) {
    reasons.push(
      "LOW_MARKET_CONFIDENCE",
    );
  }

  if (fitNeed >= 0.50) {
    reasons.push(
      "MODEL_CONFLICT",
    );
  }

  if (movement >= 0.50) {
    reasons.push(
      "STRONG_MARKET_MOVEMENT",
    );
  }

  if (urgency >= 0.80) {
    reasons.push(
      "KICKOFF_NEAR",
    );
  }

  if (freshness >= 0.80) {
    reasons.push(
      "ADVANCED_STALE_OR_MISSING",
    );
  }

  return {
    eventId:
      candidate.eventId,

    homeTeam:
      candidate.homeTeam,

    awayTeam:
      candidate.awayTeam,

    score:
      Math.round(
        score *
        1_000_000,
      ) /
      1_000_000,

    components: {
      uncertainty,
      confidenceNeed,
      modelFitNeed:
        fitNeed,
      movementNeed:
        movement,
      kickoffUrgency:
        urgency,
      freshnessNeed:
        freshness,
    },

    reasons,
  };
}

export function allocateAdvancedCalls(
  budgetInput:
    CreditBudgetInput,

  candidates:
    AdvancedCandidate[],

  options?: {
    /*
     * Optional operational cap for one
     * scheduler execution.
     */
    maxCallsThisRun?: number;

    minimumPriority?: number;
  },
): AdvancedAllocation {
  const budget =
    calculateCreditBudget(
      budgetInput,
    );

  const priorities =
    candidates
      .map(
        scoreAdvancedCandidate,
      )
      .sort(
        (a, b) =>
          b.score -
          a.score,
      );

  const minimumPriority =
    options
      ?.minimumPriority ??
    0;

  const eligible =
    priorities.filter(
      (item) =>
        item.score >=
        minimumPriority,
    );

  const operationalCap =
    options
      ?.maxCallsThisRun ??
    Number.MAX_SAFE_INTEGER;

  const callLimit =
    Math.max(
      0,
      Math.min(
        budget
          .maximumAdvancedCalls,

        operationalCap,
      ),
    );

  const selected =
    eligible.slice(
      0,
      callLimit,
    );

  const selectedIds =
    new Set(
      selected.map(
        (item) =>
          item.eventId,
      ),
    );

  const deferred =
    priorities.filter(
      (item) =>
        !selectedIds.has(
          item.eventId,
        ),
    );

  const creditsAllocated =
    selected.length *
    MEASURED_ADVANCED_EVENT_COST;

  return {
    budget,

    priorities,

    selected,

    deferred,

    creditsAllocated,

    creditsLeftAfterAllocation:
      budget.spendableCredits -
      creditsAllocated,
  };
}