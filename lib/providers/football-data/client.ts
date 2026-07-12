import { providerFetchJson } from "../core/http";
import { getFootballDataConfig } from "./config";

export class FootballDataClient {
  async get<T>(
    path: string,
    query: Record<string, string | number | undefined> = {},
  ): Promise<T> {
    const config = getFootballDataConfig();
    const url = new URL(`${config.baseUrl}/${path.replace(/^\/+/, "")}`);

    for (const [key, value] of Object.entries(query)) {
      if (value !== undefined) {
        url.searchParams.set(key, String(value));
      }
    }

    return providerFetchJson<T>({
      providerCode: "football_data",
      url: url.toString(),
      init: {
        headers: {
          "X-Auth-Token": config.apiToken,
          Accept: "application/json",
        },
      },
    });
  }
}
