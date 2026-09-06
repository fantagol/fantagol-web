import type { SupabaseClient } from "@supabase/supabase-js";

import type {
  TuttoilcalcioLiveObservation,
} from "./tuttoilcalcio-live-provider";

type RpcClient = Pick<SupabaseClient, "rpc">;

export type LiveRuntimeAuthorityState = {
  match_id: string;
  authority: "primary_live" | "degraded_live";
  source: "tuttoilcalcio" | "football_data";
  source_observation_id: string | null;
  phase:
    | "PRE_MATCH"
    | "FIRST_HALF"
    | "HALFTIME"
    | "SECOND_HALF"
    | "END_PENDING";
  minute: number | null;
  home_score: number;
  away_score: number;
  observed_at: string;
  version: number;
};

function firstRow<T>(value: unknown): T {
  if (Array.isArray(value)) {
    if (value.length === 0) {
      throw new Error("LIVE_PRIMARY_RPC_EMPTY");
    }
    return value[0] as T;
  }

  if (value && typeof value === "object") {
    return value as T;
  }

  throw new Error("LIVE_PRIMARY_RPC_INVALID_RESULT");
}

export async function recordPrimaryLiveObservation(
  client: RpcClient,
  input: {
    matchId: string;
    observation: TuttoilcalcioLiveObservation;
    correlationId?: string | null;
  },
): Promise<{
  observation_id: string;
  authority_state_version: number;
  effective_phase: string;
  effective_minute: number | null;
  effective_home_score: number;
  effective_away_score: number;
  changed_fields: string[];
}> {
  const { observation } = input;

  const { data, error } = await client.rpc(
    "record_primary_live_observation_v2_internal",
    {
      p_match_id: input.matchId,
      p_source_fixture_id: observation.sourceFixtureId,
      p_observed_at: observation.observedAt,
      p_source_status: observation.sourceStatus,
      p_phase: observation.phase,
      p_minute: observation.minute,
      p_home_score: observation.homeScore,
      p_away_score: observation.awayScore,
      p_terminal_hint: observation.terminalHint,
      p_payload_hash: observation.payloadHash,
      p_payload: observation.payload,
      p_correlation_id: input.correlationId ?? null,
    },
  );

  if (error) {
    throw new Error(
      `LIVE_PRIMARY_RECORD_FAILED:${error.message}`,
    );
  }

  return firstRow(data);
}

export async function activateFootballDataDegradedLive(
  client: RpcClient,
  input: {
    matchId: string;
    correlationId?: string | null;
  },
): Promise<LiveRuntimeAuthorityState> {
  const { data, error } = await client.rpc(
    "activate_football_data_degraded_live_internal",
    {
      p_match_id: input.matchId,
      p_correlation_id: input.correlationId ?? null,
    },
  );

  if (error) {
    throw new Error(
      `LIVE_DEGRADED_ACTIVATION_FAILED:${error.message}`,
    );
  }

  return firstRow(data);
}

export async function resolveLiveRuntimeAuthorityState(
  client: RpcClient,
  matchId: string,
): Promise<LiveRuntimeAuthorityState | null> {
  const { data, error } = await client.rpc(
    "resolve_live_match_runtime_state_internal",
    {
      p_match_id: matchId,
    },
  );

  if (error) {
    throw new Error(
      `LIVE_RUNTIME_AUTHORITY_RESOLVE_FAILED:${error.message}`,
    );
  }

  if (Array.isArray(data) && data.length === 0) {
    return null;
  }

  if (data == null) {
    return null;
  }

  return firstRow(data);
}
