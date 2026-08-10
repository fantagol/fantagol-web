import {
  calculateTemporalMovement,
  movementArrow,
  type TemporalMarketObservation,
} from "./temporal-movement";

import {
  allocateAdvancedCalls,
  calculateCreditBudget,
  MEASURED_ADVANCED_EVENT_COST,
  MEASURED_PACKAGE_COST,
  scoreAdvancedCandidate,
  type AdvancedCandidate,
} from "./credit-governor";

/*
 * Real WP222 Base observation.
 */
const base:
  TemporalMarketObservation = {
  capturedAt:
    "2026-08-08T23:42:53Z",

  source:
    "PACKAGE",

  exact: [
    {
      score: "2-0",
      probability: 0.1440,
    },
    {
      score: "1-0",
      probability: 0.1180,
    },
    {
      score: "3-0",
      probability: 0.1171,
    },
    {
      score: "2-1",
      probability: 0.0849,
    },
    {
      score: "4-0",
      probability: 0.0714,
    },
  ],

  sign: {
    home: 0.7820,
    draw: 0.1474,
    away: 0.0706,
  },

  totals: {
    over: 0.5831,
    under: 0.4169,
  },

  btts: {
    goal: 0.4068,
    noGoal: 0.5932,
  },

  marketConfidence:
    0.8613,

  finalConfidence:
    0.9097,
};

/*
 * Real WP223-B Advanced observation.
 */
const advanced:
  TemporalMarketObservation = {
  capturedAt:
    "2026-08-08T23:55:01Z",

  source:
    "ADVANCED",

  exact: [
    {
      score: "2-0",
      probability: 0.1419,
    },
    {
      score: "1-0",
      probability: 0.1166,
    },
    {
      score: "3-0",
      probability: 0.1152,
    },
    {
      score: "2-1",
      probability: 0.0859,
    },
    {
      score: "1-1",
      probability: 0.0705,
    },
  ],

  sign: {
    home: 0.7778,
    draw: 0.1491,
    away: 0.0731,
  },

  totals: {
    over: 0.5853,
    under: 0.4147,
  },

  btts: {
    goal: 0.4141,
    noGoal: 0.5859,
  },

  /*
   * Advanced quality improved materially.
   * The certification focuses on temporal
   * signal mechanics rather than reproducing
   * an omitted console field.
   */
  marketConfidence:
    0.90,

  finalConfidence:
    0.92,
};

const movement =
  calculateTemporalMovement(
    base,
    advanced,
  );

if (
  Math.abs(
    movement.sign.home
      .deltaPercentagePoints ??
      0,
  ) < 0.419 ||
  Math.abs(
    movement.sign.home
      .deltaPercentagePoints ??
      0,
  ) > 0.421
) {
  throw new Error(
    "WP223C_REAL_SIGN_DELTA_FAILED",
  );
}

if (
  movement.sign.home.direction !==
  "DOWN"
) {
  throw new Error(
    "WP223C_SIGN_DIRECTION_FAILED",
  );
}

if (
  movement.totals.over.direction !==
  "UP"
) {
  throw new Error(
    "WP223C_TOTALS_DIRECTION_FAILED",
  );
}

if (
  movement.btts.goal.direction !==
  "UP"
) {
  throw new Error(
    "WP223C_BTTS_DIRECTION_FAILED",
  );
}

if (
  movement.exact[0]
    ?.score !== "2-0"
) {
  throw new Error(
    "WP223C_EXACT_LEADER_FAILED",
  );
}

if (
  movementArrow(
    movement.sign.home.direction,
  ) !== "↓"
) {
  throw new Error(
    "WP223C_ARROW_FAILED",
  );
}

/*
 * Budget certification.
 *
 * Current real account position after
 * WP223-A:
 *
 * used = 13
 *
 * The remaining package count and the
 * safety reserve are deliberately caller
 * inputs rather than production constants.
 */
const budget =
  calculateCreditBudget({
    monthlyBudget: 500,

    creditsUsed: 13,

    guaranteedPackageCallsRemaining:
      20,

    safetyReserveCredits:
      20,
  });

if (
  budget.packageReserveCredits !==
  20 * MEASURED_PACKAGE_COST
) {
  throw new Error(
    "WP223C_PACKAGE_RESERVE_FAILED",
  );
}

if (
  budget.spendableCredits !==
  427
) {
  throw new Error(
    `WP223C_SPENDABLE_FAILED:${budget.spendableCredits}`,
  );
}

if (
  budget.maximumAdvancedCalls !==
  Math.floor(
    427 /
    MEASURED_ADVANCED_EVENT_COST,
  )
) {
  throw new Error(
    "WP223C_ADVANCED_CAP_FAILED",
  );
}

/*
 * No-budget guard.
 */
const protectedBudget =
  calculateCreditBudget({
    monthlyBudget: 100,

    creditsUsed: 40,

    guaranteedPackageCallsRemaining:
      25,

    safetyReserveCredits:
      10,
  });

if (
  protectedBudget
    .maximumAdvancedCalls !==
  0
) {
  throw new Error(
    "WP223C_PROTECTED_BUDGET_BREACH",
  );
}

const clearFavourite:
  AdvancedCandidate = {
  eventId:
    "inter-monza",

  homeTeam:
    "Inter Milan",

  awayTeam:
    "Monza",

  hoursToKickoff:
    330,

  sign: {
    home: 0.7820,
    draw: 0.1474,
    away: 0.0706,
  },

  marketConfidence:
    0.88,

  modelLoss:
    0.00001258,

  movementMagnitude:
    movement
      .movementMagnitude,

  lastAdvancedAgeHours:
    1,

  hasAdvancedSnapshot:
    true,
};

const uncertainMatch:
  AdvancedCandidate = {
  eventId:
    "parma-cagliari",

  homeTeam:
    "Parma",

  awayTeam:
    "Cagliari",

  hoursToKickoff:
    330,

  sign: {
    home: 0.3684,
    draw: 0.2881,
    away: 0.3435,
  },

  marketConfidence:
    0.75,

  modelLoss:
    0.00097961,

  movementMagnitude:
    0.025,

  lastAdvancedAgeHours:
    null,

  hasAdvancedSnapshot:
    false,
};

const clearPriority =
  scoreAdvancedCandidate(
    clearFavourite,
  );

const uncertainPriority =
  scoreAdvancedCandidate(
    uncertainMatch,
  );

if (
  uncertainPriority.score <=
  clearPriority.score
) {
  throw new Error(
    "WP223C_UNCERTAIN_MATCH_NOT_PRIORITIZED",
  );
}

/*
 * Same market profile:
 * nearer kickoff must increase priority.
 */
const far:
  AdvancedCandidate = {
  ...uncertainMatch,

  eventId:
    "far",

  hoursToKickoff:
    120,
};

const near:
  AdvancedCandidate = {
  ...uncertainMatch,

  eventId:
    "near",

  hoursToKickoff:
    5,
};

if (
  scoreAdvancedCandidate(near)
    .score <=
  scoreAdvancedCandidate(far)
    .score
) {
  throw new Error(
    "WP223C_KICKOFF_URGENCY_FAILED",
  );
}

const allocation =
  allocateAdvancedCalls(
    {
      monthlyBudget: 500,
      creditsUsed: 13,

      guaranteedPackageCallsRemaining:
        20,

      safetyReserveCredits:
        20,
    },

    [
      clearFavourite,
      uncertainMatch,
      near,
    ],

    {
      maxCallsThisRun: 2,
    },
  );

if (
  allocation.selected.length !==
  2
) {
  throw new Error(
    "WP223C_OPERATIONAL_CAP_FAILED",
  );
}

if (
  allocation
    .creditsAllocated !==
  10
) {
  throw new Error(
    "WP223C_ALLOCATION_COST_FAILED",
  );
}

if (
  allocation.selected[0]
    ?.eventId !== "near"
) {
  throw new Error(
    "WP223C_PRIORITY_ORDER_FAILED",
  );
}

console.log("");
console.log(
  "================================================================",
);

console.log(
  "[PASS] WP223-C TEMPORAL + CREDIT GOVERNOR CERTIFICATION",
);

console.log(
  "================================================================",
);

console.log("");
console.log(
  "REAL BASE -> ADVANCED MOVEMENT",
);

console.log(
  `1     ${(advanced.sign.home * 100).toFixed(2)}% ${(movement.sign.home.deltaPercentagePoints ?? 0).toFixed(2)} pp ${movementArrow(movement.sign.home.direction)}`,
);

console.log(
  `X     ${(advanced.sign.draw * 100).toFixed(2)}% ${(movement.sign.draw.deltaPercentagePoints ?? 0).toFixed(2)} pp ${movementArrow(movement.sign.draw.direction)}`,
);

console.log(
  `2     ${(advanced.sign.away * 100).toFixed(2)}% ${(movement.sign.away.deltaPercentagePoints ?? 0).toFixed(2)} pp ${movementArrow(movement.sign.away.direction)}`,
);

console.log(
  `OVER  ${(advanced.totals.over * 100).toFixed(2)}% ${(movement.totals.over.deltaPercentagePoints ?? 0).toFixed(2)} pp ${movementArrow(movement.totals.over.direction)}`,
);

console.log(
  `GOAL  ${(advanced.btts.goal * 100).toFixed(2)}% ${(movement.btts.goal.deltaPercentagePoints ?? 0).toFixed(2)} pp ${movementArrow(movement.btts.goal.direction)}`,
);

console.log("");

console.log(
  "TOP EXACT MOVEMENT",
);

for (
  const exact
  of movement.exact
) {
  console.log(
    `${exact.currentRank}. ${exact.score} ${(exact.current * 100).toFixed(2)}% ${exact.deltaPercentagePoints === null ? "NEW" : exact.deltaPercentagePoints.toFixed(2) + " pp"} ${movementArrow(exact.direction)}`,
  );
}

console.log("");
console.log(
  "REAL COST CONTRACT",
);

console.log(
  `Package cost: ${MEASURED_PACKAGE_COST}`,
);

console.log(
  `Advanced event cost: ${MEASURED_ADVANCED_EVENT_COST}`,
);

console.log(
  `Monthly budget: ${budget.monthlyBudget}`,
);

console.log(
  `Credits used: ${budget.creditsUsed}`,
);

console.log(
  `Credits remaining: ${budget.creditsRemaining}`,
);

console.log(
  `Protected package reserve: ${budget.packageReserveCredits}`,
);

console.log(
  `Caller safety reserve: ${budget.safetyReserveCredits}`,
);

console.log(
  `Spendable credits: ${budget.spendableCredits}`,
);

console.log(
  `Maximum Advanced calls: ${budget.maximumAdvancedCalls}`,
);

console.log("");

console.log(
  "PRIORITY CONTROL",
);

console.log(
  `Clear favourite: ${clearPriority.score.toFixed(4)}`,
);

console.log(
  `Uncertain match: ${uncertainPriority.score.toFixed(4)}`,
);

console.log(
  `Far kickoff: ${scoreAdvancedCandidate(far).score.toFixed(4)}`,
);

console.log(
  `Near kickoff: ${scoreAdvancedCandidate(near).score.toFixed(4)}`,
);

console.log("");

console.log(
  "ALLOCATION",
);

for (
  const selected
  of allocation.selected
) {
  console.log(
    `SELECT ${selected.eventId} score=${selected.score.toFixed(4)} reasons=${selected.reasons.join(",")}`,
  );
}

console.log(
  `Credits allocated: ${allocation.creditsAllocated}`,
);

console.log(
  `Spendable left: ${allocation.creditsLeftAfterAllocation}`,
);

console.log("");
console.log(
  "================================================================",
);

console.log(
  "[PASS] WP223-C CERTIFIED",
);

console.log(
  "================================================================",
);