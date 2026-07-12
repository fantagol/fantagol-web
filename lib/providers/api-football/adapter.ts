import type { CalendarProvider, CompetitionProvider, LiveScoreProvider } from "../core/contracts";
import { ProviderError } from "../core/errors";
import type {
  NormalizedCompetition,
  NormalizedEdition,
  NormalizedMatch,
  NormalizedProviderRound,
  NormalizedStage,
  NormalizedTeam,
} from "../types/normalized";

export class ApiFootballAdapter
  implements CompetitionProvider, CalendarProvider, LiveScoreProvider
{
  readonly code = "api_football" as const;
  readonly name = "API-Football";

  private notImplemented(operation: string): never {
    throw new ProviderError({
      code: "PROVIDER_CONFIGURATION_MISSING",
      providerCode: this.code,
      message: `${operation} is not configured yet`,
      retryable: false,
    });
  }

  async getCompetition(_externalId: string): Promise<NormalizedCompetition> { return this.notImplemented("getCompetition"); }
  async getEdition(_competitionExternalId: string, _season: number): Promise<NormalizedEdition> { return this.notImplemented("getEdition"); }
  async getStages(_editionExternalId: string): Promise<NormalizedStage[]> { return this.notImplemented("getStages"); }
  async getTeams(_editionExternalId: string): Promise<NormalizedTeam[]> { return this.notImplemented("getTeams"); }
  async getRounds(_editionExternalId: string): Promise<NormalizedProviderRound[]> { return this.notImplemented("getRounds"); }
  async getMatches(_editionExternalId: string): Promise<NormalizedMatch[]> { return this.notImplemented("getMatches"); }
  async getLiveMatches(_externalIds?: string[]): Promise<NormalizedMatch[]> { return this.notImplemented("getLiveMatches"); }
}
