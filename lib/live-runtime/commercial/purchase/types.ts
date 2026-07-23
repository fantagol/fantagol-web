import type {
  JsonObject,
  JsonValue,
} from "../json";
import type {
  CommercialRuntimeEvent,
} from "../types";

export type CommercialPurchaseAuthorizationDecision =
  | "approved"
  | "rejected";

export interface EvaluateCommercialPurchaseReadinessInput {
  purchaseId: string;
}

export interface RequestCommercialPurchaseAuthorizationInput {
  purchaseId: string;
  requestedAction: string;
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

export type CommercialPurchaseReadinessResult =
  JsonObject & {
    purchase_id?: string;
    runtime_state?: string;
    ready?: boolean;
    blocked?: boolean;
    manual_authorization_required?: boolean;
  };

export type CommercialPurchaseAuthorizationResult =
  JsonObject & {
    authorization_id?: string;
    purchase_id?: string;
    authorization_status?: string;
    reused_existing_authorization?: boolean;
  };

export type CommercialPurchaseRuntimeSnapshot =
  JsonObject & {
    purchase?: JsonObject | null;
    runtime_state?: JsonObject | null;
    authorizations?: JsonValue[];
    outbox?: JsonValue[];
  };

export type CommercialPurchaseRuntimeTimeline =
  CommercialRuntimeEvent[];
