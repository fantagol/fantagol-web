import type { JsonObject } from "../json";

export type CommercialWalletStatus =
  | "active"
  | "suspended"
  | "closed";

export interface CommercialWallet extends JsonObject {
  available: true;
  wallet_id: string;
  status: CommercialWalletStatus;
  available_passes: number;
  lifetime_earned: number;
  lifetime_consumed: number;
  lifetime_purchased: number;
  lifetime_rewarded: number;
  lifetime_promotional: number;
  ledger_version: number;
  server_time: string;
}
