import type {
  SupabaseClient,
} from "@supabase/supabase-js";

import type {
  MarketRuntimeArtifact,
} from "./market-intelligence-runtime-artifact";

export type MarketPersistenceMovement = {
  signal_type:
    | "EXACT"
    | "SIGN"
    | "TOTALS"
    | "BTTS"
    | "MARKET_CONFIDENCE"
    | "FINAL_CONFIDENCE";
  signal_key: string;
  previous_probability: number | null;
  current_probability: number | null;
  delta_probability: number | null;
  delta_percentage_points: number | null;
  previous_rank: number | null;
  current_rank: number | null;
  rank_delta: number | null;
  movement_magnitude: number;
  direction: "UP" | "DOWN" | "FLAT";
  metadata?: Record<string, unknown>;
};

export type MarketPersistenceMatch = {
  match_id: string;
  odds_market_snapshot_id: string;
  slot_number: number;
  model_code: "BM_INTERPOLATED";
  algorithm_version:
    | "BM_INTERPOLATED_V1"
    | "BM_INTERPOLATED_V2";
  sign: {
    home: number;
    draw: number;
    away: number;
  };
  totals: {
    over_25: number;
    under_25: number;
  };
  btts: {
    goal: number;
    no_goal: number;
  };
  expected_home_goals: number;
  expected_away_goals: number;
  primary_outcome: "1" | "X" | "2";
  confidence_score: number;
  market_confidence: number;
  model_loss: number;
  quality_score: number;
  input_payload: unknown;
  output_payload: unknown;
  input_hash: string;
  output_hash: string;
  movements: MarketPersistenceMovement[];
};

export type PersistMarketRoundInput = {
  fantagolRoundId: string;
  snapshotSource: "PACKAGE" | "ADVANCED";
  capturedAt: string;
  matches: MarketPersistenceMatch[];
  metadata?: Record<string, unknown>;
};

export type PersistMarketRoundResult = {
  created: boolean;
  idempotent: boolean;
  snapshot_id: string;
  snapshot_version?: number;
  captured_match_count?: number;
  input_hash: string;
  snapshot_hash?: string;
  quality_status?: string;
  quality_score?: number;
};

export async function persistMarketIntelligenceRound(
  client: SupabaseClient,
  input: PersistMarketRoundInput,
): Promise<PersistMarketRoundResult> {
  const { data, error } =
    await client.rpc(
      "persist_market_intelligence_snapshot_internal",
      {
        p_fantagol_round_id:
          input.fantagolRoundId,
        p_snapshot_source:
          input.snapshotSource,
        p_captured_at:
          input.capturedAt,
        p_matches:
          input.matches,
        p_metadata:
          input.metadata ?? {},
      },
    );

  if (error) {
    throw new Error(
      `MARKET_INTELLIGENCE_PERSISTENCE_FAILED: ${error.message}`,
    );
  }

  if (
    !data ||
    typeof data !== "object"
  ) {
    throw new Error(
      "MARKET_INTELLIGENCE_PERSISTENCE_INVALID_RESULT",
    );
  }

  return data as PersistMarketRoundResult;
}

export function artifactToPersistenceMatch(input: {
  artifact: MarketRuntimeArtifact;
  matchId: string;
  oddsMarketSnapshotId: string;
  slotNumber: number;
  inputHash: string;
  outputHash: string;
  movements?: MarketPersistenceMovement[];
}): MarketPersistenceMatch {
  const { artifact } = input;

  return {
    match_id:
      input.matchId,
    odds_market_snapshot_id:
      input.oddsMarketSnapshotId,
    slot_number:
      input.slotNumber,
    model_code:
      artifact.modelCode,
    algorithm_version:
      artifact.algorithmVersion,
    sign: {
      home:
        artifact.output.sign.home,
      draw:
        artifact.output.sign.draw,
      away:
        artifact.output.sign.away,
    },
    totals: {
      over_25:
        artifact.output.totals.over,
      under_25:
        artifact.output.totals.under,
    },
    btts: {
      goal:
        artifact.output.btts.goal,
      no_goal:
        artifact.output.btts.noGoal,
    },
    expected_home_goals:
      artifact.output.lambdaHome,
    expected_away_goals:
      artifact.output.lambdaAway,
    primary_outcome:
      artifact.primaryOutcome,
    confidence_score:
      artifact.output.confidence,
    market_confidence:
      artifact.output.marketConfidence,
    model_loss:
      artifact.output.modelFit.totalLoss,
    quality_score:
      artifact.input.qualityScore,
    input_payload:
      artifact.input,
    output_payload:
      artifact.output,
    input_hash:
      input.inputHash,
    output_hash:
      input.outputHash,
    movements:
      input.movements ?? [],
  };
}
