import type { SupabaseClient } from "@supabase/supabase-js";

import {
  AccountErasureLeaseError,
  AccountErasureProviderError,
} from "./errors";
import {
  parseClaimedExternalCommand,
  parsePreparedExternalCommand,
} from "./contracts";
import type {
  ClaimedExternalCommand,
  PreparedExternalCommand,
} from "./types";

async function rpc(
  client: SupabaseClient,
  functionName: string,
  args: Record<string, unknown>,
): Promise<unknown> {
  const { data, error } = await client.rpc(functionName, args);

  if (error) {
    const leaseError =
      error.message.includes("LEASE") ||
      error.message.includes("NOT_CLAIMABLE");

    if (leaseError) {
      throw new AccountErasureLeaseError(
        "ACCOUNT_ERASURE_EXTERNAL_LEASE_ERROR",
        error.message,
        { retryable: true, cause: error },
      );
    }

    throw new AccountErasureProviderError(
      "ACCOUNT_ERASURE_DATABASE_RPC_FAILED",
      `${functionName} failed.`,
      { retryable: false, cause: error },
    );
  }

  return data;
}

export async function prepareExternalCommand(
  client: SupabaseClient,
  input: {
    erasureStepId: string;
    workerId: string;
    correlationId: string;
  },
): Promise<PreparedExternalCommand> {
  const data = await rpc(
    client,
    "prepare_account_erasure_external_command_internal",
    {
      p_erasure_step_id: input.erasureStepId,
      p_worker_id: input.workerId,
      p_correlation_id: input.correlationId,
    },
  );

  return parsePreparedExternalCommand(data);
}

export async function claimExternalCommand(
  client: SupabaseClient,
  input: {
    commandId: string;
    workerId: string;
    correlationId: string;
    leaseInterval?: string;
  },
): Promise<ClaimedExternalCommand> {
  const data = await rpc(
    client,
    "claim_account_erasure_external_command_internal",
    {
      p_command_id: input.commandId,
      p_worker_id: input.workerId,
      p_correlation_id: input.correlationId,
      p_lease_interval: input.leaseInterval ?? "2 minutes",
    },
  );

  return parseClaimedExternalCommand(data);
}

export async function heartbeatExternalCommand(
  client: SupabaseClient,
  input: {
    commandId: string;
    workerId: string;
    leaseToken: string;
    extend?: string;
  },
): Promise<string> {
  const data = await rpc(
    client,
    "heartbeat_account_erasure_external_command_internal",
    {
      p_command_id: input.commandId,
      p_worker_id: input.workerId,
      p_lease_token: input.leaseToken,
      p_extend: input.extend ?? "2 minutes",
    },
  );

  if (typeof data !== "string") {
    throw new AccountErasureProviderError(
      "ACCOUNT_ERASURE_HEARTBEAT_CONTRACT_INVALID",
      "Heartbeat RPC returned an invalid timestamp.",
    );
  }

  return data;
}
