import type { JsonObject } from "../json";

export type RewardProviderEnvironment =
  | "test"
  | "live";

export type RewardProviderSignatureAlgorithm =
  | "HMAC_SHA256"
  | "RSA_SHA256"
  | "ECDSA_SHA256"
  | "PROVIDER_MANAGED";

export type RewardProviderVerificationFailureCode =
  | "REWARD_PROVIDER_NOT_REGISTERED"
  | "REWARD_PROVIDER_DISABLED"
  | "REWARD_PROVIDER_BINDING_NOT_FOUND"
  | "REWARD_PROVIDER_BINDING_DISABLED"
  | "REWARD_PROVIDER_PAYLOAD_INVALID"
  | "REWARD_PROVIDER_SIGNATURE_MISSING"
  | "REWARD_PROVIDER_SIGNATURE_INVALID"
  | "REWARD_PROVIDER_EVENT_EXPIRED"
  | "REWARD_PROVIDER_EVENT_REPLAYED"
  | "REWARD_PROVIDER_VERIFICATION_FAILED";

export interface CanonicalRewardProviderEvent
  extends JsonObject {
  provider_code: string;
  adapter_code: string;
  adapter_version: number;
  environment: RewardProviderEnvironment;

  source_code: string;

  provider_event_id: string;
  provider_event_type: string;

  external_claim_reference: string | null;

  payload_hash: string;
  payload: JsonObject;

  signature_verified: boolean;
  signature_algorithm:
    | RewardProviderSignatureAlgorithm
    | null;

  occurred_at: string | null;
  received_at: string;

  correlation_id: string;
  causation_id: string | null;

  metadata: JsonObject;
}

export interface RewardProviderVerificationSuccess
  extends JsonObject {
  verified: true;
  event: CanonicalRewardProviderEvent;
}

export interface RewardProviderVerificationFailure
  extends JsonObject {
  verified: false;
  error_code:
    RewardProviderVerificationFailureCode;
  error_message: string | null;

  provider_code: string | null;
  provider_event_id: string | null;

  correlation_id: string;
  metadata: JsonObject;
}

export type RewardProviderVerificationResult =
  | RewardProviderVerificationSuccess
  | RewardProviderVerificationFailure;

export interface RewardProviderAdapterContext {
  environment: RewardProviderEnvironment;
  receivedAt: string;
  correlationId: string;
  causationId?: string | null;
}

export interface RewardProviderAdapterInput {
  headers: Readonly<Record<string, string>>;
  payload: JsonObject;
  rawPayload: string;
  context: RewardProviderAdapterContext;
}

export interface RewardProviderAdapter {
  readonly providerCode: string;
  readonly adapterCode: string;
  readonly adapterVersion: number;

  verifyAndNormalize(
    input: RewardProviderAdapterInput,
  ): Promise<RewardProviderVerificationResult>;
}