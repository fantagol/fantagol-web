import "server-only";

import { callCommercialRuntimeRpc } from "../rpc";
import type {
  CommercialRewardCampaigns,
} from "./types";
import {
  normalizeRewardCampaigns,
} from "./validation";

export async function getRewardCampaigns(): Promise<CommercialRewardCampaigns> {
  const result =
    await callCommercialRuntimeRpc<unknown>(
      "get_reward_campaigns_rpc",
      {},
    );

  return normalizeRewardCampaigns(
    result.data,
  );
}
