import "server-only";

import type {
  SupabaseClient,
} from "@supabase/supabase-js";

import {
  getSupabaseServiceClient,
} from "@/lib/supabase/service";

import {
  ADMOB_REWARDED_CAMPAIGN_CODE,
  ADMOB_REWARDED_EVENT_TYPE,
  ADMOB_REWARDED_SOURCE_CODE,
} from "./admob-ssv-contract";

import type {
  VerifiedAdMobRewardedSsv,
} from "./admob-ssv-verifier";

export type AdMobClaimBindingFailureCode =
  | "ADMOB_CLAIM_REFERENCE_REQUIRED"
  | "ADMOB_PROVIDER_USER_ID_REQUIRED"
  | "ADMOB_CLAIM_NOT_FOUND"
  | "ADMOB_CLAIM_LOOKUP_FAILED"
  | "ADMOB_CLAIM_SOURCE_MISMATCH"
  | "ADMOB_CLAIM_CAMPAIGN_MISMATCH"
  | "ADMOB_CLAIM_REWARD_TYPE_MISMATCH"
  | "ADMOB_CLAIM_PASS_AMOUNT_MISMATCH"
  | "ADMOB_CLAIM_OWNER_MISMATCH"
  | "ADMOB_CLAIM_TERMINAL"
  | "ADMOB_CLAIM_LEDGER_ALREADY_ASSIGNED"
  | "ADMOB_PROVIDER_EVENT_NOT_FOUND"
  | "ADMOB_PROVIDER_EVENT_LOOKUP_FAILED"
  | "ADMOB_PROVIDER_EVENT_SOURCE_MISMATCH"
  | "ADMOB_PROVIDER_EVENT_TYPE_MISMATCH"
  | "ADMOB_PROVIDER_EVENT_REFERENCE_MISMATCH"
  | "ADMOB_PROVIDER_EVENT_NOT_VERIFIED"
  | "ADMOB_PROVIDER_EVENT_STATUS_INVALID";

export class AdMobClaimBindingError
  extends Error {
  readonly code:
    AdMobClaimBindingFailureCode;

  readonly retryable: boolean;

  constructor(
    code:
      AdMobClaimBindingFailureCode,
    message: string,
    retryable = false,
  ) {
    super(message);

    this.name =
      "AdMobClaimBindingError";

    this.code = code;
    this.retryable = retryable;
  }
}

interface RewardClaimRow {
  id: string;
  user_id:
    string | null;
  campaign_code: string;
  source_code: string;
  reward_type: string;
  passes_awarded: number;
  claim_status: string;
  verification_status: string;
  external_claim_reference:
    string | null;
  ledger_transaction_id:
    string | null;
}

interface ProviderEventRow {
  id: string;
  source_code: string;
  provider_event_id: string;
  provider_event_type: string;
  external_claim_reference:
    string | null;
  claim_id:
    string | null;
  signature_verified: boolean;
  processing_status: string;
}

export interface VerifiedAdMobClaimBinding {
  readonly claimBindingVerified: true;

  readonly claimId: string;
  readonly claimUserId: string;
  readonly campaignCode:
    typeof ADMOB_REWARDED_CAMPAIGN_CODE;
  readonly sourceCode:
    typeof ADMOB_REWARDED_SOURCE_CODE;

  readonly rewardType:
    "PASS_REWARD";

  readonly passesAwarded: 1;

  readonly claimStatus: string;
  readonly verificationStatus: string;

  readonly providerEventDatabaseId:
    string;

  readonly providerEventId: string;

  readonly providerEventType:
    typeof ADMOB_REWARDED_EVENT_TYPE;

  readonly providerEventStatus:
    string;

  readonly externalClaimReference:
    string;
}

export interface AdMobClaimBindingDependencies {
  readonly getServiceClient?:
    () => SupabaseClient;
}

function requireReference(
  value:
    string | null,
): string {
  const normalized =
    value?.trim() ?? "";

  if (!normalized) {
    throw new AdMobClaimBindingError(
      "ADMOB_CLAIM_REFERENCE_REQUIRED",
      "Verified AdMob SSV callback contains no claim reference.",
      false,
    );
  }

  return normalized;
}

function requireProviderUserId(
  value:
    string | null,
): string {
  const normalized =
    value?.trim() ?? "";

  if (!normalized) {
    throw new AdMobClaimBindingError(
      "ADMOB_PROVIDER_USER_ID_REQUIRED",
      "Verified AdMob SSV callback contains no provider user id.",
      false,
    );
  }

  return normalized;
}

function isTerminalClaimStatus(
  status: string,
): boolean {
  return (
    status === "settled" ||
    status === "rejected" ||
    status === "expired"
  );
}

export async function verifyAdMobClaimOwnershipBinding(
  verified:
    VerifiedAdMobRewardedSsv,
  dependencies:
    AdMobClaimBindingDependencies = {},
): Promise<
  VerifiedAdMobClaimBinding
> {
  const externalClaimReference =
    requireReference(
      verified.externalClaimReference,
    );

  const providerUserId =
    requireProviderUserId(
      verified.providerUserId,
    );

  const serviceClient =
    (
      dependencies.getServiceClient ??
      getSupabaseServiceClient
    )();

  const claimResult =
    await serviceClient
      .from("reward_claims")
      .select(
        [
          "id",
          "user_id",
          "campaign_code",
          "source_code",
          "reward_type",
          "passes_awarded",
          "claim_status",
          "verification_status",
          "external_claim_reference",
          "ledger_transaction_id",
        ].join(","),
      )
      .eq(
        "source_code",
        ADMOB_REWARDED_SOURCE_CODE,
      )
      .eq(
        "external_claim_reference",
        externalClaimReference,
      )
      .maybeSingle();

  if (claimResult.error) {
    throw new AdMobClaimBindingError(
      "ADMOB_CLAIM_LOOKUP_FAILED",
      claimResult.error.message ??
        "Unable to resolve reward claim.",
      true,
    );
  }

  if (!claimResult.data) {
    throw new AdMobClaimBindingError(
      "ADMOB_CLAIM_NOT_FOUND",
      "No rewarded-ad claim matches the verified external reference.",
      false,
    );
  }

  const claim =
    claimResult.data as
      unknown as
      RewardClaimRow;

  if (
    claim.source_code !==
    ADMOB_REWARDED_SOURCE_CODE
  ) {
    throw new AdMobClaimBindingError(
      "ADMOB_CLAIM_SOURCE_MISMATCH",
      "Reward claim source does not match AdMob rewarded source.",
      false,
    );
  }

  if (
    claim.campaign_code !==
    ADMOB_REWARDED_CAMPAIGN_CODE
  ) {
    throw new AdMobClaimBindingError(
      "ADMOB_CLAIM_CAMPAIGN_MISMATCH",
      "Reward claim campaign does not match rewarded-ad campaign.",
      false,
    );
  }

  if (
    claim.reward_type !==
    "PASS_REWARD"
  ) {
    throw new AdMobClaimBindingError(
      "ADMOB_CLAIM_REWARD_TYPE_MISMATCH",
      "Reward claim type is not PASS_REWARD.",
      false,
    );
  }

  if (
    claim.passes_awarded !== 1
  ) {
    throw new AdMobClaimBindingError(
      "ADMOB_CLAIM_PASS_AMOUNT_MISMATCH",
      "Rewarded-ad claim must award exactly one Pass.",
      false,
    );
  }

  if (
    !claim.user_id ||
    claim.user_id !==
      providerUserId
  ) {
    throw new AdMobClaimBindingError(
      "ADMOB_CLAIM_OWNER_MISMATCH",
      "AdMob provider user id does not own the reward claim.",
      false,
    );
  }

  if (
    isTerminalClaimStatus(
      claim.claim_status,
    )
  ) {
    throw new AdMobClaimBindingError(
      "ADMOB_CLAIM_TERMINAL",
      `Reward claim is already terminal: ${claim.claim_status}.`,
      false,
    );
  }

  if (
    claim.ledger_transaction_id !==
    null
  ) {
    throw new AdMobClaimBindingError(
      "ADMOB_CLAIM_LEDGER_ALREADY_ASSIGNED",
      "Non-terminal reward claim already has a ledger transaction.",
      false,
    );
  }

  if (
    claim.external_claim_reference !==
    externalClaimReference
  ) {
    throw new AdMobClaimBindingError(
      "ADMOB_CLAIM_REFERENCE_REQUIRED",
      "Resolved reward claim reference changed unexpectedly.",
      false,
    );
  }

  const providerResult =
    await serviceClient
      .from("reward_provider_events")
      .select(
        [
          "id",
          "source_code",
          "provider_event_id",
          "provider_event_type",
          "external_claim_reference",
          "claim_id",
          "signature_verified",
          "processing_status",
        ].join(","),
      )
      .eq(
        "source_code",
        ADMOB_REWARDED_SOURCE_CODE,
      )
      .eq(
        "provider_event_id",
        verified.providerEventId,
      )
      .maybeSingle();

  if (providerResult.error) {
    throw new AdMobClaimBindingError(
      "ADMOB_PROVIDER_EVENT_LOOKUP_FAILED",
      providerResult.error.message ??
        "Unable to resolve provider event.",
      true,
    );
  }

  if (!providerResult.data) {
    throw new AdMobClaimBindingError(
      "ADMOB_PROVIDER_EVENT_NOT_FOUND",
      "Verified AdMob provider event is not present in the inbox.",
      true,
    );
  }

  const providerEvent =
    providerResult.data as
      unknown as
      ProviderEventRow;

  if (
    providerEvent.source_code !==
    ADMOB_REWARDED_SOURCE_CODE
  ) {
    throw new AdMobClaimBindingError(
      "ADMOB_PROVIDER_EVENT_SOURCE_MISMATCH",
      "Provider event source does not match rewarded-ad source.",
      false,
    );
  }

  if (
    providerEvent.provider_event_type !==
    ADMOB_REWARDED_EVENT_TYPE
  ) {
    throw new AdMobClaimBindingError(
      "ADMOB_PROVIDER_EVENT_TYPE_MISMATCH",
      "Provider event type is not the canonical rewarded completion event.",
      false,
    );
  }

  if (
    providerEvent.external_claim_reference !==
    externalClaimReference
  ) {
    throw new AdMobClaimBindingError(
      "ADMOB_PROVIDER_EVENT_REFERENCE_MISMATCH",
      "Provider event and reward claim external references differ.",
      false,
    );
  }

  if (
    providerEvent.signature_verified !==
    true
  ) {
    throw new AdMobClaimBindingError(
      "ADMOB_PROVIDER_EVENT_NOT_VERIFIED",
      "Provider event is not signature verified.",
      false,
    );
  }

  if (
    providerEvent.processing_status !==
      "verified" &&
    providerEvent.processing_status !==
      "processed"
  ) {
    throw new AdMobClaimBindingError(
      "ADMOB_PROVIDER_EVENT_STATUS_INVALID",
      `Provider event status is not settlement-eligible: ${providerEvent.processing_status}.`,
      false,
    );
  }

  if (
    providerEvent.claim_id !== null &&
    providerEvent.claim_id !==
      claim.id
  ) {
    throw new AdMobClaimBindingError(
      "ADMOB_PROVIDER_EVENT_REFERENCE_MISMATCH",
      "Provider event is already associated with another claim.",
      false,
    );
  }

  return Object.freeze({
    claimBindingVerified:
      true,

    claimId:
      claim.id,

    claimUserId:
      claim.user_id,

    campaignCode:
      ADMOB_REWARDED_CAMPAIGN_CODE,

    sourceCode:
      ADMOB_REWARDED_SOURCE_CODE,

    rewardType:
      "PASS_REWARD",

    passesAwarded:
      1,

    claimStatus:
      claim.claim_status,

    verificationStatus:
      claim.verification_status,

    providerEventDatabaseId:
      providerEvent.id,

    providerEventId:
      providerEvent.provider_event_id,

    providerEventType:
      ADMOB_REWARDED_EVENT_TYPE,

    providerEventStatus:
      providerEvent.processing_status,

    externalClaimReference,
  });
}
