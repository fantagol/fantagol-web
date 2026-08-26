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
  5,
);

const job = (
  generation: number,
  status: string,
) => ({
  idempotencyKey:
    generation === 1
      ? baseKey
      : `${baseKey}:g${generation}`,
  status,
});

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
      job(1, "pending"),
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
      job(1, "dead_letter"),
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
      job(1, "dead_letter"),
      job(2, "dead_letter"),
    ],
  });

assert.equal(
  g2Dead.generation,
  3,
);

const g3Dead =
  decideTheOddsBootstrapGeneration({
    baseIdempotencyKey:
      baseKey,
    priorJobs: [
      job(1, "dead_letter"),
      job(2, "dead_letter"),
      job(3, "dead_letter"),
    ],
  });

assert.equal(
  g3Dead.generation,
  4,
);

const realG2State =
  decideTheOddsBootstrapGeneration({
    baseIdempotencyKey:
      baseKey,
    priorJobs: [
      job(1, "dead_letter"),
      job(2, "dead_letter"),
      job(3, "dead_letter"),
      job(4, "dead_letter"),
    ],
  });

assert.deepEqual(
  realG2State,
  {
    generation:
      5,
    idempotencyKey:
      `${baseKey}:g5`,
    reason:
      "terminal_rollover",
  },
);

const activeG5 =
  decideTheOddsBootstrapGeneration({
    baseIdempotencyKey:
      baseKey,
    priorJobs: [
      job(1, "dead_letter"),
      job(2, "dead_letter"),
      job(3, "dead_letter"),
      job(4, "dead_letter"),
      job(5, "pending"),
    ],
  });

assert.deepEqual(
  activeG5,
  {
    generation:
      5,
    idempotencyKey:
      `${baseKey}:g5`,
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
        job(1, "dead_letter"),
        job(2, "dead_letter"),
        job(3, "dead_letter"),
        job(4, "dead_letter"),
        job(5, "dead_letter"),
      ],
    }),
  /THE_ODDS_BOOTSTRAP_GENERATION_EXHAUSTED:5:dead_letter/,
);

assert.throws(
  () =>
    decideTheOddsBootstrapGeneration({
      baseIdempotencyKey:
        baseKey,
      priorJobs: [
        job(1, "dead_letter"),
        job(2, "dead_letter"),
        job(3, "dead_letter"),
        job(4, "dead_letter"),
        job(5, "completed"),
      ],
    }),
  /THE_ODDS_BOOTSTRAP_COMPLETED_WITH_MAPPING_INCOMPLETE:5/,
);

assert.throws(
  () =>
    decideTheOddsBootstrapGeneration({
      baseIdempotencyKey:
        baseKey,
      priorJobs: [
        job(1, "dead_letter"),
        job(2, "dead_letter"),
        job(3, "dead_letter"),
        job(4, "dead_letter"),
        job(5, "pending"),
        job(5, "pending"),
      ],
    }),
  /THE_ODDS_BOOTSTRAP_GENERATION_DUPLICATE:5/,
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

const g5Intent =
  buildTheOddsBootstrapPendingIntent({
    fantagolRoundId:
      roundId,
    eligibleAt,
    competitionCode:
      "SA",
    generation:
      5,
  });

assert.equal(
  g1Intent.idempotencyKey,
  baseKey,
);

assert.equal(
  g2Intent.idempotencyKey,
  `${baseKey}:g2`,
);

assert.equal(
  g3Intent.idempotencyKey,
  `${baseKey}:g3`,
);

assert.equal(
  g4Intent.idempotencyKey,
  `${baseKey}:g4`,
);

assert.equal(
  g5Intent.idempotencyKey,
  `${baseKey}:g5`,
);

assert.equal(
  g5Intent.payload.bootstrap_generation,
  5,
);

assert.equal(
  g5Intent.mode,
  "prematch",
);

assert.equal(
  g5Intent.maxAttempts,
  1,
);

assert.equal(
  g5Intent.payload.provider_code,
  "the_odds_api",
);

assert.equal(
  g5Intent.payload.bootstrap_discovery,
  true,
);

assert.equal(
  g5Intent.payload.market_snapshot_source,
  "PACKAGE",
);

assert.equal(
  "match_targets" in
    g5Intent.payload,
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
  "[PASS] g1+g2+g3 dead-letter => g4",
);

console.log(
  "[PASS] real G2 state g1+g2+g3+g4 dead-letter => g5",
);

console.log(
  "[PASS] active g5 reused",
);

console.log(
  "[PASS] g5 dead-letter => fail closed",
);

console.log(
  "[PASS] completed g5 with incomplete mapping => fail closed",
);

console.log(
  "[PASS] duplicate g5 => fail closed",
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
  "[PASS] g4 deterministic suffix preserved",
);

console.log(
  "[PASS] g5 deterministic suffix enabled",
);

console.log(
  "[PASS] PACKAGE / prematch / maxAttempts=1 preserved",
);

console.log(
  "[PASS] automatic g6 blocked",
);