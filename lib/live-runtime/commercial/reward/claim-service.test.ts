import {
  beforeEach,
  describe,
  expect,
  it,
  vi,
} from "vitest";

const mocks = vi.hoisted(() => ({
  callCommercialRuntimeRpc: vi.fn(),
  normalizeResult: vi.fn(),
}));

vi.mock("server-only", () => ({}));

vi.mock("../rpc", () => ({
  callCommercialRuntimeRpc:
    mocks.callCommercialRuntimeRpc,
}));

vi.mock("./validation", async () => {
  const actual =
    await vi.importActual<
      typeof import("./validation")
    >("./validation");

  return {
    ...actual,
    normalizeRewardClaimSubmissionResult:
      mocks.normalizeResult,
  };
});

import {
  submitMyRewardClaim,
} from "./service";

const result = {
  submitted: true as const,
  created: true,
  claim_id:
    "11111111-1111-4111-8111-111111111111",
  claim_status:
    "verification_pending" as const,
  verification_status: "pending" as const,
  campaign_code:
    "LEAGUE_FIRST_ROUND_COMPLETED",
  source_code: "LOYALTY_EVENT",
  passes: 1,
  server_time:
    "2026-07-23T21:00:00.000Z",
};

beforeEach(() => {
  vi.clearAllMocks();

  mocks.normalizeResult.mockReturnValue(
    result,
  );
});

describe("submitMyRewardClaim", () => {
  it("calls the exact claim RPC with normalized arguments", async () => {
    const evidence = {
      league_id:
        "22222222-2222-4222-8222-222222222222",
      verified_event:
        "FIRST_ROUND_COMPLETED",
    };

    const rawPayload = {
      source: "database",
    };

    mocks.callCommercialRuntimeRpc
      .mockResolvedValue({
        data: rawPayload,
        rpcName:
          "submit_my_reward_claim_rpc",
      });

    const returned =
      await submitMyRewardClaim({
        campaignCode:
          " league_first_round_completed ",
        idempotencyKey:
          " reward-claim-0001 ",
        externalClaimReference:
          " external-claim-001 ",
        evidence,
      });

    expect(
      mocks.callCommercialRuntimeRpc,
    ).toHaveBeenCalledOnce();

    expect(
      mocks.callCommercialRuntimeRpc,
    ).toHaveBeenCalledWith(
      "submit_my_reward_claim_rpc",
      {
        p_campaign_code:
          "LEAGUE_FIRST_ROUND_COMPLETED",
        p_idempotency_key:
          "reward-claim-0001",
        p_external_claim_reference:
          "external-claim-001",
        p_evidence: evidence,
      },
    );

    expect(
      mocks.normalizeResult,
    ).toHaveBeenCalledWith(rawPayload);

    expect(returned).toBe(result);
  });

  it("uses null reference and empty evidence by default", async () => {
    mocks.callCommercialRuntimeRpc
      .mockResolvedValue({
        data: result,
        rpcName:
          "submit_my_reward_claim_rpc",
      });

    await submitMyRewardClaim({
      campaignCode: "PASS_REWARD_EVENT",
      idempotencyKey: "claim-key-0001",
    });

    expect(
      mocks.callCommercialRuntimeRpc,
    ).toHaveBeenCalledWith(
      "submit_my_reward_claim_rpc",
      {
        p_campaign_code:
          "PASS_REWARD_EVENT",
        p_idempotency_key:
          "claim-key-0001",
        p_external_claim_reference: null,
        p_evidence: {},
      },
    );
  });

  it("rejects an invalid campaign code before the RPC", async () => {
    await expect(
      submitMyRewardClaim({
        campaignCode: "invalid-code",
        idempotencyKey:
          "claim-key-0001",
      }),
    ).rejects.toThrow(
      "campaignCode must be a valid uppercase code.",
    );

    expect(
      mocks.callCommercialRuntimeRpc,
    ).not.toHaveBeenCalled();
  });

  it.each([
    "short",
    " ".repeat(8),
    "x".repeat(201),
  ])(
    "rejects invalid idempotency key",
    async (idempotencyKey) => {
      await expect(
        submitMyRewardClaim({
          campaignCode:
            "PASS_REWARD_EVENT",
          idempotencyKey,
        }),
      ).rejects.toThrow(
        "idempotencyKey must contain between 8 and 200 characters.",
      );

      expect(
        mocks.callCommercialRuntimeRpc,
      ).not.toHaveBeenCalled();
    },
  );

  it("rejects an empty external reference before the RPC", async () => {
    await expect(
      submitMyRewardClaim({
        campaignCode:
          "PASS_REWARD_EVENT",
        idempotencyKey:
          "claim-key-0001",
        externalClaimReference: "   ",
      }),
    ).rejects.toThrow(
      "externalClaimReference must contain between 1 and 300 characters when present.",
    );

    expect(
      mocks.callCommercialRuntimeRpc,
    ).not.toHaveBeenCalled();
  });

  it("rejects an oversized external reference", async () => {
    await expect(
      submitMyRewardClaim({
        campaignCode:
          "PASS_REWARD_EVENT",
        idempotencyKey:
          "claim-key-0001",
        externalClaimReference:
          "x".repeat(301),
      }),
    ).rejects.toThrow(
      "externalClaimReference must contain between 1 and 300 characters when present.",
    );
  });

  it("propagates RPC failure without result normalization", async () => {
    const failure = new Error(
      "Reward claim RPC failed.",
    );

    mocks.callCommercialRuntimeRpc
      .mockRejectedValue(failure);

    await expect(
      submitMyRewardClaim({
        campaignCode:
          "PASS_REWARD_EVENT",
        idempotencyKey:
          "claim-key-0001",
      }),
    ).rejects.toBe(failure);

    expect(
      mocks.normalizeResult,
    ).not.toHaveBeenCalled();
  });

  it("propagates result validation failure", async () => {
    const failure = new TypeError(
      "Invalid reward claim result.",
    );

    mocks.callCommercialRuntimeRpc
      .mockResolvedValue({
        data: {},
        rpcName:
          "submit_my_reward_claim_rpc",
      });

    mocks.normalizeResult
      .mockImplementation(() => {
        throw failure;
      });

    await expect(
      submitMyRewardClaim({
        campaignCode:
          "PASS_REWARD_EVENT",
        idempotencyKey:
          "claim-key-0001",
      }),
    ).rejects.toBe(failure);
  });
});
