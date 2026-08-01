import type { SupabaseClient } from "@supabase/supabase-js";

import { AccountErasureProviderError } from "./errors";
import type {
  AccountErasureReceiptStatus,
  JsonObject,
} from "./types";

export async function recordExternalReceipt(
  client: SupabaseClient,
  input: {
    commandId: string;
    attemptId: string;
    workerId: string;
    leaseToken: string;
    receiptStatus: AccountErasureReceiptStatus;
    providerRequestId: string | null;
    resultDigest: string;
    publicEvidence: JsonObject;
    restrictedEvidence: JsonObject;
    affectedObjectCount: number;
    residualObjectCount: number | null;
  },
): Promise<{
  receiptId: string;
  receiptType: string;
}> {
  const { data, error } = await client.rpc(
    "record_account_erasure_external_receipt_internal",
    {
      p_command_id: input.commandId,
      p_attempt_id: input.attemptId,
      p_worker_id: input.workerId,
      p_lease_token: input.leaseToken,
      p_receipt_status: input.receiptStatus,
      p_provider_request_id: input.providerRequestId,
      p_result_digest: input.resultDigest,
      p_public_evidence: input.publicEvidence,
      p_restricted_evidence: input.restrictedEvidence,
      p_affected_object_count: input.affectedObjectCount,
      p_residual_object_count: input.residualObjectCount,
    },
  );

  if (error) {
    throw new AccountErasureProviderError(
      "ACCOUNT_ERASURE_RECEIPT_REJECTED",
      "The database rejected the external erasure receipt.",
      { retryable: false, cause: error },
    );
  }

  if (!data || typeof data !== "object" || Array.isArray(data)) {
    throw new AccountErasureProviderError(
      "ACCOUNT_ERASURE_RECEIPT_CONTRACT_INVALID",
      "Receipt RPC returned an invalid payload.",
    );
  }

  const record = data as Record<string, unknown>;

  if (
    typeof record.receipt_id !== "string" ||
    typeof record.receipt_type !== "string"
  ) {
    throw new AccountErasureProviderError(
      "ACCOUNT_ERASURE_RECEIPT_CONTRACT_INVALID",
      "Receipt identity is missing.",
    );
  }

  return {
    receiptId: record.receipt_id,
    receiptType: record.receipt_type,
  };
}
