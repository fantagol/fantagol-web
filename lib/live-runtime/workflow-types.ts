import type {
  LiveRuntimeJobStatus,
  LiveRuntimeJobType,
  LiveRuntimeScopeType,
} from "./job-service";

export type LiveRuntimeWorkflowStatus =
  | "pending"
  | "running"
  | "completed"
  | "failed"
  | "cancelled";

export type LiveRuntimeWorkflowStepStatus =
  | "blocked"
  | "ready"
  | "enqueued"
  | "running"
  | "retry_wait"
  | "completed"
  | "failed"
  | "dead_letter"
  | "skipped"
  | "cancelled";

export type LiveRuntimeWorkflowStepDefinition = {
  stepKey: string;
  jobType: LiveRuntimeJobType;
  stepOrder?: number;
  scopeType?: LiveRuntimeScopeType;
  scopeId?: string;
  dependsOn?: string[];
  priority?: number;
  maxAttempts?: number;
  scheduledAt?: string;
  payload?: Record<string, unknown>;
};

export type CreateLiveRuntimeWorkflowInput = {
  workflowType: string;
  scopeType: LiveRuntimeScopeType;
  scopeId: string;
  idempotencyKey: string;
  steps: LiveRuntimeWorkflowStepDefinition[];
  workflowVersion?: number;
  metadata?: Record<string, unknown>;
  correlationId?: string | null;
  causationId?: string | null;
  triggerJobId?: string | null;
};

export type CreatedLiveRuntimeWorkflow = {
  workflowId: string;
  workflowStatus: LiveRuntimeWorkflowStatus;
  inserted: boolean;
  stepCount: number;
  correlationId: string;
};

export type EnqueuedLiveRuntimeWorkflowStep = {
  workflowStepId: string;
  stepKey: string;
  jobId: string;
  jobStatus: LiveRuntimeJobStatus;
  inserted: boolean;
  scheduledAt: string;
};

export type ReconciledLiveRuntimeWorkflow = {
  workflowId: string;
  workflowStatus: LiveRuntimeWorkflowStatus;
  synchronizedStepCount: number;
  readyStepCount: number;
  blockedStepCount: number;
  completedStepCount: number;
  failedStepCount: number;
};

export type LiveRuntimeWorkflowStep = {
  workflowStepId: string;
  stepKey: string;
  stepOrder: number;
  jobType: LiveRuntimeJobType;
  scopeType: LiveRuntimeScopeType;
  scopeId: string;
  status: LiveRuntimeWorkflowStepStatus;
  dependsOn: string[];
  jobId: string | null;
  priority: number;
  maxAttempts: number;
  scheduledAt: string;
  enqueuedAt: string | null;
  startedAt: string | null;
  completedAt: string | null;
  failedAt: string | null;
  result: Record<string, unknown>;
  lastError: Record<string, unknown> | null;
};

export type LiveRuntimeWorkflowEvent = {
  eventId: string;
  workflowStepId: string | null;
  eventType: string;
  payload: Record<string, unknown>;
  correlationId: string;
  causationId: string | null;
  occurredAt: string;
};

export type LiveRuntimeWorkflowStatusSnapshot = {
  workflowId: string;
  workflowType: string;
  workflowVersion: number;
  workflowStatus: LiveRuntimeWorkflowStatus;
  scopeType: LiveRuntimeScopeType;
  scopeId: string;
  correlationId: string;
  createdAt: string;
  startedAt: string | null;
  completedAt: string | null;
  failedAt: string | null;
  metadata: Record<string, unknown>;
  steps: LiveRuntimeWorkflowStep[];
  recentEvents: LiveRuntimeWorkflowEvent[];
};
