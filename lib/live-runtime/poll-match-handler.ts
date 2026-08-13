import type { SupabaseClient } from "@supabase/supabase-js";

import { LiveRuntimeError } from "./errors";
import {
  ingestFootballDataPollResult,
  sha256ProviderPayload,
} from "./football-data-poll-ingestion";
import type { ClaimedLiveRuntimeJob } from "./job-service";
import {
  persistMarketBatchIntelligence,
} from "./market-intelligence-round-orchestrator";
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



function getRequiredPositiveInteger(
  payload: Record<string, unknown>,
  key: string,
): number {
  const value = payload[key];

  if (
    typeof value !== "number" ||
    !Number.isInteger(value) ||
    value <= 0
  ) {
    throw new LiveRuntimeError({
      code: "LIVE_RUNTIME_INVALID_JOB_PAYLOAD",
      message:
        `poll_match requires positive integer '${key}'`,
      details: {
        key,
        value,
      },
    });
  }

  return value;
}


function getPollTransport(
  payload: unknown,
): Record<string, unknown> {
  if (
    payload === null ||
    typeof payload !== "object" ||
    Array.isArray(payload)
  ) {
    throw new LiveRuntimeError({
      code: "LIVE_RUNTIME_INVALID_JOB_PAYLOAD",
      message:
        "The Odds API poll_match payload must be an object",
    });
  }

  const transport =
    (payload as Record<string, unknown>)
      .transport;

  if (
    transport === null ||
    typeof transport !== "object" ||
    Array.isArray(transport)
  ) {
    throw new LiveRuntimeError({
      code: "LIVE_RUNTIME_INVALID_JOB_PAYLOAD",
      message:
        "The Odds API poll_match payload requires transport metadata",
    });
  }

  return transport as Record<string, unknown>;
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
  const marketSnapshotSource =
    getOptionalString(
      job.payload,
      "market_snapshot_source",
    );

  const requestedMarkets =
    getStringArray(
      job.payload,
      "markets",
    );

  if (
    marketSnapshotSource !== null &&
    marketSnapshotSource !== "ADVANCED"
  ) {
    throw new LiveRuntimeError({
      code: "LIVE_RUNTIME_INVALID_JOB_PAYLOAD",
      message:
        "poll_match market_snapshot_source must be ADVANCED when provided",
      details: {
        jobId: job.jobId,
        marketSnapshotSource,
      },
    });
  }

  if (
    marketSnapshotSource === "ADVANCED" &&
    providerCode !== "the_odds_api"
  ) {
    throw new LiveRuntimeError({
      code: "LIVE_RUNTIME_UNSUPPORTED_JOB",
      message:
        "ADVANCED poll_match requires the_odds_api",
      details: {
        jobId: job.jobId,
        providerCode,
      },
    });
  }

  if (
    marketSnapshotSource === "ADVANCED" &&
    requestedMarkets.length === 0
  ) {
    throw new LiveRuntimeError({
      code: "LIVE_RUNTIME_INVALID_JOB_PAYLOAD",
      message:
        "ADVANCED poll_match requires explicit markets",
      details: {
        jobId: job.jobId,
      },
    });
  }


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

  const registry =
    createDefaultProviderRuntimeRegistry({
      theOddsApiMarkets:
        marketSnapshotSource ===
        "ADVANCED"
          ? requestedMarkets
          : undefined,
    });
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

    if (
      marketSnapshotSource ===
      "ADVANCED"
    ) {
      const fantagolRoundId =
        getRequiredString(
          job.payload,
          "fantagol_round_id",
        );

      const slotNumber =
        getRequiredPositiveInteger(
          job.payload,
          "slot_number",
        );

      const market =
        await persistMarketBatchIntelligence({
          client,
          fantagolRoundId,
          source:
            "ADVANCED",
          capturedAt:
            poll.fetchedAt,
          matches: [
            {
              matchId,
              externalMatchId:
                poll.externalMatchId,
              oddsMarketSnapshotId:
                persisted.oddsMarketSnapshotId,
              slotNumber,
              fetchedAt:
                poll.fetchedAt,
              providerPayload:
                poll.payload,
            },
          ],
          metadata: {
            source_job_id:
              job.jobId,
            provider_code:
              poll.providerCode,
            provider_transport:
              "event",
            market_operating_mode:
              getOptionalString(
                job.payload,
                "market_operating_mode",
              ),
            advanced_window:
              getOptionalString(
                job.payload,
                "advanced_window",
              ),
            requested_markets:
              requestedMarkets,
          },
        });

      return {
        branch:
          "official_odds_market_intelligence_event",
        provider_code:
          poll.providerCode,
        transport:
          getPollTransport(
            poll.payload,
          ),
        external_match_id:
          poll.externalMatchId,
        match_id:
          persisted.matchId,
        fetched_at:
          poll.fetchedAt,
        provider_payload_hash:
          sha256ProviderPayload(
            poll.payload,
          ),
        odds_market_snapshot_id:
          persisted.oddsMarketSnapshotId,
        snapshot_hash:
          persisted.snapshotHash,
        collected_at:
          persisted.collectedAt,
        inserted:
          persisted.inserted,
        valid_bookmakers:
          snapshot.quality.validBookmakers,
        has_consensus:
          snapshot.quality.hasConsensus,
        consensus_method:
          snapshot.consensus?.method ??
          null,
        market_modeled_match_count:
          market.modeledMatchCount,
        market_snapshot:
          market.persistence,
        market_snapshot_source:
          "ADVANCED",
      };
    }

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
