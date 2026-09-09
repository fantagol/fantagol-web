import type { SupabaseClient } from "@supabase/supabase-js";

import { LiveRuntimeError } from "./errors";
import type { ClaimedLiveRuntimeJob } from "./job-service";
import { enqueueLiveRuntimeJob } from "./job-service";
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

type FantagolRoundBindingRow = {
  fantagol_round_id: string;
};

async function loadFantagolRoundIdsForMatch(
  client: SupabaseClient,
  matchId: string,
): Promise<string[]> {
  const { data, error } = await client
    .from("fantagol_round_matches")
    .select("fantagol_round_id")
    .eq("match_id", matchId)
    .is("removed_at", null);

  if (error) {
    throw new LiveRuntimeError({
      code: "LIVE_RUNTIME_INVALID_JOB_PAYLOAD",
      message:
        "certify_match_result could not resolve canonical fantagol round bindings",
      details: {
        reason: "MATCH_ROUND_BINDING_QUERY_FAILED",
        matchId,
        postgresCode: error.code ?? null,
      },
      cause: error,
    });
  }

  const fantagolRoundIds = Array.from(
    new Set(
      ((data ?? []) as FantagolRoundBindingRow[])
        .map((row) => row.fantagol_round_id)
        .filter((value) => typeof value === "string" && value.trim() !== ""),
    ),
  );

  if (fantagolRoundIds.length === 0) {
    throw new LiveRuntimeError({
      code: "LIVE_RUNTIME_INVALID_JOB_PAYLOAD",
      message:
        "certify_match_result requires at least one canonical fantagol round binding",
      details: {
        reason: "MATCH_ROUND_BINDING_NOT_FOUND",
        matchId,
      },
    });
  }

  return fantagolRoundIds;
}
type FinalCalculableLeagueRoundRow = {
  id: string;
  version: number;
};

async function enqueueMatchCertificationConvergenceRebuildJobs(input: {
  client: SupabaseClient;
  fantagolRoundId: string;
  matchId: string;
  certificationId: string;
  certificationVersion: number;
  correlationId: string | null;
  causationId: string | null;
}) {
  const { data, error } = await input.client
    .from("league_rounds")
    .select("id,version")
    .eq("fantagol_round_id", input.fantagolRoundId)
    .eq("enabled", true)
    .eq("status", "final_calculable");

  if (error) {
    throw new LiveRuntimeError({
      code: "LIVE_RUNTIME_INVALID_JOB_PAYLOAD",
      message:
        "certify_match_result could not resolve final-calculable convergence targets",
      details: {
        reason: "MATCH_CERTIFICATION_CONVERGENCE_TARGET_QUERY_FAILED",
        matchId: input.matchId,
        fantagolRoundId: input.fantagolRoundId,
        certificationId: input.certificationId,
        postgresCode: error.code ?? null,
      },
      cause: error,
    });
  }

  const jobs = [];

  for (const leagueRound of (data ?? []) as FinalCalculableLeagueRoundRow[]) {
    const rebuildJob = await enqueueLiveRuntimeJob(input.client, {
      jobType: "rebuild_league_round",
      scopeType: "league_round",
      scopeId: leagueRound.id,
      idempotencyKey: [
        "live",
        "match-certification-convergence",
        leagueRound.id,
        input.certificationId,
      ].join(":"),
      priority: 30,
      payload: {
        fantagol_round_id: input.fantagolRoundId,
        league_round_id: leagueRound.id,
        league_round_version: leagueRound.version,
        match_id: input.matchId,
        certification_id: input.certificationId,
        certification_version: input.certificationVersion,
        lifecycle_reason: "match_certification_convergence",
        publication_channel: "realtime",
        round_certification_reason:
          "automatic official round certification",
        change_type: "MATCH_CERTIFICATION_CONVERGENCE",
        changed_fields: ["match_certifications"],
      },
      correlationId: input.correlationId,
      causationId: input.causationId,
    });

    jobs.push(rebuildJob);
  }

  return jobs;
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

  /*
   * MATCH_FINISHED can rebuild a round while the official-result stability
   * window is still open, leaving the terminal match provisional in runtime.
   * Once the match result is official, re-converge each final_calculable league
   * round bound to its canonical Fantagol round. The existing rebuild path then
   * re-materializes certified runtime rows and resumes round certification.
   *
   * This intentionally runs for every official RPC result, not only when
   * created=true. If certification commits but enqueueing fails, a retry sees
   * created=false; convergence is idempotent by league round + certification
   * identity and can safely complete the handoff.
   */
  const fantagolRoundIds =
    certification.certification_status === "official"
      ? await loadFantagolRoundIdsForMatch(client, matchId)
      : [];

  const convergenceRebuildJobs = (
    await Promise.all(
      fantagolRoundIds.map((fantagolRoundId) =>
        enqueueMatchCertificationConvergenceRebuildJobs({
          client,
          fantagolRoundId,
          matchId,
          certificationId: certification.certification_id,
          certificationVersion: certification.certification_version,
          correlationId: job.correlationId,
          causationId: job.jobId,
        }),
      ),
    )
  ).flat();

  return {
    certification_id: certification.certification_id,
    match_id: certification.match_id,
    certification_version: certification.certification_version,
    certification_status: certification.certification_status,
    certification_hash: certification.certification_hash,
    source_match_version: certification.source_match_version,
    created: certification.created,
    convergence_fantagol_round_ids: fantagolRoundIds,
    convergence_rebuild_job_count: convergenceRebuildJobs.length,
    superseded_certification_id:
      certification.superseded_certification_id,
  };
}
