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
  hashVerifiedAdMobSignedContent,
  registerVerifiedAdMobProviderEvent,
} from "./admob-provider-event-registration";

import type {
  VerifiedAdMobRewardedSsv,
} from "./admob-ssv-verifier";

function verifiedFixture():
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
      "claim-0001",
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
      "raw-query",
    signedContent:
      "transaction_id=transaction-0001&reward_amount=1",
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
  "AdMob verified provider event registration",
  () => {
    it("uses deterministic SHA-256 over verified signedContent", () => {
      expect(
        hashVerifiedAdMobSignedContent(
          "abc",
        ),
      ).toBe(
        "ba7816bf8f01cfea414140de5dae2223" +
        "b00361a396177a9cb410ff61f20015ad",
      );
    });

    it("calls exactly the canonical reward-provider registration RPC", async () => {
      const {
        client,
        rpc,
      } =
        clientFor({
          registered: true,
          duplicate: false,
          event_id:
            "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
          processing_status:
            "verified",
          signature_verified:
            true,
          correlation_id:
            "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
        });

      const verified =
        verifiedFixture();

      const result =
        await registerVerifiedAdMobProviderEvent(
          verified,
          {
            getServiceClient:
              () => client,
          },
        );

      expect(rpc).toHaveBeenCalledTimes(1);

      expect(rpc).toHaveBeenCalledWith(
        "register_reward_provider_event_internal",
        expect.objectContaining({
          p_source_code:
            "REWARDED_AD",
          p_provider_event_id:
            "transaction-0001",
          p_provider_event_type:
            "REWARDED_VIDEO_COMPLETED",
          p_external_claim_reference:
            "claim-0001",
          p_signature_verified:
            true,
        }),
      );

      const rpcArgs =
        rpc.mock.calls[0]?.[1] as
          Record<string, unknown>;

      expect(
        rpcArgs.p_payload_hash,
      ).toBe(
        hashVerifiedAdMobSignedContent(
          verified.signedContent,
        ),
      );

      expect(result).toMatchObject({
        registered: true,
        duplicate: false,
        processingStatus:
          "verified",
        signatureVerified:
          true,
      });
    });

    it("accepts an idempotent duplicate returned by the database", async () => {
      const {
        client,
      } =
        clientFor({
          registered: false,
          duplicate: true,
          event_id:
            "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
          processing_status:
            "verified",
          signature_verified:
            true,
        });

      const result =
        await registerVerifiedAdMobProviderEvent(
          verifiedFixture(),
          {
            getServiceClient:
              () => client,
          },
        );

      expect(result.registered).toBe(false);
      expect(result.duplicate).toBe(true);
    });

    it("converts database idempotency conflicts into a stable server error", async () => {
      const {
        client,
      } =
        clientFor(
          null,
          {
            code: "23505",
            message:
              "REWARD_PROVIDER_EVENT_IDEMPOTENCY_CONFLICT",
          },
        );

      await expect(
        registerVerifiedAdMobProviderEvent(
          verifiedFixture(),
          {
            getServiceClient:
              () => client,
          },
        ),
      ).rejects.toThrow(
        "ADMOB_PROVIDER_EVENT_IDEMPOTENCY_CONFLICT",
      );
    });

    it("rejects a database response that is not signature verified", async () => {
      const {
        client,
      } =
        clientFor({
          registered: true,
          duplicate: false,
          event_id:
            "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
          processing_status:
            "received",
          signature_verified:
            false,
        });

      await expect(
        registerVerifiedAdMobProviderEvent(
          verifiedFixture(),
          {
            getServiceClient:
              () => client,
          },
        ),
      ).rejects.toThrow(
        "ADMOB_PROVIDER_EVENT_NOT_SIGNATURE_VERIFIED",
      );
    });

    it("contains no settlement capability in its returned contract", async () => {
      const {
        client,
      } =
        clientFor({
          registered: true,
          duplicate: false,
          event_id:
            "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
          processing_status:
            "verified",
          signature_verified:
            true,
        });

      const result =
        await registerVerifiedAdMobProviderEvent(
          verifiedFixture(),
          {
            getServiceClient:
              () => client,
          },
        );

      expect(
        Object.keys(result),
      ).not.toContain(
        "passesAwarded",
      );

      expect(
        Object.keys(result),
      ).not.toContain(
        "ledgerTransactionId",
      );
    });
  },
);
