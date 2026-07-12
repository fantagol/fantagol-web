import type { ProviderCode } from "../types/normalized";
import { ApiFootballAdapter } from "../api-football/adapter";
import { SportmonksAdapter } from "../sportmonks/adapter";
import { TheOddsApiAdapter } from "../the-odds/adapter";

export function createProviderAdapter(code: ProviderCode) {
  switch (code) {
    case "api_football":
      return new ApiFootballAdapter();
    case "sportmonks_football":
      return new SportmonksAdapter();
    case "the_odds_api":
      return new TheOddsApiAdapter();
    default: {
      const exhaustiveCheck: never = code;
      throw new Error(`Unsupported provider: ${exhaustiveCheck}`);
    }
  }
}
