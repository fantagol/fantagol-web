import type {
  JsonObject,
  JsonValue,
} from "../json";
import type {
  CommercialRuntimeEvent,
} from "../types";

export type CommercialPurchaseAction =
  | "attach_checkout"
  | "confirm_payment"
  | "close_purchase"
  | "refund_purchase";

export type CommercialPurchaseAuthorizationDecision =
  | "approved"
  | "rejected"
  | "cancelled";

export type CommercialPurchaseAuthorizationStatus =
  | "requested"
  | "approved"
  | "rejected"
  | "expired"
  | "cancelled";

export type CommercialPurchaseRuntimeState =
  | "dormant"
  | "blocked"
  | "ready"
  | "authorized"
  | "executing"
  | "waiting_retry"
  | "completed"
  | "failed"
  | "cancelled"
  | "refunded";

export type CommercialPurchaseReadinessStatus =
  | "not_evaluated"
  | "ready"
  | "blocked"
  | "attention_required";

export type CommercialPurchaseExecutionStatus =
  | "planned"
  | "leased"
  | "running"
  | "succeeded"
  | "failed"
  | "retry_scheduled"
  | "cancelled";

export type CommercialPurchaseOutboxDispatchStatus =
  | "held"
  | "pending"
  | "claimed"
  | "completed"
  | "failed"
  | "cancelled";

export interface EvaluateCommercialPurchaseReadinessInput {
  purchaseId: string;
}

export interface RequestCommercialPurchaseAuthorizationInput {
  purchaseId: string;
  requestedAction: CommercialPurchaseAction;
  authorizationKey: string;
  requestedBy: string;
  metadata?: JsonObject;
}

export interface DecideCommercialPurchaseAuthorizationInput {
  authorizationId: string;
  decision: CommercialPurchaseAuthorizationDecision;
  decisionBy: string;
  reason?: string | null;
}

export interface GetCommercialPurchaseRuntimeInput {
  purchaseId: string;
}

export interface GetCommercialPurchaseTimelineInput {
  purchaseId: string;
}

export interface CommercialPurchaseRecord extends JsonObject {
  id: string;
  product_id: string;
  provider_id: string;
  purchase_status: string;
  correlation_id: string;
  created_at: string;
}

export interface CommercialPurchaseRuntimeStateRecord
  extends JsonObject {
  purchase_id: string;
  policy_id: string;
  runtime_state: CommercialPurchaseRuntimeState;
  readiness_status: CommercialPurchaseReadinessStatus;
  current_action: CommercialPurchaseAction | null;
  active_authorization_id: string | null;
  last_attempt_id: string | null;
  next_action_at: string | null;
  attention_required: boolean;
  automatic_execution_allowed: false;
  state_reason: string;
  state_version: number;
  evaluated_at: string | null;
  updated_at: string;
  metadata: JsonObject;
}

export interface CommercialPurchaseAuthorizationRecord
  extends JsonObject {
  id: string;
  purchase_id: string;
  policy_id: string;
  authorization_key: string;
  authorization_status: CommercialPurchaseAuthorizationStatus;
  requested_action: CommercialPurchaseAction;
  requested_by: string;
  decision_by: string | null;
  decision_reason: string | null;
  requested_at: string;
  expires_at: string;
  decided_at: string | null;
  correlation_id: string;
  metadata: JsonObject;
}

export interface CommercialPurchaseExecutionAttemptRecord
  extends JsonObject {
  id: string;
  purchase_id: string;
  authorization_id: string | null;
  provider_id: string;
  attempt_number: number;
  execution_action: CommercialPurchaseAction;
  execution_status: CommercialPurchaseExecutionStatus;
  idempotency_key: string;
  worker_code: string | null;
  lease_token: string | null;
  leased_at: string | null;
  lease_expires_at: string | null;
  started_at: string | null;
  completed_at: string | null;
  next_retry_at: string | null;
  error_code: string | null;
  error_message: string | null;
  correlation_id: string;
  causation_id: string | null;
  request_snapshot: JsonObject;
  response_snapshot: JsonObject;
  metadata: JsonObject;
  created_at: string;
}

export interface CommercialPurchaseRuntimeOutboxRecord
  extends JsonObject {
  id: string;
  purchase_id: string;
  authorization_id: string | null;
  requested_action: CommercialPurchaseAction;
  dispatch_status: CommercialPurchaseOutboxDispatchStatus;
  idempotency_key: string;
  available_at: string;
  dispatched_at: string | null;
  completed_at: string | null;
  correlation_id: string;
  payload: JsonObject;
  error_code: string | null;
  error_message: string | null;
  created_at: string;
}

export type CommercialPurchaseReadinessResult =
  | (JsonObject & {
      evaluated: true;
      purchase_id: string;
      runtime_state: CommercialPurchaseRuntimeState;
      readiness_status: CommercialPurchaseReadinessStatus;
      automatic_execution_allowed: false;
      blockers: string[];
      state_reason: string;
    })
  | (JsonObject & {
      evaluated: false;
      error_code: "COMMERCIAL_PURCHASE_NOT_FOUND";
      purchase_id: string;
    });

export type CommercialPurchaseAuthorizationRequestResult =
  | (JsonObject & {
      requested: true;
      authorization_id: string;
      authorization_status: CommercialPurchaseAuthorizationStatus;
      expires_at: string;
    })
  | (JsonObject & {
      requested: false;
      reused_existing_authorization: true;
      authorization_id: string;
      authorization_status: CommercialPurchaseAuthorizationStatus;
    })
  | (JsonObject & {
      requested: false;
      error_code:
        | "COMMERCIAL_PURCHASE_NOT_FOUND"
        | "COMMERCIAL_PURCHASE_RUNTIME_POLICY_NOT_APPROVED";
    });

export type CommercialPurchaseAuthorizationDecisionResult =
  | (JsonObject & {
      decided: true;
      authorization_id: string;
      authorization_status: CommercialPurchaseAuthorizationStatus;
      automatic_execution_scheduled: false;
    })
  | (JsonObject & {
      decided: false;
      error_code: "COMMERCIAL_PURCHASE_AUTHORIZATION_NOT_FOUND";
    })
  | (JsonObject & {
      decided: false;
      error_code: "COMMERCIAL_PURCHASE_AUTHORIZATION_ALREADY_DECIDED";
      authorization_status: CommercialPurchaseAuthorizationStatus;
    });

export type CommercialPurchaseAuthorizationResult =
  | CommercialPurchaseAuthorizationRequestResult
  | CommercialPurchaseAuthorizationDecisionResult;

export type CommercialPurchaseRuntimeSnapshot =
  JsonObject & {
    purchase: CommercialPurchaseRecord;
    runtime_state: CommercialPurchaseRuntimeStateRecord | null;
    authorizations: CommercialPurchaseAuthorizationRecord[];
    attempts: CommercialPurchaseExecutionAttemptRecord[];
    outbox: CommercialPurchaseRuntimeOutboxRecord[];
  };

export interface CommercialPurchaseRuntimeEventRecord
  extends CommercialRuntimeEvent {
  id: string;
  purchase_id: string | null;
  policy_id: string | null;
  authorization_id: string | null;
  attempt_id: string | null;
  event_type: string;
  previous_state: string | null;
  next_state: string | null;
  actor: string;
  reason: string | null;
  correlation_id: string;
  causation_id: string | null;
  payload: JsonObject;
  occurred_at: string;
}

export type CommercialPurchaseRuntimeTimeline =
  CommercialPurchaseRuntimeEventRecord[];

export type CommercialPurchaseRuntimePayload =
  | JsonObject
  | JsonValue[];
