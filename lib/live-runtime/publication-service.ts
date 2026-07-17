import type { SupabaseClient } from "@supabase/supabase-js";

import {
  callRuntimeRpc,
  requireSingleRpcRow,
} from "./rpc-utils";

export type LivePublicationChannel =
  | "web"
  | "android"
  | "internal"
  | "realtime";

export type PublishLiveStateSnapshotInput = {
  liveStateSnapshotId: string;
  channel?: LivePublicationChannel;
  metadata?: Record<string, unknown>;
};

export type PublishedLiveStateSnapshot = {
  publicationId: string;
  liveStateSnapshotId: string;
  leagueRoundId: string;
  simulationId: string;
  publicationVersion: number;
  channel: LivePublicationChannel;
  publicationStatus: string;
  simulationVersion: number;
  simulationHash: string;
  publishedAt: string;
};

type PublishSnapshotRpcRow = {
  publication_id: string;
  live_state_snapshot_id: string;
  league_round_id: string;
  simulation_id: string;
  publication_version: number;
  channel: LivePublicationChannel;
  publication_status: string;
  simulation_version: number;
  simulation_hash: string;
  published_at: string;
};

export async function publishLiveStateSnapshot(
  client: SupabaseClient,
  input: PublishLiveStateSnapshotInput,
): Promise<PublishedLiveStateSnapshot> {
  const functionName = "publish_live_state_snapshot_rpc";
  const rows = await callRuntimeRpc<PublishSnapshotRpcRow>(
    client,
    functionName,
    {
      p_live_state_snapshot_id: input.liveStateSnapshotId,
      p_channel: input.channel ?? "realtime",
      p_metadata: input.metadata ?? {},
    },
  );

  const row = requireSingleRpcRow(rows, functionName);

  return {
    publicationId: row.publication_id,
    liveStateSnapshotId: row.live_state_snapshot_id,
    leagueRoundId: row.league_round_id,
    simulationId: row.simulation_id,
    publicationVersion: row.publication_version,
    channel: row.channel,
    publicationStatus: row.publication_status,
    simulationVersion: row.simulation_version,
    simulationHash: row.simulation_hash,
    publishedAt: row.published_at,
  };
}
