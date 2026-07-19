import type { SupabaseClient } from "@supabase/supabase-js";

import type { LiveRuntimeJobStatus } from "./job-service";
import { buildSingleStepWorkflowDefinition } from "./workflow-factory";
import { launchLiveRuntimeWorkflow } from "./workflow-launcher";
import { getLiveRuntimeWorkflowStatus } from "./workflow-service";

const WORKFLOW_TYPE = "match_result_certification";
const WORKFLOW_VERSION = 1;
const STEP_KEY = "certify_match_result";

export type LaunchMatchResultCertificationWorkflowInput = {
  client: SupabaseClient;
  matchId: string;
  sourceMatchVersion: number;
  stabilityWindowSeconds: number;
  requireOfficialOdds: boolean;
  engineVersion: string;
  policyVersion: string;
  certifiedBy?: string;
  correlationId?: string | null;
  causationId?: string | null;
  triggerJobId?: string | null;
};

export type LaunchedMatchResultCertificationWorkflow = {
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
  sourceMatchVersion: number;
}): string {
  return [
    "workflow",
    WORKFLOW_TYPE,
    input.matchId,
    input.sourceMatchVersion,
  ].join(":");
}

export async function launchMatchResultCertificationWorkflow(
  input: LaunchMatchResultCertificationWorkflowInput,
): Promise<LaunchedMatchResultCertificationWorkflow> {
  const definition = buildSingleStepWorkflowDefinition({
    workflowType: WORKFLOW_TYPE,
    workflowVersion: WORKFLOW_VERSION,
    scopeType: "match",
    scopeId: input.matchId,
    idempotencyKey: buildWorkflowIdempotencyKey({
      matchId: input.matchId,
      sourceMatchVersion: input.sourceMatchVersion,
    }),
    metadata: {
      source: "evaluate_certification_readiness",
      match_id: input.matchId,
      source_match_version: input.sourceMatchVersion,
      stability_window_seconds: input.stabilityWindowSeconds,
      require_official_odds: input.requireOfficialOdds,
      engine_version: input.engineVersion,
      policy_version: input.policyVersion,
    },
    correlationId: input.correlationId ?? null,
    causationId: input.causationId ?? null,
    triggerJobId: input.triggerJobId ?? null,
    step: {
      stepKey: STEP_KEY,
      jobType: "certify_match_result",
      scopeType: "match",
      scopeId: input.matchId,
      priority: 10,
      payload: {
        match_id: input.matchId,
        source_match_version: input.sourceMatchVersion,
        stability_window_seconds: input.stabilityWindowSeconds,
        require_official_odds: input.requireOfficialOdds,
        engine_version: input.engineVersion,
        policy_version: input.policyVersion,
        certified_by: input.certifiedBy ?? "live-runtime",
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
