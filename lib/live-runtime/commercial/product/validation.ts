import type { JsonObject } from "../json";
import { isJsonObject } from "../json";
import type {
  CommercialProduct,
  CommercialProducts,
} from "./types";

type UnknownObject = Record<string, unknown>;

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

const CURRENCY_PATTERN = /^[A-Z]{3}$/;

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

  if (!UUID_PATTERN.test(normalized)) {
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

function requireNonNegativeSafeInteger(
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

function requirePositiveSafeInteger(
  object: UnknownObject,
  fieldName: string,
  context: string,
): number {
  const value = object[fieldName];

  if (
    typeof value !== "number" ||
    !Number.isSafeInteger(value) ||
    value < 1
  ) {
    throw new TypeError(
      `${context}.${fieldName} must be a positive safe integer.`,
    );
  }

  return value;
}

function requireCurrency(
  object: UnknownObject,
  fieldName: string,
  context: string,
): string {
  const value = object[fieldName];

  if (
    typeof value !== "string" ||
    !CURRENCY_PATTERN.test(value)
  ) {
    throw new TypeError(
      `${context}.${fieldName} must be a three-letter uppercase currency code.`,
    );
  }

  return value;
}

function normalizeCommercialProduct(
  value: unknown,
  index: number,
): CommercialProduct {
  const context = `commercial_products[${index}]`;

  const object = requireObject(
    value,
    context,
  );

  return {
    ...object,
    product_id: requireUuid(
      object,
      "product_id",
      context,
    ),
    product_code: requireNonEmptyString(
      object,
      "product_code",
      context,
    ),
    title: requireNonEmptyString(
      object,
      "title",
      context,
    ),
    description: requireNonEmptyString(
      object,
      "description",
      context,
    ),
    passes: requirePositiveSafeInteger(
      object,
      "passes",
      context,
    ),
    price_minor: requireNonNegativeSafeInteger(
      object,
      "price_minor",
      context,
    ),
    currency: requireCurrency(
      object,
      "currency",
      context,
    ),
    sort_order: requireNonNegativeSafeInteger(
      object,
      "sort_order",
      context,
    ),
    metadata: requireObject(
      object.metadata,
      `${context}.metadata`,
    ),
  };
}

export function normalizeCommercialProducts(
  value: unknown,
): CommercialProducts {
  return requireArray(
    value,
    "commercial_products",
  ).map(normalizeCommercialProduct);
}
