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
