import type {
  SupabaseClient,
} from "@supabase/supabase-js";

import type {
  AdvancedMarketPlan,
} from "./market-advanced-candidate-builder";
import {
  enqueueLiveRuntimeJob,
  type EnqueuedLiveRuntimeJob,
} from "./job-service";

export type AdvancedEventJobSpec = {
  matchId: string;
  externalMatchId: string;
  scheduledAt: string;
  idempotencyKey: string;
  priority: number;
  payload: Record<string, unknown>;
};

export type ScheduledAdvancedMarketEvents = {
  snapshotSource: "ADVANCED";
  window: AdvancedMarketPlan["window"];
  candidateCount: number;
  selectedCount: number;
  scheduledAt: string;
  jobs: EnqueuedLiveRuntimeJob[];
};

function toIsoSecond(
  date: Date,
): string {
  return new Date(
    Math.floor(
      date.getTime() / 1000,
    ) * 1000,
  ).toISOString();
}

function buildAdvancedEventIdempotencyKey(
  input: {
    fantagolRoundId: string;
    externalMatchId: string;
    window: AdvancedMarketPlan["window"];
  },
): string {
  return [
    "market",
    "poll-match",
    "the_odds_api",
    input.fantagolRoundId,
    "ADVANCED",
    input.window,
    input.externalMatchId,
  ].join(":");
}

/**
 * Converts a Credit-Governor-authorized ADVANCED plan into
 * event-level poll_match job specifications.
 *
 * IMPORTANT:
 * - this function does not score candidates;
 * - this function does not alter the allocation;
 * - this function never adds targets;
 * - plan.selectedTargets is authoritative.
 */
export function buildAdvancedEventJobSpecs(
  input: {
    fantagolRoundId: string;
    plan: AdvancedMarketPlan;
    now: Date;
    correlationId?: string | null;
    priority?: number;
  },
): AdvancedEventJobSpec[] {
  const scheduledAt =
    toIsoSecond(
      input.now,
    );

  const selectedIds =
    new Set(
      input.plan.allocation.selected.map(
        (selected) =>
          selected.eventId,
      ),
    );

  if (
    selectedIds.size !==
    input.plan.selectedTargets.length
  ) {
    throw new Error(
      "ADVANCED_SELECTED_TARGET_COUNT_MISMATCH",
    );
  }

  return input.plan.selectedTargets.map(
    (target) => {
      if (
        !selectedIds.has(
          target.externalMatchId,
        )
      ) {
        throw new Error(
          `ADVANCED_UNAUTHORIZED_TARGET:${target.externalMatchId}`,
        );
      }

      return {
        matchId:
          target.matchId,
        externalMatchId:
          target.externalMatchId,
        scheduledAt,
        priority:
          input.priority ?? 20,
        idempotencyKey:
          buildAdvancedEventIdempotencyKey({
            fantagolRoundId:
              input.fantagolRoundId,
            externalMatchId:
              target.externalMatchId,
            window:
              input.plan.window,
          }),
        payload: {
          provider_code:
            "the_odds_api",
          match_id:
            target.matchId,
          external_match_id:
            target.externalMatchId,
          fantagol_round_id:
            input.fantagolRoundId,
          league_round_ids:
            target.leagueRoundIds ??
            [],
          slot_number:
            target.slotNumber,
          kickoff_at:
            target.kickoffAt,
          current_status:
            target.status,
          market_snapshot_source:
            "ADVANCED",
          market_intelligence:
            true,
          market_operating_mode:
            "ADVANCED",
          advanced_window:
            input.plan.window,
          markets:
            [...input.plan.markets],
        },
      };
    },
  );
}

/**
 * Infrastructure scheduler for selected ADVANCED events.
 *
 * The Credit Governor decision has already happened upstream.
 * Only selectedTargets are converted into poll_match jobs.
 */
export async function scheduleAdvancedMarketEvents(
  input: {
    client: SupabaseClient;
    fantagolRoundId: string;
    plan: AdvancedMarketPlan;
    now: Date;
    correlationId?: string | null;
    causationId?: string | null;
    priority?: number;
  },
): Promise<ScheduledAdvancedMarketEvents> {
  const specs =
    buildAdvancedEventJobSpecs({
      fantagolRoundId:
        input.fantagolRoundId,
      plan:
        input.plan,
      now:
        input.now,
      correlationId:
        input.correlationId,
      priority:
        input.priority,
    });

  const jobs:
    EnqueuedLiveRuntimeJob[] = [];

  for (const spec of specs) {
    jobs.push(
      await enqueueLiveRuntimeJob(
        input.client,
        {
          jobType:
            "poll_match",
          scopeType:
            "match",
          scopeId:
            spec.matchId,
          idempotencyKey:
            spec.idempotencyKey,
          priority:
            spec.priority,
          scheduledAt:
            spec.scheduledAt,
          payload:
            spec.payload,
          correlationId:
            input.correlationId ??
            null,
          causationId:
            input.causationId ??
            null,
        },
      ),
    );
  }

  return {
    snapshotSource:
      "ADVANCED",
    window:
      input.plan.window,
    candidateCount:
      input.plan.candidateCount,
    selectedCount:
      specs.length,
    scheduledAt:
      toIsoSecond(
        input.now,
      ),
    jobs,
  };
}