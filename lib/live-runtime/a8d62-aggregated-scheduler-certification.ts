import { strict as assert } from "node:assert";

import {
  buildAggregatedPollingPlan,
} from "./aggregated-polling-scheduler";

const prematch =
  buildAggregatedPollingPlan({
    providerCode: "football_data",
    now: new Date("2026-08-20T12:00:00Z"),
    targets: [
      {
        providerCode: "football_data",
        externalMatchId: "1001",
        kickoffAt: "2026-08-22T16:30:00Z",
      },
      {
        providerCode: "football_data",
        externalMatchId: "1002",
        kickoffAt: "2026-08-24T18:45:00Z",
      },
    ],
  });

assert.deepEqual(prematch, {
  mode: "prematch",
  providerCode: "football_data",
  externalMatchIds: ["1001", "1002"],
  competitionCode: "SA",
  dateFrom: "2026-08-22",
  dateTo: "2026-08-25",
});

const live =
  buildAggregatedPollingPlan({
    providerCode: "football_data",
    now: new Date("2026-08-22T16:31:00Z"),
    targets: [
      {
        providerCode: "football_data",
        externalMatchId: "1001",
        kickoffAt: "2026-08-22T16:30:00Z",
        matchStatus: "live",
      },
      {
        providerCode: "football_data",
        externalMatchId: "1002",
        kickoffAt: "2026-08-22T18:45:00Z",
        matchStatus: "live",
      },
    ],
  });

assert.deepEqual(live, {
  mode: "live",
  providerCode: "football_data",
  externalMatchIds: ["1001", "1002"],
  competitionCode: "SA",
});

const deduped =
  buildAggregatedPollingPlan({
    providerCode: "football_data",
    now: new Date("2026-08-20T12:00:00Z"),
    targets: [
      {
        providerCode: "football_data",
        externalMatchId: "1001",
        kickoffAt: "2026-08-22T16:30:00Z",
      },
      {
        providerCode: "football_data",
        externalMatchId: "1001",
        kickoffAt: "2026-08-22T16:30:00Z",
      },
    ],
  });

assert.equal(
  deduped?.externalMatchIds.length,
  1,
);

const empty =
  buildAggregatedPollingPlan({
    providerCode: "football_data",
    now: new Date(),
    targets: [],
  });

assert.equal(empty, null);

console.log("");
console.log(
  "[PASS] A8D.6.2 AGGREGATED SCHEDULER CONTRACT",
);
console.log("");
console.log(
  "[PASS] N prematch Match targets -> 1 prematch provider plan",
);
console.log(
  "[PASS] started Match set -> 1 live provider plan",
);
console.log(
  "[PASS] external Match IDs deduplicated",
);
console.log(
  "[PASS] dateTo extends one day beyond final kickoff date",
);
console.log(
  "[PASS] empty target set -> no provider plan",
);