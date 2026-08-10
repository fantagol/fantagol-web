import fs from "node:fs";

import type {
  ProviderEventOdds,
} from "./contracts";

import {
  normalizeMarketIntelligenceInput,
} from "./input-normalizer";

import {
  buildBmInterpolatedResult,
  verifyBmInterpolatedResult,
} from "./score-distribution";

const rawPath = "C:\\Users\\io\\Desktop\\fantagol-web\\audit-output\\market-intelligence\\WP223-event-probe\\inter-monza-advanced-raw_2026-08-08_18-55-01.json";

const event =
  JSON.parse(
    fs.readFileSync(
      rawPath,
      "utf8",
    ),
  ) as ProviderEventOdds;

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

const depth =
  new Map(
    input.depth.map(
      (item) => [
        item.marketKey,
        item,
      ],
    ),
  );

const h2h =
  depth.get("h2h");

const totals =
  depth.get("totals");

const alternate =
  depth.get(
    "alternate_totals",
  );

const btts =
  depth.get("btts");

const correctScore =
  depth.get(
    "correct_score",
  );

if (
  !h2h ||
  h2h.validBookmakerCount < 1
) {
  throw new Error(
    "WP223B_H2H_MISSING",
  );
}

if (
  !totals ||
  totals.validBookmakerCount < 1
) {
  throw new Error(
    "WP223B_TOTALS_MISSING",
  );
}

if (
  !alternate ||
  alternate.validBookmakerCount < 1
) {
  throw new Error(
    "WP223B_ALTERNATE_TOTALS_NOT_NORMALIZED",
  );
}

if (
  !btts ||
  btts.validBookmakerCount < 1
) {
  throw new Error(
    "WP223B_BTTS_NOT_NORMALIZED",
  );
}

if (
  !correctScore ||
  correctScore.validBookmakerCount < 1
) {
  throw new Error(
    "WP223B_CORRECT_SCORE_NOT_NORMALIZED",
  );
}

const normalizedAlternate =
  input.markets.filter(
    (market) =>
      market.marketKey ===
      "alternate_totals",
  );

const points =
  new Set(
    normalizedAlternate.flatMap(
      (market) =>
        market.outcomes
          .map(
            (outcome) =>
              outcome.point,
          )
          .filter(
            (
              point,
            ): point is number =>
              point !== null,
          ),
    ),
  );

if (points.size < 3) {
  throw new Error(
    "WP223B_ALTERNATE_TOTAL_LINES_TOO_THIN",
  );
}

console.log("");
console.log(
  "================================================================",
);
console.log(
  "[PASS] WP223-B ADVANCED MARKET CERTIFICATION",
);
console.log(
  "================================================================",
);

console.log(
  `${event.home_team} vs ${event.away_team}`,
);

console.log("");

console.log("MARKET DEPTH");

for (const item of input.depth) {
  console.log(
    `${item.marketKey.padEnd(18)} total=${item.bookmakerCount} valid=${item.validBookmakerCount} rejected=${item.rejectedBookmakerCount} quality=${item.quality}`,
  );
}

console.log("");

console.log(
  `Alternate total lines: ${points.size}`,
);

console.log(
  `Input quality: ${input.quality} ${(input.qualityScore * 100).toFixed(2)}%`,
);

console.log(
  `Lambda: ${result.lambdaHome.toFixed(3)} / ${result.lambdaAway.toFixed(3)}`,
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
  `SIGN 1 ${(result.sign.home * 100).toFixed(2)}% | X ${(result.sign.draw * 100).toFixed(2)}% | 2 ${(result.sign.away * 100).toFixed(2)}%`,
);

console.log(
  `U/O O ${(result.totals.over * 100).toFixed(2)}% | U ${(result.totals.under * 100).toFixed(2)}%`,
);

console.log(
  `G/NG G ${(result.btts.goal * 100).toFixed(2)}% | NG ${(result.btts.noGoal * 100).toFixed(2)}%`,
);

console.log("");

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
  `Correct Score loss: ${result.modelFit.correctScoreError?.toFixed(8) ?? "N/A"}`,
);

console.log(
  `Final confidence: ${(result.confidence * 100).toFixed(2)}%`,
);

console.log(
  "================================================================",
);