import "server-only";

import { callCommercialRuntimeRpc } from "../rpc";
import type {
  CommercialProducts,
  GetCommercialProductsInput,
} from "./types";
import {
  normalizeCommercialProducts,
} from "./validation";

const CURRENCY_PATTERN = /^[A-Z]{3}$/;

function normalizeCurrency(
  value: string | null | undefined,
): string | null {
  if (value === null || value === undefined) {
    return null;
  }

  if (typeof value !== "string") {
    throw new TypeError(
      "currency must be a string or null.",
    );
  }

  const normalized = value.trim().toUpperCase();

  if (!CURRENCY_PATTERN.test(normalized)) {
    throw new TypeError(
      "currency must be a three-letter currency code.",
    );
  }

  return normalized;
}

export async function getCommercialProducts(
  input: GetCommercialProductsInput = {},
): Promise<CommercialProducts> {
  const currency = normalizeCurrency(
    input.currency,
  );

  const result =
    await callCommercialRuntimeRpc<unknown>(
      "get_commercial_products_rpc",
      {
        p_currency: currency,
      },
    );

  return normalizeCommercialProducts(result.data);
}
