import type { SupabaseClient } from "@supabase/supabase-js";

import {
  callRuntimeRpc,
  optionalSingleRpcRow,
  requireSingleRpcRow,
} from "./rpc-utils";
import type {
  CreateLiveRuntimeWorkflowInput,
  CreatedLiveRuntimeWorkflow,
  EnqueuedLiveRuntimeWorkflowStep,
  LiveRuntimeWorkflowEvent,
  LiveRuntimeWorkflowStatus,
  LiveRuntimeWorkflowStatusSnapshot,
  LiveRuntimeWorkflowStep,
  LiveRuntimeWorkflowStepStatus,
  ReconciledLiveRuntimeWorkflow,
} from "./workflow-types";
import type {
  LiveRuntimeJobStatus,
  LiveRuntimeJobType,
  LiveRuntimeScopeType,
} from "./job-service";

type CreateWorkflowRpcRow = {
  workflow_id: string;
  workflow_status: LiveRuntimeWorkflowStatus;
  inserted: boolean;
  step_count: number;
  correlation_id: string;
};

type EnqueueReadyWorkflowStepRpcRow = {
  workflow_step_id: string;
  step_key: string;
  job_id: string;
  job_status: LiveRuntimeJobStatus;
  inserted: boolean;
  scheduled_at: string;
};

type ReconcileWorkflowRpcRow = {
  workflow_id: string;
  workflow_status: LiveRuntimeWorkflowStatus;
  synchronized_step_count: number;
  ready_step_count: number;
  blocked_step_count: number;
  completed_step_count: number;
  failed_step_count: number;
};

type WorkflowStepRpcValue = {
  workflow_step_id: string;
  step_key: string;
  step_order: number;
  job_type: LiveRuntimeJobType;
  scope_type: LiveRuntimeScopeType;
  scope_id: string;
  status: LiveRuntimeWorkflowStepStatus;
  depends_on: string[];
  job_id: string | null;
  priority: number;
  max_attempts: number;
  scheduled_at: string;
  enqueued_at: string | null;
  started_at: string | null;
  completed_at: string | null;
  failed_at: string | null;
  result: Record<string, unknown>;
  last_error: Record<string, unknown> | null;
};

type WorkflowEventRpcValue = {
  event_id: string;
  workflow_step_id: string | null;
  event_type: string;
  payload: Record<string, unknown>;
  correlation_id: string;
  causation_id: string | null;
  occurred_at: string;
};

type WorkflowStatusRpcRow = {
  workflow_id: string;
  workflow_type: string;
  workflow_version: number;
  workflow_status: LiveRuntimeWorkflowStatus;
  scope_type: LiveRuntimeScopeType;
  scope_id: string;
  correlation_id: string;
  created_at: string;
  started_at: string | null;
  completed_at: string | null;
  failed_at: string | null;
  metadata: Record<string, unknown>;
  steps: WorkflowStepRpcValue[];
  recent_events: WorkflowEventRpcValue[];
};

function toWorkflowStepPayload(
  step: CreateLiveRuntimeWorkflowInput["steps"][number],
): Record<string, unknown> {
  return {
    step_key: step.stepKey,
    job_type: step.jobType,
    ...(step.stepOrder === undefined ? {} : { step_order: step.stepOrder }),
    ...(step.scopeType === undefined ? {} : { scope_type: step.scopeType }),
    ...(step.scopeId === undefined ? {} : { scope_id: step.scopeId }),
    depends_on: step.dependsOn ?? [],
    ...(step.priority === undefined ? {} : { priority: step.priority }),
    ...(step.maxAttempts === undefined
      ? {}
      : { max_attempts: step.maxAttempts }),
    ...(step.scheduledAt === undefined
      ? {}
      : { scheduled_at: step.scheduledAt }),
    payload: step.payload ?? {},
  };
}

function mapWorkflowStep(row: WorkflowStepRpcValue): LiveRuntimeWorkflowStep {
  return {
    workflowStepId: row.workflow_step_id,
    stepKey: row.step_key,
    stepOrder: row.step_order,
    jobType: row.job_type,
    scopeType: row.scope_type,
    scopeId: row.scope_id,
    status: row.status,
    dependsOn: row.depends_on ?? [],
    jobId: row.job_id,
    priority: row.priority,
    maxAttempts: row.max_attempts,
    scheduledAt: row.scheduled_at,
    enqueuedAt: row.enqueued_at,
    startedAt: row.started_at,
    completedAt: row.completed_at,
    failedAt: row.failed_at,
    result: row.result ?? {},
    lastError: row.last_error,
  };
}

function mapWorkflowEvent(row: WorkflowEventRpcValue): LiveRuntimeWorkflowEvent {
  return {
    eventId: row.event_id,
    workflowStepId: row.workflow_step_id,
    eventType: row.event_type,
    payload: row.payload ?? {},
    correlationId: row.correlation_id,
    causationId: row.causation_id,
    occurredAt: row.occurred_at,
  };
}

export async function createLiveRuntimeWorkflow(
  client: SupabaseClient,
  input: CreateLiveRuntimeWorkflowInput,
): Promise<CreatedLiveRuntimeWorkflow> {
  const functionName = "create_live_runtime_workflow_rpc";
  const rows = await callRuntimeRpc<CreateWorkflowRpcRow>(client, functionName, {
    p_workflow_type: input.workflowType,
    p_scope_type: input.scopeType,
    p_scope_id: input.scopeId,
    p_idempotency_key: input.idempotencyKey,
    p_steps: input.steps.map(toWorkflowStepPayload),
    p_workflow_version: input.workflowVersion ?? 1,
    p_metadata: input.metadata ?? {},
    p_correlation_id: input.correlationId ?? null,
    p_causation_id: input.causationId ?? null,
    p_trigger_job_id: input.triggerJobId ?? null,
  });

  const row = requireSingleRpcRow(rows, functionName);

  return {
    workflowId: row.workflow_id,
    workflowStatus: row.workflow_status,
    inserted: row.inserted,
    stepCount: row.step_count,
    correlationId: row.correlation_id,
  };
}

export async function enqueueReadyLiveRuntimeWorkflowSteps(
  client: SupabaseClient,
  workflowId: string,
  limit = 25,
): Promise<EnqueuedLiveRuntimeWorkflowStep[]> {
  const functionName = "enqueue_ready_live_runtime_workflow_steps_rpc";
  const rows = await callRuntimeRpc<EnqueueReadyWorkflowStepRpcRow>(
    client,
    functionName,
    {
      p_workflow_id: workflowId,
      p_limit: limit,
    },
  );

  return rows.map((row) => ({
    workflowStepId: row.workflow_step_id,
    stepKey: row.step_key,
    jobId: row.job_id,
    jobStatus: row.job_status,
    inserted: row.inserted,
    scheduledAt: row.scheduled_at,
  }));
}

export async function reconcileLiveRuntimeWorkflow(
  client: SupabaseClient,
  workflowId: string,
): Promise<ReconciledLiveRuntimeWorkflow> {
  const functionName = "reconcile_live_runtime_workflow_rpc";
  const rows = await callRuntimeRpc<ReconcileWorkflowRpcRow>(
    client,
    functionName,
    { p_workflow_id: workflowId },
  );

  const row = requireSingleRpcRow(rows, functionName);

  return {
    workflowId: row.workflow_id,
    workflowStatus: row.workflow_status,
    synchronizedStepCount: row.synchronized_step_count,
    readyStepCount: row.ready_step_count,
    blockedStepCount: row.blocked_step_count,
    completedStepCount: row.completed_step_count,
    failedStepCount: row.failed_step_count,
  };
}

export async function getLiveRuntimeWorkflowStatus(
  client: SupabaseClient,
  workflowId: string,
): Promise<LiveRuntimeWorkflowStatusSnapshot | null> {
  const functionName = "get_live_runtime_workflow_status_rpc";
  const rows = await callRuntimeRpc<WorkflowStatusRpcRow>(client, functionName, {
    p_workflow_id: workflowId,
  });

  const row = optionalSingleRpcRow(rows, functionName);

  if (!row) {
    return null;
  }

  return {
    workflowId: row.workflow_id,
    workflowType: row.workflow_type,
    workflowVersion: row.workflow_version,
    workflowStatus: row.workflow_status,
    scopeType: row.scope_type,
    scopeId: row.scope_id,
    correlationId: row.correlation_id,
    createdAt: row.created_at,
    startedAt: row.started_at,
    completedAt: row.completed_at,
    failedAt: row.failed_at,
    metadata: row.metadata ?? {},
    steps: (row.steps ?? []).map(mapWorkflowStep),
    recentEvents: (row.recent_events ?? []).map(mapWorkflowEvent),
  };
}
