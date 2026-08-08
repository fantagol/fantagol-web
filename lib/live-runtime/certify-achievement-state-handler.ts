import type { SupabaseClient } from "@supabase/supabase-js";

import { LiveRuntimeError } from "./errors";
import type { ClaimedLiveRuntimeJob } from "./job-service";
import {
  callRuntimeRpc,
  requireSingleRpcRow,
} from "./rpc-utils";

type HandleCertifyAchievementStateJobInput = {
  client: SupabaseClient;
  job: ClaimedLiveRuntimeJob;
};

type CertifyAchievementStateRpcRow = {
  result: Record<string, unknown>;
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
        `certify_achievement_state requires non-empty payload.${key}`,
      details: {
        key,
        value,
      },
    });
  }

  return value.trim();
}

export async function handleCertifyAchievementStateJob({
  client,
  job,
}: HandleCertifyAchievementStateJobInput): Promise<
  Record<string, unknown>
> {
  if (
    job.scopeType !== "league" &&
    job.scopeType !== "league_member"
  ) {
    throw new LiveRuntimeError({
      code: "LIVE_RUNTIME_INVALID_JOB_PAYLOAD",
      message:
        "certify_achievement_state requires league or league_member scope",
      details: {
        jobId: job.jobId,
        scopeType: job.scopeType,
      },
    });
  }

  const workflowType =
    getRequiredString(job.payload, "workflow_type");

  const workflowStepKey =
    getRequiredString(
      job.payload,
      "workflow_step_key",
    );

  const functionName =
    "certify_achievement_state_rpc";

  const rows =
    await callRuntimeRpc<CertifyAchievementStateRpcRow>(
      client,
      functionName,
      {
        p_workflow_type: workflowType,
        p_workflow_step_key: workflowStepKey,
        p_scope_type: job.scopeType,
        p_scope_id: job.scopeId,
        p_payload: job.payload,
        p_correlation_id: job.correlationId,
        p_causation_id: job.jobId,
      },
    );

  const row =
    requireSingleRpcRow(rows, functionName);

  if (
    !row.result ||
    typeof row.result !== "object" ||
    Array.isArray(row.result)
  ) {
    throw new LiveRuntimeError({
      code: "LIVE_RUNTIME_INVALID_RPC_RESPONSE",
      message:
        "certify_achievement_state returned invalid result",
      details: {
        functionName,
        result: row.result,
      },
    });
  }

  return row.result;
}