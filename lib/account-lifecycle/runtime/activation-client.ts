import type { SupabaseClient } from "@supabase/supabase-js";

import type {
  AccountLifecycleActivationState,
  AccountLifecycleCertificationCycleResult,
} from "./types";

export async function getAccountLifecycleActivationState(
  client: SupabaseClient,
): Promise<AccountLifecycleActivationState> {
  const { data, error } = await client.rpc(
    "get_account_lifecycle_runtime_activation_state_internal",
  );

  if (error) {
    throw new Error("ACCOUNT_LIFECYCLE_ACTIVATION_STATE_FAILED", {
      cause: error,
    });
  }

  return data as AccountLifecycleActivationState;
}

export async function executeAccountLifecycleCertificationCycle(
  client: SupabaseClient,
  workerId: string,
  correlationId: string,
): Promise<AccountLifecycleCertificationCycleResult> {
  const { data, error } = await client.rpc(
    "execute_account_lifecycle_certification_cycle_internal",
    {
      p_worker_id: workerId,
      p_correlation_id: correlationId,
    },
  );

  if (error) {
    throw new Error("ACCOUNT_LIFECYCLE_CERTIFICATION_CYCLE_FAILED", {
      cause: error,
    });
  }

  return data as AccountLifecycleCertificationCycleResult;
}
