import type { SupabaseClient } from "@supabase/supabase-js";

import type {
  MarketRoundPollingPolicyInput,
} from "./market-round-polling-policy";
import type {
  MarketRoundPollingTarget,
} from "./market-round-scheduler";
import type {
  ProductionRoundContext,
} from "./production-target-loader";

export const COMMUNITY_PRELIVE_REFRESH_INTERVAL_MS =
  24 * 60 * 60 * 1000;

export const COMMUNITY_BUILD_STALE_AFTER_MS =
  60 * 60 * 1000;

export type CanonicalCommunityAction =
  | "refresh"
  | "freeze"
  | "skip";

export type CanonicalCommunityDecision = {
  action: CanonicalCommunityAction;
  reason: string;
};

type FantagolRoundStateRow = {
  id: string;
  sequence: number;
  status: string;
  opens_at: string | null;
  lock_at: string | null;
  starts_at: string | null;
  ends_at: string | null;
};

type MarketSnapshotStateRow = {
  captured_at: string | null;
  snapshot_source: string | null;
  status: string;
};

type CommunityRegistryStateRow = {
  status: string;
  current_phase: string;
  last_requested_at: string | null;
  last_completed_at: string | null;
  next_refresh_at: string | null;
  snapshot_count: number;
  lock_snapshot_id: string | null;
};

function requireIso(
  value: string | null | undefined,
  label: string,
): string {
  if (!value) {
    throw new Error(`${label}_MISSING`);
  }

  const parsed = Date.parse(value);

  if (!Number.isFinite(parsed)) {
    throw new Error(`${label}_INVALID:${value}`);
  }

  return new Date(parsed).toISOString();
}

function earliestKickoff(
  targets: MarketRoundPollingTarget[],
): string {
  const timestamps =
    targets
      .map((target) => Date.parse(target.kickoffAt))
      .filter(Number.isFinite)
      .sort((a, b) => a - b);

  if (timestamps.length === 0) {
    throw new Error(
      "PRODUCTION_MARKET_FIRST_KICKOFF_MISSING",
    );
  }

  return new Date(timestamps[0]).toISOString();
}

async function loadCurrentRoundState(
  client: SupabaseClient,
  fantagolRoundId: string,
): Promise<FantagolRoundStateRow> {
  const { data, error } =
    await client
      .from("fantagol_rounds")
      .select(
        "id,sequence,status,opens_at,lock_at,starts_at,ends_at",
      )
      .eq("id", fantagolRoundId)
      .limit(1)
      .maybeSingle();

  if (error) {
    throw new Error(
      `PRODUCTION_ROUND_STATE_LOAD_FAILED:${error.message}`,
    );
  }

  if (!data) {
    throw new Error(
      "PRODUCTION_ROUND_STATE_NOT_FOUND",
    );
  }

  return data as FantagolRoundStateRow;
}

async function resolveCollectionStartsAt(
  client: SupabaseClient,
  round: FantagolRoundStateRow,
): Promise<string> {
  const { data, error } =
    await client
      .from("fantagol_rounds")
      .select("id,sequence,status,opens_at,lock_at,starts_at,ends_at")
      .lt("sequence", round.sequence)
      .order("sequence", { ascending: false })
      .limit(1)
      .maybeSingle();

  if (error) {
    throw new Error(
      `PRODUCTION_PREVIOUS_ROUND_LOAD_FAILED:${error.message}`,
    );
  }

  const previous =
    data as FantagolRoundStateRow | null;

  if (previous?.ends_at) {
    return requireIso(
      previous.ends_at,
      "PRODUCTION_PREVIOUS_ROUND_END",
    );
  }

  return requireIso(
    round.opens_at,
    "PRODUCTION_COLLECTION_START",
  );
}

async function loadMarketSnapshotState(
  client: SupabaseClient,
  fantagolRoundId: string,
): Promise<MarketSnapshotStateRow[]> {
  const { data, error } =
    await client
      .from("market_intelligence_snapshots")
      .select("captured_at,snapshot_source,status")
      .eq("fantagol_round_id", fantagolRoundId)
      .eq("status", "ready")
      .order("captured_at", { ascending: false });

  if (error) {
    throw new Error(
      `PRODUCTION_MARKET_SNAPSHOT_STATE_LOAD_FAILED:${error.message}`,
    );
  }

  return (data ?? []) as MarketSnapshotStateRow[];
}

function isWithin(
  value: string | null,
  startExclusive: number,
  endInclusive: number,
): boolean {
  if (!value) {
    return false;
  }

  const parsed = Date.parse(value);

  return (
    Number.isFinite(parsed) &&
    parsed > startExclusive &&
    parsed <= endInclusive
  );
}

/**
 * Canonical PACKAGE policy-state resolver.
 *
 * This resolver deliberately does not invoke the R35 Credit Governor:
 * the round-level scheduler consumes PACKAGE temporal state only.
 * ADVANCED/event-level credit allocation remains a separate certified path.
 */
export async function loadCanonicalMarketPolicyInput(input: {
  client: SupabaseClient;
  round: ProductionRoundContext;
  targets: MarketRoundPollingTarget[];
  now: Date;
}): Promise<MarketRoundPollingPolicyInput> {
  const currentRound =
    await loadCurrentRoundState(
      input.client,
      input.round.fantagolRoundId,
    );

  const [
    collectionStartsAt,
    snapshots,
  ] = await Promise.all([
    resolveCollectionStartsAt(
      input.client,
      currentRound,
    ),
    loadMarketSnapshotState(
      input.client,
      input.round.fantagolRoundId,
    ),
  ]);

  const opensAt =
    requireIso(
      currentRound.opens_at ??
        input.round.opensAt,
      "PRODUCTION_MARKET_OPENS_AT",
    );

  const firstKickoffAt =
    earliestKickoff(input.targets);

  const firstKickoffMs =
    Date.parse(firstKickoffAt);

  const packageSnapshots =
    snapshots.filter(
      (snapshot) =>
        snapshot.snapshot_source === "PACKAGE",
    );

  const advancedSnapshots =
    snapshots.filter(
      (snapshot) =>
        snapshot.snapshot_source === "ADVANCED",
    );

  const lastPackageSnapshotAt =
    packageSnapshots[0]?.captured_at ?? null;

  const opensAtMs =
    Date.parse(opensAt);

  const freshSnapshotAvailable =
    packageSnapshots.some((snapshot) => {
      if (!snapshot.captured_at) {
        return false;
      }

      const captured =
        Date.parse(snapshot.captured_at);

      return (
        Number.isFinite(captured) &&
        captured >= opensAtMs
      );
    });

  const fallbackCandidateAvailable =
    packageSnapshots.some((snapshot) => {
      if (!snapshot.captured_at) {
        return false;
      }

      const captured =
        Date.parse(snapshot.captured_at);

      return (
        Number.isFinite(captured) &&
        captured < opensAtMs
      );
    });

  const earlyStart =
    firstKickoffMs -
    48 * 60 * 60 * 1000;

  const earlyEnd =
    firstKickoffMs -
    6 * 60 * 60 * 1000;

  const finalStart =
    firstKickoffMs -
    6 * 60 * 60 * 1000;

  const earlyAdvancedCompleted =
    advancedSnapshots.some(
      (snapshot) =>
        isWithin(
          snapshot.captured_at,
          earlyStart,
          earlyEnd,
        ),
    );

  const finalAdvancedCompleted =
    advancedSnapshots.some(
      (snapshot) =>
        isWithin(
          snapshot.captured_at,
          finalStart,
          firstKickoffMs,
        ),
    );

  /*
   * Prediction opening is the published cross-domain gate.
   * The Surprise engine owns the transition into predictions_open;
   * this resolver does not duplicate Surprise internals.
   */
  const surpriseReferenceReady =
    currentRound.status ===
      "predictions_open" ||
    currentRound.status ===
      "predictions_locked" ||
    currentRound.status === "live" ||
    currentRound.status ===
      "partial_finished" ||
    currentRound.status ===
      "waiting_postponed" ||
    currentRound.status ===
      "final_calculable" ||
    currentRound.status ===
      "final_official" ||
    currentRound.status ===
      "recalculated";

  return {
    now: input.now,
    collectionStartsAt,
    opensAt,
    firstKickoffAt,
    lastPackageSnapshotAt,
    earlyAdvancedCompleted,
    finalAdvancedCompleted,
    surpriseReferenceReady,
    freshSnapshotAvailable,
    fallbackCandidateAvailable,
  };
}

async function loadCommunityRegistryState(
  client: SupabaseClient,
  fantagolRoundId: string,
): Promise<CommunityRegistryStateRow | null> {
  const { data, error } =
    await client
      .from("community_snapshot_registry")
      .select(
        "status,current_phase,last_requested_at,last_completed_at,next_refresh_at,snapshot_count,lock_snapshot_id",
      )
      .eq("fantagol_round_id", fantagolRoundId)
      .limit(1)
      .maybeSingle();

  if (error) {
    throw new Error(
      `PRODUCTION_COMMUNITY_REGISTRY_LOAD_FAILED:${error.message}`,
    );
  }

  return data as
    | CommunityRegistryStateRow
    | null;
}

function isPreLiveRoundStatus(
  status: string,
): boolean {
  return (
    status === "draft" ||
    status === "scheduled" ||
    status === "predictions_open"
  );
}

function shouldFreezeRound(
  round: ProductionRoundContext,
  now: Date,
): boolean {
  if (
    round.status ===
      "predictions_locked" ||
    round.status === "live" ||
    round.status ===
      "partial_finished" ||
    round.status ===
      "waiting_postponed" ||
    round.status ===
      "final_calculable" ||
    round.status ===
      "final_official" ||
    round.status ===
      "recalculated"
  ) {
    return true;
  }

  if (!round.lockAt) {
    return false;
  }

  const lockMs =
    Date.parse(round.lockAt);

  return (
    Number.isFinite(lockMs) &&
    now.getTime() >= lockMs
  );
}

/**
 * Canonical pre-live Community cadence resolver.
 *
 * Registry.next_refresh_at is authoritative when present.
 * Historical rows with next_refresh_at = null fall back to a 24h cadence
 * from last completion/request so stale pre-live registries can recover.
 */
export async function resolveCanonicalCommunityDecision(input: {
  client: SupabaseClient;
  round: ProductionRoundContext;
  now: Date;
}): Promise<CanonicalCommunityDecision> {
  const registry =
    await loadCommunityRegistryState(
      input.client,
      input.round.fantagolRoundId,
    );

  if (
    shouldFreezeRound(
      input.round,
      input.now,
    )
  ) {
    if (registry?.lock_snapshot_id) {
      return {
        action: "skip",
        reason:
          "community_lock_snapshot_already_frozen",
      };
    }

    return {
      action: "freeze",
      reason:
        "community_round_lock_due",
    };
  }

  if (
    !isPreLiveRoundStatus(
      input.round.status,
    )
  ) {
    return {
      action: "skip",
      reason:
        "community_round_not_prelive",
    };
  }

  if (
    !registry ||
    registry.snapshot_count <= 0
  ) {
    return {
      action: "refresh",
      reason:
        "community_initial_snapshot_due",
    };
  }

  if (registry.next_refresh_at) {
    const nextRefreshMs =
      Date.parse(
        registry.next_refresh_at,
      );

    if (
      Number.isFinite(nextRefreshMs) &&
      input.now.getTime() <
        nextRefreshMs
    ) {
      return {
        action: "skip",
        reason:
          "community_next_refresh_not_due",
      };
    }

    return {
      action: "refresh",
      reason:
        "community_next_refresh_due",
    };
  }

  const lastRequestedMs =
    registry.last_requested_at
      ? Date.parse(
          registry.last_requested_at,
        )
      : Number.NaN;

  if (
    registry.status === "building" &&
    Number.isFinite(lastRequestedMs) &&
    input.now.getTime() -
      lastRequestedMs <
      COMMUNITY_BUILD_STALE_AFTER_MS
  ) {
    return {
      action: "skip",
      reason:
        "community_build_in_progress",
    };
  }

  const lastCompletedMs =
    registry.last_completed_at
      ? Date.parse(
          registry.last_completed_at,
        )
      : Number.NaN;

  const cadenceAnchor =
    Number.isFinite(lastCompletedMs)
      ? lastCompletedMs
      : lastRequestedMs;

  if (!Number.isFinite(cadenceAnchor)) {
    return {
      action: "refresh",
      reason:
        "community_refresh_anchor_missing",
    };
  }

  if (
    input.now.getTime() -
      cadenceAnchor >=
    COMMUNITY_PRELIVE_REFRESH_INTERVAL_MS
  ) {
    return {
      action: "refresh",
      reason:
        "community_daily_refresh_due",
    };
  }

  return {
    action: "skip",
    reason:
      "community_daily_refresh_not_due",
  };
}