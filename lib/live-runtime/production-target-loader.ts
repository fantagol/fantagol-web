import type { SupabaseClient } from "@supabase/supabase-js";

import type { MarketRoundPollingTarget } from "./market-round-scheduler";
import type { LivePollingTarget } from "./scheduler";

export type ProductionProviderCode =
  | "football_data"
  | "the_odds_api";

export type ProductionRoundContext = {
  fantagolRoundId: string;
  status: string;
  opensAt: string | null;
  lockAt: string | null;
  startsAt: string | null;
  endsAt: string | null;
};

type CurrentRoundRow = {
  round_id: string;
  status: string;
  opens_at: string | null;
  lock_at: string | null;
  starts_at: string | null;
  ends_at: string | null;
};

type RoundMatchRow = {
  match_id: string;
  slot_number: number;
  required: boolean;
  removed_at: string | null;
};

type MatchRow = {
  id: string;
  kickoff: string;
  status: string;
};

type ProviderRow = {
  id: string;
  code: string;
  active: boolean;
};

type ProviderMapRow = {
  internal_id: string;
  external_id: string;
};

type LeagueRoundRow = {
  id: string;
};

function requireRows<T>(
  data: T[] | null,
  error: { message?: string } | null,
  label: string,
): T[] {
  if (error) {
    throw new Error(
      `${label}: ${error.message ?? "unknown Supabase error"}`,
    );
  }

  return data ?? [];
}

function requireSingle<T>(
  data: T | null,
  error: { message?: string } | null,
  label: string,
): T {
  if (error) {
    throw new Error(
      `${label}: ${error.message ?? "unknown Supabase error"}`,
    );
  }

  if (!data) {
    throw new Error(`${label}: row not found`);
  }

  return data;
}

export async function resolveProductionRoundContext(
  client: SupabaseClient,
): Promise<ProductionRoundContext> {
  const { data, error } = await client
    .from("current_fantagol_round_view")
    .select(
      "round_id,status,opens_at,lock_at,starts_at,ends_at",
    )
    .limit(1)
    .maybeSingle();

  const row = requireSingle(
    data as CurrentRoundRow | null,
    error,
    "PRODUCTION_CURRENT_ROUND_LOAD_FAILED",
  );

  return {
    fantagolRoundId: row.round_id,
    status: row.status,
    opensAt: row.opens_at,
    lockAt: row.lock_at,
    startsAt: row.starts_at,
    endsAt: row.ends_at,
  };
}

async function loadEnabledLeagueRoundIds(
  client: SupabaseClient,
  fantagolRoundId: string,
): Promise<string[]> {
  const { data, error } = await client
    .from("league_rounds")
    .select("id")
    .eq("fantagol_round_id", fantagolRoundId)
    .eq("enabled", true);

  return requireRows(
    data as LeagueRoundRow[] | null,
    error,
    "PRODUCTION_LEAGUE_ROUNDS_LOAD_FAILED",
  ).map((row) => row.id);
}

async function loadRequiredRoundMatches(
  client: SupabaseClient,
  fantagolRoundId: string,
): Promise<RoundMatchRow[]> {
  const { data, error } = await client
    .from("fantagol_round_matches")
    .select("match_id,slot_number,required,removed_at")
    .eq("fantagol_round_id", fantagolRoundId)
    .eq("required", true)
    .is("removed_at", null)
    .order("slot_number", { ascending: true });

  const rows = requireRows(
    data as RoundMatchRow[] | null,
    error,
    "PRODUCTION_ROUND_MATCHES_LOAD_FAILED",
  );

  if (rows.length === 0) {
    throw new Error("PRODUCTION_ROUND_MATCH_SET_EMPTY");
  }

  return rows;
}

async function loadCanonicalMatches(
  client: SupabaseClient,
  matchIds: string[],
): Promise<Map<string, MatchRow>> {
  const { data, error } = await client
    .from("matches")
    .select("id,kickoff,status")
    .in("id", matchIds);

  const rows = requireRows(
    data as MatchRow[] | null,
    error,
    "PRODUCTION_CANONICAL_MATCHES_LOAD_FAILED",
  );

  const byId = new Map(
    rows.map((row) => [row.id, row]),
  );

  for (const matchId of matchIds) {
    if (!byId.has(matchId)) {
      throw new Error(
        `PRODUCTION_CANONICAL_MATCH_MISSING:${matchId}`,
      );
    }
  }

  return byId;
}

async function loadActiveProviderId(
  client: SupabaseClient,
  providerCode: ProductionProviderCode,
): Promise<string> {
  const { data, error } = await client
    .from("data_providers")
    .select("id,code,active")
    .eq("code", providerCode)
    .eq("active", true)
    .limit(1)
    .maybeSingle();

  return requireSingle(
    data as ProviderRow | null,
    error,
    `PRODUCTION_PROVIDER_NOT_ACTIVE:${providerCode}`,
  ).id;
}

async function loadProviderMatchMap(
  client: SupabaseClient,
  providerId: string,
  providerCode: ProductionProviderCode,
  matchIds: string[],
): Promise<Map<string, string>> {
  const { data, error } = await client
    .from("provider_entity_maps")
    .select("internal_id,external_id")
    .eq("provider_id", providerId)
    .eq("entity_type", "match")
    .eq("active", true)
    .in("internal_id", matchIds);

  const rows = requireRows(
    data as ProviderMapRow[] | null,
    error,
    `PRODUCTION_PROVIDER_MAP_LOAD_FAILED:${providerCode}`,
  );

  const byInternalId = new Map(
    rows.map((row) => [
      row.internal_id,
      row.external_id,
    ]),
  );

  for (const matchId of matchIds) {
    if (!byInternalId.has(matchId)) {
      throw new Error(
        `PRODUCTION_PROVIDER_MATCH_MAPPING_MISSING:${providerCode}:${matchId}`,
      );
    }
  }

  return byInternalId;
}

export async function loadFootballDataProductionTargets(
  client: SupabaseClient,
  fantagolRoundId: string,
): Promise<LivePollingTarget[]> {
  const roundMatches =
    await loadRequiredRoundMatches(
      client,
      fantagolRoundId,
    );

  const matchIds =
    roundMatches.map((row) => row.match_id);

  const [
    matchesById,
    leagueRoundIds,
    providerId,
  ] = await Promise.all([
    loadCanonicalMatches(client, matchIds),
    loadEnabledLeagueRoundIds(
      client,
      fantagolRoundId,
    ),
    loadActiveProviderId(
      client,
      "football_data",
    ),
  ]);

  const providerMap =
    await loadProviderMatchMap(
      client,
      providerId,
      "football_data",
      matchIds,
    );

  return roundMatches.map((roundMatch) => {
    const match =
      matchesById.get(roundMatch.match_id);

    const externalMatchId =
      providerMap.get(roundMatch.match_id);

    if (!match || !externalMatchId) {
      throw new Error(
        `PRODUCTION_FOOTBALL_DATA_TARGET_INCOMPLETE:${roundMatch.match_id}`,
      );
    }

    return {
      matchId: match.id,
      providerCode: "football_data",
      externalMatchId,
      kickoffAt: match.kickoff,
      status:
        match.status as LivePollingTarget["status"],
      fantagolRoundId,
      leagueRoundIds,
    };
  });
}

export async function loadMarketRoundProductionTargets(
  client: SupabaseClient,
  fantagolRoundId: string,
): Promise<MarketRoundPollingTarget[]> {
  const roundMatches =
    await loadRequiredRoundMatches(
      client,
      fantagolRoundId,
    );

  const matchIds =
    roundMatches.map((row) => row.match_id);

  const [
    matchesById,
    leagueRoundIds,
    providerId,
  ] = await Promise.all([
    loadCanonicalMatches(client, matchIds),
    loadEnabledLeagueRoundIds(
      client,
      fantagolRoundId,
    ),
    loadActiveProviderId(
      client,
      "the_odds_api",
    ),
  ]);

  const providerMap =
    await loadProviderMatchMap(
      client,
      providerId,
      "the_odds_api",
      matchIds,
    );

  return roundMatches.map((roundMatch) => {
    const match =
      matchesById.get(roundMatch.match_id);

    const externalMatchId =
      providerMap.get(roundMatch.match_id);

    if (!match || !externalMatchId) {
      throw new Error(
        `PRODUCTION_MARKET_TARGET_INCOMPLETE:${roundMatch.match_id}`,
      );
    }

    return {
      matchId: match.id,
      externalMatchId,
      slotNumber: roundMatch.slot_number,
      kickoffAt: match.kickoff,
      status: match.status,
      leagueRoundIds,
    };
  });
}