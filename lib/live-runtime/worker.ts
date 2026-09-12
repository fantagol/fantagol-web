import type { SupabaseClient } from "@supabase/supabase-js";

import { handleCertificationReadinessJob } from "./certification-readiness-handler";
import { handleCertifyAchievementStateJob } from "./certify-achievement-state-handler";
import { handleCertifyMatchResultJob } from "./certify-match-result-handler";
import { handleCertifyRoundJob } from "./certify-round-handler";
import { LiveRuntimeError } from "./errors";
import {
  handleTerminalGameObjectiveHook,
} from "./terminal-game-objective-hook";
import { handlePollBatchJob } from "./poll-batch-handler";
import { handlePollMatchJob } from "./poll-match-handler";
import {
  claimLiveRuntimeJob,
  claimLiveRuntimeJobById,
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
import { handleRoundCertificationReadinessJob } from "./round-certification-readiness-handler";
import { launchRoundCertificationReadinessWorkflow } from "./round-certification-readiness-workflow";
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
  jobId?: string | null;
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

  // R112-R6: a primary_live rebuild is allowed to rebuild simulations,
  // materialize a Live State Snapshot and publish realtime, but it must never
  // enter the Football-Data certification-readiness workflow.
  const rebuildProvenance =
    getString(job.payload, "rebuild_provenance") ??
    "football_data_receipt";
  const primaryLiveRebuild = rebuildProvenance === "primary_live";

  const rebuilt = await rebuildLeagueRoundSimulation(client, {
    leagueRoundId: job.scopeId,
    createdByMemberId: getString(
      job.payload,
      "created_by_member_id",
    ),
    correlationId: job.correlationId,
    versions,
  });

  const liveState = {
    schema_version: 1,
    source: primaryLiveRebuild
      ? "TuttoilcalcioPrimaryLive"
      : "LiveRuntimeWorker",
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

  const publicationChannel =
    getString(job.payload, "publication_channel") ?? "realtime";

  /*
   * LIVE publication is intentionally separated from FINAL certification.
   *
   * Every healthy non-terminal Digital Twin snapshot gets a queued realtime
   * publication handoff. A terminal snapshot is deliberately left to the
   * existing certify_round -> certified_snapshot_publication path so the
   * canonical terminal publication keeps its certification metadata.
   */
  const roundView = getObject(rebuilt.digitalTwin, "round");
  const matchCount = roundView.match_count;
  const finishedMatchCount = roundView.finished_match_count;
  const pendingMatchCount = roundView.pending_match_count;

  const terminalRound =
    typeof matchCount === "number" &&
    matchCount > 0 &&
    typeof finishedMatchCount === "number" &&
    finishedMatchCount === matchCount &&
    typeof pendingMatchCount === "number" &&
    pendingMatchCount === 0;

  const livePublicationJob = terminalRound
    ? null
    : await enqueueLiveRuntimeJob(client, {
        jobType: "publish_snapshot",
        scopeType: "live_state_snapshot",
        scopeId: snapshot.liveStateSnapshotId,
        idempotencyKey: [
          "live",
          "publish-snapshot",
          snapshot.liveStateSnapshotId,
          publicationChannel,
        ].join(":"),
        // R114-R5-R95: realtime publication is a hot-path handoff.
        // It must outrank rebuild/readiness backlog once the coherent UI
        // Digital Twin snapshot already exists.
        priority: primaryLiveRebuild ? 11 : 40,
        payload: {
          live_state_snapshot_id: snapshot.liveStateSnapshotId,
          channel: publicationChannel,
          metadata: {
            publication_type: "live_state",
            source_job_id: job.jobId,
            source_rebuild_job_id: job.jobId,
            rebuild_provenance: rebuildProvenance,
            live_authority_source:
              getString(job.payload, "live_authority_source"),
            live_authority_observation_id:
              getString(job.payload, "live_authority_observation_id"),
            league_round_id: rebuilt.leagueRoundId,
            calculation_run_id: rebuilt.calculationRunId,
            ui_simulation_id: rebuilt.uiSimulationId,
            live_state_snapshot_id: snapshot.liveStateSnapshotId,
          },
        },
        correlationId: job.correlationId,
        causationId: job.jobId,
      });

  const certificationReadinessWorkflow =
    primaryLiveRebuild
      ? null
      : await launchRoundCertificationReadinessWorkflow({
      client,
      leagueRoundId: rebuilt.leagueRoundId,
      calculationRunId: rebuilt.calculationRunId,
      uiSimulationId: rebuilt.uiSimulationId,
      liveStateSnapshotId: snapshot.liveStateSnapshotId,

      publicationChannel,
      publicationMetadata: {
        source_rebuild_job_id: job.jobId,
        ui_simulation_id: rebuilt.uiSimulationId,
        live_state_snapshot_id: snapshot.liveStateSnapshotId,
      },
      engineVersion:
        getString(job.payload, "round_certification_engine_version") ??
        "round-certification-v1",
      reason:
        getString(job.payload, "round_certification_reason") ??
        "automatic official round certification",
      committedByMemberId: getString(
        job.payload,
        "committed_by_member_id",
      ),
      correlationId: job.correlationId,
      causationId: job.jobId,
      triggerJobId: job.jobId,
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
    live_publication_job_id:
      livePublicationJob?.jobId ?? null,
    live_publication_job_inserted:
      livePublicationJob?.inserted ?? false,
    live_publication_skipped_terminal:
      terminalRound,
    certification_readiness_skipped_primary_live:
      primaryLiveRebuild,
    certification_readiness_workflow_id:
      certificationReadinessWorkflow?.workflowId ?? null,
    certification_readiness_workflow_inserted:
      certificationReadinessWorkflow?.workflowInserted ?? false,
    certification_readiness_job_id:
      certificationReadinessWorkflow?.jobId ?? null,
    certification_readiness_job_inserted:
      certificationReadinessWorkflow?.jobInserted ?? false,
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
  poll_batch: async ({ client, job }) =>
    handlePollBatchJob({ client, job }),
  poll_match: async ({ client, job }) =>
    handlePollMatchJob({ client, job }),
  rebuild_league_round: rebuildLeagueRoundHandler,
  publish_snapshot: publishSnapshotHandler,
  retry_publication: publishSnapshotHandler,
  evaluate_certification_readiness: async ({ client, job }) =>
    handleCertificationReadinessJob({ client, job }),
  certify_match_result: async ({ client, job }) =>
    handleCertifyMatchResultJob({ client, job }),
  evaluate_round_certification_readiness: async ({ client, job }) =>
    handleRoundCertificationReadinessJob({ client, job }),
  certify_round: async ({ client, job }) =>
    handleCertifyRoundJob({ client, job }),
  certify_achievement_state: async ({ client, job }) =>
    handleCertifyAchievementStateJob({ client, job }),
};

export async function runLiveRuntimeWorkerOnce(
  input: RunLiveRuntimeWorkerOnceInput,
): Promise<RunLiveRuntimeWorkerOnceResult> {
  const job =
    input.jobId
      ? await claimLiveRuntimeJobById(
          input.client,
          input.jobId,
          input.workerId,
        )
      : await claimLiveRuntimeJob(
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

    await handleTerminalGameObjectiveHook(
      input.client,
      job,
    );

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
