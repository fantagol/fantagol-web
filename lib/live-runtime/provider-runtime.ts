import type { SupabaseClient } from "@supabase/supabase-js";

export type ProviderPollRequest={
  providerCode:string;
  externalMatchId:string;
};

export type ProviderPollResult={
  providerCode:string;
  externalMatchId:string;
  fetchedAt:string;
  payload:unknown;
};

export interface LiveProviderAdapter{
  pollMatch(client:SupabaseClient, request:ProviderPollRequest):Promise<ProviderPollResult>;
}

export type ProviderBatchPollMode =
  | "live"
  | "prematch";

export type ProviderBatchPollRequest = {
  providerCode: string;
  externalMatchIds: string[];

  /**
   * live:
   *   Provider-optimized active Match collection.
   *
   * prematch:
   *   Date-window collection used to observe schedule/status changes
   *   before kickoff, including postponed/cancelled states.
   */
  mode?: ProviderBatchPollMode;

  competitionCode?: string;

  /**
   * ISO calendar dates (YYYY-MM-DD).
   * dateTo follows the provider contract and is exclusive.
   */
  dateFrom?: string;
  dateTo?: string;
};

export type ProviderBatchPollResult = {
  providerCode: string;
  fetchedAt: string;
  results: ProviderPollResult[];
  requestedExternalMatchIds: string[];
  returnedExternalMatchIds: string[];
  transport: unknown;
};

export interface LiveProviderBatchAdapter extends LiveProviderAdapter {
  pollMatches(
    client: SupabaseClient,
    request: ProviderBatchPollRequest,
  ): Promise<ProviderBatchPollResult>;
}

export function supportsProviderBatchPolling(
  adapter: LiveProviderAdapter,
): adapter is LiveProviderBatchAdapter {
  return (
    "pollMatches" in adapter &&
    typeof (adapter as Partial<LiveProviderBatchAdapter>).pollMatches ===
      "function"
  );
}

export class UnsupportedProviderError extends Error{}

export class ProviderRuntimeRegistry{
  private readonly adapters=new Map<string,LiveProviderAdapter>();

  register(provider:string,adapter:LiveProviderAdapter){
    this.adapters.set(provider,adapter);
  }

  get(provider:string):LiveProviderAdapter{
    const a=this.adapters.get(provider);
    if(!a) throw new UnsupportedProviderError(`Provider '${provider}' not registered.`);
    return a;
  }
}
