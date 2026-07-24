import type { JsonObject } from "../json";
import type {
  RewardProviderAdapter,
  RewardProviderAdapterInput,
  RewardProviderVerificationFailure,
  RewardProviderVerificationFailureCode,
  RewardProviderVerificationResult,
} from "./types";
import {
  RewardProviderAdapterRegistry,
  RewardProviderAdapterRegistryError,
} from "./registry";
import type {
  RewardProviderAdapterLookup,
  RewardProviderAdapterRegistryErrorCode,
} from "./registry";
import {
  normalizeRewardProviderVerificationResult,
} from "./validation";

export interface RewardProviderPassiveVerificationRequest {
  lookup: RewardProviderAdapterLookup;
  input: RewardProviderAdapterInput;
}

function getErrorName(
  error: unknown,
): string {
  if (
    error instanceof Error &&
    error.name.trim()
  ) {
    return error.name;
  }

  return "UnknownError";
}

function getErrorMessage(
  error: unknown,
): string | null {
  if (
    error instanceof Error &&
    error.message.trim()
  ) {
    return error.message.slice(0, 500);
  }

  return null;
}

function createFailure(
  request:
    RewardProviderPassiveVerificationRequest,
  errorCode:
    RewardProviderVerificationFailureCode,
  errorMessage: string | null,
  metadata: JsonObject,
): RewardProviderVerificationFailure {
  const providerCode =
    request.lookup.providerCode.trim();

  return {
    verified: false,
    error_code: errorCode,
    error_message: errorMessage,
    provider_code:
      providerCode.length > 0
        ? providerCode
        : null,
    provider_event_id: null,
    correlation_id:
      request.input.context.correlationId,
    metadata,
  };
}

function mapRegistryFailureCode(
  code:
    RewardProviderAdapterRegistryErrorCode,
): RewardProviderVerificationFailureCode {
  switch (code) {
    case "REWARD_PROVIDER_ADAPTER_NOT_FOUND":
      return "REWARD_PROVIDER_NOT_REGISTERED";

    case "REWARD_PROVIDER_ADAPTER_DISABLED":
      return "REWARD_PROVIDER_DISABLED";

    case "REWARD_PROVIDER_ADAPTER_ALREADY_REGISTERED":
    case "REWARD_PROVIDER_ADAPTER_IDENTITY_MISMATCH":
    case "REWARD_PROVIDER_ADAPTER_SELECTION_AMBIGUOUS":
      return "REWARD_PROVIDER_VERIFICATION_FAILED";
  }
}

function verifyCanonicalIdentity(
  adapter: RewardProviderAdapter,
  request:
    RewardProviderPassiveVerificationRequest,
  result:
    RewardProviderVerificationResult,
): string | null {
  if (!result.verified) {
    return null;
  }

  const event = result.event;

  if (
    event.provider_code !==
    adapter.providerCode
  ) {
    return "Canonical event provider identity does not match the selected adapter.";
  }

  if (
    event.adapter_code !==
    adapter.adapterCode
  ) {
    return "Canonical event adapter identity does not match the selected adapter.";
  }

  if (
    event.adapter_version !==
    adapter.adapterVersion
  ) {
    return "Canonical event adapter version does not match the selected adapter.";
  }

  if (
    event.environment !==
    request.lookup.environment
  ) {
    return "Canonical event environment does not match the adapter lookup.";
  }

  if (
    event.environment !==
    request.input.context.environment
  ) {
    return "Canonical event environment does not match the adapter context.";
  }

  if (
    event.correlation_id !==
    request.input.context.correlationId
  ) {
    return "Canonical event correlation identifier does not match the adapter context.";
  }

  return null;
}

export class RewardProviderPassiveVerificationService {
  constructor(
    private readonly registry:
      RewardProviderAdapterRegistry,
  ) {}

  async verify(
    request:
      RewardProviderPassiveVerificationRequest,
  ): Promise<
    RewardProviderVerificationResult
  > {
    if (
      request.lookup.environment !==
      request.input.context.environment
    ) {
      return createFailure(
        request,
        "REWARD_PROVIDER_PAYLOAD_INVALID",
        "Reward provider lookup environment does not match the adapter context.",
        {
          stage:
            "REQUEST_CONTEXT_VALIDATION",
          lookup_environment:
            request.lookup.environment,
          context_environment:
            request.input.context.environment,
        },
      );
    }

    let adapter: RewardProviderAdapter;

    try {
      adapter =
        this.registry.resolve(
          request.lookup,
        );
    } catch (error) {
      if (
        error instanceof
        RewardProviderAdapterRegistryError
      ) {
        return createFailure(
          request,
          mapRegistryFailureCode(
            error.code,
          ),
          error.message,
          {
            stage:
              "ADAPTER_RESOLUTION",
            registry_error_code:
              error.code,
          },
        );
      }

      return createFailure(
        request,
        "REWARD_PROVIDER_VERIFICATION_FAILED",
        getErrorMessage(error),
        {
          stage:
            "ADAPTER_RESOLUTION",
          error_name:
            getErrorName(error),
        },
      );
    }

    let normalized:
      RewardProviderVerificationResult;

    try {
      const rawResult =
        await adapter.verifyAndNormalize(
          request.input,
        );

      normalized =
        normalizeRewardProviderVerificationResult(
          rawResult,
        );
    } catch (error) {
      return createFailure(
        request,
        "REWARD_PROVIDER_VERIFICATION_FAILED",
        getErrorMessage(error),
        {
          stage:
            "ADAPTER_VERIFICATION",
          adapter_code:
            adapter.adapterCode,
          adapter_version:
            adapter.adapterVersion,
          error_name:
            getErrorName(error),
        },
      );
    }

    const identityFailure =
      verifyCanonicalIdentity(
        adapter,
        request,
        normalized,
      );

    if (identityFailure !== null) {
      return createFailure(
        request,
        "REWARD_PROVIDER_VERIFICATION_FAILED",
        identityFailure,
        {
          stage:
            "CANONICAL_IDENTITY_VALIDATION",
          adapter_code:
            adapter.adapterCode,
          adapter_version:
            adapter.adapterVersion,
        },
      );
    }

    return normalized;
  }
}