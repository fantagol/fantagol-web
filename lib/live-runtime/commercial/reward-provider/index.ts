export type {
  CanonicalRewardProviderEvent,
  RewardProviderAdapter,
  RewardProviderAdapterContext,
  RewardProviderAdapterInput,
  RewardProviderEnvironment,
  RewardProviderSignatureAlgorithm,
  RewardProviderVerificationFailure,
  RewardProviderVerificationFailureCode,
  RewardProviderVerificationResult,
  RewardProviderVerificationSuccess,
} from "./types";

export {
  normalizeCanonicalRewardProviderEvent,
  normalizeRewardProviderVerificationResult,
} from "./validation";
export type {
  RewardProviderAdapterIdentity,
  RewardProviderAdapterLookup,
  RewardProviderAdapterRegistration,
  RewardProviderAdapterRegistryErrorCode,
} from "./registry";

export {
  RewardProviderAdapterRegistry,
  RewardProviderAdapterRegistryError,
} from "./registry";
export type {
  RewardProviderPassiveVerificationRequest,
} from "./service";

export {
  RewardProviderPassiveVerificationService,
} from "./service";
export {
  PASSIVE_TEST_ADAPTER_CODE,
  PASSIVE_TEST_ADAPTER_VERSION,
  PASSIVE_TEST_PAYLOAD_HASH,
  PASSIVE_TEST_PROVIDER_CODE,
  PASSIVE_TEST_SIGNATURE,
  PASSIVE_TEST_SIGNATURE_HEADER,
  PassiveTestRewardProviderAdapter,
} from "./passive-test-adapter";
export {
  bootstrapRewardProviderRegistry,
} from "./bootstrap";

export type {
  RewardProviderBootstrapEnvironment,
  RewardProviderBootstrapOptions,
  RewardProviderBootstrapResult,
  RewardProviderRegisteredAdapterDescriptor,
} from "./bootstrap";
export {
  REWARD_PROVIDER_POLICY,
  resolveRewardProviderPolicy,
} from "./policy";

export type {
  RewardProviderPolicyDescriptor,
  RewardProviderPolicyStatus,
  RewardProviderResolvedPolicyDescriptor,
} from "./policy";
