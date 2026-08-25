import type { SupabaseClient } from "@supabase/supabase-js";

import type { ClaimedLiveRuntimeJob } from "./job-service";
import {
  reconcileAndEnqueueLiveRuntimeWorkflow,
} from "./workflow-launcher";
import {
  callRuntimeRpc,
  requireSingleRpcRow,
} from "./rpc-utils";

type TerminalMaterializationRpcRow = {
  result?: Record<string, unknown>;
};

function readPayloadString(
  payload: Record<string, unknown>,
  key: string,
): string | null {
  const value = payload[key];

  return typeof value === "string" &&
    value.trim().length > 0
    ? value.trim()
    : null;
}

export type TerminalGameObjectiveHookResult = {
  workflowId: string | null;
  workflowType: string | null;
  workflowStepKey: string | null;
  reconciled: boolean;
  workflowStatus: string | null;
  terminalMaterialization:
    | Record<string, unknown>
    | null;
};

export async function handleTerminalGameObjectiveHook(
  client: SupabaseClient,
  job: ClaimedLiveRuntimeJob,
): Promise<TerminalGameObjectiveHookResult> {
  const workflowId =
    readPayloadString(
      job.payload,
      "workflow_id",
    );

  const workflowType =
    readPayloadString(
      job.payload,
      "workflow_type",
    );

  const workflowStepKey =
    readPayloadString(
      job.payload,
      "workflow_step_key",
    );

  if (!workflowId) {
    return {
      workflowId: null,
      workflowType,
      workflowStepKey,
      reconciled: false,
      workflowStatus: null,
      terminalMaterialization: null,
    };
  }

  const {
    reconciliation,
  } =
    await reconcileAndEnqueueLiveRuntimeWorkflow(
      client,
      workflowId,
    );

  if (
    reconciliation.workflowStatus !==
      "completed" ||
    workflowType !==
      "round_certification" ||
    workflowStepKey !==
      "certify_round"
  ) {
    return {
      workflowId,
      workflowType,
      workflowStepKey,
      reconciled: true,
      workflowStatus:
        reconciliation.workflowStatus,
      terminalMaterialization: null,
    };
  }

  const functionName =
    "materialize_round_terminal_game_objectives_internal";

  const rows =
    await callRuntimeRpc<TerminalMaterializationRpcRow>(
      client,
      functionName,
      {
        p_workflow_instance_id:
          workflowId,
      },
    );

  const row =
    requireSingleRpcRow(
      rows,
      functionName,
    );

  return {
    workflowId,
    workflowType,
    workflowStepKey,
    reconciled: true,
    workflowStatus:
      reconciliation.workflowStatus,
    terminalMaterialization:
      row.result ?? row,
  };
}