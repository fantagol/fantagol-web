import type { JsonObject } from "../json";

export type CommercialRewardType =
  | "PASS_REWARD"
  | "PASS_PROMOTION"
  | "PASS_GIFT"
  | "PASS_REFERRAL";

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
