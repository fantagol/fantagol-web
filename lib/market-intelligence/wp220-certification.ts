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
} from "./score-distribution";

function odds(probability: number): number {
  return 1 / probability;
}

function bookmaker(
  key: string,
  home: number,
  draw: number,
  away: number,
  over: number,
  under: number,
  yes: number,
  no: number,
): ProviderBookmaker {
  return {
    key,
    title: key.toUpperCase(),
    markets: [
      {
        key: "h2h",
        outcomes: [
          {
            name: "FantaGol Home",
            price: odds(home),
          },
          {
            name: "Draw",
            price: odds(draw),
          },
          {
            name: "FantaGol Away",
            price: odds(away),
          },
        ],
      },
      {
        key: "totals",
        outcomes: [
          {
            name: "Over",
            point: 2.5,
            price: odds(over),
          },
          {
            name: "Under",
            point: 2.5,
            price: odds(under),
          },
        ],
      },
      {
        key: "btts",
        outcomes: [
          {
            name: "Yes",
            price: odds(yes),
          },
          {
            name: "No",
            price: odds(no),
          },
        ],
      },
    ],
  };
}

const bookmakers: ProviderBookmaker[] = [
  bookmaker(
    "bm01",
    0.50,
    0.27,
    0.23,
    0.56,
    0.44,
    0.55,
    0.45,
  ),
  bookmaker(
    "bm02",
    0.49,
    0.28,
    0.23,
    0.55,
    0.45,
    0.56,
    0.44,
  ),
  bookmaker(
    "bm03",
    0.51,
    0.26,
    0.23,
    0.57,
    0.43,
    0.54,
    0.46,
  ),
  bookmaker(
    "bm04",
    0.50,
    0.27,
    0.23,
    0.56,
    0.44,
    0.55,
    0.45,
  ),
  bookmaker(
    "bm05",
    0.48,
    0.28,
    0.24,
    0.55,
    0.45,
    0.54,
    0.46,
  ),
  bookmaker(
    "bm06",
    0.51,
    0.27,
    0.22,
    0.57,
    0.43,
    0.56,
    0.44,
  ),
  bookmaker(
    "bm07",
    0.50,
    0.26,
    0.24,
    0.56,
    0.44,
    0.55,
    0.45,
  ),
  bookmaker(
    "bm08",
    0.49,
    0.27,
    0.24,
    0.55,
    0.45,
    0.55,
    0.45,
  ),

  /*
   * Deliberate malformed outlier.
   * WP219 must reject it rather than let it distort consensus.
   */
  {
    key: "bad-book",
    title: "BAD BOOK",
    markets: [
      {
        key: "h2h",
        outcomes: [
          {
            name: "FantaGol Home",
            price: 1.10,
          },
          {
            name: "Draw",
            price: 1.10,
          },
          {
            name: "FantaGol Away",
            price: 1.10,
          },
        ],
      },
    ],
  },
];

const event: ProviderEventOdds = {
  id: "wp220-cert-event",
  home_team: "FantaGol Home",
  away_team: "FantaGol Away",
  commence_time:
    "2026-08-23T18:45:00Z",
  bookmakers,
};

const input =
  normalizeMarketIntelligenceInput(
    event,
  );

if (
  !input.rejections.some(
    (item) =>
      item.bookmakerKey ===
        "bad-book" &&
      item.reason ===
        "extreme_overround",
  )
) {
  throw new Error(
    "WP220_EXPECTED_OUTLIER_REJECTION_MISSING",
  );
}

const result =
  buildBmInterpolatedResult(
    input,
  );

verifyBmInterpolatedResult(
  result,
);

if (result.exact.length === 0) {
  throw new Error(
    "WP220_EXACT_EMPTY",
  );
}

if (
  result.sign.home <=
    result.sign.away
) {
  throw new Error(
    "WP220_EXPECTED_HOME_ADVANTAGE_MISSING",
  );
}

if (
  result.totals.over <=
    result.totals.under
) {
  throw new Error(
    "WP220_EXPECTED_OVER_SIGNAL_MISSING",
  );
}

if (
  result.confidence <= 0 ||
  result.confidence > 1
) {
  throw new Error(
    "WP220_INVALID_CONFIDENCE",
  );
}

console.log(
  "============================================================",
);

console.log(
  "[PASS] WP220 DETERMINISTIC CERTIFICATION",
);

console.log(
  "============================================================",
);

console.log(
  `Rejected markets: ${input.rejections.length}`,
);

console.log(
  `Input quality: ${input.quality} (${input.qualityScore.toFixed(4)})`,
);

console.log(
  `Lambda home: ${result.lambdaHome.toFixed(3)}`,
);

console.log(
  `Lambda away: ${result.lambdaAway.toFixed(3)}`,
);

console.log("");

console.log("TOP 5 EXACT");

for (
  const exact
  of result.exact.slice(0, 5)
) {
  console.log(
    `${exact.score} ${(exact.probability * 100).toFixed(2)}%`,
  );
}

console.log("");

console.log(
  `SIGN: 1 ${(result.sign.home * 100).toFixed(2)}% | X ${(result.sign.draw * 100).toFixed(2)}% | 2 ${(result.sign.away * 100).toFixed(2)}%`,
);

console.log(
  `U/O 2.5: OVER ${(result.totals.over * 100).toFixed(2)}% | UNDER ${(result.totals.under * 100).toFixed(2)}%`,
);

console.log(
  `G/NG: GOAL ${(result.btts.goal * 100).toFixed(2)}% | NO GOAL ${(result.btts.noGoal * 100).toFixed(2)}%`,
);

console.log("");

console.log(
  `Market confidence: ${(result.marketConfidence * 100).toFixed(2)}%`,
);

console.log(
  `Model loss: ${result.modelFit.totalLoss.toFixed(6)}`,
);

console.log(
  `Final confidence: ${(result.confidence * 100).toFixed(2)}%`,
);

console.log(
  "============================================================",
);