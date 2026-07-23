import "server-only";

import { callCommercialRuntimeRpc } from "../rpc";
import {
  normalizeCommercialPurchaseAuthorizationResult,
  normalizeCommercialPurchaseReadinessResult,
  normalizeCommercialPurchaseRuntimeSnapshot,
  normalizeCommercialPurchaseRuntimeTimeline,
} from "./validation";
import type {
  CommercialPurchaseAuthorizationResult,
  CommercialPurchaseReadinessResult,
  CommercialPurchaseRuntimeSnapshot,
  CommercialPurchaseRuntimeTimeline,
  DecideCommercialPurchaseAuthorizationInput,
  EvaluateCommercialPurchaseReadinessInput,
  GetCommercialPurchaseRuntimeInput,
  GetCommercialPurchaseTimelineInput,
  RequestCommercialPurchaseAuthorizationInput,
} from "./types";

function requireNonEmptyString(
  value: string,
  fieldName: string,
): string {
  const normalized = value.trim();

  if (!normalized) {
    throw new TypeError(`${fieldName} must not be empty.`);
  }

  return normalized;
}

function requireUuid(
  value: string,
  fieldName: string,
): string {
  const normalized = requireNonEmptyString(
    value,
    fieldName,
  );

  const uuidPattern =
    /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

  if (!uuidPattern.test(normalized)) {
    throw new TypeError(
      `${fieldName} must be a valid UUID.`,
    );
  }

  return normalized;
}

export async function evaluateCommercialPurchaseReadiness(
  input: EvaluateCommercialPurchaseReadinessInput,
): Promise<CommercialPurchaseReadinessResult> {
  const purchaseId = requireUuid(
    input.purchaseId,
    "purchaseId",
  );

  const result =
    await callCommercialRuntimeRpc<unknown>(
      "evaluate_commercial_purchase_runtime_readiness_internal",
      {
        p_purchase_id: purchaseId,
      },
    );

  return normalizeCommercialPurchaseReadinessResult(
    result.data,
  );
}

export async function requestCommercialPurchaseAuthorization(
  input: RequestCommercialPurchaseAuthorizationInput,
): Promise<CommercialPurchaseAuthorizationResult> {
  const purchaseId = requireUuid(
    input.purchaseId,
    "purchaseId",
  );

  const requestedAction = requireNonEmptyString(
    input.requestedAction,
    "requestedAction",
  );

  const authorizationKey = requireNonEmptyString(
    input.authorizationKey,
    "authorizationKey",
  );

  const requestedBy = requireNonEmptyString(
    input.requestedBy,
    "requestedBy",
  );

  const result =
    await callCommercialRuntimeRpc<unknown>(
      "request_commercial_purchase_authorization_internal",
      {
        p_purchase_id: purchaseId,
        p_requested_action: requestedAction,
        p_authorization_key: authorizationKey,
        p_requested_by: requestedBy,
        p_metadata: input.metadata ?? {},
      },
    );

  return normalizeCommercialPurchaseAuthorizationResult(
    result.data,
  );
}

export async function decideCommercialPurchaseAuthorization(
  input: DecideCommercialPurchaseAuthorizationInput,
): Promise<CommercialPurchaseAuthorizationResult> {
  const authorizationId = requireUuid(
    input.authorizationId,
    "authorizationId",
  );

  const decisionBy = requireNonEmptyString(
    input.decisionBy,
    "decisionBy",
  );

  const result =
    await callCommercialRuntimeRpc<unknown>(
      "decide_commercial_purchase_authorization_internal",
      {
        p_authorization_id: authorizationId,
        p_decision: input.decision,
        p_decision_by: decisionBy,
        p_reason: input.reason?.trim() || null,
      },
    );

  return normalizeCommercialPurchaseAuthorizationResult(
    result.data,
  );
}

export async function getCommercialPurchaseRuntime(
  input: GetCommercialPurchaseRuntimeInput,
): Promise<CommercialPurchaseRuntimeSnapshot> {
  const purchaseId = requireUuid(
    input.purchaseId,
    "purchaseId",
  );

  const result =
    await callCommercialRuntimeRpc<unknown>(
      "get_commercial_purchase_runtime_internal",
      {
        p_purchase_id: purchaseId,
      },
    );

  return normalizeCommercialPurchaseRuntimeSnapshot(
    result.data,
  );
}

export async function getCommercialPurchaseRuntimeTimeline(
  input: GetCommercialPurchaseTimelineInput,
): Promise<CommercialPurchaseRuntimeTimeline> {
  const purchaseId = requireUuid(
    input.purchaseId,
    "purchaseId",
  );

  const result =
    await callCommercialRuntimeRpc<unknown>(
      "get_commercial_purchase_runtime_timeline_internal",
      {
        p_purchase_id: purchaseId,
      },
    );

  return normalizeCommercialPurchaseRuntimeTimeline(
    result.data,
  );
}
