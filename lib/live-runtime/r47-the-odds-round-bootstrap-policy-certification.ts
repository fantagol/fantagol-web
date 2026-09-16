import assert from "node:assert/strict";

import {
  decideTheOddsRoundBootstrap,
} from "./the-odds-round-bootstrap-policy";

function baseInput(
  overrides: Partial<
    Parameters<
      typeof decideTheOddsRoundBootstrap
    >[0]
  > = {},
): Parameters<
  typeof decideTheOddsRoundBootstrap
>[0] {
  return {
    now: new Date(
      "2026-09-13T16:30:00.000Z",
    ),
    currentRoundOpensAt:
      "2026-09-13T16:30:00.000Z",
    previousRoundStatus:
      "live",
    previousRoundEndsAt:
      "2026-09-14T18:45:00.000Z",
    requiredMatchCount:
      10,
    mappedMatchCount:
      0,
    ...overrides,
  };
}

/*
 * R47 / R21-R12 canonical contract:
 *
 * Odds mapping belongs to the CURRENT Round lifecycle.
 * Previous-Round terminal state must not delay Market bootstrap.
 *
 * G5 concrete overlap:
 *   current opens_at      2026-09-13 16:30Z
 *   previous still LIVE
 *   previous ends_at      2026-09-14 18:45Z
 *
 * Therefore G5 mapping bootstrap is due at 2026-09-13 16:30Z.
 */

const beforeOpening =
  decideTheOddsRoundBootstrap(
    baseInput({
      now: new Date(
        "2026-09-13T16:29:59.000Z",
      ),
    }),
  );

assert.equal(
  beforeOpening.action,
  "wait",
);
assert.equal(
  beforeOpening.reason,
  "the_odds_round_bootstrap_not_due",
);
assert.equal(
  beforeOpening.eligibleAt,
  "2026-09-13T16:30:00.000Z",
);

const atOpening =
  decideTheOddsRoundBootstrap(
    baseInput(),
  );

assert.equal(
  atOpening.action,
  "bootstrap",
);
assert.equal(
  atOpening.reason,
  "the_odds_round_bootstrap_due",
);
assert.equal(
  atOpening.eligibleAt,
  "2026-09-13T16:30:00.000Z",
);
assert.equal(
  atOpening.missingMatchCount,
  10,
);

const previousRoundStillLive =
  decideTheOddsRoundBootstrap(
    baseInput({
      previousRoundStatus:
        "live",
      previousRoundEndsAt:
        "2026-09-14T18:45:00.000Z",
    }),
  );

assert.equal(
  previousRoundStillLive.action,
  "bootstrap",
  "previous LIVE Round must not block next-Round Odds mapping bootstrap",
);

const completeMapping =
  decideTheOddsRoundBootstrap(
    baseInput({
      now: new Date(
        "2026-09-13T12:00:00.000Z",
      ),
      mappedMatchCount:
        10,
    }),
  );

assert.equal(
  completeMapping.action,
  "complete",
);
assert.equal(
  completeMapping.reason,
  "the_odds_round_mapping_complete",
);
assert.equal(
  completeMapping.missingMatchCount,
  0,
);

const missingOpening =
  decideTheOddsRoundBootstrap(
    baseInput({
      currentRoundOpensAt:
        null,
    }),
  );

assert.equal(
  missingOpening.action,
  "wait",
);
assert.equal(
  missingOpening.reason,
  "the_odds_round_opening_missing",
);
assert.equal(
  missingOpening.eligibleAt,
  null,
);

assert.throws(
  () =>
    decideTheOddsRoundBootstrap(
      baseInput({
        mappedMatchCount:
          11,
      }),
    ),
  /THE_ODDS_BOOTSTRAP_MAPPED_MATCH_COUNT_INVALID/,
);

console.log(
  "R47_THE_ODDS_BOOTSTRAP_CURRENT_ROUND_OPENING_PASS",
);
console.log(
  "R47_PREVIOUS_LIVE_ROUND_NON_BLOCKING_PASS",
);
console.log(
  "R47_MAPPING_COMPLETE_TERMINAL_PASS",
);
console.log(
  "R47_MISSING_OPENING_FAIL_CLOSED_PASS",
);
console.log(
  "R47_THE_ODDS_ROUND_BOOTSTRAP_POLICY_CERTIFICATION_PASS",
);