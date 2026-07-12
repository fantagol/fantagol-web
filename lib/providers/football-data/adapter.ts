import type {
  CalendarProvider,
  CompetitionProvider,
  LiveScoreProvider,
} from "../core/contracts";
import { ProviderError } from "../core/errors";
import type {
  NormalizedCompetition,
  NormalizedEdition,
  NormalizedMatch,
  NormalizedProviderRound,
  NormalizedStage,
  NormalizedTeam,
} from "../types/normalized";
import { FootballDataClient } from "./client";
import {
  buildEditionExternalId,
  normalizeCompetition,
  normalizeEdition,
  normalizeMatch,
  normalizeRounds,
  normalizeStage,
  normalizeTeam,
  parseEditionExternalId,
} from "./normalizers";
import type {
  FootballDataCompetition,
  FootballDataMatchesResponse,
  FootballDataTeamsResponse,
} from "./types";

export class FootballDataAdapter
  implements CompetitionProvider, CalendarProvider, LiveScoreProvider
{
  readonly code = "football_data" as const;
  readonly name = "football-data.org";

  constructor(private readonly client = new FootballDataClient()) {}

  async getCompetition(
    externalId: string,
  ): Promise<NormalizedCompetition> {
    const competition = await this.client.get<FootballDataCompetition>(
      `/competitions/${encodeURIComponent(externalId)}`,
    );

    return normalizeCompetition(competition);
  }

  async getEdition(
    competitionExternalId: string,
    season: number,
  ): Promise<NormalizedEdition> {
    const competition = await this.client.get<FootballDataCompetition>(
      `/competitions/${encodeURIComponent(competitionExternalId)}`,
    );

    const matchingSeason = competition.seasons?.find(
      (item) => Number(item.startDate.slice(0, 4)) === season,
    );

    if (!matchingSeason) {
      throw new ProviderError({
        code: "PROVIDER_ENTITY_NOT_FOUND",
        providerCode: this.code,
        message: `Season ${season} not found for competition ${competitionExternalId}`,
        retryable: false,
      });
    }

    return normalizeEdition({
      competition,
      season: matchingSeason,
    });
  }

  async getStages(
    editionExternalId: string,
  ): Promise<NormalizedStage[]> {
    return [normalizeStage(editionExternalId)];
  }

  async getTeams(
    editionExternalId: string,
  ): Promise<NormalizedTeam[]> {
    const { competitionExternalId, seasonStartYear } =
      parseEditionExternalId(editionExternalId);

    const response = await this.client.get<FootballDataTeamsResponse>(
      `/competitions/${encodeURIComponent(competitionExternalId)}/teams`,
      { season: seasonStartYear },
    );

    const countryCode = response.competition.area?.code || null;

    return response.teams.map((team) =>
      normalizeTeam(team, countryCode),
    );
  }

  async getRounds(
    editionExternalId: string,
  ): Promise<NormalizedProviderRound[]> {
    const matches = await this.loadMatches(editionExternalId);

    return normalizeRounds({
      editionExternalId,
      matches,
    });
  }

  async getMatches(
    editionExternalId: string,
  ): Promise<NormalizedMatch[]> {
    const matches = await this.loadMatches(editionExternalId);
    return matches.map(normalizeMatch);
  }

  async getLiveMatches(
    externalIds?: string[],
  ): Promise<NormalizedMatch[]> {
    const response = await this.client.get<FootballDataMatchesResponse>(
      "/matches",
      { status: "LIVE" },
    );

    const idFilter =
      externalIds && externalIds.length > 0
        ? new Set(externalIds)
        : null;

    return response.matches
      .filter((match) =>
        idFilter ? idFilter.has(String(match.id)) : true,
      )
      .map(normalizeMatch);
  }

  private async loadMatches(editionExternalId: string) {
    const { competitionExternalId, seasonStartYear } =
      parseEditionExternalId(editionExternalId);

    const response = await this.client.get<FootballDataMatchesResponse>(
      `/competitions/${encodeURIComponent(competitionExternalId)}/matches`,
      { season: seasonStartYear },
    );

    return response.matches;
  }

  static buildEditionExternalId(
    competitionExternalId: string,
    seasonStartYear: number,
  ) {
    return buildEditionExternalId(
      competitionExternalId,
      seasonStartYear,
    );
  }
}
