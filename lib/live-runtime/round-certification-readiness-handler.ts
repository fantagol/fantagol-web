import type { SupabaseClient } from "@supabase/supabase-js";

import { LiveRuntimeError } from "./errors";
import { launchRoundCertificationWorkflow } from "./round-certification-workflow";
import type { ClaimedLiveRuntimeJob } from "./job-service";
import {
  callRuntimeRpc,
  requireSingleRpcRow,
} from "./rpc-utils";

type HandleRoundCertificationReadinessJobInput = {
  client: SupabaseClient;
  job: ClaimedLiveRuntimeJob;
};

type RoundCertificationReadinessRpcRow = {
  league_round_id: string;
  round_status: string;
  source_round_version: number;
  match_set_version: number;
  required_match_count: number;
  included_match_count: number;
  excluded_match_count: number;
  certified_match_count: number;
  blocking_match_count: number;
  calculation_run_id: string;
  calculation_status: string;
  ui_simulation_id: string;
  ui_simulation_status: string;
  is_ready: boolean;
  blocking_code: string | null;
  blocking_details: Record<string, unknown>;
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
        `evaluate_round_certification_readiness requires non-empty payload.${key}`,
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
        `evaluate_round_certification_readiness requires payload.${key} to be a non-empty string when present`,
      details: { key, value },
    });
  }

  return value.trim();
}

function getOptionalNullableString(
  payload: Record<string, unknown>,
  key: string,
): string | null {
  const value = payload[key];

  if (value === undefined || value === null) {
    return null;
  }

  if (typeof value !== "string" || value.trim() === "") {
    throw new LiveRuntimeError({
      code: "LIVE_RUNTIME_INVALID_JOB_PAYLOAD",
      message:
        `evaluate_round_certification_readiness requires payload.${key} to be a non-empty string when present`,
      details: { key, value },
    });
  }

  return value.trim();
}

function getOptionalObject(
  payload: Record<string, unknown>,
  key: string,
): Record<string, unknown> {
  const value = payload[key];

  if (value === undefined || value === null) {
    return {};
  }

  if (typeof value !== "object" || Array.isArray(value)) {
    throw new LiveRuntimeError({
      code: "LIVE_RUNTIME_INVALID_JOB_PAYLOAD",
      message:
        `evaluate_round_certification_readiness requires payload.${key} to be an object when present`,
      details: { key, value },
    });
  }

  return value as Record<string, unknown>;
}

export async function handleRoundCertificationReadinessJob({
  client,
  job,
}: HandleRoundCertificationReadinessJobInput): Promise<
  Record<string, unknown>
> {
  if (job.scopeType !== "league_round") {
    throw new LiveRuntimeError({
      code: "LIVE_RUNTIME_INVALID_JOB_PAYLOAD",
      message:
        "evaluate_round_certification_readiness requires league_round scope",
      details: {
        jobId: job.jobId,
        scopeType: job.scopeType,
      },
    });
  }

  const leagueRoundId = getRequiredString(
    job.payload,
    "league_round_id",
  );
  const calculationRunId = getRequiredString(
    job.payload,
    "calculation_run_id",
  );
  const uiSimulationId = getRequiredString(
    job.payload,
    "ui_simulation_id",
  );

  if (leagueRoundId !== job.scopeId) {
    throw new LiveRuntimeError({
      code: "LIVE_RUNTIME_INVALID_JOB_PAYLOAD",
      message:
        "evaluate_round_certification_readiness scopeId and payload.league_round_id must match",
      details: {
        jobId: job.jobId,
        scopeId: job.scopeId,
        leagueRoundId,
      },
    });
  }

  const functionName =
    "evaluate_round_certification_readiness_rpc";

  const rows =
    await callRuntimeRpc<RoundCertificationReadinessRpcRow>(
      client,
      functionName,
      {
        p_league_round_id: leagueRoundId,
        p_calculation_run_id: calculationRunId,
        p_ui_simulation_id: uiSimulationId,
      },
    );

  const readiness = requireSingleRpcRow(rows, functionName);

  let followUpWorkflow = null;

  if (readiness.is_ready) {
    followUpWorkflow = await launchRoundCertificationWorkflow({
      client,
      leagueRoundId,
      calculationRunId,
      uiSimulationId,
      liveStateSnapshotId: getRequiredString(
        job.payload,
        "live_state_snapshot_id",
      ),
      publicationChannel: getOptionalString(
        job.payload,
        "publication_channel",
        "realtime",
      ),
      publicationMetadata: getOptionalObject(
        job.payload,
        "publication_metadata",
      ),
      engineVersion: getOptionalString(
        job.payload,
        "engine_version",
        "round-certification-v1",
      ),
      reason: getOptionalString(
        job.payload,
        "reason",
        "automatic official round certification",
      ),
      committedByMemberId: getOptionalNullableString(
        job.payload,
        "committed_by_member_id",
      ),
      correlationId: job.correlationId,
      causationId: job.jobId,
      triggerJobId: job.jobId,
    });
  }

  return {
    league_round_id: readiness.league_round_id,
    round_status: readiness.round_status,
    source_round_version:
      readiness.source_round_version,
    match_set_version: readiness.match_set_version,
    required_match_count:
      readiness.required_match_count,
    included_match_count:
      readiness.included_match_count,
    excluded_match_count:
      readiness.excluded_match_count,
    certified_match_count:
      readiness.certified_match_count,
    blocking_match_count:
      readiness.blocking_match_count,
    calculation_run_id:
      readiness.calculation_run_id,
    calculation_status:
      readiness.calculation_status,
    ui_simulation_id:
      readiness.ui_simulation_id,
    ui_simulation_status:
      readiness.ui_simulation_status,
    is_ready: readiness.is_ready,
    blocking_code: readiness.blocking_code,
    blocking_details:
      readiness.blocking_details,
    follow_up_workflow_id:
      followUpWorkflow?.workflowId ?? null,
    follow_up_workflow_inserted:
      followUpWorkflow?.workflowInserted ?? false,
    follow_up_job_id:
      followUpWorkflow?.jobId ?? null,
    follow_up_job_inserted:
      followUpWorkflow?.jobInserted ?? false,
  };
}
