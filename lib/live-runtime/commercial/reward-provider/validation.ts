import type { JsonObject } from "../json";
import { isJsonObject } from "../json";
import type {
  CanonicalRewardProviderEvent,
  RewardProviderEnvironment,
  RewardProviderSignatureAlgorithm,
  RewardProviderVerificationFailureCode,
  RewardProviderVerificationResult,
} from "./types";

type UnknownObject =
  Record<string, unknown>;

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

const UPPER_CODE_PATTERN =
  /^[A-Z][A-Z0-9_]+$/;

const SHA256_PATTERN =
  /^[0-9a-f]{64}$/;

const ENVIRONMENTS =
  new Set<RewardProviderEnvironment>([
    "test",
    "live",
  ]);

const SIGNATURE_ALGORITHMS =
  new Set<RewardProviderSignatureAlgorithm>([
    "HMAC_SHA256",
    "RSA_SHA256",
    "ECDSA_SHA256",
    "PROVIDER_MANAGED",
  ]);

const VERIFICATION_FAILURE_CODES =
  new Set<RewardProviderVerificationFailureCode>([
    "REWARD_PROVIDER_NOT_REGISTERED",
    "REWARD_PROVIDER_DISABLED",
    "REWARD_PROVIDER_BINDING_NOT_FOUND",
    "REWARD_PROVIDER_BINDING_DISABLED",
    "REWARD_PROVIDER_PAYLOAD_INVALID",
    "REWARD_PROVIDER_SIGNATURE_MISSING",
    "REWARD_PROVIDER_SIGNATURE_INVALID",
    "REWARD_PROVIDER_EVENT_EXPIRED",
    "REWARD_PROVIDER_EVENT_REPLAYED",
    "REWARD_PROVIDER_VERIFICATION_FAILED",
  ]);

function requireObject(
  value: unknown,
  context: string,
): JsonObject {
  if (!isJsonObject(value)) {
    throw new TypeError(
      `${context} must be a JSON object.`,
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

function requireLiteralTrue(
  object: UnknownObject,
  fieldName: string,
  context: string,
): true {
  if (
    requireBoolean(
      object,
      fieldName,
      context,
    ) !== true
  ) {
    throw new TypeError(
      `${context}.${fieldName} must be true.`,
    );
  }

  return true;
}

function requireLiteralFalse(
  object: UnknownObject,
  fieldName: string,
  context: string,
): false {
  if (
    requireBoolean(
      object,
      fieldName,
      context,
    ) !== false
  ) {
    throw new TypeError(
      `${context}.${fieldName} must be false.`,
    );
  }

  return false;
}

function requireString(
  object: UnknownObject,
  fieldName: string,
  context: string,
  minimumLength: number,
  maximumLength: number,
): string {
  const value = object[fieldName];

  if (typeof value !== "string") {
    throw new TypeError(
      `${context}.${fieldName} must be a string.`,
    );
  }

  const normalized = value.trim();

  if (
    normalized.length < minimumLength ||
    normalized.length > maximumLength
  ) {
    throw new TypeError(
      `${context}.${fieldName} must contain between ${minimumLength} and ${maximumLength} characters.`,
    );
  }

  return normalized;
}

function requireNullableString(
  object: UnknownObject,
  fieldName: string,
  context: string,
  maximumLength: number,
): string | null {
  const value = object[fieldName];

  if (value === null) {
    return null;
  }

  if (typeof value !== "string") {
    throw new TypeError(
      `${context}.${fieldName} must be a string or null.`,
    );
  }

  const normalized = value.trim();

  if (
    normalized.length < 1 ||
    normalized.length > maximumLength
  ) {
    throw new TypeError(
      `${context}.${fieldName} must contain between 1 and ${maximumLength} characters or be null.`,
    );
  }

  return normalized;
}

function requireUpperCode(
  object: UnknownObject,
  fieldName: string,
  context: string,
): string {
  const value = requireString(
    object,
    fieldName,
    context,
    2,
    100,
  );

  if (!UPPER_CODE_PATTERN.test(value)) {
    throw new TypeError(
      `${context}.${fieldName} must be an uppercase code.`,
    );
  }

  return value;
}

function requireUuid(
  object: UnknownObject,
  fieldName: string,
  context: string,
): string {
  const value = requireString(
    object,
    fieldName,
    context,
    36,
    36,
  );

  if (!UUID_PATTERN.test(value)) {
    throw new TypeError(
      `${context}.${fieldName} must be a valid UUID.`,
    );
  }

  return value;
}

function requireNullableUuid(
  object: UnknownObject,
  fieldName: string,
  context: string,
): string | null {
  const value = object[fieldName];

  if (value === null) {
    return null;
  }

  if (
    typeof value !== "string" ||
    !UUID_PATTERN.test(value.trim())
  ) {
    throw new TypeError(
      `${context}.${fieldName} must be a valid UUID or null.`,
    );
  }

  return value.trim();
}

function requirePositiveSafeInteger(
  object: UnknownObject,
  fieldName: string,
  context: string,
): number {
  const value = object[fieldName];

  if (
    typeof value !== "number" ||
    !Number.isSafeInteger(value) ||
    value < 1
  ) {
    throw new TypeError(
      `${context}.${fieldName} must be a positive safe integer.`,
    );
  }

  return value;
}

function requireTimestamp(
  object: UnknownObject,
  fieldName: string,
  context: string,
): string {
  const value = object[fieldName];

  if (
    typeof value !== "string" ||
    !value.trim() ||
    Number.isNaN(Date.parse(value))
  ) {
    throw new TypeError(
      `${context}.${fieldName} must be a valid timestamp.`,
    );
  }

  return value;
}

function requireNullableTimestamp(
  object: UnknownObject,
  fieldName: string,
  context: string,
): string | null {
  const value = object[fieldName];

  if (value === null) {
    return null;
  }

  if (
    typeof value !== "string" ||
    !value.trim() ||
    Number.isNaN(Date.parse(value))
  ) {
    throw new TypeError(
      `${context}.${fieldName} must be a valid timestamp or null.`,
    );
  }

  return value;
}

function requireEnvironment(
  value: unknown,
  context: string,
): RewardProviderEnvironment {
  if (
    typeof value !== "string" ||
    !ENVIRONMENTS.has(
      value as RewardProviderEnvironment,
    )
  ) {
    throw new TypeError(
      `${context} is invalid.`,
    );
  }

  return value as RewardProviderEnvironment;
}

function requirePayloadHash(
  object: UnknownObject,
  fieldName: string,
  context: string,
): string {
  const value = object[fieldName];

  if (
    typeof value !== "string" ||
    !SHA256_PATTERN.test(value)
  ) {
    throw new TypeError(
      `${context}.${fieldName} must be a lowercase SHA-256 hexadecimal digest.`,
    );
  }

  return value;
}

function requireNullableSignatureAlgorithm(
  value: unknown,
  context: string,
): RewardProviderSignatureAlgorithm | null {
  if (value === null) {
    return null;
  }

  if (
    typeof value !== "string" ||
    !SIGNATURE_ALGORITHMS.has(
      value as RewardProviderSignatureAlgorithm,
    )
  ) {
    throw new TypeError(
      `${context} is invalid.`,
    );
  }

  return value as RewardProviderSignatureAlgorithm;
}

function requireFailureCode(
  value: unknown,
  context: string,
): RewardProviderVerificationFailureCode {
  if (
    typeof value !== "string" ||
    !VERIFICATION_FAILURE_CODES.has(
      value as RewardProviderVerificationFailureCode,
    )
  ) {
    throw new TypeError(
      `${context} is invalid.`,
    );
  }

  return value as RewardProviderVerificationFailureCode;
}

function normalizeCanonicalEvent(
  value: unknown,
  context: string,
): CanonicalRewardProviderEvent {
  const object = requireObject(
    value,
    context,
  );

  const occurredAt =
    requireNullableTimestamp(
      object,
      "occurred_at",
      context,
    );

  const receivedAt =
    requireTimestamp(
      object,
      "received_at",
      context,
    );

  if (
    occurredAt !== null &&
    Date.parse(occurredAt) >
      Date.parse(receivedAt)
  ) {
    throw new TypeError(
      `${context}.occurred_at cannot be later than received_at.`,
    );
  }

  return {
    ...object,
    provider_code: requireUpperCode(
      object,
      "provider_code",
      context,
    ),
    adapter_code: requireUpperCode(
      object,
      "adapter_code",
      context,
    ),
    adapter_version:
      requirePositiveSafeInteger(
        object,
        "adapter_version",
        context,
      ),
    environment: requireEnvironment(
      object.environment,
      `${context}.environment`,
    ),
    source_code: requireUpperCode(
      object,
      "source_code",
      context,
    ),
    provider_event_id: requireString(
      object,
      "provider_event_id",
      context,
      1,
      300,
    ),
    provider_event_type: requireString(
      object,
      "provider_event_type",
      context,
      1,
      200,
    ),
    external_claim_reference:
      requireNullableString(
        object,
        "external_claim_reference",
        context,
        300,
      ),
    payload_hash: requirePayloadHash(
      object,
      "payload_hash",
      context,
    ),
    payload: requireObject(
      object.payload,
      `${context}.payload`,
    ),
    signature_verified: requireBoolean(
      object,
      "signature_verified",
      context,
    ),
    signature_algorithm:
      requireNullableSignatureAlgorithm(
        object.signature_algorithm,
        `${context}.signature_algorithm`,
      ),
    occurred_at: occurredAt,
    received_at: receivedAt,
    correlation_id: requireUuid(
      object,
      "correlation_id",
      context,
    ),
    causation_id: requireNullableUuid(
      object,
      "causation_id",
      context,
    ),
    metadata: requireObject(
      object.metadata,
      `${context}.metadata`,
    ),
  };
}

export function normalizeCanonicalRewardProviderEvent(
  value: unknown,
): CanonicalRewardProviderEvent {
  return normalizeCanonicalEvent(
    value,
    "reward_provider_event",
  );
}

export function normalizeRewardProviderVerificationResult(
  value: unknown,
): RewardProviderVerificationResult {
  const context =
    "reward_provider_verification";

  const object = requireObject(
    value,
    context,
  );

  if (object.verified === true) {
    const event =
      normalizeCanonicalEvent(
        object.event,
        `${context}.event`,
      );

    if (!event.signature_verified) {
      throw new TypeError(
        `${context}.event.signature_verified must be true for a verified result.`,
      );
    }

    return {
      ...object,
      verified: requireLiteralTrue(
        object,
        "verified",
        context,
      ),
      event,
    };
  }

  if (object.verified === false) {
    return {
      ...object,
      verified: requireLiteralFalse(
        object,
        "verified",
        context,
      ),
      error_code: requireFailureCode(
        object.error_code,
        `${context}.error_code`,
      ),
      error_message:
        requireNullableString(
          object,
          "error_message",
          context,
          500,
        ),
      provider_code:
        requireNullableString(
          object,
          "provider_code",
          context,
          100,
        ),
      provider_event_id:
        requireNullableString(
          object,
          "provider_event_id",
          context,
          300,
        ),
      correlation_id: requireUuid(
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

  throw new TypeError(
    `${context}.verified must be a boolean.`,
  );
}