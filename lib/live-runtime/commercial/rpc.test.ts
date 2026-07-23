import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  getSupabaseServiceClient: vi.fn(),
  rpc: vi.fn(),
}));

vi.mock("server-only", () => ({}));

vi.mock("@/lib/supabase/service", () => ({
  getSupabaseServiceClient:
    mocks.getSupabaseServiceClient,
}));

import { CommercialRuntimeError } from "./errors";
import { callCommercialRuntimeRpc } from "./rpc";

const RPC_NAME =
  "get_commercial_purchase_runtime_internal";

beforeEach(() => {
  vi.clearAllMocks();

  mocks.getSupabaseServiceClient.mockReturnValue({
    rpc: mocks.rpc,
  });
});

describe("callCommercialRuntimeRpc success contract", () => {
  it("gets the service client exactly once", async () => {
    mocks.rpc.mockResolvedValue({
      data: {
        ok: true,
      },
      error: null,
    });

    await callCommercialRuntimeRpc(RPC_NAME, {});

    expect(
      mocks.getSupabaseServiceClient,
    ).toHaveBeenCalledOnce();
  });

  it("calls the exact RPC with the supplied arguments", async () => {
    const args = {
      p_purchase_id:
        "11111111-1111-4111-8111-111111111111",
      p_include_history: true,
    };

    mocks.rpc.mockResolvedValue({
      data: {
        ok: true,
      },
      error: null,
    });

    await callCommercialRuntimeRpc(RPC_NAME, args);

    expect(mocks.rpc).toHaveBeenCalledOnce();
    expect(mocks.rpc).toHaveBeenCalledWith(
      RPC_NAME,
      args,
    );
  });

  it("preserves the original argument object", async () => {
    const args = {
      nested: {
        source: "control-room",
      },
    };

    mocks.rpc.mockResolvedValue({
      data: null,
      error: null,
    });

    await callCommercialRuntimeRpc(RPC_NAME, args);

    expect(mocks.rpc.mock.calls[0]?.[1]).toBe(args);
  });

  it("returns the data and RPC name without transformation", async () => {
    const payload = {
      purchase: {
        id: "11111111-1111-4111-8111-111111111111",
      },
      authorizations: [],
    };

    mocks.rpc.mockResolvedValue({
      data: payload,
      error: null,
    });

    const result =
      await callCommercialRuntimeRpc<
        typeof payload
      >(RPC_NAME, {});

    expect(result).toEqual({
      data: payload,
      rpcName: RPC_NAME,
    });

    expect(result.data).toBe(payload);
  });

  it("accepts a null RPC payload as successful data", async () => {
    mocks.rpc.mockResolvedValue({
      data: null,
      error: null,
    });

    const result =
      await callCommercialRuntimeRpc<null>(
        RPC_NAME,
        {},
      );

    expect(result).toEqual({
      data: null,
      rpcName: RPC_NAME,
    });
  });

  it("does not treat an undefined error as a failure", async () => {
    const payload = ["event-1", "event-2"];

    mocks.rpc.mockResolvedValue({
      data: payload,
      error: undefined,
    });

    await expect(
      callCommercialRuntimeRpc<string[]>(
        RPC_NAME,
        {},
      ),
    ).resolves.toEqual({
      data: payload,
      rpcName: RPC_NAME,
    });
  });
});

describe("callCommercialRuntimeRpc PostgREST error contract", () => {
  it("converts a PostgREST failure into CommercialRuntimeError", async () => {
    const postgrestError = {
      code: "P0001",
      message: "Purchase runtime failed.",
      details: "Purchase state is inconsistent.",
      hint: "Reconcile the purchase.",
      name: "PostgrestError",
    };

    mocks.rpc.mockResolvedValue({
      data: null,
      error: postgrestError,
    });

    let thrown: unknown;

    try {
      await callCommercialRuntimeRpc(
        RPC_NAME,
        {},
      );
    } catch (error) {
      thrown = error;
    }

    expect(thrown).toBeInstanceOf(
      CommercialRuntimeError,
    );
    expect(thrown).toMatchObject({
      name: "CommercialRuntimeError",
      message: "Purchase runtime failed.",
      rpcName: RPC_NAME,
      code: "P0001",
      details: "Purchase state is inconsistent.",
      hint: "Reconcile the purchase.",
      causeValue: postgrestError,
    });
  });

  it("preserves the original PostgREST error as causeValue", async () => {
    const postgrestError = {
      code: "23505",
      message: "Duplicate runtime record.",
      details: null,
      hint: null,
      name: "PostgrestError",
    };

    mocks.rpc.mockResolvedValue({
      data: null,
      error: postgrestError,
    });

    await expect(
      callCommercialRuntimeRpc(
        RPC_NAME,
        {},
      ),
    ).rejects.toMatchObject({
      causeValue: postgrestError,
    });
  });

  it("uses the deterministic fallback for an empty message", async () => {
    const postgrestError = {
      code: "P0001",
      message: "",
      details: null,
      hint: null,
      name: "PostgrestError",
    };

    mocks.rpc.mockResolvedValue({
      data: null,
      error: postgrestError,
    });

    await expect(
      callCommercialRuntimeRpc(
        RPC_NAME,
        {},
      ),
    ).rejects.toMatchObject({
      message:
        `Commercial runtime RPC ${RPC_NAME} failed.`,
      rpcName: RPC_NAME,
    });
  });

  it("normalizes absent optional error fields to null", async () => {
    const postgrestError = {
      code: undefined,
      message: "Runtime unavailable.",
      details: undefined,
      hint: undefined,
      name: "PostgrestError",
    };

    mocks.rpc.mockResolvedValue({
      data: null,
      error: postgrestError,
    });

    await expect(
      callCommercialRuntimeRpc(
        RPC_NAME,
        {},
      ),
    ).rejects.toMatchObject({
      code: null,
      details: null,
      hint: null,
    });
  });

  it("prefers the error branch even when data is present", async () => {
    const postgrestError = {
      code: "P0001",
      message: "Rejected database result.",
      details: null,
      hint: null,
      name: "PostgrestError",
    };

    mocks.rpc.mockResolvedValue({
      data: {
        shouldNotBeReturned: true,
      },
      error: postgrestError,
    });

    await expect(
      callCommercialRuntimeRpc(
        RPC_NAME,
        {},
      ),
    ).rejects.toBeInstanceOf(
      CommercialRuntimeError,
    );
  });
});

describe("callCommercialRuntimeRpc client failure propagation", () => {
  it("propagates service client construction failures unchanged", async () => {
    const clientError = new Error(
      "Supabase service configuration missing.",
    );

    mocks.getSupabaseServiceClient.mockImplementation(
      () => {
        throw clientError;
      },
    );

    await expect(
      callCommercialRuntimeRpc(
        RPC_NAME,
        {},
      ),
    ).rejects.toBe(clientError);

    expect(mocks.rpc).not.toHaveBeenCalled();
  });

  it("propagates RPC invocation failures unchanged", async () => {
    const invocationError = new Error(
      "Network request failed.",
    );

    mocks.rpc.mockRejectedValue(invocationError);

    await expect(
      callCommercialRuntimeRpc(
        RPC_NAME,
        {},
      ),
    ).rejects.toBe(invocationError);
  });
});
