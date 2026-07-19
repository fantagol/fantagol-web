import type { SupabaseClient } from "@supabase/supabase-js";

import type { LiveRuntimeJobStatus } from "./job-service";
import { buildSingleStepWorkflowDefinition } from "./workflow-factory";
import { launchLiveRuntimeWorkflow } from "./workflow-launcher";
import { getLiveRuntimeWorkflowStatus } from "./workflow-service";

const WORKFLOW_TYPE = "certified_snapshot_publication";
const WORKFLOW_VERSION = 1;
const STEP_KEY = "publish_snapshot";

export type LaunchCertifiedSnapshotPublicationWorkflowInput = {
  client: SupabaseClient;
  liveStateSnapshotId: string;
  publicationChannel: string;
  certificationId: string;
  leagueRoundId: string;
  calculationRunId: string;
  uiSimulationId: string;
  certificationVersion: number;
  certificationHash: string;
  ledgerVersion: number;
  publicationMetadata?: Record<string, unknown>;
  correlationId?: string | null;
  causationId?: string | null;
  triggerJobId?: string | null;
};

export type LaunchedCertifiedSnapshotPublicationWorkflow = {
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
    LaunchCertifiedSnapshotPublicationWorkflowInput,
    "liveStateSnapshotId" | "publicationChannel" | "certificationId"
  >,
): string {
  return [
    "workflow",
    WORKFLOW_TYPE,
    input.liveStateSnapshotId,
    input.publicationChannel,
    input.certificationId,
  ].join(":");
}

export async function launchCertifiedSnapshotPublicationWorkflow(
  input: LaunchCertifiedSnapshotPublicationWorkflowInput,
): Promise<LaunchedCertifiedSnapshotPublicationWorkflow> {
  const definition = buildSingleStepWorkflowDefinition({
    workflowType: WORKFLOW_TYPE,
    workflowVersion: WORKFLOW_VERSION,
    scopeType: "live_state_snapshot",
    scopeId: input.liveStateSnapshotId,
    idempotencyKey: buildWorkflowIdempotencyKey(input),
    metadata: {
      source: "certify_round",
      certification_id: input.certificationId,
      league_round_id: input.leagueRoundId,
      calculation_run_id: input.calculationRunId,
      ui_simulation_id: input.uiSimulationId,
      certification_version: input.certificationVersion,
      certification_hash: input.certificationHash,
      ledger_version: input.ledgerVersion,
      publication_channel: input.publicationChannel,
    },
    correlationId: input.correlationId ?? null,
    causationId: input.causationId ?? null,
    triggerJobId: input.triggerJobId ?? null,
    step: {
      stepKey: STEP_KEY,
      jobType: "publish_snapshot",
      scopeType: "live_state_snapshot",
      scopeId: input.liveStateSnapshotId,
      priority: 40,
      payload: {
        live_state_snapshot_id: input.liveStateSnapshotId,
        channel: input.publicationChannel,
        metadata: {
          ...input.publicationMetadata,
          source_job_id: input.triggerJobId ?? null,
          league_round_id: input.leagueRoundId,
          calculation_run_id: input.calculationRunId,
          ui_simulation_id: input.uiSimulationId,
          certification_id: input.certificationId,
          certification_version: input.certificationVersion,
          certification_hash: input.certificationHash,
          ledger_version: input.ledgerVersion,
        },
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
