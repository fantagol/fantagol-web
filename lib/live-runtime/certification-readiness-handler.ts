import type { SupabaseClient } from "@supabase/supabase-js";

import { LiveRuntimeError } from "./errors";
import type { ClaimedLiveRuntimeJob } from "./job-service";
import { freezeOfficialMatchOddsSnapshot } from "./odds-snapshot-service";

type HandleCertificationReadinessJobInput = {
  client: SupabaseClient;
  job: ClaimedLiveRuntimeJob;
};

function getRequiredString(
  payload: Record<string, unknown>,
  key: string,
): string {
  const value = payload[key];

  if (typeof value !== "string" || value.trim() === "") {
    throw new LiveRuntimeError({
      code: "LIVE_RUNTIME_INVALID_JOB_PAYLOAD",
      message:
        `evaluate_certification_readiness requires non-empty payload.${key}`,
      details: { key, value },
    });
  }

  return value.trim();
}

function getOptionalString(
  payload: Record<string, unknown>,
  key: string,
  fallback: string,
): string {
  const value = payload[key];

  if (value === undefined || value === null) {
    return fallback;
  }

  if (typeof value !== "string" || value.trim() === "") {
    throw new LiveRuntimeError({
      code: "LIVE_RUNTIME_INVALID_JOB_PAYLOAD",
      message:
        `evaluate_certification_readiness requires payload.${key} to be a non-empty string when present`,
      details: { key, value },
    });
  }

  return value.trim();
}

function getFreezeAt(payload: Record<string, unknown>): string {
  const value = getOptionalString(
    payload,
    "freeze_at",
    new Date().toISOString(),
  );
  const parsed = new Date(value);

  if (Number.isNaN(parsed.getTime())) {
    throw new LiveRuntimeError({
      code: "LIVE_RUNTIME_INVALID_JOB_PAYLOAD",
      message:
        "evaluate_certification_readiness requires payload.freeze_at to be a valid ISO date",
      details: { freezeAt: value },
    });
  }

  return parsed.toISOString();
}

export async function handleCertificationReadinessJob({
  client,
  job,
}: HandleCertificationReadinessJobInput): Promise<
  Record<string, unknown>
> {
  if (job.scopeType !== "match") {
    throw new LiveRuntimeError({
      code: "LIVE_RUNTIME_INVALID_JOB_PAYLOAD",
      message:
        "evaluate_certification_readiness requires match scope",
      details: {
        jobId: job.jobId,
        scopeType: job.scopeType,
      },
    });
  }

  const matchId = getRequiredString(job.payload, "match_id");

  if (matchId !== job.scopeId) {
    throw new LiveRuntimeError({
      code: "LIVE_RUNTIME_INVALID_JOB_PAYLOAD",
      message:
        "evaluate_certification_readiness scopeId and payload.match_id must match",
      details: {
        jobId: job.jobId,
        scopeId: job.scopeId,
        matchId,
      },
    });
  }

  const freezeAt = getFreezeAt(job.payload);
  const freezeReason = getOptionalString(
    job.payload,
    "freeze_reason",
    "kickoff",
  );
  const policyVersion = getOptionalString(
    job.payload,
    "policy_version",
    "official_match_odds_v1",
  );

  const frozen = await freezeOfficialMatchOddsSnapshot(client, {
    matchId,
    freezeAt,
    freezeReason,
    policyVersion,
  });

  return {
    match_id: frozen.matchId,
    certification_readiness_evaluated: true,
    official_odds_ready: true,
    official_match_odds_snapshot_id:
      frozen.officialMatchOddsSnapshotId,
    odds_market_snapshot_id: frozen.oddsMarketSnapshotId,
    source_collected_at: frozen.sourceCollectedAt,
    official_hash: frozen.officialHash,
    already_frozen: frozen.alreadyFrozen,
    freeze_at: freezeAt,
    freeze_reason: freezeReason,
    policy_version: policyVersion,
  };
}
