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
  4,
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

assert.equal(
  activeG1.generation,
  1,
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

const g2Dead =
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
  g2Dead,
  {
    generation:
      3,
    idempotencyKey:
      `${baseKey}:g3`,
    reason:
      "terminal_rollover",
  },
);

const realG2Recovery =
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
  });

assert.deepEqual(
  realG2Recovery,
  {
    generation:
      4,
    idempotencyKey:
      `${baseKey}:g4`,
    reason:
      "terminal_rollover",
  },
);

const activeG4 =
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
      {
        idempotencyKey:
          `${baseKey}:g4`,
        status:
          "pending",
      },
    ],
  });

assert.deepEqual(
  activeG4,
  {
    generation:
      4,
    idempotencyKey:
      `${baseKey}:g4`,
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
        {
          idempotencyKey:
            `${baseKey}:g4`,
          status:
            "dead_letter",
        },
      ],
    }),
  /THE_ODDS_BOOTSTRAP_GENERATION_EXHAUSTED:4:dead_letter/,
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
        {
          idempotencyKey:
            `${baseKey}:g4`,
          status:
            "completed",
        },
      ],
    }),
  /THE_ODDS_BOOTSTRAP_COMPLETED_WITH_MAPPING_INCOMPLETE:4/,
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
        {
          idempotencyKey:
            `${baseKey}:g4`,
          status:
            "pending",
        },
        {
          idempotencyKey:
            `${baseKey}:g4`,
          status:
            "pending",
        },
      ],
    }),
  /THE_ODDS_BOOTSTRAP_GENERATION_DUPLICATE:4/,
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

const g4Intent =
  buildTheOddsBootstrapPendingIntent({
    fantagolRoundId:
      roundId,
    eligibleAt,
    competitionCode:
      "SA",
    generation:
      4,
  });

assert.equal(
  g4Intent.idempotencyKey,
  `${baseKey}:g4`,
);

assert.equal(
  g4Intent.payload.bootstrap_generation,
  4,
);

assert.equal(
  g4Intent.mode,
  "prematch",
);

assert.equal(
  g4Intent.maxAttempts,
  1,
);

assert.equal(
  g4Intent.payload.provider_code,
  "the_odds_api",
);

assert.equal(
  g4Intent.payload.bootstrap_discovery,
  true,
);

assert.equal(
  g4Intent.payload.market_snapshot_source,
  "PACKAGE",
);

assert.equal(
  "match_targets" in
    g4Intent.payload,
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
  "[PASS] g1+g2 dead-letter => g3",
);

console.log(
  "[PASS] real G2 state g1+g2+g3 dead-letter => g4",
);

console.log(
  "[PASS] active g4 reused",
);

console.log(
  "[PASS] g4 dead-letter => fail closed",
);

console.log(
  "[PASS] completed g4 with incomplete mapping => fail closed",
);

console.log(
  "[PASS] duplicate g4 => fail closed",
);

console.log(
  "[PASS] g1 legacy key preserved",
);

console.log(
  "[PASS] g2 deterministic suffix preserved",
);

console.log(
  "[PASS] g3 deterministic suffix preserved",
);

console.log(
  "[PASS] g4 deterministic suffix enabled",
);

console.log(
  "[PASS] PACKAGE / prematch / maxAttempts=1 preserved",
);

console.log(
  "[PASS] automatic g5 blocked",
);