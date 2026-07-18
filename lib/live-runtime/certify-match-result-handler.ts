import type { SupabaseClient } from "@supabase/supabase-js";

import { LiveRuntimeError } from "./errors";
import type { ClaimedLiveRuntimeJob } from "./job-service";
import {
  callRuntimeRpc,
  requireSingleRpcRow,
} from "./rpc-utils";

type HandleCertifyMatchResultJobInput = {
  client: SupabaseClient;
  job: ClaimedLiveRuntimeJob;
};

type CertifyMatchResultRpcRow = {
  certification_id: string;
  match_id: string;
  certification_version: number;
  certification_status: string;
  certification_hash: string;
  source_match_version: number;
  created: boolean;
  superseded_certification_id: string | null;
};

function getRequiredString(
  payload: Record<string, unknown>,
  key: string,
): string {
  const value = payload[key];

  if (typeof value !== "string" || value.trim() === "") {
    throw new LiveRuntimeError({
      code: "LIVE_RUNTIME_INVALID_JOB_PAYLOAD",
      message: `certify_match_result requires non-empty payload.${key}`,
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
        `certify_match_result requires payload.${key} to be a non-empty string when present`,
      details: { key, value },
    });
  }

  return value.trim();
}

function getOptionalInteger(
  payload: Record<string, unknown>,
  key: string,
  fallback: number,
): number {
  const value = payload[key];

  if (value === undefined || value === null) {
    return fallback;
  }

  if (!Number.isInteger(value) || (value as number) < 0) {
    throw new LiveRuntimeError({
      code: "LIVE_RUNTIME_INVALID_JOB_PAYLOAD",
      message:
        `certify_match_result requires payload.${key} to be a non-negative integer`,
      details: { key, value },
    });
  }

  return value as number;
}

function getOptionalBoolean(
  payload: Record<string, unknown>,
  key: string,
  fallback: boolean,
): boolean {
  const value = payload[key];

  if (value === undefined || value === null) {
    return fallback;
  }

  if (typeof value !== "boolean") {
    throw new LiveRuntimeError({
      code: "LIVE_RUNTIME_INVALID_JOB_PAYLOAD",
      message:
        `certify_match_result requires payload.${key} to be boolean`,
      details: { key, value },
    });
  }

  return value;
}

export async function handleCertifyMatchResultJob({
  client,
  job,
}: HandleCertifyMatchResultJobInput): Promise<
  Record<string, unknown>
> {
  if (job.scopeType !== "match") {
    throw new LiveRuntimeError({
      code: "LIVE_RUNTIME_INVALID_JOB_PAYLOAD",
      message: "certify_match_result requires match scope",
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
        "certify_match_result scopeId and payload.match_id must match",
      details: {
        jobId: job.jobId,
        scopeId: job.scopeId,
        matchId,
      },
    });
  }

  const functionName = "certify_match_result_rpc";
  const rows = await callRuntimeRpc<CertifyMatchResultRpcRow>(
    client,
    functionName,
    {
      p_match_id: matchId,
      p_stability_window_seconds: getOptionalInteger(
        job.payload,
        "stability_window_seconds",
        300,
      ),
      p_require_official_odds: getOptionalBoolean(
        job.payload,
        "require_official_odds",
        true,
      ),
      p_engine_version: getOptionalString(
        job.payload,
        "engine_version",
        "match-result-certification-v1",
      ),
      p_policy_version: getOptionalString(
        job.payload,
        "policy_version",
        "match-result-certification-policy-v1",
      ),
      p_certified_by: getOptionalString(
        job.payload,
        "certified_by",
        "live-runtime",
      ),
      p_correlation_id: job.correlationId,
    },
  );

  const certification = requireSingleRpcRow(rows, functionName);

  return {
    certification_id: certification.certification_id,
    match_id: certification.match_id,
    certification_version: certification.certification_version,
    certification_status: certification.certification_status,
    certification_hash: certification.certification_hash,
    source_match_version: certification.source_match_version,
    created: certification.created,
    superseded_certification_id:
      certification.superseded_certification_id,
  };
}
