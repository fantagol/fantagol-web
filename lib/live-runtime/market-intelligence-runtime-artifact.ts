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

export type MarketRuntimePrimaryOutcome =
  | "1"
  | "X"
  | "2";

export type MarketRuntimeArtifact = {
  providerEventId: string;
  modelCode: "BM_INTERPOLATED";
  algorithmVersion: "BM_INTERPOLATED_V1";
  input: MarketIntelligenceInput;
  output: BmInterpolatedResult;
  primaryOutcome: MarketRuntimePrimaryOutcome;
};

function primaryOutcome(
  result: BmInterpolatedResult,
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
): MarketRuntimeArtifact {
  const input =
    normalizeMarketIntelligenceInput(event);

  const output =
    buildBmInterpolatedResult(input);

  verifyBmInterpolatedResult(output);

  return {
    providerEventId:
      input.providerEventId,
    modelCode:
      output.modelCode,
    algorithmVersion:
      output.algorithmVersion,
    input,
    output,
    primaryOutcome:
      primaryOutcome(output),
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
