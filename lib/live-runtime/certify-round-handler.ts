import type { SupabaseClient } from "@supabase/supabase-js";

import { LiveRuntimeError } from "./errors";
import {
  enqueueLiveRuntimeJob,
  type ClaimedLiveRuntimeJob,
} from "./job-service";
import {
  callRuntimeRpc,
  requireSingleRpcRow,
} from "./rpc-utils";

type HandleCertifyRoundJobInput = {
  client: SupabaseClient;
  job: ClaimedLiveRuntimeJob;
};

type CertifyRoundRpcRow = {
  certification_id: string;
  league_round_id: string;
  certification_version: number;
  certification_status: string;
  calculation_run_id: string;
  ui_simulation_id: string;
  certification_hash: string;
  ledger_version: number;
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
      message:
        `certify_round requires non-empty payload.${key}`,
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
        `certify_round requires payload.${key} to be a non-empty string when present`,
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
        `certify_round requires payload.${key} to be a non-empty string when present`,
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
        `certify_round requires payload.${key} to be an object when present`,
      details: { key, value },
    });
  }

  return value as Record<string, unknown>;
}

export async function handleCertifyRoundJob({
  client,
  job,
}: HandleCertifyRoundJobInput): Promise<
  Record<string, unknown>
> {
  if (job.scopeType !== "league_round") {
    throw new LiveRuntimeError({
      code: "LIVE_RUNTIME_INVALID_JOB_PAYLOAD",
      message: "certify_round requires league_round scope",
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
  const liveStateSnapshotId = getRequiredString(
    job.payload,
    "live_state_snapshot_id",
  );

  if (leagueRoundId !== job.scopeId) {
    throw new LiveRuntimeError({
      code: "LIVE_RUNTIME_INVALID_JOB_PAYLOAD",
      message:
        "certify_round scopeId and payload.league_round_id must match",
      details: {
        jobId: job.jobId,
        scopeId: job.scopeId,
        leagueRoundId,
      },
    });
  }

  const functionName = "certify_round_rpc";

  const rows = await callRuntimeRpc<CertifyRoundRpcRow>(
    client,
    functionName,
    {
      p_league_round_id: leagueRoundId,
      p_calculation_run_id: calculationRunId,
      p_ui_simulation_id: uiSimulationId,
      p_engine_version: getOptionalString(
        job.payload,
        "engine_version",
        "round-certification-v1",
      ),
      p_reason: getOptionalString(
        job.payload,
        "reason",
        "automatic official round certification",
      ),
      p_committed_by_member_id:
        getOptionalNullableString(
          job.payload,
          "committed_by_member_id",
        ),
      p_correlation_id: job.correlationId,
    },
  );

  const certification =
    requireSingleRpcRow(rows, functionName);

  const publicationChannel = getOptionalString(
    job.payload,
    "publication_channel",
    "realtime",
  );

  const publicationJob =
    await enqueueLiveRuntimeJob(client, {
      jobType: "publish_snapshot",
      scopeType: "live_state_snapshot",
      scopeId: liveStateSnapshotId,
      idempotencyKey: [
        "live",
        "publish-certified-snapshot",
        liveStateSnapshotId,
        publicationChannel,
        certification.certification_id,
      ].join(":"),
      priority: 40,
      payload: {
        live_state_snapshot_id:
          liveStateSnapshotId,
        channel: publicationChannel,
        metadata: {
          ...getOptionalObject(
            job.payload,
            "publication_metadata",
          ),
          source_job_id: job.jobId,
          league_round_id:
            certification.league_round_id,
          calculation_run_id:
            certification.calculation_run_id,
          ui_simulation_id:
            certification.ui_simulation_id,
          certification_id:
            certification.certification_id,
          certification_version:
            certification.certification_version,
          certification_hash:
            certification.certification_hash,
          ledger_version:
            certification.ledger_version,
        },
      },
      correlationId: job.correlationId,
      causationId: job.jobId,
    });

  return {
    certification_id:
      certification.certification_id,
    league_round_id:
      certification.league_round_id,
    certification_version:
      certification.certification_version,
    certification_status:
      certification.certification_status,
    calculation_run_id:
      certification.calculation_run_id,
    ui_simulation_id:
      certification.ui_simulation_id,
    certification_hash:
      certification.certification_hash,
    ledger_version:
      certification.ledger_version,
    created: certification.created,
    superseded_certification_id:
      certification.superseded_certification_id,
    live_state_snapshot_id:
      liveStateSnapshotId,
    publication_job_id:
      publicationJob.jobId,
    publication_job_inserted:
      publicationJob.inserted,
  };
}
