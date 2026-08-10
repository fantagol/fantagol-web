import { strict as assert } from "node:assert";

import { resolveRefreshRoundSideEffects } from "./refresh-round-side-effects";

type Scenario = {
  name: string;
  changeType: string;
  matchStatus: string;
  refreshedApplied: boolean;
  expectedMaterialize: boolean;
  expectedRebuild: boolean;
};

const scenarios: Scenario[] = [
  {
    name: "POSTPONED_APPLIED",
    changeType: "MATCH_POSTPONED",
    matchStatus: "postponed",
    refreshedApplied: true,
    expectedMaterialize: true,
    expectedRebuild: true,
  },
  {
    name: "POSTPONED_RETRY_ALREADY_APPLIED",
    changeType: "MATCH_POSTPONED",
    matchStatus: "postponed",
    refreshedApplied: false,
    expectedMaterialize: true,
    expectedRebuild: true,
  },
  {
    name: "SCORE_CHANGED_BASELINE",
    changeType: "MATCH_SCORE_CHANGED",
    matchStatus: "live",
    refreshedApplied: true,
    expectedMaterialize: false,
    expectedRebuild: true,
  },
  {
    name: "SCORE_CHANGED_NOOP_RETRY",
    changeType: "MATCH_SCORE_CHANGED",
    matchStatus: "live",
    refreshedApplied: false,
    expectedMaterialize: false,
    expectedRebuild: false,
  },
  {
    name: "POSTPONED_CHANGE_WITH_WRONG_STATUS",
    changeType: "MATCH_POSTPONED",
    matchStatus: "live",
    refreshedApplied: true,
    expectedMaterialize: false,
    expectedRebuild: true,
  },
];

console.log("");
console.log("================================================================");
console.log("FANTAGOL - A8D.6P.9");
console.log("POSTPONED LIVE BRIDGE OFFLINE CERTIFICATION");
console.log("================================================================");
console.log("");

for (const scenario of scenarios) {
  const result = resolveRefreshRoundSideEffects({
    changeType: scenario.changeType,
    matchStatus: scenario.matchStatus,
    refreshedApplied: scenario.refreshedApplied,
  });

  assert.equal(
    result.materializePostponed,
    scenario.expectedMaterialize,
    `${scenario.name}: materializePostponed`,
  );

  assert.equal(
    result.enqueueRebuild,
    scenario.expectedRebuild,
    `${scenario.name}: enqueueRebuild`,
  );

  console.log(
    `[PASS] ${scenario.name} | ` +
      `materialize=${String(result.materializePostponed)} | ` +
      `rebuild=${String(result.enqueueRebuild)}`,
  );
}

const postponedApplied =
  resolveRefreshRoundSideEffects({
    changeType: "MATCH_POSTPONED",
    matchStatus: "postponed",
    refreshedApplied: true,
  });

const postponedRetry =
  resolveRefreshRoundSideEffects({
    changeType: "MATCH_POSTPONED",
    matchStatus: "postponed",
    refreshedApplied: false,
  });

const scoreChanged =
  resolveRefreshRoundSideEffects({
    changeType: "MATCH_SCORE_CHANGED",
    matchStatus: "live",
    refreshedApplied: true,
  });

assert.deepEqual(postponedApplied, {
  materializePostponed: true,
  enqueueRebuild: true,
});

assert.deepEqual(postponedRetry, {
  materializePostponed: true,
  enqueueRebuild: true,
});

assert.deepEqual(scoreChanged, {
  materializePostponed: false,
  enqueueRebuild: true,
});

console.log("");
console.log(
  "[PASS] MATCH_POSTPONED materializes governance",
);
console.log(
  "[PASS] MATCH_POSTPONED retry recovers governance when refreshed.applied=false",
);
console.log(
  "[PASS] MATCH_SCORE_CHANGED never enters Postponed Governance",
);
console.log(
  "[PASS] Historical rebuild behavior preserved for applied normal changes",
);
console.log("");
console.log(
  "[PASS] A8D.6P.9 OFFLINE BEHAVIOR CERTIFICATION COMPLETE",
);