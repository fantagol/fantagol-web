import "server-only";

import type { PostgrestError } from "@supabase/supabase-js";

import { getSupabaseServiceClient } from "@/lib/supabase/service";

import { CommercialRuntimeError } from "./errors";
import type {
  CommercialRuntimeRpcName,
  CommercialRuntimeRpcResult,
} from "./types";

type RpcArguments = Record<string, unknown>;

function normalizePostgrestError(
  rpcName: CommercialRuntimeRpcName,
  error: PostgrestError,
): CommercialRuntimeError {
  return new CommercialRuntimeError(
    {
      rpcName,
      code: error.code ?? null,
      message:
        error.message ||
        `Commercial runtime RPC ${rpcName} failed.`,
      details: error.details ?? null,
      hint: error.hint ?? null,
    },
    error,
  );
}

export async function callCommercialRuntimeRpc<T>(
  rpcName: CommercialRuntimeRpcName,
  args: RpcArguments,
): Promise<CommercialRuntimeRpcResult<T>> {
  const supabase = getSupabaseServiceClient();

  const { data, error } = await supabase.rpc(
    rpcName,
    args,
  );

  if (error) {
    throw normalizePostgrestError(rpcName, error);
  }

  return {
    data: data as T,
    rpcName,
  };
}
