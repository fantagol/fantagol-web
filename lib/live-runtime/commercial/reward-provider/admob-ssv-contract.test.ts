import {
  describe,
  expect,
  it,
} from "vitest";

import {
  ADMOB_REWARDED_ADAPTER_CODE,
  ADMOB_REWARDED_ADAPTER_VERSION,
  ADMOB_REWARDED_CAMPAIGN_CODE,
  ADMOB_REWARDED_EVENT_TYPE,
  ADMOB_REWARDED_PROVIDER_CODE,
  ADMOB_REWARDED_SIGNATURE_ALGORITHM,
  ADMOB_REWARDED_SOURCE_CODE,
  normalizeAdMobRewardedSsvIdentity,
} from "./admob-ssv-contract";

describe(
  "AdMob rewarded SSV canonical contract",
  () => {
    it("exposes stable canonical identities", () => {
      expect(
        ADMOB_REWARDED_PROVIDER_CODE,
      ).toBe("ADMOB_REWARDED");

      expect(
        ADMOB_REWARDED_ADAPTER_CODE,
      ).toBe(
        "ADMOB_REWARDED_SSV_ADAPTER",
      );

      expect(
        ADMOB_REWARDED_ADAPTER_VERSION,
      ).toBe(1);

      expect(
        ADMOB_REWARDED_SOURCE_CODE,
      ).toBe("REWARDED_AD");

      expect(
        ADMOB_REWARDED_CAMPAIGN_CODE,
      ).toBe(
        "REWARDED_AD_FOUNDATION",
      );

      expect(
        ADMOB_REWARDED_EVENT_TYPE,
      ).toBe(
        "REWARDED_VIDEO_COMPLETED",
      );

      expect(
        ADMOB_REWARDED_SIGNATURE_ALGORITHM,
      ).toBe("ECDSA_SHA256");
    });

    it("maps AdMob transaction_id to providerEventId", () => {
      expect(
        normalizeAdMobRewardedSsvIdentity({
          transaction_id:
            "18fa792de1bca816048293fc71035638",
          custom_data:
            "claim-11111111-1111-4111-8111-111111111111",
          user_id:
            "11111111-1111-4111-8111-111111111111",
        }),
      ).toEqual({
        providerEventId:
          "18fa792de1bca816048293fc71035638",
        externalClaimReference:
          "claim-11111111-1111-4111-8111-111111111111",
        providerUserId:
          "11111111-1111-4111-8111-111111111111",
      });
    });

    it("accepts absent optional SSV context", () => {
      expect(
        normalizeAdMobRewardedSsvIdentity({
          transaction_id:
            "transaction-0001",
          custom_data: null,
          user_id: null,
        }),
      ).toEqual({
        providerEventId:
          "transaction-0001",
        externalClaimReference:
          null,
        providerUserId: null,
      });
    });

    it("normalizes surrounding whitespace", () => {
      expect(
        normalizeAdMobRewardedSsvIdentity({
          transaction_id:
            "  transaction-0002  ",
          custom_data:
            "  claim-0002  ",
          user_id:
            "  user-0002  ",
        }),
      ).toEqual({
        providerEventId:
          "transaction-0002",
        externalClaimReference:
          "claim-0002",
        providerUserId:
          "user-0002",
      });
    });

    it("rejects an empty transaction identifier", () => {
      expect(() =>
        normalizeAdMobRewardedSsvIdentity({
          transaction_id: "   ",
          custom_data: null,
          user_id: null,
        }),
      ).toThrow(
        "AdMob SSV transaction_id must contain between 1 and 300 characters.",
      );
    });

    it("rejects an oversized transaction identifier", () => {
      expect(() =>
        normalizeAdMobRewardedSsvIdentity({
          transaction_id:
            "x".repeat(301),
          custom_data: null,
          user_id: null,
        }),
      ).toThrow();
    });
  },
);
