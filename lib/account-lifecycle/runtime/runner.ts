import "server-only";

import { randomUUID } from "node:crypto";

import { getSupabaseServiceClient } from "../../supabase/service";
import {
  executeAccountLifecycleCertificationCycle,
  getAccountLifecycleActivationState,
} from "./activation-client";

function requiredEnvironment(name: string): string {
  const value = process.env[name]?.trim();

  if (!value) {
    throw new Error(`Missing server configuration: ${name}`);
  }

  return value;
}

export async function runAccountLifecycleCertificationCycle() {
  if (process.env.ACCOUNT_ERASURE_CERTIFICATION_MODE !== "true") {
    throw new Error("ACCOUNT_ERASURE_CERTIFICATION_MODE_REQUIRED");
  }

  const expectedLifecycleId = requiredEnvironment(
    "ACCOUNT_ERASURE_CERTIFICATION_LIFECYCLE_ID",
  );
  const expectedRunId = requiredEnvironment(
    "ACCOUNT_ERASURE_CERTIFICATION_RUN_ID",
  );
  const workerId = requiredEnvironment("ACCOUNT_ERASURE_WORKER_ID");

  const client = getSupabaseServiceClient();
  const state = await getAccountLifecycleActivationState(client);

  if (
    state.activation_level !== 1 ||
    state.activation_mode !== "certification" ||
    state.approved_account_lifecycle_id !== expectedLifecycleId ||
    state.approved_erasure_run_id !== expectedRunId ||
    state.storage_provider_enabled ||
    state.auth_provider_enabled
  ) {
    throw new Error("ACCOUNT_ERASURE_CERTIFICATION_SCOPE_REJECTED");
  }

  return executeAccountLifecycleCertificationCycle(
    client,
    workerId,
    randomUUID(),
  );
}
