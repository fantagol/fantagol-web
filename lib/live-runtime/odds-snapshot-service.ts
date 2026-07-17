import type { SupabaseClient } from "@supabase/supabase-js";

import { callRuntimeRpc, requireSingleRpcRow } from "./rpc-utils";
import type { CanonicalOddsSnapshot } from "./odds-snapshot";

type CreateOddsSnapshotRpcRow = {
  odds_market_snapshot_id: string;
  match_id: string;
  provider_id: string;
  collected_at: string;
  snapshot_hash: string;
  inserted: boolean;
};

type FreezeOddsSnapshotRpcRow = {
  official_match_odds_snapshot_id: string;
  match_id: string;
  odds_market_snapshot_id: string;
  source_collected_at: string;
  official_hash: string;
  already_frozen: boolean;
};

export async function persistCanonicalOddsSnapshot(
  client: SupabaseClient,
  input: {
    matchId: string;
    providerPayload: unknown;
    snapshot: CanonicalOddsSnapshot;
  },
) {
  const functionName = "create_odds_market_snapshot_rpc";
  const rows = await callRuntimeRpc<CreateOddsSnapshotRpcRow>(
    client,
    functionName,
    {
      p_match_id: input.matchId,
      p_provider_code: input.snapshot.providerCode,
      p_external_match_id: input.snapshot.externalMatchId,
      p_collected_at: input.snapshot.collectedAt,
      p_provider_payload: input.providerPayload,
      p_canonical_payload: input.snapshot,
      p_consensus_payload: input.snapshot.consensus,
      p_quality_payload: input.snapshot.quality,
      p_snapshot_schema_version: 1,
    },
  );

  const row = requireSingleRpcRow(rows, functionName);

  return {
    oddsMarketSnapshotId: row.odds_market_snapshot_id,
    matchId: row.match_id,
    providerId: row.provider_id,
    collectedAt: row.collected_at,
    snapshotHash: row.snapshot_hash,
    inserted: row.inserted,
  };
}

export async function freezeOfficialMatchOddsSnapshot(
  client: SupabaseClient,
  input: {
    matchId: string;
    freezeAt?: string;
    freezeReason?: string;
    policyVersion?: string;
  },
) {
  const functionName = "freeze_match_odds_snapshot_rpc";
  const rows = await callRuntimeRpc<FreezeOddsSnapshotRpcRow>(
    client,
    functionName,
    {
      p_match_id: input.matchId,
      p_freeze_at: input.freezeAt ?? new Date().toISOString(),
      p_freeze_reason: input.freezeReason ?? "round_lock",
      p_policy_version:
        input.policyVersion ?? "official_match_odds_v1",
    },
  );

  const row = requireSingleRpcRow(rows, functionName);

  return {
    officialMatchOddsSnapshotId:
      row.official_match_odds_snapshot_id,
    matchId: row.match_id,
    oddsMarketSnapshotId: row.odds_market_snapshot_id,
    sourceCollectedAt: row.source_collected_at,
    officialHash: row.official_hash,
    alreadyFrozen: row.already_frozen,
  };
}
