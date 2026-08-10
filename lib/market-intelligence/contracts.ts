export const BM_INTERPOLATED_MODEL_CODE =
  "BM_INTERPOLATED" as const;

export const BM_INTERPOLATED_ALGORITHM_VERSION =
  "BM_INTERPOLATED_V1" as const;

export type MarketIntelligenceMarketKey =
  | "h2h"
  | "totals"
  | "alternate_totals"
  | "btts"
  | "correct_score";

export type MarketIntelligenceSignal =
  | "EXACT"
  | "SIGN"
  | "TOTALS"
  | "BTTS";

export type MarketIntelligenceQuality =
  | "strong"
  | "usable"
  | "thin"
  | "insufficient";

export interface ProviderOutcome {
  name: string;
  price: number;
  point?: number | null;
  description?: string | null;
}

export interface ProviderMarket {
  key: string;
  last_update?: string | null;
  outcomes: ProviderOutcome[];
}

export interface ProviderBookmaker {
  key: string;
  title?: string | null;
  last_update?: string | null;
  markets: ProviderMarket[];
}

export interface ProviderEventOdds {
  id: string;
  sport_key?: string | null;
  commence_time?: string | null;
  home_team: string;
  away_team: string;
  bookmakers: ProviderBookmaker[];
}

export interface NormalizedOutcome {
  name: string;
  point: number | null;
  decimalOdds: number;
  rawImpliedProbability: number;
  fairProbability: number;
}

export interface NormalizedBookmakerMarket {
  bookmakerKey: string;
  bookmakerTitle: string | null;
  marketKey: MarketIntelligenceMarketKey;
  lastUpdate: string | null;
  overround: number;
  outcomes: NormalizedOutcome[];
}

export interface MarketDepth {
  marketKey: MarketIntelligenceMarketKey;
  bookmakerCount: number;
  validBookmakerCount: number;
  rejectedBookmakerCount: number;
  outcomeCount: number;
  quality: MarketIntelligenceQuality;
}

export type MarketRejectionReason =
  | "unsupported_market"
  | "missing_outcomes"
  | "invalid_price"
  | "insufficient_outcomes"
  | "invalid_probability_sum"
  | "extreme_overround"
  | "duplicate_outcome"
  | "invalid_total_line";

export interface MarketRejection {
  bookmakerKey: string;
  marketKey: string;
  reason: MarketRejectionReason;
  details?: string;
}

export interface MarketIntelligenceInput {
  modelCode: typeof BM_INTERPOLATED_MODEL_CODE;

  algorithmVersion:
    typeof BM_INTERPOLATED_ALGORITHM_VERSION;

  providerEventId: string;

  homeTeam: string;
  awayTeam: string;

  commenceTime: string | null;

  markets: NormalizedBookmakerMarket[];

  depth: MarketDepth[];

  rejections: MarketRejection[];

  availableSignals: MarketIntelligenceSignal[];

  qualityScore: number;

  quality: MarketIntelligenceQuality;
}