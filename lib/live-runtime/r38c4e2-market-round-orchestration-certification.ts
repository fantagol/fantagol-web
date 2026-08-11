import assert from "node:assert/strict";

import {
  movementRows,
} from "./market-intelligence-round-orchestrator";
import {
  decideMarketRoundPollingWithCommissioning,
} from "./market-commissioning-policy";

const decision =
  decideMarketRoundPollingWithCommissioning({
    now:
      new Date(
        "2026-08-10T12:00:00.000Z",
      ),
    collectionStartsAt:
      "2026-08-01T00:00:00.000Z",
    opensAt:
      "2026-07-14T00:45:49.273153Z",
    firstKickoffAt:
      "2026-08-23T16:30:00.000Z",
    lastPackageSnapshotAt:
      null,
    surpriseReferenceReady:
      false,
    freshSnapshotAvailable:
      false,
    fallbackCandidateAvailable:
      false,
    earlyAdvancedCompleted:
      false,
    finalAdvancedCompleted:
      false,
  });

assert.equal(
  decision.commissioningActive,
  true,
);
assert.equal(
  decision.packageSnapshotDue,
  true,
);
assert.equal(
  decision.advancedWindow,
  null,
);

const noPreviousRows =
  movementRows({
    previousCapturedAt: null,
    currentCapturedAt:
      "2026-08-10T12:00:00.000Z",
    previousSource: null,
    currentSource: "PACKAGE",
    exact: [],
    sign: {
      home: {
        previous: null,
        current: 0.40,
        delta: null,
        deltaPercentagePoints: null,
        direction: "FLAT",
      },
      draw: {
        previous: null,
        current: 0.30,
        delta: null,
        deltaPercentagePoints: null,
        direction: "FLAT",
      },
      away: {
        previous: null,
        current: 0.30,
        delta: null,
        deltaPercentagePoints: null,
        direction: "FLAT",
      },
    },
    totals: {
      over: {
        previous: null,
        current: 0.55,
        delta: null,
        deltaPercentagePoints: null,
        direction: "FLAT",
      },
      under: {
        previous: null,
        current: 0.45,
        delta: null,
        deltaPercentagePoints: null,
        direction: "FLAT",
      },
    },
    btts: {
      goal: {
        previous: null,
        current: 0.52,
        delta: null,
        deltaPercentagePoints: null,
        direction: "FLAT",
      },
      noGoal: {
        previous: null,
        current: 0.48,
        delta: null,
        deltaPercentagePoints: null,
        direction: "FLAT",
      },
    },
    marketConfidence: {
      previous: null,
      current: 0.70,
      delta: null,
      deltaPercentagePoints: null,
      direction: "FLAT",
    },
    finalConfidence: {
      previous: null,
      current: 0.68,
      delta: null,
      deltaPercentagePoints: null,
      direction: "FLAT",
    },
    movementMagnitude: 0,
  });

assert.equal(
  noPreviousRows.length,
  0,
);

const movementRowsWithPrevious =
  movementRows({
    previousCapturedAt:
      "2026-08-10T12:00:00.000Z",
    currentCapturedAt:
      "2026-08-11T12:00:00.000Z",
    previousSource: "PACKAGE",
    currentSource: "PACKAGE",
    exact: [
      {
        score: "1-0",
        previous: 0.14,
        current: 0.15,
        delta: 0.01,
        deltaPercentagePoints: 1,
        direction: "UP",
        previousRank: 2,
        currentRank: 1,
        rankDelta: 1,
      },
    ],
    sign: {
      home: {
        previous: 0.40,
        current: 0.41,
        delta: 0.01,
        deltaPercentagePoints: 1,
        direction: "UP",
      },
      draw: {
        previous: 0.30,
        current: 0.29,
        delta: -0.01,
        deltaPercentagePoints: -1,
        direction: "DOWN",
      },
      away: {
        previous: 0.30,
        current: 0.30,
        delta: 0,
        deltaPercentagePoints: 0,
        direction: "FLAT",
      },
    },
    totals: {
      over: {
        previous: 0.55,
        current: 0.56,
        delta: 0.01,
        deltaPercentagePoints: 1,
        direction: "UP",
      },
      under: {
        previous: 0.45,
        current: 0.44,
        delta: -0.01,
        deltaPercentagePoints: -1,
        direction: "DOWN",
      },
    },
    btts: {
      goal: {
        previous: 0.52,
        current: 0.53,
        delta: 0.01,
        deltaPercentagePoints: 1,
        direction: "UP",
      },
      noGoal: {
        previous: 0.48,
        current: 0.47,
        delta: -0.01,
        deltaPercentagePoints: -1,
        direction: "DOWN",
      },
    },
    marketConfidence: {
      previous: 0.70,
      current: 0.71,
      delta: 0.01,
      deltaPercentagePoints: 1,
      direction: "UP",
    },
    finalConfidence: {
      previous: 0.68,
      current: 0.69,
      delta: 0.01,
      deltaPercentagePoints: 1,
      direction: "UP",
    },
    movementMagnitude: 0.01,
  });

assert.equal(
  movementRowsWithPrevious.length,
  10,
);

assert.equal(
  movementRowsWithPrevious[0]?.signal_type,
  "EXACT",
);

assert.equal(
  movementRowsWithPrevious.some(
    (row) =>
      row.signal_type ===
      "MARKET_CONFIDENCE",
  ),
  true,
);

assert.equal(
  movementRowsWithPrevious.some(
    (row) =>
      row.signal_type ===
      "FINAL_CONFIDENCE",
  ),
  true,
);

console.log(
  "[PASS] R38-C4-E2 MARKET ROUND ORCHESTRATION CONTRACT",
);
console.log(
  "[PASS] commissioning -> PACKAGE due / advanced suppressed",
);
console.log(
  "[PASS] first Market snapshot produces no granular movement rows",
);
console.log(
  "[PASS] previous snapshot produces granular Exact/Sign/Totals/BTTS/confidence rows",
);
