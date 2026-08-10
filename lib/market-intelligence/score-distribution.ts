import type {
  MarketIntelligenceInput,
} from "./contracts";

import {
  buildMarketConsensus,
  type MarketConsensus,
} from "./consensus";

export interface ScoreCell {
  homeGoals: number;
  awayGoals: number;
  probability: number;
}

export interface ExactPrediction {
  score: string;
  homeGoals: number;
  awayGoals: number;
  probability: number;
}

export interface SignDistribution {
  home: number;
  draw: number;
  away: number;
}

export interface TotalsDistribution {
  line: 2.5;
  over: number;
  under: number;
}

export interface BttsDistribution {
  goal: number;
  noGoal: number;
}

export interface ModelFit {
  h2hError: number | null;
  totalsError: number | null;
  bttsError: number | null;
  correctScoreError: number | null;
  totalLoss: number;
}

export interface BmInterpolatedResult {
  modelCode: "BM_INTERPOLATED";
  algorithmVersion: "BM_INTERPOLATED_V1";

  lambdaHome: number;
  lambdaAway: number;

  scoreMatrix: ScoreCell[];

  exact: ExactPrediction[];
  sign: SignDistribution;
  totals: TotalsDistribution;
  btts: BttsDistribution;

  marketConfidence: number;
  modelFit: ModelFit;
  confidence: number;
}

interface MarketTargets {
  home: number | null;
  draw: number | null;
  away: number | null;

  over25: number | null;
  under25: number | null;

  bttsYes: number | null;
  bttsNo: number | null;

  correctScores: Map<string, number>;
}

const MAX_GOALS = 8;

function normalizeName(value: string): string {
  return value.trim().toLowerCase();
}

function poisson(
  lambda: number,
  goals: number,
): number {
  let factorial = 1;

  for (let index = 2; index <= goals; index += 1) {
    factorial *= index;
  }

  return (
    Math.exp(-lambda) *
    Math.pow(lambda, goals) /
    factorial
  );
}

function createMatrix(
  lambdaHome: number,
  lambdaAway: number,
): ScoreCell[] {
  const cells: ScoreCell[] = [];

  for (
    let homeGoals = 0;
    homeGoals <= MAX_GOALS;
    homeGoals += 1
  ) {
    const homeProbability =
      poisson(lambdaHome, homeGoals);

    for (
      let awayGoals = 0;
      awayGoals <= MAX_GOALS;
      awayGoals += 1
    ) {
      cells.push({
        homeGoals,
        awayGoals,
        probability:
          homeProbability *
          poisson(lambdaAway, awayGoals),
      });
    }
  }

  const total = cells.reduce(
    (sum, cell) => sum + cell.probability,
    0,
  );

  return cells.map((cell) => ({
    ...cell,
    probability: cell.probability / total,
  }));
}

function deriveSign(
  matrix: ScoreCell[],
): SignDistribution {
  let home = 0;
  let draw = 0;
  let away = 0;

  for (const cell of matrix) {
    if (cell.homeGoals > cell.awayGoals) {
      home += cell.probability;
    } else if (cell.homeGoals === cell.awayGoals) {
      draw += cell.probability;
    } else {
      away += cell.probability;
    }
  }

  return { home, draw, away };
}

function deriveTotals(
  matrix: ScoreCell[],
): TotalsDistribution {
  let over = 0;
  let under = 0;

  for (const cell of matrix) {
    if (cell.homeGoals + cell.awayGoals > 2.5) {
      over += cell.probability;
    } else {
      under += cell.probability;
    }
  }

  return {
    line: 2.5,
    over,
    under,
  };
}

function deriveBtts(
  matrix: ScoreCell[],
): BttsDistribution {
  let goal = 0;
  let noGoal = 0;

  for (const cell of matrix) {
    if (
      cell.homeGoals > 0 &&
      cell.awayGoals > 0
    ) {
      goal += cell.probability;
    } else {
      noGoal += cell.probability;
    }
  }

  return { goal, noGoal };
}

function findOutcome(
  consensus: MarketConsensus | undefined,
  candidates: string[],
  point?: number,
): number | null {
  if (!consensus) return null;

  const normalizedCandidates =
    candidates.map(normalizeName);

  const outcome = consensus.outcomes.find(
    (item) => {
      const name = normalizeName(item.name);

      const nameMatches =
        normalizedCandidates.includes(name);

      const pointMatches =
        point === undefined ||
        item.point === point;

      return nameMatches && pointMatches;
    },
  );

  return outcome?.probability ?? null;
}

function buildTargets(
  input: MarketIntelligenceInput,
  consensus: MarketConsensus[],
): MarketTargets {
  const h2h = consensus.find(
    (market) => market.marketKey === "h2h",
  );

  const totals = consensus.find(
    (market) => market.marketKey === "totals",
  );

  const alternateTotals = consensus.find(
    (market) =>
      market.marketKey === "alternate_totals",
  );

  const btts = consensus.find(
    (market) => market.marketKey === "btts",
  );

  const correctScore = consensus.find(
    (market) =>
      market.marketKey === "correct_score",
  );

  const home =
    findOutcome(h2h, [
      input.homeTeam,
      "home",
      "1",
    ]);

  const draw =
    findOutcome(h2h, [
      "draw",
      "x",
    ]);

  const away =
    findOutcome(h2h, [
      input.awayTeam,
      "away",
      "2",
    ]);

  const over25 =
    findOutcome(
      totals,
      ["over"],
      2.5,
    ) ??
    findOutcome(
      alternateTotals,
      ["over"],
      2.5,
    );

  const under25 =
    findOutcome(
      totals,
      ["under"],
      2.5,
    ) ??
    findOutcome(
      alternateTotals,
      ["under"],
      2.5,
    );

  const bttsYes =
    findOutcome(btts, [
      "yes",
      "goal",
    ]);

  const bttsNo =
    findOutcome(btts, [
      "no",
      "no goal",
      "nogoal",
    ]);

  const correctScores =
    new Map<string, number>();

  if (correctScore) {
    for (const outcome of correctScore.outcomes) {
      /*
       * Supported provider forms:
       *
       * 2-1
       * 2:1
       * Home Team:2|Away Team:1
       * Away Team:1|Home Team:0
       */

      const simple =
        outcome.name.match(
          /^(\d+)\s*[-:]\s*(\d+)$/,
        );

      if (simple) {
        correctScores.set(
          `${Number(simple[1])}-${Number(simple[2])}`,
          outcome.probability,
        );

        continue;
      }

      const parts =
        outcome.name
          .split("|")
          .map(
            (part) =>
              part.trim(),
          );

      if (parts.length !== 2) {
        continue;
      }

      const parseTeamScore =
        (
          part: string,
        ): {
          team: string;
          goals: number;
        } | null => {
          const separator =
            part.lastIndexOf(":");

          if (separator <= 0) {
            return null;
          }

          const team =
            part
              .slice(0, separator)
              .trim();

          const rawGoals =
            part
              .slice(separator + 1)
              .trim();

          const goals =
            Number(rawGoals);

          if (
            team.length === 0 ||
            !Number.isInteger(goals) ||
            goals < 0
          ) {
            return null;
          }

          return {
            team,
            goals,
          };
        };

      const first =
        parseTeamScore(parts[0]);

      const second =
        parseTeamScore(parts[1]);

      if (!first || !second) {
        continue;
      }

      const normalizeTeam =
        (value: string) =>
          value
            .trim()
            .toLowerCase();

      const homeTeam =
        normalizeTeam(
          input.homeTeam,
        );

      const awayTeam =
        normalizeTeam(
          input.awayTeam,
        );

      const firstTeam =
        normalizeTeam(
          first.team,
        );

      const secondTeam =
        normalizeTeam(
          second.team,
        );

      if (
        firstTeam === homeTeam &&
        secondTeam === awayTeam
      ) {
        correctScores.set(
          `${first.goals}-${second.goals}`,
          outcome.probability,
        );

        continue;
      }

      if (
        firstTeam === awayTeam &&
        secondTeam === homeTeam
      ) {
        correctScores.set(
          `${second.goals}-${first.goals}`,
          outcome.probability,
        );
      }
    }
  }

  return {
    home,
    draw,
    away,
    over25,
    under25,
    bttsYes,
    bttsNo,
    correctScores,
  };
}

function squaredError(
  actual: number,
  target: number,
): number {
  const delta = actual - target;
  return delta * delta;
}

function evaluateFit(
  matrix: ScoreCell[],
  targets: MarketTargets,
): ModelFit {
  const sign = deriveSign(matrix);
  const totals = deriveTotals(matrix);
  const btts = deriveBtts(matrix);

  let h2hError: number | null = null;

  if (
    targets.home !== null &&
    targets.draw !== null &&
    targets.away !== null
  ) {
    h2hError =
      squaredError(sign.home, targets.home) +
      squaredError(sign.draw, targets.draw) +
      squaredError(sign.away, targets.away);
  }

  let totalsError: number | null = null;

  if (
    targets.over25 !== null &&
    targets.under25 !== null
  ) {
    totalsError =
      squaredError(
        totals.over,
        targets.over25,
      ) +
      squaredError(
        totals.under,
        targets.under25,
      );
  }

  let bttsError: number | null = null;

  if (
    targets.bttsYes !== null &&
    targets.bttsNo !== null
  ) {
    bttsError =
      squaredError(
        btts.goal,
        targets.bttsYes,
      ) +
      squaredError(
        btts.noGoal,
        targets.bttsNo,
      );
  }

  let correctScoreError: number | null = null;

  if (targets.correctScores.size > 0) {
    let sum = 0;
    let count = 0;

    for (
      const [score, target]
      of targets.correctScores
    ) {
      const [homeGoals, awayGoals] =
        score.split("-").map(Number);

      const cell = matrix.find(
        (item) =>
          item.homeGoals === homeGoals &&
          item.awayGoals === awayGoals,
      );

      if (!cell) continue;

      sum += squaredError(
        cell.probability,
        target,
      );

      count += 1;
    }

    if (count > 0) {
      correctScoreError = sum / count;
    }
  }

  /*
   * H2H and totals are the structural anchors.
   * BTTS refines the joint distribution.
   * Correct score is intentionally low-weight auxiliary evidence.
   */
  const totalLoss =
    (h2hError ?? 0) * 1.00 +
    (totalsError ?? 0) * 1.00 +
    (bttsError ?? 0) * 0.65 +
    (correctScoreError ?? 0) * 0.15;

  return {
    h2hError,
    totalsError,
    bttsError,
    correctScoreError,
    totalLoss,
  };
}

function fitDistribution(
  targets: MarketTargets,
): {
  lambdaHome: number;
  lambdaAway: number;
  matrix: ScoreCell[];
  fit: ModelFit;
} {
  let best:
    | {
        lambdaHome: number;
        lambdaAway: number;
        matrix: ScoreCell[];
        fit: ModelFit;
      }
    | null = null;

  /*
   * Coarse deterministic search.
   * 0.20..4.50 covers the practical football range
   * while remaining bounded and reproducible.
   */
  for (
    let homeStep = 4;
    homeStep <= 90;
    homeStep += 1
  ) {
    const lambdaHome = homeStep * 0.05;

    for (
      let awayStep = 4;
      awayStep <= 90;
      awayStep += 1
    ) {
      const lambdaAway = awayStep * 0.05;

      const matrix = createMatrix(
        lambdaHome,
        lambdaAway,
      );

      const fit = evaluateFit(
        matrix,
        targets,
      );

      if (
        !best ||
        fit.totalLoss < best.fit.totalLoss
      ) {
        best = {
          lambdaHome,
          lambdaAway,
          matrix,
          fit,
        };
      }
    }
  }

  if (!best) {
    throw new Error(
      "BM_INTERPOLATED_DISTRIBUTION_FIT_FAILED",
    );
  }

  /*
   * Local refinement around the coarse optimum.
   */
  let refined = best;

  for (
    let homeOffset = -10;
    homeOffset <= 10;
    homeOffset += 1
  ) {
    for (
      let awayOffset = -10;
      awayOffset <= 10;
      awayOffset += 1
    ) {
      const lambdaHome =
        best.lambdaHome +
        homeOffset * 0.005;

      const lambdaAway =
        best.lambdaAway +
        awayOffset * 0.005;

      if (
        lambdaHome <= 0 ||
        lambdaAway <= 0
      ) {
        continue;
      }

      const matrix = createMatrix(
        lambdaHome,
        lambdaAway,
      );

      const fit = evaluateFit(
        matrix,
        targets,
      );

      if (
        fit.totalLoss <
        refined.fit.totalLoss
      ) {
        refined = {
          lambdaHome,
          lambdaAway,
          matrix,
          fit,
        };
      }
    }
  }

  return refined;
}

function calculateMarketConfidence(
  input: MarketIntelligenceInput,
  consensus: MarketConsensus[],
): number {
  if (consensus.length === 0) return 0;

  const weighted = consensus.map(
    (market) => {
      const weight =
        market.marketKey === "h2h"
          ? 0.35
          : market.marketKey === "totals"
            ? 0.30
            : market.marketKey ===
                "alternate_totals"
              ? 0.15
              : market.marketKey === "btts"
                ? 0.15
                : 0.05;

      return {
        value: market.confidence,
        weight,
      };
    },
  );

  const availableWeight =
    weighted.reduce(
      (sum, item) => sum + item.weight,
      0,
    );

  const consensusConfidence =
    availableWeight === 0
      ? 0
      : weighted.reduce(
          (sum, item) =>
            sum + item.value * item.weight,
          0,
        ) / availableWeight;

  return (
    Math.round(
      (
        consensusConfidence * 0.7 +
        input.qualityScore * 0.3
      ) *
        1_000_000,
    ) / 1_000_000
  );
}

function fitConfidence(
  loss: number,
): number {
  return Math.max(
    0,
    Math.min(
      1,
      1 / (1 + loss * 25),
    ),
  );
}

export function buildBmInterpolatedResult(
  input: MarketIntelligenceInput,
): BmInterpolatedResult {
  const consensus =
    buildMarketConsensus(input);

  const targets =
    buildTargets(input, consensus);

  if (
    targets.home === null ||
    targets.draw === null ||
    targets.away === null
  ) {
    throw new Error(
      "BM_INTERPOLATED_H2H_REQUIRED",
    );
  }

  if (
    targets.over25 === null ||
    targets.under25 === null
  ) {
    throw new Error(
      "BM_INTERPOLATED_TOTALS_25_REQUIRED",
    );
  }

  const fitted =
    fitDistribution(targets);

  const sign =
    deriveSign(fitted.matrix);

  const totals =
    deriveTotals(fitted.matrix);

  const btts =
    deriveBtts(fitted.matrix);

  const exact =
    fitted.matrix
      .map((cell) => ({
        score:
          `${cell.homeGoals}-${cell.awayGoals}`,
        homeGoals: cell.homeGoals,
        awayGoals: cell.awayGoals,
        probability: cell.probability,
      }))
      .sort(
        (a, b) =>
          b.probability -
          a.probability,
      );

  const marketConfidence =
    calculateMarketConfidence(
      input,
      consensus,
    );

  const modelFitConfidence =
    fitConfidence(
      fitted.fit.totalLoss,
    );

  const confidence =
    Math.round(
      (
        marketConfidence * 0.65 +
        modelFitConfidence * 0.35
      ) *
        1_000_000,
    ) / 1_000_000;

  return {
    modelCode: "BM_INTERPOLATED",
    algorithmVersion:
      "BM_INTERPOLATED_V1",

    lambdaHome:
      fitted.lambdaHome,

    lambdaAway:
      fitted.lambdaAway,

    scoreMatrix:
      fitted.matrix,

    exact,

    sign,
    totals,
    btts,

    marketConfidence,
    modelFit:
      fitted.fit,

    confidence,
  };
}

export function verifyBmInterpolatedResult(
  result: BmInterpolatedResult,
  tolerance = 1e-9,
): void {
  const matrixSum =
    result.scoreMatrix.reduce(
      (sum, cell) =>
        sum + cell.probability,
      0,
    );

  if (
    Math.abs(matrixSum - 1) >
    tolerance
  ) {
    throw new Error(
      "BM_INTERPOLATED_MATRIX_NOT_NORMALIZED",
    );
  }

  const signSum =
    result.sign.home +
    result.sign.draw +
    result.sign.away;

  if (
    Math.abs(signSum - 1) >
    tolerance
  ) {
    throw new Error(
      "BM_INTERPOLATED_SIGN_NOT_NORMALIZED",
    );
  }

  const totalsSum =
    result.totals.over +
    result.totals.under;

  if (
    Math.abs(totalsSum - 1) >
    tolerance
  ) {
    throw new Error(
      "BM_INTERPOLATED_TOTALS_NOT_NORMALIZED",
    );
  }

  const bttsSum =
    result.btts.goal +
    result.btts.noGoal;

  if (
    Math.abs(bttsSum - 1) >
    tolerance
  ) {
    throw new Error(
      "BM_INTERPOLATED_BTTS_NOT_NORMALIZED",
    );
  }

  const matrixSign =
    deriveSign(result.scoreMatrix);

  const matrixTotals =
    deriveTotals(result.scoreMatrix);

  const matrixBtts =
    deriveBtts(result.scoreMatrix);

  if (
    Math.abs(
      matrixSign.home -
      result.sign.home,
    ) > tolerance ||
    Math.abs(
      matrixSign.draw -
      result.sign.draw,
    ) > tolerance ||
    Math.abs(
      matrixSign.away -
      result.sign.away,
    ) > tolerance
  ) {
    throw new Error(
      "BM_INTERPOLATED_SIGN_MATRIX_MISMATCH",
    );
  }

  if (
    Math.abs(
      matrixTotals.over -
      result.totals.over,
    ) > tolerance ||
    Math.abs(
      matrixTotals.under -
      result.totals.under,
    ) > tolerance
  ) {
    throw new Error(
      "BM_INTERPOLATED_TOTALS_MATRIX_MISMATCH",
    );
  }

  if (
    Math.abs(
      matrixBtts.goal -
      result.btts.goal,
    ) > tolerance ||
    Math.abs(
      matrixBtts.noGoal -
      result.btts.noGoal,
    ) > tolerance
  ) {
    throw new Error(
      "BM_INTERPOLATED_BTTS_MATRIX_MISMATCH",
    );
  }
}