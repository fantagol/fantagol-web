import { strict as assert } from "node:assert";

import {
  buildAggregatedPollingPlans,
} from "./aggregated-polling-scheduler";
import {
  resolveFootballDataPollingDecision,
} from "./football-data-polling-policy";

console.log("");
console.log(
  "================================================================",
);
console.log(
  "FANTAGOL - A8D.6.7B DUAL AGGREGATE + FREQUENCY CERTIFICATION",
);
console.log(
  "================================================================",
);

// ----------------------------------------------------------------
// 1. EARLY BOOTSTRAP
// ----------------------------------------------------------------

const bootstrap =
  resolveFootballDataPollingDecision({
    now:
      new Date(
        "2026-08-09T18:00:00Z",
      ),
    mode: "prematch",
    nextKickoffAt:
      new Date(
        "2026-08-22T16:30:00Z",
      ),
  });

assert.deepEqual(
  bootstrap,
  {
    band:
      "bootstrap_dormant",
    intervalSeconds:
      21600,
    reason:
      "pre_season_bootstrap_until_2026_08_16",
  },
);

console.log(
  "[PASS] 2026-08-09 -> aggregate PREMATCH every 6h",
);

// ----------------------------------------------------------------
// 2. CANONICAL PREMATCH BANDS
// ----------------------------------------------------------------

assert.equal(
  resolveFootballDataPollingDecision({
    now:
      new Date(
        "2026-08-16T00:00:00Z",
      ),
    mode: "prematch",
    nextKickoffAt:
      new Date(
        "2026-08-22T16:30:00Z",
      ),
  }).intervalSeconds,
  10800,
);

console.log(
  "[PASS] >72h -> every 3h",
);

assert.equal(
  resolveFootballDataPollingDecision({
    now:
      new Date(
        "2026-08-20T00:00:00Z",
      ),
    mode: "prematch",
    nextKickoffAt:
      new Date(
        "2026-08-22T16:30:00Z",
      ),
  }).intervalSeconds,
  3600,
);

console.log(
  "[PASS] 72h..24h -> every 60m",
);

assert.equal(
  resolveFootballDataPollingDecision({
    now:
      new Date(
        "2026-08-22T00:00:00Z",
      ),
    mode: "prematch",
    nextKickoffAt:
      new Date(
        "2026-08-22T16:30:00Z",
      ),
  }).intervalSeconds,
  1800,
);

console.log(
  "[PASS] 24h..3h -> every 30m",
);

assert.equal(
  resolveFootballDataPollingDecision({
    now:
      new Date(
        "2026-08-22T14:00:00Z",
      ),
    mode: "prematch",
    nextKickoffAt:
      new Date(
        "2026-08-22T16:30:00Z",
      ),
  }).intervalSeconds,
  600,
);

console.log(
  "[PASS] <3h -> every 10m",
);

assert.equal(
  resolveFootballDataPollingDecision({
    now:
      new Date(
        "2026-08-22T16:31:00Z",
      ),
    mode: "live",
  }).intervalSeconds,
  60,
);

console.log(
  "[PASS] LIVE -> every 60s",
);

// ----------------------------------------------------------------
// 3. DUAL SATURDAY / SUNDAY / MONDAY PLAN
// ----------------------------------------------------------------

const dualPlans =
  buildAggregatedPollingPlans({
    providerCode:
      "football_data",
    competitionCode:
      "SA",
    now:
      new Date(
        "2026-08-22T16:45:00Z",
      ),
    targets: [
      {
        providerCode:
          "football_data",
        externalMatchId:
          "1001",
        kickoffAt:
          "2026-08-22T16:30:00Z",
        matchStatus:
          "live",
      },
      {
        providerCode:
          "football_data",
        externalMatchId:
          "1002",
        kickoffAt:
          "2026-08-23T18:45:00Z",
        matchStatus:
          "scheduled",
      },
      {
        providerCode:
          "football_data",
        externalMatchId:
          "1003",
        kickoffAt:
          "2026-08-24T18:45:00Z",
        matchStatus:
          "scheduled",
      },
    ],
  });

assert.equal(
  dualPlans.length,
  2,
);

const livePlan =
  dualPlans.find(
    (plan) =>
      plan.mode === "live",
  );

const prematchPlan =
  dualPlans.find(
    (plan) =>
      plan.mode === "prematch",
  );

assert.deepEqual(
  livePlan,
  {
    mode:
      "live",
    providerCode:
      "football_data",
    externalMatchIds:
      ["1001"],
    competitionCode:
      "SA",
  },
);

assert.deepEqual(
  prematchPlan,
  {
    mode:
      "prematch",
    providerCode:
      "football_data",
    externalMatchIds:
      ["1002", "1003"],
    competitionCode:
      "SA",
    dateFrom:
      "2026-08-23",
    dateTo:
      "2026-08-25",
  },
);

console.log(
  "[PASS] Saturday LIVE and Sunday/Monday PREMATCH coexist",
);

console.log(
  "[PASS] LIVE target excluded from PREMATCH aggregate",
);

console.log(
  "[PASS] future fixtures remain schedule-monitored during LIVE",
);

// ----------------------------------------------------------------
// 4. NO DUPLICATION
// ----------------------------------------------------------------

const deduplicated =
  buildAggregatedPollingPlans({
    providerCode:
      "football_data",
    now:
      new Date(
        "2026-08-16T00:00:00Z",
      ),
    targets: [
      {
        providerCode:
          "football_data",
        externalMatchId:
          "1001",
        kickoffAt:
          "2026-08-22T16:30:00Z",
        matchStatus:
          "scheduled",
      },
      {
        providerCode:
          "football_data",
        externalMatchId:
          "1001",
        kickoffAt:
          "2026-08-22T16:30:00Z",
        matchStatus:
          "scheduled",
      },
    ],
  });

assert.equal(
  deduplicated.length,
  1,
);

assert.equal(
  deduplicated[0]?.externalMatchIds.length,
  1,
);

console.log(
  "[PASS] duplicate provider IDs collapsed",
);

console.log("");
console.log(
  "[PASS] A8D.6.7B DUAL AGGREGATE POLICY CERTIFIED",
);