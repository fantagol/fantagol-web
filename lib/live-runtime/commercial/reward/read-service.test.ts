import { beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));

const callCommercialRuntimeRpcMock = vi.hoisted(() => vi.fn());

vi.mock("../rpc", () => ({
  callCommercialRuntimeRpc: callCommercialRuntimeRpcMock,
}));

import { getMyRewardClaim, getMyRewardClaims } from "./service";

const CLAIM_ID = "11111111-1111-4111-8111-111111111111";

const CLAIM = {
  claim_id: CLAIM_ID,
  campaign_code: "LOYALTY_REWARD",
  source_code: "PROMOTION",
  reward_type: "PASS_REWARD",
  passes_awarded: 1,
  claim_status: "submitted",
  verification_status: "pending",
  submitted_at: "2026-07-23T20:00:00.000Z",
  verified_at: null,
  rejected_at: null,
  settled_at: null,
  expired_at: null,
};

describe("reward claim read service", () => {
  beforeEach(() => {
    callCommercialRuntimeRpcMock.mockReset();
  });

  it("gets claims with canonical defaults", async () => {
    callCommercialRuntimeRpcMock.mockResolvedValue({
      data: [CLAIM],
      rpcName: "get_my_reward_claims_rpc",
    });

    await expect(getMyRewardClaims()).resolves.toEqual([CLAIM]);

    expect(callCommercialRuntimeRpcMock).toHaveBeenCalledWith(
      "get_my_reward_claims_rpc",
      {
        p_limit: 50,
        p_offset: 0,
      },
    );
  });

  it("passes validated pagination values", async () => {
    callCommercialRuntimeRpcMock.mockResolvedValue({
      data: [],
      rpcName: "get_my_reward_claims_rpc",
    });

    await getMyRewardClaims({
      limit: 25,
      offset: 50,
    });

    expect(callCommercialRuntimeRpcMock).toHaveBeenCalledWith(
      "get_my_reward_claims_rpc",
      {
        p_limit: 25,
        p_offset: 50,
      },
    );
  });

  it("rejects invalid pagination before RPC execution", async () => {
    await expect(
      getMyRewardClaims({
        limit: 201,
      }),
    ).rejects.toThrow("limit must be a safe integer between 1 and 200.");

    expect(callCommercialRuntimeRpcMock).not.toHaveBeenCalled();
  });

  it("gets a single claim by UUID", async () => {
    callCommercialRuntimeRpcMock.mockResolvedValue({
      data: {
        found: true,
        ...CLAIM,
        external_claim_reference: null,
        server_time: "2026-07-23T20:01:00.000Z",
      },
      rpcName: "get_my_reward_claim_rpc",
    });

    await expect(
      getMyRewardClaim({
        claimId: CLAIM_ID,
      }),
    ).resolves.toMatchObject({
      found: true,
      claim_id: CLAIM_ID,
    });

    expect(callCommercialRuntimeRpcMock).toHaveBeenCalledWith(
      "get_my_reward_claim_rpc",
      {
        p_claim_id: CLAIM_ID,
      },
    );
  });

  it("preserves the not-found result", async () => {
    callCommercialRuntimeRpcMock.mockResolvedValue({
      data: {
        found: false,
        error_code: "REWARD_CLAIM_NOT_FOUND",
      },
      rpcName: "get_my_reward_claim_rpc",
    });

    await expect(
      getMyRewardClaim({
        claimId: CLAIM_ID,
      }),
    ).resolves.toEqual({
      found: false,
      error_code: "REWARD_CLAIM_NOT_FOUND",
    });
  });

  it("rejects invalid claim identifiers before RPC execution", async () => {
    await expect(
      getMyRewardClaim({
        claimId: "invalid",
      }),
    ).rejects.toThrow("claimId must be a valid UUID.");

    expect(callCommercialRuntimeRpcMock).not.toHaveBeenCalled();
  });
});
