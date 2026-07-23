import "server-only";

import { callCommercialRuntimeRpc } from "../rpc";
import type {
  CommercialLedger,
  GetMyCommercialLedgerInput,
} from "./types";
import {
  normalizeCommercialLedger,
} from "./validation";

function requireLimit(
  value: number | undefined,
): number {
  const normalized = value ?? 50;

  if (
    !Number.isSafeInteger(normalized) ||
    normalized < 1 ||
    normalized > 200
  ) {
    throw new TypeError(
      "limit must be a safe integer between 1 and 200.",
    );
  }

  return normalized;
}

function requireOffset(
  value: number | undefined,
): number {
  const normalized = value ?? 0;

  if (
    !Number.isSafeInteger(normalized) ||
    normalized < 0
  ) {
    throw new TypeError(
      "offset must be a non-negative safe integer.",
    );
  }

  return normalized;
}

export async function getMyCommercialLedger(
  input: GetMyCommercialLedgerInput = {},
): Promise<CommercialLedger> {
  const limit = requireLimit(input.limit);
  const offset = requireOffset(input.offset);

  const result =
    await callCommercialRuntimeRpc<unknown>(
      "get_my_commercial_ledger_rpc",
      {
        p_limit: limit,
        p_offset: offset,
      },
    );

  return normalizeCommercialLedger(result.data);
}
