import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";

import {
  dispatchWorkflowLoyaltyBatch,
  reconcileExpiredWorkflowLoyaltyLeases,
} from "./service";
import type {
  DispatchWorkflowLoyaltyBatchResult,
  ReconcileWorkflowLoyaltyLeasesResult,
} from "./types";

export interface WorkflowLoyaltyDispatchHandlerInput {
  workerId: string;
  batchLimit?: number;
  leaseSeconds?: number;
  reconciliationLimit?: number;
}

export interface WorkflowLoyaltyDispatchHandlerResult {
  reconciliation: ReconcileWorkflowLoyaltyLeasesResult;
  dispatch: DispatchWorkflowLoyaltyBatchResult;
}

/**
 * Server-only worker primitive.
 *
 * It first reconciles expired leases, then dispatches a bounded batch.
 * With Migration 107 defaults all bindings and producers are disabled, so this
 * handler remains operationally inert until controlled activation.
 */
export async function handleWorkflowLoyaltyDispatch(
  supabase: SupabaseClient,
  input: WorkflowLoyaltyDispatchHandlerInput,
): Promise<WorkflowLoyaltyDispatchHandlerResult> {
  const reconciliation = await reconcileExpiredWorkflowLoyaltyLeases(
    supabase,
    input.reconciliationLimit ?? 100,
  );

  const dispatch = await dispatchWorkflowLoyaltyBatch(supabase, {
    workerId: input.workerId,
    limit: input.batchLimit ?? 25,
    leaseSeconds: input.leaseSeconds ?? 120,
  });

  return {
    reconciliation,
    dispatch,
  };
}
