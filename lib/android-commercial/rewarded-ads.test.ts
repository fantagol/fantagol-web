import {
  describe,
  expect,
  it,
} from "vitest";

import type {
  FantaGolRewardedAdsStatus,
  FantaGolRewardedSsvOptions,
  FantaGolRewardEarnedEvent,
} from "./rewarded-ads";

describe(
  "FantaGol Android rewarded ads bridge contract",
  () => {
    it("keeps the SSV reference explicit", () => {
      const options:
        FantaGolRewardedSsvOptions = {
          userId:
            "11111111-1111-4111-8111-111111111111",
          customData:
            "claim-11111111-1111-4111-8111-111111111111",
        };

      expect(options.userId).toContain(
        "11111111",
      );

      expect(options.customData).toContain(
        "claim-",
      );
    });

    it("models test-mode native status", () => {
      const status:
        FantaGolRewardedAdsStatus = {
          mobileAdsInitialized: true,
          rewardedReady: false,
          testMode: true,
          adUnitId:
            "ca-app-pub-3940256099942544/5224354917",
          canRequestAds: true,
        };

      expect(status.testMode).toBe(true);

      expect(status.adUnitId).toBe(
        "ca-app-pub-3940256099942544/5224354917",
      );
    });

    it("models rewardEarned as non-authoritative", () => {
      const event:
        FantaGolRewardEarnedEvent = {
          amount: 1,
          type: "reward",
          testMode: true,
          economicallyAuthoritative:
            false,
        };

      expect(
        event.economicallyAuthoritative,
      ).toBe(false);

      expect(event.amount).toBe(1);

      expect(event.testMode).toBe(true);
    });

    it("keeps rewarded lifecycle separated from Pass settlement", () => {
      const lifecycleEvents = [
        "rewardedShown",
        "rewardEarned",
        "rewardedDismissed",
        "rewardedShowFailed",
      ];

      expect(lifecycleEvents).toContain(
        "rewardEarned",
      );

      expect(lifecycleEvents).not.toContain(
        "passCredited",
      );
    });
  },
);
