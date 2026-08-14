import {
  supabase,
} from "@/lib/supabaseClient";

import {
  configureRewardedAdSsv,
} from "./rewarded-ads";

export const REWARDED_AD_CAMPAIGN_CODE =
  "REWARDED_AD_FOUNDATION";

export interface RewardedAdClaimAttempt {
  readonly attemptId: string;
  readonly idempotencyKey: string;
  readonly externalClaimReference: string;
}

export interface PreparedRewardedAdClaim {
  readonly prepared: true;

  readonly userId: string;
  readonly claimId: string;

  readonly claimStatus:
    "verification_pending";

  readonly verificationStatus:
    "pending";

  readonly campaignCode:
    typeof REWARDED_AD_CAMPAIGN_CODE;

  readonly sourceCode:
    "REWARDED_AD";

  readonly passes:
    1;

  readonly idempotencyKey: string;
  readonly externalClaimReference: string;

  readonly created: boolean;
}

type RewardClaimRpcResponse = {
  submitted?: unknown;
  created?: unknown;
  claim_id?: unknown;
  claim_status?: unknown;
  verification_status?: unknown;
  campaign_code?: unknown;
  source_code?: unknown;
  passes?: unknown;
  error_code?: unknown;
};

function randomUuid(): string {
  if (
    typeof globalThis.crypto ===
      "undefined" ||
    typeof globalThis.crypto.randomUUID !==
      "function"
  ) {
    throw new Error(
      "REWARDED_AD_SECURE_UUID_UNAVAILABLE",
    );
  }

  return globalThis.crypto.randomUUID();
}

export function createRewardedAdClaimAttempt():
  RewardedAdClaimAttempt {
  const attemptId =
    randomUuid();

  return Object.freeze({
    attemptId,

    idempotencyKey:
      `rewarded-ad:${attemptId}`,

    externalClaimReference:
      `admob:${attemptId}`,
  });
}

function requireRpcString(
  value: unknown,
  field: string,
): string {
  if (
    typeof value !== "string" ||
    !value.trim()
  ) {
    throw new Error(
      `REWARDED_AD_CLAIM_RESPONSE_INVALID:${field}`,
    );
  }

  return value.trim();
}

export async function prepareRewardedAdClaim(
  attempt:
    RewardedAdClaimAttempt =
      createRewardedAdClaimAttempt(),
): Promise<
  PreparedRewardedAdClaim
> {
  const {
    data: {
      session,
    },
    error:
      sessionError,
  } =
    await supabase.auth.getSession();

  if (sessionError) {
    throw new Error(
      `REWARDED_AD_SESSION_FAILED:${sessionError.message}`,
    );
  }

  const user =
    session?.user;

  if (!user?.id) {
    throw new Error(
      "REWARDED_AD_AUTH_REQUIRED",
    );
  }

  const {
    data,
    error,
  } =
    await supabase.rpc(
      "submit_my_reward_claim_rpc",
      {
        p_campaign_code:
          REWARDED_AD_CAMPAIGN_CODE,

        p_idempotency_key:
          attempt.idempotencyKey,

        p_external_claim_reference:
          attempt.externalClaimReference,

        p_evidence: {
          provider:
            "ADMOB",

          platform:
            "ANDROID",

          verification:
            "SSV",

          attempt_id:
            attempt.attemptId,
        },
      },
    );

  if (error) {
    throw new Error(
      `REWARDED_AD_CLAIM_RPC_FAILED:${error.code ?? "UNKNOWN"}:${error.message}`,
    );
  }

  if (
    !data ||
    typeof data !== "object" ||
    Array.isArray(data)
  ) {
    throw new Error(
      "REWARDED_AD_CLAIM_RESPONSE_INVALID",
    );
  }

  const payload =
    data as
      RewardClaimRpcResponse;

  if (payload.submitted !== true) {
    const errorCode =
      typeof payload.error_code ===
        "string"
        ? payload.error_code
        : "UNKNOWN";

    throw new Error(
      `REWARDED_AD_CLAIM_REJECTED:${errorCode}`,
    );
  }

  const claimId =
    requireRpcString(
      payload.claim_id,
      "claim_id",
    );

  const campaignCode =
    requireRpcString(
      payload.campaign_code,
      "campaign_code",
    );

  const sourceCode =
    requireRpcString(
      payload.source_code,
      "source_code",
    );

  const claimStatus =
    requireRpcString(
      payload.claim_status,
      "claim_status",
    );

  const verificationStatus =
    requireRpcString(
      payload.verification_status,
      "verification_status",
    );

  if (
    campaignCode !==
      REWARDED_AD_CAMPAIGN_CODE
  ) {
    throw new Error(
      "REWARDED_AD_CLAIM_CAMPAIGN_MISMATCH",
    );
  }

  if (
    sourceCode !==
      "REWARDED_AD"
  ) {
    throw new Error(
      "REWARDED_AD_CLAIM_SOURCE_MISMATCH",
    );
  }

  if (
    claimStatus !==
      "verification_pending"
  ) {
    throw new Error(
      "REWARDED_AD_CLAIM_STATUS_INVALID",
    );
  }

  if (
    verificationStatus !==
      "pending"
  ) {
    throw new Error(
      "REWARDED_AD_CLAIM_VERIFICATION_STATUS_INVALID",
    );
  }

  if (
    payload.passes !== 1
  ) {
    throw new Error(
      "REWARDED_AD_CLAIM_PASS_AMOUNT_INVALID",
    );
  }

  await configureRewardedAdSsv({
    userId:
      user.id,

    customData:
      attempt.externalClaimReference,
  });

  return Object.freeze({
    prepared:
      true,

    userId:
      user.id,

    claimId,

    claimStatus:
      "verification_pending",

    verificationStatus:
      "pending",

    campaignCode:
      REWARDED_AD_CAMPAIGN_CODE,

    sourceCode:
      "REWARDED_AD",

    passes:
      1,

    idempotencyKey:
      attempt.idempotencyKey,

    externalClaimReference:
      attempt.externalClaimReference,

    created:
      payload.created === true,
  });
}
