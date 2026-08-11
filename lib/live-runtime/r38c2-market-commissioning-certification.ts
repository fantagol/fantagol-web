import assert from "node:assert/strict";

import {
  ODDS_COMMISSIONING_END_AT,
  ODDS_COMMISSIONING_PACKAGE_INTERVAL_SECONDS,
  decideMarketRoundPollingWithCommissioning,
} from "./market-commissioning-policy";

const base = {
  collectionStartsAt: "2026-08-01T00:00:00.000Z",
  opensAt: "2026-07-14T00:45:49.273153Z",
  firstKickoffAt: "2026-08-22T16:30:00.000Z",
  freshSnapshotAvailable: false,
  earlyAdvancedCompleted: false,
  finalAdvancedCompleted: false,
};

const first = decideMarketRoundPollingWithCommissioning({
  ...base,
  now: new Date("2026-08-10T12:00:00.000Z"),
  lastPackageSnapshotAt: null,
});

assert.equal(first.operatingMode, "commissioning");
assert.equal(first.commissioningActive, true);
assert.equal(first.packageSnapshotDue, true);
assert.equal(first.shouldPoll, true);
assert.equal(first.advancedWindow, null);
assert.equal(
  first.reason,
  "commissioning_sparse_package_due",
);

const tooSoon =
  decideMarketRoundPollingWithCommissioning({
    ...base,
    now: new Date("2026-08-11T11:00:00.000Z"),
    lastPackageSnapshotAt:
      "2026-08-10T12:00:00.000Z",
  });

assert.equal(tooSoon.packageSnapshotDue, false);
assert.equal(tooSoon.shouldPoll, false);
assert.equal(tooSoon.advancedWindow, null);
assert.equal(
  tooSoon.reason,
  "commissioning_sparse_wait",
);

const dueAt24h =
  decideMarketRoundPollingWithCommissioning({
    ...base,
    now: new Date("2026-08-11T12:00:00.000Z"),
    lastPackageSnapshotAt:
      "2026-08-10T12:00:00.000Z",
  });

assert.equal(dueAt24h.packageSnapshotDue, true);
assert.equal(dueAt24h.shouldPoll, true);
assert.equal(dueAt24h.advancedWindow, null);

const beforeExpiry =
  decideMarketRoundPollingWithCommissioning({
    ...base,
    now: new Date("2026-08-16T23:59:59.000Z"),
    lastPackageSnapshotAt:
      "2026-08-15T12:00:00.000Z",
  });

assert.equal(
  beforeExpiry.operatingMode,
  "commissioning",
);
assert.equal(beforeExpiry.advancedWindow, null);

const afterExpiry =
  decideMarketRoundPollingWithCommissioning({
    ...base,
    now: new Date(ODDS_COMMISSIONING_END_AT),
    lastPackageSnapshotAt:
      "2026-08-16T12:00:00.000Z",
  });

assert.equal(afterExpiry.operatingMode, "standard");
assert.equal(
  afterExpiry.commissioningActive,
  false,
);
assert.equal(
  afterExpiry.commissioningEndsAt,
  ODDS_COMMISSIONING_END_AT,
);

/*
 * Canonical standard early-window scenario:
 * after commissioning expiry, inside 48h..6h from kickoff,
 * and Surprise Reference already certified/open.
 *
 * Without surpriseReferenceReady=true the canonical policy intentionally
 * remains in opening_grace and suppresses advancedWindow.
 */
const standardEarly =
  decideMarketRoundPollingWithCommissioning({
    ...base,
    surpriseReferenceReady: true,
    now: new Date("2026-08-21T00:00:00.000Z"),
    lastPackageSnapshotAt:
      "2026-08-20T00:00:00.000Z",
  });

assert.equal(
  standardEarly.operatingMode,
  "standard",
);
assert.equal(
  standardEarly.phase,
  "open",
);
assert.equal(
  standardEarly.advancedWindow,
  "early",
);
assert.equal(
  standardEarly.reason,
  "market_intelligence_after_opening",
);

const openingGrace =
  decideMarketRoundPollingWithCommissioning({
    ...base,
    surpriseReferenceReady: false,
    fallbackCandidateAvailable: false,
    now: new Date("2026-08-21T00:00:00.000Z"),
    lastPackageSnapshotAt:
      "2026-08-20T00:00:00.000Z",
  });

assert.equal(
  openingGrace.operatingMode,
  "standard",
);
assert.equal(
  openingGrace.phase,
  "opening_grace",
);
assert.equal(
  openingGrace.advancedWindow,
  null,
);

const afterKickoff =
  decideMarketRoundPollingWithCommissioning({
    ...base,
    surpriseReferenceReady: true,
    now: new Date("2026-08-22T16:30:01.000Z"),
    lastPackageSnapshotAt:
      "2026-08-22T12:00:00.000Z",
  });

assert.equal(afterKickoff.operatingMode, "standard");
assert.equal(afterKickoff.shouldPoll, false);
assert.equal(afterKickoff.advancedWindow, null);

console.log(
  "[PASS] R38-C2-R4 TEMPORARY ODDS COMMISSIONING POLICY",
);
console.log(
  `Commissioning ends: ${ODDS_COMMISSIONING_END_AT}`,
);
console.log(
  `Daily package interval: ${ODDS_COMMISSIONING_PACKAGE_INTERVAL_SECONDS}s`,
);
console.log(
  "[PASS] collectionStartsAt canonical input preserved",
);
console.log(
  "[PASS] T+23h blocked / T+24h due",
);
console.log(
  "[PASS] advanced/event calls suppressed during commissioning",
);
console.log(
  "[PASS] expiry restores canonical standard policy",
);
console.log(
  "[PASS] canonical opening_grace suppression preserved",
);
console.log(
  "[PASS] standard early window activates only in certified open state",
);
console.log(
  "[PASS] first kickoff hard stop preserved",
);
