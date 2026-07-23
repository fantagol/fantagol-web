import type { JsonObject } from "../json";
import { isJsonObject } from "../json";
import type {
  CommercialWallet,
  CommercialWalletStatus,
} from "./types";

type UnknownObject = Record<string, unknown>;

function requireObject(
  value: unknown,
  context: string,
): JsonObject {
  if (!isJsonObject(value)) {
    throw new TypeError(`${context} must be a JSON object.`);
  }

  return value;
}

function requireTrue(
  object: UnknownObject,
  fieldName: string,
  context: string,
): true {
  const value = object[fieldName];

  if (value !== true) {
    throw new TypeError(
      `${context}.${fieldName} must be true.`,
    );
  }

  return true;
}

function requireUuid(
  object: UnknownObject,
  fieldName: string,
  context: string,
): string {
  const value = object[fieldName];

  if (typeof value !== "string") {
    throw new TypeError(
      `${context}.${fieldName} must be a valid UUID.`,
    );
  }

  const normalized = value.trim();

  const uuidPattern =
    /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

  if (!uuidPattern.test(normalized)) {
    throw new TypeError(
      `${context}.${fieldName} must be a valid UUID.`,
    );
  }

  return normalized;
}

function requireWalletStatus(
  value: unknown,
  context: string,
): CommercialWalletStatus {
  switch (value) {
    case "active":
    case "suspended":
    case "closed":
      return value;
    default:
      throw new TypeError(`${context} is invalid.`);
  }
}

function requireNonNegativeInteger(
  object: UnknownObject,
  fieldName: string,
  context: string,
): number {
  const value = object[fieldName];

  if (
    typeof value !== "number" ||
    !Number.isSafeInteger(value) ||
    value < 0
  ) {
    throw new TypeError(
      `${context}.${fieldName} must be a non-negative safe integer.`,
    );
  }

  return value;
}

function requireTimestamp(
  object: UnknownObject,
  fieldName: string,
  context: string,
): string {
  const value = object[fieldName];

  if (
    typeof value !== "string" ||
    !value.trim() ||
    Number.isNaN(Date.parse(value))
  ) {
    throw new TypeError(
      `${context}.${fieldName} must be a valid timestamp.`,
    );
  }

  return value;
}

export function normalizeCommercialWallet(
  value: unknown,
): CommercialWallet {
  const context = "commercial_wallet";
  const object = requireObject(value, context);

  return {
    available: requireTrue(
      object,
      "available",
      context,
    ),
    wallet_id: requireUuid(
      object,
      "wallet_id",
      context,
    ),
    status: requireWalletStatus(
      object.status,
      `${context}.status`,
    ),
    available_passes: requireNonNegativeInteger(
      object,
      "available_passes",
      context,
    ),
    lifetime_earned: requireNonNegativeInteger(
      object,
      "lifetime_earned",
      context,
    ),
    lifetime_consumed: requireNonNegativeInteger(
      object,
      "lifetime_consumed",
      context,
    ),
    lifetime_purchased: requireNonNegativeInteger(
      object,
      "lifetime_purchased",
      context,
    ),
    lifetime_rewarded: requireNonNegativeInteger(
      object,
      "lifetime_rewarded",
      context,
    ),
    lifetime_promotional: requireNonNegativeInteger(
      object,
      "lifetime_promotional",
      context,
    ),
    ledger_version: requireNonNegativeInteger(
      object,
      "ledger_version",
      context,
    ),
    server_time: requireTimestamp(
      object,
      "server_time",
      context,
    ),
  };
}
