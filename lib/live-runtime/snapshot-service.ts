import type { SupabaseClient } from "@supabase/supabase-js";

import {
  callRuntimeRpc,
  requireSingleRpcRow,
} from "./rpc-utils";

export type CreateLiveStateSnapshotInput = {
  simulationId: string;
  liveState: Record<string, unknown>;
  timelineCursor?: Record<string, unknown>;
  health?: Record<string, unknown>;
  engineVersion?: string;
  snapshotSchemaVersion?: number;
  correlationId?: string | null;
};

export type CreatedLiveStateSnapshot = {
  liveStateSnapshotId: string;
  leagueRoundId: string;
  simulationId: string;
  liveStateVersion: number;
  snapshotStatus: string;
  inputHash: string;
  outputHash: string;
  snapshotHash: string;
};

type CreateSnapshotRpcRow = {
  live_state_snapshot_id: string;
  league_round_id: string;
  simulation_id: string;
  live_state_version: number;
  snapshot_status: string;
  input_hash: string;
  output_hash: string;
  snapshot_hash: string;
};

export async function createLiveStateSnapshot(
  client: SupabaseClient,
  input: CreateLiveStateSnapshotInput,
): Promise<CreatedLiveStateSnapshot> {
  const functionName = "create_live_state_snapshot_rpc";
  const rows = await callRuntimeRpc<CreateSnapshotRpcRow>(
    client,
    functionName,
    {
      p_simulation_id: input.simulationId,
      p_live_state: input.liveState,
      p_timeline_cursor: input.timelineCursor ?? {},
      p_health: input.health ?? {
        status: "healthy",
        stale: false,
      },
      p_engine_version: input.engineVersion ?? "live-state-v1",
      p_snapshot_schema_version: input.snapshotSchemaVersion ?? 1,
      p_correlation_id: input.correlationId ?? null,
    },
  );

  const row = requireSingleRpcRow(rows, functionName);

  return {
    liveStateSnapshotId: row.live_state_snapshot_id,
    leagueRoundId: row.league_round_id,
    simulationId: row.simulation_id,
    liveStateVersion: row.live_state_version,
    snapshotStatus: row.snapshot_status,
    inputHash: row.input_hash,
    outputHash: row.output_hash,
    snapshotHash: row.snapshot_hash,
  };
}
