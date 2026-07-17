import type { SupabaseClient } from "@supabase/supabase-js";

import { LiveRuntimeError } from "./errors";
import { handlePollMatchJob } from "./poll-match-handler";
import {
  claimLiveRuntimeJob,
  completeLiveRuntimeJob,
  enqueueLiveRuntimeJob,
  failLiveRuntimeJob,
  type ClaimedLiveRuntimeJob,
  type LiveRuntimeJobType,
} from "./job-service";
import {
  publishLiveStateSnapshot,
  type LivePublicationChannel,
} from "./publication-service";
import { handleRefreshRoundJob } from "./refresh-round-handler";
import { createLiveStateSnapshot } from "./snapshot-service";
import {
  rebuildLeagueRoundSimulation,
  type SimulationPipelineVersions,
} from "./simulation-service";

export type LiveRuntimeWorkerContext = {
  client: SupabaseClient;
  workerId: string;
  job: ClaimedLiveRuntimeJob;
};

export type LiveRuntimeWorkerHandler = (
  context: LiveRuntimeWorkerContext,
) => Promise<Record<string, unknown>>;

export type LiveRuntimeWorkerHandlers = Partial<
  Record<LiveRuntimeJobType, LiveRuntimeWorkerHandler>
>;

export type RunLiveRuntimeWorkerOnceInput = {
  client: SupabaseClient;
  workerId: string;
  jobTypes?: LiveRuntimeJobType[] | null;
  handlers?: LiveRuntimeWorkerHandlers;
  retryDelaySeconds?: number;
};

export type RunLiveRuntimeWorkerOnceResult =
  | {
      claimed: false;
      completed: false;
      jobId: null;
    }
  | {
      claimed: true;
      completed: true;
      jobId: string;
      jobType: LiveRuntimeJobType;
      result: Record<string, unknown>;
    }
  | {
      claimed: true;
      completed: false;
      jobId: string;
      jobType: LiveRuntimeJobType;
      error: Record<string, unknown>;
    };

function getString(
  payload: Record<string, unknown>,
  key: string,
): string | null {
  const value = payload[key];
  return typeof value === "string" && value.length > 0 ? value : null;
}

function getObject(
  payload: Record<string, unknown>,
  key: string,
): Record<string, unknown> {
  const value = payload[key];

  if (value && typeof value === "object" && !Array.isArray(value)) {
    return value as Record<string, unknown>;
  }

  return {};
}

function serializeWorkerError(error: unknown): Record<string, unknown> {
  if (error instanceof LiveRuntimeError) {
    return {
      name: error.name,
      code: error.code,
      message: error.message,
      details: error.details ?? {},
    };
  }

  if (error instanceof Error) {
    return {
      name: error.name,
      message: error.message,
      stack: error.stack ?? null,
    };
  }

  return {
    name: "UnknownError",
    message: String(error),
  };
}

const rebuildLeagueRoundHandler: LiveRuntimeWorkerHandler = async ({
  client,
  job,
}) => {
  if (job.scopeType !== "league_round") {
    throw new LiveRuntimeError({
      code: "LIVE_RUNTIME_INVALID_JOB_PAYLOAD",
      message: "rebuild_league_round requires league_round scope",
      details: {
        jobId: job.jobId,
        scopeType: job.scopeType,
      },
    });
  }

  const versions = getObject(
    job.payload,
    "versions",
  ) as Partial<SimulationPipelineVersions>;

  const rebuilt = await rebuildLeagueRoundSimulation(client, {
    leagueRoundId: job.scopeId,
    surpriseCandidates: getObject(
      job.payload,
      "surprise_candidates",
    ),
    createdByMemberId: getString(
      job.payload,
      "created_by_member_id",
    ),
    correlationId: job.correlationId,
    versions,
  });

  const liveState = {
    schema_version: 1,
    source: "LiveRuntimeWorker",
    league_round_id: rebuilt.leagueRoundId,
    calculation_run_id: rebuilt.calculationRunId,
    ui_simulation_id: rebuilt.uiSimulationId,
    ui_simulation_version: rebuilt.uiSimulationVersion,
    ui_simulation_hash: rebuilt.uiSimulationHash,
    digital_twin: rebuilt.digitalTwin,
  };

  const snapshot = await createLiveStateSnapshot(client, {
    simulationId: rebuilt.uiSimulationId,
    liveState,
    timelineCursor: {
      source_job_id: job.jobId,
      correlation_id: job.correlationId,
    },
    health: {
      status: "healthy",
      stale: false,
      rebuilt_at: new Date().toISOString(),
    },
    engineVersion:
      getString(job.payload, "live_state_engine_version") ??
      "live-state-v1",
    correlationId: job.correlationId,
  });

  const publicationJob = await enqueueLiveRuntimeJob(client, {
    jobType: "publish_snapshot",
    scopeType: "live_state_snapshot",
    scopeId: snapshot.liveStateSnapshotId,
    idempotencyKey: [
      "live",
      "publish-snapshot",
      snapshot.liveStateSnapshotId,
      getString(job.payload, "publication_channel") ?? "realtime",
    ].join(":"),
    priority: 40,
    payload: {
      live_state_snapshot_id: snapshot.liveStateSnapshotId,
      channel:
        getString(job.payload, "publication_channel") ?? "realtime",
      metadata: {
        source_job_id: job.jobId,
        ui_simulation_id: rebuilt.uiSimulationId,
      },
    },
    correlationId: job.correlationId,
    causationId: job.jobId,
  });

  return {
    league_round_id: rebuilt.leagueRoundId,
    calculation_run_id: rebuilt.calculationRunId,
    points_simulation_id: rebuilt.pointsSimulationId,
    fantacalcio_simulation_id: rebuilt.fantacalcioSimulationId,
    one_to_one_simulation_id: rebuilt.oneToOneSimulationId,
    standings_simulation_id: rebuilt.standingsSimulationId,
    ui_simulation_id: rebuilt.uiSimulationId,
    live_state_snapshot_id: snapshot.liveStateSnapshotId,
    publication_job_id: publicationJob.jobId,
  };
};

const publishSnapshotHandler: LiveRuntimeWorkerHandler = async ({
  client,
  job,
}) => {
  const liveStateSnapshotId =
    getString(job.payload, "live_state_snapshot_id") ?? job.scopeId;
  const channel = (
    getString(job.payload, "channel") ?? "realtime"
  ) as LivePublicationChannel;

  const publication = await publishLiveStateSnapshot(client, {
    liveStateSnapshotId,
    channel,
    metadata: getObject(job.payload, "metadata"),
  });

  return {
    publication_id: publication.publicationId,
    live_state_snapshot_id: publication.liveStateSnapshotId,
    publication_version: publication.publicationVersion,
    channel: publication.channel,
    published_at: publication.publishedAt,
  };
};

const DEFAULT_HANDLERS: LiveRuntimeWorkerHandlers = {
  refresh_round: async ({ client, job }) =>
    handleRefreshRoundJob({ client, job }),
  poll_match: async ({ client, job }) =>
    handlePollMatchJob({ client, job }),
  rebuild_league_round: rebuildLeagueRoundHandler,
  publish_snapshot: publishSnapshotHandler,
  retry_publication: publishSnapshotHandler,
};

export async function runLiveRuntimeWorkerOnce(
  input: RunLiveRuntimeWorkerOnceInput,
): Promise<RunLiveRuntimeWorkerOnceResult> {
  const job = await claimLiveRuntimeJob(
    input.client,
    input.workerId,
    input.jobTypes,
  );

  if (!job) {
    return {
      claimed: false,
      completed: false,
      jobId: null,
    };
  }

  const handler = input.handlers?.[job.jobType] ??
    DEFAULT_HANDLERS[job.jobType];

  if (!handler) {
    const error = new LiveRuntimeError({
      code: "LIVE_RUNTIME_UNSUPPORTED_JOB",
      message: `No Live Runtime Worker handler for ${job.jobType}`,
      details: {
        jobId: job.jobId,
        jobType: job.jobType,
      },
    });
    const serialized = serializeWorkerError(error);

    await failLiveRuntimeJob(input.client, {
      jobId: job.jobId,
      workerId: input.workerId,
      error: serialized,
      retryDelaySeconds: input.retryDelaySeconds ?? 30,
    });

    return {
      claimed: true,
      completed: false,
      jobId: job.jobId,
      jobType: job.jobType,
      error: serialized,
    };
  }

  try {
    const result = await handler({
      client: input.client,
      workerId: input.workerId,
      job,
    });

    await completeLiveRuntimeJob(input.client, {
      jobId: job.jobId,
      workerId: input.workerId,
      result,
    });

    return {
      claimed: true,
      completed: true,
      jobId: job.jobId,
      jobType: job.jobType,
      result,
    };
  } catch (error) {
    const serialized = serializeWorkerError(error);

    await failLiveRuntimeJob(input.client, {
      jobId: job.jobId,
      workerId: input.workerId,
      error: serialized,
      retryDelaySeconds: input.retryDelaySeconds ?? 30,
    });

    return {
      claimed: true,
      completed: false,
      jobId: job.jobId,
      jobType: job.jobType,
      error: serialized,
    };
  }
}
