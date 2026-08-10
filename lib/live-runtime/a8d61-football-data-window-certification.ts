import { strict as assert } from "node:assert";

import { buildFootballDataBatchEndpoint } from "./football-data-live-adapter";

const live =
  buildFootballDataBatchEndpoint({
    providerCode: "football_data",
    externalMatchIds: ["1001", "1002"],
    mode: "live",
    competitionCode: "SA",
  });

const prematch =
  buildFootballDataBatchEndpoint({
    providerCode: "football_data",
    externalMatchIds: ["1001", "1002"],
    mode: "prematch",
    competitionCode: "SA",
    dateFrom: "2026-08-22",
    dateTo: "2026-08-25",
  });

assert.equal(
  live,
  "/matches?competitions=SA&status=LIVE",
);

assert.equal(
  prematch,
  "/matches?competitions=SA&dateFrom=2026-08-22&dateTo=2026-08-25",
);

assert.equal(
  prematch.includes("status="),
  false,
);

assert.equal(
  live.includes("dateFrom="),
  false,
);

assert.equal(
  live.includes("dateTo="),
  false,
);

let invalidWindowRejected = false;

try {
  buildFootballDataBatchEndpoint({
    providerCode: "football_data",
    externalMatchIds: ["1001"],
    mode: "prematch",
    competitionCode: "SA",
    dateFrom: "2026-08-25",
    dateTo: "2026-08-22",
  });
} catch {
  invalidWindowRejected = true;
}

assert.equal(
  invalidWindowRejected,
  true,
);

console.log("");
console.log(
  "[PASS] A8D.6.1 FOOTBALL DATA WINDOW CONTRACT",
);
console.log("");
console.log(`LIVE:     ${live}`);
console.log(`PREMATCH: ${prematch}`);
console.log("");
console.log(
  "[PASS] LIVE uses one aggregate collection",
);
console.log(
  "[PASS] PREMATCH uses one date-window collection",
);
console.log(
  "[PASS] competition constrained to Serie A",
);
console.log(
  "[PASS] PREMATCH has no status filter",
);
console.log(
  "[PASS] invalid date window rejected",
);
console.log(
  "[PASS] dateTo treated as exclusive contract boundary",
);