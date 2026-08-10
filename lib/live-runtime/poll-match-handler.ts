import type { SupabaseClient } from "@supabase/supabase-js";

import { LiveRuntimeError } from "./errors";
import {
  ingestFootballDataPollResult,
  sha256ProviderPayload,
} from "./football-data-poll-ingestion";
import type { ClaimedLiveRuntimeJob } from "./job-service";
import { persistCanonicalOddsSnapshot } from "./odds-snapshot-service";
import { createDefaultProviderRuntimeRegistry } from "./provider-runtime-registry";
import { executeProviderPoll } from "./provider-runtime-runner";
import { normalizeTheOddsApiSnapshot } from "./the-odds-api-snapshot-normalizer";

function getRequiredString(
  payload: Record<string, unknown>,
  key: string,
): string {
  const value = payload[key];

  if (typeof value !== "string" || value.trim() === "") {
    throw new LiveRuntimeError({
      code: "LIVE_RUNTIME_INVALID_JOB_PAYLOAD",
      message: `poll_match requires non-empty '${key}'`,
      details: { key, value },
    });
  }

  return value.trim();
}

function getOptionalString(
  payload: Record<string, unknown>,
  key: string,
): string | null {
  const value = payload[key];

  if (value === null || value === undefined) {
    return null;
  }

  if (typeof value !== "string" || value.trim() === "") {
    throw new LiveRuntimeError({
      code: "LIVE_RUNTIME_INVALID_JOB_PAYLOAD",
      message: `poll_match requires '${key}' to be string or null`,
      details: { key, value },
    });
  }

  return value.trim();
}

function getStringArray(
  payload: Record<string, unknown>,
  key: string,
): string[] {
  const value = payload[key];

  if (value === undefined || value === null) {
    return [];
  }

  if (
    !Array.isArray(value) ||
    value.some(
      (entry) =>
        typeof entry !== "string" || entry.trim() === "",
    )
  ) {
    throw new LiveRuntimeError({
      code: "LIVE_RUNTIME_INVALID_JOB_PAYLOAD",
      message:
        `poll_match requires '${key}' to be an array of non-empty strings`,
      details: { key, value },
    });
  }

  return value.map((entry) => entry.trim());
}


export async function handlePollMatchJob(input: {
  client: SupabaseClient;
  job: ClaimedLiveRuntimeJob;
}): Promise<Record<string, unknown>> {
  const { client, job } = input;

  if (job.scopeType !== "match") {
    throw new LiveRuntimeError({
      code: "LIVE_RUNTIME_INVALID_JOB_PAYLOAD",
      message: "poll_match requires match scope",
      details: {
        jobId: job.jobId,
        scopeType: job.scopeType,
      },
    });
  }

  const matchId =
    getRequiredString(job.payload, "match_id") || job.scopeId;
  const providerCode = getRequiredString(
    job.payload,
    "provider_code",
  );
  const externalMatchId = getRequiredString(
    job.payload,
    "external_match_id",
  );

  if (matchId !== job.scopeId) {
    throw new LiveRuntimeError({
      code: "LIVE_RUNTIME_INVALID_JOB_PAYLOAD",
      message: "poll_match payload match_id must equal job scope_id",
      details: {
        jobId: job.jobId,
        scopeId: job.scopeId,
        matchId,
      },
    });
  }

  if (
    providerCode !== "the_odds_api" &&
    providerCode !== "football_data"
  ) {
    throw new LiveRuntimeError({
      code: "LIVE_RUNTIME_UNSUPPORTED_JOB",
      message:
        `poll_match provider branch '${providerCode}' is not active yet`,
      details: {
        jobId: job.jobId,
        providerCode,
        supportedProviders: [
          "the_odds_api",
          "football_data",
        ],
      },
    });
  }

  const registry = createDefaultProviderRuntimeRegistry();
  const poll = await executeProviderPoll(
    client,
    registry,
    providerCode,
    externalMatchId,
  );

  if (providerCode === "the_odds_api") {
    const snapshot = normalizeTheOddsApiSnapshot({
      providerCode: poll.providerCode,
      externalMatchId: poll.externalMatchId,
      fetchedAt: poll.fetchedAt,
      payload: poll.payload,
    });

    const persisted = await persistCanonicalOddsSnapshot(client, {
      matchId,
      providerPayload: poll.payload,
      snapshot,
    });

    return {
      branch: "official_odds",
      provider_code: poll.providerCode,
      external_match_id: poll.externalMatchId,
      match_id: persisted.matchId,
      fetched_at: poll.fetchedAt,
      provider_payload_hash: sha256ProviderPayload(poll.payload),
      odds_market_snapshot_id: persisted.oddsMarketSnapshotId,
      snapshot_hash: persisted.snapshotHash,
      collected_at: persisted.collectedAt,
      inserted: persisted.inserted,
      valid_bookmakers: snapshot.quality.validBookmakers,
      has_consensus: snapshot.quality.hasConsensus,
      consensus_method: snapshot.consensus?.method ?? null,
    };
  }

  const ingestion =
    await ingestFootballDataPollResult({
      client,
      poll,
      scope: {
        matchId,
        fantagolRoundId: getOptionalString(
          job.payload,
          "fantagol_round_id",
        ),
        leagueRoundIds: getStringArray(
          job.payload,
          "league_round_ids",
        ),
      },
    });

  return {
    branch: "official_live_match",
    ...ingestion,
  };
}
