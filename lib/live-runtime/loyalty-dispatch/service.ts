import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";

import type {
  DispatchWorkflowLoyaltyBatchResult,
  EnqueueWorkflowLoyaltyDispatchInput,
  EnqueueWorkflowLoyaltyDispatchResult,
  ReconcileWorkflowLoyaltyLeasesResult,
} from "./types";

export class WorkflowLoyaltyDispatchError extends Error {
  readonly operation: string;
  readonly code?: string;
  readonly details?: string;
  readonly hint?: string;

  constructor(params: {
    operation: string;
    message: string;
    code?: string;
    details?: string;
    hint?: string;
  }) {
    super(params.message);
    this.name = "WorkflowLoyaltyDispatchError";
    this.operation = params.operation;
    this.code = params.code;
    this.details = params.details;
    this.hint = params.hint;
  }
}

function assertObject<T extends object>(
  value: unknown,
  operation: string,
): T {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new WorkflowLoyaltyDispatchError({
      operation,
      message: `${operation} returned a non-object payload`,
    });
  }

  return value as T;
}

function normalizeWorkerId(workerId: string): string {
  const normalized = workerId.trim();

  if (normalized.length < 3) {
    throw new WorkflowLoyaltyDispatchError({
      operation: "normalizeWorkerId",
      message: "Workflow loyalty worker id must contain at least 3 characters",
    });
  }

  return normalized;
}

export async function enqueueWorkflowLoyaltyDispatch(
  supabase: SupabaseClient,
  input: EnqueueWorkflowLoyaltyDispatchInput,
): Promise<EnqueueWorkflowLoyaltyDispatchResult> {
  const operation = "enqueueWorkflowLoyaltyDispatch";

  const { data, error } = await supabase.rpc(
    "enqueue_workflow_loyalty_dispatch_internal",
    {
      p_binding_code: input.bindingCode,
      p_workflow_instance_id: input.workflowInstanceId,
      p_workflow_step_id: input.workflowStepId ?? null,
      p_workflow_execution_key: input.workflowExecutionKey,
      p_user_id: input.userId,
      p_certification_reference: input.certificationReference,
      p_certification_digest: input.certificationDigest,
      p_evidence_version: input.evidenceVersion ?? 1,
      p_evidence: input.evidence,
      p_occurred_at: input.occurredAt ?? null,
      p_league_id: input.leagueId ?? null,
      p_league_round_id: input.leagueRoundId ?? null,
      p_season_id: input.seasonId ?? null,
      p_prediction_result_id: input.predictionResultId ?? null,
      p_correlation_id: input.correlationId ?? null,
      p_causation_id: input.causationId ?? null,
      p_payload: input.payload ?? {},
      p_metadata: input.metadata ?? {},
    },
  );

  if (error) {
    throw new WorkflowLoyaltyDispatchError({
      operation,
      message: error.message,
      code: error.code,
      details: error.details,
      hint: error.hint,
    });
  }

  return assertObject<EnqueueWorkflowLoyaltyDispatchResult>(data, operation);
}

export async function dispatchWorkflowLoyaltyBatch(
  supabase: SupabaseClient,
  params: {
    workerId: string;
    limit?: number;
    leaseSeconds?: number;
  },
): Promise<DispatchWorkflowLoyaltyBatchResult> {
  const operation = "dispatchWorkflowLoyaltyBatch";
  const workerId = normalizeWorkerId(params.workerId);
  const limit = Math.max(1, Math.min(params.limit ?? 25, 250));
  const leaseSeconds = Math.max(15, Math.min(params.leaseSeconds ?? 120, 3600));

  const { data, error } = await supabase.rpc(
    "dispatch_workflow_loyalty_batch_internal",
    {
      p_worker_id: workerId,
      p_limit: limit,
      p_lease_seconds: leaseSeconds,
    },
  );

  if (error) {
    throw new WorkflowLoyaltyDispatchError({
      operation,
      message: error.message,
      code: error.code,
      details: error.details,
      hint: error.hint,
    });
  }

  return assertObject<DispatchWorkflowLoyaltyBatchResult>(data, operation);
}

export async function reconcileExpiredWorkflowLoyaltyLeases(
  supabase: SupabaseClient,
  limit = 100,
): Promise<ReconcileWorkflowLoyaltyLeasesResult> {
  const operation = "reconcileExpiredWorkflowLoyaltyLeases";
  const safeLimit = Math.max(1, Math.min(limit, 1000));

  const { data, error } = await supabase.rpc(
    "reconcile_expired_workflow_loyalty_leases_internal",
    { p_limit: safeLimit },
  );

  if (error) {
    throw new WorkflowLoyaltyDispatchError({
      operation,
      message: error.message,
      code: error.code,
      details: error.details,
      hint: error.hint,
    });
  }

  return assertObject<ReconcileWorkflowLoyaltyLeasesResult>(data, operation);
}
