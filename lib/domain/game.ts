export const GAME_MODES = ["punti_puri", "fantacalcio", "one_to_one"] as const;
export type GameMode = (typeof GAME_MODES)[number];

export const MATCHDAY_STATUSES = [
  "scheduled",
  "open",
  "locked",
  "live",
  "partial",
  "final",
  "recalculated",
] as const;
export type MatchdayStatus = (typeof MATCHDAY_STATUSES)[number];

export const PREDICTION_STATUSES = ["draft", "submitted", "locked", "void"] as const;
export type PredictionStatus = (typeof PREDICTION_STATUSES)[number];

export interface PredictionInput {
  matchId: string;
  homeGoals: number;
  awayGoals: number;
}

export function assertValidPredictedGoals(value: number): void {
  if (!Number.isInteger(value) || value < 0 || value > 9) {
    throw new Error("Il numero di gol previsto deve essere un intero tra 0 e 9.");
  }
}
