import type { SupabaseClient } from "@supabase/supabase-js";

import {
  enqueueFinalCalculableLeagueRoundRebuildJobs,
} from "./rebuild-enqueue";

import {
  loadFootballDataProductionTargets,
  loadMarketRoundProductionTargets,
  resolveProductionRoundContext,
  type ProductionRoundContext,
} from "./production-target-loader";

import {
  loadCanonicalMonthlyMarketCreditState,
  type FixedMonthlyMarketCreditState,
} from "./market-credit-governance-resolver";
import {
  buildAdvancedMarketPlan,
  type AdvancedMarketPlan,
} from "./market-advanced-candidate-builder";
import {
  scheduleAdvancedMarketEvents,
  type ScheduledAdvancedMarketEvents,
} from "./market-advanced-event-scheduler";
import {
  decideMarketRoundPollingPolicy,
} from "./market-round-polling-policy";
import {
  scheduleFootballDataAggregatedPolling,
  type LivePollingTarget,
  type ScheduledFootballDataAggregate,
} from "./scheduler";
import {
  scheduleMarketRoundPolling,
  type MarketRoundPollingTarget,
  type ScheduledMarketRoundPolling,
} from "./market-round-scheduler";
import type {
  MarketRoundPollingPolicyInput,
} from "./market-round-polling-policy";
import {
  runLiveRuntimeWorkerOnce,
  type RunLiveRuntimeWorkerOnceResult,
} from "./worker";
import {
  loadCanonicalMarketPolicyInput,
  resolveCanonicalCommunityDecision,
} from "./production-runtime-state-resolvers";
import {
  loadCanonicalTheOddsRoundBootstrapDecision,
  type TheOddsRoundBootstrapDecision,
} from "./the-odds-round-bootstrap-policy";
import {
  enqueueTheOddsBootstrapPendingIntent,
} from "./the-odds-bootstrap-pending-intent";
import type {
  EnqueuedLiveRuntimeJob,
  LiveRuntimeJobType,
} from "./job-service";

export type ProductionCommunityAction =
  | "refresh"
  | "freeze"
  | "skip";

export type ProductionCommunityDecision = {
  action: ProductionCommunityAction;
  reason: string;
};

export type ProductionHeartbeatStepStatus =
  | "completed"
  | "skipped"
  | "failed";

export type ProductionHeartbeatStep<T> = {
  status: ProductionHeartbeatStepStatus;
  value: T | null;
  error: string | null;
};

export type ProductionHeartbeatWorkerDrain = {
  attempted: number;
  claimed: number;
  completed: number;
  results: RunLiveRuntimeWorkerOnceResult[];
};

export const ADVANCED_OPERATIONAL_MAX_CALLS_PER_HEARTBEAT =
  10 as const;

export type ProductionHeartbeatResult = {
  startedAt: string;
  finishedAt: string;
  round: ProductionHeartbeatStep<ProductionRoundContext>;
  footballData:
    ProductionHeartbeatStep<ScheduledFootballDataAggregate[]>;
  market:
    ProductionHeartbeatStep<ScheduledMarketRoundPolling>;
  marketAdvanced:
    ProductionHeartbeatStep<ScheduledAdvancedMarketEvents>;
  community:
    ProductionHeartbeatStep<unknown>;
  worker:
    ProductionHeartbeatStep<ProductionHeartbeatWorkerDrain>;
};

export type LoadMarketPolicyInput = (input: {
  client: SupabaseClient;
  round: ProductionRoundContext;
  targets: MarketRoundPollingTarget[];
  now: Date;
}) => Promise<MarketRoundPollingPolicyInput>;

export type LoadMonthlyMarketCreditState = (input: {
  client: SupabaseClient;
  now?: Date;
}) => Promise<FixedMonthlyMarketCreditState>;

export type BuildAdvancedPlan =
  typeof buildAdvancedMarketPlan;

export type ScheduleAdvancedMarket =
  typeof scheduleAdvancedMarketEvents;

export type ResolveCommunityDecision = (input: {
  client: SupabaseClient;
  round: ProductionRoundContext;
  now: Date;
}) => Promise<ProductionCommunityDecision>;

export type ProductionHeartbeatDependencies = {
  resolveRoundContext: (
    client: SupabaseClient,
  ) => Promise<ProductionRoundContext>;

  loadFootballDataTargets: (
    client: SupabaseClient,
    fantagolRoundId: string,
  ) => Promise<LivePollingTarget[]>;

  loadMarketTargets: (
    client: SupabaseClient,
    fantagolRoundId: string,
  ) => Promise<MarketRoundPollingTarget[]>;

  loadMarketBootstrapDecision: (input: {
    client: SupabaseClient;
    round: ProductionRoundContext;
    now: Date;
  }) => Promise<TheOddsRoundBootstrapDecision>;

  enqueueMarketBootstrapIntent: (
    client: SupabaseClient,
    input: {
      fantagolRoundId: string;
      eligibleAt: string;
      competitionCode?: string;
    },
  ) => Promise<EnqueuedLiveRuntimeJob>;

  loadMarketPolicyInput: LoadMarketPolicyInput;

  loadMonthlyMarketCreditState:
    LoadMonthlyMarketCreditState;

  buildAdvancedPlan:
    BuildAdvancedPlan;

  scheduleAdvancedMarket:
    ScheduleAdvancedMarket;

  resolveCommunityDecision: ResolveCommunityDecision;

  scheduleFootballData: typeof scheduleFootballDataAggregatedPolling;
  scheduleMarket: typeof scheduleMarketRoundPolling;

  advancePredictionOpening: (input: {
    client: SupabaseClient;
    fantagolRoundId: string;
  }) => Promise<unknown>;

  advancePredictionLock: (input: {
    client: SupabaseClient;
    fantagolRoundId: string;
  }) => Promise<unknown>;

  advanceRoundLive: (input: {
    client: SupabaseClient;
    fantagolRoundId: string;
  }) => Promise<unknown>;

  advanceRoundFinalCalculable: (input: {
    client: SupabaseClient;
    fantagolRoundId: string;
  }) => Promise<unknown>;
  enqueueFinalCalculableRebuilds:
    typeof enqueueFinalCalculableLeagueRoundRebuildJobs;

  expireDuePredictionRecoveries: (input: {
    client: SupabaseClient;
    at: string;
  }) => Promise<unknown>;

  refreshCommunity: (input: {
    client: SupabaseClient;
    fantagolRoundId: string;
    correlationId: string | null;
  }) => Promise<unknown>;

  freezeCommunity: (input: {
    client: SupabaseClient;
    fantagolRoundId: string;
    correlationId: string | null;
  }) => Promise<unknown>;

  runWorkerOnce: typeof runLiveRuntimeWorkerOnce;
};

export type RunProductionHeartbeatInput = {
  client: SupabaseClient;
  workerId: string;
  now?: Date;
  correlationId?: string | null;
  competitionCode?: string;
  priority?: number;
  workerJobTypes?: LiveRuntimeJobType[] | null;
  maxWorkerJobs?: number;
  dependencies?: Partial<ProductionHeartbeatDependencies>;
};

function serializeError(error: unknown): string {
  if (error instanceof Error) {
    return error.message;
  }

  try {
    return JSON.stringify(error);
  } catch {
    return String(error);
  }
}

function completed<T>(
  value: T,
): ProductionHeartbeatStep<T> {
  return {
    status: "completed",
    value,
    error: null,
  };
}

function skipped<T>(): ProductionHeartbeatStep<T> {
  return {
    status: "skipped",
    value: null,
    error: null,
  };
}

function failed<T>(
  error: unknown,
): ProductionHeartbeatStep<T> {
  return {
    status: "failed",
    value: null,
    error: serializeError(error),
  };
}

async function advancePredictionOpeningDefault(input: {
  client: SupabaseClient;
  fantagolRoundId: string;
}): Promise<unknown> {
  const { data, error } =
    await input.client.rpc(
      "advance_prediction_opening_internal",
      {
        p_fantagol_round_id:
          input.fantagolRoundId,
      },
    );

  if (error) {
    throw new Error(
      `PREDICTION_OPENING_ADVANCE_FAILED:${error.message}`,
    );
  }

  return data;
}

async function advancePredictionLockDefault(input: {
  client: SupabaseClient;
  fantagolRoundId: string;
}): Promise<unknown> {
  const { data, error } =
    await input.client.rpc(
      "advance_prediction_lock_internal",
      {
        p_fantagol_round_id:
          input.fantagolRoundId,
      },
    );

  if (error) {
    throw new Error(
      `PREDICTION_LOCK_ADVANCE_FAILED:${error.message}`,
    );
  }

  return data;
}

async function advanceRoundLiveDefault(input: {
  client: SupabaseClient;
  fantagolRoundId: string;
}): Promise<unknown> {
  const { data, error } =
    await input.client.rpc(
      "advance_round_live_internal",
      {
        p_fantagol_round_id:
          input.fantagolRoundId,
      },
    );

  if (error) {
    throw new Error(
      `ROUND_LIVE_ADVANCE_FAILED:${error.message}`,
    );
  }

  return data;
}

async function advanceRoundFinalCalculableDefault(input: {
  client: SupabaseClient;
  fantagolRoundId: string;
}): Promise<unknown> {
  const { data, error } =
    await input.client.rpc(
      "advance_round_final_calculable_internal",
      {
        p_fantagol_round_id:
          input.fantagolRoundId,
      },
    );

  if (error) {
    throw new Error(
      `ROUND_FINAL_CALCULABLE_ADVANCE_FAILED:${error.message}`,
    );
  }

  return data;
}

async function expireDuePredictionRecoveriesDefault(input: {
  client: SupabaseClient;
  at: string;
}): Promise<unknown> {
  const { data, error } =
    await input.client.rpc(
      "expire_due_prediction_recoveries_internal",
      {
        p_at: input.at,
      },
    );

  if (error) {
    throw new Error(
      `PREDICTION_RECOVERY_EXPIRY_FAILED:${error.message}`,
    );
  }

  return data;
}

async function refreshCommunityDefault(input: {
  client: SupabaseClient;
  fantagolRoundId: string;
  correlationId: string | null;
}): Promise<unknown> {
  const { data, error } = await input.client.rpc(
    "refresh_community_snapshot_rpc",
    {
      p_fantagol_round_id: input.fantagolRoundId,
      p_engine_version: "community-intelligence-v2",
      p_correlation_id: input.correlationId,
    },
  );

  if (error) {
    throw new Error(
      `COMMUNITY_REFRESH_FAILED:${error.message}`,
    );
  }

  return data;
}

async function freezeCommunityDefault(input: {
  client: SupabaseClient;
  fantagolRoundId: string;
  correlationId: string | null;
}): Promise<unknown> {
  const { data, error } = await input.client.rpc(
    "freeze_community_lock_snapshot_rpc",
    {
      p_fantagol_round_id: input.fantagolRoundId,
      p_engine_version: "community-intelligence-v2",
      p_correlation_id: input.correlationId,
    },
  );

  if (error) {
    throw new Error(
      `COMMUNITY_FREEZE_FAILED:${error.message}`,
    );
  }

  return data;
}

function resolveDependencies(
  input: RunProductionHeartbeatInput,
): ProductionHeartbeatDependencies {
  const overrides =
    input.dependencies ?? {};

  return {
    resolveRoundContext:
      overrides.resolveRoundContext ??
      resolveProductionRoundContext,

    loadFootballDataTargets:
      overrides.loadFootballDataTargets ??
      loadFootballDataProductionTargets,

    loadMarketTargets:
      overrides.loadMarketTargets ??
      loadMarketRoundProductionTargets,

    loadMarketBootstrapDecision:
      overrides.loadMarketBootstrapDecision ??
      loadCanonicalTheOddsRoundBootstrapDecision,

    enqueueMarketBootstrapIntent:
      overrides.enqueueMarketBootstrapIntent ??
      enqueueTheOddsBootstrapPendingIntent,

    loadMarketPolicyInput:
      overrides.loadMarketPolicyInput ??
      loadCanonicalMarketPolicyInput,

    loadMonthlyMarketCreditState:
      overrides.loadMonthlyMarketCreditState ??
      loadCanonicalMonthlyMarketCreditState,

    buildAdvancedPlan:
      overrides.buildAdvancedPlan ??
      buildAdvancedMarketPlan,

    scheduleAdvancedMarket:
      overrides.scheduleAdvancedMarket ??
      scheduleAdvancedMarketEvents,

    resolveCommunityDecision:
      overrides.resolveCommunityDecision ??
      resolveCanonicalCommunityDecision,

    scheduleFootballData:
      overrides.scheduleFootballData ??
      scheduleFootballDataAggregatedPolling,

    scheduleMarket:
      overrides.scheduleMarket ??
      scheduleMarketRoundPolling,

    advancePredictionOpening:
      overrides.advancePredictionOpening ??
      advancePredictionOpeningDefault,

    advancePredictionLock:
      overrides.advancePredictionLock ??
      advancePredictionLockDefault,

    advanceRoundLive:
      overrides.advanceRoundLive ??
      advanceRoundLiveDefault,

    advanceRoundFinalCalculable:
      overrides.advanceRoundFinalCalculable ??
      advanceRoundFinalCalculableDefault,
    enqueueFinalCalculableRebuilds:
      overrides.enqueueFinalCalculableRebuilds ??
      enqueueFinalCalculableLeagueRoundRebuildJobs,

    expireDuePredictionRecoveries:
      overrides.expireDuePredictionRecoveries ??
      expireDuePredictionRecoveriesDefault,

    refreshCommunity:
      overrides.refreshCommunity ??
      refreshCommunityDefault,

    freezeCommunity:
      overrides.freezeCommunity ??
      freezeCommunityDefault,

    runWorkerOnce:
      overrides.runWorkerOnce ??
      runLiveRuntimeWorkerOnce,
  };
}

async function drainWorker(input: {
  client: SupabaseClient;
  workerId: string;
  jobTypes?: LiveRuntimeJobType[] | null;
  maxJobs: number;
  runWorkerOnce: typeof runLiveRuntimeWorkerOnce;
}): Promise<ProductionHeartbeatWorkerDrain> {
  const results: RunLiveRuntimeWorkerOnceResult[] = [];

  let attempted = 0;
  let claimed = 0;
  let completedCount = 0;

  for (
    let index = 0;
    index < input.maxJobs;
    index += 1
  ) {
    attempted += 1;

    const result =
      await input.runWorkerOnce({
        client: input.client,
        workerId: input.workerId,
        jobTypes: input.jobTypes ?? null,
      });

    results.push(result);

    if (!result.claimed) {
      break;
    }

    claimed += 1;

    if (result.completed) {
      completedCount += 1;
    }
  }

  return {
    attempted,
    claimed,
    completed: completedCount,
    results,
  };
}

/**
 * R39 production heartbeat orchestration boundary.
 *
 * This function owns coordination only. It does NOT invent:
 * - Football Data cadence;
 * - Market cadence or R35 credit policy;
 * - Community cadence / due-state semantics.
 *
 * Market state and Community due-state are deliberately caller-supplied
 * resolvers until their canonical production resolvers are certified.
 */
export async function runProductionHeartbeat(
  input: RunProductionHeartbeatInput,
): Promise<ProductionHeartbeatResult> {
  const now = input.now ?? new Date();
  const startedAt = now.toISOString();
  const correlationId =
    input.correlationId ?? null;
  const deps = resolveDependencies(input);

  let roundStep:
    ProductionHeartbeatStep<ProductionRoundContext>;

  try {
    const round =
      await deps.resolveRoundContext(
        input.client,
      );

    roundStep = completed(round);
  } catch (error) {
    return {
      startedAt,
      finishedAt: new Date().toISOString(),
      round: failed(error),
      footballData: skipped(),
      market: skipped(),
      marketAdvanced: skipped(),
      community: skipped(),
      worker: skipped(),
    };
  }

  const round = roundStep.value;

  if (!round) {
    return {
      startedAt,
      finishedAt: new Date().toISOString(),
      round: failed(
        new Error(
          "PRODUCTION_HEARTBEAT_ROUND_UNAVAILABLE",
        ),
      ),
      footballData: skipped(),
      market: skipped(),
      marketAdvanced: skipped(),
      community: skipped(),
      worker: skipped(),
    };
  }

  let footballDataStep:
    ProductionHeartbeatStep<ScheduledFootballDataAggregate[]>;

  try {
    const targets =
      await deps.loadFootballDataTargets(
        input.client,
        round.fantagolRoundId,
      );

    const scheduled =
      await deps.scheduleFootballData({
        client: input.client,
        targets,
        now,
        correlationId,
        priority: input.priority,
        competitionCode:
          input.competitionCode ?? "SA",
      });

    footballDataStep =
      completed(scheduled);
  } catch (error) {
    footballDataStep = failed(error);
  }

  let marketStep:
    ProductionHeartbeatStep<ScheduledMarketRoundPolling>;

  let marketAdvancedStep:
    ProductionHeartbeatStep<ScheduledAdvancedMarketEvents> =
      skipped();

  try {
    /*
     * Mapping bootstrap gate.
     *
     * This MUST execute before loadMarketRoundProductionTargets(), because
     * that canonical loader intentionally requires complete Odds mappings.
     *
     * R16-R2B1 is observation/gating only:
     * bootstrap/wait does not enqueue, call providers or consume credits.
     */
    const bootstrapDecision =
      await deps.loadMarketBootstrapDecision({
        client:
          input.client,
        round,
        now,
      });

    if (
      bootstrapDecision.action ===
      "wait"
    ) {
      throw new Error(
        [
          "THE_ODDS_BOOTSTRAP_WAIT",
          bootstrapDecision.reason,
          bootstrapDecision.eligibleAt ??
            "none",
          `${bootstrapDecision.mappedMatchCount}/${bootstrapDecision.requiredMatchCount}`,
        ].join(":"),
      );
    }

    if (
      bootstrapDecision.action ===
      "bootstrap"
    ) {
      const eligibleAt =
        bootstrapDecision.eligibleAt;

      const bootstrapJob =
        await deps.enqueueMarketBootstrapIntent(
          input.client,
          {
            fantagolRoundId:
              round.fantagolRoundId,
            eligibleAt,
            competitionCode:
              "SA",
          },
        );

      /*
       * R2B2-B deliberately stops here.
       *
       * The job may now exist in the canonical queue, but R2B2-A still
       * makes its worker execution fail closed before the Odds provider.
       */
      throw new Error(
        [
          "THE_ODDS_BOOTSTRAP_PENDING",
          bootstrapDecision.reason,
          eligibleAt,
          bootstrapJob.jobId,
          bootstrapJob.inserted
            ? "inserted"
            : "reused",
          `${bootstrapDecision.mappedMatchCount}/${bootstrapDecision.requiredMatchCount}`,
        ].join(":"),
      );
    }

    const targets =
      await deps.loadMarketTargets(
        input.client,
        round.fantagolRoundId,
      );

    const policyInput =
      await deps.loadMarketPolicyInput({
        client: input.client,
        round,
        targets,
        now,
      });

    const policyDecision =
      decideMarketRoundPollingPolicy(
        policyInput,
      );

    const scheduled =
      await deps.scheduleMarket({
        client: input.client,
        fantagolRoundId:
          round.fantagolRoundId,
        targets,
        policyInput,
        correlationId,
        priority:
          input.priority,
      });

    marketStep =
      completed(
        scheduled,
      );

    /*
     * PACKAGE is complete at this boundary.
     *
     * Anything below belongs exclusively to
     * ADVANCED governance and MUST NOT mutate
     * the already completed PACKAGE result.
     */
    if (
      policyDecision.advancedWindow !==
      null
    ) {
      try {
        const creditState =
          await deps.loadMonthlyMarketCreditState({
            client:
              input.client,
            now,
          });

        const maxCallsThisRun =
          Math.min(
            creditState
              .maximumAdvancedCallsByBucket,
            ADVANCED_OPERATIONAL_MAX_CALLS_PER_HEARTBEAT,
          );

        if (
          maxCallsThisRun > 0
        ) {
          const plan:
            AdvancedMarketPlan =
            await deps.buildAdvancedPlan({
              client:
                input.client,
              fantagolRoundId:
                round.fantagolRoundId,
              targets,
              now,
              window:
                policyDecision
                  .advancedWindow,
              budgetInput:
                creditState
                  .governorBudgetInput,
              maxCallsThisRun,
            });

          if (
            plan.selectedTargets.length >
            0
          ) {
            marketAdvancedStep =
              completed(
                await deps
                  .scheduleAdvancedMarket({
                    client:
                      input.client,
                    fantagolRoundId:
                      round.fantagolRoundId,
                    plan,
                    now,
                    correlationId,
                    priority:
                      input.priority,
                  }),
              );
          }
        }
      } catch (error) {
        marketAdvancedStep =
          failed(
            error,
          );
      }
    }
  } catch (error) {
    /*
     * Failure before PACKAGE completion means
     * the market PACKAGE step itself failed.
     * ADVANCED remains fail-closed/skipped.
     */
    marketStep =
      failed(
        error,
      );

    marketAdvancedStep =
      skipped();
  }

  /*
   * Canonical prediction-opening advancement.
   *
   * Heartbeat owns no opening semantics.
   * The DB authority is idempotent and fail-closed.
   *
   * A PACKAGE scheduled during this heartbeat may only be
   * persisted by the worker later. A subsequent heartbeat
   * retries after Surprise Reference becomes READY.
   */
  try {
    await deps.advancePredictionOpening({
      client: input.client,
      fantagolRoundId:
        round.fantagolRoundId,
    });
  } catch {
    /*
     * Opening advancement failure must not reclassify Market or
     * ADVANCED execution. The next heartbeat retries.
     */
  }

  /*
   * Canonical prediction-lock advancement.
   *
   * Heartbeat owns no lock semantics. The DB authority delegates
   * every League Round to lock_round_predictions_rpc and is
   * idempotent / fail-closed before lock_at.
   */
  try {
    await deps.advancePredictionLock({
      client: input.client,
      fantagolRoundId:
        round.fantagolRoundId,
    });
  } catch {
    /*
     * A lock-authority failure must not stop provider polling.
     * The next heartbeat retries the idempotent authority.
     */
  }

  /*
   * Canonical live lifecycle advancement.
   *
   * The heartbeat owns no match/live semantics.
   * The DB authority advances only after persisted provider state proves
   * that one required official Match Set member is actually live.
   *
   * first_official_score_at is resolved independently from accepted
   * MATCH_SCORE_CHANGED evidence, so live 0-0 remains valid.
   */

  try {
    await deps.advanceRoundLive({
      client: input.client,
      fantagolRoundId:
        round.fantagolRoundId,
    });
  } catch {
    /*
     * A lifecycle-authority failure must not stop provider polling or
     * worker drainage. The next heartbeat retries the idempotent authority.
     */
  }

  /*
   * Recovery expiry is terminal cleanup only.
   * It must not mutate canonical round lifecycle state.
   * Failure is retried by the next heartbeat.
   */
  /*
   * Canonical post-LIVE lifecycle reconciliation.
   *
   * The database owns all terminal-match semantics.
   * This heartbeat merely asks the idempotent authority whether the
   * round can advance LIVE -> FINAL_CALCULABLE.
   */
  try {
    await deps.advanceRoundFinalCalculable({
      client: input.client,
      fantagolRoundId:
        round.fantagolRoundId,
    });

    /*
     * Lifecycle-specific final rebuild producer.
     *
     * The database authority deliberately owns no job enqueue.
     * Once League Rounds are FINAL_CALCULABLE, enqueue one
     * idempotent final rebuild per enabled League Round.
     *
     * If the round is not ready yet this resolves zero targets.
     * Partial enqueue failure is safe: the next heartbeat retries
     * and enqueue_live_runtime_job_rpc preserves idempotency.
     */
    await deps.enqueueFinalCalculableRebuilds({
      client: input.client,
      fantagolRoundId:
        round.fantagolRoundId,
      correlationId,
      causationId: null,
    });
  } catch {
    /*
     * Fail open at transport/orchestration level.
     * The DB authority itself fails closed and the next heartbeat retries.
     */
  }


  try {
    await deps.expireDuePredictionRecoveries({
      client: input.client,
      at: startedAt,
    });
  } catch {
    /*
     * Recovery expiry failure must not stop provider polling or
     * worker drainage. The next heartbeat retries the idempotent sweep.
     */
  }

  let communityStep:
    ProductionHeartbeatStep<unknown>;

  try {
    const decision =
      await deps.resolveCommunityDecision({
        client: input.client,
        round,
        now,
      });

    if (decision.action === "skip") {
      communityStep = {
        status: "skipped",
        value: {
          reason: decision.reason,
        },
        error: null,
      };
    } else if (
      decision.action === "freeze"
    ) {
      communityStep =
        completed(
          await deps.freezeCommunity({
            client: input.client,
            fantagolRoundId:
              round.fantagolRoundId,
            correlationId,
          }),
        );
    } else {
      communityStep =
        completed(
          await deps.refreshCommunity({
            client: input.client,
            fantagolRoundId:
              round.fantagolRoundId,
            correlationId,
          }),
        );
    }
  } catch (error) {
    communityStep = failed(error);
  }

  let workerStep:
    ProductionHeartbeatStep<ProductionHeartbeatWorkerDrain>;

  try {
    workerStep =
      completed(
        await drainWorker({
          client: input.client,
          workerId: input.workerId,
          jobTypes:
            input.workerJobTypes ?? null,
          maxJobs:
            Math.max(
              0,
              Math.min(
                input.maxWorkerJobs ?? 8,
                50,
              ),
            ),
          runWorkerOnce:
            deps.runWorkerOnce,
        }),
      );
  } catch (error) {
    workerStep = failed(error);
  }

  return {
    startedAt,
    finishedAt:
      new Date().toISOString(),
    round: roundStep,
    footballData: footballDataStep,
    market: marketStep,
    marketAdvanced:
      marketAdvancedStep,
    community: communityStep,
    worker: workerStep,
  };
}
