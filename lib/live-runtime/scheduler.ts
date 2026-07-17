import type { SupabaseClient } from "@supabase/supabase-js";

import {
  enqueueLiveRuntimeJob,
  type EnqueuedLiveRuntimeJob,
} from "./job-service";
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

  const decision = decidePollingPolicy({
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
