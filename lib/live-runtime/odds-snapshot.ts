export type OneXTwoOutcome = "home" | "draw" | "away";

export type CanonicalBookmakerOneXTwo = {
  bookmakerKey: string;
  bookmakerTitle: string;
  lastUpdate: string | null;
  decimalOdds: Record<OneXTwoOutcome, number>;
  impliedProbabilities: Record<OneXTwoOutcome, number>;
  normalizedProbabilities: Record<OneXTwoOutcome, number>;
  overround: number;
};

export type CanonicalOneXTwoConsensus = {
  method:
    | "median_normalized_probability"
    | "mean_normalized_probability"
    | "single_bookmaker_normalized_probability";
  bookmakersCount: number;
  probabilities: Record<OneXTwoOutcome, number>;
  fairDecimalOdds: Record<OneXTwoOutcome, number>;
};

export type CanonicalOddsSnapshot = {
  schemaVersion: "fantagol_odds_snapshot_v1";
  providerCode: string;
  externalMatchId: string;
  homeTeam: string;
  awayTeam: string;
  commenceTime: string | null;
  collectedAt: string;
  market: "h2h";
  oddsFormat: "decimal";
  bookmakers: CanonicalBookmakerOneXTwo[];
  consensus: CanonicalOneXTwoConsensus | null;
  quality: {
    validBookmakers: number;
    hasConsensus: boolean;
    reason: string | null;
  };
};

const OUTCOMES: OneXTwoOutcome[] = ["home", "draw", "away"];

function mean(values: number[]): number {
  return values.reduce((sum, value) => sum + value, 0) / values.length;
}

function median(values: number[]): number {
  const sorted = [...values].sort((a, b) => a - b);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 0
    ? (sorted[middle - 1] + sorted[middle]) / 2
    : sorted[middle];
}

function round(value: number, decimals: number): number {
  const factor = 10 ** decimals;
  return Math.round((value + Number.EPSILON) * factor) / factor;
}

export function createCanonicalBookmakerOneXTwo(input: {
  bookmakerKey: string;
  bookmakerTitle: string;
  lastUpdate?: string | null;
  home: number;
  draw: number;
  away: number;
}): CanonicalBookmakerOneXTwo {
  const decimalOdds = {
    home: input.home,
    draw: input.draw,
    away: input.away,
  };

  for (const outcome of OUTCOMES) {
    const value = decimalOdds[outcome];
    if (!Number.isFinite(value) || value <= 1) {
      throw new Error(`Invalid decimal odds for '${outcome}': ${String(value)}.`);
    }
  }

  const impliedProbabilities = {
    home: 1 / decimalOdds.home,
    draw: 1 / decimalOdds.draw,
    away: 1 / decimalOdds.away,
  };

  const total =
    impliedProbabilities.home +
    impliedProbabilities.draw +
    impliedProbabilities.away;

  return {
    bookmakerKey: input.bookmakerKey,
    bookmakerTitle: input.bookmakerTitle,
    lastUpdate: input.lastUpdate ?? null,
    decimalOdds,
    impliedProbabilities: {
      home: round(impliedProbabilities.home, 8),
      draw: round(impliedProbabilities.draw, 8),
      away: round(impliedProbabilities.away, 8),
    },
    normalizedProbabilities: {
      home: round(impliedProbabilities.home / total, 8),
      draw: round(impliedProbabilities.draw / total, 8),
      away: round(impliedProbabilities.away / total, 8),
    },
    overround: round(total - 1, 8),
  };
}

export function buildOneXTwoConsensus(
  bookmakers: CanonicalBookmakerOneXTwo[],
): CanonicalOneXTwoConsensus | null {
  if (bookmakers.length === 0) return null;

  const method =
    bookmakers.length >= 3
      ? "median_normalized_probability"
      : bookmakers.length === 2
        ? "mean_normalized_probability"
        : "single_bookmaker_normalized_probability";

  const reducer = bookmakers.length >= 3 ? median : mean;

  const probabilities = {
    home: reducer(bookmakers.map((b) => b.normalizedProbabilities.home)),
    draw: reducer(bookmakers.map((b) => b.normalizedProbabilities.draw)),
    away: reducer(bookmakers.map((b) => b.normalizedProbabilities.away)),
  };

  const total =
    probabilities.home +
    probabilities.draw +
    probabilities.away;

  for (const outcome of OUTCOMES) probabilities[outcome] /= total;

  return {
    method,
    bookmakersCount: bookmakers.length,
    probabilities: {
      home: round(probabilities.home, 8),
      draw: round(probabilities.draw, 8),
      away: round(probabilities.away, 8),
    },
    fairDecimalOdds: {
      home: round(1 / probabilities.home, 4),
      draw: round(1 / probabilities.draw, 4),
      away: round(1 / probabilities.away, 4),
    },
  };
}
