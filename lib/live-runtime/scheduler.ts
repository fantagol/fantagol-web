import type { SupabaseClient } from "@supabase/supabase-js";

import {
  enqueueLiveRuntimeJob,
  type EnqueuedLiveRuntimeJob,
} from "./job-service";
import {
  buildAggregatedPollingPlans,
  type AggregatedPollingPlan,
} from "./aggregated-polling-scheduler";
import {
  resolveFootballDataPollingDecision,
  type FootballDataPollingDecision,
} from "./football-data-polling-policy";
import { decideMarketPollingPolicy } from "./market-polling-policy";
import { decidePollingPolicy } from "./polling-policy";
import type {
  PollingPolicyDecision,
  RuntimePersistedMatchState,
} from "./types";

export type LivePollingTarget = {
  matchId: string;
  providerCode: string;
  externalMatchId: string;
  kickoffAt: string;
  status: RuntimePersistedMatchState["status"];
  fantagolRoundId?: string | null;
  leagueRoundIds?: string[];
  postLiveStable?: boolean;
  roundCertified?: boolean;
  providerMetadata?: Record<string, unknown>;
};

export type ScheduleLivePollingInput = {
  client: SupabaseClient;
  target: LivePollingTarget;
  now?: Date;
  correlationId?: string | null;
  causationId?: string | null;
  priority?: number;
};

export type ScheduledLivePolling = {
  target: LivePollingTarget;
  decision: PollingPolicyDecision;
  nextPollAt: string | null;
  job: EnqueuedLiveRuntimeJob | null;
};

export type ScheduleLivePollingBatchInput = {
  client: SupabaseClient;
  targets: LivePollingTarget[];
  now?: Date;
  correlationId?: string | null;
  priority?: number;
};

export type ScheduledLivePollingBatch = {
  evaluatedCount: number;
  scheduledCount: number;
  stoppedCount: number;
  results: ScheduledLivePolling[];
};

function toIsoSecond(date: Date): string {
  return new Date(
    Math.floor(date.getTime() / 1000) * 1000,
  ).toISOString();
}

function buildPollIdempotencyKey(input: {
  providerCode: string;
  externalMatchId: string;
  nextPollAt: string;
}): string {
  return [
    "live",
    "poll-match",
    input.providerCode,
    input.externalMatchId,
    input.nextPollAt,
  ].join(":");
}

export async function scheduleLivePolling(
  input: ScheduleLivePollingInput,
): Promise<ScheduledLivePolling> {
  const now = input.now ?? new Date();

  const decision =
    input.target.providerCode === "the_odds_api"
      ? decideMarketPollingPolicy({
          status: input.target.status,
          kickoffAt: input.target.kickoffAt,
          now,
          roundCertified: input.target.roundCertified,
        })
      : decidePollingPolicy({
          status: input.target.status,
          kickoffAt: input.target.kickoffAt,
          now,
          postLiveStable: input.target.postLiveStable,
          roundCertified: input.target.roundCertified,
        });

  if (!decision.shouldPoll || decision.intervalSeconds === null) {
    return {
      target: input.target,
      decision,
      nextPollAt: null,
      job: null,
    };
  }

  const nextPollAt = toIsoSecond(
    new Date(now.getTime() + decision.intervalSeconds * 1000),
  );

  const job = await enqueueLiveRuntimeJob(input.client, {
    jobType: "poll_match",
    scopeType: "match",
    scopeId: input.target.matchId,
    idempotencyKey: buildPollIdempotencyKey({
      providerCode: input.target.providerCode,
      externalMatchId: input.target.externalMatchId,
      nextPollAt,
    }),
    priority: input.priority ?? 10,
    scheduledAt: nextPollAt,
    payload: {
      match_id: input.target.matchId,
      provider_code: input.target.providerCode,
      external_match_id: input.target.externalMatchId,
      kickoff_at: input.target.kickoffAt,
      current_status: input.target.status,
      fantagol_round_id: input.target.fantagolRoundId ?? null,
      league_round_ids: input.target.leagueRoundIds ?? [],
      polling_band: decision.band,
      polling_reason: decision.reason,
      provider_metadata: input.target.providerMetadata ?? {},
    },
    correlationId: input.correlationId ?? null,
    causationId: input.causationId ?? null,
  });

  return {
    target: input.target,
    decision,
    nextPollAt,
    job,
  };
}

export async function scheduleLivePollingBatch(
  input: ScheduleLivePollingBatchInput,
): Promise<ScheduledLivePollingBatch> {
  const now = input.now ?? new Date();
  const results: ScheduledLivePolling[] = [];

  // Sequential enqueueing deliberately protects provider/runtime bursts and
  // keeps ordering deterministic for equal scheduling timestamps.
  for (const target of input.targets) {
    results.push(
      await scheduleLivePolling({
        client: input.client,
        target,
        now,
        correlationId: input.correlationId ?? null,
        priority: input.priority,
      }),
    );
  }

  return {
    evaluatedCount: results.length,
    scheduledCount: results.filter((result) => result.job !== null).length,
    stoppedCount: results.filter((result) => result.job === null).length,
    results,
  };
}

export type ScheduledFootballDataAggregate = {
  fantagolRoundId: string;
  plan: AggregatedPollingPlan;
  decision: FootballDataPollingDecision;
  nextPollAt: string;
  job: EnqueuedLiveRuntimeJob;
};

export type ScheduleFootballDataAggregatedPollingInput = {
  client: SupabaseClient;
  targets: LivePollingTarget[];
  now?: Date;
  correlationId?: string | null;
  causationId?: string | null;
  priority?: number;
  competitionCode?: string;
};

function buildAggregatePollIdempotencyKey(input: {
  fantagolRoundId: string;
  mode: AggregatedPollingPlan["mode"];
  nextPollAt: string;
}): string {
  return [
    "live",
    "poll-batch",
    "football_data",
    input.fantagolRoundId,
    input.mode,
    input.nextPollAt,
  ].join(":");
}

function earliestFutureKickoff(
  targets: LivePollingTarget[],
  externalMatchIds: string[],
): Date | null {
  const allowed =
    new Set(externalMatchIds);

  const dates =
    targets
      .filter(
        (target) =>
          allowed.has(
            target.externalMatchId,
          ),
      )
      .map(
        (target) =>
          new Date(
            target.kickoffAt,
          ),
      )
      .filter(
        (value) =>
          !Number.isNaN(
            value.getTime(),
          ),
      )
      .sort(
        (a, b) =>
          a.getTime() -
          b.getTime(),
      );

  return dates[0] ?? null;
}

/**
 * Production Football Data scheduling path.
 *
 * One FantaGol Round becomes at most:
 *
 *   1 aggregate LIVE job
 *   1 aggregate PREMATCH job
 *
 * instead of N poll_match jobs.
 */
export async function scheduleFootballDataAggregatedPolling(
  input: ScheduleFootballDataAggregatedPollingInput,
): Promise<ScheduledFootballDataAggregate[]> {
  const now =
    input.now ?? new Date();

  const footballDataTargets =
    input.targets.filter(
      (target) =>
        target.providerCode ===
        "football_data",
    );

  if (
    footballDataTargets.length === 0
  ) {
    return [];
  }

  const byRound =
    new Map<
      string,
      LivePollingTarget[]
    >();

  for (
    const target of
    footballDataTargets
  ) {
    const fantagolRoundId =
      target.fantagolRoundId;

    if (!fantagolRoundId) {
      throw new Error(
        `Football Data aggregate target '${target.matchId}' requires fantagolRoundId`,
      );
    }

    const group =
      byRound.get(
        fantagolRoundId,
      ) ?? [];

    group.push(target);

    byRound.set(
      fantagolRoundId,
      group,
    );
  }

  const scheduled:
    ScheduledFootballDataAggregate[] = [];

  for (
    const [
      fantagolRoundId,
      roundTargets,
    ] of byRound
  ) {
    const plans =
      buildAggregatedPollingPlans({
        providerCode:
          "football_data",
        competitionCode:
          input.competitionCode ??
          "SA",
        now,
        targets:
          roundTargets.map(
            (target) => ({
              providerCode:
                target.providerCode,
              externalMatchId:
                target.externalMatchId,
              kickoffAt:
                target.kickoffAt,
              matchStatus:
                target.status,
            }),
          ),
      });

    for (const plan of plans) {
      const planTargets =
        roundTargets.filter(
          (target) =>
            plan.externalMatchIds.includes(
              target.externalMatchId,
            ),
        );

      const decision =
        resolveFootballDataPollingDecision({
          now,
          mode:
            plan.mode,
          nextKickoffAt:
            plan.mode ===
            "prematch"
              ? earliestFutureKickoff(
                  planTargets,
                  plan.externalMatchIds,
                )
              : null,
        });

      const nextPollAt =
        toIsoSecond(
          new Date(
            now.getTime() +
              decision.intervalSeconds *
                1000,
          ),
        );

      const job =
        await enqueueLiveRuntimeJob(
          input.client,
          {
            jobType:
              "poll_batch",
            scopeType:
              "fantagol_round",
            scopeId:
              fantagolRoundId,
            idempotencyKey:
              buildAggregatePollIdempotencyKey({
                fantagolRoundId,
                mode:
                  plan.mode,
                nextPollAt,
              }),
            priority:
              input.priority ?? 10,
            scheduledAt:
              nextPollAt,
            payload: {
              provider_code:
                "football_data",
              mode:
                plan.mode,
              competition_code:
                plan.competitionCode,
              date_from:
                plan.mode ===
                "prematch"
                  ? plan.dateFrom
                  : null,
              date_to:
                plan.mode ===
                "prematch"
                  ? plan.dateTo
                  : null,
              polling_band:
                decision.band,
              polling_reason:
                decision.reason,
              match_targets:
                planTargets.map(
                  (target) => ({
                    match_id:
                      target.matchId,
                    external_match_id:
                      target.externalMatchId,
                    fantagol_round_id:
                      fantagolRoundId,
                    league_round_ids:
                      target.leagueRoundIds ??
                      [],
                    kickoff_at:
                      target.kickoffAt,
                    current_status:
                      target.status,
                  }),
                ),
            },
            correlationId:
              input.correlationId ??
              null,
            causationId:
              input.causationId ??
              null,
          },
        );

      scheduled.push({
        fantagolRoundId,
        plan,
        decision,
        nextPollAt,
        job,
      });
    }
  }

  return scheduled;
}
