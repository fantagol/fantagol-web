import { strict as assert } from "node:assert";

import {
  decideTheOddsRoundBootstrap,
  THE_ODDS_BOOTSTRAP_DELAY_MS,
} from "./the-odds-round-bootstrap-policy";

assert.equal(
  THE_ODDS_BOOTSTRAP_DELAY_MS,
  86_400_000,
);

const g1EndsAt =
  "2026-08-24T18:45:00.000Z";

const beforeDue =
  decideTheOddsRoundBootstrap({
    now:
      new Date(
        "2026-08-25T18:44:59.000Z",
      ),
    currentRoundOpensAt:
      "2026-08-23T16:30:00.000Z",
    previousRoundStatus:
      "final_calculable",
    previousRoundEndsAt:
      g1EndsAt,
    requiredMatchCount:
      10,
    mappedMatchCount:
      0,
  });

assert.equal(
  beforeDue.action,
  "wait",
);

assert.equal(
  beforeDue.reason,
  "the_odds_round_bootstrap_not_due",
);

assert.equal(
  beforeDue.eligibleAt,
  "2026-08-25T18:45:00.000Z",
);

const realG2State =
  decideTheOddsRoundBootstrap({
    now:
      new Date(
        "2026-08-26T14:57:08.871Z",
      ),
    currentRoundOpensAt:
      "2026-08-23T16:30:00.000Z",
    previousRoundStatus:
      "final_calculable",
    previousRoundEndsAt:
      g1EndsAt,
    requiredMatchCount:
      10,
    mappedMatchCount:
      0,
  });

assert.equal(
  realG2State.action,
  "bootstrap",
);

assert.equal(
  realG2State.reason,
  "the_odds_round_bootstrap_due",
);

assert.equal(
  realG2State.eligibleAt,
  "2026-08-25T18:45:00.000Z",
);

assert.equal(
  realG2State.missingMatchCount,
  10,
);

const partial =
  decideTheOddsRoundBootstrap({
    now:
      new Date(
        "2026-08-26T14:57:08.871Z",
      ),
    currentRoundOpensAt:
      "2026-08-23T16:30:00.000Z",
    previousRoundStatus:
      "final_calculable",
    previousRoundEndsAt:
      g1EndsAt,
    requiredMatchCount:
      10,
    mappedMatchCount:
      6,
  });

assert.equal(
  partial.action,
  "bootstrap",
);

assert.equal(
  partial.missingMatchCount,
  4,
);

const complete =
  decideTheOddsRoundBootstrap({
    now:
      new Date(
        "2026-08-26T14:57:08.871Z",
      ),
    currentRoundOpensAt:
      "2026-08-23T16:30:00.000Z",
    previousRoundStatus:
      "final_calculable",
    previousRoundEndsAt:
      g1EndsAt,
    requiredMatchCount:
      10,
    mappedMatchCount:
      10,
  });

assert.equal(
  complete.action,
  "complete",
);

assert.equal(
  complete.reason,
  "the_odds_round_mapping_complete",
);

const livePrevious =
  decideTheOddsRoundBootstrap({
    now:
      new Date(
        "2026-08-26T14:57:08.871Z",
      ),
    currentRoundOpensAt:
      "2026-08-23T16:30:00.000Z",
    previousRoundStatus:
      "live",
    previousRoundEndsAt:
      g1EndsAt,
    requiredMatchCount:
      10,
    mappedMatchCount:
      0,
  });

assert.equal(
  livePrevious.action,
  "wait",
);

assert.equal(
  livePrevious.reason,
  "the_odds_previous_round_not_certified",
);

console.log(
  "[PASS] close +24h authority",
);

console.log(
  "[PASS] G2 real state => bootstrap required 0/10",
);

console.log(
  "[PASS] partial mapping remains bootstrap required",
);

console.log(
  "[PASS] complete 10/10 mapping exits bootstrap",
);

console.log(
  "[PASS] uncertified previous round fails closed",
);
