import { createHash } from "node:crypto";

import {
  AccountErasureContractError,
  AccountErasureValidationError,
} from "./errors";
import type {
  AccountErasureCommandType,
  AuthCommandTarget,
  ClaimedExternalCommand,
  JsonObject,
  PreparedExternalCommand,
  StorageCommandTarget,
} from "./types";

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function asObject(value: unknown, context: string): JsonObject {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new AccountErasureContractError(
      "ACCOUNT_ERASURE_RPC_CONTRACT_INVALID",
      `${context} must be an object.`,
    );
  }

  return value as JsonObject;
}

function asString(value: unknown, context: string): string {
  if (typeof value !== "string" || value.trim() === "") {
    throw new AccountErasureContractError(
      "ACCOUNT_ERASURE_RPC_CONTRACT_INVALID",
      `${context} must be a non-empty string.`,
    );
  }

  return value;
}

function asNumber(value: unknown, context: string): number {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    throw new AccountErasureContractError(
      "ACCOUNT_ERASURE_RPC_CONTRACT_INVALID",
      `${context} must be a finite number.`,
    );
  }

  return value;
}

function asCommandType(value: unknown): AccountErasureCommandType {
  if (
    value !== "DELETE_STORAGE_ASSETS" &&
    value !== "DELETE_SUPABASE_AUTH_IDENTITY"
  ) {
    throw new AccountErasureContractError(
      "ACCOUNT_ERASURE_COMMAND_TYPE_UNSUPPORTED",
      "Unsupported account-erasure external command type.",
    );
  }

  return value;
}

export function parsePreparedExternalCommand(
  value: unknown,
): PreparedExternalCommand {
  const data = asObject(value, "prepared command");

  return {
    commandId: asString(data.command_id, "command_id"),
    commandType: asCommandType(data.command_type),
    commandStatus: asString(data.command_status, "command_status"),
    providerCode: asString(data.provider_code, "provider_code"),
    providerOperation: asString(
      data.provider_operation,
      "provider_operation",
    ),
    requestDigest: asString(data.request_digest, "request_digest"),
    idempotencyKey: asString(data.idempotency_key, "idempotency_key"),
    restrictedPayload: asObject(
      data.restricted_payload,
      "restricted_payload",
    ),
  };
}

export function parseClaimedExternalCommand(
  value: unknown,
): ClaimedExternalCommand {
  const data = asObject(value, "claimed command");

  return {
    commandId: asString(data.command_id, "command_id"),
    commandType: asCommandType(data.command_type),
    commandStatus: "dispatched",
    providerCode: asString(data.provider_code, "provider_code"),
    providerOperation: asString(
      data.provider_operation,
      "provider_operation",
    ),
    requestDigest: asString(data.request_digest, "request_digest"),
    idempotencyKey: asString(data.idempotency_key, "idempotency_key"),
    restrictedPayload: asObject(
      data.restricted_payload,
      "restricted_payload",
    ),
    attemptId: asString(data.attempt_id, "attempt_id"),
    attemptNumber: asNumber(data.attempt_number, "attempt_number"),
    leaseToken: asString(data.lease_token, "lease_token"),
    leaseExpiresAt: asString(data.lease_expires_at, "lease_expires_at"),
  };
}

export function parseStorageTarget(
  payload: JsonObject,
): StorageCommandTarget {
  const rawPaths = payload.normalized_paths;

  if (!Array.isArray(rawPaths)) {
    throw new AccountErasureContractError(
      "STORAGE_COMMAND_PAYLOAD_INVALID",
      "normalized_paths must be an array.",
    );
  }

  const authUserId =
    payload.auth_user_id === null
      ? null
      : asString(payload.auth_user_id, "auth_user_id");

  if (authUserId !== null && !UUID_PATTERN.test(authUserId)) {
    throw new AccountErasureContractError(
      "STORAGE_COMMAND_PAYLOAD_INVALID",
      "auth_user_id is not a valid UUID.",
    );
  }

  return {
    bucketCode: asString(payload.bucket_code, "bucket_code"),
    authUserId,
    normalizedPaths: rawPaths.map((path, index) =>
      asString(path, `normalized_paths[${index}]`),
    ),
    candidateCount: asNumber(
      payload.candidate_count,
      "candidate_count",
    ),
    requiresResidualScan: payload.requires_residual_scan === true,
  };
}

export function parseAuthTarget(payload: JsonObject): AuthCommandTarget {
  const authUserId = asString(payload.auth_user_id, "auth_user_id");

  if (!UUID_PATTERN.test(authUserId) || payload.hard_delete !== true) {
    throw new AccountErasureContractError(
      "AUTH_COMMAND_PAYLOAD_INVALID",
      "Auth deletion target is invalid.",
    );
  }

  return {
    authUserId,
    hardDelete: true,
  };
}

export function assertUuid(value: string, context: string): void {
  if (!UUID_PATTERN.test(value)) {
    throw new AccountErasureValidationError(
      "ACCOUNT_ERASURE_UUID_INVALID",
      `${context} must be a valid UUID.`,
    );
  }
}

function canonicalize(value: unknown): unknown {
  if (Array.isArray(value)) {
    return value.map(canonicalize);
  }

  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value as JsonObject)
        .sort(([left], [right]) => left.localeCompare(right))
        .map(([key, entry]) => [key, canonicalize(entry)]),
    );
  }

  return value;
}

export function digestJson(value: unknown): string {
  return createHash("sha256")
    .update(JSON.stringify(canonicalize(value)))
    .digest("hex");
}
