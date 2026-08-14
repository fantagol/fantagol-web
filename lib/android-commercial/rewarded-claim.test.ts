import {
  beforeEach,
  describe,
  expect,
  it,
  vi,
} from "vitest";

const mocks =
  vi.hoisted(() => ({
    getSession:
      vi.fn(),

    rpc:
      vi.fn(),

    configureSsv:
      vi.fn(),
  }));

vi.mock(
  "@/lib/supabaseClient",
  () => ({
    supabase: {
      auth: {
        getSession:
          mocks.getSession,
      },

      rpc:
        mocks.rpc,
    },
  }),
);

vi.mock(
  "./rewarded-ads",
  () => ({
    configureRewardedAdSsv:
      mocks.configureSsv,
  }),
);

import {
  prepareRewardedAdClaim,
  type RewardedAdClaimAttempt,
} from "./rewarded-claim";

const attempt:
  RewardedAdClaimAttempt = {
    attemptId:
      "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",

    idempotencyKey:
      "rewarded-ad:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",

    externalClaimReference:
      "admob:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
  };

beforeEach(() => {
  vi.clearAllMocks();

  mocks.getSession
    .mockResolvedValue({
      data: {
        session: {
          user: {
            id:
              "11111111-1111-4111-8111-111111111111",
          },
        },
      },

      error:
        null,
    });

  mocks.rpc
    .mockResolvedValue({
      data: {
        submitted:
          true,

        created:
          true,

        claim_id:
          "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",

        claim_status:
          "verification_pending",

        verification_status:
          "pending",

        campaign_code:
          "REWARDED_AD_FOUNDATION",

        source_code:
          "REWARDED_AD",

        passes:
          1,
      },

      error:
        null,
    });

  mocks.configureSsv
    .mockResolvedValue({
      configured:
        true,
    });
});

describe(
  "Android rewarded claim preparation",
  () => {
    it("submits the claim as the authenticated browser user", async () => {
      await prepareRewardedAdClaim(
        attempt,
      );

      expect(
        mocks.rpc,
      ).toHaveBeenCalledWith(
        "submit_my_reward_claim_rpc",
        {
          p_campaign_code:
            "REWARDED_AD_FOUNDATION",

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
    });

    it("configures SSV with authenticated user and exact claim reference", async () => {
      await prepareRewardedAdClaim(
        attempt,
      );

      expect(
        mocks.configureSsv,
      ).toHaveBeenCalledWith({
        userId:
          "11111111-1111-4111-8111-111111111111",

        customData:
          attempt.externalClaimReference,
      });
    });

    it("returns a certified pending rewarded claim", async () => {
      const result =
        await prepareRewardedAdClaim(
          attempt,
        );

      expect(result).toMatchObject({
        prepared:
          true,

        claimId:
          "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",

        campaignCode:
          "REWARDED_AD_FOUNDATION",

        sourceCode:
          "REWARDED_AD",

        claimStatus:
          "verification_pending",

        verificationStatus:
          "pending",

        passes:
          1,
      });
    });

    it("does not configure SSV when campaign is unavailable", async () => {
      mocks.rpc
        .mockResolvedValue({
          data: {
            submitted:
              false,

            error_code:
              "REWARD_CAMPAIGN_NOT_AVAILABLE",
          },

          error:
            null,
        });

      await expect(
        prepareRewardedAdClaim(
          attempt,
        ),
      ).rejects.toThrow(
        "REWARDED_AD_CLAIM_REJECTED:REWARD_CAMPAIGN_NOT_AVAILABLE",
      );

      expect(
        mocks.configureSsv,
      ).not.toHaveBeenCalled();
    });

    it("requires an authenticated user", async () => {
      mocks.getSession
        .mockResolvedValue({
          data: {
            session:
              null,
          },

          error:
            null,
        });

      await expect(
        prepareRewardedAdClaim(
          attempt,
        ),
      ).rejects.toThrow(
        "REWARDED_AD_AUTH_REQUIRED",
      );

      expect(
        mocks.rpc,
      ).not.toHaveBeenCalled();

      expect(
        mocks.configureSsv,
      ).not.toHaveBeenCalled();
    });

    it("rejects an unexpected Pass amount before SSV configuration", async () => {
      mocks.rpc
        .mockResolvedValue({
          data: {
            submitted:
              true,

            created:
              true,

            claim_id:
              "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",

            claim_status:
              "verification_pending",

            verification_status:
              "pending",

            campaign_code:
              "REWARDED_AD_FOUNDATION",

            source_code:
              "REWARDED_AD",

            passes:
              99,
          },

          error:
            null,
        });

      await expect(
        prepareRewardedAdClaim(
          attempt,
        ),
      ).rejects.toThrow(
        "REWARDED_AD_CLAIM_PASS_AMOUNT_INVALID",
      );

      expect(
        mocks.configureSsv,
      ).not.toHaveBeenCalled();
    });

    it("keeps claim submission separate from settlement", async () => {
      await prepareRewardedAdClaim(
        attempt,
      );

      expect(
        mocks.rpc,
      ).toHaveBeenCalledTimes(1);

      expect(
        mocks.rpc.mock.calls[0]?.[0],
      ).toBe(
        "submit_my_reward_claim_rpc",
      );
    });
  },
);
