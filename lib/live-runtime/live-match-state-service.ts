import type { SupabaseClient } from "@supabase/supabase-js";

import type { NormalizedMatchStatus } from "../providers/types/normalized";
import { LiveRuntimeError } from "./errors";
import type { RuntimePersistedMatchState } from "./types";

type ReceiptStateRow = {
  normalized_payload: unknown;
};

const NORMALIZED_MATCH_STATUSES = new Set<NormalizedMatchStatus>([
  "scheduled",
  "postponed",
  "cancelled",
  "live_first_half",
  "halftime",
  "live_second_half",
  "extra_time",
  "penalties",
  "finished",
  "awarded",
  "abandoned",
]);

function isRecord(value: unknown): value is Record<string, unknown> {
  return (
    typeof value === "object" &&
    value !== null &&
    !Array.isArray(value)
  );
}

function requireString(
  payload: Record<string, unknown>,
  key: string,
): string {
  const value = payload[key];

  if (typeof value !== "string" || value.trim() === "") {
    throw new LiveRuntimeError({
      code: "LIVE_RUNTIME_INVALID_RPC_RESPONSE",
      message:
        `Latest live receipt contains an invalid '${key}' value`,
      details: { key, value },
    });
  }

  return value;
}

function requireNullableInteger(
  payload: Record<string, unknown>,
  key: string,
): number | null {
  const value = payload[key];

  if (value === null) {
    return null;
  }

  if (!Number.isInteger(value) || (value as number) < 0) {
    throw new LiveRuntimeError({
      code: "LIVE_RUNTIME_INVALID_RPC_RESPONSE",
      message:
        `Latest live receipt contains an invalid '${key}' value`,
      details: { key, value },
    });
  }

  return value as number;
}

function requireNullableString(
  payload: Record<string, unknown>,
  key: string,
): string | null {
  const value = payload[key];

  if (value === null) {
    return null;
  }

  if (typeof value !== "string") {
    throw new LiveRuntimeError({
      code: "LIVE_RUNTIME_INVALID_RPC_RESPONSE",
      message:
        `Latest live receipt contains an invalid '${key}' value`,
      details: { key, value },
    });
  }

  return value;
}

function parsePersistedState(
  normalizedPayload: unknown,
): RuntimePersistedMatchState {
  if (!isRecord(normalizedPayload)) {
    throw new LiveRuntimeError({
      code: "LIVE_RUNTIME_INVALID_RPC_RESPONSE",
      message:
        "Latest live receipt contains a non-object normalized payload",
      details: { normalizedPayload },
    });
  }

  const status = requireString(normalizedPayload, "status");

  if (!NORMALIZED_MATCH_STATUSES.has(status as NormalizedMatchStatus)) {
    throw new LiveRuntimeError({
      code: "LIVE_RUNTIME_INVALID_RPC_RESPONSE",
      message:
        "Latest live receipt contains an unsupported match status",
      details: { status },
    });
  }

  return {
    kickoffAt: requireString(normalizedPayload, "kickoff_at"),
    status: status as NormalizedMatchStatus,
    homeScore: requireNullableInteger(
      normalizedPayload,
      "home_score",
    ),
    awayScore: requireNullableInteger(
      normalizedPayload,
      "away_score",
    ),
    minute: requireNullableInteger(normalizedPayload, "minute"),
    period: requireNullableString(normalizedPayload, "period"),
    providerUpdatedAt: requireString(
      normalizedPayload,
      "provider_updated_at",
    ),
  };
}

/**
 * Loads the latest valid provider receipt for a match and reconstructs the
 * compact state required by the Live Runtime change detector.
 */
export async function loadPreviousLiveMatchState(
  client: SupabaseClient,
  matchId: string,
): Promise<RuntimePersistedMatchState | null> {
  const { data, error } = await client
    .from("live_match_update_receipts")
    .select("normalized_payload")
    .eq("match_id", matchId)
    .in("processing_status", ["accepted", "processed"])
    .order("received_at", { ascending: false })
    .limit(1)
    .maybeSingle();

  if (error) {
    throw new LiveRuntimeError({
      code: "LIVE_RUNTIME_RPC_ERROR",
      message:
        "Unable to load the previous persisted live match state",
      details: {
        operation: "load_previous_live_match_state",
        matchId,
        databaseCode: error.code,
        databaseMessage: error.message,
      },
      cause: error,
    });
  }

  if (!data) {
    return null;
  }

  return parsePersistedState(
    (data as ReceiptStateRow).normalized_payload,
  );
}
