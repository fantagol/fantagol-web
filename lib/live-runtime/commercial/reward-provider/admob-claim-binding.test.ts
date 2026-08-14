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

import {
  AdMobClaimBindingError,
  verifyAdMobClaimOwnershipBinding,
} from "./admob-claim-binding";

import type {
  VerifiedAdMobRewardedSsv,
} from "./admob-ssv-verifier";

function verifiedFixture(
  overrides:
    Partial<
      VerifiedAdMobRewardedSsv
    > = {},
):
  VerifiedAdMobRewardedSsv {
  return {
    verified: true,
    sourceCode:
      "REWARDED_AD",
    providerEventType:
      "REWARDED_VIDEO_COMPLETED",
    providerEventId:
      "transaction-0001",
    externalClaimReference:
      "claim-rewarded-0001",
    providerUserId:
      "11111111-1111-4111-8111-111111111111",
    transactionId:
      "transaction-0001",
    timestampMs:
      1786737600000,
    adNetwork:
      "5450213213286189855",
    adUnit:
      "123456789",
    rewardAmount:
      "1",
    rewardItem:
      "Premium Pass",
    keyId:
      12345,
    rawQuery:
      "raw",
    signedContent:
      "signed",
    ...overrides,
  };
}

const claim = {
  id:
    "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
  user_id:
    "11111111-1111-4111-8111-111111111111",
  campaign_code:
    "REWARDED_AD_FOUNDATION",
  source_code:
    "REWARDED_AD",
  reward_type:
    "PASS_REWARD",
  passes_awarded:
    1,
  claim_status:
    "verification_pending",
  verification_status:
    "pending",
  external_claim_reference:
    "claim-rewarded-0001",
  ledger_transaction_id:
    null,
};

const providerEvent = {
  id:
    "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
  source_code:
    "REWARDED_AD",
  provider_event_id:
    "transaction-0001",
  provider_event_type:
    "REWARDED_VIDEO_COMPLETED",
  external_claim_reference:
    "claim-rewarded-0001",
  claim_id:
    null,
  signature_verified:
    true,
  processing_status:
    "verified",
};

function queryResult(
  data: unknown,
  error: unknown = null,
) {
  return {
    select:
      vi.fn().mockReturnThis(),

    eq:
      vi.fn().mockReturnThis(),

    maybeSingle:
      vi.fn().mockResolvedValue({
        data,
        error,
      }),
  };
}

function serviceClient(
  claimData:
    unknown = claim,
  providerData:
    unknown = providerEvent,
) {
  const claimQuery =
    queryResult(
      claimData,
    );

  const providerQuery =
    queryResult(
      providerData,
    );

  const from =
    vi.fn(
      (table: string) => {
        if (
          table ===
          "reward_claims"
        ) {
          return claimQuery;
        }

        if (
          table ===
          "reward_provider_events"
        ) {
          return providerQuery;
        }

        throw new Error(
          `Unexpected table: ${table}`,
        );
      },
    );

  return {
    client:
      {
        from,
      } as unknown as
        SupabaseClient,

    from,
    claimQuery,
    providerQuery,
  };
}

describe(
  "AdMob claim ownership binding",
  () => {
    it("binds a verified provider event to the owning non-terminal claim", async () => {
      const fixture =
        serviceClient();

      const result =
        await verifyAdMobClaimOwnershipBinding(
          verifiedFixture(),
          {
            getServiceClient:
              () =>
                fixture.client,
          },
        );

      expect(result).toEqual({
        claimBindingVerified:
          true,
        claimId:
          claim.id,
        claimUserId:
          claim.user_id,
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
          providerEvent.id,
        providerEventId:
          "transaction-0001",
        providerEventType:
          "REWARDED_VIDEO_COMPLETED",
        providerEventStatus:
          "verified",
        externalClaimReference:
          "claim-rewarded-0001",
      });

      expect(
        fixture.from,
      ).toHaveBeenCalledWith(
        "reward_claims",
      );

      expect(
        fixture.from,
      ).toHaveBeenCalledWith(
        "reward_provider_events",
      );
    });

    it("rejects an SSV callback with no claim reference", async () => {
      const fixture =
        serviceClient();

      await expect(
        verifyAdMobClaimOwnershipBinding(
          verifiedFixture({
            externalClaimReference:
              null,
          }),
          {
            getServiceClient:
              () =>
                fixture.client,
          },
        ),
      ).rejects.toMatchObject({
        code:
          "ADMOB_CLAIM_REFERENCE_REQUIRED",
      });

      expect(
        fixture.from,
      ).not.toHaveBeenCalled();
    });

    it("rejects an SSV callback with no provider user id", async () => {
      const fixture =
        serviceClient();

      await expect(
        verifyAdMobClaimOwnershipBinding(
          verifiedFixture({
            providerUserId:
              null,
          }),
          {
            getServiceClient:
              () =>
                fixture.client,
          },
        ),
      ).rejects.toMatchObject({
        code:
          "ADMOB_PROVIDER_USER_ID_REQUIRED",
      });
    });

    it("rejects cross-user claim ownership", async () => {
      const fixture =
        serviceClient({
          ...claim,
          user_id:
            "22222222-2222-4222-8222-222222222222",
        });

      await expect(
        verifyAdMobClaimOwnershipBinding(
          verifiedFixture(),
          {
            getServiceClient:
              () =>
                fixture.client,
          },
        ),
      ).rejects.toMatchObject({
        code:
          "ADMOB_CLAIM_OWNER_MISMATCH",
      });
    });

    it.each([
      "settled",
      "rejected",
      "expired",
    ])(
      "rejects terminal claim status %s",
      async (claimStatus) => {
        const fixture =
          serviceClient({
            ...claim,
            claim_status:
              claimStatus,
          });

        await expect(
          verifyAdMobClaimOwnershipBinding(
            verifiedFixture(),
            {
              getServiceClient:
                () =>
                  fixture.client,
            },
          ),
        ).rejects.toMatchObject({
          code:
            "ADMOB_CLAIM_TERMINAL",
        });
      },
    );

    it("rejects a claim with an existing ledger transaction", async () => {
      const fixture =
        serviceClient({
          ...claim,
          ledger_transaction_id:
            "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
        });

      await expect(
        verifyAdMobClaimOwnershipBinding(
          verifiedFixture(),
          {
            getServiceClient:
              () =>
                fixture.client,
          },
        ),
      ).rejects.toMatchObject({
        code:
          "ADMOB_CLAIM_LEDGER_ALREADY_ASSIGNED",
      });
    });

    it("rejects a provider event for another claim reference", async () => {
      const fixture =
        serviceClient(
          claim,
          {
            ...providerEvent,
            external_claim_reference:
              "claim-other",
          },
        );

      await expect(
        verifyAdMobClaimOwnershipBinding(
          verifiedFixture(),
          {
            getServiceClient:
              () =>
                fixture.client,
          },
        ),
      ).rejects.toMatchObject({
        code:
          "ADMOB_PROVIDER_EVENT_REFERENCE_MISMATCH",
      });
    });

    it("rejects a provider event whose signature is not verified", async () => {
      const fixture =
        serviceClient(
          claim,
          {
            ...providerEvent,
            signature_verified:
              false,
            processing_status:
              "received",
          },
        );

      await expect(
        verifyAdMobClaimOwnershipBinding(
          verifiedFixture(),
          {
            getServiceClient:
              () =>
                fixture.client,
          },
        ),
      ).rejects.toMatchObject({
        code:
          "ADMOB_PROVIDER_EVENT_NOT_VERIFIED",
      });
    });

    it("rejects a provider event already linked to another claim", async () => {
      const fixture =
        serviceClient(
          claim,
          {
            ...providerEvent,
            claim_id:
              "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
          },
        );

      await expect(
        verifyAdMobClaimOwnershipBinding(
          verifiedFixture(),
          {
            getServiceClient:
              () =>
                fixture.client,
          },
        ),
      ).rejects.toMatchObject({
        code:
          "ADMOB_PROVIDER_EVENT_REFERENCE_MISMATCH",
      });
    });

    it("does not expose any settlement or ledger result", async () => {
      const fixture =
        serviceClient();

      const result =
        await verifyAdMobClaimOwnershipBinding(
          verifiedFixture(),
          {
            getServiceClient:
              () =>
                fixture.client,
          },
        );

      expect(
        Object.keys(result),
      ).not.toContain(
        "ledgerTransactionId",
      );

      expect(
        Object.keys(result),
      ).not.toContain(
        "settled",
      );
    });

    it("uses the canonical error class", () => {
      const error =
        new AdMobClaimBindingError(
          "ADMOB_CLAIM_NOT_FOUND",
          "missing",
        );

      expect(error.code).toBe(
        "ADMOB_CLAIM_NOT_FOUND",
      );
    });
  },
);
