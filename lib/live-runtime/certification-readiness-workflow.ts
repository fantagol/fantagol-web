import type { SupabaseClient } from "@supabase/supabase-js";

import { buildSingleStepWorkflowDefinition } from "./workflow-factory";
import { launchLiveRuntimeWorkflow } from "./workflow-launcher";
import { getLiveRuntimeWorkflowStatus } from "./workflow-service";
import type { LiveRuntimeJobStatus } from "./job-service";

const WORKFLOW_TYPE = "match_certification_readiness";
const WORKFLOW_VERSION = 1;
const STEP_KEY = "evaluate_certification_readiness";

export type LaunchCertificationReadinessWorkflowInput = {
  client: SupabaseClient;
  matchId: string;
  receiptId: string;
  freezeAt: string;
  matchStatus: string;
  matchStateVersion: number;
  correlationId?: string | null;
  causationId?: string | null;
  triggerJobId?: string | null;
};

export type LaunchedCertificationReadinessWorkflow = {
  workflowId: string;
  workflowInserted: boolean;
  workflowStatus: string;
  workflowStepKey: string;
  jobId: string | null;
  jobInserted: boolean;
  jobStatus: LiveRuntimeJobStatus | null;
};

function buildWorkflowIdempotencyKey(input: {
  matchId: string;
  receiptId: string;
}): string {
  return [
    "workflow",
    WORKFLOW_TYPE,
    input.matchId,
    input.receiptId,
  ].join(":");
}

/**
 * Launches the first workflow-backed segment of the live runtime.
 *
 * The workflow is intentionally created only after refresh_round has produced
 * the definitive provider timestamp, match status and match-state version.
 * Migration 062 stores static step payloads and does not inject one step's
 * result into another step's payload.
 */
export async function launchCertificationReadinessWorkflow(
  input: LaunchCertificationReadinessWorkflowInput,
): Promise<LaunchedCertificationReadinessWorkflow> {
  const definition = buildSingleStepWorkflowDefinition({
    workflowType: WORKFLOW_TYPE,
    workflowVersion: WORKFLOW_VERSION,
    scopeType: "match",
    scopeId: input.matchId,
    idempotencyKey: buildWorkflowIdempotencyKey({
      matchId: input.matchId,
      receiptId: input.receiptId,
    }),
    metadata: {
      source: "refresh_round",
      receipt_id: input.receiptId,
      match_status: input.matchStatus,
      match_state_version: input.matchStateVersion,
    },
    correlationId: input.correlationId ?? null,
    causationId: input.causationId ?? null,
    triggerJobId: input.triggerJobId ?? null,
    step: {
      stepKey: STEP_KEY,
      jobType: "evaluate_certification_readiness",
      scopeType: "match",
      scopeId: input.matchId,
      priority: 20,
      payload: {
        match_id: input.matchId,
        receipt_id: input.receiptId,
        freeze_at: input.freezeAt,
        freeze_reason: "first_certification_eligible_live_state",
        policy_version: "official_match_odds_v1",
        match_status: input.matchStatus,
        match_state_version: input.matchStateVersion,
      },
    },
  });

  const launched = await launchLiveRuntimeWorkflow(input.client, definition, {
    enqueueLimit: 1,
  });
  const newlyEnqueued = launched.enqueuedSteps.find(
    (step) => step.stepKey === STEP_KEY,
  );

  if (newlyEnqueued) {
    return {
      workflowId: launched.workflow.workflowId,
      workflowInserted: launched.workflow.inserted,
      workflowStatus: launched.workflow.workflowStatus,
      workflowStepKey: newlyEnqueued.stepKey,
      jobId: newlyEnqueued.jobId,
      jobInserted: newlyEnqueued.inserted,
      jobStatus: newlyEnqueued.jobStatus,
    };
  }

  // Idempotent relaunch: the workflow/step may already exist and therefore no
  // new ready step is returned. Resolve the previously linked job explicitly.
  const snapshot = await getLiveRuntimeWorkflowStatus(
    input.client,
    launched.workflow.workflowId,
  );
  const existingStep = snapshot?.steps.find(
    (step) => step.stepKey === STEP_KEY,
  );

  return {
    workflowId: launched.workflow.workflowId,
    workflowInserted: launched.workflow.inserted,
    workflowStatus:
      snapshot?.workflowStatus ?? launched.workflow.workflowStatus,
    workflowStepKey: STEP_KEY,
    jobId: existingStep?.jobId ?? null,
    jobInserted: false,
    jobStatus: null,
  };
}
