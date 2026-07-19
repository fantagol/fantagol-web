import type { SupabaseClient } from "@supabase/supabase-js";

import type { LiveRuntimeJobStatus } from "./job-service";
import { buildSingleStepWorkflowDefinition } from "./workflow-factory";
import { launchLiveRuntimeWorkflow } from "./workflow-launcher";
import { getLiveRuntimeWorkflowStatus } from "./workflow-service";

const WORKFLOW_TYPE = "round_certification";
const WORKFLOW_VERSION = 1;
const STEP_KEY = "certify_round";

export type LaunchRoundCertificationWorkflowInput = {
  client: SupabaseClient;
  leagueRoundId: string;
  calculationRunId: string;
  uiSimulationId: string;
  liveStateSnapshotId: string;
  publicationChannel: string;
  publicationMetadata?: Record<string, unknown>;
  engineVersion?: string;
  reason?: string;
  committedByMemberId?: string | null;
  correlationId?: string | null;
  causationId?: string | null;
  triggerJobId?: string | null;
};

export type LaunchedRoundCertificationWorkflow = {
  workflowId: string;
  workflowInserted: boolean;
  workflowStatus: string;
  workflowStepKey: string;
  jobId: string | null;
  jobInserted: boolean;
  jobStatus: LiveRuntimeJobStatus | null;
};

function buildWorkflowIdempotencyKey(
  input: Pick<
    LaunchRoundCertificationWorkflowInput,
    "leagueRoundId" | "calculationRunId" | "uiSimulationId"
  >,
): string {
  return [
    "workflow",
    WORKFLOW_TYPE,
    input.leagueRoundId,
    input.calculationRunId,
    input.uiSimulationId,
  ].join(":");
}

export async function launchRoundCertificationWorkflow(
  input: LaunchRoundCertificationWorkflowInput,
): Promise<LaunchedRoundCertificationWorkflow> {
  const definition = buildSingleStepWorkflowDefinition({
    workflowType: WORKFLOW_TYPE,
    workflowVersion: WORKFLOW_VERSION,
    scopeType: "league_round",
    scopeId: input.leagueRoundId,
    idempotencyKey: buildWorkflowIdempotencyKey(input),
    metadata: {
      source: "evaluate_round_certification_readiness",
      league_round_id: input.leagueRoundId,
      calculation_run_id: input.calculationRunId,
      ui_simulation_id: input.uiSimulationId,
      live_state_snapshot_id: input.liveStateSnapshotId,
    },
    correlationId: input.correlationId ?? null,
    causationId: input.causationId ?? null,
    triggerJobId: input.triggerJobId ?? null,
    step: {
      stepKey: STEP_KEY,
      jobType: "certify_round",
      scopeType: "league_round",
      scopeId: input.leagueRoundId,
      priority: 35,
      payload: {
        league_round_id: input.leagueRoundId,
        calculation_run_id: input.calculationRunId,
        ui_simulation_id: input.uiSimulationId,
        live_state_snapshot_id: input.liveStateSnapshotId,
        publication_channel: input.publicationChannel,
        publication_metadata: input.publicationMetadata ?? {},
        engine_version:
          input.engineVersion ?? "round-certification-v1",
        reason:
          input.reason ?? "automatic official round certification",
        committed_by_member_id: input.committedByMemberId ?? null,
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
