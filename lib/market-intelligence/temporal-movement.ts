export type MarketObservationSource =
  | "PACKAGE"
  | "ADVANCED";

export type MovementDirection =
  | "UP"
  | "DOWN"
  | "FLAT";

export interface TemporalExactSignal {
  score: string;
  probability: number;
}

export interface TemporalMarketObservation {
  capturedAt: string;

  source:
    MarketObservationSource;

  exact:
    TemporalExactSignal[];

  sign: {
    home: number;
    draw: number;
    away: number;
  };

  totals: {
    over: number;
    under: number;
  };

  btts: {
    goal: number;
    noGoal: number;
  };

  marketConfidence: number;
  finalConfidence: number;
}

export interface ProbabilityMovement {
  previous: number | null;
  current: number;

  delta: number | null;
  deltaPercentagePoints: number | null;

  direction:
    MovementDirection;
}

export interface ExactMovement
  extends ProbabilityMovement {
  score: string;
  previousRank: number | null;
  currentRank: number;
  rankDelta: number | null;
}

export interface TemporalMovementResult {
  previousCapturedAt:
    string | null;

  currentCapturedAt:
    string;

  previousSource:
    MarketObservationSource | null;

  currentSource:
    MarketObservationSource;

  exact:
    ExactMovement[];

  sign: {
    home: ProbabilityMovement;
    draw: ProbabilityMovement;
    away: ProbabilityMovement;
  };

  totals: {
    over: ProbabilityMovement;
    under: ProbabilityMovement;
  };

  btts: {
    goal: ProbabilityMovement;
    noGoal: ProbabilityMovement;
  };

  marketConfidence:
    ProbabilityMovement;

  finalConfidence:
    ProbabilityMovement;

  movementMagnitude: number;
}

const DEFAULT_FLAT_EPSILON =
  0.0005;

function clampProbability(
  value: number,
): number {
  return Math.max(
    0,
    Math.min(1, value),
  );
}

function directionFromDelta(
  delta: number | null,
  epsilon: number,
): MovementDirection {
  if (delta === null) {
    return "FLAT";
  }

  if (delta > epsilon) {
    return "UP";
  }

  if (delta < -epsilon) {
    return "DOWN";
  }

  return "FLAT";
}

function movement(
  previous: number | null,
  current: number,
  epsilon: number,
): ProbabilityMovement {
  const safeCurrent =
    clampProbability(current);

  const safePrevious =
    previous === null
      ? null
      : clampProbability(previous);

  const delta =
    safePrevious === null
      ? null
      : safeCurrent -
        safePrevious;

  return {
    previous:
      safePrevious,

    current:
      safeCurrent,

    delta,

    deltaPercentagePoints:
      delta === null
        ? null
        : delta * 100,

    direction:
      directionFromDelta(
        delta,
        epsilon,
      ),
  };
}

function previousExactMap(
  observation:
    TemporalMarketObservation | null,
): Map<
  string,
  {
    probability: number;
    rank: number;
  }
> {
  const result =
    new Map<
      string,
      {
        probability: number;
        rank: number;
      }
    >();

  if (!observation) {
    return result;
  }

  observation.exact.forEach(
    (item, index) => {
      result.set(
        item.score,
        {
          probability:
            item.probability,

          rank:
            index + 1,
        },
      );
    },
  );

  return result;
}

export function calculateTemporalMovement(
  previous:
    TemporalMarketObservation | null,

  current:
    TemporalMarketObservation,

  options?: {
    exactLimit?: number;
    flatEpsilon?: number;
  },
): TemporalMovementResult {
  const exactLimit =
    options?.exactLimit ?? 5;

  const epsilon =
    options?.flatEpsilon ??
    DEFAULT_FLAT_EPSILON;

  const previousExact =
    previousExactMap(
      previous,
    );

  const exact:
    ExactMovement[] =
    current.exact
      .slice(0, exactLimit)
      .map(
        (item, index) => {
          const old =
            previousExact.get(
              item.score,
            );

          const base =
            movement(
              old?.probability ??
                null,

              item.probability,

              epsilon,
            );

          const currentRank =
            index + 1;

          return {
            score:
              item.score,

            ...base,

            previousRank:
              old?.rank ??
              null,

            currentRank,

            rankDelta:
              old
                ? old.rank -
                  currentRank
                : null,
          };
        },
      );

  const sign = {
    home:
      movement(
        previous?.sign.home ??
          null,

        current.sign.home,

        epsilon,
      ),

    draw:
      movement(
        previous?.sign.draw ??
          null,

        current.sign.draw,

        epsilon,
      ),

    away:
      movement(
        previous?.sign.away ??
          null,

        current.sign.away,

        epsilon,
      ),
  };

  const totals = {
    over:
      movement(
        previous?.totals.over ??
          null,

        current.totals.over,

        epsilon,
      ),

    under:
      movement(
        previous?.totals.under ??
          null,

        current.totals.under,

        epsilon,
      ),
  };

  const btts = {
    goal:
      movement(
        previous?.btts.goal ??
          null,

        current.btts.goal,

        epsilon,
      ),

    noGoal:
      movement(
        previous?.btts.noGoal ??
          null,

        current.btts.noGoal,

        epsilon,
      ),
  };

  const marketConfidence =
    movement(
      previous
        ?.marketConfidence ??
        null,

      current.marketConfidence,

      epsilon,
    );

  const finalConfidence =
    movement(
      previous
        ?.finalConfidence ??
        null,

      current.finalConfidence,

      epsilon,
    );

  /*
   * Movement magnitude describes how much
   * the central BM interpretation moved.
   *
   * Confidence changes are intentionally
   * excluded: they measure evidence quality,
   * not prediction direction.
   */
  const directionalDeltas =
    [
      sign.home.delta,
      sign.draw.delta,
      sign.away.delta,

      totals.over.delta,
      totals.under.delta,

      btts.goal.delta,
      btts.noGoal.delta,
    ].filter(
      (
        value,
      ): value is number =>
        value !== null,
    );

  const movementMagnitude =
    directionalDeltas.length === 0
      ? 0
      : directionalDeltas.reduce(
          (sum, value) =>
            sum +
            Math.abs(value),
          0,
        ) /
        directionalDeltas.length;

  return {
    previousCapturedAt:
      previous?.capturedAt ??
      null,

    currentCapturedAt:
      current.capturedAt,

    previousSource:
      previous?.source ??
      null,

    currentSource:
      current.source,

    exact,

    sign,
    totals,
    btts,

    marketConfidence,
    finalConfidence,

    movementMagnitude,
  };
}

export function movementArrow(
  direction:
    MovementDirection,
): "↑" | "↓" | "−" {
  switch (direction) {
    case "UP":
      return "↑";

    case "DOWN":
      return "↓";

    case "FLAT":
      return "−";
  }
}