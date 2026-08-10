import { strict as assert } from "node:assert";

import {
  buildAggregatedPollingPlans,
} from "./aggregated-polling-scheduler";

import {
  resolveFootballDataPollingDecision,
} from "./football-data-polling-policy";

const bootstrapTargets = [
  {
    providerCode: "football_data",
    externalMatchId: "558632",
    kickoffAt: "2026-08-22T16:30:00Z",
    matchStatus: "scheduled",
  },
  {
    providerCode: "football_data",
    externalMatchId: "558629",
    kickoffAt: "2026-08-22T16:30:00Z",
    matchStatus: "scheduled",
  },
];

const bootstrapPlans =
  buildAggregatedPollingPlans({
    providerCode: "football_data",
    competitionCode: "SA",
    now: new Date("2026-08-09T18:30:00Z"),
    targets: bootstrapTargets,
  });

assert.equal(
  bootstrapPlans.length,
  1,
);

assert.equal(
  bootstrapPlans[0]?.mode,
  "prematch",
);

const bootstrapDecision =
  resolveFootballDataPollingDecision({
    now: new Date("2026-08-09T18:30:00Z"),
    mode: "prematch",
    nextKickoffAt:
      new Date("2026-08-22T16:30:00Z"),
  });

assert.equal(
  bootstrapDecision.intervalSeconds,
  21600,
);

const dualPlans =
  buildAggregatedPollingPlans({
    providerCode: "football_data",
    competitionCode: "SA",
    now: new Date("2026-08-22T16:35:00Z"),
    targets: [
      {
        providerCode: "football_data",
        externalMatchId: "558632",
        kickoffAt: "2026-08-22T16:30:00Z",
        matchStatus: "live_first_half",
      },
      {
        providerCode: "football_data",
        externalMatchId: "558631",
        kickoffAt: "2026-08-22T18:45:00Z",
        matchStatus: "scheduled",
      },
    ],
  });

assert.equal(
  dualPlans.length,
  2,
);

assert.equal(
  dualPlans.filter(
    (plan) => plan.mode === "live",
  ).length,
  1,
);

assert.equal(
  dualPlans.filter(
    (plan) => plan.mode === "prematch",
  ).length,
  1,
);

console.log("");
console.log(
  "[PASS] A8D.6.7D PRODUCTION SCHEDULER CONTRACT",
);
console.log(
  "[PASS] bootstrap -> aggregate PREMATCH",
);
console.log(
  "[PASS] bootstrap cadence -> 21600 seconds",
);
console.log(
  "[PASS] live_first_half -> LIVE aggregate",
);
console.log(
  "[PASS] scheduled future Match -> PREMATCH aggregate",
);
console.log(
  "[PASS] dual production planning preserved",
);