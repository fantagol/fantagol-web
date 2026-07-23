import type { JsonObject } from "../json";

export type CommercialRewardType =
  | "PASS_REWARD"
  | "PASS_PROMOTION"
  | "PASS_GIFT"
  | "PASS_REFERRAL";

export type CommercialRewardClaimStatus =
  | "submitted"
  | "verification_pending"
  | "verified"
  | "rejected"
  | "settled"
  | "expired";

export type CommercialRewardVerificationStatus =
  | "pending"
  | "processing"
  | "verified"
  | "rejected"
  | "expired";

export type CommercialRewardClaimSubmissionErrorCode =
  | "REWARD_CAMPAIGN_NOT_AVAILABLE"
  | "REWARD_SOURCE_NOT_AVAILABLE"
  | "REWARD_USER_CLAIM_LIMIT_REACHED"
  | "REWARD_CLAIM_COOLDOWN_ACTIVE"
  | "COMMERCIAL_WALLET_NOT_ACTIVE";

export interface CommercialRewardCampaign
  extends JsonObject {
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

export type CommercialRewardCampaigns =
  CommercialRewardCampaign[];

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
  verification_status:
    CommercialRewardVerificationStatus;
  campaign_code: string;
  source_code?: string;
  passes: number;
  server_time: string;
}

export interface CommercialRewardClaimSubmissionFailure {
  submitted: false;
  error_code:
    CommercialRewardClaimSubmissionErrorCode;
  campaign_code?: string;
  source_code?: string;
  retry_after?: string;
  server_time: string;
}

export type CommercialRewardClaimSubmissionResult =
  | CommercialRewardClaimSubmissionSuccess
  | CommercialRewardClaimSubmissionFailure;
