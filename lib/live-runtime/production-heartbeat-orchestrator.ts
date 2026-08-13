import type { SupabaseClient } from "@supabase/supabase-js";

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
import type {
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

async function refreshCommunityDefault(input: {
  client: SupabaseClient;
  fantagolRoundId: string;
  correlationId: string | null;
}): Promise<unknown> {
  const { data, error } = await input.client.rpc(
    "refresh_community_snapshot_rpc",
    {
      p_fantagol_round_id: input.fantagolRoundId,
      p_engine_version: "community-intelligence-v1",
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
      p_engine_version: "community-intelligence-v1",
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