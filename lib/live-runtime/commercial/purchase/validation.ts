import type { JsonObject } from "../json";
import { isJsonObject } from "../json";
import type {
  CommercialPurchaseAction,
  CommercialPurchaseAuthorizationDecisionResult,
  CommercialPurchaseAuthorizationRecord,
  CommercialPurchaseAuthorizationRequestResult,
  CommercialPurchaseAuthorizationResult,
  CommercialPurchaseAuthorizationStatus,
  CommercialPurchaseExecutionAttemptRecord,
  CommercialPurchaseExecutionStatus,
  CommercialPurchaseOutboxDispatchStatus,
  CommercialPurchaseReadinessResult,
  CommercialPurchaseReadinessStatus,
  CommercialPurchaseRecord,
  CommercialPurchaseRuntimeEventRecord,
  CommercialPurchaseRuntimeOutboxRecord,
  CommercialPurchaseRuntimeSnapshot,
  CommercialPurchaseRuntimeState,
  CommercialPurchaseRuntimeStateRecord,
  CommercialPurchaseRuntimeTimeline,
} from "./types";

type UnknownObject = Record<string, unknown>;

function requireObject(
  value: unknown,
  context: string,
): JsonObject {
  if (!isJsonObject(value)) {
    throw new TypeError(`${context} must be a JSON object.`);
  }

  return value;
}

function requireArray(
  value: unknown,
  context: string,
): unknown[] {
  if (!Array.isArray(value)) {
    throw new TypeError(`${context} must be an array.`);
  }

  return value;
}

function requireString(
  object: UnknownObject,
  fieldName: string,
  context: string,
): string {
  const value = object[fieldName];

  if (typeof value !== "string" || !value.trim()) {
    throw new TypeError(
      `${context}.${fieldName} must be a non-empty string.`,
    );
  }

  return value;
}

function optionalString(
  object: UnknownObject,
  fieldName: string,
  context: string,
): string | null {
  const value = object[fieldName];

  if (value === null || value === undefined) {
    return null;
  }

  if (typeof value !== "string") {
    throw new TypeError(
      `${context}.${fieldName} must be a string or null.`,
    );
  }

  return value;
}

function requireBoolean(
  object: UnknownObject,
  fieldName: string,
  context: string,
): boolean {
  const value = object[fieldName];

  if (typeof value !== "boolean") {
    throw new TypeError(
      `${context}.${fieldName} must be a boolean.`,
    );
  }

  return value;
}

function requireFalse(
  object: UnknownObject,
  fieldName: string,
  context: string,
): false {
  const value = requireBoolean(
    object,
    fieldName,
    context,
  );

  if (value !== false) {
    throw new TypeError(
      `${context}.${fieldName} must be false.`,
    );
  }

  return false;
}

function requireNumber(
  object: UnknownObject,
  fieldName: string,
  context: string,
): number {
  const value = object[fieldName];

  if (typeof value !== "number" || !Number.isFinite(value)) {
    throw new TypeError(
      `${context}.${fieldName} must be a finite number.`,
    );
  }

  return value;
}

function requireStringArray(
  object: UnknownObject,
  fieldName: string,
  context: string,
): string[] {
  const value = requireArray(
    object[fieldName],
    `${context}.${fieldName}`,
  );

  return value.map((entry, index) => {
    if (typeof entry !== "string") {
      throw new TypeError(
        `${context}.${fieldName}[${index}] must be a string.`,
      );
    }

    return entry;
  });
}

function requireAction(
  value: unknown,
  context: string,
): CommercialPurchaseAction {
  switch (value) {
    case "attach_checkout":
    case "confirm_payment":
    case "close_purchase":
    case "refund_purchase":
      return value;
    default:
      throw new TypeError(`${context} is invalid.`);
  }
}

function optionalAction(
  value: unknown,
  context: string,
): CommercialPurchaseAction | null {
  if (value === null || value === undefined) {
    return null;
  }

  return requireAction(value, context);
}

function requireRuntimeState(
  value: unknown,
  context: string,
): CommercialPurchaseRuntimeState {
  switch (value) {
    case "dormant":
    case "blocked":
    case "ready":
    case "authorized":
    case "executing":
    case "waiting_retry":
    case "completed":
    case "failed":
    case "cancelled":
    case "refunded":
      return value;
    default:
      throw new TypeError(`${context} is invalid.`);
  }
}

function requireReadinessStatus(
  value: unknown,
  context: string,
): CommercialPurchaseReadinessStatus {
  switch (value) {
    case "not_evaluated":
    case "ready":
    case "blocked":
    case "attention_required":
      return value;
    default:
      throw new TypeError(`${context} is invalid.`);
  }
}

function requireAuthorizationStatus(
  value: unknown,
  context: string,
): CommercialPurchaseAuthorizationStatus {
  switch (value) {
    case "requested":
    case "approved":
    case "rejected":
    case "expired":
    case "cancelled":
      return value;
    default:
      throw new TypeError(`${context} is invalid.`);
  }
}

function requireExecutionStatus(
  value: unknown,
  context: string,
): CommercialPurchaseExecutionStatus {
  switch (value) {
    case "planned":
    case "leased":
    case "running":
    case "succeeded":
    case "failed":
    case "retry_scheduled":
    case "cancelled":
      return value;
    default:
      throw new TypeError(`${context} is invalid.`);
  }
}

function requireOutboxStatus(
  value: unknown,
  context: string,
): CommercialPurchaseOutboxDispatchStatus {
  switch (value) {
    case "held":
    case "pending":
    case "claimed":
    case "completed":
    case "failed":
    case "cancelled":
      return value;
    default:
      throw new TypeError(`${context} is invalid.`);
  }
}

function normalizePurchaseRecord(
  value: unknown,
): CommercialPurchaseRecord {
  const object = requireObject(
    value,
    "Commercial purchase runtime snapshot.purchase",
  );

  return {
    ...object,
    id: requireString(object, "id", "purchase"),
    product_id: requireString(object, "product_id", "purchase"),
    provider_id: requireString(object, "provider_id", "purchase"),
    purchase_status: requireString(
      object,
      "purchase_status",
      "purchase",
    ),
    correlation_id: requireString(
      object,
      "correlation_id",
      "purchase",
    ),
    created_at: requireString(
      object,
      "created_at",
      "purchase",
    ),
  };
}

function normalizeRuntimeStateRecord(
  value: unknown,
): CommercialPurchaseRuntimeStateRecord | null {
  if (value === null || value === undefined) {
    return null;
  }

  const object = requireObject(
    value,
    "Commercial purchase runtime snapshot.runtime_state",
  );

  return {
    ...object,
    purchase_id: requireString(
      object,
      "purchase_id",
      "runtime_state",
    ),
    policy_id: requireString(
      object,
      "policy_id",
      "runtime_state",
    ),
    runtime_state: requireRuntimeState(
      object.runtime_state,
      "runtime_state.runtime_state",
    ),
    readiness_status: requireReadinessStatus(
      object.readiness_status,
      "runtime_state.readiness_status",
    ),
    current_action: optionalAction(
      object.current_action,
      "runtime_state.current_action",
    ),
    active_authorization_id: optionalString(
      object,
      "active_authorization_id",
      "runtime_state",
    ),
    last_attempt_id: optionalString(
      object,
      "last_attempt_id",
      "runtime_state",
    ),
    next_action_at: optionalString(
      object,
      "next_action_at",
      "runtime_state",
    ),
    attention_required: requireBoolean(
      object,
      "attention_required",
      "runtime_state",
    ),
    automatic_execution_allowed: requireFalse(
      object,
      "automatic_execution_allowed",
      "runtime_state",
    ),
    state_reason: requireString(
      object,
      "state_reason",
      "runtime_state",
    ),
    state_version: requireNumber(
      object,
      "state_version",
      "runtime_state",
    ),
    evaluated_at: optionalString(
      object,
      "evaluated_at",
      "runtime_state",
    ),
    updated_at: requireString(
      object,
      "updated_at",
      "runtime_state",
    ),
    metadata: requireObject(
      object.metadata,
      "runtime_state.metadata",
    ),
  };
}

function normalizeAuthorizationRecord(
  value: unknown,
  index: number,
): CommercialPurchaseAuthorizationRecord {
  const context = `authorizations[${index}]`;
  const object = requireObject(value, context);

  return {
    ...object,
    id: requireString(object, "id", context),
    purchase_id: requireString(object, "purchase_id", context),
    policy_id: requireString(object, "policy_id", context),
    authorization_key: requireString(
      object,
      "authorization_key",
      context,
    ),
    authorization_status: requireAuthorizationStatus(
      object.authorization_status,
      `${context}.authorization_status`,
    ),
    requested_action: requireAction(
      object.requested_action,
      `${context}.requested_action`,
    ),
    requested_by: requireString(
      object,
      "requested_by",
      context,
    ),
    decision_by: optionalString(
      object,
      "decision_by",
      context,
    ),
    decision_reason: optionalString(
      object,
      "decision_reason",
      context,
    ),
    requested_at: requireString(
      object,
      "requested_at",
      context,
    ),
    expires_at: requireString(
      object,
      "expires_at",
      context,
    ),
    decided_at: optionalString(
      object,
      "decided_at",
      context,
    ),
    correlation_id: requireString(
      object,
      "correlation_id",
      context,
    ),
    metadata: requireObject(
      object.metadata,
      `${context}.metadata`,
    ),
  };
}

function normalizeAttemptRecord(
  value: unknown,
  index: number,
): CommercialPurchaseExecutionAttemptRecord {
  const context = `attempts[${index}]`;
  const object = requireObject(value, context);

  return {
    ...object,
    id: requireString(object, "id", context),
    purchase_id: requireString(object, "purchase_id", context),
    authorization_id: optionalString(
      object,
      "authorization_id",
      context,
    ),
    provider_id: requireString(
      object,
      "provider_id",
      context,
    ),
    attempt_number: requireNumber(
      object,
      "attempt_number",
      context,
    ),
    execution_action: requireAction(
      object.execution_action,
      `${context}.execution_action`,
    ),
    execution_status: requireExecutionStatus(
      object.execution_status,
      `${context}.execution_status`,
    ),
    idempotency_key: requireString(
      object,
      "idempotency_key",
      context,
    ),
    worker_code: optionalString(
      object,
      "worker_code",
      context,
    ),
    lease_token: optionalString(
      object,
      "lease_token",
      context,
    ),
    leased_at: optionalString(
      object,
      "leased_at",
      context,
    ),
    lease_expires_at: optionalString(
      object,
      "lease_expires_at",
      context,
    ),
    started_at: optionalString(
      object,
      "started_at",
      context,
    ),
    completed_at: optionalString(
      object,
      "completed_at",
      context,
    ),
    next_retry_at: optionalString(
      object,
      "next_retry_at",
      context,
    ),
    error_code: optionalString(
      object,
      "error_code",
      context,
    ),
    error_message: optionalString(
      object,
      "error_message",
      context,
    ),
    correlation_id: requireString(
      object,
      "correlation_id",
      context,
    ),
    causation_id: optionalString(
      object,
      "causation_id",
      context,
    ),
    request_snapshot: requireObject(
      object.request_snapshot,
      `${context}.request_snapshot`,
    ),
    response_snapshot: requireObject(
      object.response_snapshot,
      `${context}.response_snapshot`,
    ),
    metadata: requireObject(
      object.metadata,
      `${context}.metadata`,
    ),
    created_at: requireString(
      object,
      "created_at",
      context,
    ),
  };
}

function normalizeOutboxRecord(
  value: unknown,
  index: number,
): CommercialPurchaseRuntimeOutboxRecord {
  const context = `outbox[${index}]`;
  const object = requireObject(value, context);

  return {
    ...object,
    id: requireString(object, "id", context),
    purchase_id: requireString(object, "purchase_id", context),
    authorization_id: optionalString(
      object,
      "authorization_id",
      context,
    ),
    requested_action: requireAction(
      object.requested_action,
      `${context}.requested_action`,
    ),
    dispatch_status: requireOutboxStatus(
      object.dispatch_status,
      `${context}.dispatch_status`,
    ),
    idempotency_key: requireString(
      object,
      "idempotency_key",
      context,
    ),
    available_at: requireString(
      object,
      "available_at",
      context,
    ),
    dispatched_at: optionalString(
      object,
      "dispatched_at",
      context,
    ),
    completed_at: optionalString(
      object,
      "completed_at",
      context,
    ),
    correlation_id: requireString(
      object,
      "correlation_id",
      context,
    ),
    payload: requireObject(
      object.payload,
      `${context}.payload`,
    ),
    error_code: optionalString(
      object,
      "error_code",
      context,
    ),
    error_message: optionalString(
      object,
      "error_message",
      context,
    ),
    created_at: requireString(
      object,
      "created_at",
      context,
    ),
  };
}

export function normalizeCommercialPurchaseReadinessResult(
  value: unknown,
): CommercialPurchaseReadinessResult {
  const object = requireObject(
    value,
    "Commercial purchase readiness result",
  );

  if (object.evaluated === true) {
    return {
      ...object,
      evaluated: true,
      purchase_id: requireString(
        object,
        "purchase_id",
        "readiness",
      ),
      runtime_state: requireRuntimeState(
        object.runtime_state,
        "readiness.runtime_state",
      ),
      readiness_status: requireReadinessStatus(
        object.readiness_status,
        "readiness.readiness_status",
      ),
      automatic_execution_allowed: requireFalse(
        object,
        "automatic_execution_allowed",
        "readiness",
      ),
      blockers: requireStringArray(
        object,
        "blockers",
        "readiness",
      ),
      state_reason: requireString(
        object,
        "state_reason",
        "readiness",
      ),
    };
  }

  if (
    object.evaluated === false &&
    object.error_code === "COMMERCIAL_PURCHASE_NOT_FOUND"
  ) {
    return {
      ...object,
      evaluated: false,
      error_code: "COMMERCIAL_PURCHASE_NOT_FOUND",
      purchase_id: requireString(
        object,
        "purchase_id",
        "readiness",
      ),
    };
  }

  throw new TypeError(
    "Commercial purchase readiness result has an invalid discriminator.",
  );
}

function normalizeAuthorizationRequestResult(
  object: JsonObject,
): CommercialPurchaseAuthorizationRequestResult {
  if (object.requested === true) {
    return {
      ...object,
      requested: true,
      authorization_id: requireString(
        object,
        "authorization_id",
        "authorization",
      ),
      authorization_status: requireAuthorizationStatus(
        object.authorization_status,
        "authorization.authorization_status",
      ),
      expires_at: requireString(
        object,
        "expires_at",
        "authorization",
      ),
    };
  }

  if (
    object.requested === false &&
    object.reused_existing_authorization === true
  ) {
    return {
      ...object,
      requested: false,
      reused_existing_authorization: true,
      authorization_id: requireString(
        object,
        "authorization_id",
        "authorization",
      ),
      authorization_status: requireAuthorizationStatus(
        object.authorization_status,
        "authorization.authorization_status",
      ),
    };
  }

  if (
    object.requested === false &&
    (
      object.error_code === "COMMERCIAL_PURCHASE_NOT_FOUND" ||
      object.error_code ===
        "COMMERCIAL_PURCHASE_RUNTIME_POLICY_NOT_APPROVED"
    )
  ) {
    return {
      ...object,
      requested: false,
      error_code: object.error_code,
    };
  }

  throw new TypeError(
    "Commercial purchase authorization request result has an invalid discriminator.",
  );
}

function normalizeAuthorizationDecisionResult(
  object: JsonObject,
): CommercialPurchaseAuthorizationDecisionResult {
  if (object.decided === true) {
    return {
      ...object,
      decided: true,
      authorization_id: requireString(
        object,
        "authorization_id",
        "authorization_decision",
      ),
      authorization_status: requireAuthorizationStatus(
        object.authorization_status,
        "authorization_decision.authorization_status",
      ),
      automatic_execution_scheduled: requireFalse(
        object,
        "automatic_execution_scheduled",
        "authorization_decision",
      ),
    };
  }

  if (
    object.decided === false &&
    object.error_code ===
      "COMMERCIAL_PURCHASE_AUTHORIZATION_NOT_FOUND"
  ) {
    return {
      ...object,
      decided: false,
      error_code:
        "COMMERCIAL_PURCHASE_AUTHORIZATION_NOT_FOUND",
    };
  }

  if (
    object.decided === false &&
    object.error_code ===
      "COMMERCIAL_PURCHASE_AUTHORIZATION_ALREADY_DECIDED"
  ) {
    return {
      ...object,
      decided: false,
      error_code:
        "COMMERCIAL_PURCHASE_AUTHORIZATION_ALREADY_DECIDED",
      authorization_status: requireAuthorizationStatus(
        object.authorization_status,
        "authorization_decision.authorization_status",
      ),
    };
  }

  throw new TypeError(
    "Commercial purchase authorization decision result has an invalid discriminator.",
  );
}

export function normalizeCommercialPurchaseAuthorizationResult(
  value: unknown,
): CommercialPurchaseAuthorizationResult {
  const object = requireObject(
    value,
    "Commercial purchase authorization result",
  );

  if ("requested" in object) {
    return normalizeAuthorizationRequestResult(object);
  }

  if ("decided" in object) {
    return normalizeAuthorizationDecisionResult(object);
  }

  throw new TypeError(
    "Commercial purchase authorization result has no valid discriminator.",
  );
}

export function normalizeCommercialPurchaseRuntimeSnapshot(
  value: unknown,
): CommercialPurchaseRuntimeSnapshot {
  const object = requireObject(
    value,
    "Commercial purchase runtime snapshot",
  );

  const authorizations = requireArray(
    object.authorizations,
    "Commercial purchase runtime snapshot.authorizations",
  ).map(normalizeAuthorizationRecord);

  const attempts = requireArray(
    object.attempts,
    "Commercial purchase runtime snapshot.attempts",
  ).map(normalizeAttemptRecord);

  const outbox = requireArray(
    object.outbox,
    "Commercial purchase runtime snapshot.outbox",
  ).map(normalizeOutboxRecord);

  return {
    ...object,
    purchase: normalizePurchaseRecord(object.purchase),
    runtime_state: normalizeRuntimeStateRecord(
      object.runtime_state,
    ),
    authorizations,
    attempts,
    outbox,
  };
}

function normalizeTimelineEntry(
  value: unknown,
  index: number,
): CommercialPurchaseRuntimeEventRecord {
  const context =
    `Commercial purchase runtime timeline entry ${index}`;
  const object = requireObject(value, context);

  return {
    ...object,
    id: requireString(object, "id", context),
    purchase_id: optionalString(
      object,
      "purchase_id",
      context,
    ),
    policy_id: optionalString(
      object,
      "policy_id",
      context,
    ),
    authorization_id: optionalString(
      object,
      "authorization_id",
      context,
    ),
    attempt_id: optionalString(
      object,
      "attempt_id",
      context,
    ),
    event_type: requireString(
      object,
      "event_type",
      context,
    ),
    previous_state: optionalString(
      object,
      "previous_state",
      context,
    ),
    next_state: optionalString(
      object,
      "next_state",
      context,
    ),
    actor: requireString(
      object,
      "actor",
      context,
    ),
    reason: optionalString(
      object,
      "reason",
      context,
    ),
    correlation_id: requireString(
      object,
      "correlation_id",
      context,
    ),
    causation_id: optionalString(
      object,
      "causation_id",
      context,
    ),
    payload: requireObject(
      object.payload,
      `${context}.payload`,
    ),
    occurred_at: requireString(
      object,
      "occurred_at",
      context,
    ),
  };
}

export function normalizeCommercialPurchaseRuntimeTimeline(
  value: unknown,
): CommercialPurchaseRuntimeTimeline {
  return requireArray(
    value,
    "Commercial purchase runtime timeline",
  ).map(normalizeTimelineEntry);
}
