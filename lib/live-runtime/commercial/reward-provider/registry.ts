import type {
  RewardProviderAdapter,
  RewardProviderEnvironment,
} from "./types";

const UPPER_CODE_PATTERN =
  /^[A-Z][A-Z0-9_]+$/;

function normalizeCode(
  value: string,
  fieldName: string,
): string {
  const normalized = value.trim();

  if (
    normalized.length < 2 ||
    normalized.length > 100 ||
    !UPPER_CODE_PATTERN.test(normalized)
  ) {
    throw new TypeError(
      `${fieldName} must be an uppercase code containing between 2 and 100 characters.`,
    );
  }

  return normalized;
}

function requirePositiveSafeInteger(
  value: number,
  fieldName: string,
): number {
  if (
    !Number.isSafeInteger(value) ||
    value < 1
  ) {
    throw new TypeError(
      `${fieldName} must be a positive safe integer.`,
    );
  }

  return value;
}

export interface RewardProviderAdapterIdentity {
  providerCode: string;
  adapterCode: string;
  adapterVersion: number;
}

export interface RewardProviderAdapterRegistration
  extends RewardProviderAdapterIdentity {
  environment: RewardProviderEnvironment;
  enabled: boolean;
  adapter: RewardProviderAdapter;
}

export interface RewardProviderAdapterLookup {
  providerCode: string;
  environment: RewardProviderEnvironment;
  adapterCode?: string;
  adapterVersion?: number;
}

export type RewardProviderAdapterRegistryErrorCode =
  | "REWARD_PROVIDER_ADAPTER_ALREADY_REGISTERED"
  | "REWARD_PROVIDER_ADAPTER_NOT_FOUND"
  | "REWARD_PROVIDER_ADAPTER_DISABLED"
  | "REWARD_PROVIDER_ADAPTER_IDENTITY_MISMATCH"
  | "REWARD_PROVIDER_ADAPTER_SELECTION_AMBIGUOUS";

export class RewardProviderAdapterRegistryError
  extends Error {
  readonly code:
    RewardProviderAdapterRegistryErrorCode;

  constructor(
    code: RewardProviderAdapterRegistryErrorCode,
    message: string,
  ) {
    super(message);

    this.name =
      "RewardProviderAdapterRegistryError";
    this.code = code;
  }
}

function createRegistrationKey(
  providerCode: string,
  adapterCode: string,
  adapterVersion: number,
  environment: RewardProviderEnvironment,
): string {
  return [
    providerCode,
    adapterCode,
    adapterVersion.toString(),
    environment,
  ].join(":");
}

function normalizeRegistration(
  registration:
    RewardProviderAdapterRegistration,
): RewardProviderAdapterRegistration {
  const providerCode = normalizeCode(
    registration.providerCode,
    "registration.providerCode",
  );

  const adapterCode = normalizeCode(
    registration.adapterCode,
    "registration.adapterCode",
  );

  const adapterVersion =
    requirePositiveSafeInteger(
      registration.adapterVersion,
      "registration.adapterVersion",
    );

  if (
    registration.environment !== "test" &&
    registration.environment !== "live"
  ) {
    throw new TypeError(
      "registration.environment is invalid.",
    );
  }

  if (
    typeof registration.enabled !==
    "boolean"
  ) {
    throw new TypeError(
      "registration.enabled must be a boolean.",
    );
  }

  const adapterProviderCode =
    normalizeCode(
      registration.adapter.providerCode,
      "registration.adapter.providerCode",
    );

  const adapterAdapterCode =
    normalizeCode(
      registration.adapter.adapterCode,
      "registration.adapter.adapterCode",
    );

  const adapterAdapterVersion =
    requirePositiveSafeInteger(
      registration.adapter.adapterVersion,
      "registration.adapter.adapterVersion",
    );

  if (
    providerCode !== adapterProviderCode ||
    adapterCode !== adapterAdapterCode ||
    adapterVersion !==
      adapterAdapterVersion
  ) {
    throw new RewardProviderAdapterRegistryError(
      "REWARD_PROVIDER_ADAPTER_IDENTITY_MISMATCH",
      "Reward provider adapter identity does not match its registration.",
    );
  }

  return {
    providerCode,
    adapterCode,
    adapterVersion,
    environment:
      registration.environment,
    enabled: registration.enabled,
    adapter: registration.adapter,
  };
}

function normalizeLookup(
  lookup: RewardProviderAdapterLookup,
): RewardProviderAdapterLookup {
  const providerCode = normalizeCode(
    lookup.providerCode,
    "lookup.providerCode",
  );

  if (
    lookup.environment !== "test" &&
    lookup.environment !== "live"
  ) {
    throw new TypeError(
      "lookup.environment is invalid.",
    );
  }

  const adapterCode =
    lookup.adapterCode === undefined
      ? undefined
      : normalizeCode(
          lookup.adapterCode,
          "lookup.adapterCode",
        );

  const adapterVersion =
    lookup.adapterVersion === undefined
      ? undefined
      : requirePositiveSafeInteger(
          lookup.adapterVersion,
          "lookup.adapterVersion",
        );

  return {
    providerCode,
    environment: lookup.environment,
    adapterCode,
    adapterVersion,
  };
}

export class RewardProviderAdapterRegistry {
  private readonly registrations =
    new Map<
      string,
      RewardProviderAdapterRegistration
    >();

  register(
    registration:
      RewardProviderAdapterRegistration,
  ): void {
    const normalized =
      normalizeRegistration(registration);

    const key = createRegistrationKey(
      normalized.providerCode,
      normalized.adapterCode,
      normalized.adapterVersion,
      normalized.environment,
    );

    if (this.registrations.has(key)) {
      throw new RewardProviderAdapterRegistryError(
        "REWARD_PROVIDER_ADAPTER_ALREADY_REGISTERED",
        `Reward provider adapter ${key} is already registered.`,
      );
    }

    this.registrations.set(
      key,
      Object.freeze(normalized),
    );
  }

  resolve(
    lookup: RewardProviderAdapterLookup,
  ): RewardProviderAdapter {
    const normalized =
      normalizeLookup(lookup);

    const candidates =
      this.listRegistrations().filter(
        (registration) =>
          registration.providerCode ===
            normalized.providerCode &&
          registration.environment ===
            normalized.environment &&
          (
            normalized.adapterCode ===
              undefined ||
            registration.adapterCode ===
              normalized.adapterCode
          ) &&
          (
            normalized.adapterVersion ===
              undefined ||
            registration.adapterVersion ===
              normalized.adapterVersion
          ),
      );

    if (candidates.length === 0) {
      throw new RewardProviderAdapterRegistryError(
        "REWARD_PROVIDER_ADAPTER_NOT_FOUND",
        "No reward provider adapter matches the requested lookup.",
      );
    }

    if (candidates.length > 1) {
      throw new RewardProviderAdapterRegistryError(
        "REWARD_PROVIDER_ADAPTER_SELECTION_AMBIGUOUS",
        "Multiple reward provider adapters match the requested lookup.",
      );
    }

    const registration = candidates[0];

    if (!registration.enabled) {
      throw new RewardProviderAdapterRegistryError(
        "REWARD_PROVIDER_ADAPTER_DISABLED",
        "The selected reward provider adapter is disabled.",
      );
    }

    return registration.adapter;
  }

  has(
    lookup: RewardProviderAdapterIdentity & {
      environment: RewardProviderEnvironment;
    },
  ): boolean {
    const providerCode = normalizeCode(
      lookup.providerCode,
      "lookup.providerCode",
    );

    const adapterCode = normalizeCode(
      lookup.adapterCode,
      "lookup.adapterCode",
    );

    const adapterVersion =
      requirePositiveSafeInteger(
        lookup.adapterVersion,
        "lookup.adapterVersion",
      );

    if (
      lookup.environment !== "test" &&
      lookup.environment !== "live"
    ) {
      throw new TypeError(
        "lookup.environment is invalid.",
      );
    }

    const key = createRegistrationKey(
      providerCode,
      adapterCode,
      adapterVersion,
      lookup.environment,
    );

    return this.registrations.has(key);
  }

  listRegistrations():
    readonly RewardProviderAdapterRegistration[] {
    return Array.from(
      this.registrations.values(),
    );
  }

  size(): number {
    return this.registrations.size;
  }
}