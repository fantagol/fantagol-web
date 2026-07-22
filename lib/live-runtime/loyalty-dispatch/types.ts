export type JsonPrimitive = string | number | boolean | null;
export type JsonValue = JsonPrimitive | JsonObject | JsonValue[];
export type JsonObject = { [key: string]: JsonValue };

export type WorkflowLoyaltyBindingCode =
  | "WF_LOYALTY_LEAGUE_8_MEMBERS"
  | "WF_LOYALTY_LEAGUE_FIRST_ROUND"
  | "WF_LOYALTY_LEAGUE_SEASON_COMPLETE"
  | "WF_LOYALTY_PARTICIPATION_FULL_SEASON"
  | "WF_LOYALTY_PARTICIPATION_STREAK_10"
  | "WF_LOYALTY_PARTICIPATION_STREAK_5"
  | "WF_LOYALTY_PREDICTION_CANTONATA"
  | "WF_LOYALTY_PREDICTION_EXACT"
  | "WF_LOYALTY_PREDICTION_GRAND_SLAM"
  | "WF_LOYALTY_PROFILE_AFTER_FIRST_ROUND";

export interface WorkflowLoyaltyCertificationEvidence {
  certified: true;
  workflow_completed: true;
  step_completed: true;
  workflow_code: string;
  completion_step_code: string;
  workflow_instance_id: string;
  workflow_step_id?: string;
  certified_at: string;
  certification_digest: string;
}

export interface EnqueueWorkflowLoyaltyDispatchInput {
  bindingCode: WorkflowLoyaltyBindingCode;
  workflowInstanceId: string;
  workflowStepId?: string | null;
  workflowExecutionKey: string;
  userId: string;
  certificationReference: string;
  certificationDigest: string;
  evidenceVersion?: number;
  evidence: WorkflowLoyaltyCertificationEvidence;
  occurredAt?: string | null;
  leagueId?: string | null;
  leagueRoundId?: string | null;
  seasonId?: string | null;
  predictionResultId?: string | null;
  correlationId?: string | null;
  causationId?: string | null;
  payload?: JsonObject;
  metadata?: JsonObject;
}

export interface EnqueueWorkflowLoyaltyDispatchResult {
  created: boolean;
  already_exists: boolean;
  outbox_event_id: string;
  dispatch_status: string;
  producer_code?: string;
  producer_event_key?: string;
  producer_receipt_id?: string | null;
  runtime_inbox_event_id?: string | null;
  server_time: string;
}

export interface DispatchWorkflowLoyaltyBatchResult {
  worker_id?: string;
  requested_limit?: number;
  processed_count?: number;
  claimed_count?: number;
  dispatched_count?: number;
  duplicate_count?: number;
  rejected_count?: number;
  retry_scheduled_count?: number;
  dead_letter_count?: number;
  results?: JsonValue[];
  server_time?: string;
}

export interface ReconcileWorkflowLoyaltyLeasesResult {
  reconciled_count?: number;
  retry_scheduled_count?: number;
  dead_letter_count?: number;
  server_time?: string;
}
