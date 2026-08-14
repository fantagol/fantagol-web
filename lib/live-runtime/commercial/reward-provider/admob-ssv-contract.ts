import type { JsonObject } from "../json";

export const ADMOB_REWARDED_PROVIDER_CODE =
  "ADMOB_REWARDED";

export const ADMOB_REWARDED_ADAPTER_CODE =
  "ADMOB_REWARDED_SSV_ADAPTER";

export const ADMOB_REWARDED_ADAPTER_VERSION =
  1;

export const ADMOB_REWARDED_SOURCE_CODE =
  "REWARDED_AD";

export const ADMOB_REWARDED_CAMPAIGN_CODE =
  "REWARDED_AD_FOUNDATION";

export const ADMOB_REWARDED_EVENT_TYPE =
  "REWARDED_VIDEO_COMPLETED";

export const ADMOB_REWARDED_SIGNATURE_ALGORITHM =
  "ECDSA_SHA256";

export interface AdMobRewardedSsvCallback
  extends JsonObject {
  readonly ad_network: string;
  readonly ad_unit: string;
  readonly custom_data: string | null;
  readonly key_id: string;
  readonly reward_amount: string;
  readonly reward_item: string;
  readonly signature: string;
  readonly timestamp: string;
  readonly transaction_id: string;
  readonly user_id: string | null;
}

export interface AdMobRewardedSsvIdentity {
  readonly providerEventId: string;
  readonly externalClaimReference:
    string | null;
  readonly providerUserId:
    string | null;
}

function normalizeOptionalValue(
  value:
    | string
    | null
    | undefined,
  maximumLength: number,
): string | null {
  if (
    value === undefined ||
    value === null
  ) {
    return null;
  }

  const normalized =
    value.trim();

  if (!normalized) {
    return null;
  }

  if (
    normalized.length >
    maximumLength
  ) {
    throw new TypeError(
      `AdMob SSV value exceeds ${maximumLength} characters.`,
    );
  }

  return normalized;
}

function requireValue(
  value: string,
  fieldName: string,
  maximumLength: number,
): string {
  const normalized =
    value.trim();

  if (
    !normalized ||
    normalized.length >
      maximumLength
  ) {
    throw new TypeError(
      `AdMob SSV ${fieldName} must contain between 1 and ${maximumLength} characters.`,
    );
  }

  return normalized;
}

export function normalizeAdMobRewardedSsvIdentity(
  callback:
    Pick<
      AdMobRewardedSsvCallback,
      | "transaction_id"
      | "custom_data"
      | "user_id"
    >,
): AdMobRewardedSsvIdentity {
  return Object.freeze({
    providerEventId:
      requireValue(
        callback.transaction_id,
        "transaction_id",
        300,
      ),

    externalClaimReference:
      normalizeOptionalValue(
        callback.custom_data,
        300,
      ),

    providerUserId:
      normalizeOptionalValue(
        callback.user_id,
        300,
      ),
  });
}
