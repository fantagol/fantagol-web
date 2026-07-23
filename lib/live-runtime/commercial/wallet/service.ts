import "server-only";

import { callCommercialRuntimeRpc } from "../rpc";
import type { CommercialWallet } from "./types";
import { normalizeCommercialWallet } from "./validation";

export async function getMyCommercialWallet(): Promise<CommercialWallet> {
  const result =
    await callCommercialRuntimeRpc<unknown>(
      "get_my_commercial_wallet_rpc",
      {},
    );

  return normalizeCommercialWallet(result.data);
}
