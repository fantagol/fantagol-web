import "server-only";

import { asJsonObject, isJsonObject } from "../json";
import { callCommercialRuntimeRpc } from "../rpc";
import type {
  CommercialPurchaseAuthorizationResult,
  CommercialPurchaseReadinessResult,
  CommercialPurchaseRuntimeSnapshot,
  CommercialPurchaseRuntimeEventRecord,
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

function requireTimelineString(
  entry: Record<string, unknown>,
  fieldName: string,
  index: number,
): string {
  const value = entry[fieldName];

  if (typeof value !== "string" || !value.trim()) {
    throw new TypeError(
      `Commercial purchase runtime timeline entry ${index}.${fieldName} must be a non-empty string.`,
    );
  }

  return value;
}

function optionalTimelineString(
  entry: Record<string, unknown>,
  fieldName: string,
  index: number,
): string | null {
  const value = entry[fieldName];

  if (value === null || value === undefined) {
    return null;
  }

  if (typeof value !== "string") {
    throw new TypeError(
      `Commercial purchase runtime timeline entry ${index}.${fieldName} must be a string or null.`,
    );
  }

  return value;
}

function normalizeTimeline(
  value: unknown,
): CommercialPurchaseRuntimeTimeline {
  if (!Array.isArray(value)) {
    throw new TypeError(
      "Commercial purchase runtime timeline must be an array.",
    );
  }

  return value.map(
    (
      entry,
      index,
    ): CommercialPurchaseRuntimeEventRecord => {
      if (!isJsonObject(entry)) {
        throw new TypeError(
          `Commercial purchase runtime timeline entry ${index} must be a JSON object.`,
        );
      }

      const payload = entry.payload;

      if (!isJsonObject(payload)) {
        throw new TypeError(
          `Commercial purchase runtime timeline entry ${index}.payload must be a JSON object.`,
        );
      }

      return {
        id: requireTimelineString(
          entry,
          "id",
          index,
        ),
        purchase_id: optionalTimelineString(
          entry,
          "purchase_id",
          index,
        ),
        policy_id: optionalTimelineString(
          entry,
          "policy_id",
          index,
        ),
        authorization_id: optionalTimelineString(
          entry,
          "authorization_id",
          index,
        ),
        attempt_id: optionalTimelineString(
          entry,
          "attempt_id",
          index,
        ),
        event_type: requireTimelineString(
          entry,
          "event_type",
          index,
        ),
        previous_state: optionalTimelineString(
          entry,
          "previous_state",
          index,
        ),
        next_state: optionalTimelineString(
          entry,
          "next_state",
          index,
        ),
        actor: requireTimelineString(
          entry,
          "actor",
          index,
        ),
        reason: optionalTimelineString(
          entry,
          "reason",
          index,
        ),
        correlation_id: requireTimelineString(
          entry,
          "correlation_id",
          index,
        ),
        causation_id: optionalTimelineString(
          entry,
          "causation_id",
          index,
        ),
        payload,
        occurred_at: requireTimelineString(
          entry,
          "occurred_at",
          index,
        ),
      };
    },
  );
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

  return asJsonObject(
    result.data,
    "Commercial purchase readiness result",
  ) as CommercialPurchaseReadinessResult;
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

  return asJsonObject(
    result.data,
    "Commercial purchase authorization result",
  ) as CommercialPurchaseAuthorizationResult;
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

  return asJsonObject(
    result.data,
    "Commercial purchase authorization decision result",
  ) as CommercialPurchaseAuthorizationResult;
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

  return asJsonObject(
    result.data,
    "Commercial purchase runtime snapshot",
  ) as CommercialPurchaseRuntimeSnapshot;
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

  return normalizeTimeline(result.data);
}
