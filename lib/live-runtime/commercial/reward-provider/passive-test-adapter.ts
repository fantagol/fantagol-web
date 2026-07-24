import type { JsonObject } from "../json";
import { isJsonObject } from "../json";
import type {
  CanonicalRewardProviderEvent,
  RewardProviderAdapter,
  RewardProviderAdapterInput,
  RewardProviderVerificationFailure,
  RewardProviderVerificationFailureCode,
  RewardProviderVerificationResult,
} from "./types";

export const PASSIVE_TEST_PROVIDER_CODE =
  "REWARDED_AD_PASSIVE_TEST";

export const PASSIVE_TEST_ADAPTER_CODE =
  "REWARDED_AD_PASSIVE_TEST_ADAPTER";

export const PASSIVE_TEST_ADAPTER_VERSION =
  1;

export const PASSIVE_TEST_SIGNATURE_HEADER =
  "x-fantagol-passive-test-signature";

export const PASSIVE_TEST_SIGNATURE =
  "fantagol-passive-test-signature-v1";

export const PASSIVE_TEST_PAYLOAD_HASH =
  "a".repeat(64);

type UnknownObject =
  Record<string, unknown>;

function createFailure(
  input: RewardProviderAdapterInput,
  errorCode:
    RewardProviderVerificationFailureCode,
  errorMessage: string,
  providerEventId: string | null,
  metadata: JsonObject,
): RewardProviderVerificationFailure {
  return {
    verified: false,
    error_code: errorCode,
    error_message: errorMessage,
    provider_code:
      PASSIVE_TEST_PROVIDER_CODE,
    provider_event_id:
      providerEventId,
    correlation_id:
      input.context.correlationId,
    metadata,
  };
}

function readOptionalEventId(
  payload: JsonObject,
): string | null {
  const value =
    payload.provider_event_id;

  if (
    typeof value === "string" &&
    value.trim().length > 0
  ) {
    return value.trim().slice(0, 300);
  }

  return null;
}

function requireString(
  object: UnknownObject,
  fieldName: string,
  minimumLength: number,
  maximumLength: number,
): string {
  const value = object[fieldName];

  if (typeof value !== "string") {
    throw new TypeError(
      `${fieldName} must be a string.`,
    );
  }

  const normalized = value.trim();

  if (
    normalized.length < minimumLength ||
    normalized.length > maximumLength
  ) {
    throw new TypeError(
      `${fieldName} must contain between ${minimumLength} and ${maximumLength} characters.`,
    );
  }

  return normalized;
}

function requireNullableString(
  object: UnknownObject,
  fieldName: string,
  maximumLength: number,
): string | null {
  const value = object[fieldName];

  if (
    value === undefined ||
    value === null
  ) {
    return null;
  }

  if (typeof value !== "string") {
    throw new TypeError(
      `${fieldName} must be a string or null.`,
    );
  }

  const normalized = value.trim();

  if (
    normalized.length < 1 ||
    normalized.length > maximumLength
  ) {
    throw new TypeError(
      `${fieldName} must contain between 1 and ${maximumLength} characters.`,
    );
  }

  return normalized;
}

function requireBoolean(
  object: UnknownObject,
  fieldName: string,
): boolean {
  const value = object[fieldName];

  if (typeof value !== "boolean") {
    throw new TypeError(
      `${fieldName} must be a boolean.`,
    );
  }

  return value;
}

function requireNullableTimestamp(
  object: UnknownObject,
  fieldName: string,
): string | null {
  const value = object[fieldName];

  if (
    value === undefined ||
    value === null
  ) {
    return null;
  }

  if (
    typeof value !== "string" ||
    !Number.isFinite(
      Date.parse(value),
    )
  ) {
    throw new TypeError(
      `${fieldName} must be an ISO timestamp or null.`,
    );
  }

  return new Date(value).toISOString();
}

function readHeader(
  headers:
    Readonly<Record<string, string>>,
  headerName: string,
): string | null {
  const normalizedHeaderName =
    headerName.toLowerCase();

  for (
    const [
      currentName,
      currentValue,
    ] of Object.entries(headers)
  ) {
    if (
      currentName.toLowerCase() ===
      normalizedHeaderName
    ) {
      return currentValue;
    }
  }

  return null;
}

function normalizePayload(
  input: RewardProviderAdapterInput,
): CanonicalRewardProviderEvent {
  if (!isJsonObject(input.payload)) {
    throw new TypeError(
      "payload must be a JSON object.",
    );
  }

  const payload =
    input.payload as UnknownObject;

  const providerEventId =
    requireString(
      payload,
      "provider_event_id",
      1,
      300,
    );

  const providerEventType =
    requireString(
      payload,
      "provider_event_type",
      2,
      100,
    );

  const externalClaimReference =
    requireNullableString(
      payload,
      "external_claim_reference",
      300,
    );

  const completed =
    requireBoolean(
      payload,
      "completed",
    );

  if (!completed) {
    throw new TypeError(
      "completed must be true.",
    );
  }

  const occurredAt =
    requireNullableTimestamp(
      payload,
      "occurred_at",
    );

  if (
    occurredAt !== null &&
    Date.parse(occurredAt) >
      Date.parse(
        input.context.receivedAt,
      )
  ) {
    throw new TypeError(
      "occurred_at cannot be later than receivedAt.",
    );
  }

  return {
    provider_code:
      PASSIVE_TEST_PROVIDER_CODE,
    adapter_code:
      PASSIVE_TEST_ADAPTER_CODE,
    adapter_version:
      PASSIVE_TEST_ADAPTER_VERSION,
    environment: "test",

    source_code: "REWARDED_AD",

    provider_event_id:
      providerEventId,
    provider_event_type:
      providerEventType,

    external_claim_reference:
      externalClaimReference,

    payload_hash:
      PASSIVE_TEST_PAYLOAD_HASH,
    payload: {
      provider_event_id:
        providerEventId,
      provider_event_type:
        providerEventType,
      external_claim_reference:
        externalClaimReference,
      completed: true,
      occurred_at: occurredAt,
    },

    signature_verified: true,
    signature_algorithm:
      "PROVIDER_MANAGED",

    occurred_at: occurredAt,
    received_at:
      new Date(
        input.context.receivedAt,
      ).toISOString(),

    correlation_id:
      input.context.correlationId,
    causation_id:
      input.context.causationId ??
      null,

    metadata: {
      passive_test_adapter: true,
      synthetic_provider: true,
      network_access: false,
      persistence_access: false,
      settlement_access: false,
    },
  };
}

export class PassiveTestRewardProviderAdapter
  implements RewardProviderAdapter {
  readonly providerCode =
    PASSIVE_TEST_PROVIDER_CODE;

  readonly adapterCode =
    PASSIVE_TEST_ADAPTER_CODE;

  readonly adapterVersion =
    PASSIVE_TEST_ADAPTER_VERSION;

  async verifyAndNormalize(
    input: RewardProviderAdapterInput,
  ): Promise<
    RewardProviderVerificationResult
  > {
    const providerEventId =
      readOptionalEventId(
        input.payload,
      );

    if (
      input.context.environment !==
      "test"
    ) {
      return createFailure(
        input,
        "REWARD_PROVIDER_DISABLED",
        "The passive test provider adapter is available only in the test environment.",
        providerEventId,
        {
          stage:
            "TEST_ENVIRONMENT_ENFORCEMENT",
          requested_environment:
            input.context.environment,
        },
      );
    }

    const signature =
      readHeader(
        input.headers,
        PASSIVE_TEST_SIGNATURE_HEADER,
      );

    if (signature === null) {
      return createFailure(
        input,
        "REWARD_PROVIDER_SIGNATURE_MISSING",
        "The passive test provider signature is missing.",
        providerEventId,
        {
          stage:
            "TEST_SIGNATURE_VERIFICATION",
          signature_header:
            PASSIVE_TEST_SIGNATURE_HEADER,
        },
      );
    }

    if (
      signature !==
      PASSIVE_TEST_SIGNATURE
    ) {
      return createFailure(
        input,
        "REWARD_PROVIDER_SIGNATURE_INVALID",
        "The passive test provider signature is invalid.",
        providerEventId,
        {
          stage:
            "TEST_SIGNATURE_VERIFICATION",
          signature_header:
            PASSIVE_TEST_SIGNATURE_HEADER,
        },
      );
    }

    try {
      return {
        verified: true,
        event:
          normalizePayload(input),
      };
    } catch (error) {
      return createFailure(
        input,
        "REWARD_PROVIDER_PAYLOAD_INVALID",
        error instanceof Error
          ? error.message
          : "The passive test provider payload is invalid.",
        providerEventId,
        {
          stage:
            "TEST_PAYLOAD_NORMALIZATION",
          error_name:
            error instanceof Error
              ? error.name
              : "UnknownError",
        },
      );
    }
  }
}