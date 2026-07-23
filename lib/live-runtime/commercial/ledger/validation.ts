import type { JsonObject } from "../json";
import { isJsonObject } from "../json";
import type {
  CommercialLedger,
  CommercialLedgerEntry,
} from "./types";

type UnknownObject = Record<string, unknown>;

function requireObject(
  value: unknown,
  context: string,
): JsonObject {
  if (!isJsonObject(value)) {
    throw new TypeError(
      `${context} must be a JSON object.`,
    );
  }

  return value;
}

function requireArray(
  value: unknown,
  context: string,
): unknown[] {
  if (!Array.isArray(value)) {
    throw new TypeError(
      `${context} must be an array.`,
    );
  }

  return value;
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

function requireNonEmptyString(
  object: UnknownObject,
  fieldName: string,
  context: string,
): string {
  const value = object[fieldName];

  if (
    typeof value !== "string" ||
    !value.trim()
  ) {
    throw new TypeError(
      `${context}.${fieldName} must be a non-empty string.`,
    );
  }

  return value;
}

function optionalString(
  object: UnknownObject,
  fieldName: string,
  context: string,
): string | null {
  const value = object[fieldName];

  if (value === null || value === undefined) {
    return null;
  }

  if (typeof value !== "string") {
    throw new TypeError(
      `${context}.${fieldName} must be a string or null.`,
    );
  }

  return value;
}

function requireSafeInteger(
  object: UnknownObject,
  fieldName: string,
  context: string,
): number {
  const value = object[fieldName];

  if (
    typeof value !== "number" ||
    !Number.isSafeInteger(value)
  ) {
    throw new TypeError(
      `${context}.${fieldName} must be a safe integer.`,
    );
  }

  return value;
}

function requireNonNegativeSafeInteger(
  object: UnknownObject,
  fieldName: string,
  context: string,
): number {
  const value = requireSafeInteger(
    object,
    fieldName,
    context,
  );

  if (value < 0) {
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

function normalizeCommercialLedgerEntry(
  value: unknown,
  index: number,
): CommercialLedgerEntry {
  const context = `commercial_ledger[${index}]`;

  const object = requireObject(
    value,
    context,
  );

  return {
    ...object,
    ledger_id: requireUuid(
      object,
      "ledger_id",
      context,
    ),
    transaction_type: requireNonEmptyString(
      object,
      "transaction_type",
      context,
    ),
    amount: requireSafeInteger(
      object,
      "amount",
      context,
    ),
    balance_before:
      requireNonNegativeSafeInteger(
        object,
        "balance_before",
        context,
      ),
    balance_after:
      requireNonNegativeSafeInteger(
        object,
        "balance_after",
        context,
      ),
    source_engine: requireNonEmptyString(
      object,
      "source_engine",
      context,
    ),
    external_reference: optionalString(
      object,
      "external_reference",
      context,
    ),
    metadata: requireObject(
      object.metadata,
      `${context}.metadata`,
    ),
    created_at: requireTimestamp(
      object,
      "created_at",
      context,
    ),
  };
}

export function normalizeCommercialLedger(
  value: unknown,
): CommercialLedger {
  return requireArray(
    value,
    "commercial_ledger",
  ).map(normalizeCommercialLedgerEntry);
}
