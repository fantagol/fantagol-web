import type { SupabaseClient } from "@supabase/supabase-js";

import { LiveRuntimeError } from "./errors";
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

/**
 * Keep this list aligned with build_points_pure_calculation_run_rpc.
 *
 * The Calculation Engine is authoritative: these states must never enter the
 * simulation pipeline. In particular, provider updates can legitimately be
 * applied while a round is still predictions_open, but that must not create
 * rebuild jobs that can only fail with LEAGUE_ROUND_NOT_CALCULABLE.
 */
const NON_CALCULABLE_LEAGUE_ROUND_STATUSES = new Set([
  "scheduled",
  "predictions_open",
  "cancelled",
  "archived",
]);

type LeagueRoundCalculabilityRow = {
  id: string;
  status: string;
  enabled: boolean;
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

async function loadCalculableLeagueRoundIds(
  client: SupabaseClient,
  leagueRoundIds: string[],
): Promise<string[]> {
  const uniqueIds = [...new Set(leagueRoundIds)];

  if (uniqueIds.length === 0) {
    return [];
  }

  const { data, error } = await client
    .from("league_rounds")
    .select("id,status,enabled")
    .in("id", uniqueIds);

  if (error) {
    throw new LiveRuntimeError({
      code: "LIVE_RUNTIME_RPC_ERROR",
      message: "Unable to resolve league round calculability before rebuild enqueue",
      details: {
        code: error.code,
        message: error.message,
        details: error.details,
        hint: error.hint,
        leagueRoundIds: uniqueIds,
      },
      cause: error,
    });
  }

  const rows = (data ?? []) as LeagueRoundCalculabilityRow[];
  const rowsById = new Map(rows.map((row) => [row.id, row]));

  const missingIds = uniqueIds.filter((id) => !rowsById.has(id));

  if (missingIds.length > 0) {
    throw new LiveRuntimeError({
      code: "LIVE_RUNTIME_INVALID_RPC_RESPONSE",
      message: "Unable to resolve every league round before rebuild enqueue",
      details: {
        leagueRoundIds: uniqueIds,
        missingLeagueRoundIds: missingIds,
      },
    });
  }

  return uniqueIds.filter((leagueRoundId) => {
    const row = rowsById.get(leagueRoundId);

    return Boolean(
      row &&
        row.enabled &&
        !NON_CALCULABLE_LEAGUE_ROUND_STATUSES.has(row.status),
    );
  });
}

export async function enqueueLeagueRoundRebuildJobs(
  input: EnqueueLeagueRoundRebuildJobsInput,
): Promise<EnqueuedLiveRuntimeJob[]> {
  const jobs: EnqueuedLiveRuntimeJob[] = [];

  const calculableLeagueRoundIds =
    await loadCalculableLeagueRoundIds(
      input.client,
      input.leagueRoundIds,
    );

  for (const leagueRoundId of calculableLeagueRoundIds) {
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