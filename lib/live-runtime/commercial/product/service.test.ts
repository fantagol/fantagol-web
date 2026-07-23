import {
  beforeEach,
  describe,
  expect,
  it,
  vi,
} from "vitest";

const mocks = vi.hoisted(() => ({
  callCommercialRuntimeRpc: vi.fn(),
  normalizeCommercialProducts: vi.fn(),
}));

vi.mock("server-only", () => ({}));

vi.mock("../rpc", () => ({
  callCommercialRuntimeRpc:
    mocks.callCommercialRuntimeRpc,
}));

vi.mock("./validation", () => ({
  normalizeCommercialProducts:
    mocks.normalizeCommercialProducts,
}));

import {
  getCommercialProducts,
} from "./service";

const products = [
  {
    product_id:
      "11111111-1111-4111-8111-111111111111",
    product_code: "PASS_10",
    title: "10 Pass",
    description: "Pacchetto da 10 Pass FantaGol.",
    passes: 10,
    price_minor: 499,
    currency: "EUR",
    sort_order: 10,
    metadata: {},
  },
];

beforeEach(() => {
  vi.clearAllMocks();

  mocks.normalizeCommercialProducts.mockReturnValue(
    products,
  );
});

describe("getCommercialProducts", () => {
  it("calls the exact product RPC without a currency filter", async () => {
    const rawPayload = [
      {
        source: "database",
      },
    ];

    mocks.callCommercialRuntimeRpc.mockResolvedValue({
      data: rawPayload,
      rpcName: "get_commercial_products_rpc",
    });

    const result =
      await getCommercialProducts();

    expect(
      mocks.callCommercialRuntimeRpc,
    ).toHaveBeenCalledOnce();

    expect(
      mocks.callCommercialRuntimeRpc,
    ).toHaveBeenCalledWith(
      "get_commercial_products_rpc",
      {
        p_currency: null,
      },
    );

    expect(
      mocks.normalizeCommercialProducts,
    ).toHaveBeenCalledOnce();

    expect(
      mocks.normalizeCommercialProducts,
    ).toHaveBeenCalledWith(rawPayload);

    expect(result).toBe(products);
  });

  it("normalizes and forwards a currency filter", async () => {
    mocks.callCommercialRuntimeRpc.mockResolvedValue({
      data: [],
      rpcName: "get_commercial_products_rpc",
    });

    await getCommercialProducts({
      currency: " eur ",
    });

    expect(
      mocks.callCommercialRuntimeRpc,
    ).toHaveBeenCalledWith(
      "get_commercial_products_rpc",
      {
        p_currency: "EUR",
      },
    );
  });

  it("accepts an explicit null currency", async () => {
    mocks.callCommercialRuntimeRpc.mockResolvedValue({
      data: [],
      rpcName: "get_commercial_products_rpc",
    });

    await getCommercialProducts({
      currency: null,
    });

    expect(
      mocks.callCommercialRuntimeRpc,
    ).toHaveBeenCalledWith(
      "get_commercial_products_rpc",
      {
        p_currency: null,
      },
    );
  });

  it.each([
    "",
    "EU",
    "EURO",
    "12A",
  ])(
    "rejects invalid currency %s before calling the RPC",
    async (currency) => {
      await expect(
        getCommercialProducts({
          currency,
        }),
      ).rejects.toThrow(
        "currency must be a three-letter currency code.",
      );

      expect(
        mocks.callCommercialRuntimeRpc,
      ).not.toHaveBeenCalled();

      expect(
        mocks.normalizeCommercialProducts,
      ).not.toHaveBeenCalled();
    },
  );

  it("propagates an RPC failure without normalization", async () => {
    const failure = new Error(
      "Product RPC failed.",
    );

    mocks.callCommercialRuntimeRpc.mockRejectedValue(
      failure,
    );

    await expect(
      getCommercialProducts(),
    ).rejects.toBe(failure);

    expect(
      mocks.normalizeCommercialProducts,
    ).not.toHaveBeenCalled();
  });

  it("propagates a validation failure after the RPC", async () => {
    const failure = new TypeError(
      "Invalid product payload.",
    );

    mocks.callCommercialRuntimeRpc.mockResolvedValue({
      data: [],
      rpcName: "get_commercial_products_rpc",
    });

    mocks.normalizeCommercialProducts
      .mockImplementation(() => {
        throw failure;
      });

    await expect(
      getCommercialProducts(),
    ).rejects.toBe(failure);

    expect(
      mocks.callCommercialRuntimeRpc,
    ).toHaveBeenCalledOnce();
  });
});
