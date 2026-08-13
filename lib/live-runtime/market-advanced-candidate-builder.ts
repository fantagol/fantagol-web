import type { SupabaseClient } from "@supabase/supabase-js";

import {
  allocateAdvancedCalls,
  type AdvancedAllocation,
  type AdvancedCandidate,
  type CreditBudgetInput,
} from "../market-intelligence/credit-governor";
import type {
  MarketRoundPollingTarget,
} from "./market-round-scheduler";

export const ADVANCED_MARKETS = [
  "h2h",
  "totals",
  "alternate_totals",
  "btts",
  "correct_score",
] as const;

export type AdvancedMarketWindow =
  | "early"
  | "final";

export type AdvancedMarketPlan = {
  window: AdvancedMarketWindow;
  candidateCount: number;
  allocation: AdvancedAllocation;
  selectedTargets: MarketRoundPollingTarget[];
  markets: readonly string[];
};

type LatestMarketRow = {
  home_probability: number;
  draw_probability: number;
  away_probability: number;
  market_confidence: number;
  model_loss: number;
};

type MovementRow = {
  movement_magnitude: number | null;
};

type MatchIdentityRow = {
  id: string;
  kickoff: string;
  home_team_id: string;
  away_team_id: string;
};

type TeamRow = {
  id: string;
  name: string;
};

type AdvancedSnapshotRow = {
  id: string;
  captured_at: string;
};

type AdvancedMatchRow = {
  match_id: string;
  market_intelligence_snapshot_id: string;
};

function asFiniteNumber(
  value: unknown,
  label: string,
): number {
  const parsed = Number(value);

  if (!Number.isFinite(parsed)) {
    throw new Error(
      `ADVANCED_CANDIDATE_${label}_INVALID`,
    );
  }

  return parsed;
}

function maxMovement(
  rows: MovementRow[],
): number {
  return rows.reduce(
    (max, row) =>
      Math.max(
        max,
        Math.abs(
          Number(
            row.movement_magnitude ?? 0,
          ),
        ),
      ),
    0,
  );
}

async function loadLatestMarket(
  client: SupabaseClient,
  matchId: string,
): Promise<LatestMarketRow> {
  const { data, error } =
    await client.rpc(
      "get_latest_market_intelligence_match_internal",
      {
        p_match_id: matchId,
      },
    );

  if (error) {
    throw new Error(
      `ADVANCED_CANDIDATE_LATEST_LOAD_FAILED:${error.message}`,
    );
  }

  const row =
    Array.isArray(data)
      ? data[0]
      : data;

  if (!row) {
    throw new Error(
      `ADVANCED_CANDIDATE_LATEST_MISSING:${matchId}`,
    );
  }

  return row as LatestMarketRow;
}

async function loadMovementMagnitude(
  client: SupabaseClient,
  matchId: string,
): Promise<number> {
  const { data, error } =
    await client.rpc(
      "get_market_intelligence_match_movements_internal",
      {
        p_match_id: matchId,
        p_limit: 100,
      },
    );

  if (error) {
    throw new Error(
      `ADVANCED_CANDIDATE_MOVEMENT_LOAD_FAILED:${error.message}`,
    );
  }

  return maxMovement(
    (data ?? []) as MovementRow[],
  );
}

async function loadAdvancedAgeByMatch(
  client: SupabaseClient,
  fantagolRoundId: string,
  matchIds: string[],
  now: Date,
): Promise<
  Map<
    string,
    {
      hasAdvancedSnapshot: boolean;
      lastAdvancedAgeHours: number | null;
    }
  >
> {
  const { data: snapshots, error: snapshotError } =
    await client
      .from("market_intelligence_snapshots")
      .select("id,captured_at")
      .eq(
        "fantagol_round_id",
        fantagolRoundId,
      )
      .eq("snapshot_source", "ADVANCED")
      .eq("status", "ready")
      .order("captured_at", {
        ascending: false,
      });

  if (snapshotError) {
    throw new Error(
      `ADVANCED_SNAPSHOT_LOAD_FAILED:${snapshotError.message}`,
    );
  }

  const typedSnapshots =
    (snapshots ?? []) as AdvancedSnapshotRow[];

  if (typedSnapshots.length === 0) {
    return new Map(
      matchIds.map((matchId) => [
        matchId,
        {
          hasAdvancedSnapshot: false,
          lastAdvancedAgeHours: null,
        },
      ]),
    );
  }

  const capturedAtBySnapshotId =
    new Map(
      typedSnapshots.map((row) => [
        row.id,
        row.captured_at,
      ]),
    );

  const { data: matchRows, error: matchError } =
    await client
      .from(
        "market_intelligence_match_snapshots",
      )
      .select("match_id,market_intelligence_snapshot_id")
      .in("market_intelligence_snapshot_id",
        typedSnapshots.map(
          (row) => row.id,
        ),
      )
      .in("match_id", matchIds);

  if (matchError) {
    throw new Error(
      `ADVANCED_MATCH_SNAPSHOT_LOAD_FAILED:${matchError.message}`,
    );
  }

  const latestByMatch =
    new Map<string, number>();

  for (
    const row of
      (matchRows ?? []) as AdvancedMatchRow[]
  ) {
    const capturedAt =
      capturedAtBySnapshotId.get(
        row.market_intelligence_snapshot_id,
      );

    if (!capturedAt) continue;

    const timestamp =
      Date.parse(capturedAt);

    if (
      !Number.isFinite(timestamp)
    ) {
      continue;
    }

    const previous =
      latestByMatch.get(row.match_id);

    if (
      previous === undefined ||
      timestamp > previous
    ) {
      latestByMatch.set(
        row.match_id,
        timestamp,
      );
    }
  }

  const result =
    new Map<
      string,
      {
        hasAdvancedSnapshot: boolean;
        lastAdvancedAgeHours: number | null;
      }
    >();

  for (const matchId of matchIds) {
    const timestamp =
      latestByMatch.get(matchId);

    if (timestamp === undefined) {
      result.set(matchId, {
        hasAdvancedSnapshot: false,
        lastAdvancedAgeHours: null,
      });
      continue;
    }

    result.set(matchId, {
      hasAdvancedSnapshot: true,
      lastAdvancedAgeHours:
        Math.max(
          0,
          (
            now.getTime() -
            timestamp
          ) /
            (60 * 60 * 1000),
        ),
    });
  }

  return result;
}

export async function loadAdvancedCandidates(
  input: {
    client: SupabaseClient;
    fantagolRoundId: string;
    targets: MarketRoundPollingTarget[];
    now: Date;
  },
): Promise<AdvancedCandidate[]> {
  const matchIds =
    input.targets.map(
      (target) => target.matchId,
    );

  const { data: matches, error: matchError } =
    await input.client
      .from("matches")
      .select(
        "id,kickoff,home_team_id,away_team_id",
      )
      .in("id", matchIds);

  if (matchError) {
    throw new Error(
      `ADVANCED_MATCH_IDENTITY_LOAD_FAILED:${matchError.message}`,
    );
  }

  const typedMatches =
    (matches ?? []) as MatchIdentityRow[];

  const teamIds =
    [
      ...new Set(
        typedMatches.flatMap(
          (match) => [
            match.home_team_id,
            match.away_team_id,
          ],
        ),
      ),
    ];

  const { data: teams, error: teamError } =
    await input.client
      .from("teams")
      .select("id,name")
      .in("id", teamIds);

  if (teamError) {
    throw new Error(
      `ADVANCED_TEAM_LOAD_FAILED:${teamError.message}`,
    );
  }

  const teamNameById =
    new Map(
      ((teams ?? []) as TeamRow[]).map(
        (team) => [
          team.id,
          team.name,
        ],
      ),
    );

  const matchById =
    new Map(
      typedMatches.map(
        (match) => [
          match.id,
          match,
        ],
      ),
    );

  const advancedAgeByMatch =
    await loadAdvancedAgeByMatch(
      input.client,
      input.fantagolRoundId,
      matchIds,
      input.now,
    );

  const candidates:
    AdvancedCandidate[] = [];

  for (const target of input.targets) {
    const match =
      matchById.get(target.matchId);

    if (!match) {
      throw new Error(
        `ADVANCED_MATCH_IDENTITY_MISSING:${target.matchId}`,
      );
    }

    const [
      latest,
      movementMagnitude,
    ] = await Promise.all([
      loadLatestMarket(
        input.client,
        target.matchId,
      ),
      loadMovementMagnitude(
        input.client,
        target.matchId,
      ),
    ]);

    const homeTeam =
      teamNameById.get(
        match.home_team_id,
      );

    const awayTeam =
      teamNameById.get(
        match.away_team_id,
      );

    if (!homeTeam || !awayTeam) {
      throw new Error(
        `ADVANCED_TEAM_IDENTITY_MISSING:${target.matchId}`,
      );
    }

    const kickoffMs =
      Date.parse(match.kickoff);

    if (!Number.isFinite(kickoffMs)) {
      throw new Error(
        `ADVANCED_KICKOFF_INVALID:${target.matchId}`,
      );
    }

    const age =
      advancedAgeByMatch.get(
        target.matchId,
      ) ?? {
        hasAdvancedSnapshot: false,
        lastAdvancedAgeHours: null,
      };

    candidates.push({
      eventId:
        target.externalMatchId,
      homeTeam,
      awayTeam,
      hoursToKickoff:
        (kickoffMs -
          input.now.getTime()) /
        (60 * 60 * 1000),
      sign: {
        home: asFiniteNumber(
          latest.home_probability,
          "HOME_PROBABILITY",
        ),
        draw: asFiniteNumber(
          latest.draw_probability,
          "DRAW_PROBABILITY",
        ),
        away: asFiniteNumber(
          latest.away_probability,
          "AWAY_PROBABILITY",
        ),
      },
      marketConfidence:
        asFiniteNumber(
          latest.market_confidence,
          "MARKET_CONFIDENCE",
        ),
      modelLoss:
        asFiniteNumber(
          latest.model_loss,
          "MODEL_LOSS",
        ),
      movementMagnitude,
      lastAdvancedAgeHours:
        age.lastAdvancedAgeHours,
      hasAdvancedSnapshot:
        age.hasAdvancedSnapshot,
    });
  }

  return candidates;
}

export async function buildAdvancedMarketPlan(
  input: {
    client: SupabaseClient;
    fantagolRoundId: string;
    targets: MarketRoundPollingTarget[];
    now: Date;
    window: AdvancedMarketWindow;
    budgetInput: CreditBudgetInput;
    maxCallsThisRun: number;
    minimumPriority?: number;
  },
): Promise<AdvancedMarketPlan> {
  const candidates =
    await loadAdvancedCandidates({
      client: input.client,
      fantagolRoundId:
        input.fantagolRoundId,
      targets: input.targets,
      now: input.now,
    });

  const allocation =
    allocateAdvancedCalls(
      input.budgetInput,
      candidates,
      {
        maxCallsThisRun:
          input.maxCallsThisRun,
        minimumPriority:
          input.minimumPriority,
      },
    );

  const targetByEventId =
    new Map(
      input.targets.map(
        (target) => [
          target.externalMatchId,
          target,
        ],
      ),
    );

  const selectedTargets =
    allocation.selected.map(
      (selected) => {
        const target =
          targetByEventId.get(
            selected.eventId,
          );

        if (!target) {
          throw new Error(
            `ADVANCED_SELECTED_TARGET_MISSING:${selected.eventId}`,
          );
        }

        return target;
      },
    );

  return {
    window: input.window,
    candidateCount:
      candidates.length,
    allocation,
    selectedTargets,
    markets: ADVANCED_MARKETS,
  };
}