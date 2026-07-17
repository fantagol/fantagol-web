import type { SupabaseClient } from "@supabase/supabase-js";
import {ProviderRuntimeRegistry,ProviderPollResult} from "./provider-runtime";

export async function executeProviderPoll(
 client:SupabaseClient,
 registry:ProviderRuntimeRegistry,
 providerCode:string,
 externalMatchId:string,
):Promise<ProviderPollResult>{
 const adapter=registry.get(providerCode);
 return adapter.pollMatch(client,{providerCode,externalMatchId});
}
