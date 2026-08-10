import {
  BM_INTERPOLATED_ALGORITHM_VERSION,
  BM_INTERPOLATED_MODEL_CODE,
  type MarketDepth,
  type MarketIntelligenceInput,
  type MarketIntelligenceMarketKey,
  type MarketIntelligenceSignal,
  type MarketRejection,
  type NormalizedBookmakerMarket,
  type NormalizedOutcome,
  type ProviderEventOdds,
  type ProviderMarket,
} from "./contracts";

import {
  calculateInputQuality,
  classifyMarketDepth,
} from "./quality";

const SUPPORTED_MARKETS =
  new Set<MarketIntelligenceMarketKey>([
    "h2h",
    "totals",
    "alternate_totals",
    "btts",
    "correct_score",
  ]);

const MAX_ACCEPTED_OVERROUND = 1.35;

const MIN_ACCEPTED_PROBABILITY_SUM = 0.90;

function isSupportedMarket(
  key: string,
): key is MarketIntelligenceMarketKey {
  return SUPPORTED_MARKETS.has(
    key as MarketIntelligenceMarketKey,
  );
}

function requiredOutcomeCount(
  marketKey: MarketIntelligenceMarketKey,
): number {
  switch (marketKey) {
    case "h2h":
      return 3;

    case "totals":
    case "alternate_totals":
    case "btts":
      return 2;

    case "correct_score":
      return 3;
  }
}

function normalizeOutcomeGroup(
  bookmakerKey: string,
  marketKey: MarketIntelligenceMarketKey,
  outcomes: ProviderMarket["outcomes"],
):
  | {
      outcomes: NormalizedOutcome[];
      overround: number;
      rejection: null;
    }
  | {
      outcomes: null;
      overround: null;
      rejection: MarketRejection;
    } {
  const rawProbabilities =
    outcomes.map(
      (outcome) => 1 / outcome.price,
    );

  const probabilitySum =
    rawProbabilities.reduce(
      (sum, probability) =>
        sum + probability,
      0,
    );

  if (
    !Number.isFinite(probabilitySum) ||
    probabilitySum <
      MIN_ACCEPTED_PROBABILITY_SUM
  ) {
    return {
      outcomes: null,
      overround: null,
      rejection: {
        bookmakerKey,
        marketKey,
        reason:
          "invalid_probability_sum",
        details:
          String(probabilitySum),
      },
    };
  }

  if (
    probabilitySum >
    MAX_ACCEPTED_OVERROUND
  ) {
    return {
      outcomes: null,
      overround: null,
      rejection: {
        bookmakerKey,
        marketKey,
        reason:
          "extreme_overround",
        details:
          String(probabilitySum),
      },
    };
  }

  return {
    outcomes:
      outcomes.map(
        (outcome, index) => ({
          name: outcome.name,
          point:
            outcome.point ??
            null,
          decimalOdds:
            outcome.price,
          rawImpliedProbability:
            rawProbabilities[index],
          fairProbability:
            rawProbabilities[index] /
            probabilitySum,
        }),
      ),

    overround:
      probabilitySum,

    rejection:
      null,
  };
}
function normalizeMarket(
  bookmakerKey: string,
  bookmakerTitle: string | null,
  market: ProviderMarket,
):
  | {
      normalized: NormalizedBookmakerMarket;
      rejection: null;
    }
  | {
      normalized: null;
      rejection: MarketRejection;
    } {

  if (!isSupportedMarket(market.key)) {
    return {
      normalized: null,
      rejection: {
        bookmakerKey,
        marketKey: market.key,
        reason: "unsupported_market",
      },
    };
  }

  if (
    !Array.isArray(market.outcomes) ||
    market.outcomes.length === 0
  ) {
    return {
      normalized: null,
      rejection: {
        bookmakerKey,
        marketKey: market.key,
        reason: "missing_outcomes",
      },
    };
  }

  if (
    market.outcomes.length <
    requiredOutcomeCount(market.key)
  ) {
    return {
      normalized: null,
      rejection: {
        bookmakerKey,
        marketKey: market.key,
        reason: "insufficient_outcomes",
      },
    };
  }

  const identities =
    new Set<string>();

  for (const outcome of market.outcomes) {

    if (
      !Number.isFinite(outcome.price) ||
      outcome.price <= 1
    ) {
      return {
        normalized: null,
        rejection: {
          bookmakerKey,
          marketKey: market.key,
          reason: "invalid_price",
        },
      };
    }

    const identity =
      `${outcome.name}::${outcome.point ?? ""}`;

    if (identities.has(identity)) {
      return {
        normalized: null,
        rejection: {
          bookmakerKey,
          marketKey: market.key,
          reason: "duplicate_outcome",
          details: identity,
        },
      };
    }

    identities.add(identity);

    if (
      (
        market.key === "totals" ||
        market.key ===
          "alternate_totals"
      ) &&
      (
        outcome.point === null ||
        outcome.point === undefined ||
        !Number.isFinite(
          outcome.point,
        ) ||
        outcome.point <= 0
      )
    ) {
      return {
        normalized: null,
        rejection: {
          bookmakerKey,
          marketKey: market.key,
          reason: "invalid_total_line",
        },
      };
    }
  }

  /*
   * Correct Score is a many-outcome market.
   * Its aggregate bookmaker margin can legitimately exceed
   * the generic 1.35 threshold used by compact markets.
   *
   * We validate each price independently and then remove
   * the total market margin across the complete score grid.
   */
  if (market.key === "correct_score") {
    const validOutcomes =
      market.outcomes.filter(
        (outcome) =>
          Number.isFinite(outcome.price) &&
          outcome.price > 1,
      );

    if (validOutcomes.length < 3) {
      return {
        normalized: null,
        rejection: {
          bookmakerKey,
          marketKey: market.key,
          reason:
            "insufficient_outcomes",
        },
      };
    }

    const rawProbabilities =
      validOutcomes.map(
        (outcome) =>
          1 / outcome.price,
      );

    const probabilitySum =
      rawProbabilities.reduce(
        (sum, probability) =>
          sum + probability,
        0,
      );

    if (
      !Number.isFinite(probabilitySum) ||
      probabilitySum <= 0
    ) {
      return {
        normalized: null,
        rejection: {
          bookmakerKey,
          marketKey: market.key,
          reason:
            "invalid_probability_sum",
          details:
            String(probabilitySum),
        },
      };
    }

    const outcomes:
      NormalizedOutcome[] =
      validOutcomes.map(
        (outcome, index) => ({
          name:
            outcome.name,

          point:
            outcome.point ??
            null,

          decimalOdds:
            outcome.price,

          rawImpliedProbability:
            rawProbabilities[index],

          fairProbability:
            rawProbabilities[index] /
            probabilitySum,
        }),
      );

    return {
      normalized: {
        bookmakerKey,
        bookmakerTitle,

        marketKey:
          market.key,

        lastUpdate:
          market.last_update ??
          null,

        overround:
          probabilitySum,

        outcomes,
      },

      rejection:
        null,
    };
  }
  /*
   * Alternate totals contains several independent
   * Over/Under lines inside the same provider market.
   * Normalize each point independently.
   */
  if (market.key === "alternate_totals") {
    const byPoint =
      new Map<
        number,
        ProviderMarket["outcomes"]
      >();

    for (const outcome of market.outcomes) {
      if (
        outcome.point === null ||
        outcome.point === undefined ||
        !Number.isFinite(outcome.point)
      ) {
        continue;
      }

      const existing =
        byPoint.get(outcome.point);

      if (existing) {
        existing.push(outcome);
      } else {
        byPoint.set(
          outcome.point,
          [outcome],
        );
      }
    }

    const normalizedOutcomes:
      NormalizedOutcome[] = [];

    const lineOverrounds:
      number[] = [];

    for (
      const [, lineOutcomes]
      of byPoint
    ) {
      if (lineOutcomes.length < 2) {
        continue;
      }

      const group =
        normalizeOutcomeGroup(
          bookmakerKey,
          market.key,
          lineOutcomes,
        );

      if (group.rejection) {
        continue;
      }

      normalizedOutcomes.push(
        ...group.outcomes,
      );

      lineOverrounds.push(
        group.overround,
      );
    }

    if (normalizedOutcomes.length < 2) {
      return {
        normalized: null,
        rejection: {
          bookmakerKey,
          marketKey: market.key,
          reason:
            "insufficient_outcomes",
        },
      };
    }

    const meanOverround =
      lineOverrounds.reduce(
        (sum, value) =>
          sum + value,
        0,
      ) /
      lineOverrounds.length;

    return {
      normalized: {
        bookmakerKey,
        bookmakerTitle,
        marketKey:
          market.key,
        lastUpdate:
          market.last_update ??
          null,
        overround:
          meanOverround,
        outcomes:
          normalizedOutcomes,
      },

      rejection:
        null,
    };
  }

  const group =
    normalizeOutcomeGroup(
      bookmakerKey,
      market.key,
      market.outcomes,
    );

  if (group.rejection) {
    return {
      normalized: null,
      rejection:
        group.rejection,
    };
  }

  return {
    normalized: {
      bookmakerKey,
      bookmakerTitle,
      marketKey:
        market.key,
      lastUpdate:
        market.last_update ??
        null,
      overround:
        group.overround,
      outcomes:
        group.outcomes,
    },

    rejection: null,
  };
}

function deriveSignals(
  markets:
    NormalizedBookmakerMarket[],
): MarketIntelligenceSignal[] {

  const keys =
    new Set(
      markets.map(
        (market) =>
          market.marketKey,
      ),
    );

  const signals:
    MarketIntelligenceSignal[] = [];

  if (keys.has("h2h")) {
    signals.push("SIGN");
  }

  if (
    keys.has("totals") ||
    keys.has(
      "alternate_totals",
    )
  ) {
    signals.push("TOTALS");
  }

  if (keys.has("btts")) {
    signals.push("BTTS");
  }

  if (
    keys.has("h2h") &&
    (
      keys.has("totals") ||
      keys.has(
        "alternate_totals",
      )
    )
  ) {
    signals.push("EXACT");
  }

  return signals;
}

export function
normalizeMarketIntelligenceInput(
  event: ProviderEventOdds,
): MarketIntelligenceInput {

  const markets:
    NormalizedBookmakerMarket[] = [];

  const rejections:
    MarketRejection[] = [];

  const rawDepth =
    new Map<
      MarketIntelligenceMarketKey,
      {
        bookmakerKeys:
          Set<string>;

        validBookmakerKeys:
          Set<string>;

        outcomeCount:
          number;
      }
    >();

  for (
    const marketKey
    of SUPPORTED_MARKETS
  ) {
    rawDepth.set(
      marketKey,
      {
        bookmakerKeys:
          new Set(),

        validBookmakerKeys:
          new Set(),

        outcomeCount: 0,
      },
    );
  }

  for (
    const bookmaker
    of event.bookmakers ?? []
  ) {

    for (
      const market
      of bookmaker.markets ?? []
    ) {

      if (
        isSupportedMarket(
          market.key,
        )
      ) {
        rawDepth
          .get(market.key)
          ?.bookmakerKeys
          .add(bookmaker.key);
      }

      const result =
        normalizeMarket(
          bookmaker.key,
          bookmaker.title ??
            null,
          market,
        );

      if (result.rejection) {
        rejections.push(
          result.rejection,
        );

        continue;
      }

      const normalized =
        result.normalized;

      markets.push(
        normalized,
      );

      const depth =
        rawDepth.get(
          normalized.marketKey,
        );

      depth
        ?.validBookmakerKeys
        .add(bookmaker.key);

      if (depth) {
        depth.outcomeCount +=
          normalized
            .outcomes
            .length;
      }
    }
  }

  const depth:
    MarketDepth[] =
    Array.from(
      SUPPORTED_MARKETS,
    ).map(
      (marketKey) => {

        const item =
          rawDepth.get(
            marketKey,
          );

        const bookmakerCount =
          item
            ?.bookmakerKeys
            .size ??
          0;

        const validBookmakerCount =
          item
            ?.validBookmakerKeys
            .size ??
          0;

        return {
          marketKey,

          bookmakerCount,

          validBookmakerCount,

          rejectedBookmakerCount:
            bookmakerCount -
            validBookmakerCount,

          outcomeCount:
            item
              ?.outcomeCount ??
            0,

          quality:
            classifyMarketDepth(
              marketKey,
              validBookmakerCount,
            ),
        };
      },
    );

  const quality =
    calculateInputQuality(
      depth,
    );

  return {
    modelCode:
      BM_INTERPOLATED_MODEL_CODE,

    algorithmVersion:
      BM_INTERPOLATED_ALGORITHM_VERSION,

    providerEventId:
      event.id,

    homeTeam:
      event.home_team,

    awayTeam:
      event.away_team,

    commenceTime:
      event.commence_time ??
      null,

    markets,

    depth,

    rejections,

    availableSignals:
      deriveSignals(
        markets,
      ),

    qualityScore:
      quality.score,

    quality:
      quality.quality,
  };
}