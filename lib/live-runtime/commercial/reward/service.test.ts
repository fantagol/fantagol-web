import {
  beforeEach,
  describe,
  expect,
  it,
  vi,
} from "vitest";

const mocks = vi.hoisted(() => ({
  callCommercialRuntimeRpc: vi.fn(),
  normalizeRewardCampaigns: vi.fn(),
}));

vi.mock("server-only", () => ({}));

vi.mock("../rpc", () => ({
  callCommercialRuntimeRpc:
    mocks.callCommercialRuntimeRpc,
}));

vi.mock("./validation", () => ({
  normalizeRewardCampaigns:
    mocks.normalizeRewardCampaigns,
}));

import {
  getRewardCampaigns,
} from "./service";

const campaigns = [
  {
    campaign_id:
      "11111111-1111-4111-8111-111111111111",
    campaign_code:
      "LEAGUE_FIRST_ROUND_COMPLETED",
    source_code: "LOYALTY_EVENT",
    title: "Prima giornata completata",
    description: null,
    reward_type: "PASS_REWARD",
    passes_per_claim: 1,
    cooldown_seconds: 0,
    starts_at: null,
    ends_at: null,
    metadata: {},
  },
];

beforeEach(() => {
  vi.clearAllMocks();

  mocks.normalizeRewardCampaigns
    .mockReturnValue(campaigns);
});

describe("getRewardCampaigns", () => {
  it("calls the exact public reward campaign RPC", async () => {
    const rawPayload = [
      {
        source: "database",
      },
    ];

    mocks.callCommercialRuntimeRpc
      .mockResolvedValue({
        data: rawPayload,
        rpcName:
          "get_reward_campaigns_rpc",
      });

    const result =
      await getRewardCampaigns();

    expect(
      mocks.callCommercialRuntimeRpc,
    ).toHaveBeenCalledOnce();

    expect(
      mocks.callCommercialRuntimeRpc,
    ).toHaveBeenCalledWith(
      "get_reward_campaigns_rpc",
      {},
    );

    expect(
      mocks.normalizeRewardCampaigns,
    ).toHaveBeenCalledOnce();

    expect(
      mocks.normalizeRewardCampaigns,
    ).toHaveBeenCalledWith(rawPayload);

    expect(result).toBe(campaigns);
  });

  it("propagates an RPC failure without normalization", async () => {
    const failure = new Error(
      "Reward campaign RPC failed.",
    );

    mocks.callCommercialRuntimeRpc
      .mockRejectedValue(failure);

    await expect(
      getRewardCampaigns(),
    ).rejects.toBe(failure);

    expect(
      mocks.normalizeRewardCampaigns,
    ).not.toHaveBeenCalled();
  });

  it("propagates validation failure after the RPC", async () => {
    const failure = new TypeError(
      "Invalid reward campaign payload.",
    );

    mocks.callCommercialRuntimeRpc
      .mockResolvedValue({
        data: [],
        rpcName:
          "get_reward_campaigns_rpc",
      });

    mocks.normalizeRewardCampaigns
      .mockImplementation(() => {
        throw failure;
      });

    await expect(
      getRewardCampaigns(),
    ).rejects.toBe(failure);

    expect(
      mocks.callCommercialRuntimeRpc,
    ).toHaveBeenCalledOnce();
  });
});
