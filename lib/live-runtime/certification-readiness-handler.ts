import type { SupabaseClient } from "@supabase/supabase-js";

import { LiveRuntimeError } from "./errors";
import {
  enqueueLiveRuntimeJob,
  type ClaimedLiveRuntimeJob,
} from "./job-service";
import { launchMatchResultCertificationWorkflow } from "./match-result-certification-workflow";
import { freezeOfficialMatchOddsSnapshot } from "./odds-snapshot-service";
import {
  callRuntimeRpc,
  requireSingleRpcRow,
} from "./rpc-utils";

type HandleCertificationReadinessJobInput = {
  client: SupabaseClient;
  job: ClaimedLiveRuntimeJob;
};

type MatchCertificationReadinessRpcRow = {
  match_id: string;
  certification_state: string;
  source_match_version: number;
  is_ready: boolean;
  stable_since: string | null;
  ready_at: string | null;
  blocking_code: string | null;
  active_certification_id: string | null;
  details: Record<string, unknown>;
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
        `evaluate_certification_readiness requires payload.${key} to be a non-negative integer`,
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
        `evaluate_certification_readiness requires payload.${key} to be boolean`,
      details: { key, value },
    });
  }

  return value;
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

function requireValidScheduledAt(value: string, field: string): string {
  const parsed = new Date(value);

  if (Number.isNaN(parsed.getTime())) {
    throw new LiveRuntimeError({
      code: "LIVE_RUNTIME_INVALID_RPC_RESPONSE",
      message: `Match certification RPC returned invalid ${field}`,
      details: { field, value },
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
  const oddsPolicyVersion = getOptionalString(
    job.payload,
    "policy_version",
    "official_match_odds_v1",
  );
  const stabilityWindowSeconds = getOptionalInteger(
    job.payload,
    "stability_window_seconds",
    300,
  );
  const requireOfficialOdds = getOptionalBoolean(
    job.payload,
    "require_official_odds",
    true,
  );
  const certificationEngineVersion = getOptionalString(
    job.payload,
    "certification_engine_version",
    "match-result-certification-v1",
  );
  const certificationPolicyVersion = getOptionalString(
    job.payload,
    "certification_policy_version",
    "match-result-certification-policy-v1",
  );

  const frozen = await freezeOfficialMatchOddsSnapshot(client, {
    matchId,
    freezeAt,
    freezeReason,
    policyVersion: oddsPolicyVersion,
  });

  const functionName = "evaluate_match_certification_readiness_rpc";
  const rows = await callRuntimeRpc<MatchCertificationReadinessRpcRow>(
    client,
    functionName,
    {
      p_match_id: matchId,
      p_stability_window_seconds: stabilityWindowSeconds,
      p_require_official_odds: requireOfficialOdds,
      p_correlation_id: job.correlationId,
    },
  );
  const readiness = requireSingleRpcRow(rows, functionName);

  let followUpJob = null;
  let followUpWorkflow = null;

  if (readiness.is_ready) {
    followUpWorkflow = await launchMatchResultCertificationWorkflow({
      client,
      matchId,
      sourceMatchVersion: readiness.source_match_version,
      stabilityWindowSeconds,
      requireOfficialOdds,
      engineVersion: certificationEngineVersion,
      policyVersion: certificationPolicyVersion,
      certifiedBy: "live-runtime",
      correlationId: job.correlationId,
      causationId: job.jobId,
      triggerJobId: job.jobId,
    });
  } else if (
    readiness.certification_state === "stabilizing" &&
    readiness.ready_at
  ) {
    const scheduledAt = requireValidScheduledAt(
      readiness.ready_at,
      "ready_at",
    );

    followUpJob = await enqueueLiveRuntimeJob(client, {
      jobType: "evaluate_certification_readiness",
      scopeType: "match",
      scopeId: matchId,
      idempotencyKey: [
        "live",
        "evaluate-certification-readiness",
        matchId,
        readiness.source_match_version,
        scheduledAt,
      ].join(":"),
      priority: 20,
      scheduledAt,
      payload: {
        ...job.payload,
        match_id: matchId,
        freeze_at: freezeAt,
        freeze_reason: freezeReason,
        policy_version: oddsPolicyVersion,
        stability_window_seconds: stabilityWindowSeconds,
        require_official_odds: requireOfficialOdds,
        certification_engine_version: certificationEngineVersion,
        certification_policy_version: certificationPolicyVersion,
      },
      correlationId: job.correlationId,
      causationId: job.jobId,
    });
  }

  return {
    match_id: readiness.match_id,
    certification_readiness_evaluated: true,
    certification_state: readiness.certification_state,
    source_match_version: readiness.source_match_version,
    is_ready: readiness.is_ready,
    stable_since: readiness.stable_since,
    ready_at: readiness.ready_at,
    blocking_code: readiness.blocking_code,
    active_certification_id: readiness.active_certification_id,
    readiness_details: readiness.details,
    official_odds_ready: true,
    official_match_odds_snapshot_id:
      frozen.officialMatchOddsSnapshotId,
    odds_market_snapshot_id: frozen.oddsMarketSnapshotId,
    source_collected_at: frozen.sourceCollectedAt,
    official_hash: frozen.officialHash,
    already_frozen: frozen.alreadyFrozen,
    freeze_at: freezeAt,
    freeze_reason: freezeReason,
    odds_policy_version: oddsPolicyVersion,
    stability_window_seconds: stabilityWindowSeconds,
    require_official_odds: requireOfficialOdds,
    follow_up_workflow_id:
      followUpWorkflow?.workflowId ?? null,
    follow_up_workflow_inserted:
      followUpWorkflow?.workflowInserted ?? false,
    follow_up_job_id:
      followUpWorkflow?.jobId ?? followUpJob?.jobId ?? null,
    follow_up_job_type: readiness.is_ready
      ? "certify_match_result"
      : followUpJob
        ? "evaluate_certification_readiness"
        : null,
    follow_up_job_inserted:
      followUpWorkflow?.jobInserted ?? followUpJob?.inserted ?? false,
    follow_up_scheduled_at: followUpJob?.scheduledAt ?? null,
  };
}
