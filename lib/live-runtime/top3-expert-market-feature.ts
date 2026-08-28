import type {
  SupabaseClient,
} from "@supabase/supabase-js";

import type {
  BmInterpolatedResult,
} from "../market-intelligence/score-distribution";

export const TOP3_EXPERT_FEATURE_VERSION =
  "TOP3_EXPERT_FEATURE_V1" as const;

export const BM_INTERPOLATED_V2 =
  "BM_INTERPOLATED_V2" as const;

export type MarketRuntimeAlgorithmVersion =
  | "BM_INTERPOLATED_V1"
  | typeof BM_INTERPOLATED_V2;

type CohortRow = {
  league_id: string;
  league_member_id: string;
  user_id: string;
  rank: number;
  rank_weight: number | string;
};

type LeagueRoundRow = {
  id: string;
  league_id: string;
};

type PredictionRow = {
  league_round_id: string;
  league_member_id: string;
  user_id: string;
  match_id: string;
  home_prediction: number;
  away_prediction: number;
  official_submitted_at: string;
  submitted_version: number;
};

type FeatureExact = {
  score: string;
  homeGoals: number;
  awayGoals: number;
  probability: number;
};

export type Top3ExpertFeatureV1 = {
  featureVersion:
    typeof TOP3_EXPERT_FEATURE_VERSION;

  leagueCount: number;
  cohortMemberCount: number;
  availablePredictionCount: number;

  /*
   * Across the future Community each league is one
   * equal expert panel. Inside the league:
   * rank 1 = .45, rank 2 = .33, rank 3 = .22.
   *
   * Missing predictions are not redistributed.
   * They reduce coverageWeight and therefore reduce
   * the maximum influence of this feature.
   */
  coverageWeight: number;

  sign: {
    home: number;
    draw: number;
    away: number;
  };

  exact: FeatureExact[];
};

export type BmInterpolatedRuntimeResult =
  Omit<
    BmInterpolatedResult,
    "algorithmVersion"
  > & {
    algorithmVersion:
      MarketRuntimeAlgorithmVersion;
  };

const RANK_WEIGHT = new Map([
  [1, 0.45],
  [2, 0.33],
  [3, 0.22],
]);

const TOP3_MIN_ACTIVE_USER_PARTICIPANTS = 4;

const MAX_TOP3_WEIGHT = 0.18;

function numberValue(
  value: unknown,
): number {
  const parsed =
    typeof value === "number"
      ? value
      : Number(value);

  return Number.isFinite(parsed)
    ? parsed
    : 0;
}

function clamp01(
  value: number,
): number {
  return Math.max(
    0,
    Math.min(1, value),
  );
}

function round6(
  value: number,
): number {
  return (
    Math.round(
      value * 1_000_000,
    ) /
    1_000_000
  );
}

function latestPrediction(
  current: PredictionRow | undefined,
  candidate: PredictionRow,
): PredictionRow {
  if (!current) return candidate;

  const currentAt =
    Date.parse(
      current.official_submitted_at,
    );

  const candidateAt =
    Date.parse(
      candidate.official_submitted_at,
    );

  if (candidateAt > currentAt) {
    return candidate;
  }

  if (
    candidateAt === currentAt &&
    candidate.submitted_version >
      current.submitted_version
  ) {
    return candidate;
  }

  return current;
}

export async function
loadActiveMarketRuntimeAlgorithmVersion(
  client: SupabaseClient,
): Promise<MarketRuntimeAlgorithmVersion> {
  const { data, error } =
    await client
      .from(
        "market_intelligence_models",
      )
      .select("algorithm_version")
      .eq(
        "model_code",
        "BM_INTERPOLATED",
      )
      .eq("status", "active")
      .order(
        "model_version",
        { ascending: false },
      )
      .limit(1);

  if (error) {
    throw new Error(
      `TOP3_ACTIVE_MODEL_LOOKUP_FAILED:${error.message}`,
    );
  }

  const version =
    data?.[0]?.algorithm_version;

  if (
    version !==
      "BM_INTERPOLATED_V1" &&
    version !==
      BM_INTERPOLATED_V2
  ) {
    throw new Error(
      `TOP3_ACTIVE_MODEL_VERSION_INVALID:${String(version)}`,
    );
  }

  return version;
}

async function previousRoundId(
  client: SupabaseClient,
  targetRoundId: string,
): Promise<string | null> {
  const {
    data: current,
    error: currentError,
  } =
    await client
      .from("fantagol_rounds")
      .select("id,starts_at")
      .eq("id", targetRoundId)
      .maybeSingle();

  if (currentError) {
    throw new Error(
      `TOP3_CURRENT_ROUND_FAILED:${currentError.message}`,
    );
  }

  if (
    !current ||
    typeof current.starts_at !==
      "string"
  ) {
    return null;
  }

  const {
    data: previous,
    error: previousError,
  } =
    await client
      .from("fantagol_rounds")
      .select("id")
      .lt(
        "starts_at",
        current.starts_at,
      )
      .order(
        "starts_at",
        { ascending: false },
      )
      .limit(1);

  if (previousError) {
    throw new Error(
      `TOP3_PREVIOUS_ROUND_FAILED:${previousError.message}`,
    );
  }

  return previous?.[0]?.id ?? null;
}

export async function
ensureFrozenCommunityTop3Cohort(
  client: SupabaseClient,
  targetRoundId: string,
): Promise<void> {
  const {
    data: existing,
    error: existingError,
  } =
    await client
      .from(
        "community_top3_cohort_members",
      )
      .select("id")
      .eq(
        "target_fantagol_round_id",
        targetRoundId,
      )
      .limit(1);

  if (existingError) {
    throw new Error(
      `TOP3_COHORT_LOOKUP_FAILED:${existingError.message}`,
    );
  }

  if (
    (existing ?? []).length > 0
  ) {
    return;
  }

  const basisRoundId =
    await previousRoundId(
      client,
      targetRoundId,
    );

  if (!basisRoundId) {
    return;
  }

  /*
   * TOP3_CANONICAL_STANDINGS_SNAPSHOT
   *
   * The Top3 service MUST NOT rebuild league standings.
   * The immutable authority is the active official
   * Round Certification of the immediately previous
   * FantaGol Round.
   *
   * Ranking order, tie-breaks, zero-point members and
   * deterministic fallback therefore remain exactly
   * those already certified by StandingsPreviewBuilder.
   */
  const {
    data: basisLeagueRoundData,
    error: basisLeagueRoundError,
  } =
    await client
      .from("league_rounds")
      .select("id,league_id")
      .eq(
        "fantagol_round_id",
        basisRoundId,
      )
      .eq("enabled", true);

  if (basisLeagueRoundError) {
    throw new Error(
      `TOP3_BASIS_LEAGUE_ROUNDS_FAILED:${basisLeagueRoundError.message}`,
    );
  }

  const basisLeagueRounds =
    (basisLeagueRoundData ?? []) as
      LeagueRoundRow[];

  if (basisLeagueRounds.length === 0) {
    return;
  }

  /*
   * TOP3_MINIMUM_REAL_PARTICIPANTS
   *
   * A Top3 panel has semantic value only when
   * the league contains at least four real,
   * currently active participants.
   *
   * Active membership rows without user_id are
   * not eligible participants for the expert
   * signal and MUST NOT make a league eligible.
   */
  const basisLeagueIds =
    [...new Set(
      basisLeagueRounds.map(
        (row) => row.league_id,
      ),
    )];

  const {
    data: activeMemberData,
    error: activeMemberError,
  } =
    await client
      .from("league_members")
      .select(
        "id,league_id,user_id,status",
      )
      .in(
        "league_id",
        basisLeagueIds,
      )
      .eq("status", "active");

  if (activeMemberError) {
    throw new Error(
      `TOP3_ACTIVE_PARTICIPANTS_FAILED:${activeMemberError.message}`,
    );
  }

  const activeUserCountByLeague =
    new Map<string, number>();

  for (
    const row
    of activeMemberData ?? []
  ) {
    if (
      typeof row.league_id !==
        "string" ||
      typeof row.user_id !==
        "string"
    ) {
      continue;
    }

    activeUserCountByLeague.set(
      row.league_id,
      (
        activeUserCountByLeague.get(
          row.league_id,
        ) ?? 0
      ) + 1,
    );
  }

  const eligibleLeagueIds =
    new Set(
      basisLeagueIds.filter(
        (leagueId) =>
          (
            activeUserCountByLeague.get(
              leagueId,
            ) ?? 0
          ) >=
          TOP3_MIN_ACTIVE_USER_PARTICIPANTS,
      ),
    );

  if (eligibleLeagueIds.size === 0) {
    return;
  }

  const eligibleBasisLeagueRounds =
    basisLeagueRounds.filter(
      (row) =>
        eligibleLeagueIds.has(
          row.league_id,
        ),
    );

  const basisLeagueRoundIds =
    eligibleBasisLeagueRounds.map(
      (row) => row.id,
    );

  const {
    data: certificationData,
    error: certificationError,
  } =
    await client
      .from("round_certifications")
      .select(
        "id,league_round_id,standings_snapshot",
      )
      .in(
        "league_round_id",
        basisLeagueRoundIds,
      )
      .eq("status", "official")
      .eq("active", true);

  if (certificationError) {
    throw new Error(
      `TOP3_OFFICIAL_STANDINGS_FAILED:${certificationError.message}`,
    );
  }

  type OfficialCertificationRow = {
    id: string;
    league_round_id: string;
    standings_snapshot: unknown;
  };

  type OfficialRankingRow = {
    league_member_id?: unknown;
    projected_points?: unknown;
  };

  const certificationByLeagueRound =
    new Map(
      (
        (certificationData ?? []) as
          unknown as
          OfficialCertificationRow[]
      ).map(
        (row) => [
          row.league_round_id,
          row,
        ],
      ),
    );

  const candidateMemberIds =
    new Set<string>();

  const canonicalTop3ByLeague =
    new Map<
      string,
      Array<{
        memberId: string;
        points: number;
        rank: number;
      }>
    >();

  for (
    const leagueRound
    of eligibleBasisLeagueRounds
  ) {
    const certification =
      certificationByLeagueRound.get(
        leagueRound.id,
      );

    if (!certification) {
      continue;
    }

    const snapshot =
      certification.standings_snapshot;

    if (
      !snapshot ||
      typeof snapshot !== "object"
    ) {
      continue;
    }

    const modes =
      (
        snapshot as {
          modes?: unknown;
        }
      ).modes;

    if (
      !modes ||
      typeof modes !== "object"
    ) {
      continue;
    }

    const purePoints =
      (
        modes as {
          pure_points?: unknown;
        }
      ).pure_points;

    if (
      !purePoints ||
      typeof purePoints !== "object"
    ) {
      continue;
    }

    const ranking =
      (
        purePoints as {
          ranking?: unknown;
        }
      ).ranking;

    if (!Array.isArray(ranking)) {
      continue;
    }

    const canonicalTop3:
      Array<{
        memberId: string;
        points: number;
        rank: number;
      }> = [];

    for (
      let index = 0;
      index <
        Math.min(
          ranking.length,
          3,
        );
      index += 1
    ) {
      const row =
        ranking[index] as
          OfficialRankingRow;

      const memberId =
        typeof row
          ?.league_member_id ===
          "string"
          ? row.league_member_id
          : null;

      if (!memberId) {
        continue;
      }

      canonicalTop3.push({
        memberId,
        points:
          numberValue(
            row.projected_points,
          ),
        rank:
          index + 1,
      });

      candidateMemberIds.add(
        memberId,
      );
    }

    if (canonicalTop3.length > 0) {
      canonicalTop3ByLeague.set(
        leagueRound.league_id,
        canonicalTop3,
      );
    }
  }

  if (candidateMemberIds.size === 0) {
    return;
  }

  const {
    data: members,
    error: memberError,
  } =
    await client
      .from("league_members")
      .select(
        "id,league_id,user_id",
      )
      .in(
        "id",
        [...candidateMemberIds],
      );

  if (memberError) {
    throw new Error(
      `TOP3_MEMBERS_FAILED:${memberError.message}`,
    );
  }

  const memberById =
    new Map(
      (members ?? [])
        .filter(
          (row) =>
            typeof row.id ===
              "string" &&
            typeof row.user_id ===
              "string" &&
            typeof row.league_id ===
              "string",
        )
        .map(
          (row) => [
            row.id,
            row,
          ],
        ),
    );

  const insertRows: Array<{
    target_fantagol_round_id: string;
    basis_fantagol_round_id: string;
    league_id: string;
    league_member_id: string;
    user_id: string;
    rank: number;
    pure_points: number;
    rank_weight: number;
  }> = [];

  for (
    const [
      leagueId,
      canonicalTop3,
    ]
    of canonicalTop3ByLeague.entries()
  ) {
    for (
      const leader
      of canonicalTop3
    ) {
      const member =
        memberById.get(
          leader.memberId,
        );

      if (
        !member?.user_id ||
        member.league_id !==
          leagueId
      ) {
        continue;
      }

      insertRows.push({
        target_fantagol_round_id:
          targetRoundId,
        basis_fantagol_round_id:
          basisRoundId,
        league_id:
          leagueId,
        league_member_id:
          leader.memberId,
        user_id:
          member.user_id,
        rank:
          leader.rank,
        pure_points:
          leader.points,
        rank_weight:
          RANK_WEIGHT.get(
            leader.rank,
          ) ?? 0,
      });
    }
  }

  if (insertRows.length === 0) {
    return;
  }

  const { error: insertError } =
    await client
      .from(
        "community_top3_cohort_members",
      )
      .insert(insertRows);

  if (
    insertError &&
    !insertError.message
      .toLowerCase()
      .includes("duplicate")
  ) {
    throw new Error(
      `TOP3_COHORT_FREEZE_FAILED:${insertError.message}`,
    );
  }
}

async function
loadCohort(
  client: SupabaseClient,
  roundId: string,
): Promise<CohortRow[]> {
  const { data, error } =
    await client
      .from(
        "community_top3_cohort_members",
      )
      .select(
        [
          "league_id",
          "league_member_id",
          "user_id",
          "rank",
          "rank_weight",
        ].join(","),
      )
      .eq(
        "target_fantagol_round_id",
        roundId,
      )
      .order(
        "league_id",
        { ascending: true },
      )
      .order(
        "rank",
        { ascending: true },
      );

  if (error) {
    throw new Error(
      `TOP3_COHORT_READ_FAILED:${error.message}`,
    );
  }

  return (
    (data ?? []) as unknown as
      CohortRow[]
  );
}

function buildFeatureMap(
  cohort: CohortRow[],
  currentLeagueRounds:
    LeagueRoundRow[],
  predictions:
    PredictionRow[],
): Map<
  string,
  Top3ExpertFeatureV1
> {
  const currentRoundByLeague =
    new Map(
      currentLeagueRounds.map(
        (row) => [
          row.league_id,
          row.id,
        ],
      ),
    );

  const latest =
    new Map<
      string,
      PredictionRow
    >();

  for (const prediction of predictions) {
    const key = [
      prediction.league_round_id,
      prediction.league_member_id,
      prediction.match_id,
    ].join(":");

    latest.set(
      key,
      latestPrediction(
        latest.get(key),
        prediction,
      ),
    );
  }

  const leagueCount =
    new Set(
      cohort.map(
        (row) => row.league_id,
      ),
    ).size;

  const byMatch =
    new Map<
      string,
      {
        availableWeight: number;
        availablePredictionCount:
          number;
        homeWeight: number;
        drawWeight: number;
        awayWeight: number;
        exact: Map<
          string,
          {
            homeGoals: number;
            awayGoals: number;
            weight: number;
          }
        >;
      }
    >();

  for (const member of cohort) {
    const leagueRoundId =
      currentRoundByLeague.get(
        member.league_id,
      );

    if (!leagueRoundId) {
      continue;
    }

    const candidatePrefix = [
      leagueRoundId,
      member.league_member_id,
    ].join(":");

    for (
      const [key, prediction]
      of latest.entries()
    ) {
      if (
        !key.startsWith(
          `${candidatePrefix}:`,
        )
      ) {
        continue;
      }

      const weight =
        numberValue(
          member.rank_weight,
        );

      const state =
        byMatch.get(
          prediction.match_id,
        ) ?? {
          availableWeight: 0,
          availablePredictionCount:
            0,
          homeWeight: 0,
          drawWeight: 0,
          awayWeight: 0,
          exact: new Map(),
        };

      state.availableWeight +=
        weight;

      state.availablePredictionCount +=
        1;

      if (
        prediction.home_prediction >
        prediction.away_prediction
      ) {
        state.homeWeight += weight;
      } else if (
        prediction.home_prediction ===
        prediction.away_prediction
      ) {
        state.drawWeight += weight;
      } else {
        state.awayWeight += weight;
      }

      const score = [
        prediction.home_prediction,
        prediction.away_prediction,
      ].join("-");

      const current =
        state.exact.get(score);

      if (current) {
        current.weight += weight;
      } else {
        state.exact.set(
          score,
          {
            homeGoals:
              prediction.home_prediction,
            awayGoals:
              prediction.away_prediction,
            weight,
          },
        );
      }

      byMatch.set(
        prediction.match_id,
        state,
      );
    }
  }

  const result =
    new Map<
      string,
      Top3ExpertFeatureV1
    >();

  const maximumCommunityWeight =
    Math.max(
      1,
      leagueCount,
    );

  for (
    const [matchId, state]
    of byMatch.entries()
  ) {
    if (
      state.availableWeight <= 0
    ) {
      continue;
    }

    result.set(
      matchId,
      {
        featureVersion:
          TOP3_EXPERT_FEATURE_VERSION,

        leagueCount,

        cohortMemberCount:
          cohort.length,

        availablePredictionCount:
          state
            .availablePredictionCount,

        coverageWeight:
          round6(
            state.availableWeight /
            maximumCommunityWeight,
          ),

        sign: {
          home:
            round6(
              state.homeWeight /
              state.availableWeight,
            ),
          draw:
            round6(
              state.drawWeight /
              state.availableWeight,
            ),
          away:
            round6(
              state.awayWeight /
              state.availableWeight,
            ),
        },

        exact:
          [...state.exact.entries()]
            .map(
              ([score, item]) => ({
                score,
                homeGoals:
                  item.homeGoals,
                awayGoals:
                  item.awayGoals,
                probability:
                  round6(
                    item.weight /
                    state.availableWeight,
                  ),
              }),
            )
            .sort(
              (a, b) =>
                b.probability -
                a.probability,
            ),
      },
    );
  }

  return result;
}

async function currentLeagueRounds(
  client: SupabaseClient,
  roundId: string,
): Promise<LeagueRoundRow[]> {
  const { data, error } =
    await client
      .from("league_rounds")
      .select("id,league_id")
      .eq(
        "fantagol_round_id",
        roundId,
      )
      .eq("enabled", true);

  if (error) {
    throw new Error(
      `TOP3_CURRENT_LEAGUE_ROUNDS_FAILED:${error.message}`,
    );
  }

  return (data ?? []) as
    LeagueRoundRow[];
}

async function currentPredictions(
  client: SupabaseClient,
  cohort: CohortRow[],
  leagueRounds:
    LeagueRoundRow[],
): Promise<PredictionRow[]> {
  if (
    cohort.length === 0 ||
    leagueRounds.length === 0
  ) {
    return [];
  }

  const memberIds =
    [...new Set(
      cohort.map(
        (row) =>
          row.league_member_id,
      ),
    )];

  const roundIds =
    leagueRounds.map(
      (row) => row.id,
    );

  const { data, error } =
    await client
      .from("predictions")
      .select(
        [
          "league_round_id",
          "league_member_id",
          "user_id",
          "match_id",
          "home_prediction",
          "away_prediction",
          "official_submitted_at",
          "submitted_version",
        ].join(","),
      )
      .in(
        "league_round_id",
        roundIds,
      )
      .in(
        "league_member_id",
        memberIds,
      )
      .eq("status", "submitted")
      .not(
        "submitted_version",
        "is",
        null,
      )
      .not(
        "official_submitted_at",
        "is",
        null,
      );

  if (error) {
    throw new Error(
      `TOP3_CURRENT_PREDICTIONS_FAILED:${error.message}`,
    );
  }

  const rows =
    (data ?? []) as unknown as
      PredictionRow[];

  return rows.filter(
    (row) =>
      typeof row.user_id ===
        "string" &&
      typeof row.match_id ===
        "string" &&
      Number.isInteger(
        row.home_prediction,
      ) &&
      Number.isInteger(
        row.away_prediction,
      ) &&
      typeof
        row.official_submitted_at ===
        "string" &&
      Number.isInteger(
        row.submitted_version,
      ),
  );
}

export async function
isCommunityTop3RefreshOpen(
  client: SupabaseClient,
  roundId: string,
  capturedAt: string,
): Promise<boolean> {
  const capturedAtMs =
    Date.parse(capturedAt);

  if (!Number.isFinite(capturedAtMs)) {
    throw new Error(
      "TOP3_REFRESH_CAPTURED_AT_INVALID",
    );
  }

  const { data, error } =
    await client
      .from("fantagol_rounds")
      .select("starts_at")
      .eq("id", roundId)
      .maybeSingle();

  if (error) {
    throw new Error(
      `TOP3_REFRESH_ROUND_TIMING_FAILED:${error.message}`,
    );
  }

  if (
    !data ||
    typeof data.starts_at !==
      "string"
  ) {
    throw new Error(
      "TOP3_REFRESH_ROUND_TIMING_MISSING",
    );
  }

  const kickoffMs =
    Date.parse(data.starts_at);

  if (!Number.isFinite(kickoffMs)) {
    throw new Error(
      "TOP3_REFRESH_KICKOFF_INVALID",
    );
  }

  /*
   * Strict lifecycle boundary:
   *
   * capturedAt < starts_at  -> refresh allowed
   * capturedAt >= starts_at -> frozen
   *
   * At kickoff the Top3 signal becomes immutable
   * for the whole target FantaGol round.
   */
  return capturedAtMs < kickoffMs;
}

export async function
refreshCommunityTop3ExpertSnapshot(
  client: SupabaseClient,
  roundId: string,
  capturedAt: string,
  source:
    | "PACKAGE"
    | "ADVANCED_FALLBACK",
): Promise<
  Map<string, Top3ExpertFeatureV1>
> {
  const refreshOpen =
    await isCommunityTop3RefreshOpen(
      client,
      roundId,
      capturedAt,
    );

  if (!refreshOpen) {
    return loadLatestCommunityTop3ExpertSnapshot(
      client,
      roundId,
    );
  }

  await ensureFrozenCommunityTop3Cohort(
    client,
    roundId,
  );

  const cohort =
    await loadCohort(
      client,
      roundId,
    );

  const leagueRounds =
    await currentLeagueRounds(
      client,
      roundId,
    );

  const predictions =
    await currentPredictions(
      client,
      cohort,
      leagueRounds,
    );

  const features =
    buildFeatureMap(
      cohort,
      leagueRounds,
      predictions,
    );

  const {
    data: last,
    error: lastError,
  } =
    await client
      .from(
        "community_top3_expert_snapshots",
      )
      .select("snapshot_version")
      .eq(
        "fantagol_round_id",
        roundId,
      )
      .order(
        "snapshot_version",
        { ascending: false },
      )
      .limit(1);

  if (lastError) {
    throw new Error(
      `TOP3_SNAPSHOT_VERSION_FAILED:${lastError.message}`,
    );
  }

  const version =
    (
      last?.[0]
        ?.snapshot_version ??
      0
    ) + 1;

  const leagueCount =
    new Set(
      cohort.map(
        (row) => row.league_id,
      ),
    ).size;

  const payload =
    Object.fromEntries(
      [...features.entries()],
    );

  const { error: insertError } =
    await client
      .from(
        "community_top3_expert_snapshots",
      )
      .insert({
        fantagol_round_id:
          roundId,
        snapshot_version:
          version,
        captured_at:
          capturedAt,
        snapshot_source:
          source,
        league_count:
          leagueCount,
        cohort_member_count:
          cohort.length,
        available_prediction_count:
          predictions.length,
        feature_version:
          TOP3_EXPERT_FEATURE_VERSION,
        payload,
      });

  if (insertError) {
    throw new Error(
      `TOP3_SNAPSHOT_INSERT_FAILED:${insertError.message}`,
    );
  }

  return features;
}

export async function
loadLatestCommunityTop3ExpertSnapshot(
  client: SupabaseClient,
  roundId: string,
): Promise<
  Map<string, Top3ExpertFeatureV1>
> {
  const { data, error } =
    await client
      .from(
        "community_top3_expert_snapshots",
      )
      .select("payload")
      .eq(
        "fantagol_round_id",
        roundId,
      )
      .order(
        "snapshot_version",
        { ascending: false },
      )
      .limit(1);

  if (error) {
    throw new Error(
      `TOP3_LATEST_SNAPSHOT_FAILED:${error.message}`,
    );
  }

  const payload =
    data?.[0]?.payload;

  if (
    !payload ||
    typeof payload !== "object" ||
    Array.isArray(payload)
  ) {
    return new Map();
  }

  return new Map(
    Object.entries(payload).map(
      ([matchId, feature]) => [
        matchId,
        feature as
          Top3ExpertFeatureV1,
      ],
    ),
  );
}

function topGapUncertainty(
  sign: {
    home: number;
    draw: number;
    away: number;
  },
): number {
  const ordered = [
    sign.home,
    sign.draw,
    sign.away,
  ].sort(
    (a, b) => b - a,
  );

  return clamp01(
    1 -
    (
      ordered[0] -
      ordered[1]
    ) /
      0.5,
  );
}

function expertAgreement(
  feature:
    Top3ExpertFeatureV1,
): number {
  const top =
    Math.max(
      feature.sign.home,
      feature.sign.draw,
      feature.sign.away,
    );

  return clamp01(
    (
      top -
      1 / 3
    ) /
      (
        2 / 3
      ),
  );
}

export function
applyTop3ExpertFeatureV1(
  base: BmInterpolatedResult,
  feature:
    Top3ExpertFeatureV1 | null,
): {
  result:
    BmInterpolatedRuntimeResult;
  appliedWeight: number;
} {
  if (!feature) {
    return {
      result: {
        ...base,
        algorithmVersion:
          BM_INTERPOLATED_V2,
      },
      appliedWeight: 0,
    };
  }

  const appliedWeight =
    round6(
      MAX_TOP3_WEIGHT *
        clamp01(
          feature.coverageWeight,
        ) *
        (
          0.25 +
          expertAgreement(feature) *
            0.75
        ) *
        (
          0.35 +
          topGapUncertainty(
            base.sign,
          ) *
            0.65
        ),
    );

  const expertByScore =
    new Map(
      feature.exact.map(
        (item) => [
          item.score,
          item.probability,
        ],
      ),
    );

  const supportedMass =
    base.scoreMatrix.reduce(
      (sum, cell) =>
        sum +
        (
          expertByScore.get(
            `${cell.homeGoals}-${cell.awayGoals}`,
          ) ?? 0
        ),
      0,
    );

  if (
    appliedWeight <= 0 ||
    supportedMass <= 0
  ) {
    return {
      result: {
        ...base,
        algorithmVersion:
          BM_INTERPOLATED_V2,
      },
      appliedWeight: 0,
    };
  }

  const raw =
    base.scoreMatrix.map(
      (cell) => {
        const expert =
          (
            expertByScore.get(
              `${cell.homeGoals}-${cell.awayGoals}`,
            ) ?? 0
          ) /
          supportedMass;

        return {
          ...cell,
          probability:
            cell.probability *
              (
                1 -
                appliedWeight
              ) +
            expert *
              appliedWeight,
        };
      },
    );

  const total =
    raw.reduce(
      (sum, cell) =>
        sum + cell.probability,
      0,
    );

  const matrix =
    raw.map(
      (cell) => ({
        ...cell,
        probability:
          cell.probability /
          total,
      }),
    );

  let home = 0;
  let draw = 0;
  let away = 0;
  let over = 0;
  let under = 0;
  let goal = 0;
  let noGoal = 0;
  let lambdaHome = 0;
  let lambdaAway = 0;

  for (const cell of matrix) {
    if (
      cell.homeGoals >
      cell.awayGoals
    ) home += cell.probability;
    else if (
      cell.homeGoals ===
      cell.awayGoals
    ) draw += cell.probability;
    else away += cell.probability;

    if (
      cell.homeGoals +
        cell.awayGoals >
      2.5
    ) over += cell.probability;
    else under += cell.probability;

    if (
      cell.homeGoals > 0 &&
      cell.awayGoals > 0
    ) goal += cell.probability;
    else noGoal += cell.probability;

    lambdaHome +=
      cell.homeGoals *
      cell.probability;

    lambdaAway +=
      cell.awayGoals *
      cell.probability;
  }

  const exact =
    matrix
      .map(
        (cell) => ({
          score:
            `${cell.homeGoals}-${cell.awayGoals}`,
          homeGoals:
            cell.homeGoals,
          awayGoals:
            cell.awayGoals,
          probability:
            cell.probability,
        }),
      )
      .sort(
        (a, b) =>
          b.probability -
          a.probability,
      );

  return {
    result: {
      ...base,
      algorithmVersion:
        BM_INTERPOLATED_V2,
      scoreMatrix: matrix,
      exact,
      sign: {
        home: round6(home),
        draw: round6(draw),
        away: round6(away),
      },
      totals: {
        line: 2.5,
        over: round6(over),
        under: round6(under),
      },
      btts: {
        goal: round6(goal),
        noGoal:
          round6(noGoal),
      },
      lambdaHome,
      lambdaAway,
    },
    appliedWeight,
  };
}