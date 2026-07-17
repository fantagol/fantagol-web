import type { SupabaseClient } from "@supabase/supabase-js";

import { detectLiveMatchChange } from "./change-detector";
import { LiveRuntimeError } from "./errors";
import {
  enqueueLiveRuntimeJob,
  type EnqueuedLiveRuntimeJob,
} from "./job-service";
import { enqueueLeagueRoundRebuildJobs } from "./rebuild-enqueue";
import { normalizeLiveMatchUpdate } from "./normalizer";
import { decidePollingPolicy } from "./polling-policy";
import {
  registerLiveMatchUpdate,
  type LiveMatchUpdateReceipt,
} from "./receipt-service";
import type {
  LiveProviderMatch,
  LiveRuntimeChangeDetection,
  PollingPolicyDecision,
  RuntimeNormalizedMatchUpdate,
  RuntimePersistedMatchState,
} from "./types";

export type LiveRuntimeIngestionScope = {
  matchId: string;
  fantagolRoundId: string | null;
  leagueRoundIds: string[];
};

export type IngestLiveProviderUpdateInput = {
  client: SupabaseClient;
  match: LiveProviderMatch;
  previousState: RuntimePersistedMatchState | null;
  scope: LiveRuntimeIngestionScope;
  payloadHash: string;
  correlationId?: string | null;
  causationId?: string | null;
  receivedAt?: Date;
  roundCertified?: boolean;
  postLiveStable?: boolean;
};

export type LiveRuntimeIngestionResult = {
  normalizedUpdate: RuntimeNormalizedMatchUpdate;
  change: LiveRuntimeChangeDetection;
  receipt: LiveMatchUpdateReceipt;
  enqueuedJobs: EnqueuedLiveRuntimeJob[];
  polling: PollingPolicyDecision;
  duplicate: boolean;
  meaningfulChange: boolean;
};

function requireSha256(value: string): string {
  const canonical = value.trim().toLowerCase();

  if (!/^[0-9a-f]{64}$/.test(canonical)) {
    throw new LiveRuntimeError({
      code: "LIVE_RUNTIME_INVALID_PAYLOAD_HASH",
      message: "payloadHash must be a lowercase SHA-256 hexadecimal value",
      details: { payloadHash: value },
    });
  }

  return canonical;
}

function buildMatchRefreshIdempotencyKey(input: {
  matchId: string;
  providerUpdatedAt: string;
  payloadHash: string;
}): string {
  return [
    "live",
    "refresh-match",
    input.matchId,
    input.providerUpdatedAt,
    input.payloadHash,
  ].join(":");
}

async function enqueueMeaningfulChangeJobs(input: {
  client: SupabaseClient;
  scope: LiveRuntimeIngestionScope;
  update: RuntimeNormalizedMatchUpdate;
  change: LiveRuntimeChangeDetection;
  receipt: LiveMatchUpdateReceipt;
  payloadHash: string;
  causationId?: string | null;
}): Promise<EnqueuedLiveRuntimeJob[]> {
  const jobs: EnqueuedLiveRuntimeJob[] = [];

  const refreshJob = await enqueueLiveRuntimeJob(input.client, {
    jobType: "refresh_round",
    scopeType: "match",
    scopeId: input.scope.matchId,
    idempotencyKey: buildMatchRefreshIdempotencyKey({
      matchId: input.scope.matchId,
      providerUpdatedAt: input.update.providerUpdatedAt,
      payloadHash: input.payloadHash,
    }),
    priority: 20,
    payload: {
      receipt_id: input.receipt.receiptId,
      match_id: input.scope.matchId,
      fantagol_round_id: input.scope.fantagolRoundId,
      external_match_id: input.update.externalMatchId,
      provider_code: input.update.providerCode,
      change_type: input.change.changeType,
      changed_fields: input.change.changedFields,
      normalized_update: input.update.normalizedPayload,
    },
    correlationId: input.receipt.correlationId,
    causationId: input.causationId ?? null,
  });

  jobs.push(refreshJob);

  const rebuildJobs = await enqueueLeagueRoundRebuildJobs({
    client: input.client,
    leagueRoundIds: input.scope.leagueRoundIds,
    receiptId: input.receipt.receiptId,
    matchId: input.scope.matchId,
    fantagolRoundId: input.scope.fantagolRoundId,
    changeType: input.change.changeType,
    changedFields: input.change.changedFields,
    correlationId: input.receipt.correlationId,
    causationId: refreshJob.jobId,
  });

  jobs.push(...rebuildJobs);

  return jobs;
}

/**
 * Ingests one provider-normalized match update into the persistent Live Runtime.
 *
 * This function deliberately does not mutate Match state, rebuild simulations,
 * create Live State Snapshots or publish them. It only:
 *
 * 1. creates the canonical runtime update;
 * 2. detects whether the update is meaningful;
 * 3. registers the immutable provider receipt;
 * 4. enqueues the downstream runtime work when required;
 * 5. returns the next polling decision.
 */
export async function ingestLiveProviderUpdate(
  input: IngestLiveProviderUpdateInput,
): Promise<LiveRuntimeIngestionResult> {
  if (!input.scope.matchId) {
    throw new LiveRuntimeError({
      code: "LIVE_RUNTIME_CONFIGURATION_ERROR",
      message: "A resolved internal matchId is required for live ingestion",
    });
  }

  const payloadHash = requireSha256(input.payloadHash);
  const normalizedUpdate = normalizeLiveMatchUpdate(
    input.match,
    input.receivedAt,
  );
  const change = detectLiveMatchChange(
    input.previousState,
    normalizedUpdate,
  );

  const receipt = await registerLiveMatchUpdate(input.client, {
    matchId: input.scope.matchId,
    payloadHash,
    update: normalizedUpdate,
    change,
    correlationId: input.correlationId ?? null,
  });

  const duplicate = !receipt.inserted;

  let enqueuedJobs: EnqueuedLiveRuntimeJob[] = [];

  if (
    !duplicate &&
    receipt.processingStatus === "accepted" &&
    change.meaningfulChange
  ) {
    enqueuedJobs = await enqueueMeaningfulChangeJobs({
      client: input.client,
      scope: input.scope,
      update: normalizedUpdate,
      change,
      receipt,
      payloadHash,
      causationId: input.causationId ?? null,
    });
  }

  const polling = decidePollingPolicy({
    status: normalizedUpdate.status,
    kickoffAt: normalizedUpdate.kickoffAt,
    postLiveStable: input.postLiveStable,
    roundCertified: input.roundCertified,
  });

  return {
    normalizedUpdate,
    change,
    receipt,
    enqueuedJobs,
    polling,
    duplicate,
    meaningfulChange: change.meaningfulChange,
  };
}
