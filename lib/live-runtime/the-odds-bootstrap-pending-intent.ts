import type { SupabaseClient } from "@supabase/supabase-js";

import type {
  EnqueuedLiveRuntimeJob,
} from "./job-service";

import {
  enqueueTheOddsPackagePendingIntent,
  type EnqueueTheOddsPackagePendingIntentInput,
} from "./the-odds-package-pending-intent";

/**
 * Bootstrap generation contract.
 *
 * Generation 1 is the historical / legacy key without a suffix.
 *
 *   the_odds_mapping_bootstrap:<round>:<eligibleAt>
 *
 * Generation 2 is the first explicitly versioned terminal rollover.
 *
 *   the_odds_mapping_bootstrap:<round>:<eligibleAt>:g2
 *
 * IMPORTANT:
 * this constant is intentionally bounded.
 *
 * A terminal g2 MUST NOT automatically create g3 on every heartbeat.
 * A future g3 requires an explicit source-contract upgrade after the
 * failure has been understood.
 */
export const THE_ODDS_BOOTSTRAP_SUPPORTED_GENERATION =
  5 as const;

export type BuildTheOddsBootstrapPendingIntentInput = {
  fantagolRoundId: string;
  eligibleAt: string;
  competitionCode?: string;
  generation?: number;
};

export type TheOddsBootstrapGenerationJob = {
  idempotencyKey: string;
  status: string;
};

export type TheOddsBootstrapGenerationDecision = {
  generation: number;
  idempotencyKey: string;
  reason:
    | "first_generation"
    | "reuse_active_generation"
    | "terminal_rollover";
};

type BootstrapGenerationJobRow = {
  idempotency_key: string;
  status: string;
};

function normalizeBootstrapIdentity(input: {
  fantagolRoundId: string;
  eligibleAt: string;
}) {
  const fantagolRoundId =
    input.fantagolRoundId.trim();

  if (fantagolRoundId === "") {
    throw new Error(
      "THE_ODDS_BOOTSTRAP_PENDING_ROUND_REQUIRED",
    );
  }

  const eligibleAtMs =
    Date.parse(
      input.eligibleAt,
    );

  if (!Number.isFinite(eligibleAtMs)) {
    throw new Error(
      "THE_ODDS_BOOTSTRAP_PENDING_ELIGIBLE_AT_INVALID",
    );
  }

  const eligibleAt =
    new Date(
      eligibleAtMs,
    ).toISOString();

  const baseIdempotencyKey =
    [
      "the_odds_mapping_bootstrap",
      fantagolRoundId,
      eligibleAt,
    ].join(":");

  return {
    fantagolRoundId,
    eligibleAt,
    baseIdempotencyKey,
  };
}

function buildGenerationKey(
  baseIdempotencyKey: string,
  generation: number,
): string {
  if (
    !Number.isInteger(generation) ||
    generation <= 0 ||
    generation >
      THE_ODDS_BOOTSTRAP_SUPPORTED_GENERATION
  ) {
    throw new Error(
      `THE_ODDS_BOOTSTRAP_GENERATION_INVALID:${generation}`,
    );
  }

  /*
   * Generation 1 preserves historical identity exactly.
   *
   * This is required so all already-created bootstrap jobs remain
   * authoritative evidence and no migration/rewrite is necessary.
   */
  if (generation === 1) {
    return baseIdempotencyKey;
  }

  return `${baseIdempotencyKey}:g${generation}`;
}

function parseGenerationFromKey(
  baseIdempotencyKey: string,
  idempotencyKey: string,
): number {
  if (idempotencyKey === baseIdempotencyKey) {
    return 1;
  }

  const prefix =
    `${baseIdempotencyKey}:g`;

  if (!idempotencyKey.startsWith(prefix)) {
    throw new Error(
      `THE_ODDS_BOOTSTRAP_GENERATION_KEY_OUT_OF_SCOPE:${idempotencyKey}`,
    );
  }

  const raw =
    idempotencyKey.slice(
      prefix.length,
    );

  if (!/^[1-9]\d*$/.test(raw)) {
    throw new Error(
      `THE_ODDS_BOOTSTRAP_GENERATION_KEY_INVALID:${idempotencyKey}`,
    );
  }

  const generation =
    Number(raw);

  if (
    !Number.isSafeInteger(generation) ||
    generation <= 1
  ) {
    throw new Error(
      `THE_ODDS_BOOTSTRAP_GENERATION_KEY_INVALID:${idempotencyKey}`,
    );
  }

  return generation;
}

const ACTIVE_GENERATION_STATUSES =
  new Set([
    "pending",
    "running",
    "retry_wait",
  ]);

const TERMINAL_ROLLOVER_STATUSES =
  new Set([
    "dead_letter",
    "cancelled",
  ]);

/**
 * Pure generation authority.
 *
 * No provider.
 * No queue write.
 * No DB.
 *
 * Rules:
 *
 * no prior generation
 *   -> g1
 *
 * latest generation still active
 *   -> same generation / same exact key
 *
 * latest generation dead_letter or cancelled
 *   -> next generation ONLY when that generation is explicitly
 *      supported by this deployed source contract
 *
 * latest generation completed while caller still says mapping
 * incomplete
 *   -> fail closed because the two authorities disagree
 *
 * latest supported generation terminal
 *   -> fail closed; no automatic infinite retry chain
 */
export function decideTheOddsBootstrapGeneration(
  input: {
    baseIdempotencyKey: string;
    priorJobs: TheOddsBootstrapGenerationJob[];
    supportedGeneration?: number;
  },
): TheOddsBootstrapGenerationDecision {
  const baseIdempotencyKey =
    input.baseIdempotencyKey.trim();

  if (baseIdempotencyKey === "") {
    throw new Error(
      "THE_ODDS_BOOTSTRAP_GENERATION_BASE_KEY_REQUIRED",
    );
  }

  const supportedGeneration =
    input.supportedGeneration ??
    THE_ODDS_BOOTSTRAP_SUPPORTED_GENERATION;

  if (
    !Number.isInteger(
      supportedGeneration,
    ) ||
    supportedGeneration <= 0
  ) {
    throw new Error(
      "THE_ODDS_BOOTSTRAP_SUPPORTED_GENERATION_INVALID",
    );
  }

  if (input.priorJobs.length === 0) {
    return {
      generation:
        1,
      idempotencyKey:
        buildGenerationKey(
          baseIdempotencyKey,
          1,
        ),
      reason:
        "first_generation",
    };
  }

  const byGeneration =
    new Map<
      number,
      TheOddsBootstrapGenerationJob
    >();

  for (const job of input.priorJobs) {
    const generation =
      parseGenerationFromKey(
        baseIdempotencyKey,
        job.idempotencyKey,
      );

    if (byGeneration.has(generation)) {
      throw new Error(
        `THE_ODDS_BOOTSTRAP_GENERATION_DUPLICATE:${generation}`,
      );
    }

    byGeneration.set(
      generation,
      job,
    );
  }

  const generations =
    [...byGeneration.keys()]
      .sort(
        (left, right) =>
          left - right,
      );

  const latestGeneration =
    generations[
      generations.length - 1
    ];

  const latest =
    byGeneration.get(
      latestGeneration,
    );

  if (!latest) {
    throw new Error(
      "THE_ODDS_BOOTSTRAP_GENERATION_LATEST_MISSING",
    );
  }

  if (
    latestGeneration >
    supportedGeneration
  ) {
    throw new Error(
      `THE_ODDS_BOOTSTRAP_GENERATION_AHEAD_OF_RUNTIME:${latestGeneration}:${supportedGeneration}`,
    );
  }

  if (
    ACTIVE_GENERATION_STATUSES.has(
      latest.status,
    )
  ) {
    return {
      generation:
        latestGeneration,
      idempotencyKey:
        latest.idempotencyKey,
      reason:
        "reuse_active_generation",
    };
  }

  if (
    TERMINAL_ROLLOVER_STATUSES.has(
      latest.status,
    )
  ) {
    const nextGeneration =
      latestGeneration + 1;

    if (
      nextGeneration >
      supportedGeneration
    ) {
      throw new Error(
        `THE_ODDS_BOOTSTRAP_GENERATION_EXHAUSTED:${latestGeneration}:${latest.status}`,
      );
    }

    return {
      generation:
        nextGeneration,
      idempotencyKey:
        buildGenerationKey(
          baseIdempotencyKey,
          nextGeneration,
        ),
      reason:
        "terminal_rollover",
    };
  }

  if (latest.status === "completed") {
    throw new Error(
      `THE_ODDS_BOOTSTRAP_COMPLETED_WITH_MAPPING_INCOMPLETE:${latestGeneration}`,
    );
  }

  throw new Error(
    `THE_ODDS_BOOTSTRAP_GENERATION_STATUS_UNSUPPORTED:${latestGeneration}:${latest.status}`,
  );
}

/**
 * Read-only production generation resolver.
 *
 * The semantic base identity is round + canonical eligibleAt.
 *
 * Only jobs whose idempotency key belongs to that exact bootstrap
 * identity are considered.
 */
export async function loadTheOddsBootstrapGenerationDecision(
  input: {
    client: SupabaseClient;
    fantagolRoundId: string;
    eligibleAt: string;
  },
): Promise<TheOddsBootstrapGenerationDecision> {
  const identity =
    normalizeBootstrapIdentity(
      input,
    );

  const {
    data,
    error,
  } = await input.client
    .from(
      "live_runtime_jobs",
    )
    .select(
      "idempotency_key,status",
    )
    .eq(
      "job_type",
      "poll_batch",
    )
    .eq(
      "scope_type",
      "fantagol_round",
    )
    .eq(
      "scope_id",
      identity.fantagolRoundId,
    )
    .like(
      "idempotency_key",
      `${identity.baseIdempotencyKey}%`,
    );

  if (error) {
    throw new Error(
      `THE_ODDS_BOOTSTRAP_GENERATION_LOAD_FAILED:${error.message}`,
    );
  }

  const rows =
    (
      data ??
      []
    ) as BootstrapGenerationJobRow[];

  /*
   * LIKE(base%) is intentionally followed by strict parsing.
   * Any malformed key sharing the semantic prefix fails closed.
   */
  const priorJobs =
    rows.map(
      (row) => ({
        idempotencyKey:
          row.idempotency_key,
        status:
          row.status,
      }),
    );

  return decideTheOddsBootstrapGeneration({
    baseIdempotencyKey:
      identity.baseIdempotencyKey,
    priorJobs,
  });
}

export function buildTheOddsBootstrapPendingIntent(
  input: BuildTheOddsBootstrapPendingIntentInput,
): EnqueueTheOddsPackagePendingIntentInput {
  const identity =
    normalizeBootstrapIdentity(
      input,
    );

  const competitionCode =
    input.competitionCode?.trim() ||
    "SA";

  const generation =
    input.generation ??
    1;

  const idempotencyKey =
    buildGenerationKey(
      identity.baseIdempotencyKey,
      generation,
    );

  return {
    fantagolRoundId:
      identity.fantagolRoundId,

    mode:
      "prematch",

    /*
     * This value identifies the market lifecycle purpose of the
     * intent. It does not convert the job into an EVENT refinement.
     */
    marketOperatingMode:
      "PACKAGE",

    marketPolicyReason:
      "THE_ODDS_MAPPING_BOOTSTRAP",

    idempotencyKey,

    priority:
      50,

    scheduledAt:
      identity.eligibleAt,

    maxAttempts:
      1,

    payload: {
      provider_code:
        "the_odds_api",

      mode:
        "prematch",

      bootstrap_discovery:
        true,

      bootstrap_generation:
        generation,

      fantagol_round_id:
        identity.fantagolRoundId,

      competition_code:
        competitionCode,

      bootstrap_eligible_at:
        identity.eligibleAt,

      market_snapshot_source:
        "PACKAGE",

      market_policy_reason:
        "THE_ODDS_MAPPING_BOOTSTRAP",
    },
  };
}

export async function enqueueTheOddsBootstrapPendingIntent(
  client: SupabaseClient,
  input: BuildTheOddsBootstrapPendingIntentInput,
): Promise<EnqueuedLiveRuntimeJob> {
  const generationDecision =
    await loadTheOddsBootstrapGenerationDecision({
      client,
      fantagolRoundId:
        input.fantagolRoundId,
      eligibleAt:
        input.eligibleAt,
    });

  return enqueueTheOddsPackagePendingIntent(
    client,
    buildTheOddsBootstrapPendingIntent({
      ...input,
      generation:
        generationDecision.generation,
    }),
  );
}