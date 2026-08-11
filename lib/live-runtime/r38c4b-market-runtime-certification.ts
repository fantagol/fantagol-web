import assert from "node:assert/strict";
import fs from "node:fs";

import type {
  ProviderEventOdds,
} from "../market-intelligence/contracts";
import {
  buildMarketRuntimeArtifact,
  calculateMarketRuntimeMovement,
} from "./market-intelligence-runtime-artifact";

function loadEvents(path: string): ProviderEventOdds[] {
  const raw = JSON.parse(
    fs.readFileSync(path, "utf8"),
  ) as unknown;

  if (Array.isArray(raw)) {
    return raw as ProviderEventOdds[];
  }

  if (
    raw &&
    typeof raw === "object" &&
    "events" in raw &&
    Array.isArray(
      (raw as { events?: unknown }).events,
    )
  ) {
    return (
      raw as {
        events: ProviderEventOdds[];
      }
    ).events;
  }

  throw new Error(
    "R38C4B_RAW_PACKAGE_CONTRACT_UNSUPPORTED",
  );
}

function perturbEvent(
  event: ProviderEventOdds,
): ProviderEventOdds {
  const cloned = JSON.parse(
    JSON.stringify(event),
  ) as ProviderEventOdds;

  for (const bookmaker of cloned.bookmakers) {
    for (const market of bookmaker.markets) {
      if (market.key === "h2h") {
        for (const outcome of market.outcomes) {
          if (
            outcome.name === cloned.home_team
          ) {
            outcome.price *= 0.72;
          }
          else if (
            outcome.name === cloned.away_team
          ) {
            outcome.price *= 1.30;
          }
          else if (
            outcome.name.trim().toLowerCase() ===
            "draw"
          ) {
            outcome.price *= 1.12;
          }
        }
      }

      if (
        market.key === "totals" ||
        market.key === "alternate_totals"
      ) {
        for (const outcome of market.outcomes) {
          if (outcome.point !== 2.5) continue;

          const name =
            outcome.name.trim().toLowerCase();

          if (name === "over") {
            outcome.price *= 0.78;
          }
          else if (name === "under") {
            outcome.price *= 1.24;
          }
        }
      }
    }
  }

  return cloned;
}

const rawPath = process.argv[2];

if (!rawPath) {
  throw new Error(
    "R38C4B_RAW_PACKAGE_PATH_REQUIRED",
  );
}

const events = loadEvents(rawPath);

assert.equal(
  events.length,
  10,
  "Expected 10 Serie A package events",
);

const artifacts =
  events.map(buildMarketRuntimeArtifact);

assert.equal(artifacts.length, 10);

for (const artifact of artifacts) {
  assert.equal(
    artifact.modelCode,
    "BM_INTERPOLATED",
  );
  assert.equal(
    artifact.algorithmVersion,
    "BM_INTERPOLATED_V1",
  );
  assert.ok(
    artifact.input.availableSignals.includes(
      "SIGN",
    ),
  );
  assert.ok(
    artifact.input.availableSignals.includes(
      "TOTALS",
    ),
  );
  assert.equal(
    artifact.output.scoreMatrix.length,
    81,
  );
  assert.equal(
    artifact.output.exact.length,
    81,
  );
  assert.ok(
    artifact.output.marketConfidence >= 0 &&
      artifact.output.marketConfidence <= 1,
  );
  assert.ok(
    artifact.output.confidence >= 0 &&
      artifact.output.confidence <= 1,
  );
}

const baseline = artifacts[0];

const noPrevious =
  calculateMarketRuntimeMovement(
    null,
    {
      artifact: baseline,
      capturedAt:
        "2026-08-10T12:00:00.000Z",
      source: "PACKAGE",
    },
  );

assert.equal(
  noPrevious.previousCapturedAt,
  null,
);
assert.equal(
  noPrevious.movementMagnitude,
  0,
);

const movedEvent =
  perturbEvent(events[0]);

const moved =
  buildMarketRuntimeArtifact(
    movedEvent,
  );

/*
 * First prove the BM output actually moved.
 * This avoids falsely blaming Temporal Movement when
 * the fitting grid legitimately selects the same optimum.
 */
const lambdaChanged =
  Math.abs(
    moved.output.lambdaHome -
      baseline.output.lambdaHome,
  ) > 1e-12 ||
  Math.abs(
    moved.output.lambdaAway -
      baseline.output.lambdaAway,
  ) > 1e-12;

const signChanged =
  Math.abs(
    moved.output.sign.home -
      baseline.output.sign.home,
  ) > 1e-12 ||
  Math.abs(
    moved.output.sign.draw -
      baseline.output.sign.draw,
  ) > 1e-12 ||
  Math.abs(
    moved.output.sign.away -
      baseline.output.sign.away,
  ) > 1e-12;

const totalsChanged =
  Math.abs(
    moved.output.totals.over -
      baseline.output.totals.over,
  ) > 1e-12 ||
  Math.abs(
    moved.output.totals.under -
      baseline.output.totals.under,
  ) > 1e-12;

assert.ok(
  lambdaChanged ||
    signChanged ||
    totalsChanged,
  "Controlled provider perturbation did not change BM output",
);

const movement =
  calculateMarketRuntimeMovement(
    {
      artifact: baseline,
      capturedAt:
        "2026-08-10T12:00:00.000Z",
      source: "PACKAGE",
    },
    {
      artifact: moved,
      capturedAt:
        "2026-08-11T12:00:00.000Z",
      source: "PACKAGE",
    },
  );

assert.equal(
  movement.previousCapturedAt,
  "2026-08-10T12:00:00.000Z",
);

assert.ok(
  movement.movementMagnitude > 0,
  "Temporal movement magnitude must react after certified BM output change",
);

assert.ok(
  movement.sign.home.delta !== null,
);

const h2hOnly: ProviderEventOdds = {
  id: "h2h-only",
  home_team: "Home",
  away_team: "Away",
  bookmakers: [
    {
      key: "test",
      title: "Test",
      markets: [
        {
          key: "h2h",
          outcomes: [
            { name: "Home", price: 2.1 },
            { name: "Draw", price: 3.2 },
            { name: "Away", price: 3.5 },
          ],
        },
      ],
    },
  ],
};

assert.throws(
  () =>
    buildMarketRuntimeArtifact(h2hOnly),
  /BM_INTERPOLATED_TOTALS_25_REQUIRED/,
);

console.log(
  "[PASS] R38-C4-B-R1 MARKET RUNTIME TRANSFORMER",
);
console.log(
  `Provider events: ${events.length}`,
);
console.log(
  `Modeled artifacts: ${artifacts.length}`,
);
console.log(
  "[PASS] 10/10 package events BM_INTERPOLATED",
);
console.log(
  "[PASS] persistence payload exposes complete certified output",
);
console.log(
  "[PASS] temporal movement baseline = zero without previous snapshot",
);
console.log(
  "[PASS] controlled provider change produces changed BM output",
);
console.log(
  "[PASS] temporal movement reacts after BM output change",
);
console.log(
  "[PASS] H2H-only payload rejected instead of fabricating Totals",
);
