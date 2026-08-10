import type { SupabaseClient } from "@supabase/supabase-js";

import { callRuntimeRpc } from "./rpc-utils";

export type PostponedMaterializationRow = {
  league_round_id: string;
  decision: string;
  created: boolean;
};

export type MaterializePostponedMatchInput = {
  client: SupabaseClient;
  matchId: string;
  previousKickoffAt: string | null;
  currentKickoffAt: string | null;
};

/**
 * Materializes the provider-observed POSTPONED fact into the per-League-Round
 * governance ledger.
 *
 * The database function is intentionally idempotent. Repeated Runtime attempts
 * must therefore call this function again rather than assuming that a prior
 * Match refresh also completed the governance side effect.
 *
 * This service does NOT choose KEEP, REOPEN or EXCLUDE.
 */
export async function materializePostponedMatch(
  input: MaterializePostponedMatchInput,
): Promise<PostponedMaterializationRow[]> {
  return callRuntimeRpc<PostponedMaterializationRow>(
    input.client,
    "materialize_postponed_match_internal",
    {
      p_match_id: input.matchId,
      p_previous_kickoff: input.previousKickoffAt,
      p_current_kickoff: input.currentKickoffAt,
    },
  );
}