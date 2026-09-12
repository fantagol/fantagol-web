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


export type EnqueueFinalCalculableLeagueRoundRebuildJobsInput = {
  client: SupabaseClient;
  fantagolRoundId: string;
  correlationId: string | null;
  causationId: string | null;
};

type FinalCalculableLeagueRoundRow = {
  id: string;
  version: number;
  status: string;
  enabled: boolean;
};

function buildFinalCalculableRebuildIdempotencyKey(input: {
  leagueRoundId: string;
  leagueRoundVersion: number;
}): string {
  return [
    "live",
    "final-calculable",
    "rebuild-league-round",
    input.leagueRoundId,
    `v${input.leagueRoundVersion}`,
  ].join(":");
}

async function loadFinalCalculableLeagueRounds(
  client: SupabaseClient,
  fantagolRoundId: string,
): Promise<FinalCalculableLeagueRoundRow[]> {
  const { data, error } = await client
    .from("league_rounds")
    .select("id,version,status,enabled")
    .eq("fantagol_round_id", fantagolRoundId)
    .eq("enabled", true)
    .eq("status", "final_calculable");

  if (error) {
    throw new LiveRuntimeError({
      code: "LIVE_RUNTIME_RPC_ERROR",
      message:
        "Unable to resolve FINAL_CALCULABLE league rounds before rebuild enqueue",
      details: {
        code: error.code,
        message: error.message,
        details: error.details,
        hint: error.hint,
        fantagolRoundId,
      },
      cause: error,
    });
  }

  return (data ?? []) as FinalCalculableLeagueRoundRow[];
}

export async function enqueueFinalCalculableLeagueRoundRebuildJobs(
  input: EnqueueFinalCalculableLeagueRoundRebuildJobsInput,
): Promise<EnqueuedLiveRuntimeJob[]> {
  const leagueRounds =
    await loadFinalCalculableLeagueRounds(
      input.client,
      input.fantagolRoundId,
    );

  const jobs: EnqueuedLiveRuntimeJob[] = [];

  for (const leagueRound of leagueRounds) {
    const rebuildJob =
      await enqueueLiveRuntimeJob(
        input.client,
        {
          jobType: "rebuild_league_round",
          scopeType: "league_round",
          scopeId: leagueRound.id,
          idempotencyKey:
            buildFinalCalculableRebuildIdempotencyKey({
              leagueRoundId:
                leagueRound.id,
              leagueRoundVersion:
                leagueRound.version,
            }),
          priority: 30,
          payload: {
            fantagol_round_id:
              input.fantagolRoundId,
            league_round_id:
              leagueRound.id,
            league_round_version:
              leagueRound.version,
            lifecycle_reason:
              "final_calculable",
            publication_channel:
              "realtime",
            round_certification_reason:
              "automatic official round certification",
          },
          correlationId:
            input.correlationId,
          causationId:
            input.causationId,
        },
      );

    jobs.push(rebuildJob);
  }

  return jobs;
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
/**
 * Full simulation pipeline admission.
 *
 * A league round is rebuildable only when its league owns an active schedule
 * version and that active schedule contains BOTH Fantacalcio and One-to-One
 * fixtures for the exact league round. This mirrors the downstream builders'
 * structural prerequisites and prevents known ACTIVE_*_SCHEDULE_NOT_FOUND
 * dead letters.
 *
 * Primary-live uses this stricter gate without changing the official
 * Football-Data receipt fanout in this milestone.
 */
async function loadFullPipelineRebuildableLeagueRoundIds(
  client: SupabaseClient,
  leagueRoundIds: string[],
): Promise<string[]> {
  const calculableLeagueRoundIds =
    await loadCalculableLeagueRoundIds(
      client,
      leagueRoundIds,
    );

  if (calculableLeagueRoundIds.length === 0) {
    return [];
  }

  const { data: roundData, error: roundError } =
    await client
      .from("league_rounds")
      .select("id,league_id")
      .in("id", calculableLeagueRoundIds);

  if (roundError) {
    throw new LiveRuntimeError({
      code: "LIVE_RUNTIME_RPC_ERROR",
      message:
        "Unable to resolve league round schedule ownership before primary-live rebuild enqueue",
      details: {
        code: roundError.code,
        message: roundError.message,
        details: roundError.details,
        hint: roundError.hint,
        leagueRoundIds: calculableLeagueRoundIds,
      },
      cause: roundError,
    });
  }

  const roundRows = (roundData ?? []) as Array<{
    id: string;
    league_id: string;
  }>;
  const roundById = new Map(
    roundRows.map((row) => [row.id, row]),
  );

  const missingRoundIds =
    calculableLeagueRoundIds.filter(
      (id) => !roundById.has(id),
    );

  if (missingRoundIds.length > 0) {
    throw new LiveRuntimeError({
      code: "LIVE_RUNTIME_INVALID_RPC_RESPONSE",
      message:
        "Unable to resolve every league round schedule owner before primary-live rebuild enqueue",
      details: {
        leagueRoundIds: calculableLeagueRoundIds,
        missingLeagueRoundIds: missingRoundIds,
      },
    });
  }

  const leagueIds = [
    ...new Set(
      roundRows.map((row) => row.league_id),
    ),
  ];

  const { data: scheduleData, error: scheduleError } =
    await client
      .from("league_schedule_versions")
      .select("id,league_id")
      .in("league_id", leagueIds)
      .eq("active", true);

  if (scheduleError) {
    throw new LiveRuntimeError({
      code: "LIVE_RUNTIME_RPC_ERROR",
      message:
        "Unable to resolve active league schedules before primary-live rebuild enqueue",
      details: {
        code: scheduleError.code,
        message: scheduleError.message,
        details: scheduleError.details,
        hint: scheduleError.hint,
        leagueIds,
      },
      cause: scheduleError,
    });
  }

  const scheduleRows = (scheduleData ?? []) as Array<{
    id: string;
    league_id: string;
  }>;

  const scheduleByLeagueId = new Map(
    scheduleRows.map((row) => [
      row.league_id,
      row.id,
    ]),
  );

  const activeScheduleIds = [
    ...new Set(
      scheduleRows.map((row) => row.id),
    ),
  ];

  if (activeScheduleIds.length === 0) {
    return [];
  }

  const { data: fixtureData, error: fixtureError } =
    await client
      .from("league_fixtures")
      .select(
        "schedule_version_id,league_round_id,mode",
      )
      .in("schedule_version_id", activeScheduleIds)
      .in(
        "league_round_id",
        calculableLeagueRoundIds,
      )
      .in("mode", ["fantacalcio", "one_to_one"]);

  if (fixtureError) {
    throw new LiveRuntimeError({
      code: "LIVE_RUNTIME_RPC_ERROR",
      message:
        "Unable to resolve active schedule fixtures before primary-live rebuild enqueue",
      details: {
        code: fixtureError.code,
        message: fixtureError.message,
        details: fixtureError.details,
        hint: fixtureError.hint,
        leagueRoundIds: calculableLeagueRoundIds,
        activeScheduleIds,
      },
      cause: fixtureError,
    });
  }

  const fixtureRows = (fixtureData ?? []) as Array<{
    schedule_version_id: string;
    league_round_id: string;
    mode: string;
  }>;

  const modesByLeagueRoundId = new Map<
    string,
    Set<string>
  >();

  for (const fixture of fixtureRows) {
    const round = roundById.get(
      fixture.league_round_id,
    );

    if (!round) {
      continue;
    }

    const activeScheduleId =
      scheduleByLeagueId.get(round.league_id);

    if (
      !activeScheduleId ||
      fixture.schedule_version_id !==
        activeScheduleId
    ) {
      continue;
    }

    const modes =
      modesByLeagueRoundId.get(
        fixture.league_round_id,
      ) ?? new Set<string>();

    modes.add(fixture.mode);
    modesByLeagueRoundId.set(
      fixture.league_round_id,
      modes,
    );
  }

  return calculableLeagueRoundIds.filter(
    (leagueRoundId) => {
      const round = roundById.get(leagueRoundId);

      if (!round) {
        return false;
      }

      const activeScheduleId =
        scheduleByLeagueId.get(round.league_id);

      if (!activeScheduleId) {
        return false;
      }

      const modes =
        modesByLeagueRoundId.get(leagueRoundId);

      return Boolean(
        modes?.has("fantacalcio") &&
          modes.has("one_to_one"),
      );
    },
  );
}
// ---------------------------------------------------------------------------
// R112-R6 - PRIMARY LIVE REBUILD PROVENANCE
// ---------------------------------------------------------------------------

export type EnqueuePrimaryLiveLeagueRoundRebuildJobsInput = {
  client: SupabaseClient;
  leagueRoundIds: string[];
  observationId: string;
  authorityVersion: number;
  matchId: string;
  fantagolRoundId: string | null;
  changedFields: string[];
  correlationId: string | null;
  causationId: string | null;
};

/**
 * Enqueue the normal simulation/snapshot/realtime-publication pipeline from a
 * non-official LIVE authority observation.
 *
 * This path deliberately has NO receipt_id. receipt_id belongs exclusively to
 * the Football-Data canonical evidence chain.
 */
export async function enqueuePrimaryLiveLeagueRoundRebuildJobs(
  input: EnqueuePrimaryLiveLeagueRoundRebuildJobsInput,
): Promise<EnqueuedLiveRuntimeJob[]> {
  const leagueRoundIds =
    await loadFullPipelineRebuildableLeagueRoundIds(
      input.client,
      input.leagueRoundIds,
    );

  const jobs: EnqueuedLiveRuntimeJob[] = [];

  for (const leagueRoundId of leagueRoundIds) {
    /*
     * R114-R5-R95: primary-live rebuilds use a dedicated atomic DB enqueue.
     * The RPC serializes per league_round, coalesces stale queued versions,
     * preserves claimed/running work, and fixes the hot rebuild priority at 12.
     * Football-Data continues through enqueueLiveRuntimeJob unchanged.
     */
    const { data, error } = await input.client.rpc(
      "enqueue_primary_live_rebuild_job_rpc",
      {
        p_league_round_id: leagueRoundId,
        p_observation_id: input.observationId,
        p_authority_version: input.authorityVersion,
        p_match_id: input.matchId,
        p_fantagol_round_id: input.fantagolRoundId,
        p_changed_fields: input.changedFields,
        p_correlation_id: input.correlationId,
        p_causation_id: input.causationId,
      },
    );

    if (error) {
      throw new Error(
        `enqueue_primary_live_rebuild_job_rpc failed: ${error.message}`,
      );
    }

    const rpcRows = data as
      | Array<{
          job_id: string;
          job_status: string;
          inserted: boolean;
          scheduled_at: string;
          attempt_count: number;
          correlation_id: string;
        }>
      | null;

    const row = rpcRows?.[0];

    if (!row) {
      throw new Error(
        "enqueue_primary_live_rebuild_job_rpc returned no row",
      );
    }

    const rebuildJob: EnqueuedLiveRuntimeJob = {
      jobId: row.job_id,
      jobStatus: row.job_status as EnqueuedLiveRuntimeJob["jobStatus"],
      inserted: row.inserted,
      scheduledAt: row.scheduled_at,
      attemptCount: row.attempt_count,
      correlationId: row.correlation_id,
    };

    jobs.push(rebuildJob);
  }

  return jobs;
}
