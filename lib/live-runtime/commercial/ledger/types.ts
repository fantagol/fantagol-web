import type { JsonObject } from "../json";

export interface GetMyCommercialLedgerInput {
  limit?: number;
  offset?: number;
}

export interface CommercialLedgerEntry
  extends JsonObject {
  ledger_id: string;
  transaction_type: string;
  amount: number;
  balance_before: number;
  balance_after: number;
  source_engine: string;
  external_reference: string | null;
  metadata: JsonObject;
  created_at: string;
}

export type CommercialLedger =
  CommercialLedgerEntry[];
