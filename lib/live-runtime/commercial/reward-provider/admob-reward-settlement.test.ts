import {
  describe,
  expect,
  it,
  vi,
} from "vitest";

vi.mock("server-only", () => ({}));

vi.mock("@/lib/supabase/service", () => ({
  getSupabaseServiceClient:
    vi.fn(),
}));

import type {
  SupabaseClient,
} from "@supabase/supabase-js";

import type {
  VerifiedAdMobClaimBinding,
} from "./admob-claim-binding";

import {
  AdMobRewardSettlementError,
  settleVerifiedAdMobRewardClaim,
} from "./admob-reward-settlement";

function bindingFixture():
  VerifiedAdMobClaimBinding {
  return {
    claimBindingVerified:
      true,

    claimId:
      "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",

    claimUserId:
      "11111111-1111-4111-8111-111111111111",

    campaignCode:
      "REWARDED_AD_FOUNDATION",

    sourceCode:
      "REWARDED_AD",

    rewardType:
      "PASS_REWARD",

    passesAwarded:
      1,

    claimStatus:
      "verification_pending",

    verificationStatus:
      "pending",

    providerEventDatabaseId:
      "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",

    providerEventId:
      "google-transaction-0001",

    providerEventType:
      "REWARDED_VIDEO_COMPLETED",

    providerEventStatus:
      "verified",

    externalClaimReference:
      "claim-rewarded-0001",
  };
}

function clientFor(
  data: unknown,
  error: unknown = null,
) {
  const rpc =
    vi.fn().mockResolvedValue({
      data,
      error,
    });

  return {
    client:
      {
        rpc,
      } as unknown as
        SupabaseClient,

    rpc,
  };
}

describe(
  "AdMob reward settlement adapter",
  () => {
    it("calls only the canonical atomic settlement RPC", async () => {
      const {
        client,
        rpc,
      } =
        clientFor({
          settled: true,
          already_settled: false,
          claim_id:
            "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
          ledger_id:
            "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
          reward_type:
            "PASS_REWARD",
          passes_awarded:
            1,
          available_passes:
            7,
          settled_at:
            "2026-08-14T19:00:00.000Z",
        });

      const result =
        await settleVerifiedAdMobRewardClaim(
          bindingFixture(),
          {
            getServiceClient:
              () => client,
          },
        );

      expect(rpc).toHaveBeenCalledTimes(1);

      expect(rpc).toHaveBeenCalledWith(
        "settle_reward_claim_internal",
        {
          p_claim_id:
            "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",

          p_provider_event_id:
            "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",

          p_external_claim_reference:
            "claim-rewarded-0001",

          p_metadata:
            expect.objectContaining({
              settlementSource:
                "ADMOB_SSV",

              claimBindingVerified:
                true,

              providerEventId:
                "google-transaction-0001",

              providerEventDatabaseId:
                "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
            }),
        },
      );

      expect(result).toEqual({
        settled: true,
        alreadySettled:
          false,
        claimId:
          "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        ledgerTransactionId:
          "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
        rewardType:
          "PASS_REWARD",
        passesAwarded:
          1,
        availablePasses:
          7,
        settledAt:
          "2026-08-14T19:00:00.000Z",
      });
    });

    it("accepts an idempotent already-settled replay", async () => {
      const {
        client,
      } =
        clientFor({
          settled: true,
          already_settled: true,
          claim_id:
            "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
          ledger_id:
            "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
          passes_awarded:
            1,
        });

      const result =
        await settleVerifiedAdMobRewardClaim(
          bindingFixture(),
          {
            getServiceClient:
              () => client,
          },
        );

      expect(
        result.alreadySettled,
      ).toBe(true);

      expect(
        result.ledgerTransactionId,
      ).toBe(
        "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
      );

      expect(
        result.passesAwarded,
      ).toBe(1);
    });

    it("passes the provider-event database UUID rather than the Google transaction id", async () => {
      const {
        client,
        rpc,
      } =
        clientFor({
          settled: true,
          already_settled: false,
          claim_id:
            "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
          ledger_id:
            "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
          passes_awarded:
            1,
        });

      await settleVerifiedAdMobRewardClaim(
        bindingFixture(),
        {
          getServiceClient:
            () => client,
        },
      );

      const argumentsObject =
        rpc.mock.calls[0]?.[1] as
          Record<string, unknown>;

      expect(
        argumentsObject.p_provider_event_id,
      ).toBe(
        "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
      );

      expect(
        argumentsObject.p_provider_event_id,
      ).not.toBe(
        "google-transaction-0001",
      );
    });

    it("rejects a settlement rejected by campaign/source governance", async () => {
      const {
        client,
      } =
        clientFor({
          settled: false,
          error_code:
            "REWARD_CAMPAIGN_OR_SOURCE_DISABLED",
          claim_id:
            "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        });

      await expect(
        settleVerifiedAdMobRewardClaim(
          bindingFixture(),
          {
            getServiceClient:
              () => client,
          },
        ),
      ).rejects.toMatchObject({
        code:
          "ADMOB_SETTLEMENT_REJECTED",

        settlementErrorCode:
          "REWARD_CAMPAIGN_OR_SOURCE_DISABLED",

        retryable:
          false,
      });
    });

    it("rejects a terminal claim response", async () => {
      const {
        client,
      } =
        clientFor({
          settled: false,
          error_code:
            "REWARD_CLAIM_TERMINAL",
          claim_id:
            "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
          claim_status:
            "rejected",
        });

      await expect(
        settleVerifiedAdMobRewardClaim(
          bindingFixture(),
          {
            getServiceClient:
              () => client,
          },
        ),
      ).rejects.toMatchObject({
        code:
          "ADMOB_SETTLEMENT_REJECTED",
        settlementErrorCode:
          "REWARD_CLAIM_TERMINAL",
      });
    });

    it("preserves database transport errors as retryable when appropriate", async () => {
      const {
        client,
      } =
        clientFor(
          null,
          {
            code:
              "40001",

            message:
              "serialization failure",
          },
        );

      await expect(
        settleVerifiedAdMobRewardClaim(
          bindingFixture(),
          {
            getServiceClient:
              () => client,
          },
        ),
      ).rejects.toMatchObject({
        code:
          "ADMOB_SETTLEMENT_RPC_FAILED",
        retryable:
          true,
        databaseErrorCode:
          "40001",
      });
    });

    it("rejects a mismatched claim id returned by the database", async () => {
      const {
        client,
      } =
        clientFor({
          settled: true,
          already_settled: false,
          claim_id:
            "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
          ledger_id:
            "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
          passes_awarded:
            1,
        });

      await expect(
        settleVerifiedAdMobRewardClaim(
          bindingFixture(),
          {
            getServiceClient:
              () => client,
          },
        ),
      ).rejects.toMatchObject({
        code:
          "ADMOB_SETTLEMENT_RESPONSE_INVALID",
      });
    });

    it("rejects a mismatched Pass amount returned by the database", async () => {
      const {
        client,
      } =
        clientFor({
          settled: true,
          already_settled: false,
          claim_id:
            "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
          ledger_id:
            "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
          passes_awarded:
            99,
        });

      await expect(
        settleVerifiedAdMobRewardClaim(
          bindingFixture(),
          {
            getServiceClient:
              () => client,
          },
        ),
      ).rejects.toMatchObject({
        code:
          "ADMOB_SETTLEMENT_RESPONSE_INVALID",
      });
    });

    it("rejects malformed settlement responses", async () => {
      const {
        client,
      } =
        clientFor(
          "not-json-object",
        );

      await expect(
        settleVerifiedAdMobRewardClaim(
          bindingFixture(),
          {
            getServiceClient:
              () => client,
          },
        ),
      ).rejects.toMatchObject({
        code:
          "ADMOB_SETTLEMENT_RESPONSE_INVALID",
      });
    });

    it("never calls direct ledger or wallet writers", async () => {
      const {
        client,
        rpc,
      } =
        clientFor({
          settled: true,
          already_settled: false,
          claim_id:
            "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
          ledger_id:
            "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
          passes_awarded:
            1,
        });

      await settleVerifiedAdMobRewardClaim(
        bindingFixture(),
        {
          getServiceClient:
            () => client,
        },
      );

      expect(rpc).toHaveBeenCalledTimes(1);

      expect(
        rpc.mock.calls
          .map(
            (call) =>
              call[0],
          ),
      ).toEqual([
        "settle_reward_claim_internal",
      ]);
    });

    it("uses the canonical settlement error type", () => {
      const error =
        new AdMobRewardSettlementError(
          "ADMOB_SETTLEMENT_REJECTED",
          "rejected",
        );

      expect(error.code).toBe(
        "ADMOB_SETTLEMENT_REJECTED",
      );
    });
  },
);
