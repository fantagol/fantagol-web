import type {
  SupabaseClient,
} from "@supabase/supabase-js";

const SURPRISE_REFERENCE_POLICY_VERSION =
  "surprise_reference_v1";

type RoundRow = {
  id: string;
  active: boolean;
  status: string;
  opens_at: string | null;
};

type RoundMatchRow = {
  match_id: string;
  required: boolean;
  removed_at: string | null;
};

type ExistingReferenceMatchRow = {
  match_id: string;
};

type OddsSnapshotRow = {
  id: string;
  match_id: string;
  collected_at: string;
  consensus_payload: unknown;
  quality_payload:
    | Record<string, unknown>
    | null;
};

type MarketPackageSnapshotRow = {
  id: string;
  fantagol_round_id: string;
  status: string;
  captured_at: string | null;
  snapshot_source: string | null;
  required_match_count: number;
  captured_match_count: number;
};

type MarketPackageMatchRow = {
  market_intelligence_snapshot_id: string;
  match_id: string;
  odds_market_snapshot_id: string;
  slot_number: number;
};

type SurpriseReferenceStatusRow = {
  fantagol_round_id: string;
  status: string;
  reference_at: string;
  required_match_count: number;
  captured_match_count: number;
  reference_hash: string | null;
  ready_at: string | null;
  ready: boolean;
};

export type SurpriseReferenceActivationResult = {
  attempted: boolean;
  ready: boolean;
  status:
    | "not_started"
    | "building"
    | "ready";
  referenceAt: string | null;
  requiredMatchCount: number;
  capturedMatchCount: number;
  insertedMatchCount: number;
  missingMatchIds: string[];
  reason: string;
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
    throw new Error(
      `${label}_INVALID:${value}`,
    );
  }

  return new Date(parsed).toISOString();
}

async function loadStatus(
  client: SupabaseClient,
  fantagolRoundId: string,
): Promise<SurpriseReferenceStatusRow | null> {
  const { data, error } =
    await client.rpc(
      "get_surprise_reference_status_internal",
      {
        p_fantagol_round_id:
          fantagolRoundId,
      },
    );

  if (error) {
    throw new Error(
      `SURPRISE_REFERENCE_STATUS_LOAD_FAILED:${error.message}`,
    );
  }

  if (!data) {
    return null;
  }

  if (Array.isArray(data)) {
    return (
      (data[0] as
        | SurpriseReferenceStatusRow
        | undefined) ??
      null
    );
  }

  return data as
    SurpriseReferenceStatusRow;
}

async function loadRound(
  client: SupabaseClient,
  fantagolRoundId: string,
): Promise<RoundRow> {
  const { data, error } =
    await client
      .from("fantagol_rounds")
      .select(
        "id,active,status,opens_at",
      )
      .eq("id", fantagolRoundId)
      .limit(1)
      .maybeSingle();

  if (error) {
    throw new Error(
      `SURPRISE_REFERENCE_ROUND_LOAD_FAILED:${error.message}`,
    );
  }

  if (!data) {
    throw new Error(
      "SURPRISE_REFERENCE_ROUND_NOT_FOUND",
    );
  }

  return data as RoundRow;
}

async function loadRequiredMatchIds(
  client: SupabaseClient,
  fantagolRoundId: string,
): Promise<string[]> {
  const { data, error } =
    await client
      .from("fantagol_round_matches")
      .select(
        "match_id,required,removed_at",
      )
      .eq(
        "fantagol_round_id",
        fantagolRoundId,
      )
      .eq("required", true)
      .is("removed_at", null);

  if (error) {
    throw new Error(
      `SURPRISE_REFERENCE_MATCH_SET_LOAD_FAILED:${error.message}`,
    );
  }

  return (
    (data ?? []) as RoundMatchRow[]
  )
    .map((row) => row.match_id)
    .sort();
}

async function loadExistingMatchIds(
  client: SupabaseClient,
  fantagolRoundId: string,
): Promise<Set<string>> {
  const { data, error } =
    await client
      .from("surprise_reference_matches")
      .select("match_id")
      .eq(
        "fantagol_round_id",
        fantagolRoundId,
      );

  if (error) {
    throw new Error(
      `SURPRISE_REFERENCE_EXISTING_MATCHES_LOAD_FAILED:${error.message}`,
    );
  }

  return new Set(
    (
      (data ?? []) as
        ExistingReferenceMatchRow[]
    ).map((row) => row.match_id),
  );
}

async function loadFirstCompleteCanonicalPackage(input: {
  client: SupabaseClient;
  fantagolRoundId: string;
  opensAt: string;
  requiredMatchIds: string[];
}): Promise<{
  referenceAt: string;
  snapshots: Map<string, OddsSnapshotRow>;
} | null> {
  const requiredMatchIds =
    [...new Set(input.requiredMatchIds)].sort();

  if (requiredMatchIds.length === 0) {
    return null;
  }

  /*
   * Canonical PACKAGE authority.
   *
   * We select the first READY PACKAGE captured at or after
   * opens_at, then follow its child rows to the exact persisted
   * odds_market_snapshot_id values.
   *
   * No independent per-match timestamp reconstruction is allowed.
   */
  const { data: packageRows, error: packageError } =
    await input.client
      .from("market_intelligence_snapshots")
      .select(
        [
          "id",
          "fantagol_round_id",
          "status",
          "captured_at",
          "snapshot_source",
          "required_match_count",
          "captured_match_count",
          "snapshot_version",
        ].join(","),
      )
      .eq(
        "fantagol_round_id",
        input.fantagolRoundId,
      )
      .eq("snapshot_source", "PACKAGE")
      .eq("status", "ready")
      .gte("captured_at", input.opensAt)
      .eq(
        "required_match_count",
        requiredMatchIds.length,
      )
      .eq(
        "captured_match_count",
        requiredMatchIds.length,
      )
      .order("captured_at", {
        ascending: true,
      })
      .order("snapshot_version", {
        ascending: true,
      })
      .limit(10);

  if (packageError) {
    throw new Error(
      `SURPRISE_PACKAGE_LOOKUP_FAILED:${packageError.message}`,
    );
  }

  const packages =
    (packageRows ?? []) as unknown as MarketPackageSnapshotRow[];

  for (const packageRow of packages) {
    if (!packageRow.captured_at) {
      continue;
    }

    const {
      data: matchRows,
      error: matchRowsError,
    } = await input.client
      .from(
        "market_intelligence_match_snapshots",
      )
      .select(
        [
          "market_intelligence_snapshot_id",
          "match_id",
          "odds_market_snapshot_id",
          "slot_number",
        ].join(","),
      )
      .eq(
        "market_intelligence_snapshot_id",
        packageRow.id,
      )
      .order("slot_number", {
        ascending: true,
      });

    if (matchRowsError) {
      throw new Error(
        `SURPRISE_PACKAGE_MATCH_LOOKUP_FAILED:${matchRowsError.message}`,
      );
    }

    const packageMatches =
      (matchRows ?? []) as unknown as MarketPackageMatchRow[];

    if (
      packageMatches.length !==
      requiredMatchIds.length
    ) {
      continue;
    }

    const packageMatchIds =
      [...new Set(
        packageMatches.map(
          (row) => row.match_id,
        ),
      )].sort();

    if (
      packageMatchIds.length !==
        requiredMatchIds.length ||
      packageMatchIds.some(
        (matchId, index) =>
          matchId !== requiredMatchIds[index],
      )
    ) {
      continue;
    }

    const oddsSnapshotIds =
      packageMatches.map(
        (row) => row.odds_market_snapshot_id,
      );

    if (
      new Set(oddsSnapshotIds).size !==
      requiredMatchIds.length
    ) {
      continue;
    }

    const {
      data: oddsRows,
      error: oddsError,
    } = await input.client
      .from("odds_market_snapshots")
      .select(
        [
          "id",
          "match_id",
          "collected_at",
          "consensus_payload",
          "quality_payload",
          "market_code",
        ].join(","),
      )
      .in("id", oddsSnapshotIds)
      .eq("market_code", "h2h");

    if (oddsError) {
      throw new Error(
        `SURPRISE_PACKAGE_ODDS_LOOKUP_FAILED:${oddsError.message}`,
      );
    }

    const rawOddsRows =
      (oddsRows ?? []) as unknown as Array<
        OddsSnapshotRow & {
          market_code: string;
        }
      >;

    if (
      rawOddsRows.length !==
      requiredMatchIds.length
    ) {
      continue;
    }

    const oddsById =
      new Map(
        rawOddsRows.map(
          (row) => [row.id, row],
        ),
      );

    const snapshots =
      new Map<string, OddsSnapshotRow>();

    let valid = true;

    for (const packageMatch of packageMatches) {
      const row = oddsById.get(
        packageMatch.odds_market_snapshot_id,
      );

      if (
        !row ||
        row.match_id !== packageMatch.match_id ||
        !row.consensus_payload ||
        row.quality_payload?.hasConsensus !== true
      ) {
        valid = false;
        break;
      }

      snapshots.set(
        packageMatch.match_id,
        row,
      );
    }

    if (
      !valid ||
      snapshots.size !== requiredMatchIds.length
    ) {
      continue;
    }

    return {
      referenceAt: packageRow.captured_at,
      snapshots,
    };
  }

  return null;
}
export async function materializeSurpriseReferenceFromPersistedOdds(
  client: SupabaseClient,
  input: {
    fantagolRoundId: string;
    runtimeSource?: string;
  },
): Promise<SurpriseReferenceActivationResult> {
  const existingStatus =
    await loadStatus(
      client,
      input.fantagolRoundId,
    );

  if (existingStatus?.ready) {
    return {
      attempted: false,
      ready: true,
      status: "ready",
      referenceAt:
        existingStatus.reference_at,
      requiredMatchCount:
        existingStatus
          .required_match_count,
      capturedMatchCount:
        existingStatus
          .captured_match_count,
      insertedMatchCount: 0,
      missingMatchIds: [],
      reason:
        "surprise_reference_already_ready",
    };
  }

  const round =
    await loadRound(
      client,
      input.fantagolRoundId,
    );

  if (
    !round.active ||
    round.status === "cancelled"
  ) {
    return {
      attempted: false,
      ready: false,
      status: "not_started",
      referenceAt: null,
      requiredMatchCount: 0,
      capturedMatchCount: 0,
      insertedMatchCount: 0,
      missingMatchIds: [],
      reason:
        "surprise_reference_round_not_eligible",
    };
  }
  const opensAt =
    requireIso(
      round.opens_at,
      "SURPRISE_REFERENCE_OPENS_AT",
    );

  const requiredMatchIds =
    await loadRequiredMatchIds(
      client,
      input.fantagolRoundId,
    );

  if (
    requiredMatchIds.length === 0
  ) {
    throw new Error(
      "SURPRISE_REFERENCE_REQUIRED_MATCH_SET_EMPTY",
    );
  }

  const canonicalPackage =
    await loadFirstCompleteCanonicalPackage({
      client,
      fantagolRoundId:
        input.fantagolRoundId,
      opensAt,
      requiredMatchIds,
    });

  if (!canonicalPackage) {
    return {
      attempted: true,
      ready: false,
      status: "not_started",
      referenceAt: null,
      requiredMatchCount:
        requiredMatchIds.length,
      capturedMatchCount: 0,
      insertedMatchCount: 0,
      missingMatchIds:
        requiredMatchIds,
      reason:
        "surprise_reference_waiting_for_first_complete_package",
    };
  }

  const referenceAt =
    canonicalPackage.referenceAt;

  const eligibleSnapshots =
    canonicalPackage.snapshots;
  const { error: beginError } =
    await client.rpc(
      "begin_surprise_reference_round_internal",
      {
        p_fantagol_round_id:
          input.fantagolRoundId,
        p_reference_at:
          referenceAt,
        p_policy_version:
          SURPRISE_REFERENCE_POLICY_VERSION,
        p_metadata: {
          runtime:
            "surprise-reference-runtime-r7",
          source:
            input.runtimeSource ??
            "PACKAGE",
        },
      },
    );

  if (beginError) {
    throw new Error(
      `SURPRISE_REFERENCE_BEGIN_FAILED:${beginError.message}`,
    );
  }

  const existingMatchIds =
    await loadExistingMatchIds(
      client,
      input.fantagolRoundId,
    );

  const missingBeforeAttach =
    requiredMatchIds.filter(
      (matchId) =>
        !existingMatchIds.has(matchId),
    );


  let insertedMatchCount = 0;

  for (
    const matchId of
      missingBeforeAttach
  ) {
    const snapshot =
      eligibleSnapshots.get(matchId);

    if (!snapshot) {
      continue;
    }

    const { data, error } =
      await client.rpc(
        "attach_surprise_reference_match_internal",
        {
          p_fantagol_round_id:
            input.fantagolRoundId,
          p_match_id:
            matchId,
          p_odds_market_snapshot_id:
            snapshot.id,
          p_metadata: {
            runtime:
              "surprise-reference-runtime-r7",
            source:
              input.runtimeSource ??
              "PACKAGE",
          },
        },
      );

    if (error) {
      throw new Error(
        `SURPRISE_REFERENCE_ATTACH_FAILED:${matchId}:${error.message}`,
      );
    }

    const first =
      Array.isArray(data)
        ? data[0]
        : data;

    if (
      first &&
      typeof first === "object" &&
      "inserted" in first &&
      first.inserted === true
    ) {
      insertedMatchCount += 1;
    }
  }

  const statusAfterAttach =
    await loadStatus(
      client,
      input.fantagolRoundId,
    );

  if (!statusAfterAttach) {
    throw new Error(
      "SURPRISE_REFERENCE_STATUS_MISSING_AFTER_BEGIN",
    );
  }

  if (
    statusAfterAttach
      .captured_match_count <
    statusAfterAttach
      .required_match_count
  ) {
    const captured =
      await loadExistingMatchIds(
        client,
        input.fantagolRoundId,
      );

    return {
      attempted: true,
      ready: false,
      status: "building",
      referenceAt,
      requiredMatchCount:
        statusAfterAttach
          .required_match_count,
      capturedMatchCount:
        statusAfterAttach
          .captured_match_count,
      insertedMatchCount,
      missingMatchIds:
        requiredMatchIds.filter(
          (matchId) =>
            !captured.has(matchId),
        ),
      reason:
        "surprise_reference_waiting_for_complete_h2h_coverage",
    };
  }

  const { error: finalizeError } =
    await client.rpc(
      "finalize_surprise_reference_round_internal",
      {
        p_fantagol_round_id:
          input.fantagolRoundId,
      },
    );

  if (finalizeError) {
    throw new Error(
      `SURPRISE_REFERENCE_FINALIZE_FAILED:${finalizeError.message}`,
    );
  }

  const finalStatus =
    await loadStatus(
      client,
      input.fantagolRoundId,
    );

  if (!finalStatus?.ready) {
    throw new Error(
      "SURPRISE_REFERENCE_FINALIZE_DID_NOT_REACH_READY",
    );
  }

  return {
    attempted: true,
    ready: true,
    status: "ready",
    referenceAt:
      finalStatus.reference_at,
    requiredMatchCount:
      finalStatus.required_match_count,
    capturedMatchCount:
      finalStatus.captured_match_count,
    insertedMatchCount,
    missingMatchIds: [],
    reason:
      "surprise_reference_ready",
  };
}

export async function loadSurpriseReferenceReady(
  client: SupabaseClient,
  fantagolRoundId: string,
): Promise<boolean> {
  const { data, error } =
    await client.rpc(
      "surprise_reference_ready_internal",
      {
        p_fantagol_round_id:
          fantagolRoundId,
      },
    );

  if (error) {
    throw new Error(
      `SURPRISE_REFERENCE_READY_LOAD_FAILED:${error.message}`,
    );
  }

  return data === true;
}