import { ProviderError } from "../core/errors";

const DEFAULT_BASE_URL = "https://api.football-data.org/v4";

export type FootballDataConfig = {
  apiToken: string;
  baseUrl: string;
};

export function getFootballDataConfig(): FootballDataConfig {
  const apiToken = process.env.FOOTBALL_DATA_TOKEN?.trim();
  const baseUrl =
    process.env.FOOTBALL_DATA_BASE_URL?.trim() || DEFAULT_BASE_URL;

  if (!apiToken) {
    throw new ProviderError({
      code: "PROVIDER_CONFIGURATION_MISSING",
      providerCode: "football_data",
      message: "FOOTBALL_DATA_TOKEN is not configured",
      retryable: false,
    });
  }

  return {
    apiToken,
    baseUrl: baseUrl.replace(/\/+$/, ""),
  };
}
