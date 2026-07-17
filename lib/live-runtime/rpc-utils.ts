import type { SupabaseClient } from "@supabase/supabase-js";

import { LiveRuntimeError } from "./errors";

export type RpcRow = Record<string, unknown>;

export async function callRuntimeRpc<T extends RpcRow>(
  client: SupabaseClient,
  functionName: string,
  args: Record<string, unknown>,
): Promise<T[]> {
  const { data, error } = await client.rpc(functionName, args);

  if (error) {
    throw new LiveRuntimeError({
      code: "LIVE_RUNTIME_RPC_ERROR",
      message: `Live Runtime RPC failed: ${functionName}`,
      details: {
        functionName,
        code: error.code,
        message: error.message,
        details: error.details,
        hint: error.hint,
      },
      cause: error,
    });
  }

  if (!Array.isArray(data)) {
    throw new LiveRuntimeError({
      code: "LIVE_RUNTIME_INVALID_RPC_RESPONSE",
      message: `Live Runtime RPC returned a non-array response: ${functionName}`,
      details: {
        functionName,
        responseType: typeof data,
      },
    });
  }

  return data as T[];
}

export function requireSingleRpcRow<T extends RpcRow>(
  rows: T[],
  functionName: string,
): T {
  if (rows.length !== 1) {
    throw new LiveRuntimeError({
      code: "LIVE_RUNTIME_INVALID_RPC_RESPONSE",
      message: `Live Runtime RPC must return exactly one row: ${functionName}`,
      details: {
        functionName,
        rowCount: rows.length,
      },
    });
  }

  return rows[0];
}

export function optionalSingleRpcRow<T extends RpcRow>(
  rows: T[],
  functionName: string,
): T | null {
  if (rows.length > 1) {
    throw new LiveRuntimeError({
      code: "LIVE_RUNTIME_INVALID_RPC_RESPONSE",
      message: `Live Runtime RPC returned more than one row: ${functionName}`,
      details: {
        functionName,
        rowCount: rows.length,
      },
    });
  }

  return rows[0] ?? null;
}
