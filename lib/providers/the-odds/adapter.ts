/* eslint-disable @typescript-eslint/no-unused-vars -- Provider adapter signatures intentionally retain contract parameters that are not consumed by fallback implementations. */
import type { OddsProvider } from "../core/contracts";
import { ProviderError } from "../core/errors";
import type { NormalizedOddsSnapshot } from "../types/normalized";

export class TheOddsApiAdapter implements OddsProvider {
  readonly code = "the_odds_api" as const;
  readonly name = "The Odds API";

  async getOdds(_matchExternalIds: string[]): Promise<NormalizedOddsSnapshot[]> {
    throw new ProviderError({
      code: "PROVIDER_CONFIGURATION_MISSING",
      providerCode: this.code,
      message: "getOdds is not configured yet",
      retryable: false,
    });
  }
}
