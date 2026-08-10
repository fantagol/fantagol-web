import type {
  MarketDepth,
  MarketIntelligenceMarketKey,
  MarketIntelligenceQuality,
} from "./contracts";

export const MARKET_MINIMUM_BOOKMAKERS: Record<
  MarketIntelligenceMarketKey,
  number
> = {
  h2h: 3,
  totals: 3,
  alternate_totals: 2,
  btts: 2,
  correct_score: 1,
};

export const MARKET_STRONG_BOOKMAKERS: Record<
  MarketIntelligenceMarketKey,
  number
> = {
  h2h: 8,
  totals: 8,
  alternate_totals: 4,
  btts: 5,
  correct_score: 3,
};

export function classifyMarketDepth(
  marketKey: MarketIntelligenceMarketKey,
  validBookmakerCount: number,
): MarketIntelligenceQuality {
  const minimum =
    MARKET_MINIMUM_BOOKMAKERS[marketKey];

  const strong =
    MARKET_STRONG_BOOKMAKERS[marketKey];

  if (validBookmakerCount >= strong) {
    return "strong";
  }

  if (validBookmakerCount >= minimum) {
    return "usable";
  }

  if (validBookmakerCount > 0) {
    return "thin";
  }

  return "insufficient";
}

function qualityValue(
  quality: MarketIntelligenceQuality,
): number {
  switch (quality) {
    case "strong":
      return 1;

    case "usable":
      return 0.72;

    case "thin":
      return 0.38;

    case "insufficient":
      return 0;
  }
}

const MARKET_QUALITY_WEIGHTS: Record<
  MarketIntelligenceMarketKey,
  number
> = {
  h2h: 0.35,
  totals: 0.30,
  alternate_totals: 0.15,
  btts: 0.15,
  correct_score: 0.05,
};

export function calculateInputQuality(
  depth: MarketDepth[],
): {
  score: number;
  quality: MarketIntelligenceQuality;
} {
  const byMarket = new Map(
    depth.map((item) => [
      item.marketKey,
      item,
    ]),
  );

  let score = 0;

  for (
    const [marketKey, weight]
    of Object.entries(
      MARKET_QUALITY_WEIGHTS,
    ) as Array<
      [
        MarketIntelligenceMarketKey,
        number,
      ]
    >
  ) {
    const market =
      byMarket.get(marketKey);

    score +=
      weight *
      qualityValue(
        market?.quality ??
          "insufficient",
      );
  }

  const rounded =
    Math.round(score * 1_000_000) /
    1_000_000;

  if (rounded >= 0.80) {
    return {
      score: rounded,
      quality: "strong",
    };
  }

  if (rounded >= 0.55) {
    return {
      score: rounded,
      quality: "usable",
    };
  }

  if (rounded > 0) {
    return {
      score: rounded,
      quality: "thin",
    };
  }

  return {
    score: 0,
    quality: "insufficient",
  };
}