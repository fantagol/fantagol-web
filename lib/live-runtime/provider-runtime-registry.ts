import { FootballDataLiveAdapter } from "./football-data-live-adapter";
import { ProviderRuntimeRegistry } from "./provider-runtime";

export type CreateDefaultProviderRuntimeRegistryOptions = {
  footballDataApiToken?: string;
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

  return registry;
}
