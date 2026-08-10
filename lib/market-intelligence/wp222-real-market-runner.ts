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
  type BmInterpolatedResult,
} from "./score-distribution";

const rawPayloadPath = "C:\\Users\\io\\Desktop\\fantagol-web\\audit-output\\market-intelligence\\WP222-real-market\\serie-a-package-raw_2026-08-08_18-42-53.json";
const summaryJsonPath = "C:\\Users\\io\\Desktop\\fantagol-web\\audit-output\\market-intelligence\\WP222-real-market\\bm-interpolated-results_2026-08-08_18-46-33.json";
const summaryTxtPath = "C:\\Users\\io\\Desktop\\fantagol-web\\audit-output\\market-intelligence\\WP222-real-market\\bm-interpolated-results_2026-08-08_18-46-33.txt";

interface EventReport {
  providerEventId: string;
  commenceTime: string | null;
  homeTeam: string;
  awayTeam: string;

  providerBookmakers: number;

  normalizedMarkets: number;
  rejectedMarkets: number;

  depth: Array<{
    marketKey: string;
    bookmakerCount: number;
    validBookmakerCount: number;
    rejectedBookmakerCount: number;
    outcomeCount: number;
    quality: string;
  }>;

  inputQuality: string;
  inputQualityScore: number;

  lambdaHome: number;
  lambdaAway: number;

  topExact: Array<{
    score: string;
    probability: number;
  }>;

  sign: {
    home: number;
    draw: number;
    away: number;
  };

  totals: {
    line: number;
    over: number;
    under: number;
  };

  btts: {
    goal: number;
    noGoal: number;
  };

  marketConfidence: number;

  modelLoss: number;

  modelFit: BmInterpolatedResult["modelFit"];

  confidence: number;
}

interface SkippedEvent {
  providerEventId: string;
  homeTeam: string;
  awayTeam: string;
  stage: string;
  reason: string;
}

const raw =
  fs.readFileSync(
    rawPayloadPath,
    "utf8",
  );

const events =
  JSON.parse(raw) as ProviderEventOdds[];

if (!Array.isArray(events)) {
  throw new Error(
    "WP222_PROVIDER_PAYLOAD_NOT_ARRAY",
  );
}

if (events.length === 0) {
  throw new Error(
    "WP222_NO_EVENTS",
  );
}

const reports: EventReport[] = [];
const skipped: SkippedEvent[] = [];

const orderedEvents =
  [...events].sort(
    (a, b) =>
      String(
        a.commence_time ?? "",
      ).localeCompare(
        String(
          b.commence_time ?? "",
        ),
      ),
  );

for (const event of orderedEvents) {

  let input;

  try {

    input =
      normalizeMarketIntelligenceInput(
        event,
      );

  }
  catch (error) {

    const message =
      error instanceof Error
        ? error.message
        : String(error);

    skipped.push({
      providerEventId:
        event.id,

      homeTeam:
        event.home_team,

      awayTeam:
        event.away_team,

      stage:
        "normalization",

      reason:
        message,
    });

    console.log("");
    console.log(
      `[SKIP] ${event.home_team} vs ${event.away_team}`,
    );
    console.log(
      "Stage: normalization",
    );
    console.log(
      `Reason: ${message}`,
    );

    continue;
  }

  let result;

  try {

    result =
      buildBmInterpolatedResult(
        input,
      );

    verifyBmInterpolatedResult(
      result,
    );

  }
  catch (error) {

    const message =
      error instanceof Error
        ? error.message
        : String(error);

    skipped.push({
      providerEventId:
        event.id,

      homeTeam:
        event.home_team,

      awayTeam:
        event.away_team,

      stage:
        "model",

      reason:
        message,
    });

    console.log("");
    console.log(
      `[SKIP] ${event.home_team} vs ${event.away_team}`,
    );
    console.log(
      "Stage: model",
    );
    console.log(
      `Reason: ${message}`,
    );

    continue;
  }

  const report: EventReport = {
    providerEventId:
      event.id,

    commenceTime:
      event.commence_time ?? null,

    homeTeam:
      event.home_team,

    awayTeam:
      event.away_team,

    providerBookmakers:
      event.bookmakers?.length ?? 0,

    normalizedMarkets:
      input.markets.length,

    rejectedMarkets:
      input.rejections.length,

    depth:
      input.depth.map(
        (item) => ({
          marketKey:
            item.marketKey,

          bookmakerCount:
            item.bookmakerCount,

          validBookmakerCount:
            item.validBookmakerCount,

          rejectedBookmakerCount:
            item.rejectedBookmakerCount,

          outcomeCount:
            item.outcomeCount,

          quality:
            item.quality,
        }),
      ),

    inputQuality:
      input.quality,

    inputQualityScore:
      input.qualityScore,

    lambdaHome:
      result.lambdaHome,

    lambdaAway:
      result.lambdaAway,

    topExact:
      result.exact
        .slice(0, 5)
        .map(
          (item) => ({
            score:
              item.score,

            probability:
              item.probability,
          }),
        ),

    sign: {
      home:
        result.sign.home,

      draw:
        result.sign.draw,

      away:
        result.sign.away,
    },

    totals: {
      line:
        result.totals.line,

      over:
        result.totals.over,

      under:
        result.totals.under,
    },

    btts: {
      goal:
        result.btts.goal,

      noGoal:
        result.btts.noGoal,
    },

    marketConfidence:
      result.marketConfidence,

    modelLoss:
      result.modelFit.totalLoss,

    modelFit:
      result.modelFit,

    confidence:
      result.confidence,
  };

  reports.push(report);

  console.log("");
  console.log(
    "============================================================",
  );

  console.log(
    `${event.home_team} vs ${event.away_team}`,
  );

  console.log(
    `Kickoff: ${event.commence_time ?? "-"}`,
  );

  console.log(
    "============================================================",
  );

  console.log(
    `Provider bookmakers: ${report.providerBookmakers}`,
  );

  console.log(
    `Normalized markets: ${report.normalizedMarkets}`,
  );

  console.log(
    `Rejected markets: ${report.rejectedMarkets}`,
  );

  console.log("");

  console.log(
    "MARKET DEPTH",
  );

  for (const depth of report.depth) {

    console.log(
      `${depth.marketKey.padEnd(18)} total=${String(depth.bookmakerCount).padStart(2)} valid=${String(depth.validBookmakerCount).padStart(2)} rejected=${String(depth.rejectedBookmakerCount).padStart(2)} quality=${depth.quality}`,
    );
  }

  console.log("");

  console.log(
    `Input quality: ${report.inputQuality} ${(report.inputQualityScore * 100).toFixed(2)}%`,
  );

  console.log(
    `Lambda: ${report.lambdaHome.toFixed(3)} / ${report.lambdaAway.toFixed(3)}`,
  );

  console.log("");

  console.log(
    "TOP 5 EXACT",
  );

  for (const exact of report.topExact) {

    console.log(
      `${exact.score.padEnd(5)} ${(exact.probability * 100).toFixed(2)}%`,
    );
  }

  console.log("");

  console.log(
    `SIGN: 1 ${(report.sign.home * 100).toFixed(2)}% | X ${(report.sign.draw * 100).toFixed(2)}% | 2 ${(report.sign.away * 100).toFixed(2)}%`,
  );

  console.log(
    `U/O 2.5: OVER ${(report.totals.over * 100).toFixed(2)}% | UNDER ${(report.totals.under * 100).toFixed(2)}%`,
  );

  console.log(
    `G/NG: GOAL ${(report.btts.goal * 100).toFixed(2)}% | NO GOAL ${(report.btts.noGoal * 100).toFixed(2)}%`,
  );

  console.log("");

  console.log(
    `Market confidence: ${(report.marketConfidence * 100).toFixed(2)}%`,
  );

  console.log(
    `Model loss: ${report.modelLoss.toFixed(8)}`,
  );

  console.log(
    `Final confidence: ${(report.confidence * 100).toFixed(2)}%`,
  );
}

if (reports.length === 0) {

  throw new Error(
    "WP222_NO_EVENT_COULD_BE_MODELED",
  );
}

const output = {
  generatedAt:
    new Date().toISOString(),

  algorithmVersion:
    "BM_INTERPOLATED_V1",

  source:
    "THE_ODDS_API_PACKAGE_OFFLINE",

  providerEventCount:
    events.length,

  modeledEventCount:
    reports.length,

  skippedEventCount:
    skipped.length,

  events:
    reports,

  skipped,
};

fs.writeFileSync(
  summaryJsonPath,
  JSON.stringify(
    output,
    null,
    2,
  ),
  "utf8",
);

const lines: string[] = [];

lines.push(
  "================================================================",
);

lines.push(
  "FANTAGOL - BM_INTERPOLATED_V1",
);

lines.push(
  "WP222 REAL MARKET OFFLINE PROCESSING",
);

lines.push(
  "================================================================",
);

lines.push("");

lines.push(
  `Provider events: ${events.length}`,
);

lines.push(
  `Modeled events: ${reports.length}`,
);

lines.push(
  `Skipped events: ${skipped.length}`,
);

for (const report of reports) {

  lines.push("");

  lines.push(
    "----------------------------------------------------------------",
  );

  lines.push(
    `${report.homeTeam} vs ${report.awayTeam}`,
  );

  lines.push(
    `Kickoff: ${report.commenceTime ?? "-"}`,
  );

  lines.push(
    `Bookmakers: ${report.providerBookmakers}`,
  );

  lines.push(
    `Normalized markets: ${report.normalizedMarkets}`,
  );

  lines.push(
    `Rejected markets: ${report.rejectedMarkets}`,
  );

  lines.push(
    `Input quality: ${report.inputQuality} ${(report.inputQualityScore * 100).toFixed(2)}%`,
  );

  lines.push("");

  lines.push(
    "MARKET DEPTH",
  );

  for (const depth of report.depth) {

    lines.push(
      `${depth.marketKey} total=${depth.bookmakerCount} valid=${depth.validBookmakerCount} rejected=${depth.rejectedBookmakerCount} quality=${depth.quality}`,
    );
  }

  lines.push("");

  lines.push(
    `Lambda: ${report.lambdaHome.toFixed(3)} / ${report.lambdaAway.toFixed(3)}`,
  );

  lines.push("");

  lines.push(
    "TOP 5 EXACT",
  );

  for (const exact of report.topExact) {

    lines.push(
      `${exact.score} ${(exact.probability * 100).toFixed(2)}%`,
    );
  }

  lines.push("");

  lines.push(
    `SIGN 1 ${(report.sign.home * 100).toFixed(2)}% | X ${(report.sign.draw * 100).toFixed(2)}% | 2 ${(report.sign.away * 100).toFixed(2)}%`,
  );

  lines.push(
    `U/O O ${(report.totals.over * 100).toFixed(2)}% | U ${(report.totals.under * 100).toFixed(2)}%`,
  );

  lines.push(
    `G/NG G ${(report.btts.goal * 100).toFixed(2)}% | NG ${(report.btts.noGoal * 100).toFixed(2)}%`,
  );

  lines.push("");

  lines.push(
    `Market confidence: ${(report.marketConfidence * 100).toFixed(2)}%`,
  );

  lines.push(
    `Model loss: ${report.modelLoss.toFixed(8)}`,
  );

  lines.push(
    `Final confidence: ${(report.confidence * 100).toFixed(2)}%`,
  );
}

if (skipped.length > 0) {

  lines.push("");

  lines.push(
    "================================================================",
  );

  lines.push(
    "SKIPPED EVENTS",
  );

  lines.push(
    "================================================================",
  );

  for (const item of skipped) {

    lines.push(
      `${item.homeTeam} vs ${item.awayTeam} | stage=${item.stage} | ${item.reason}`,
    );
  }
}

fs.writeFileSync(
  summaryTxtPath,
  lines.join("\n"),
  "utf8",
);

console.log("");

console.log(
  "================================================================",
);

console.log(
  `[PASS] WP222 MODELED ${reports.length}/${events.length} EVENTS`,
);

console.log(
  `[INFO] WP222 SKIPPED ${skipped.length}/${events.length} EVENTS`,
);

console.log(
  "================================================================",
);