import type { SupabaseClient } from "@supabase/supabase-js";

import type {
  ProductionRoundContext,
} from "./production-target-loader";

export const THE_ODDS_BOOTSTRAP_DELAY_MS =
  24 * 60 * 60 * 1000;

export type TheOddsRoundBootstrapDecision =
  | {
      action: "complete";
      reason:
        "the_odds_round_mapping_complete";
      eligibleAt: null;
      requiredMatchCount: number;
      mappedMatchCount: number;
      missingMatchCount: 0;
    }
  | {
      action: "wait";
      reason:
        | "the_odds_previous_round_not_certified"
        | "the_odds_previous_round_end_missing"
        | "the_odds_round_bootstrap_not_due"
        | "the_odds_first_round_opening_missing"
        | "the_odds_first_round_bootstrap_not_due";
      eligibleAt: string | null;
      requiredMatchCount: number;
      mappedMatchCount: number;
      missingMatchCount: number;
    }
  | {
      action: "bootstrap";
      reason:
        | "the_odds_round_bootstrap_due"
        | "the_odds_first_round_bootstrap_due";
      eligibleAt: string;
      requiredMatchCount: number;
      mappedMatchCount: number;
      missingMatchCount: number;
    };

export type DecideTheOddsRoundBootstrapInput = {
  now: Date;

  currentRoundOpensAt:
    string | null;

  previousRoundStatus:
    string | null;

  previousRoundEndsAt:
    string | null;

  requiredMatchCount:
    number;

  mappedMatchCount:
    number;
};

type CurrentRoundAuthorityRow = {
  id: string;
  edition_id: string;
  sequence: number;
  opens_at: string | null;
};

type PreviousRoundAuthorityRow = {
  id: string;
  edition_id: string;
  sequence: number;
  status: string;
  ends_at: string | null;
};

type RequiredMatchRow = {
  match_id: string;
};

type ProviderRow = {
  id: string;
};

type ProviderMapRow = {
  internal_id: string;
  external_id: string;
};

function parseIsoMs(
  value: string,
  label: string,
): number {
  const parsed =
    Date.parse(value);

  if (!Number.isFinite(parsed)) {
    throw new Error(
      `${label}_INVALID:${value}`,
    );
  }

  return parsed;
}

function previousStatusIsCertified(
  status: string,
): boolean {
  return (
    status === "final_calculable" ||
    status === "final_official" ||
    status === "recalculated"
  );
}

/**
 * Pure temporal/mapping decision.
 *
 * New-round rule:
 *
 * previous canonical Round certified
 *       +
 * previous ends_at + 24h reached
 *       +
 * current Round Odds mapping incomplete
 *       =
 * bootstrap required
 *
 * Once mapping is complete this authority permanently exits and normal
 * PACKAGE cadence remains governed by the existing Market policy.
 */
export function decideTheOddsRoundBootstrap(
  input: DecideTheOddsRoundBootstrapInput,
): TheOddsRoundBootstrapDecision {
  if (
    !Number.isInteger(
      input.requiredMatchCount,
    ) ||
    input.requiredMatchCount <= 0
  ) {
    throw new Error(
      "THE_ODDS_BOOTSTRAP_REQUIRED_MATCH_COUNT_INVALID",
    );
  }

  if (
    !Number.isInteger(
      input.mappedMatchCount,
    ) ||
    input.mappedMatchCount < 0 ||
    input.mappedMatchCount >
      input.requiredMatchCount
  ) {
    throw new Error(
      "THE_ODDS_BOOTSTRAP_MAPPED_MATCH_COUNT_INVALID",
    );
  }

  const missingMatchCount =
    input.requiredMatchCount -
    input.mappedMatchCount;

  if (missingMatchCount === 0) {
    return {
      action:
        "complete",
      reason:
        "the_odds_round_mapping_complete",
      eligibleAt:
        null,
      requiredMatchCount:
        input.requiredMatchCount,
      mappedMatchCount:
        input.mappedMatchCount,
      missingMatchCount:
        0,
    };
  }

  /*
   * Edition Round 1 has no previous Round.
   * This fallback is deliberately conservative and does not affect
   * the generic N -> N+1 authority.
   */
  if (
    input.previousRoundStatus === null &&
    input.previousRoundEndsAt === null
  ) {
    if (!input.currentRoundOpensAt) {
      return {
        action:
          "wait",
        reason:
          "the_odds_first_round_opening_missing",
        eligibleAt:
          null,
        requiredMatchCount:
          input.requiredMatchCount,
        mappedMatchCount:
          input.mappedMatchCount,
        missingMatchCount,
      };
    }

    const openingMs =
      parseIsoMs(
        input.currentRoundOpensAt,
        "THE_ODDS_BOOTSTRAP_FIRST_ROUND_OPENING",
      );

    const eligibleAt =
      new Date(
        openingMs,
      ).toISOString();

    if (
      input.now.getTime() <
      openingMs
    ) {
      return {
        action:
          "wait",
        reason:
          "the_odds_first_round_bootstrap_not_due",
        eligibleAt,
        requiredMatchCount:
          input.requiredMatchCount,
        mappedMatchCount:
          input.mappedMatchCount,
        missingMatchCount,
      };
    }

    return {
      action:
        "bootstrap",
      reason:
        "the_odds_first_round_bootstrap_due",
      eligibleAt,
      requiredMatchCount:
        input.requiredMatchCount,
      mappedMatchCount:
        input.mappedMatchCount,
      missingMatchCount,
    };
  }

  if (
    !input.previousRoundStatus ||
    !previousStatusIsCertified(
      input.previousRoundStatus,
    )
  ) {
    return {
      action:
        "wait",
      reason:
        "the_odds_previous_round_not_certified",
      eligibleAt:
        null,
      requiredMatchCount:
        input.requiredMatchCount,
      mappedMatchCount:
        input.mappedMatchCount,
      missingMatchCount,
    };
  }

  if (!input.previousRoundEndsAt) {
    return {
      action:
        "wait",
      reason:
        "the_odds_previous_round_end_missing",
      eligibleAt:
        null,
      requiredMatchCount:
        input.requiredMatchCount,
      mappedMatchCount:
        input.mappedMatchCount,
      missingMatchCount,
    };
  }

  const previousEndsAtMs =
    parseIsoMs(
      input.previousRoundEndsAt,
      "THE_ODDS_BOOTSTRAP_PREVIOUS_END",
    );

  const eligibleAtMs =
    previousEndsAtMs +
    THE_ODDS_BOOTSTRAP_DELAY_MS;

  const eligibleAt =
    new Date(
      eligibleAtMs,
    ).toISOString();

  if (
    input.now.getTime() <
    eligibleAtMs
  ) {
    return {
      action:
        "wait",
      reason:
        "the_odds_round_bootstrap_not_due",
      eligibleAt,
      requiredMatchCount:
        input.requiredMatchCount,
      mappedMatchCount:
        input.mappedMatchCount,
      missingMatchCount,
    };
  }

  return {
    action:
      "bootstrap",
    reason:
      "the_odds_round_bootstrap_due",
    eligibleAt,
    requiredMatchCount:
      input.requiredMatchCount,
    mappedMatchCount:
      input.mappedMatchCount,
    missingMatchCount,
  };
}

/**
 * Production read-only resolver.
 *
 * Critical lineage rule:
 * previous Round is resolved inside the SAME edition_id.
 *
 * No provider call.
 * No queue mutation.
 * No provider mapping mutation.
 */
export async function loadCanonicalTheOddsRoundBootstrapDecision(
  input: {
    client: SupabaseClient;
    round: ProductionRoundContext;
    now: Date;
  },
): Promise<TheOddsRoundBootstrapDecision> {
  const {
    data: currentData,
    error: currentError,
  } =
    await input.client
      .from("fantagol_rounds")
      .select(
        "id,edition_id,sequence,opens_at",
      )
      .eq(
        "id",
        input.round.fantagolRoundId,
      )
      .limit(1)
      .maybeSingle();

  if (currentError) {
    throw new Error(
      `THE_ODDS_BOOTSTRAP_CURRENT_ROUND_LOAD_FAILED:${currentError.message}`,
    );
  }

  if (!currentData) {
    throw new Error(
      "THE_ODDS_BOOTSTRAP_CURRENT_ROUND_NOT_FOUND",
    );
  }

  const current =
    currentData as CurrentRoundAuthorityRow;

  const {
    data: previousData,
    error: previousError,
  } =
    await input.client
      .from("fantagol_rounds")
      .select(
        "id,edition_id,sequence,status,ends_at",
      )
      .eq(
        "edition_id",
        current.edition_id,
      )
      .lt(
        "sequence",
        current.sequence,
      )
      .order(
        "sequence",
        {
          ascending:
            false,
        },
      )
      .limit(1)
      .maybeSingle();

  if (previousError) {
    throw new Error(
      `THE_ODDS_BOOTSTRAP_PREVIOUS_ROUND_LOAD_FAILED:${previousError.message}`,
    );
  }

  const previous =
    previousData as
      | PreviousRoundAuthorityRow
      | null;

  const {
    data: requiredData,
    error: requiredError,
  } =
    await input.client
      .from(
        "fantagol_round_matches",
      )
      .select("match_id")
      .eq(
        "fantagol_round_id",
        input.round.fantagolRoundId,
      )
      .eq(
        "required",
        true,
      )
      .is(
        "removed_at",
        null,
      );

  if (requiredError) {
    throw new Error(
      `THE_ODDS_BOOTSTRAP_REQUIRED_MATCH_LOAD_FAILED:${requiredError.message}`,
    );
  }

  const requiredRows =
    (requiredData ??
      []) as RequiredMatchRow[];

  if (
    requiredRows.length === 0
  ) {
    throw new Error(
      "THE_ODDS_BOOTSTRAP_REQUIRED_MATCH_SET_EMPTY",
    );
  }

  const requiredMatchIds =
    requiredRows.map(
      (row) =>
        row.match_id,
    );

  const {
    data: providerData,
    error: providerError,
  } =
    await input.client
      .from("data_providers")
      .select("id")
      .eq(
        "code",
        "the_odds_api",
      )
      .eq(
        "active",
        true,
      )
      .limit(1)
      .maybeSingle();

  if (providerError) {
    throw new Error(
      `THE_ODDS_BOOTSTRAP_PROVIDER_LOAD_FAILED:${providerError.message}`,
    );
  }

  if (!providerData) {
    throw new Error(
      "THE_ODDS_BOOTSTRAP_PROVIDER_NOT_ACTIVE",
    );
  }

  const provider =
    providerData as ProviderRow;

  const {
    data: mapData,
    error: mapError,
  } =
    await input.client
      .from(
        "provider_entity_maps",
      )
      .select(
        "internal_id,external_id",
      )
      .eq(
        "provider_id",
        provider.id,
      )
      .eq(
        "entity_type",
        "match",
      )
      .eq(
        "active",
        true,
      )
      .in(
        "internal_id",
        requiredMatchIds,
      );

  if (mapError) {
    throw new Error(
      `THE_ODDS_BOOTSTRAP_PROVIDER_MAP_LOAD_FAILED:${mapError.message}`,
    );
  }

  const mapRows =
    (mapData ??
      []) as ProviderMapRow[];

  const mappedMatchIds =
    new Set(
      mapRows
        .filter(
          (row) =>
            typeof row.external_id ===
              "string" &&
            row.external_id.trim() !==
              "",
        )
        .map(
          (row) =>
            row.internal_id,
        ),
    );

  return decideTheOddsRoundBootstrap({
    now:
      input.now,

    currentRoundOpensAt:
      current.opens_at ??
      input.round.opensAt,

    previousRoundStatus:
      previous?.status ??
      null,

    previousRoundEndsAt:
      previous?.ends_at ??
      null,

    requiredMatchCount:
      requiredMatchIds.length,

    mappedMatchCount:
      mappedMatchIds.size,
  });
}
