import {
  beforeEach,
  describe,
  expect,
  it,
  vi,
} from "vitest";

const mocks = vi.hoisted(() => ({
  callCommercialRuntimeRpc: vi.fn(),
  normalizeCommercialWallet: vi.fn(),
}));

vi.mock("server-only", () => ({}));

vi.mock("../rpc", () => ({
  callCommercialRuntimeRpc:
    mocks.callCommercialRuntimeRpc,
}));

vi.mock("./validation", () => ({
  normalizeCommercialWallet:
    mocks.normalizeCommercialWallet,
}));

import { getMyCommercialWallet } from "./service";

const wallet = {
  available: true as const,
  wallet_id:
    "11111111-1111-4111-8111-111111111111",
  status: "active" as const,
  available_passes: 8,
  lifetime_earned: 15,
  lifetime_consumed: 7,
  lifetime_purchased: 5,
  lifetime_rewarded: 10,
  lifetime_promotional: 0,
  ledger_version: 12,
  server_time: "2026-07-23T18:00:00.000Z",
};

beforeEach(() => {
  vi.clearAllMocks();

  mocks.normalizeCommercialWallet.mockReturnValue(
    wallet,
  );
});

describe("getMyCommercialWallet", () => {
  it("calls the exact public wallet RPC without arguments", async () => {
    const rawPayload = {
      source: "database",
    };

    mocks.callCommercialRuntimeRpc.mockResolvedValue({
      data: rawPayload,
      rpcName: "get_my_commercial_wallet_rpc",
    });

    const result = await getMyCommercialWallet();

    expect(
      mocks.callCommercialRuntimeRpc,
    ).toHaveBeenCalledOnce();

    expect(
      mocks.callCommercialRuntimeRpc,
    ).toHaveBeenCalledWith(
      "get_my_commercial_wallet_rpc",
      {},
    );

    expect(
      mocks.normalizeCommercialWallet,
    ).toHaveBeenCalledOnce();

    expect(
      mocks.normalizeCommercialWallet,
    ).toHaveBeenCalledWith(rawPayload);

    expect(result).toBe(wallet);
  });

  it("propagates an RPC failure without attempting normalization", async () => {
    const failure = new Error("Wallet RPC failed.");

    mocks.callCommercialRuntimeRpc.mockRejectedValue(
      failure,
    );

    await expect(
      getMyCommercialWallet(),
    ).rejects.toBe(failure);

    expect(
      mocks.normalizeCommercialWallet,
    ).not.toHaveBeenCalled();
  });
});
