import { strict as assert } from "node:assert";

import {
  buildTheOddsBootstrapPendingIntent,
  decideTheOddsBootstrapGeneration,
  THE_ODDS_BOOTSTRAP_SUPPORTED_GENERATION,
} from "./the-odds-bootstrap-pending-intent";

const roundId =
  "43e943c7-df99-4c0b-8732-e6f505694271";

const eligibleAt =
  "2026-08-25T18:45:00.000Z";

const baseKey =
  [
    "the_odds_mapping_bootstrap",
    roundId,
    eligibleAt,
  ].join(":");

assert.equal(
  THE_ODDS_BOOTSTRAP_SUPPORTED_GENERATION,
  2,
);

const noHistory =
  decideTheOddsBootstrapGeneration({
    baseIdempotencyKey:
      baseKey,
    priorJobs:
      [],
  });

assert.deepEqual(
  noHistory,
  {
    generation:
      1,
    idempotencyKey:
      baseKey,
    reason:
      "first_generation",
  },
);

const pendingLegacy =
  decideTheOddsBootstrapGeneration({
    baseIdempotencyKey:
      baseKey,
    priorJobs: [
      {
        idempotencyKey:
          baseKey,
        status:
          "pending",
      },
    ],
  });

assert.deepEqual(
  pendingLegacy,
  {
    generation:
      1,
    idempotencyKey:
      baseKey,
    reason:
      "reuse_active_generation",
  },
);

const realG2DeadLetter =
  decideTheOddsBootstrapGeneration({
    baseIdempotencyKey:
      baseKey,
    priorJobs: [
      {
        idempotencyKey:
          baseKey,
        status:
          "dead_letter",
      },
    ],
  });

assert.deepEqual(
  realG2DeadLetter,
  {
    generation:
      2,
    idempotencyKey:
      `${baseKey}:g2`,
    reason:
      "terminal_rollover",
  },
);

const cancelledLegacy =
  decideTheOddsBootstrapGeneration({
    baseIdempotencyKey:
      baseKey,
    priorJobs: [
      {
        idempotencyKey:
          baseKey,
        status:
          "cancelled",
      },
    ],
  });

assert.equal(
  cancelledLegacy.generation,
  2,
);

const activeG2 =
  decideTheOddsBootstrapGeneration({
    baseIdempotencyKey:
      baseKey,
    priorJobs: [
      {
        idempotencyKey:
          baseKey,
        status:
          "dead_letter",
      },
      {
        idempotencyKey:
          `${baseKey}:g2`,
        status:
          "pending",
      },
    ],
  });

assert.deepEqual(
  activeG2,
  {
    generation:
      2,
    idempotencyKey:
      `${baseKey}:g2`,
    reason:
      "reuse_active_generation",
  },
);

assert.throws(
  () =>
    decideTheOddsBootstrapGeneration({
      baseIdempotencyKey:
        baseKey,
      priorJobs: [
        {
          idempotencyKey:
            baseKey,
          status:
            "dead_letter",
        },
        {
          idempotencyKey:
            `${baseKey}:g2`,
          status:
            "dead_letter",
        },
      ],
    }),
  /THE_ODDS_BOOTSTRAP_GENERATION_EXHAUSTED:2:dead_letter/,
);

assert.throws(
  () =>
    decideTheOddsBootstrapGeneration({
      baseIdempotencyKey:
        baseKey,
      priorJobs: [
        {
          idempotencyKey:
            baseKey,
          status:
            "completed",
        },
      ],
    }),
  /THE_ODDS_BOOTSTRAP_COMPLETED_WITH_MAPPING_INCOMPLETE:1/,
);

assert.throws(
  () =>
    decideTheOddsBootstrapGeneration({
      baseIdempotencyKey:
        baseKey,
      priorJobs: [
        {
          idempotencyKey:
            baseKey,
          status:
            "failed",
        },
      ],
    }),
  /THE_ODDS_BOOTSTRAP_GENERATION_STATUS_UNSUPPORTED:1:failed/,
);

assert.throws(
  () =>
    decideTheOddsBootstrapGeneration({
      baseIdempotencyKey:
        baseKey,
      priorJobs: [
        {
          idempotencyKey:
            baseKey,
          status:
            "pending",
        },
        {
          idempotencyKey:
            baseKey,
          status:
            "pending",
        },
      ],
    }),
  /THE_ODDS_BOOTSTRAP_GENERATION_DUPLICATE:1/,
);

const g1Intent =
  buildTheOddsBootstrapPendingIntent({
    fantagolRoundId:
      roundId,
    eligibleAt:
      "2026-08-25T18:45:00Z",
    competitionCode:
      "SA",
    generation:
      1,
  });

assert.equal(
  g1Intent.idempotencyKey,
  baseKey,
);

assert.equal(
  g1Intent.payload.bootstrap_generation,
  1,
);

const g2Intent =
  buildTheOddsBootstrapPendingIntent({
    fantagolRoundId:
      roundId,
    eligibleAt:
      eligibleAt,
    competitionCode:
      "SA",
    generation:
      2,
  });

assert.equal(
  g2Intent.idempotencyKey,
  `${baseKey}:g2`,
);

assert.equal(
  g2Intent.payload.bootstrap_generation,
  2,
);

assert.equal(
  g2Intent.mode,
  "prematch",
);

assert.equal(
  g2Intent.maxAttempts,
  1,
);

assert.equal(
  g2Intent.payload.provider_code,
  "the_odds_api",
);

assert.equal(
  g2Intent.payload.bootstrap_discovery,
  true,
);

assert.equal(
  g2Intent.payload.market_snapshot_source,
  "PACKAGE",
);

assert.equal(
  "match_targets" in
    g2Intent.payload,
  false,
);

console.log(
  "[PASS] no history => legacy generation 1",
);

console.log(
  "[PASS] active generation is reused",
);

console.log(
  "[PASS] legacy dead-letter => generation 2",
);

console.log(
  "[PASS] generation 2 dead-letter => fail closed",
);

console.log(
  "[PASS] completed + incomplete objective => fail closed",
);

console.log(
  "[PASS] duplicate generation => fail closed",
);

console.log(
  "[PASS] legacy g1 key remains byte-compatible",
);

console.log(
  "[PASS] g2 key gains deterministic :g2 suffix",
);

console.log(
  "[PASS] PACKAGE / prematch / maxAttempts=1 preserved",
);

console.log(
  "[PASS] no automatic unbounded rollover",
);