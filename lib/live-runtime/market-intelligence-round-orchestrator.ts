import { createHash } from "node:crypto";

import type { SupabaseClient } from "@supabase/supabase-js";

import type {
  ProviderEventOdds,
} from "../market-intelligence/contracts";
import type {
  MarketObservationSource,
  ProbabilityMovement,
  TemporalMarketObservation,
  TemporalMovementResult,
} from "../market-intelligence/temporal-movement";
import {
  buildMarketRuntimeArtifact,
  toTemporalMarketObservation,
} from "./market-intelligence-runtime-artifact";
import {
  BM_INTERPOLATED_V2,
  loadActiveMarketRuntimeAlgorithmVersion,
  loadLatestCommunityTop3ExpertSnapshot,
  refreshCommunityTop3ExpertSnapshot,
} from "./top3-expert-market-feature";
import {
  artifactToPersistenceMatch,
  persistMarketIntelligenceRound,
  type MarketPersistenceMatch,
  type MarketPersistenceMovement,
  type PersistMarketRoundResult,
} from "./market-intelligence-persistence-service";
import {
  materializeSurpriseReferenceFromPersistedOdds,
} from "./surprise-reference-runtime";

export type MarketBatchCanonicalMatch = {
  matchId: string;
  externalMatchId: string;
  oddsMarketSnapshotId: string;
  slotNumber: number;
  fetchedAt: string;
  providerPayload: unknown;
};

type LatestMarketRow = {
  captured_at: string | null;
  snapshot_source:
    | MarketObservationSource
    | null;
  output_payload: unknown;
};

function isRecord(
  value: unknown,
): value is Record<string, unknown> {
  return (
    typeof value === "object" &&
    value !== null &&
    !Array.isArray(value)
  );
}

function stableSortValue(
  value: unknown,
): unknown {
  if (Array.isArray(value)) {
    return value.map(stableSortValue);
  }

  if (!isRecord(value)) {
    return value;
  }

  return Object.fromEntries(
    Object.keys(value)
      .sort()
      .map(
        (key) => [
          key,
          stableSortValue(value[key]),
        ],
      ),
  );
}

function sha256Json(
  value: unknown,
): string {
  return createHash("sha256")
    .update(
      JSON.stringify(
        stableSortValue(value),
      ),
    )
    .digest("hex");
}

function providerEventFromPayload(
  payload: unknown,
): ProviderEventOdds {
  if (!isRecord(payload)) {
    throw new Error(
      "MARKET_RUNTIME_PROVIDER_PAYLOAD_INVALID",
    );
  }

  const eventOdds =
    payload.eventOdds;

  if (!isRecord(eventOdds)) {
    throw new Error(
      "MARKET_RUNTIME_EVENT_ODDS_MISSING",
    );
  }

  const id =
    eventOdds.id;

  const homeTeam =
    eventOdds.home_team;

  const awayTeam =
    eventOdds.away_team;

  const bookmakers =
    eventOdds.bookmakers;

  if (
    typeof id !== "string" ||
    typeof homeTeam !== "string" ||
    typeof awayTeam !== "string" ||
    !Array.isArray(bookmakers)
  ) {
    throw new Error(
      "MARKET_RUNTIME_EVENT_ODDS_CONTRACT_INVALID",
    );
  }

  return eventOdds as unknown as ProviderEventOdds;
}

function numberField(
  value: unknown,
  label: string,
): number {
  if (
    typeof value !== "number" ||
    !Number.isFinite(value)
  ) {
    throw new Error(
      `MARKET_RUNTIME_PREVIOUS_OUTPUT_INVALID_${label}`,
    );
  }

  return value;
}

function previousObservation(
  row: LatestMarketRow | null,
): TemporalMarketObservation | null {
  if (
    !row ||
    !row.captured_at ||
    !row.snapshot_source
  ) {
    return null;
  }

  if (!isRecord(row.output_payload)) {
    throw new Error(
      "MARKET_RUNTIME_PREVIOUS_OUTPUT_INVALID",
    );
  }

  const output =
    row.output_payload;

  const exact =
    output.exact;

  const sign =
    output.sign;

  const totals =
    output.totals;

  const btts =
    output.btts;

  if (
    !Array.isArray(exact) ||
    !isRecord(sign) ||
    !isRecord(totals) ||
    !isRecord(btts)
  ) {
    throw new Error(
      "MARKET_RUNTIME_PREVIOUS_OUTPUT_SHAPE_INVALID",
    );
  }

  return {
    capturedAt:
      row.captured_at,
    source:
      row.snapshot_source,
    exact:
      exact.map(
        (item) => {
          if (!isRecord(item)) {
            throw new Error(
              "MARKET_RUNTIME_PREVIOUS_EXACT_INVALID",
            );
          }

          if (
            typeof item.score !== "string"
          ) {
            throw new Error(
              "MARKET_RUNTIME_PREVIOUS_EXACT_SCORE_INVALID",
            );
          }

          return {
            score:
              item.score,
            probability:
              numberField(
                item.probability,
                "EXACT_PROBABILITY",
              ),
          };
        },
      ),
    sign: {
      home:
        numberField(
          sign.home,
          "SIGN_HOME",
        ),
      draw:
        numberField(
          sign.draw,
          "SIGN_DRAW",
        ),
      away:
        numberField(
          sign.away,
          "SIGN_AWAY",
        ),
    },
    totals: {
      over:
        numberField(
          totals.over,
          "TOTALS_OVER",
        ),
      under:
        numberField(
          totals.under,
          "TOTALS_UNDER",
        ),
    },
    btts: {
      goal:
        numberField(
          btts.goal,
          "BTTS_GOAL",
        ),
      noGoal:
        numberField(
          btts.noGoal,
          "BTTS_NO_GOAL",
        ),
    },
    marketConfidence:
      numberField(
        output.marketConfidence,
        "MARKET_CONFIDENCE",
      ),
    finalConfidence:
      numberField(
        output.confidence,
        "FINAL_CONFIDENCE",
      ),
  };
}

async function loadLatestMarketRow(
  client: SupabaseClient,
  matchId: string,
): Promise<LatestMarketRow | null> {
  const { data, error } =
    await client.rpc(
      "get_latest_market_intelligence_match_internal",
      {
        p_match_id:
          matchId,
      },
    );

  if (error) {
    throw new Error(
      `MARKET_RUNTIME_PREVIOUS_READ_FAILED: ${error.message}`,
    );
  }

  if (!Array.isArray(data)) {
    if (data === null) {
      return null;
    }

    throw new Error(
      "MARKET_RUNTIME_PREVIOUS_READ_INVALID",
    );
  }

  const first =
    data[0];

  if (!first) {
    return null;
  }

  if (!isRecord(first)) {
    throw new Error(
      "MARKET_RUNTIME_PREVIOUS_ROW_INVALID",
    );
  }

  const source =
    first.snapshot_source;

  if (
    source !== null &&
    source !== "PACKAGE" &&
    source !== "ADVANCED"
  ) {
    throw new Error(
      "MARKET_RUNTIME_PREVIOUS_SOURCE_INVALID",
    );
  }

  return {
    captured_at:
      typeof first.captured_at ===
      "string"
        ? first.captured_at
        : null,
    snapshot_source:
      source as
        | MarketObservationSource
        | null,
    output_payload:
      first.output_payload,
  };
}

function movementRow(input: {
  signalType:
    MarketPersistenceMovement["signal_type"];
  signalKey: string;
  value: ProbabilityMovement;
  movementMagnitude: number;
  previousRank?: number | null;
  currentRank?: number | null;
  rankDelta?: number | null;
}): MarketPersistenceMovement {
  return {
    signal_type:
      input.signalType,
    signal_key:
      input.signalKey,
    previous_probability:
      input.value.previous,
    current_probability:
      input.value.current,
    delta_probability:
      input.value.delta,
    delta_percentage_points:
      input.value.deltaPercentagePoints,
    previous_rank:
      input.previousRank ?? null,
    current_rank:
      input.currentRank ?? null,
    rank_delta:
      input.rankDelta ?? null,
    movement_magnitude:
      input.movementMagnitude,
    direction:
      input.value.direction,
    metadata: {},
  };
}

export function movementRows(
  movement: TemporalMovementResult,
): MarketPersistenceMovement[] {
  if (
    movement.previousCapturedAt === null
  ) {
    return [];
  }

  const rows:
    MarketPersistenceMovement[] = [];

  for (const exact of movement.exact) {
    rows.push(
      movementRow({
        signalType: "EXACT",
        signalKey: exact.score,
        value: exact,
        movementMagnitude:
          Math.abs(exact.delta ?? 0),
        previousRank:
          exact.previousRank,
        currentRank:
          exact.currentRank,
        rankDelta:
          exact.rankDelta,
      }),
    );
  }

  const probabilitySignals = [
    ["SIGN", "1", movement.sign.home],
    ["SIGN", "X", movement.sign.draw],
    ["SIGN", "2", movement.sign.away],
    ["TOTALS", "OVER_2_5", movement.totals.over],
    ["TOTALS", "UNDER_2_5", movement.totals.under],
    ["BTTS", "GOAL", movement.btts.goal],
    ["BTTS", "NO_GOAL", movement.btts.noGoal],
    [
      "MARKET_CONFIDENCE",
      "MARKET_CONFIDENCE",
      movement.marketConfidence,
    ],
    [
      "FINAL_CONFIDENCE",
      "FINAL_CONFIDENCE",
      movement.finalConfidence,
    ],
  ] as const;

  for (
    const [
      signalType,
      signalKey,
      value,
    ] of probabilitySignals
  ) {
    rows.push(
      movementRow({
        signalType,
        signalKey,
        value,
        movementMagnitude:
          Math.abs(value.delta ?? 0),
      }),
    );
  }

  return rows;
}

export async function persistMarketBatchIntelligence(input: {
  client: SupabaseClient;
  fantagolRoundId: string;
  source: MarketObservationSource;
  capturedAt: string;
  matches: MarketBatchCanonicalMatch[];
  metadata?: Record<string, unknown>;
}): Promise<{
  modeledMatchCount: number;
  persistence: PersistMarketRoundResult;
}> {
  if (input.matches.length === 0) {
    throw new Error(
      "MARKET_RUNTIME_BATCH_EMPTY",
    );
  }

  const ordered =
    [...input.matches].sort(
      (a, b) =>
        a.slotNumber - b.slotNumber,
    );

  const runtimeAlgorithmVersion =
    await loadActiveMarketRuntimeAlgorithmVersion(
      input.client,
    );

  /*
   * Top3 lifecycle:
   *
   * PACKAGE:
   *   freeze missing per-league cohort (idempotent),
   *   read the leaders' latest official predictions,
   *   persist a new daily aggregate snapshot.
   *
   * ADVANCED:
   *   reuse the latest persisted Top3 snapshot so
   *   EVENTS refine the same Bookmakers model.
   *
   * Source deployment is safe before Migration 277:
   * V1 never touches the new tables.
   */
  const top3ExpertFeatures =
    runtimeAlgorithmVersion ===
      BM_INTERPOLATED_V2
      ? input.source === "PACKAGE"
        ? await refreshCommunityTop3ExpertSnapshot(
            input.client,
            input.fantagolRoundId,
            input.capturedAt,
            "PACKAGE",
          )
        : (
            await loadLatestCommunityTop3ExpertSnapshot(
              input.client,
              input.fantagolRoundId,
            )
          )
      : new Map();

  const persistenceMatches:
    MarketPersistenceMatch[] = [];

  for (const match of ordered) {
    const event =
      providerEventFromPayload(
        match.providerPayload,
      );

    if (
      event.id !==
      match.externalMatchId
    ) {
      throw new Error(
        "MARKET_RUNTIME_EVENT_ID_MISMATCH",
      );
    }

    const artifact =
      buildMarketRuntimeArtifact(
        event,
        {
          algorithmVersion:
            runtimeAlgorithmVersion,
          top3ExpertFeature:
            top3ExpertFeatures.get(
              match.matchId,
            ) ?? null,
        },
      );

    const latest =
      await loadLatestMarketRow(
        input.client,
        match.matchId,
      );

    const previous =
      previousObservation(
        latest,
      );

    const current =
      toTemporalMarketObservation(
        artifact,
        input.capturedAt,
        input.source,
      );

    const {
      calculateTemporalMovement,
    } =
      await import(
        "../market-intelligence/temporal-movement"
      );

    const movement =
      calculateTemporalMovement(
        previous,
        current,
      );

    persistenceMatches.push(
      artifactToPersistenceMatch({
        artifact,
        matchId:
          match.matchId,
        oddsMarketSnapshotId:
          match.oddsMarketSnapshotId,
        slotNumber:
          match.slotNumber,
        inputHash:
          sha256Json(
            artifact.input,
          ),
        outputHash:
          sha256Json(
            artifact.output,
          ),
        movements:
          movementRows(
            movement,
          ),
      }),
    );
  }

  const persistence =
    await persistMarketIntelligenceRound(
      input.client,
      {
        fantagolRoundId:
          input.fantagolRoundId,
        snapshotSource:
          input.source,
        capturedAt:
          input.capturedAt,
        matches:
          persistenceMatches,
        metadata: {
          runtime:
            "R38-C4-E2",
          modeled_match_count:
            persistenceMatches.length,
          runtime_algorithm_version:
            runtimeAlgorithmVersion,
          top3_expert_feature_version:
            runtimeAlgorithmVersion ===
              BM_INTERPOLATED_V2
              ? "TOP3_EXPERT_FEATURE_V1"
              : null,
          top3_expert_scope:
            runtimeAlgorithmVersion ===
              BM_INTERPOLATED_V2
              ? "ALL_ACTIVE_LEAGUES"
              : null,
          ...(input.metadata ?? {}),
        },
      },
    );

  /*
   * Surprise Reference activation is a downstream
   * consumer of already-persisted PACKAGE odds.
   *
   * IMPORTANT:
   * - no provider call;
   * - no additional market credit;
   * - no runtime job enqueue;
   * - ADVANCED snapshots never redefine the immutable
   *   pre-opening Surprise reference.
   */
  if (input.source === "PACKAGE") {
    await materializeSurpriseReferenceFromPersistedOdds(
      input.client,
      {
        fantagolRoundId:
          input.fantagolRoundId,
        runtimeSource:
          input.source,
      },
    );
  }

  return {
    modeledMatchCount:
      persistenceMatches.length,
    persistence,
  };
}
