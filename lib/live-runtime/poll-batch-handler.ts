import type { SupabaseClient } from "@supabase/supabase-js";

import { ingestFootballDataPollResult } from "./football-data-poll-ingestion";
import type { ClaimedLiveRuntimeJob } from "./job-service";
import {
  executeProviderBatchPoll,
} from "./provider-runtime-runner";
import { createDefaultProviderRuntimeRegistry } from "./provider-runtime-registry";
import type {
  ProviderBatchPollMode,
} from "./provider-runtime";



type BatchMatchTarget = {
  matchId: string;
  externalMatchId: string;
  fantagolRoundId: string | null;
  leagueRoundIds: string[];
};

function getBatchMatchTargets(
  payload: Record<string, unknown>,
): BatchMatchTarget[] {
  const value = payload.match_targets;

  if (!Array.isArray(value) || value.length === 0) {
    throw new Error(
      "poll_batch requires non-empty 'match_targets'",
    );
  }

  return value.map((entry, index) => {
    if (
      typeof entry !== "object" ||
      entry === null ||
      Array.isArray(entry)
    ) {
      throw new Error(
        `poll_batch match_targets[${index}] must be an object`,
      );
    }

    const record =
      entry as Record<string, unknown>;

    const matchId = record.match_id;
    const externalMatchId =
      record.external_match_id;

    if (
      typeof matchId !== "string" ||
      matchId.trim() === "" ||
      typeof externalMatchId !== "string" ||
      externalMatchId.trim() === ""
    ) {
      throw new Error(
        `poll_batch match_targets[${index}] has invalid identifiers`,
      );
    }

    const leagueRoundIds =
      record.league_round_ids;

    if (
      leagueRoundIds !== undefined &&
      (
        !Array.isArray(leagueRoundIds) ||
        leagueRoundIds.some(
          (item) =>
            typeof item !== "string" ||
            item.trim() === "",
        )
      )
    ) {
      throw new Error(
        `poll_batch match_targets[${index}] has invalid league_round_ids`,
      );
    }

    const fantagolRoundId =
      record.fantagol_round_id;

    if (
      fantagolRoundId !== undefined &&
      fantagolRoundId !== null &&
      (
        typeof fantagolRoundId !== "string" ||
        fantagolRoundId.trim() === ""
      )
    ) {
      throw new Error(
        `poll_batch match_targets[${index}] has invalid fantagol_round_id`,
      );
    }

    return {
      matchId: matchId.trim(),
      externalMatchId:
        externalMatchId.trim(),
      fantagolRoundId:
        typeof fantagolRoundId === "string"
          ? fantagolRoundId.trim()
          : null,
      leagueRoundIds:
        Array.isArray(leagueRoundIds)
          ? leagueRoundIds.map(
              (item) =>
                (item as string).trim(),
            )
          : [],
    };
  });
}
function getRequiredString(
  payload: Record<string, unknown>,
  field: string,
): string {
  const value = payload[field];

  if (typeof value !== "string" || value.trim() === "") {
    throw new Error(`Missing required field '${field}'.`);
  }

  return value;
}

function getOptionalString(
  payload: Record<string, unknown>,
  field: string,
): string | undefined {
  const value = payload[field];

  return typeof value === "string" &&
    value.trim() !== ""
    ? value
    : undefined;
}

export async function handlePollBatchJob(input: {
  client: SupabaseClient;
  job: ClaimedLiveRuntimeJob;
}) {
  const providerCode =
    getRequiredString(
      input.job.payload,
      "provider_code",
    );

  const matchTargets =
    getBatchMatchTargets(
      input.job.payload,
    );

  const externalMatchIds =
    matchTargets.map(
      (target) =>
        target.externalMatchId,
    );

  const mode =
    getRequiredString(
      input.job.payload,
      "mode",
    ) as ProviderBatchPollMode;

  if (
    mode !== "live" &&
    mode !== "prematch"
  ) {
    throw new Error(
      `Unsupported batch polling mode '${mode}'.`,
    );
  }

  const result =
    await executeProviderBatchPoll(
      input.client,
      createDefaultProviderRuntimeRegistry(),
      providerCode,
      externalMatchIds,
      {
        mode,
        competitionCode:
          getOptionalString(
            input.job.payload,
            "competition_code",
          ) ?? "SA",
        dateFrom:
          getOptionalString(
            input.job.payload,
            "date_from",
          ),
        dateTo:
          getOptionalString(
            input.job.payload,
            "date_to",
          ),
      },
    );

  const targetByExternalId =
    new Map(
      matchTargets.map(
        (target) => [
          target.externalMatchId,
          target,
        ] as const),
    );

  const ingestions = [];

  for (const poll of result.results) {
    const target =
      targetByExternalId.get(
        poll.externalMatchId,
      );

    if (!target) {
      throw new Error(
        `Batch result '${poll.externalMatchId}' has no canonical Match target`,
      );
    }

    ingestions.push(
      await ingestFootballDataPollResult({
        client: input.client,
        poll,
        scope: {
          matchId: target.matchId,
          fantagolRoundId:
            target.fantagolRoundId,
          leagueRoundIds:
            target.leagueRoundIds,
        },
      }),
    );
  }

  return {
    provider_code: result.providerCode,
    mode,
    requested_match_count:
      result.requestedExternalMatchIds.length,
    returned_match_count:
      result.returnedExternalMatchIds.length,
    returned_external_match_ids:
      result.returnedExternalMatchIds,
    ingested_match_count:
      ingestions.length,
    meaningful_change_count:
      ingestions.filter(
        (item) =>
          item.meaningful_change,
      ).length,
    enqueued_job_count:
      ingestions.reduce(
        (count, item) =>
          count +
          item.enqueued_job_ids.length,
        0,
      ),
    ingestions,
    fetched_at: result.fetchedAt,
    date_from:
      getOptionalString(
        input.job.payload,
        "date_from",
      ) ?? null,
    date_to:
      getOptionalString(
        input.job.payload,
        "date_to",
      ) ?? null,
  };
}