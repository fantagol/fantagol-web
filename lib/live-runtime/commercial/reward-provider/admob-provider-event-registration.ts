import "server-only";

import {
  createHash,
} from "node:crypto";

import type {
  SupabaseClient,
} from "@supabase/supabase-js";

import {
  getSupabaseServiceClient,
} from "@/lib/supabase/service";

import type {
  VerifiedAdMobRewardedSsv,
} from "./admob-ssv-verifier";

export interface AdMobProviderEventRegistrationResult {
  readonly registered: boolean;
  readonly duplicate: boolean;
  readonly eventId: string;
  readonly processingStatus: string;
  readonly signatureVerified: boolean;
  readonly correlationId:
    string | null;
  readonly payloadHash: string;
}

type ProviderEventRpcPayload = {
  registered?: unknown;
  duplicate?: unknown;
  event_id?: unknown;
  processing_status?: unknown;
  signature_verified?: unknown;
  correlation_id?: unknown;
};

export interface AdMobProviderEventRegistrarDependencies {
  readonly getServiceClient?:
    () => SupabaseClient;
}

export function hashVerifiedAdMobSignedContent(
  signedContent: string,
): string {
  return createHash("sha256")
    .update(
      signedContent,
      "utf8",
    )
    .digest("hex");
}

function requireBoolean(
  value: unknown,
  field: string,
): boolean {
  if (typeof value !== "boolean") {
    throw new Error(
      `ADMOB_PROVIDER_EVENT_RESPONSE_INVALID:${field}`,
    );
  }

  return value;
}

function requireString(
  value: unknown,
  field: string,
): string {
  if (
    typeof value !== "string" ||
    !value.trim()
  ) {
    throw new Error(
      `ADMOB_PROVIDER_EVENT_RESPONSE_INVALID:${field}`,
    );
  }

  return value.trim();
}

export async function registerVerifiedAdMobProviderEvent(
  verified:
    VerifiedAdMobRewardedSsv,
  dependencies:
    AdMobProviderEventRegistrarDependencies = {},
): Promise<
  AdMobProviderEventRegistrationResult
> {
  if (verified.verified !== true) {
    throw new Error(
      "ADMOB_PROVIDER_EVENT_REQUIRES_VERIFIED_SSV",
    );
  }

  const payloadHash =
    hashVerifiedAdMobSignedContent(
      verified.signedContent,
    );

  const payload = {
    provider: "ADMOB_REWARDED",
    sourceCode:
      verified.sourceCode,
    providerEventType:
      verified.providerEventType,
    transactionId:
      verified.transactionId,
    externalClaimReference:
      verified.externalClaimReference,
    providerUserId:
      verified.providerUserId,
    timestampMs:
      verified.timestampMs,
    adNetwork:
      verified.adNetwork,
    adUnit:
      verified.adUnit,
    rewardAmount:
      verified.rewardAmount,
    rewardItem:
      verified.rewardItem,
    keyId:
      verified.keyId,
    signedContentSha256:
      payloadHash,
    signatureVerified:
      true,
  };

  const serviceClient =
    (
      dependencies.getServiceClient ??
      getSupabaseServiceClient
    )();

  const {
    data,
    error,
  } =
    await serviceClient.rpc(
      "register_reward_provider_event_internal",
      {
        p_source_code:
          verified.sourceCode,

        p_provider_event_id:
          verified.providerEventId,

        p_provider_event_type:
          verified.providerEventType,

        p_external_claim_reference:
          verified.externalClaimReference,

        p_payload_hash:
          payloadHash,

        p_payload:
          payload,

        p_signature_verified:
          true,
      },
    );

  if (error) {
    const code =
      typeof error.code === "string"
        ? error.code
        : "";

    const message =
      typeof error.message === "string"
        ? error.message
        : "Provider event registration failed.";

    if (
      code === "23505" ||
      message.includes(
        "REWARD_PROVIDER_EVENT_IDEMPOTENCY_CONFLICT",
      )
    ) {
      throw new Error(
        "ADMOB_PROVIDER_EVENT_IDEMPOTENCY_CONFLICT",
      );
    }

    throw new Error(
      `ADMOB_PROVIDER_EVENT_REGISTRATION_FAILED:${code || "UNKNOWN"}:${message}`,
    );
  }

  if (
    !data ||
    typeof data !== "object" ||
    Array.isArray(data)
  ) {
    throw new Error(
      "ADMOB_PROVIDER_EVENT_RESPONSE_INVALID",
    );
  }

  const response =
    data as ProviderEventRpcPayload;

  const registered =
    requireBoolean(
      response.registered,
      "registered",
    );

  const duplicate =
    requireBoolean(
      response.duplicate,
      "duplicate",
    );

  const eventId =
    requireString(
      response.event_id,
      "event_id",
    );

  const processingStatus =
    requireString(
      response.processing_status,
      "processing_status",
    );

  const signatureVerified =
    requireBoolean(
      response.signature_verified,
      "signature_verified",
    );

  if (!signatureVerified) {
    throw new Error(
      "ADMOB_PROVIDER_EVENT_NOT_SIGNATURE_VERIFIED",
    );
  }

  if (
    processingStatus !==
      "verified" &&
    processingStatus !==
      "processed"
  ) {
    throw new Error(
      `ADMOB_PROVIDER_EVENT_STATUS_INVALID:${processingStatus}`,
    );
  }

  return Object.freeze({
    registered,
    duplicate,
    eventId,
    processingStatus,
    signatureVerified,

    correlationId:
      typeof response.correlation_id ===
        "string" &&
      response.correlation_id.trim()
        ? response.correlation_id.trim()
        : null,

    payloadHash,
  });
}
