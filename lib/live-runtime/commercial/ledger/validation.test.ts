import {
  describe,
  expect,
  it,
} from "vitest";

import {
  normalizeCommercialLedger,
} from "./validation";

const LEDGER_ID =
  "11111111-1111-4111-8111-111111111111";

const CREATED_AT =
  "2026-07-23T20:00:00.000Z";

function createLedgerEntry() {
  return {
    ledger_id: LEDGER_ID,
    transaction_type: "PASS_REWARD",
    amount: 3,
    balance_before: 5,
    balance_after: 8,
    source_engine: "LOYALTY_REWARD_ENGINE",
    external_reference: "reward-001",
    metadata: {
      campaign_code: "LOYALTY_EXACT",
      certified: true,
    },
    created_at: CREATED_AT,
  };
}

describe("normalizeCommercialLedger", () => {
  it("accepts the complete ledger payload", () => {
    const payload = [
      createLedgerEntry(),
    ];

    expect(
      normalizeCommercialLedger(payload),
    ).toEqual(payload);
  });

  it("accepts an empty ledger", () => {
    expect(
      normalizeCommercialLedger([]),
    ).toEqual([]);
  });

  it("accepts signed transaction amounts", () => {
    const payload = [
      {
        ...createLedgerEntry(),
        transaction_type: "PASS_CONSUMPTION",
        amount: -1,
        balance_before: 8,
        balance_after: 7,
      },
    ];

    expect(
      normalizeCommercialLedger(payload)[0].amount,
    ).toBe(-1);
  });

  it("accepts a null external reference", () => {
    const payload = [
      {
        ...createLedgerEntry(),
        external_reference: null,
      },
    ];

    expect(
      normalizeCommercialLedger(payload)[0]
        .external_reference,
    ).toBeNull();
  });

  it("rejects a non-array payload", () => {
    expect(() =>
      normalizeCommercialLedger({}),
    ).toThrow(
      "commercial_ledger must be an array.",
    );
  });

  it("rejects a non-object ledger entry", () => {
    expect(() =>
      normalizeCommercialLedger([null]),
    ).toThrow(
      "commercial_ledger[0] must be a JSON object.",
    );
  });

  it("rejects an invalid ledger UUID", () => {
    expect(() =>
      normalizeCommercialLedger([
        {
          ...createLedgerEntry(),
          ledger_id: "not-a-uuid",
        },
      ]),
    ).toThrow(
      "commercial_ledger[0].ledger_id must be a valid UUID.",
    );
  });

  it.each([
    "transaction_type",
    "source_engine",
  ] as const)(
    "rejects an empty %s",
    (fieldName) => {
      expect(() =>
        normalizeCommercialLedger([
          {
            ...createLedgerEntry(),
            [fieldName]: "   ",
          },
        ]),
      ).toThrow(
        `commercial_ledger[0].${fieldName} must be a non-empty string.`,
      );
    },
  );

  it.each([
    "amount",
    "balance_before",
    "balance_after",
  ] as const)(
    "rejects an unsafe %s value",
    (fieldName) => {
      expect(() =>
        normalizeCommercialLedger([
          {
            ...createLedgerEntry(),
            [fieldName]:
              Number.MAX_SAFE_INTEGER + 1,
          },
        ]),
      ).toThrow(
        `commercial_ledger[0].${fieldName} must be a safe integer.`,
      );
    },
  );

  it.each([
    "balance_before",
    "balance_after",
  ] as const)(
    "rejects a negative %s",
    (fieldName) => {
      expect(() =>
        normalizeCommercialLedger([
          {
            ...createLedgerEntry(),
            [fieldName]: -1,
          },
        ]),
      ).toThrow(
        `commercial_ledger[0].${fieldName} must be a non-negative safe integer.`,
      );
    },
  );

  it("rejects a non-object metadata payload", () => {
    expect(() =>
      normalizeCommercialLedger([
        {
          ...createLedgerEntry(),
          metadata: [],
        },
      ]),
    ).toThrow(
      "commercial_ledger[0].metadata must be a JSON object.",
    );
  });

  it("rejects an invalid timestamp", () => {
    expect(() =>
      normalizeCommercialLedger([
        {
          ...createLedgerEntry(),
          created_at: "not-a-timestamp",
        },
      ]),
    ).toThrow(
      "commercial_ledger[0].created_at must be a valid timestamp.",
    );
  });
});
