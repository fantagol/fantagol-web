import { describe, expect, it } from "vitest";

import { normalizeCommercialWallet } from "./validation";

const WALLET_ID =
  "11111111-1111-4111-8111-111111111111";

const NOW = "2026-07-23T18:00:00.000Z";

function createWalletPayload() {
  return {
    available: true,
    wallet_id: WALLET_ID,
    status: "active",
    available_passes: 8,
    lifetime_earned: 15,
    lifetime_consumed: 7,
    lifetime_purchased: 5,
    lifetime_rewarded: 10,
    lifetime_promotional: 0,
    ledger_version: 12,
    server_time: NOW,
  };
}

describe("normalizeCommercialWallet", () => {
  it("accepts the complete wallet RPC payload", () => {
    expect(
      normalizeCommercialWallet(
        createWalletPayload(),
      ),
    ).toEqual(createWalletPayload());
  });

  it.each([
    "active",
    "suspended",
    "closed",
  ] as const)(
    "accepts the %s wallet status",
    (status) => {
      const payload = {
        ...createWalletPayload(),
        status,
      };

      expect(
        normalizeCommercialWallet(payload).status,
      ).toBe(status);
    },
  );

  it("rejects an unavailable wallet payload", () => {
    expect(() =>
      normalizeCommercialWallet({
        ...createWalletPayload(),
        available: false,
      }),
    ).toThrow(
      "commercial_wallet.available must be true.",
    );
  });

  it("rejects an invalid wallet status", () => {
    expect(() =>
      normalizeCommercialWallet({
        ...createWalletPayload(),
        status: "blocked",
      }),
    ).toThrow(
      "commercial_wallet.status is invalid.",
    );
  });

  it.each([
    "available_passes",
    "lifetime_earned",
    "lifetime_consumed",
    "lifetime_purchased",
    "lifetime_rewarded",
    "lifetime_promotional",
    "ledger_version",
  ] as const)(
    "rejects an invalid %s value",
    (fieldName) => {
      expect(() =>
        normalizeCommercialWallet({
          ...createWalletPayload(),
          [fieldName]: -1,
        }),
      ).toThrow(
        `commercial_wallet.${fieldName} must be a non-negative safe integer.`,
      );
    },
  );

  it("rejects an invalid wallet UUID", () => {
    expect(() =>
      normalizeCommercialWallet({
        ...createWalletPayload(),
        wallet_id: "not-a-uuid",
      }),
    ).toThrow(
      "commercial_wallet.wallet_id must be a valid UUID.",
    );
  });

  it("rejects an invalid server timestamp", () => {
    expect(() =>
      normalizeCommercialWallet({
        ...createWalletPayload(),
        server_time: "not-a-timestamp",
      }),
    ).toThrow(
      "commercial_wallet.server_time must be a valid timestamp.",
    );
  });

  it("rejects a non-object payload", () => {
    expect(() =>
      normalizeCommercialWallet(null),
    ).toThrow(
      "commercial_wallet must be a JSON object.",
    );
  });
});
