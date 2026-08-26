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
  3,
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

const activeG1 =
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
  activeG1,
  {
    generation:
      1,
    idempotencyKey:
      baseKey,
    reason:
      "reuse_active_generation",
  },
);

const g1Dead =
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
  g1Dead,
  {
    generation:
      2,
    idempotencyKey:
      `${baseKey}:g2`,
    reason:
      "terminal_rollover",
  },
);

const realG2State =
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
  });

assert.deepEqual(
  realG2State,
  {
    generation:
      3,
    idempotencyKey:
      `${baseKey}:g3`,
    reason:
      "terminal_rollover",
  },
);

const activeG3 =
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
      {
        idempotencyKey:
          `${baseKey}:g3`,
        status:
          "pending",
      },
    ],
  });

assert.deepEqual(
  activeG3,
  {
    generation:
      3,
    idempotencyKey:
      `${baseKey}:g3`,
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
        {
          idempotencyKey:
            `${baseKey}:g3`,
          status:
            "dead_letter",
        },
      ],
    }),
  /THE_ODDS_BOOTSTRAP_GENERATION_EXHAUSTED:3:dead_letter/,
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
        {
          idempotencyKey:
            `${baseKey}:g3`,
          status:
            "completed",
        },
      ],
    }),
  /THE_ODDS_BOOTSTRAP_COMPLETED_WITH_MAPPING_INCOMPLETE:3/,
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
        {
          idempotencyKey:
            `${baseKey}:g3`,
          status:
            "pending",
        },
        {
          idempotencyKey:
            `${baseKey}:g3`,
          status:
            "pending",
        },
      ],
    }),
  /THE_ODDS_BOOTSTRAP_GENERATION_DUPLICATE:3/,
);

const g1Intent =
  buildTheOddsBootstrapPendingIntent({
    fantagolRoundId:
      roundId,
    eligibleAt,
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

const g3Intent =
  buildTheOddsBootstrapPendingIntent({
    fantagolRoundId:
      roundId,
    eligibleAt,
    competitionCode:
      "SA",
    generation:
      3,
  });

assert.equal(
  g3Intent.idempotencyKey,
  `${baseKey}:g3`,
);

assert.equal(
  g3Intent.payload.bootstrap_generation,
  3,
);

assert.equal(
  g3Intent.mode,
  "prematch",
);

assert.equal(
  g3Intent.maxAttempts,
  1,
);

assert.equal(
  g3Intent.payload.provider_code,
  "the_odds_api",
);

assert.equal(
  g3Intent.payload.bootstrap_discovery,
  true,
);

assert.equal(
  g3Intent.payload.market_snapshot_source,
  "PACKAGE",
);

assert.equal(
  "match_targets" in
    g3Intent.payload,
  false,
);

console.log(
  "[PASS] no history => generation 1",
);

console.log(
  "[PASS] active generation reused",
);

console.log(
  "[PASS] g1 dead-letter => g2",
);

console.log(
  "[PASS] real G2 state g1+g2 dead-letter => g3",
);

console.log(
  "[PASS] active g3 reused",
);

console.log(
  "[PASS] g3 dead-letter => fail closed",
);

console.log(
  "[PASS] completed g3 with incomplete mapping => fail closed",
);

console.log(
  "[PASS] duplicate g3 => fail closed",
);

console.log(
  "[PASS] g1 legacy key preserved",
);

console.log(
  "[PASS] g2 deterministic suffix preserved",
);

console.log(
  "[PASS] g3 deterministic suffix enabled",
);

console.log(
  "[PASS] PACKAGE / prematch / maxAttempts=1 preserved",
);

console.log(
  "[PASS] automatic g4 blocked",
);