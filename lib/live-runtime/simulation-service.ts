import type { SupabaseClient } from "@supabase/supabase-js";

import { LiveRuntimeError } from "./errors";
import {
  callRuntimeRpc,
  requireSingleRpcRow,
} from "./rpc-utils";

export type SimulationPipelineVersions = {
  resolution: string;
  points: string;
  fantacalcio: string;
  oneToOne: string;
  standings: string;
  ui: string;
  liveState: string;
};

export const DEFAULT_SIMULATION_PIPELINE_VERSIONS: SimulationPipelineVersions = {
  resolution: "prediction-resolution-v1",
  points: "round-simulation-v1",
  fantacalcio: "round-simulation-v1-fantacalcio-v1",
  oneToOne: "round-simulation-v1-one-to-one-v1",
  standings: "round-simulation-v1-standings-v1",
  ui: "round-simulation-v1-ui-v1",
  liveState: "live-state-v1",
};

type CalculationRunRpcRow = {
  calculation_run_id: string;
  league_round_id: string;
  run_version: number;
  calculation_status: string;
  member_count: number;
  match_count: number;
  result_count: number;
  input_hash: string;
  output_hash: string;
};

type SimulationRpcRow = {
  simulation_id: string;
  source_simulation_id?: string;
  league_round_id: string;
  calculation_run_id: string;
  simulation_version: number;
  simulation_status: string;
  builder_status: string;
  input_hash: string;
  output_hash: string;
  simulation_hash: string;
};

export type RebuiltLeagueRoundSimulation = {
  leagueRoundId: string;
  calculationRunId: string;
  pointsSimulationId: string;
  fantacalcioSimulationId: string;
  oneToOneSimulationId: string;
  standingsSimulationId: string;
  uiSimulationId: string;
  uiSimulationVersion: number;
  uiSimulationHash: string;
  digitalTwin: Record<string, unknown>;
};

async function callSingleSimulationRpc(
  client: SupabaseClient,
  functionName: string,
  args: Record<string, unknown>,
): Promise<SimulationRpcRow> {
  const rows = await callRuntimeRpc<SimulationRpcRow>(
    client,
    functionName,
    args,
  );

  return requireSingleRpcRow(rows, functionName);
}

async function loadSimulationDigitalTwin(
  client: SupabaseClient,
  simulationId: string,
): Promise<Record<string, unknown>> {
  const { data, error } = await client
    .from("round_simulations")
    .select("digital_twin")
    .eq("id", simulationId)
    .single();

  if (error) {
    throw new LiveRuntimeError({
      code: "LIVE_RUNTIME_RPC_ERROR",
      message: "Unable to load the completed UI Simulation Digital Twin",
      details: {
        simulationId,
        code: error.code,
        message: error.message,
        details: error.details,
        hint: error.hint,
      },
      cause: error,
    });
  }

  const digitalTwin = data?.digital_twin;

  if (
    !digitalTwin ||
    typeof digitalTwin !== "object" ||
    Array.isArray(digitalTwin)
  ) {
    throw new LiveRuntimeError({
      code: "LIVE_RUNTIME_INVALID_RPC_RESPONSE",
      message: "UI Simulation did not contain a valid Digital Twin",
      details: { simulationId },
    });
  }

  return digitalTwin as Record<string, unknown>;
}

export async function rebuildLeagueRoundSimulation(
  client: SupabaseClient,
  input: {
    leagueRoundId: string;
    surpriseCandidates?: Record<string, unknown>;
    createdByMemberId?: string | null;
    correlationId?: string | null;
    versions?: Partial<SimulationPipelineVersions>;
  },
): Promise<RebuiltLeagueRoundSimulation> {
  const versions: SimulationPipelineVersions = {
    ...DEFAULT_SIMULATION_PIPELINE_VERSIONS,
    ...input.versions,
  };

  const calculationRows = await callRuntimeRpc<CalculationRunRpcRow>(
    client,
    "build_points_pure_calculation_run_rpc",
    {
      p_league_round_id: input.leagueRoundId,
      p_surprise_candidates: input.surpriseCandidates ?? {},
      p_engine_version: versions.resolution,
      p_created_by_member_id: input.createdByMemberId ?? null,
    },
  );
  const calculation = requireSingleRpcRow(
    calculationRows,
    "build_points_pure_calculation_run_rpc",
  );

  const points = await callSingleSimulationRpc(
    client,
    "build_points_preview_simulation_rpc",
    {
      p_calculation_run_id: calculation.calculation_run_id,
      p_simulation_engine_version: versions.points,
      p_created_by_member_id: input.createdByMemberId ?? null,
      p_correlation_id: input.correlationId ?? null,
    },
  );

  const [fantacalcio, oneToOne] = await Promise.all([
    callSingleSimulationRpc(
      client,
      "build_fantacalcio_preview_simulation_rpc",
      {
        p_source_simulation_id: points.simulation_id,
        p_simulation_engine_version: versions.fantacalcio,
        p_created_by_member_id: input.createdByMemberId ?? null,
        p_correlation_id: input.correlationId ?? null,
      },
    ),
    callSingleSimulationRpc(
      client,
      "build_one_to_one_preview_simulation_rpc",
      {
        p_source_simulation_id: points.simulation_id,
        p_simulation_engine_version: versions.oneToOne,
        p_created_by_member_id: input.createdByMemberId ?? null,
        p_correlation_id: input.correlationId ?? null,
      },
    ),
  ]);

  const standings = await callSingleSimulationRpc(
    client,
    "build_standings_preview_simulation_rpc",
    {
      p_source_simulation_id: points.simulation_id,
      p_simulation_engine_version: versions.standings,
      p_created_by_member_id: input.createdByMemberId ?? null,
      p_correlation_id: input.correlationId ?? null,
    },
  );

  const ui = await callSingleSimulationRpc(
    client,
    "build_ui_snapshot_simulation_rpc",
    {
      p_source_simulation_id: standings.simulation_id,
      p_simulation_engine_version: versions.ui,
      p_created_by_member_id: input.createdByMemberId ?? null,
      p_correlation_id: input.correlationId ?? null,
    },
  );

  const digitalTwin = await loadSimulationDigitalTwin(
    client,
    ui.simulation_id,
  );

  return {
    leagueRoundId: calculation.league_round_id,
    calculationRunId: calculation.calculation_run_id,
    pointsSimulationId: points.simulation_id,
    fantacalcioSimulationId: fantacalcio.simulation_id,
    oneToOneSimulationId: oneToOne.simulation_id,
    standingsSimulationId: standings.simulation_id,
    uiSimulationId: ui.simulation_id,
    uiSimulationVersion: ui.simulation_version,
    uiSimulationHash: ui.simulation_hash,
    digitalTwin,
  };
}
