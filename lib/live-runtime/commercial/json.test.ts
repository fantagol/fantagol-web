import {
  describe,
  expect,
  expectTypeOf,
  it,
} from "vitest";

import {
  asJsonObject,
  isJsonObject,
} from "./json";

import type {
  JsonObject,
  JsonPrimitive,
  JsonValue,
} from "./json";

describe("JsonPrimitive contract", () => {
  it("accepts the complete primitive union", () => {
    const values = [
      "commercial",
      42,
      true,
      false,
      null,
    ] satisfies JsonPrimitive[];

    expect(values).toEqual([
      "commercial",
      42,
      true,
      false,
      null,
    ]);
  });

  it("matches the stable primitive type union", () => {
    expectTypeOf<JsonPrimitive>().toEqualTypeOf<
      string | number | boolean | null
    >();
  });

  it("rejects undefined as a JSON primitive", () => {
    // @ts-expect-error Undefined is not a JSON primitive.
    const value: JsonPrimitive = undefined;

    expect(value).toBeUndefined();
  });
});

describe("JsonValue contract", () => {
  it("accepts nested JSON-compatible values", () => {
    const value = {
      purchase_id: "purchase-001",
      authorized: true,
      amount: 12.5,
      metadata: {
        source: "unit-test",
        tags: ["commercial", "runtime"],
        retry_count: 0,
      },
      optional_value: null,
      timeline: [
        {
          state: "pending",
          sequence: 1,
        },
        {
          state: "authorized",
          sequence: 2,
        },
      ],
    } satisfies JsonValue;

    expect(value.metadata.tags).toEqual([
      "commercial",
      "runtime",
    ]);
    expect(value.timeline).toHaveLength(2);
  });

  it("accepts recursively nested arrays", () => {
    const value = [
      "commercial",
      [1, 2, [true, null]],
      {
        nested: [["runtime"]],
      },
    ] satisfies JsonValue;

    expect(value).toEqual([
      "commercial",
      [1, 2, [true, null]],
      {
        nested: [["runtime"]],
      },
    ]);
  });

  it("rejects functions", () => {
    // @ts-expect-error Functions are not JSON values.
    const value: JsonValue = () => "invalid";

    expect(typeof value).toBe("function");
  });

  it("rejects Date instances", () => {
    // @ts-expect-error Date is not assignable to JsonValue.
    const value: JsonValue = new Date(
      "2026-07-23T16:00:00.000Z",
    );

    expect(value).toBeInstanceOf(Date);
  });

  it("rejects Map instances", () => {
    // @ts-expect-error Map is not assignable to JsonValue.
    const value: JsonValue = new Map([
      ["state", "ready"],
    ]);

    expect(value).toBeInstanceOf(Map);
  });

  it("rejects Set instances", () => {
    // @ts-expect-error Set is not assignable to JsonValue.
    const value: JsonValue = new Set([
      "commercial",
      "runtime",
    ]);

    expect(value).toBeInstanceOf(Set);
  });

  it("rejects undefined object properties", () => {
    const value = {
      // @ts-expect-error Undefined is not a JsonValue.
      optional: undefined,
    } satisfies JsonObject;

    expect(value.optional).toBeUndefined();
  });
});

describe("JsonObject contract", () => {
  it("accepts an empty object", () => {
    const value = {} satisfies JsonObject;

    expect(value).toEqual({});
  });

  it("accepts arbitrary JSON-compatible keys", () => {
    const value = {
      purchase_id: "purchase-001",
      sequence: 3,
      approved: true,
      reason: null,
      payload: {
        source: "commercial-runtime",
      },
      states: ["pending", "authorized"],
    } satisfies JsonObject;

    expect(value.payload.source).toBe(
      "commercial-runtime",
    );
  });

  it("exposes JsonValue for arbitrary keys", () => {
    expectTypeOf<
      JsonObject[string]
    >().toEqualTypeOf<JsonValue>();
  });
});

describe("isJsonObject", () => {
  it("returns true for a plain object", () => {
    expect(
      isJsonObject({
        purchase_id: "purchase-001",
      }),
    ).toBe(true);
  });

  it("returns true for an empty object", () => {
    expect(isJsonObject({})).toBe(true);
  });

  it("returns true for objects with a null prototype", () => {
    const value = Object.create(null) as object;

    expect(isJsonObject(value)).toBe(true);
  });

  it("returns true for Date instances under the current broad guard", () => {
    expect(
      isJsonObject(
        new Date("2026-07-23T16:00:00.000Z"),
      ),
    ).toBe(true);
  });

  it("returns true for Map instances under the current broad guard", () => {
    expect(
      isJsonObject(
        new Map([["state", "ready"]]),
      ),
    ).toBe(true);
  });

  it.each([
    null,
    undefined,
    "commercial",
    42,
    true,
    [],
    ["runtime"],
  ])(
    "returns false for non-object or array values",
    (value) => {
      expect(isJsonObject(value)).toBe(false);
    },
  );
});

describe("asJsonObject", () => {
  it("returns the original object by identity", () => {
    const value = {
      purchase_id: "purchase-001",
      state: "ready",
    };

    expect(
      asJsonObject(value, "purchase runtime"),
    ).toBe(value);
  });

  it("accepts an empty object", () => {
    const value = {};

    expect(
      asJsonObject(value, "runtime payload"),
    ).toBe(value);
  });

  it("returns Date instances under the current broad guard", () => {
    const value = new Date(
      "2026-07-23T16:00:00.000Z",
    );

    expect(
      asJsonObject(value, "runtime date"),
    ).toBe(value);
  });

  it("throws TypeError for an array", () => {
    expect(() =>
      asJsonObject([], "runtime payload"),
    ).toThrow(TypeError);
  });

  it("uses the supplied context in the exact error message", () => {
    expect(() =>
      asJsonObject(null, "commercial metadata"),
    ).toThrow(
      "commercial metadata must be a JSON object.",
    );
  });

  it.each([
    undefined,
    "commercial",
    42,
    false,
    [],
  ])(
    "rejects invalid JSON object inputs",
    (value) => {
      expect(() =>
        asJsonObject(value, "runtime value"),
      ).toThrow(
        "runtime value must be a JSON object.",
      );
    },
  );
});
