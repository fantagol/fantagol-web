import type {
  MarketIntelligenceInput,
  ProviderEventOdds,
} from "../market-intelligence/contracts";
import {
  normalizeMarketIntelligenceInput,
} from "../market-intelligence/input-normalizer";
import {
  buildBmInterpolatedResult,
  verifyBmInterpolatedResult,
  type BmInterpolatedResult,
} from "../market-intelligence/score-distribution";
import {
  calculateTemporalMovement,
  type MarketObservationSource,
  type TemporalMarketObservation,
  type TemporalMovementResult,
} from "../market-intelligence/temporal-movement";
import {
  applyTop3ExpertFeatureV1,
  type BmInterpolatedRuntimeResult,
  type MarketRuntimeAlgorithmVersion,
  type Top3ExpertFeatureV1,
} from "./top3-expert-market-feature";

export type MarketRuntimePrimaryOutcome =
  | "1"
  | "X"
  | "2";

export type MarketRuntimeInput =
  MarketIntelligenceInput & {
    runtimeAlgorithmVersion:
      MarketRuntimeAlgorithmVersion;
    top3ExpertFeature:
      Top3ExpertFeatureV1 | null;
    top3ExpertAppliedWeight:
      number;
  };

export type MarketRuntimeArtifact = {
  providerEventId: string;
  modelCode: "BM_INTERPOLATED";
  algorithmVersion:
    MarketRuntimeAlgorithmVersion;
  input: MarketRuntimeInput;
  output:
    BmInterpolatedRuntimeResult;
  primaryOutcome: MarketRuntimePrimaryOutcome;
};

function primaryOutcome(
  result: BmInterpolatedRuntimeResult,
): MarketRuntimePrimaryOutcome {
  const rows = [
    ["1", result.sign.home],
    ["X", result.sign.draw],
    ["2", result.sign.away],
  ] as const;

  return rows.reduce(
    (best, current) =>
      current[1] > best[1]
        ? current
        : best,
  )[0];
}

export function buildMarketRuntimeArtifact(
  event: ProviderEventOdds,
  options?: {
    algorithmVersion?:
      MarketRuntimeAlgorithmVersion;
    top3ExpertFeature?:
      Top3ExpertFeatureV1 | null;
  },
): MarketRuntimeArtifact {
  const normalizedInput =
    normalizeMarketIntelligenceInput(event);

  const baseOutput =
    buildBmInterpolatedResult(
      normalizedInput,
    );

  verifyBmInterpolatedResult(
    baseOutput,
  );

  const runtimeAlgorithmVersion =
    options?.algorithmVersion ??
    "BM_INTERPOLATED_V1";

  const adjusted =
    runtimeAlgorithmVersion ===
      "BM_INTERPOLATED_V2"
      ? applyTop3ExpertFeatureV1(
          baseOutput,
          options?.top3ExpertFeature ??
            null,
        )
      : {
          result:
            baseOutput as
              BmInterpolatedRuntimeResult,
          appliedWeight: 0,
        };

  const input:
    MarketRuntimeInput = {
      ...normalizedInput,
      runtimeAlgorithmVersion,
      top3ExpertFeature:
        runtimeAlgorithmVersion ===
          "BM_INTERPOLATED_V2"
          ? options
              ?.top3ExpertFeature ??
            null
          : null,
      top3ExpertAppliedWeight:
        adjusted.appliedWeight,
    };

  return {
    providerEventId:
      input.providerEventId,
    modelCode:
      adjusted.result.modelCode,
    algorithmVersion:
      adjusted
        .result
        .algorithmVersion,
    input,
    output:
      adjusted.result,
    primaryOutcome:
      primaryOutcome(
        adjusted.result,
      ),
  };
}

export function toTemporalMarketObservation(
  artifact: MarketRuntimeArtifact,
  capturedAt: string,
  source: MarketObservationSource,
): TemporalMarketObservation {
  return {
    capturedAt,
    source,
    exact:
      artifact.output.exact.map(
        (item) => ({
          score: item.score,
          probability: item.probability,
        }),
      ),
    sign: {
      home: artifact.output.sign.home,
      draw: artifact.output.sign.draw,
      away: artifact.output.sign.away,
    },
    totals: {
      over: artifact.output.totals.over,
      under: artifact.output.totals.under,
    },
    btts: {
      goal: artifact.output.btts.goal,
      noGoal: artifact.output.btts.noGoal,
    },
    marketConfidence:
      artifact.output.marketConfidence,
    finalConfidence:
      artifact.output.confidence,
  };
}

export function calculateMarketRuntimeMovement(
  previous: {
    artifact: MarketRuntimeArtifact;
    capturedAt: string;
    source: MarketObservationSource;
  } | null,
  current: {
    artifact: MarketRuntimeArtifact;
    capturedAt: string;
    source: MarketObservationSource;
  },
): TemporalMovementResult {
  return calculateTemporalMovement(
    previous
      ? toTemporalMarketObservation(
          previous.artifact,
          previous.capturedAt,
          previous.source,
        )
      : null,
    toTemporalMarketObservation(
      current.artifact,
      current.capturedAt,
      current.source,
    ),
  );
}
