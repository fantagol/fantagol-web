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

import {
  NextRequest,
} from "next/server";

import {
  AdMobClaimBindingError,
} from "./admob-claim-binding";

import {
  AdMobRewardSettlementError,
} from "./admob-reward-settlement";

import {
  AdMobSsvVerificationError,
  type VerifiedAdMobRewardedSsv,
} from "./admob-ssv-verifier";

import {
  createAdMobSsvGetHandler,
} from "@/app/api/commercial/rewarded-ad/ssv/route";

function verifiedFixture():
  VerifiedAdMobRewardedSsv {
  return {
    verified: true,
    sourceCode:
      "REWARDED_AD",
    providerEventType:
      "REWARDED_VIDEO_COMPLETED",
    providerEventId:
      "google-transaction-0001",
    externalClaimReference:
      "claim-rewarded-0001",
    providerUserId:
      "11111111-1111-4111-8111-111111111111",
    transactionId:
      "google-transaction-0001",
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
  };
}

function registrationFixture() {
  return {
    registered: true,
    duplicate: false,
    eventId:
      "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
    processingStatus:
      "verified",
    signatureVerified:
      true,
    correlationId:
      null,
    payloadHash:
      "a".repeat(64),
  };
}

function bindingFixture() {
  return {
    claimBindingVerified:
      true as const,

    claimId:
      "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",

    claimUserId:
      "11111111-1111-4111-8111-111111111111",

    campaignCode:
      "REWARDED_AD_FOUNDATION" as const,

    sourceCode:
      "REWARDED_AD" as const,

    rewardType:
      "PASS_REWARD" as const,

    passesAwarded:
      1 as const,

    claimStatus:
      "verification_pending",

    verificationStatus:
      "pending",

    providerEventDatabaseId:
      "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",

    providerEventId:
      "google-transaction-0001",

    providerEventType:
      "REWARDED_VIDEO_COMPLETED" as const,

    providerEventStatus:
      "verified",

    externalClaimReference:
      "claim-rewarded-0001",
  };
}

function settlementFixture(
  alreadySettled = false,
) {
  return {
    settled: true as const,

    alreadySettled,

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
  };
}

function request() {
  return new NextRequest(
    "https://fantagol.app/api/commercial/rewarded-ad/ssv?fixture=1",
  );
}

describe(
  "AdMob SSV settlement orchestration",
  () => {
    it("executes verify -> register -> bind -> settle in strict order", async () => {
      const order:
        string[] = [];

      const handler =
        createAdMobSsvGetHandler({
          verify:
            async () => {
              order.push("verify");
              return verifiedFixture();
            },

          register:
            async () => {
              order.push("register");
              return registrationFixture();
            },

          bindClaim:
            async () => {
              order.push("bind");
              return bindingFixture();
            },

          settle:
            async () => {
              order.push("settle");
              return settlementFixture();
            },
        });

      const response =
        await handler(
          request(),
        );

      expect(order).toEqual([
        "verify",
        "register",
        "bind",
        "settle",
      ]);

      expect(response.status).toBe(200);

      expect(
        await response.json(),
      ).toMatchObject({
        verified: true,
        registered: true,
        claimBindingVerified:
          true,
        settled: true,
        alreadySettled:
          false,
        passesAwarded:
          1,
        availablePasses:
          7,
        economicallyAuthoritative:
          true,
      });
    });

    it("never reaches later phases after signature failure", async () => {
      const register =
        vi.fn();

      const bindClaim =
        vi.fn();

      const settle =
        vi.fn();

      const handler =
        createAdMobSsvGetHandler({
          verify:
            async () => {
              throw new AdMobSsvVerificationError(
                "SSV_SIGNATURE_INVALID",
                "invalid",
                false,
              );
            },

          register,
          bindClaim,
          settle,
        });

      const response =
        await handler(
          request(),
        );

      expect(response.status).toBe(400);

      expect(register).not.toHaveBeenCalled();
      expect(bindClaim).not.toHaveBeenCalled();
      expect(settle).not.toHaveBeenCalled();
    });

    it("never binds or settles after provider registration failure", async () => {
      const bindClaim =
        vi.fn();

      const settle =
        vi.fn();

      const handler =
        createAdMobSsvGetHandler({
          verify:
            async () =>
              verifiedFixture(),

          register:
            async () => {
              throw new Error(
                "ADMOB_PROVIDER_EVENT_IDEMPOTENCY_CONFLICT",
              );
            },

          bindClaim,
          settle,
        });

      const response =
        await handler(
          request(),
        );

      expect(response.status).toBe(409);

      expect(bindClaim).not.toHaveBeenCalled();
      expect(settle).not.toHaveBeenCalled();
    });

    it("never settles after ownership binding failure", async () => {
      const settle =
        vi.fn();

      const handler =
        createAdMobSsvGetHandler({
          verify:
            async () =>
              verifiedFixture(),

          register:
            async () =>
              registrationFixture(),

          bindClaim:
            async () => {
              throw new AdMobClaimBindingError(
                "ADMOB_CLAIM_OWNER_MISMATCH",
                "wrong owner",
                false,
              );
            },

          settle,
        });

      const response =
        await handler(
          request(),
        );

      expect(response.status).toBe(409);

      expect(settle).not.toHaveBeenCalled();

      expect(
        await response.json(),
      ).toMatchObject({
        claimBindingVerified:
          false,
        economicallyAuthoritative:
          false,
      });
    });

    it("returns 503 for retryable settlement failures", async () => {
      const handler =
        createAdMobSsvGetHandler({
          verify:
            async () =>
              verifiedFixture(),

          register:
            async () =>
              registrationFixture(),

          bindClaim:
            async () =>
              bindingFixture(),

          settle:
            async () => {
              throw new AdMobRewardSettlementError(
                "ADMOB_SETTLEMENT_RPC_FAILED",
                "serialization failure",
                {
                  retryable:
                    true,
                  databaseErrorCode:
                    "40001",
                },
              );
            },
        });

      const response =
        await handler(
          request(),
        );

      expect(response.status).toBe(503);

      expect(
        await response.json(),
      ).toMatchObject({
        verified: true,
        claimBindingVerified:
          true,
        settled: false,
        retryable: true,
        economicallyAuthoritative:
          false,
      });
    });

    it("returns 409 for permanent settlement rejection", async () => {
      const handler =
        createAdMobSsvGetHandler({
          verify:
            async () =>
              verifiedFixture(),

          register:
            async () =>
              registrationFixture(),

          bindClaim:
            async () =>
              bindingFixture(),

          settle:
            async () => {
              throw new AdMobRewardSettlementError(
                "ADMOB_SETTLEMENT_REJECTED",
                "disabled",
                {
                  retryable:
                    false,

                  settlementErrorCode:
                    "REWARD_CAMPAIGN_OR_SOURCE_DISABLED",
                },
              );
            },
        });

      const response =
        await handler(
          request(),
        );

      expect(response.status).toBe(409);

      expect(
        await response.json(),
      ).toMatchObject({
        settled: false,
        settlementErrorCode:
          "REWARD_CAMPAIGN_OR_SOURCE_DISABLED",
        retryable: false,
        economicallyAuthoritative:
          false,
      });
    });

    it("returns successful HTTP 200 for an idempotent already-settled replay", async () => {
      const handler =
        createAdMobSsvGetHandler({
          verify:
            async () =>
              verifiedFixture(),

          register:
            async () => ({
              ...registrationFixture(),
              registered: false,
              duplicate: true,
            }),

          bindClaim:
            async () =>
              bindingFixture(),

          settle:
            async () =>
              settlementFixture(
                true,
              ),
        });

      const response =
        await handler(
          request(),
        );

      expect(response.status).toBe(200);

      expect(
        await response.json(),
      ).toMatchObject({
        registered: false,
        duplicate: true,
        settled: true,
        alreadySettled:
          true,
        ledgerTransactionId:
          "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
        passesAwarded:
          1,
        economicallyAuthoritative:
          true,
      });
    });

    it("returns economic authority only after settlement succeeds", async () => {
      const handler =
        createAdMobSsvGetHandler({
          verify:
            async () =>
              verifiedFixture(),

          register:
            async () =>
              registrationFixture(),

          bindClaim:
            async () =>
              bindingFixture(),

          settle:
            async () =>
              settlementFixture(),
        });

      const body =
        await (
          await handler(
            request(),
          )
        ).json();

      expect(
        body.economicallyAuthoritative,
      ).toBe(true);

      expect(body.settled).toBe(true);

      expect(
        body.ledgerTransactionId,
      ).toBe(
        "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
      );
    });
  },
);
