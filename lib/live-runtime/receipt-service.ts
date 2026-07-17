import type { SupabaseClient } from "@supabase/supabase-js";

import {
  callRuntimeRpc,
  requireSingleRpcRow,
} from "./rpc-utils";
import type {
  LiveRuntimeChangeDetection,
  RuntimeNormalizedMatchUpdate,
} from "./types";

export type RegisterLiveMatchUpdateInput = {
  matchId: string | null;
  payloadHash: string;
  update: RuntimeNormalizedMatchUpdate;
  change: LiveRuntimeChangeDetection;
  correlationId?: string | null;
};

export type LiveMatchUpdateReceipt = {
  receiptId: string;
  inserted: boolean;
  processingStatus:
    | "received"
    | "accepted"
    | "duplicate"
    | "processed"
    | "rejected"
    | "failed";
  meaningfulChange: boolean | null;
  changeType: LiveRuntimeChangeDetection["changeType"] | null;
  correlationId: string;
};

type RegisterReceiptRpcRow = {
  receipt_id: string;
  inserted: boolean;
  processing_status: LiveMatchUpdateReceipt["processingStatus"];
  meaningful_change: boolean | null;
  change_type: LiveMatchUpdateReceipt["changeType"];
  correlation_id: string;
};

const RPC_NAME = "register_live_match_update_rpc";

export async function registerLiveMatchUpdate(
  client: SupabaseClient,
  input: RegisterLiveMatchUpdateInput,
): Promise<LiveMatchUpdateReceipt> {
  const rows = await callRuntimeRpc<RegisterReceiptRpcRow>(
    client,
    RPC_NAME,
    {
      p_provider_code: input.update.providerCode,
      p_external_match_id: input.update.externalMatchId,
      p_match_id: input.matchId,
      p_provider_updated_at: input.update.providerUpdatedAt,
      p_payload_hash: input.payloadHash,
      p_normalized_payload: input.update.normalizedPayload,
      p_meaningful_change: input.change.meaningfulChange,
      p_change_type: input.change.changeType,
      p_correlation_id: input.correlationId ?? null,
    },
  );

  const row = requireSingleRpcRow(rows, RPC_NAME);

  return {
    receiptId: row.receipt_id,
    inserted: row.inserted,
    processingStatus: row.processing_status,
    meaningfulChange: row.meaningful_change,
    changeType: row.change_type,
    correlationId: row.correlation_id,
  };
}
