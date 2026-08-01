import type { SupabaseClient } from "@supabase/supabase-js";

import { AccountErasureProviderError } from "./errors";
import type { JsonObject } from "./types";

async function rpc(
  client: SupabaseClient,
  functionName: string,
  args: Record<string, unknown>,
): Promise<unknown> {
  const { data, error } = await client.rpc(functionName, args);

  if (error) {
    throw new AccountErasureProviderError(
      "ACCOUNT_ERASURE_RECOVERY_RPC_FAILED",
      `${functionName} failed.`,
      { retryable: false, cause: error },
    );
  }

  return data;
}

export async function finalizeExternalAttemptFailure(
  client: SupabaseClient,
  input: {
    commandId: string;
    attemptId: string;
    workerId: string;
    leaseToken: string;
    outcome: "failed" | "ambiguous";
    errorCode: string;
    errorClass: string;
    retryable: boolean;
    providerRequestId?: string | null;
    responseDigest?: string | null;
    publicEvidence?: JsonObject;
    restrictedResponse?: JsonObject;
  },
): Promise<void> {
  await rpc(
    client,
    "finalize_account_erasure_external_attempt_internal",
    {
      p_command_id: input.commandId,
      p_attempt_id: input.attemptId,
      p_worker_id: input.workerId,
      p_lease_token: input.leaseToken,
      p_outcome: input.outcome,
      p_error_code: input.errorCode,
      p_error_class: input.errorClass,
      p_retryable: input.retryable,
      p_provider_request_id: input.providerRequestId ?? null,
      p_response_digest: input.responseDigest ?? null,
      p_public_evidence: input.publicEvidence ?? {},
      p_restricted_response: input.restrictedResponse ?? {},
    },
  );
}

export async function scheduleExternalCommandRetry(
  client: SupabaseClient,
  commandId: string,
): Promise<void> {
  await rpc(
    client,
    "schedule_account_erasure_external_retry_internal",
    {
      p_command_id: commandId,
      p_available_at: null,
    },
  );
}
