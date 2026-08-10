import type {
  MarketIntelligenceInput,
  MarketIntelligenceMarketKey,
  NormalizedBookmakerMarket,
} from "./contracts";

export interface ConsensusOutcome {
  name: string;
  point: number | null;
  probability: number;
  bookmakerCount: number;
  dispersion: number;
}

export interface MarketConsensus {
  marketKey: MarketIntelligenceMarketKey;
  outcomes: ConsensusOutcome[];
  bookmakerCount: number;
  confidence: number;
}

function median(values: number[]): number {
  if (values.length === 0) return 0;

  const sorted = [...values].sort((a, b) => a - b);
  const middle = Math.floor(sorted.length / 2);

  if (sorted.length % 2 === 1) {
    return sorted[middle];
  }

  return (sorted[middle - 1] + sorted[middle]) / 2;
}

function medianAbsoluteDeviation(values: number[]): number {
  if (values.length <= 1) return 0;

  const center = median(values);

  return median(
    values.map((value) => Math.abs(value - center)),
  );
}

function outcomeIdentity(
  name: string,
  point: number | null,
): string {
  return `${name.trim().toLowerCase()}::${point ?? ""}`;
}

function buildConsensus(
  marketKey: MarketIntelligenceMarketKey,
  markets: NormalizedBookmakerMarket[],
): MarketConsensus | null {
  if (markets.length === 0) return null;

  const observations = new Map<
    string,
    {
      name: string;
      point: number | null;
      probabilities: number[];
    }
  >();

  for (const market of markets) {
    for (const outcome of market.outcomes) {
      const key = outcomeIdentity(
        outcome.name,
        outcome.point,
      );

      const existing = observations.get(key);

      if (existing) {
        existing.probabilities.push(
          outcome.fairProbability,
        );
      } else {
        observations.set(key, {
          name: outcome.name,
          point: outcome.point,
          probabilities: [
            outcome.fairProbability,
          ],
        });
      }
    }
  }

  const raw = Array.from(observations.values()).map(
    (item) => {
      const probability = median(item.probabilities);

      return {
        name: item.name,
        point: item.point,
        probability,
        bookmakerCount: item.probabilities.length,
        dispersion: medianAbsoluteDeviation(
          item.probabilities,
        ),
      };
    },
  );

  /*
   * Do not globally renormalize markets containing multiple
   * independent lines (for example alternate totals).
   * Each line is normalized separately.
   */
  const lineGroups = new Map<string, typeof raw>();

  for (const outcome of raw) {
    const lineKey =
      marketKey === "totals" ||
      marketKey === "alternate_totals"
        ? String(outcome.point)
        : "GLOBAL";

    const group = lineGroups.get(lineKey);

    if (group) {
      group.push(outcome);
    } else {
      lineGroups.set(lineKey, [outcome]);
    }
  }

  const outcomes: ConsensusOutcome[] = [];

  for (const group of lineGroups.values()) {
    const sum = group.reduce(
      (total, item) => total + item.probability,
      0,
    );

    if (sum <= 0) continue;

    for (const item of group) {
      outcomes.push({
        ...item,
        probability: item.probability / sum,
      });
    }
  }

  const dispersions = outcomes.map(
    (outcome) => outcome.dispersion,
  );

  const meanDispersion =
    dispersions.length === 0
      ? 1
      : dispersions.reduce(
          (sum, value) => sum + value,
          0,
        ) / dispersions.length;

  const depthFactor =
    Math.min(1, markets.length / 8);

  const agreementFactor =
    Math.max(0, 1 - meanDispersion * 8);

  const confidence =
    Math.round(
      depthFactor *
        agreementFactor *
        1_000_000,
    ) / 1_000_000;

  return {
    marketKey,
    outcomes,
    bookmakerCount: markets.length,
    confidence,
  };
}

export function buildMarketConsensus(
  input: MarketIntelligenceInput,
): MarketConsensus[] {
  const keys: MarketIntelligenceMarketKey[] = [
    "h2h",
    "totals",
    "alternate_totals",
    "btts",
    "correct_score",
  ];

  const result: MarketConsensus[] = [];

  for (const key of keys) {
    const markets = input.markets.filter(
      (market) => market.marketKey === key,
    );

    const consensus = buildConsensus(key, markets);

    if (consensus) {
      result.push(consensus);
    }
  }

  return result;
}