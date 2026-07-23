import type { JsonObject } from "../json";

export type CommercialRewardType =
  "PASS_REWARD" | "PASS_PROMOTION" | "PASS_GIFT" | "PASS_REFERRAL";

export type CommercialRewardClaimStatus =
  | "submitted"
  | "verification_pending"
  | "verified"
  | "rejected"
  | "settled"
  | "expired";

export type CommercialRewardVerificationStatus =
  "pending" | "processing" | "verified" | "rejected" | "expired";

export type CommercialRewardClaimSubmissionErrorCode =
  | "REWARD_CAMPAIGN_NOT_AVAILABLE"
  | "REWARD_SOURCE_NOT_AVAILABLE"
  | "REWARD_USER_CLAIM_LIMIT_REACHED"
  | "REWARD_CLAIM_COOLDOWN_ACTIVE"
  | "COMMERCIAL_WALLET_NOT_ACTIVE";

export interface CommercialRewardCampaign extends JsonObject {
  campaign_id: string;
  campaign_code: string;
  source_code: string;
  title: string;
  description: string | null;
  reward_type: CommercialRewardType;
  passes_per_claim: number;
  cooldown_seconds: number;
  starts_at: string | null;
  ends_at: string | null;
  metadata: JsonObject;
}

export type CommercialRewardCampaigns = CommercialRewardCampaign[];

export interface CommercialRewardClaim extends JsonObject {
  claim_id: string;
  campaign_code: string;
  source_code: string;
  reward_type: CommercialRewardType;
  passes_awarded: number;
  claim_status: CommercialRewardClaimStatus;
  verification_status: CommercialRewardVerificationStatus;
  submitted_at: string;
  verified_at: string | null;
  rejected_at: string | null;
  settled_at: string | null;
  expired_at: string | null;
}

export type CommercialRewardClaims = CommercialRewardClaim[];

export interface GetMyCommercialRewardClaimsInput {
  limit?: number;
  offset?: number;
}

export interface GetMyCommercialRewardClaimInput {
  claimId: string;
}

export interface CommercialRewardClaimLookupSuccess extends CommercialRewardClaim {
  found: true;
  external_claim_reference: string | null;
  server_time: string;
}

export interface CommercialRewardClaimLookupFailure extends JsonObject {
  found: false;
  error_code: "REWARD_CLAIM_NOT_FOUND";
}

export type CommercialRewardClaimLookupResult =
  CommercialRewardClaimLookupSuccess | CommercialRewardClaimLookupFailure;

export interface SubmitCommercialRewardClaimInput {
  campaignCode: string;
  idempotencyKey: string;
  externalClaimReference?: string | null;
  evidence?: JsonObject;
}

export interface CommercialRewardClaimSubmissionSuccess {
  submitted: true;
  created: boolean;
  claim_id: string;
  claim_status: CommercialRewardClaimStatus;
  verification_status: CommercialRewardVerificationStatus;
  campaign_code: string;
  source_code?: string;
  passes: number;
  server_time: string;
}

export interface CommercialRewardClaimSubmissionFailure {
  submitted: false;
  error_code: CommercialRewardClaimSubmissionErrorCode;
  campaign_code?: string;
  source_code?: string;
  retry_after?: string;
  server_time: string;
}

export type CommercialRewardClaimSubmissionResult =
  | CommercialRewardClaimSubmissionSuccess
  | CommercialRewardClaimSubmissionFailure;
