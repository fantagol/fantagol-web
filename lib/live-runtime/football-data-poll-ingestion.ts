import { createHash } from "node:crypto";

import type { SupabaseClient } from "@supabase/supabase-js";

import { normalizeMatch } from "../providers/football-data/normalizers";
import type { FootballDataMatch } from "../providers/football-data/types";
import { LiveRuntimeError } from "./errors";
import {
  resolveFootballDataIngestionAdmission,
} from "./football-data-authority-policy";
import { resolveLiveRuntimeAuthorityState } from "./live-primary-authority";
import { loadPreviousLiveMatchState } from "./live-match-state-service";
import { ingestLiveProviderUpdate } from "./orchestrator";
import type { ProviderPollResult } from "./provider-runtime";

export type FootballDataPollIngestionScope = {
  matchId: string;
  fantagolRoundId: string | null;
  leagueRoundIds: string[];
};

export type FootballDataPollIngestionResult = {
  provider_code: string;
  external_match_id: string;
  match_id: string;
  fetched_at: string;
  provider_payload_hash: string;
  receipt_id: string | null;
  receipt_inserted: boolean;
  processing_status: string;
  duplicate: boolean;
  meaningful_change: boolean;
  change_type: string;
  changed_fields: string[];
  enqueued_job_ids: string[];
  polling_band: string;
  polling_interval_seconds: number | null;
  should_poll: boolean;
  polling_reason: string;
};

function isRecord(
  value: unknown,
): value is Record<string, unknown> {
  return (
    typeof value === "object" &&
    value !== null &&
    !Array.isArray(value)
  );
}

export function sha256ProviderPayload(
  value: unknown,
): string {
  return createHash("sha256")
    .update(JSON.stringify(value))
    .digest("hex");
}

export function getFootballDataMatchFromPoll(
  payload: unknown,
  expectedExternalMatchId: string,
): FootballDataMatch {
  if (
    !isRecord(payload) ||
    !isRecord(payload.match)
  ) {
    throw new LiveRuntimeError({
      code: "LIVE_RUNTIME_INVALID_MATCH",
      message:
        "Football-Data poll payload must contain a match object",
      details: { payload },
    });
  }

  const match = payload.match;

  if (
    typeof match.id !== "number" ||
    String(match.id) !== expectedExternalMatchId ||
    typeof match.utcDate !== "string" ||
    typeof match.status !== "string" ||
    !isRecord(match.competition) ||
    !isRecord(match.season) ||
    !isRecord(match.homeTeam) ||
    !isRecord(match.awayTeam) ||
    !isRecord(match.score) ||
    !isRecord(match.score.fullTime)
  ) {
    throw new LiveRuntimeError({
      code: "LIVE_RUNTIME_INVALID_MATCH",
      message:
        "Football-Data poll returned an invalid or mismatched match payload",
      details: {
        expectedExternalMatchId,
        receivedExternalMatchId:
          typeof match.id === "number"
            ? String(match.id)
            : null,
      },
    });
  }

  return match as unknown as FootballDataMatch;
}

export async function ingestFootballDataPollResult(input: {
  client: SupabaseClient;
  poll: ProviderPollResult;
  scope: FootballDataPollIngestionScope;
}): Promise<FootballDataPollIngestionResult> {
  if (input.poll.providerCode !== "football_data") {
    throw new LiveRuntimeError({
      code: "LIVE_RUNTIME_UNSUPPORTED_JOB",
      message:
        "Football Data ingestion received another provider",
      details: {
        providerCode: input.poll.providerCode,
      },
    });
  }

  const providerMatch =
    getFootballDataMatchFromPoll(
      input.poll.payload,
      input.poll.externalMatchId,
    );

  const previousState =
    await loadPreviousLiveMatchState(
      input.client,
      input.scope.matchId,
    );

  const normalizedMatch =
    normalizeMatch(providerMatch);

  const providerPayloadHash =
    sha256ProviderPayload(
      input.poll.payload,
    );

  /*
   * R114-R9-R2 - EXCLUSIVE LIVE AUTHORITY HARD BARRIER
   *
   * Scheduler suppression prevents new Football-Data work from kickoff while Tutto owns
   * FIRST_HALF / HALFTIME / SECOND_HALF. This ingestion barrier also makes
   * already queued or racing Football-Data jobs harmless.
   *
   * Allowed Football-Data responsibilities:
   *   1. PRE-LIVE schedule/kickoff/postponement/cancellation evidence.
   *   2. Official FINISHED/AWARDED only after Tutto END_PENDING.
   *
   * Football-Data can never establish or mutate provisional LIVE state.
   */
  const liveAuthority =
    await resolveLiveRuntimeAuthorityState(
      input.client,
      input.scope.matchId,
    );

  /*
   * R114-R11B-R2 - SAME AUTHORITY WINDOW AT INGESTION
   *
   * This closes the queued-job race: a Football-Data poll scheduled before
   * kickoff but executed at/after kickoff cannot write while Tutto is taking
   * ownership, even if primary_live has not been materialized yet.
   *
   * The Football-Data payload carries the provider kickoff as utcDate; before
   * LIVE, Football-Data is the schedule authority, so this is the correct
   * temporal boundary for admission. Once Tutto reaches END_PENDING the
   * authority window overrides the clock and allows only FINISHED/AWARDED.
   */
  const footballDataAdmission =
    resolveFootballDataIngestionAdmission({
      authority:
        liveAuthority,
      kickoffAt:
        providerMatch.utcDate,
      receivedAt:
        new Date(input.poll.fetchedAt),
      normalizedStatus:
        normalizedMatch.status,
    });

  if (footballDataAdmission === "suppress") {
    return {
      provider_code:
        input.poll.providerCode,
      external_match_id:
        input.poll.externalMatchId,
      match_id:
        input.scope.matchId,
      fetched_at:
        input.poll.fetchedAt,
      provider_payload_hash:
        providerPayloadHash,
      receipt_id:
        null,
      receipt_inserted:
        false,
      processing_status:
        "suppressed_tutto_exclusive_live",
      duplicate:
        false,
      meaningful_change:
        false,
      change_type:
        "FOOTBALL_DATA_LIVE_SUPPRESSED",
      changed_fields:
        [],
      enqueued_job_ids:
        [],
      polling_band:
        "stopped",
      polling_interval_seconds:
        null,
      should_poll:
        false,
      polling_reason:
        "tuttoilcalcio_exclusive_live_authority",
    };
  }

  const ingestion =
    await ingestLiveProviderUpdate({
      client: input.client,
      match: normalizedMatch,
      previousState,
      scope: {
        matchId: input.scope.matchId,
        fantagolRoundId:
          input.scope.fantagolRoundId,
        leagueRoundIds:
          input.scope.leagueRoundIds,
      },
      payloadHash:
        providerPayloadHash,
      receivedAt:
        new Date(input.poll.fetchedAt),
    });

  return {
    provider_code:
      input.poll.providerCode,
    external_match_id:
      input.poll.externalMatchId,
    match_id:
      input.scope.matchId,
    fetched_at:
      input.poll.fetchedAt,
    provider_payload_hash:
      providerPayloadHash,
    receipt_id:
      ingestion.receipt.receiptId,
    receipt_inserted:
      ingestion.receipt.inserted,
    processing_status:
      ingestion.receipt.processingStatus,
    duplicate:
      ingestion.duplicate,
    meaningful_change:
      ingestion.meaningfulChange,
    change_type:
      ingestion.change.changeType,
    changed_fields:
      ingestion.change.changedFields,
    enqueued_job_ids:
      ingestion.enqueuedJobs.map(
        (job) => job.jobId,
      ),
    polling_band:
      ingestion.polling.band,
    polling_interval_seconds:
      ingestion.polling.intervalSeconds,
    should_poll:
      ingestion.polling.shouldPoll,
    polling_reason:
      ingestion.polling.reason,
  };
}