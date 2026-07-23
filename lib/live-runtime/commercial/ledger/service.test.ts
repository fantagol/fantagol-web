import {
  beforeEach,
  describe,
  expect,
  it,
  vi,
} from "vitest";

const mocks = vi.hoisted(() => ({
  callCommercialRuntimeRpc: vi.fn(),
  normalizeCommercialLedger: vi.fn(),
}));

vi.mock("server-only", () => ({}));

vi.mock("../rpc", () => ({
  callCommercialRuntimeRpc:
    mocks.callCommercialRuntimeRpc,
}));

vi.mock("./validation", () => ({
  normalizeCommercialLedger:
    mocks.normalizeCommercialLedger,
}));

import {
  getMyCommercialLedger,
} from "./service";

const ledger = [
  {
    ledger_id:
      "11111111-1111-4111-8111-111111111111",
    transaction_type: "PASS_REWARD",
    amount: 3,
    balance_before: 5,
    balance_after: 8,
    source_engine: "LOYALTY_REWARD_ENGINE",
    external_reference: "reward-001",
    metadata: {},
    created_at:
      "2026-07-23T20:00:00.000Z",
  },
];

beforeEach(() => {
  vi.clearAllMocks();

  mocks.normalizeCommercialLedger.mockReturnValue(
    ledger,
  );
});

describe("getMyCommercialLedger", () => {
  it("calls the exact ledger RPC with default pagination", async () => {
    const rawPayload = [
      {
        source: "database",
      },
    ];

    mocks.callCommercialRuntimeRpc.mockResolvedValue({
      data: rawPayload,
      rpcName: "get_my_commercial_ledger_rpc",
    });

    const result =
      await getMyCommercialLedger();

    expect(
      mocks.callCommercialRuntimeRpc,
    ).toHaveBeenCalledOnce();

    expect(
      mocks.callCommercialRuntimeRpc,
    ).toHaveBeenCalledWith(
      "get_my_commercial_ledger_rpc",
      {
        p_limit: 50,
        p_offset: 0,
      },
    );

    expect(
      mocks.normalizeCommercialLedger,
    ).toHaveBeenCalledOnce();

    expect(
      mocks.normalizeCommercialLedger,
    ).toHaveBeenCalledWith(rawPayload);

    expect(result).toBe(ledger);
  });

  it("forwards explicit pagination", async () => {
    mocks.callCommercialRuntimeRpc.mockResolvedValue({
      data: [],
      rpcName: "get_my_commercial_ledger_rpc",
    });

    await getMyCommercialLedger({
      limit: 25,
      offset: 50,
    });

    expect(
      mocks.callCommercialRuntimeRpc,
    ).toHaveBeenCalledWith(
      "get_my_commercial_ledger_rpc",
      {
        p_limit: 25,
        p_offset: 50,
      },
    );
  });

  it.each([
    0,
    201,
    1.5,
    Number.MAX_SAFE_INTEGER + 1,
  ])(
    "rejects invalid limit %s before calling the RPC",
    async (limit) => {
      await expect(
        getMyCommercialLedger({
          limit,
        }),
      ).rejects.toThrow(
        "limit must be a safe integer between 1 and 200.",
      );

      expect(
        mocks.callCommercialRuntimeRpc,
      ).not.toHaveBeenCalled();

      expect(
        mocks.normalizeCommercialLedger,
      ).not.toHaveBeenCalled();
    },
  );

  it.each([
    -1,
    1.5,
    Number.MAX_SAFE_INTEGER + 1,
  ])(
    "rejects invalid offset %s before calling the RPC",
    async (offset) => {
      await expect(
        getMyCommercialLedger({
          offset,
        }),
      ).rejects.toThrow(
        "offset must be a non-negative safe integer.",
      );

      expect(
        mocks.callCommercialRuntimeRpc,
      ).not.toHaveBeenCalled();

      expect(
        mocks.normalizeCommercialLedger,
      ).not.toHaveBeenCalled();
    },
  );

  it("propagates an RPC failure without normalization", async () => {
    const failure = new Error(
      "Ledger RPC failed.",
    );

    mocks.callCommercialRuntimeRpc.mockRejectedValue(
      failure,
    );

    await expect(
      getMyCommercialLedger(),
    ).rejects.toBe(failure);

    expect(
      mocks.normalizeCommercialLedger,
    ).not.toHaveBeenCalled();
  });

  it("propagates a validation failure after the RPC", async () => {
    const failure = new TypeError(
      "Invalid ledger payload.",
    );

    mocks.callCommercialRuntimeRpc.mockResolvedValue({
      data: [],
      rpcName: "get_my_commercial_ledger_rpc",
    });

    mocks.normalizeCommercialLedger
      .mockImplementation(() => {
        throw failure;
      });

    await expect(
      getMyCommercialLedger(),
    ).rejects.toBe(failure);

    expect(
      mocks.callCommercialRuntimeRpc,
    ).toHaveBeenCalledOnce();
  });
});
