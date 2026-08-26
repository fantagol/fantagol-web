import { strict as assert } from "node:assert";

import {
  buildTheOddsBootstrapPendingIntent,
} from "./the-odds-bootstrap-pending-intent";

const first =
  buildTheOddsBootstrapPendingIntent({
    fantagolRoundId:
      "43e943c7-df99-4c0b-8732-e6f505694271",
    eligibleAt:
      "2026-08-25T18:45:00Z",
    competitionCode:
      "SA",
  });

const second =
  buildTheOddsBootstrapPendingIntent({
    fantagolRoundId:
      "43e943c7-df99-4c0b-8732-e6f505694271",
    eligibleAt:
      "2026-08-25T18:45:00.000Z",
    competitionCode:
      "SA",
  });

assert.equal(
  first.idempotencyKey,
  second.idempotencyKey,
);

assert.equal(
  first.mode,
  "prematch",
);

assert.equal(
  first.maxAttempts,
  1,
);

assert.equal(
  first.scheduledAt,
  "2026-08-25T18:45:00.000Z",
);

assert.equal(
  first.payload.provider_code,
  "the_odds_api",
);

assert.equal(
  first.payload.mode,
  "prematch",
);

assert.equal(
  first.payload.bootstrap_discovery,
  true,
);

assert.equal(
  first.payload.fantagol_round_id,
  "43e943c7-df99-4c0b-8732-e6f505694271",
);

assert.equal(
  first.payload.competition_code,
  "SA",
);

assert.equal(
  "match_targets" in first.payload,
  false,
);

assert.equal(
  first.payload.market_snapshot_source,
  "PACKAGE",
);

console.log(
  "[PASS] bootstrap pending idempotency stable",
);

console.log(
  "[PASS] bootstrap payload has no match_targets",
);

console.log(
  "[PASS] bootstrap payload is the_odds_api prematch",
);

console.log(
  "[PASS] bootstrap payload remains PACKAGE not EVENT",
);

console.log(
  "[PASS] bootstrap worker maxAttempts = 1",
);
