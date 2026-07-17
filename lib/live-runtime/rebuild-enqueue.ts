import type { SupabaseClient } from "@supabase/supabase-js";

import {
  enqueueLiveRuntimeJob,
  type EnqueuedLiveRuntimeJob,
} from "./job-service";

export type EnqueueLeagueRoundRebuildJobsInput = {
  client: SupabaseClient;
  leagueRoundIds: string[];
  receiptId: string;
  matchId: string;
  fantagolRoundId: string | null;
  changeType: string;
  changedFields: string[];
  correlationId: string | null;
  causationId: string | null;
};

function buildLeagueRoundRebuildIdempotencyKey(input: {
  leagueRoundId: string;
  receiptId: string;
}): string {
  return [
    "live",
    "rebuild-league-round",
    input.leagueRoundId,
    input.receiptId,
  ].join(":");
}

export async function enqueueLeagueRoundRebuildJobs(
  input: EnqueueLeagueRoundRebuildJobsInput,
): Promise<EnqueuedLiveRuntimeJob[]> {
  const jobs: EnqueuedLiveRuntimeJob[] = [];

  for (const leagueRoundId of [...new Set(input.leagueRoundIds)]) {
    const rebuildJob = await enqueueLiveRuntimeJob(input.client, {
      jobType: "rebuild_league_round",
      scopeType: "league_round",
      scopeId: leagueRoundId,
      idempotencyKey: buildLeagueRoundRebuildIdempotencyKey({
        leagueRoundId,
        receiptId: input.receiptId,
      }),
      priority: 30,
      payload: {
        receipt_id: input.receiptId,
        match_id: input.matchId,
        fantagol_round_id: input.fantagolRoundId,
        league_round_id: leagueRoundId,
        change_type: input.changeType,
        changed_fields: input.changedFields,
      },
      correlationId: input.correlationId,
      causationId: input.causationId,
    });

    jobs.push(rebuildJob);
  }

  return jobs;
}
