import type {
  ProviderBookmaker,
  ProviderEventOdds,
} from "./contracts";

import {
  normalizeMarketIntelligenceInput,
} from "./input-normalizer";

import {
  buildBmInterpolatedResult,
  verifyBmInterpolatedResult,
  type BmInterpolatedResult,
} from "./score-distribution";

interface ScenarioMarket {
  home: number;
  draw: number;
  away: number;

  over: number;
  under: number;

  goal: number;
  noGoal: number;
}

interface Scenario {
  code: string;
  description: string;

  market: ScenarioMarket;

  bookmakerCount: number;

  dispersion:
    | "tight"
    | "wide";

  expect:
    | "HOME"
    | "DRAW_BALANCED"
    | "AWAY";

  expectTotals:
    | "OVER"
    | "UNDER";

  expectBtts?:
    | "GOAL"
    | "NO_GOAL";
}

interface ScenarioResult {
  scenario: Scenario;
  result: BmInterpolatedResult;
  rejectionCount: number;
  inputQualityScore: number;
}

function decimalOdds(
  probability: number,
): number {
  return 1 / probability;
}

function clamp(
  value: number,
  minimum: number,
  maximum: number,
): number {
  return Math.max(
    minimum,
    Math.min(maximum, value),
  );
}

function normalizeThree(
  home: number,
  draw: number,
  away: number,
): [number, number, number] {
  const sum =
    home + draw + away;

  return [
    home / sum,
    draw / sum,
    away / sum,
  ];
}

function bookmakerVariation(
  index: number,
  dispersion: "tight" | "wide",
): number {
  const pattern = [
    -1,
    0.5,
    1,
    -0.5,
    0,
    0.75,
    -0.75,
    0.25,
    -0.25,
    0.6,
    -0.6,
    0.4,
  ];

  const unit =
    pattern[
      index %
      pattern.length
    ];

  return unit *
    (
      dispersion === "tight"
        ? 0.006
        : 0.055
    );
}

function createBookmaker(
  scenario: Scenario,
  index: number,
): ProviderBookmaker {
  const delta =
    bookmakerVariation(
      index,
      scenario.dispersion,
    );

  const base =
    scenario.market;

  /*
   * Vary home and away in opposite directions.
   * Draw varies only slightly.
   */
  const rawHome =
    clamp(
      base.home + delta,
      0.05,
      0.88,
    );

  const rawAway =
    clamp(
      base.away - delta,
      0.05,
      0.88,
    );

  const rawDraw =
    clamp(
      base.draw -
        delta * 0.15,
      0.08,
      0.60,
    );

  const [
    home,
    draw,
    away,
  ] =
    normalizeThree(
      rawHome,
      rawDraw,
      rawAway,
    );

  const over =
    clamp(
      base.over +
        delta * 0.65,
      0.08,
      0.92,
    );

  const under =
    1 - over;

  const goal =
    clamp(
      base.goal +
        delta * 0.50,
      0.08,
      0.92,
    );

  const noGoal =
    1 - goal;

  return {
    key:
      `${scenario.code.toLowerCase()}-bm-${String(index + 1).padStart(2, "0")}`,

    title:
      `${scenario.code} BM ${index + 1}`,

    markets: [
      {
        key: "h2h",
        outcomes: [
          {
            name: "FantaGol Home",
            price:
              decimalOdds(home),
          },
          {
            name: "Draw",
            price:
              decimalOdds(draw),
          },
          {
            name: "FantaGol Away",
            price:
              decimalOdds(away),
          },
        ],
      },

      {
        key: "totals",
        outcomes: [
          {
            name: "Over",
            point: 2.5,
            price:
              decimalOdds(over),
          },
          {
            name: "Under",
            point: 2.5,
            price:
              decimalOdds(under),
          },
        ],
      },

      {
        key: "btts",
        outcomes: [
          {
            name: "Yes",
            price:
              decimalOdds(goal),
          },
          {
            name: "No",
            price:
              decimalOdds(noGoal),
          },
        ],
      },
    ],
  };
}

function buildEvent(
  scenario: Scenario,
): ProviderEventOdds {
  const bookmakers =
    Array.from(
      {
        length:
          scenario.bookmakerCount,
      },
      (_, index) =>
        createBookmaker(
          scenario,
          index,
        ),
    );

  return {
    id:
      `wp221-${scenario.code.toLowerCase()}`,

    home_team:
      "FantaGol Home",

    away_team:
      "FantaGol Away",

    commence_time:
      "2026-08-23T18:45:00Z",

    bookmakers,
  };
}

const scenarios: Scenario[] = [
  {
    code: "A",
    description:
      "Strong home favourite + open match",

    market: {
      home: 0.68,
      draw: 0.19,
      away: 0.13,

      over: 0.67,
      under: 0.33,

      goal: 0.56,
      noGoal: 0.44,
    },

    bookmakerCount: 10,
    dispersion: "tight",

    expect: "HOME",
    expectTotals: "OVER",
    expectBtts: "GOAL",
  },

  {
    code: "B",
    description:
      "Strong away favourite + closed match",

    market: {
      home: 0.17,
      draw: 0.25,
      away: 0.58,

      over: 0.34,
      under: 0.66,

      goal: 0.38,
      noGoal: 0.62,
    },

    bookmakerCount: 10,
    dispersion: "tight",

    expect: "AWAY",
    expectTotals: "UNDER",
    expectBtts: "NO_GOAL",
  },

  {
    code: "C",
    description:
      "Balanced match + Under",

    market: {
      home: 0.36,
      draw: 0.32,
      away: 0.32,

      over: 0.32,
      under: 0.68,

      goal: 0.39,
      noGoal: 0.61,
    },

    bookmakerCount: 10,
    dispersion: "tight",

    expect: "DRAW_BALANCED",
    expectTotals: "UNDER",
    expectBtts: "NO_GOAL",
  },

  {
    code: "D",
    description:
      "Balanced match + high scoring",

    market: {
      home: 0.38,
      draw: 0.27,
      away: 0.35,

      over: 0.72,
      under: 0.28,

      goal: 0.69,
      noGoal: 0.31,
    },

    bookmakerCount: 10,
    dispersion: "tight",

    expect: "DRAW_BALANCED",
    expectTotals: "OVER",
    expectBtts: "GOAL",
  },

  {
    code: "E",
    description:
      "Contradictory markets stress case",

    market: {
      home: 0.61,
      draw: 0.23,
      away: 0.16,

      /*
       * Strong home dominance combined with
       * very low scoring and high BTTS.
       * The canonical matrix cannot perfectly
       * satisfy all three simultaneously.
       */
      over: 0.28,
      under: 0.72,

      goal: 0.68,
      noGoal: 0.32,
    },

    bookmakerCount: 10,
    dispersion: "tight",

    expect: "HOME",
    expectTotals: "UNDER",
  },

  {
    code: "F_TIGHT",
    description:
      "Confidence control - tight bookmakers",

    market: {
      home: 0.50,
      draw: 0.27,
      away: 0.23,

      over: 0.56,
      under: 0.44,

      goal: 0.55,
      noGoal: 0.45,
    },

    bookmakerCount: 10,
    dispersion: "tight",

    expect: "HOME",
    expectTotals: "OVER",
    expectBtts: "GOAL",
  },

  {
    code: "F_WIDE",
    description:
      "Confidence control - dispersed bookmakers",

    market: {
      home: 0.50,
      draw: 0.27,
      away: 0.23,

      over: 0.56,
      under: 0.44,

      goal: 0.55,
      noGoal: 0.45,
    },

    bookmakerCount: 10,
    dispersion: "wide",

    expect: "HOME",
    expectTotals: "OVER",
    expectBtts: "GOAL",
  },
];

function assertProbability(
  value: number,
  label: string,
): void {
  if (
    !Number.isFinite(value) ||
    value < 0 ||
    value > 1
  ) {
    throw new Error(
      `WP221_INVALID_PROBABILITY:${label}:${value}`,
    );
  }
}

function certifyScenario(
  scenario: Scenario,
): ScenarioResult {
  const event =
    buildEvent(scenario);

  const input =
    normalizeMarketIntelligenceInput(
      event,
    );

  const result =
    buildBmInterpolatedResult(
      input,
    );

  verifyBmInterpolatedResult(
    result,
  );

  assertProbability(
    result.sign.home,
    `${scenario.code}:home`,
  );

  assertProbability(
    result.sign.draw,
    `${scenario.code}:draw`,
  );

  assertProbability(
    result.sign.away,
    `${scenario.code}:away`,
  );

  assertProbability(
    result.totals.over,
    `${scenario.code}:over`,
  );

  assertProbability(
    result.totals.under,
    `${scenario.code}:under`,
  );

  assertProbability(
    result.btts.goal,
    `${scenario.code}:goal`,
  );

  assertProbability(
    result.btts.noGoal,
    `${scenario.code}:noGoal`,
  );

  assertProbability(
    result.marketConfidence,
    `${scenario.code}:marketConfidence`,
  );

  assertProbability(
    result.confidence,
    `${scenario.code}:confidence`,
  );

  if (
    !Number.isFinite(
      result.modelFit.totalLoss,
    ) ||
    result.modelFit.totalLoss < 0
  ) {
    throw new Error(
      `WP221_INVALID_MODEL_LOSS:${scenario.code}`,
    );
  }

  if (scenario.expect === "HOME") {
    if (
      result.sign.home <=
        result.sign.draw ||
      result.sign.home <=
        result.sign.away
    ) {
      throw new Error(
        `WP221_HOME_SIGNAL_FAILED:${scenario.code}`,
      );
    }
  }

  if (scenario.expect === "AWAY") {
    if (
      result.sign.away <=
        result.sign.home ||
      result.sign.away <=
        result.sign.draw
    ) {
      throw new Error(
        `WP221_AWAY_SIGNAL_FAILED:${scenario.code}`,
      );
    }
  }

  if (
    scenario.expect ===
    "DRAW_BALANCED"
  ) {
    const homeAwayGap =
      Math.abs(
        result.sign.home -
        result.sign.away,
      );

    if (homeAwayGap > 0.15) {
      throw new Error(
        `WP221_BALANCE_FAILED:${scenario.code}:${homeAwayGap}`,
      );
    }
  }

  if (
    scenario.expectTotals ===
    "OVER"
  ) {
    if (
      result.totals.over <=
      result.totals.under
    ) {
      throw new Error(
        `WP221_OVER_SIGNAL_FAILED:${scenario.code}`,
      );
    }
  }

  if (
    scenario.expectTotals ===
    "UNDER"
  ) {
    if (
      result.totals.under <=
      result.totals.over
    ) {
      throw new Error(
        `WP221_UNDER_SIGNAL_FAILED:${scenario.code}`,
      );
    }
  }

  /*
   * E is intentionally contradictory.
   * We do not require BTTS direction there:
   * model loss is what must expose the conflict.
   */
  if (
    scenario.expectBtts === "GOAL"
  ) {
    if (
      result.btts.goal <=
      result.btts.noGoal
    ) {
      throw new Error(
        `WP221_GOAL_SIGNAL_FAILED:${scenario.code}`,
      );
    }
  }

  if (
    scenario.expectBtts ===
    "NO_GOAL"
  ) {
    if (
      result.btts.noGoal <=
      result.btts.goal
    ) {
      throw new Error(
        `WP221_NO_GOAL_SIGNAL_FAILED:${scenario.code}`,
      );
    }
  }

  return {
    scenario,
    result,
    rejectionCount:
      input.rejections.length,
    inputQualityScore:
      input.qualityScore,
  };
}

const results =
  scenarios.map(
    certifyScenario,
  );

const byCode =
  new Map(
    results.map(
      (item) => [
        item.scenario.code,
        item,
      ],
    ),
  );

const tight =
  byCode.get("F_TIGHT");

const wide =
  byCode.get("F_WIDE");

if (!tight || !wide) {
  throw new Error(
    "WP221_CONFIDENCE_CONTROL_MISSING",
  );
}

/*
 * Same central market, same depth:
 * greater bookmaker disagreement must not
 * produce greater market confidence.
 */
if (
  wide.result.marketConfidence >=
  tight.result.marketConfidence
) {
  throw new Error(
    `WP221_CONFIDENCE_MONOTONICITY_FAILED:${tight.result.marketConfidence}:${wide.result.marketConfidence}`,
  );
}

const contradictory =
  byCode.get("E");

const reference =
  byCode.get("F_TIGHT");

if (
  !contradictory ||
  !reference
) {
  throw new Error(
    "WP221_MODEL_FIT_CONTROL_MISSING",
  );
}

/*
 * Contradictory markets should fit worse than
 * a conventional internally compatible market.
 */
if (
  contradictory.result.modelFit.totalLoss <=
  reference.result.modelFit.totalLoss
) {
  throw new Error(
    `WP221_CONTRADICTION_NOT_DETECTED:${contradictory.result.modelFit.totalLoss}:${reference.result.modelFit.totalLoss}`,
  );
}

console.log("");
console.log(
  "================================================================",
);
console.log(
  "[PASS] WP221 STRESS & COHERENCE CERTIFICATION",
);
console.log(
  "================================================================",
);

for (const item of results) {
  const {
    scenario,
    result,
  } = item;

  console.log("");
  console.log(
    `--- ${scenario.code}: ${scenario.description} ---`,
  );

  console.log(
    `Lambda: ${result.lambdaHome.toFixed(3)} / ${result.lambdaAway.toFixed(3)}`,
  );

  console.log(
    `Exact #1: ${result.exact[0]?.score ?? "-"} ${((result.exact[0]?.probability ?? 0) * 100).toFixed(2)}%`,
  );

  console.log(
    `Exact #2: ${result.exact[1]?.score ?? "-"} ${((result.exact[1]?.probability ?? 0) * 100).toFixed(2)}%`,
  );

  console.log(
    `Exact #3: ${result.exact[2]?.score ?? "-"} ${((result.exact[2]?.probability ?? 0) * 100).toFixed(2)}%`,
  );

  console.log(
    `SIGN  1 ${(result.sign.home * 100).toFixed(2)}% | X ${(result.sign.draw * 100).toFixed(2)}% | 2 ${(result.sign.away * 100).toFixed(2)}%`,
  );

  console.log(
    `U/O   O ${(result.totals.over * 100).toFixed(2)}% | U ${(result.totals.under * 100).toFixed(2)}%`,
  );

  console.log(
    `G/NG  G ${(result.btts.goal * 100).toFixed(2)}% | NG ${(result.btts.noGoal * 100).toFixed(2)}%`,
  );

  console.log(
    `Input quality: ${(item.inputQualityScore * 100).toFixed(2)}%`,
  );

  console.log(
    `Market confidence: ${(result.marketConfidence * 100).toFixed(2)}%`,
  );

  console.log(
    `Model loss: ${result.modelFit.totalLoss.toFixed(8)}`,
  );

  console.log(
    `H2H loss: ${result.modelFit.h2hError?.toFixed(8) ?? "N/A"}`,
  );

  console.log(
    `Totals loss: ${result.modelFit.totalsError?.toFixed(8) ?? "N/A"}`,
  );

  console.log(
    `BTTS loss: ${result.modelFit.bttsError?.toFixed(8) ?? "N/A"}`,
  );

  console.log(
    `Final confidence: ${(result.confidence * 100).toFixed(2)}%`,
  );
}

console.log("");
console.log(
  "=== CONFIDENCE MONOTONICITY ===",
);

console.log(
  `TIGHT market confidence: ${(tight.result.marketConfidence * 100).toFixed(2)}%`,
);

console.log(
  `WIDE market confidence: ${(wide.result.marketConfidence * 100).toFixed(2)}%`,
);

console.log(
  "[PASS] Greater bookmaker dispersion lowers market confidence",
);

console.log("");
console.log(
  "=== CONTRADICTION DETECTION ===",
);

console.log(
  `Compatible loss: ${reference.result.modelFit.totalLoss.toFixed(8)}`,
);

console.log(
  `Contradictory loss: ${contradictory.result.modelFit.totalLoss.toFixed(8)}`,
);

console.log(
  "[PASS] Contradictory markets produce higher model loss",
);

console.log("");
console.log(
  "================================================================",
);
console.log(
  "[PASS] ALL WP221 SCENARIOS CERTIFIED",
);
console.log(
  "================================================================",
);