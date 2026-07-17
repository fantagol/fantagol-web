import type { SupabaseClient } from "@supabase/supabase-js";

import { LiveRuntimeError } from "./errors";
import type { ClaimedLiveRuntimeJob } from "./job-service";
import { enqueueLeagueRoundRebuildJobs } from "./rebuild-enqueue";
import {
  callRuntimeRpc,
  requireSingleRpcRow,
} from "./rpc-utils";

type RefreshLiveMatchRpcRow = {
  match_id: string;
  applied: boolean;
  stale: boolean;
  previous_version: number;
  current_version: number;
  provider_updated_at: string;
  match_status: string;
  home_score: number | null;
  away_score: number | null;
  minute: number | null;
  period: string | null;
};

export type HandleRefreshRoundJobInput = {
  client: SupabaseClient;
  job: ClaimedLiveRuntimeJob;
};

function getRequiredString(
  payload: Record<string, unknown>,
  key: string,
): string {
  const value = payload[key];

  if (typeof value !== "string" || value.trim().length === 0) {
    throw new LiveRuntimeError({
      code: "LIVE_RUNTIME_INVALID_JOB_PAYLOAD",
      message: `refresh_round requires payload.${key}`,
      details: { key, payload },
    });
  }

  return value;
}

function getOptionalString(
  payload: Record<string, unknown>,
  key: string,
): string | null {
  const value = payload[key];

  if (value === null || value === undefined) {
    return null;
  }

  if (typeof value !== "string" || value.trim().length === 0) {
    throw new LiveRuntimeError({
      code: "LIVE_RUNTIME_INVALID_JOB_PAYLOAD",
      message: `refresh_round requires payload.${key} to be a string or null`,
      details: { key, payload },
    });
  }

  return value;
}

function getRequiredStringArray(
  payload: Record<string, unknown>,
  key: string,
): string[] {
  const value = payload[key];

  if (
    !Array.isArray(value) ||
    value.some(
      (item) => typeof item !== "string" || item.trim().length === 0,
    )
  ) {
    throw new LiveRuntimeError({
      code: "LIVE_RUNTIME_INVALID_JOB_PAYLOAD",
      message: `refresh_round requires string array payload.${key}`,
      details: { key, payload },
    });
  }

  return [...new Set(value)];
}

function getRequiredObject(
  payload: Record<string, unknown>,
  key: string,
): Record<string, unknown> {
  const value = payload[key];

  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new LiveRuntimeError({
      code: "LIVE_RUNTIME_INVALID_JOB_PAYLOAD",
      message: `refresh_round requires object payload.${key}`,
      details: { key, payload },
    });
  }

  return value as Record<string, unknown>;
}

export async function handleRefreshRoundJob({
  client,
  job,
}: HandleRefreshRoundJobInput): Promise<Record<string, unknown>> {
  if (job.scopeType !== "match") {
    throw new LiveRuntimeError({
      code: "LIVE_RUNTIME_INVALID_JOB_PAYLOAD",
      message: "refresh_round requires match scope",
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
      message: "refresh_round scopeId and payload.match_id must match",
      details: {
        jobId: job.jobId,
        scopeId: job.scopeId,
        matchId,
      },
    });
  }

  const receiptId = getRequiredString(job.payload, "receipt_id");
  const leagueRoundIds = getRequiredStringArray(
    job.payload,
    "league_round_ids",
  );
  const fantagolRoundId = getOptionalString(
    job.payload,
    "fantagol_round_id",
  );
  const changeType = getRequiredString(job.payload, "change_type");
  const changedFields = getRequiredStringArray(
    job.payload,
    "changed_fields",
  );
  const normalizedUpdate = getRequiredObject(
    job.payload,
    "normalized_update",
  );

  const rows = await callRuntimeRpc<RefreshLiveMatchRpcRow>(
    client,
    "refresh_live_match_state_rpc",
    {
      p_match_id: matchId,
      p_normalized_update: normalizedUpdate,
    },
  );

  const refreshed = requireSingleRpcRow(
    rows,
    "refresh_live_match_state_rpc",
  );

  const rebuildJobs = refreshed.applied
    ? await enqueueLeagueRoundRebuildJobs({
        client,
        leagueRoundIds,
        receiptId,
        matchId,
        fantagolRoundId,
        changeType,
        changedFields,
        correlationId: job.correlationId,
        causationId: job.jobId,
      })
    : [];

  return {
    match_id: refreshed.match_id,
    receipt_id: receiptId,
    applied: refreshed.applied,
    stale: refreshed.stale,
    previous_version: refreshed.previous_version,
    current_version: refreshed.current_version,
    provider_updated_at: refreshed.provider_updated_at,
    status: refreshed.match_status,
    home_score: refreshed.home_score,
    away_score: refreshed.away_score,
    minute: refreshed.minute,
    period: refreshed.period,
    rebuild_job_count: rebuildJobs.length,
    rebuild_job_ids: rebuildJobs.map((rebuildJob) => rebuildJob.jobId),
  };
}
