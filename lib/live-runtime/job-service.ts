import type { SupabaseClient } from "@supabase/supabase-js";

import {
  callRuntimeRpc,
  optionalSingleRpcRow,
  requireSingleRpcRow,
} from "./rpc-utils";

export type LiveRuntimeJobType =
  | "poll_match"
  | "refresh_round"
  | "rebuild_league_round"
  | "publish_snapshot"
  | "retry_publication"
  | "evaluate_certification_readiness";

export type LiveRuntimeScopeType =
  | "match"
  | "fantagol_round"
  | "league_round"
  | "round_simulation"
  | "live_state_snapshot"
  | "publication";

export type LiveRuntimeJobStatus =
  | "pending"
  | "claimed"
  | "running"
  | "completed"
  | "failed"
  | "retry_wait"
  | "dead_letter"
  | "cancelled";

export type EnqueueLiveRuntimeJobInput = {
  jobType: LiveRuntimeJobType;
  scopeType: LiveRuntimeScopeType;
  scopeId: string;
  idempotencyKey: string;
  priority?: number;
  scheduledAt?: string;
  payload?: Record<string, unknown>;
  maxAttempts?: number;
  correlationId?: string | null;
  causationId?: string | null;
};

export type EnqueuedLiveRuntimeJob = {
  jobId: string;
  jobStatus: LiveRuntimeJobStatus;
  inserted: boolean;
  scheduledAt: string;
  attemptCount: number;
  correlationId: string;
};

export type ClaimedLiveRuntimeJob = {
  jobId: string;
  jobType: LiveRuntimeJobType;
  jobStatus: LiveRuntimeJobStatus;
  priority: number;
  scopeType: LiveRuntimeScopeType;
  scopeId: string;
  scheduledAt: string;
  attemptCount: number;
  maxAttempts: number;
  correlationId: string;
  causationId: string | null;
  payload: Record<string, unknown>;
};

export type CompletedLiveRuntimeJob = {
  jobId: string;
  jobStatus: LiveRuntimeJobStatus;
  attemptCount: number;
  completedAt: string;
  result: Record<string, unknown>;
};

export type FailedLiveRuntimeJob = {
  jobId: string;
  jobStatus: LiveRuntimeJobStatus;
  attemptCount: number;
  maxAttempts: number;
  scheduledAt: string;
  deadLetterId: string | null;
};

type EnqueueRpcRow = {
  job_id: string;
  job_status: LiveRuntimeJobStatus;
  inserted: boolean;
  scheduled_at: string;
  attempt_count: number;
  correlation_id: string;
};

type ClaimRpcRow = {
  job_id: string;
  job_type: LiveRuntimeJobType;
  job_status: LiveRuntimeJobStatus;
  priority: number;
  scope_type: LiveRuntimeScopeType;
  scope_id: string;
  scheduled_at: string;
  attempt_count: number;
  max_attempts: number;
  correlation_id: string;
  causation_id: string | null;
  payload: Record<string, unknown>;
};

type CompleteRpcRow = {
  job_id: string;
  job_status: LiveRuntimeJobStatus;
  attempt_count: number;
  completed_at: string;
  result: Record<string, unknown>;
};

type FailRpcRow = {
  job_id: string;
  job_status: LiveRuntimeJobStatus;
  attempt_count: number;
  max_attempts: number;
  scheduled_at: string;
  dead_letter_id: string | null;
};

export async function enqueueLiveRuntimeJob(
  client: SupabaseClient,
  input: EnqueueLiveRuntimeJobInput,
): Promise<EnqueuedLiveRuntimeJob> {
  const functionName = "enqueue_live_runtime_job_rpc";
  const rows = await callRuntimeRpc<EnqueueRpcRow>(client, functionName, {
    p_job_type: input.jobType,
    p_scope_type: input.scopeType,
    p_scope_id: input.scopeId,
    p_idempotency_key: input.idempotencyKey,
    p_priority: input.priority ?? 100,
    p_scheduled_at: input.scheduledAt ?? new Date().toISOString(),
    p_payload: input.payload ?? {},
    p_max_attempts: input.maxAttempts ?? 5,
    p_correlation_id: input.correlationId ?? null,
    p_causation_id: input.causationId ?? null,
  });

  const row = requireSingleRpcRow(rows, functionName);

  return {
    jobId: row.job_id,
    jobStatus: row.job_status,
    inserted: row.inserted,
    scheduledAt: row.scheduled_at,
    attemptCount: row.attempt_count,
    correlationId: row.correlation_id,
  };
}

export async function claimLiveRuntimeJob(
  client: SupabaseClient,
  workerId: string,
  jobTypes?: LiveRuntimeJobType[] | null,
): Promise<ClaimedLiveRuntimeJob | null> {
  const functionName = "claim_live_runtime_job_rpc";
  const rows = await callRuntimeRpc<ClaimRpcRow>(client, functionName, {
    p_worker_id: workerId,
    p_job_types: jobTypes ?? null,
  });

  const row = optionalSingleRpcRow(rows, functionName);

  if (!row) {
    return null;
  }

  return {
    jobId: row.job_id,
    jobType: row.job_type,
    jobStatus: row.job_status,
    priority: row.priority,
    scopeType: row.scope_type,
    scopeId: row.scope_id,
    scheduledAt: row.scheduled_at,
    attemptCount: row.attempt_count,
    maxAttempts: row.max_attempts,
    correlationId: row.correlation_id,
    causationId: row.causation_id,
    payload: row.payload,
  };
}

export async function completeLiveRuntimeJob(
  client: SupabaseClient,
  input: {
    jobId: string;
    workerId: string;
    result?: Record<string, unknown>;
  },
): Promise<CompletedLiveRuntimeJob> {
  const functionName = "complete_live_runtime_job_rpc";
  const rows = await callRuntimeRpc<CompleteRpcRow>(client, functionName, {
    p_job_id: input.jobId,
    p_worker_id: input.workerId,
    p_result: input.result ?? {},
  });

  const row = requireSingleRpcRow(rows, functionName);

  return {
    jobId: row.job_id,
    jobStatus: row.job_status,
    attemptCount: row.attempt_count,
    completedAt: row.completed_at,
    result: row.result,
  };
}

export async function failLiveRuntimeJob(
  client: SupabaseClient,
  input: {
    jobId: string;
    workerId: string;
    error: Record<string, unknown>;
    retryDelaySeconds?: number;
  },
): Promise<FailedLiveRuntimeJob> {
  const functionName = "fail_live_runtime_job_rpc";
  const rows = await callRuntimeRpc<FailRpcRow>(client, functionName, {
    p_job_id: input.jobId,
    p_worker_id: input.workerId,
    p_error: input.error,
    p_retry_delay_seconds: input.retryDelaySeconds ?? 30,
  });

  const row = requireSingleRpcRow(rows, functionName);

  return {
    jobId: row.job_id,
    jobStatus: row.job_status,
    attemptCount: row.attempt_count,
    maxAttempts: row.max_attempts,
    scheduledAt: row.scheduled_at,
    deadLetterId: row.dead_letter_id,
  };
}
