import type { SupabaseClient } from "@supabase/supabase-js";

import {
  ProviderRuntimeRegistry,
  type ProviderBatchPollResult,
  type ProviderPollResult,
  supportsProviderBatchPolling,
} from "./provider-runtime";

export async function executeProviderPoll(
  client: SupabaseClient,
  registry: ProviderRuntimeRegistry,
  providerCode: string,
  externalMatchId: string,
): Promise<ProviderPollResult> {
  const adapter = registry.get(providerCode);

  return adapter.pollMatch(client, {
    providerCode,
    externalMatchId,
  });
}

export async function executeProviderBatchPoll(
  client: SupabaseClient,
  registry: ProviderRuntimeRegistry,
  providerCode: string,
  externalMatchIds: string[],
  options?: {
    mode?: "live" | "prematch";
    competitionCode?: string;
    dateFrom?: string;
    dateTo?: string;
  },
): Promise<ProviderBatchPollResult> {
  const adapter = registry.get(providerCode);

  if (!supportsProviderBatchPolling(adapter)) {
    throw new Error(
      `Provider '${providerCode}' does not support batch polling.`,
    );
  }

  return adapter.pollMatches(client, {
    providerCode,
    externalMatchIds,
    mode: options?.mode,
    competitionCode: options?.competitionCode,
    dateFrom: options?.dateFrom,
    dateTo: options?.dateTo,
  });
}