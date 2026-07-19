import type { SupabaseClient } from "@supabase/supabase-js";

import type { LiveRuntimeWorkflowDefinition } from "./workflow-factory";
import {
  createLiveRuntimeWorkflow,
  enqueueReadyLiveRuntimeWorkflowSteps,
  reconcileLiveRuntimeWorkflow,
} from "./workflow-service";
import type {
  CreatedLiveRuntimeWorkflow,
  EnqueuedLiveRuntimeWorkflowStep,
  ReconciledLiveRuntimeWorkflow,
} from "./workflow-types";

export type LaunchLiveRuntimeWorkflowOptions = {
  enqueueLimit?: number;
};

export type LaunchedLiveRuntimeWorkflow = {
  workflow: CreatedLiveRuntimeWorkflow;
  enqueuedSteps: EnqueuedLiveRuntimeWorkflowStep[];
};

export type ReconciledAndEnqueuedLiveRuntimeWorkflow = {
  reconciliation: ReconciledLiveRuntimeWorkflow;
  enqueuedSteps: EnqueuedLiveRuntimeWorkflowStep[];
};

function normalizeEnqueueLimit(value: number | undefined): number {
  if (value === undefined) {
    return 25;
  }

  if (!Number.isInteger(value) || value < 1 || value > 100) {
    throw new RangeError("enqueueLimit must be an integer between 1 and 100");
  }

  return value;
}

/**
 * Creates an idempotent workflow aggregate and immediately enqueues all root
 * steps that are ready at launch time.
 */
export async function launchLiveRuntimeWorkflow(
  client: SupabaseClient,
  definition: LiveRuntimeWorkflowDefinition,
  options: LaunchLiveRuntimeWorkflowOptions = {},
): Promise<LaunchedLiveRuntimeWorkflow> {
  const workflow = await createLiveRuntimeWorkflow(client, definition);
  const enqueuedSteps = await enqueueReadyLiveRuntimeWorkflowSteps(
    client,
    workflow.workflowId,
    normalizeEnqueueLimit(options.enqueueLimit),
  );

  return {
    workflow,
    enqueuedSteps,
  };
}

/**
 * Synchronizes a workflow against its linked jobs and enqueues every step whose
 * dependencies have become satisfied. This is intentionally explicit: the
 * worker integration will decide when to invoke it in the next subphase.
 */
export async function reconcileAndEnqueueLiveRuntimeWorkflow(
  client: SupabaseClient,
  workflowId: string,
  options: LaunchLiveRuntimeWorkflowOptions = {},
): Promise<ReconciledAndEnqueuedLiveRuntimeWorkflow> {
  const reconciliation = await reconcileLiveRuntimeWorkflow(
    client,
    workflowId,
  );
  const enqueuedSteps = await enqueueReadyLiveRuntimeWorkflowSteps(
    client,
    workflowId,
    normalizeEnqueueLimit(options.enqueueLimit),
  );

  return {
    reconciliation,
    enqueuedSteps,
  };
}
