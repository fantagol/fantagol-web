import { FootballDataLiveAdapter } from "./football-data-live-adapter";
import { ProviderRuntimeRegistry } from "./provider-runtime";
import { TheOddsApiLiveAdapter } from "./the-odds-api-live-adapter";

export type CreateDefaultProviderRuntimeRegistryOptions = {
  footballDataApiToken?: string;
  theOddsApiKey?: string;
  theOddsApiSportKey?: string;
};

export function createDefaultProviderRuntimeRegistry(
  options: CreateDefaultProviderRuntimeRegistryOptions = {},
): ProviderRuntimeRegistry {
  const registry = new ProviderRuntimeRegistry();

  registry.register(
    "football_data",
    new FootballDataLiveAdapter({
      apiToken: options.footballDataApiToken,
    }),
  );

  registry.register(
    "the_odds_api",
    new TheOddsApiLiveAdapter({
      apiKey: options.theOddsApiKey,
      sportKey: options.theOddsApiSportKey,
    }),
  );

  return registry;
}
