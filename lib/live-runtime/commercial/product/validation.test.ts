import {
  describe,
  expect,
  it,
} from "vitest";

import {
  normalizeCommercialProducts,
} from "./validation";

const PRODUCT_ID =
  "11111111-1111-4111-8111-111111111111";

function createProduct() {
  return {
    product_id: PRODUCT_ID,
    product_code: "PASS_10",
    title: "10 Pass",
    description: "Pacchetto da 10 Pass FantaGol.",
    passes: 10,
    price_minor: 499,
    currency: "EUR",
    sort_order: 10,
    metadata: {
      featured: true,
      category: "pass",
    },
  };
}

describe("normalizeCommercialProducts", () => {
  it("accepts a complete product catalog", () => {
    const payload = [
      createProduct(),
    ];

    expect(
      normalizeCommercialProducts(payload),
    ).toEqual(payload);
  });

  it("accepts an empty product catalog", () => {
    expect(
      normalizeCommercialProducts([]),
    ).toEqual([]);
  });

  it("preserves JSON-compatible extension fields", () => {
    const payload = [
      {
        ...createProduct(),
        campaign_code: "SUMMER_2026",
      },
    ];

    expect(
      normalizeCommercialProducts(payload)[0]
        .campaign_code,
    ).toBe("SUMMER_2026");
  });

  it("accepts a zero price", () => {
    const payload = [
      {
        ...createProduct(),
        price_minor: 0,
      },
    ];

    expect(
      normalizeCommercialProducts(payload)[0]
        .price_minor,
    ).toBe(0);
  });

  it("accepts a zero sort order", () => {
    const payload = [
      {
        ...createProduct(),
        sort_order: 0,
      },
    ];

    expect(
      normalizeCommercialProducts(payload)[0]
        .sort_order,
    ).toBe(0);
  });

  it("rejects a non-array payload", () => {
    expect(() =>
      normalizeCommercialProducts({}),
    ).toThrow(
      "commercial_products must be an array.",
    );
  });

  it("rejects a non-object product", () => {
    expect(() =>
      normalizeCommercialProducts([null]),
    ).toThrow(
      "commercial_products[0] must be a JSON object.",
    );
  });

  it("rejects an invalid product UUID", () => {
    expect(() =>
      normalizeCommercialProducts([
        {
          ...createProduct(),
          product_id: "not-a-uuid",
        },
      ]),
    ).toThrow(
      "commercial_products[0].product_id must be a valid UUID.",
    );
  });

  it.each([
    "product_code",
    "title",
    "description",
  ] as const)(
    "rejects an empty %s",
    (fieldName) => {
      expect(() =>
        normalizeCommercialProducts([
          {
            ...createProduct(),
            [fieldName]: "   ",
          },
        ]),
      ).toThrow(
        `commercial_products[0].${fieldName} must be a non-empty string.`,
      );
    },
  );

  it.each([
    0,
    -1,
    1.5,
    Number.MAX_SAFE_INTEGER + 1,
  ])(
    "rejects invalid passes value %s",
    (passes) => {
      expect(() =>
        normalizeCommercialProducts([
          {
            ...createProduct(),
            passes,
          },
        ]),
      ).toThrow(
        "commercial_products[0].passes must be a positive safe integer.",
      );
    },
  );

  it.each([
    -1,
    1.5,
    Number.MAX_SAFE_INTEGER + 1,
  ])(
    "rejects invalid price_minor value %s",
    (price_minor) => {
      expect(() =>
        normalizeCommercialProducts([
          {
            ...createProduct(),
            price_minor,
          },
        ]),
      ).toThrow(
        "commercial_products[0].price_minor must be a non-negative safe integer.",
      );
    },
  );

  it.each([
    -1,
    1.5,
    Number.MAX_SAFE_INTEGER + 1,
  ])(
    "rejects invalid sort_order value %s",
    (sort_order) => {
      expect(() =>
        normalizeCommercialProducts([
          {
            ...createProduct(),
            sort_order,
          },
        ]),
      ).toThrow(
        "commercial_products[0].sort_order must be a non-negative safe integer.",
      );
    },
  );

  it.each([
    "eur",
    "EU",
    "EURO",
    "",
  ])(
    "rejects invalid currency %s",
    (currency) => {
      expect(() =>
        normalizeCommercialProducts([
          {
            ...createProduct(),
            currency,
          },
        ]),
      ).toThrow(
        "commercial_products[0].currency must be a three-letter uppercase currency code.",
      );
    },
  );

  it("rejects non-object metadata", () => {
    expect(() =>
      normalizeCommercialProducts([
        {
          ...createProduct(),
          metadata: [],
        },
      ]),
    ).toThrow(
      "commercial_products[0].metadata must be a JSON object.",
    );
  });
});
