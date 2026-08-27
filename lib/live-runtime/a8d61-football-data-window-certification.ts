import { strict as assert } from "node:assert";

import {
  buildFootballDataBatchEndpoint,
} from "./football-data-live-adapter";

const prematch =
  buildFootballDataBatchEndpoint({
    providerCode: "football_data",
    externalMatchIds: [
      "1001",
      "1002",
    ],
    mode: "prematch",
    competitionCode: "SA",

    /*
     * Deliberately stale dates.
     *
     * PREMATCH discovery must remain authoritative for the requested
     * Match IDs even when their real kickoff has moved outside this
     * previously-known calendar window.
     */
    dateFrom: "2026-08-30",
    dateTo: "2026-08-31",
  });

assert.equal(
  prematch,
  "/matches?competitions=SA&ids=1001%2C1002",
);

assert.equal(
  prematch.includes("dateFrom="),
  false,
);

assert.equal(
  prematch.includes("dateTo="),
  false,
);

assert.equal(
  prematch.includes("status="),
  false,
);

const live =
  buildFootballDataBatchEndpoint({
    providerCode: "football_data",
    externalMatchIds: [
      "1001",
      "1002",
    ],
    mode: "live",
    competitionCode: "SA",
  });

assert.equal(
  live,
  "/matches?competitions=SA&status=LIVE",
);

assert.equal(
  live.includes("ids="),
  false,
);

const g2Regression =
  buildFootballDataBatchEndpoint({
    providerCode: "football_data",
    externalMatchIds: [
      "558626",
      "558620",
      "558619",
      "558628",
      "558623",
      "558624",
      "558627",
      "558622",
      "558621",
      "558625",
    ],
    mode: "prematch",
    competitionCode: "SA",

    /*
     * This is the exact stale Giornata 2 window observed in production.
     * The endpoint must no longer use it as a discovery boundary.
     */
    dateFrom: "2026-08-30",
    dateTo: "2026-08-31",
  });

assert.equal(
  g2Regression,
  "/matches?competitions=SA&ids=558626%2C558620%2C558619%2C558628%2C558623%2C558624%2C558627%2C558622%2C558621%2C558625",
);

assert.equal(
  g2Regression.includes("2026-08-30"),
  false,
);

assert.equal(
  g2Regression.includes("2026-08-31"),
  false,
);

assert.throws(
  () =>
    buildFootballDataBatchEndpoint({
      providerCode:
        "football_data",
      externalMatchIds:
        [],
      mode:
        "prematch",
      competitionCode:
        "SA",
    }),
  /requires at least one match id/,
);

assert.throws(
  () =>
    buildFootballDataBatchEndpoint({
      providerCode:
        "football_data",
      externalMatchIds:
        ["NOT_NUMERIC"],
      mode:
        "prematch",
      competitionCode:
        "SA",
    }),
  /Invalid Football-Data match id/,
);

console.log("");
console.log(
  "[PASS] A8D.6.1 FOOTBALL DATA EXACT-ID PREMATCH CONTRACT",
);
console.log("");
console.log(
  "[PASS] PREMATCH uses one exact-ID collection",
);
console.log(
  "[PASS] PREMATCH discovery is independent from stale kickoff dates",
);
console.log(
  "[PASS] Giornata 2 stale-window regression covered",
);
console.log(
  "[PASS] PREMATCH has no LIVE status filter",
);
console.log(
  "[PASS] LIVE aggregate contract unchanged",
);
console.log(
  "[PASS] malformed PREMATCH Match IDs fail closed",
);
