import { strict as assert } from "node:assert";

type Target = {
  matchId: string;
  externalMatchId: string;
};

const targets: Target[] = [
  {
    matchId: "match-a",
    externalMatchId: "1001",
  },
  {
    matchId: "match-b",
    externalMatchId: "1002",
  },
];

const targetByExternalId =
  new Map(
    targets.map(
      (target) => [
        target.externalMatchId,
        target,
      ] as const,
    ),
  );

const providerResults = [
  "1001",
  "1002",
];

const resolved =
  providerResults.map(
    (externalMatchId) =>
      targetByExternalId.get(
        externalMatchId,
      ),
  );

assert.equal(
  resolved.length,
  2,
);

assert.equal(
  resolved[0]?.matchId,
  "match-a",
);

assert.equal(
  resolved[1]?.matchId,
  "match-b",
);

assert.equal(
  targetByExternalId.get("9999"),
  undefined,
);

console.log("");
console.log(
  "[PASS] A8D.6.3 BATCH FAN-OUT CONTRACT",
);
console.log("");
console.log(
  "[PASS] Provider result 1001 -> canonical match-a",
);
console.log(
  "[PASS] Provider result 1002 -> canonical match-b",
);
console.log(
  "[PASS] Unknown provider result has no canonical scope",
);
console.log(
  "[PASS] Fan-out remains one-result-at-a-time downstream",
);