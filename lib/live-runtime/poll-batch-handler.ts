import type { SupabaseClient } from "@supabase/supabase-js";

import { ingestFootballDataPollResult } from "./football-data-poll-ingestion";
import type { ClaimedLiveRuntimeJob } from "./job-service";
import {
  persistMarketBatchIntelligence,
  type MarketBatchCanonicalMatch,
} from "./market-intelligence-round-orchestrator";
import {
  buildTheOddsRoundBootstrapMapping,
  loadTheOddsBootstrapCanonicalTargets,
  persistTheOddsRoundBootstrapMapping,
} from "./the-odds-package-bootstrap";
import { persistCanonicalOddsSnapshot } from "./odds-snapshot-service";
import {
  executeProviderBatchPoll,
  executeProviderPoll,
} from "./provider-runtime-runner";
import { createDefaultProviderRuntimeRegistry } from "./provider-runtime-registry";
import type {
  ProviderBatchPollMode,
} from "./provider-runtime";
import {
  normalizeTheOddsApiSnapshot,
} from "./the-odds-api-snapshot-normalizer";

type BatchMatchTarget = {
  matchId: string;
  externalMatchId: string;
  fantagolRoundId: string | null;
  slotNumber: number | null;
  leagueRoundIds: string[];
};

const FOOTBALL_DATA_TERMINAL_VERIFICATION_LIVE_STATUSES =
  new Set([
    "live_first_half",
    "halftime",
    "live_second_half",
    "extra_time",
    "penalties",
  ]);
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

    const slotNumber =
      record.slot_number;

    if (
      slotNumber !== undefined &&
      slotNumber !== null &&
      (
        typeof slotNumber !== "number" ||
        !Number.isInteger(slotNumber) ||
        slotNumber <= 0
      )
    ) {
      throw new Error(
        `poll_batch match_targets[${index}] has invalid slot_number`,
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
      slotNumber:
        typeof slotNumber === "number"
          ? slotNumber
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

  if (
    typeof value !== "string" ||
    value.trim() === ""
  ) {
    throw new Error(
      `Missing required field '${field}'.`,
    );
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

export type TheOddsBootstrapDiscoveryPlan =
  | {
      bootstrapDiscovery: false;
    }
  | {
      bootstrapDiscovery: true;
      fantagolRoundId: string;
      competitionCode: string;
    };

/**
 * Parse the explicit The Odds API mapping-bootstrap poll_batch contract.
 *
 * This is deliberately separate from ordinary match_targets polling:
 *
 * normal poll_batch
 *   -> canonical external Match IDs already exist
 *
 * bootstrap discovery poll_batch
 *   -> external Match IDs do NOT exist yet
 *   -> sport-level PACKAGE discovery will establish them
 *
 * R47-R2B2-A only recognizes and validates this contract.
 * Execution remains fail-closed before any provider request.
 */
export function parseTheOddsBootstrapDiscoveryPlan(
  input: {
    payload: Record<string, unknown>;
    providerCode: string;
    mode: ProviderBatchPollMode;
  },
): TheOddsBootstrapDiscoveryPlan {
  const rawDiscovery =
    input.payload.bootstrap_discovery;

  if (rawDiscovery !== true) {
    return {
      bootstrapDiscovery: false,
    };
  }

  if (
    input.providerCode !==
    "the_odds_api"
  ) {
    throw new Error(
      "THE_ODDS_BOOTSTRAP_DISCOVERY_PROVIDER_INVALID",
    );
  }

  if (input.mode !== "prematch") {
    throw new Error(
      "THE_ODDS_BOOTSTRAP_DISCOVERY_MODE_INVALID",
    );
  }

  /*
   * Never permit a hybrid job.
   *
   * A bootstrap discovery job cannot carry match_targets because those
   * targets necessarily imply provider external IDs already exist.
   */
  if (
    input.payload.match_targets !==
    undefined
  ) {
    throw new Error(
      "THE_ODDS_BOOTSTRAP_DISCOVERY_MATCH_TARGETS_FORBIDDEN",
    );
  }

  const fantagolRoundId =
    getRequiredString(
      input.payload,
      "fantagol_round_id",
    );

  const competitionCode =
    getOptionalString(
      input.payload,
      "competition_code",
    ) ?? "SA";

  return {
    bootstrapDiscovery: true,
    fantagolRoundId,
    competitionCode,
  };
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

  const bootstrapDiscovery =
    parseTheOddsBootstrapDiscoveryPlan({
      payload:
        input.job.payload,
      providerCode,
      mode,
    });

  /*
   * R47-R2B2-C bootstrap discovery execution.
   *
   * canonical Round Match Set
   *   -> one sport-level The Odds API PACKAGE discovery
   *   -> deterministic exact fixture mapping
   *   -> atomic DB mapping authority
   *
   * EVENT / ADVANCED transport remains excluded by the
   * bootstrap payload parser.
   */
  if (
    bootstrapDiscovery.bootstrapDiscovery
  ) {
    const canonicalTargets =
      await loadTheOddsBootstrapCanonicalTargets({
        client:
          input.client,
        fantagolRoundId:
          bootstrapDiscovery.fantagolRoundId,
      });

    const discoveryResult =
      await executeProviderBatchPoll(
        input.client,
        createDefaultProviderRuntimeRegistry(),
        providerCode,
        [],
        {
          mode,
          competitionCode:
            bootstrapDiscovery.competitionCode,
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
          discovery: true,
        },
      );

    const mappings =
      buildTheOddsRoundBootstrapMapping({
        targets:
          canonicalTargets,
        polls:
          discoveryResult.results,
      });

    const mappingPersistence =
      await persistTheOddsRoundBootstrapMapping({
        client:
          input.client,
        fantagolRoundId:
          bootstrapDiscovery.fantagolRoundId,
        mappings,
      });

    return {
      provider_code:
        providerCode,
      mode,
      bootstrap_discovery:
        true,
      fantagol_round_id:
        bootstrapDiscovery.fantagolRoundId,
      competition_code:
        bootstrapDiscovery.competitionCode,
      canonical_target_count:
        canonicalTargets.length,
      provider_event_count:
        discoveryResult.results.length,
      mapping_count:
        mappings.length,
      mapped_match_count:
        mappingPersistence.mapped_match_count,
      inserted_match_count:
        mappingPersistence.inserted_match_count,
      distinct_external_match_count:
        mappingPersistence.distinct_external_match_count,
      mapping_idempotent:
        mappingPersistence.idempotent,
      requested_external_match_ids:
        discoveryResult.requestedExternalMatchIds,
      returned_external_match_ids:
        discoveryResult.returnedExternalMatchIds,
    };
  }

  const matchTargets =
    getBatchMatchTargets(
      input.job.payload,
    );

  const externalMatchIds =
    matchTargets.map(
      (target) =>
        target.externalMatchId,
    );

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

  if (providerCode === "football_data") {
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

    const returnedExternalIdSet =
      new Set(
        result.returnedExternalMatchIds,
      );

    const missingRequestedExternalIds =
      mode === "live"
        ? result.requestedExternalMatchIds.filter(
            (externalMatchId) =>
              !returnedExternalIdSet.has(
                externalMatchId,
              ),
          )
        : [];

    const missingTargets =
      missingRequestedExternalIds.map(
        (externalMatchId) => {
          const target =
            targetByExternalId.get(
              externalMatchId,
            );

          if (!target) {
            throw new Error(
              `Missing LIVE batch target '${externalMatchId}' has no canonical Match target`,
            );
          }

          return target;
        },
      );

    let terminalVerificationTargets:
      BatchMatchTarget[] = [];

    if (missingTargets.length > 0) {
      const {
        data: canonicalStatusData,
        error: canonicalStatusError,
      } = await input.client
        .from("matches")
        .select("id,status")
        .in(
          "id",
          missingTargets.map(
            (target) => target.matchId,
          ),
        );

      if (canonicalStatusError) {
        throw new Error(
          `FOOTBALL_DATA_TERMINAL_STATUS_LOOKUP_FAILED: ${canonicalStatusError.message}`,
        );
      }

      const canonicalLiveMatchIds =
        new Set(
          (
            (canonicalStatusData ?? []) as Array<{
              id: string;
              status: string;
            }>
          )
            .filter((row) =>
              FOOTBALL_DATA_TERMINAL_VERIFICATION_LIVE_STATUSES.has(
                row.status,
              ),
            )
            .map((row) => row.id),
        );

      terminalVerificationTargets =
        missingTargets.filter(
          (target) =>
            canonicalLiveMatchIds.has(
              target.matchId,
            ),
        );
    }

    const terminalVerificationExternalIds:
      string[] = [];

    if (
      terminalVerificationTargets.length > 0
    ) {
      const pointRegistry =
        createDefaultProviderRuntimeRegistry();

      for (
        const target
        of terminalVerificationTargets
      ) {
        const terminalPoll =
          await executeProviderPoll(
            input.client,
            pointRegistry,
            providerCode,
            target.externalMatchId,
          );

        terminalVerificationExternalIds.push(
          target.externalMatchId,
        );

        ingestions.push(
          await ingestFootballDataPollResult({
            client: input.client,
            poll: terminalPoll,
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
    }

    return {
      branch:
        "football_data_batch",
      provider_code:
        result.providerCode,
      mode,
      requested_match_count:
        result.requestedExternalMatchIds.length,
      returned_match_count:
        result.returnedExternalMatchIds.length,
      returned_external_match_ids:
        result.returnedExternalMatchIds,
      missing_requested_match_count:
        missingRequestedExternalIds.length,
      missing_requested_external_match_ids:
        missingRequestedExternalIds,
      terminal_verification_match_count:
        terminalVerificationExternalIds.length,
      terminal_verification_external_match_ids:
        terminalVerificationExternalIds,
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
      fetched_at:
        result.fetchedAt,
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
  if (providerCode === "the_odds_api") {
    const canonicalMatches:
      MarketBatchCanonicalMatch[] = [];

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

      if (
        !target.fantagolRoundId ||
        target.slotNumber === null
      ) {
        throw new Error(
          "MARKET_BATCH_TARGET_ROUND_SLOT_REQUIRED",
        );
      }

      const snapshot =
        normalizeTheOddsApiSnapshot({
          providerCode:
            poll.providerCode,
          externalMatchId:
            poll.externalMatchId,
          fetchedAt:
            poll.fetchedAt,
          payload:
            poll.payload,
        });

      const persisted =
        await persistCanonicalOddsSnapshot(
          input.client,
          {
            matchId:
              target.matchId,
            providerPayload:
              poll.payload,
            snapshot,
          },
        );

      canonicalMatches.push({
        matchId:
          target.matchId,
        externalMatchId:
          poll.externalMatchId,
        oddsMarketSnapshotId:
          persisted.oddsMarketSnapshotId,
        slotNumber:
          target.slotNumber,
        fetchedAt:
          poll.fetchedAt,
        providerPayload:
          poll.payload,
      });
    }

    const roundIds =
      new Set(
        matchTargets.map(
          (target) =>
            target.fantagolRoundId,
        ),
      );

    if (
      roundIds.size !== 1 ||
      roundIds.has(null)
    ) {
      throw new Error(
        "MARKET_BATCH_SINGLE_ROUND_REQUIRED",
      );
    }

    if (
      canonicalMatches.length !==
      matchTargets.length
    ) {
      throw new Error(
        "MARKET_BATCH_INCOMPLETE_PROVIDER_RESULT",
      );
    }

    const fantagolRoundId =
      matchTargets[0]
        ?.fantagolRoundId;

    if (!fantagolRoundId) {
      throw new Error(
        "MARKET_BATCH_ROUND_REQUIRED",
      );
    }

    const source =
      getOptionalString(
        input.job.payload,
        "market_snapshot_source",
      ) ?? "PACKAGE";

    if (
      source !== "PACKAGE" &&
      source !== "ADVANCED"
    ) {
      throw new Error(
        "MARKET_BATCH_SOURCE_INVALID",
      );
    }

    const market =
      await persistMarketBatchIntelligence({
        client:
          input.client,
        fantagolRoundId,
        source,
        capturedAt:
          result.fetchedAt,
        matches:
          canonicalMatches,
        metadata: {
          source_job_id:
            input.job.jobId,
          provider_code:
            result.providerCode,
          provider_transport:
            result.transport,
          market_operating_mode:
            getOptionalString(
              input.job.payload,
              "market_operating_mode",
            ) ?? null,
          market_policy_reason:
            getOptionalString(
              input.job.payload,
              "market_policy_reason",
            ) ?? null,
        },
      });

    return {
      branch:
        "official_odds_market_intelligence_batch",
      provider_code:
        result.providerCode,
      mode,
      requested_match_count:
        result.requestedExternalMatchIds.length,
      returned_match_count:
        result.returnedExternalMatchIds.length,
      persisted_match_count:
        canonicalMatches.length,
      complete_batch:
        canonicalMatches.length ===
        matchTargets.length,
      market_modeled_match_count:
        market.modeledMatchCount,
      market_snapshot:
        market.persistence,
      fetched_at:
        result.fetchedAt,
      transport:
        result.transport,
    };
  }

  throw new Error(
    `Unsupported poll_batch provider '${providerCode}'.`,
  );
}
