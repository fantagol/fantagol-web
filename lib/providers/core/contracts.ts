import type {
  NormalizedCompetition,
  NormalizedEdition,
  NormalizedMatch,
  NormalizedOddsSnapshot,
  NormalizedProviderRound,
  NormalizedStage,
  NormalizedTeam,
  ProviderCode,
} from "../types/normalized";

export interface ProviderAdapter {
  readonly code: ProviderCode;
  readonly name: string;
}

export interface CompetitionProvider extends ProviderAdapter {
  getCompetition(externalId: string): Promise<NormalizedCompetition>;
  getEdition(competitionExternalId: string, season: number): Promise<NormalizedEdition>;
  getStages(editionExternalId: string): Promise<NormalizedStage[]>;
}

export interface CalendarProvider extends ProviderAdapter {
  getTeams(editionExternalId: string): Promise<NormalizedTeam[]>;
  getRounds(editionExternalId: string): Promise<NormalizedProviderRound[]>;
  getMatches(editionExternalId: string): Promise<NormalizedMatch[]>;
}

export interface LiveScoreProvider extends ProviderAdapter {
  getLiveMatches(externalIds?: string[]): Promise<NormalizedMatch[]>;
}

export interface OddsProvider extends ProviderAdapter {
  getOdds(matchExternalIds: string[]): Promise<NormalizedOddsSnapshot[]>;
}
