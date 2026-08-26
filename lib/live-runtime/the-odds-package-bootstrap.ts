import type { SupabaseClient } from "@supabase/supabase-js";

import type {
  ProviderPollResult,
} from "./provider-runtime";

export type TheOddsBootstrapCanonicalTarget = {
  matchId: string;
  slotNumber: number;
  kickoffAt: string;
  homeTeam: string;
  awayTeam: string;
};

type TheOddsBootstrapRoundMatchRow = {
  match_id: string;
  slot_number: number;
  required: boolean;
  removed_at: string | null;
};

type TheOddsBootstrapMatchRow = {
  id: string;
  kickoff: string;
  home_team_id: string;
  away_team_id: string;
};

type TheOddsBootstrapTeamRow = {
  id: string;
  name: string;
};

export async function loadTheOddsBootstrapCanonicalTargets(
  input: {
    client: SupabaseClient;
    fantagolRoundId: string;
  },
): Promise<TheOddsBootstrapCanonicalTarget[]> {
  const {
    data: roundMatchData,
    error: roundMatchError,
  } = await input.client
    .from("fantagol_round_matches")
    .select(
      "match_id,slot_number,required,removed_at",
    )
    .eq(
      "fantagol_round_id",
      input.fantagolRoundId,
    )
    .eq("required", true)
    .is("removed_at", null)
    .order(
      "slot_number",
      { ascending: true },
    );

  if (roundMatchError) {
    throw new Error(
      `THE_ODDS_BOOTSTRAP_ROUND_MATCHES_LOAD_FAILED:${roundMatchError.message}`,
    );
  }

  const roundMatches =
    (
      roundMatchData ??
      []
    ) as TheOddsBootstrapRoundMatchRow[];

  if (roundMatches.length === 0) {
    throw new Error(
      "THE_ODDS_BOOTSTRAP_CANONICAL_TARGETS_EMPTY",
    );
  }

  const matchIds =
    roundMatches.map(
      (row) => row.match_id,
    );

  if (
    new Set(matchIds).size !==
    roundMatches.length
  ) {
    throw new Error(
      "THE_ODDS_BOOTSTRAP_CANONICAL_MATCH_DUPLICATE",
    );
  }

  const slots =
    roundMatches.map(
      (row) => row.slot_number,
    );

  if (
    new Set(slots).size !==
    roundMatches.length
  ) {
    throw new Error(
      "THE_ODDS_BOOTSTRAP_CANONICAL_SLOT_DUPLICATE",
    );
  }

  const {
    data: matchData,
    error: matchError,
  } = await input.client
    .from("matches")
    .select(
      "id,kickoff,home_team_id,away_team_id",
    )
    .in(
      "id",
      matchIds,
    );

  if (matchError) {
    throw new Error(
      `THE_ODDS_BOOTSTRAP_CANONICAL_MATCHES_LOAD_FAILED:${matchError.message}`,
    );
  }

  const matches =
    (
      matchData ??
      []
    ) as TheOddsBootstrapMatchRow[];

  const byId =
    new Map(
      matches.map(
        (match) => [
          match.id,
          match,
        ],
      ),
    );

  const teamIds =
    [
      ...new Set(
        matches.flatMap(
          (match) => [
            match.home_team_id,
            match.away_team_id,
          ],
        ),
      ),
    ];

  if (
    teamIds.length !==
    matches.length * 2
  ) {
    throw new Error(
      "THE_ODDS_BOOTSTRAP_CANONICAL_TEAM_CARDINALITY_INVALID",
    );
  }

  const {
    data: teamData,
    error: teamError,
  } = await input.client
    .from("teams")
    .select(
      "id,name",
    )
    .in(
      "id",
      teamIds,
    );

  if (teamError) {
    throw new Error(
      `THE_ODDS_BOOTSTRAP_CANONICAL_TEAMS_LOAD_FAILED:${teamError.message}`,
    );
  }

  const teams =
    (
      teamData ??
      []
    ) as TheOddsBootstrapTeamRow[];

  if (
    teams.length !==
    teamIds.length
  ) {
    throw new Error(
      `THE_ODDS_BOOTSTRAP_CANONICAL_TEAMS_INCOMPLETE:${teamIds.length}:${teams.length}`,
    );
  }

  const teamById =
    new Map(
      teams.map(
        (team) => [
          team.id,
          team,
        ],
      ),
    );

  return roundMatches.map(
    (roundMatch) => {
      const match =
        byId.get(
          roundMatch.match_id,
        );

      if (!match) {
        throw new Error(
          `THE_ODDS_BOOTSTRAP_CANONICAL_MATCH_MISSING:${roundMatch.match_id}`,
        );
      }

      if (
        typeof match.kickoff !== "string" ||
        match.kickoff.trim() === "" ||
        typeof match.home_team_id !== "string" ||
        match.home_team_id.trim() === "" ||
        typeof match.away_team_id !== "string" ||
        match.away_team_id.trim() === ""
      ) {
        throw new Error(
          `THE_ODDS_BOOTSTRAP_CANONICAL_MATCH_INVALID:${roundMatch.match_id}`,
        );
      }

      const homeTeam =
        teamById.get(
          match.home_team_id,
        );

      const awayTeam =
        teamById.get(
          match.away_team_id,
        );

      if (
        !homeTeam ||
        typeof homeTeam.name !== "string" ||
        homeTeam.name.trim() === ""
      ) {
        throw new Error(
          `THE_ODDS_BOOTSTRAP_CANONICAL_HOME_TEAM_MISSING:${roundMatch.match_id}:${match.home_team_id}`,
        );
      }

      if (
        !awayTeam ||
        typeof awayTeam.name !== "string" ||
        awayTeam.name.trim() === ""
      ) {
        throw new Error(
          `THE_ODDS_BOOTSTRAP_CANONICAL_AWAY_TEAM_MISSING:${roundMatch.match_id}:${match.away_team_id}`,
        );
      }

      return {
        matchId:
          roundMatch.match_id,
        slotNumber:
          roundMatch.slot_number,
        kickoffAt:
          match.kickoff,
        homeTeam:
          homeTeam.name.trim(),
        awayTeam:
          awayTeam.name.trim(),
      };
    },
  );
}
export type TheOddsBootstrapMapping = {
  matchId: string;
  slotNumber: number;
  externalMatchId: string;
  canonicalHomeTeam: string;
  canonicalAwayTeam: string;
  providerHomeTeam: string;
  providerAwayTeam: string;
  canonicalKickoffAt: string;
  providerKickoffAt: string;
  kickoffDeltaSeconds: number;
};

type ProviderBootstrapEvent = {
  externalMatchId: string;
  homeTeam: string;
  awayTeam: string;
  commenceTime: string;
  homeNorm: string;
  awayNorm: string;
};

function isRecord(
  value: unknown,
): value is Record<string, unknown> {
  return (
    typeof value === "object" &&
    value !== null &&
    !Array.isArray(value)
  );
}

function stripDiacritics(
  value: string,
): string {
  return value
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "");
}

export function normalizeTheOddsTeamName(
  value: string,
): string {
  const stopTokens =
    new Set([
      "fc",
      "ac",
      "acf",
      "ssc",
      "ss",
      "us",
      "as",
      "bc",
      "cfc",
      "calcio",
      "football",
      "club",
    ]);

  const normalized =
    stripDiacritics(
      value.toLowerCase(),
    )
      .replace(/[^a-z0-9]+/g, " ")
      .trim()
      .split(/\s+/)
      .filter(
        (token) =>
          token !== "" &&
          !stopTokens.has(token) &&
          !/^(18|19|20)\d{2}$/.test(token),
      )
      .join(" ");

  const aliases:
    Record<string, string> = {
      "internazionale milano": "inter",
      internazionale: "inter",
      "inter milano": "inter",
      "inter milan": "inter",
      "milan milano": "milan",
      "hellas verona": "verona",
      "verona hellas": "verona",
    };

  return aliases[normalized] ?? normalized;
}

function requireIsoMs(
  value: string,
  label: string,
): number {
  const parsed =
    Date.parse(value);

  if (!Number.isFinite(parsed)) {
    throw new Error(
      `THE_ODDS_BOOTSTRAP_INVALID_${label}`,
    );
  }

  return parsed;
}

function providerEventFromPoll(
  poll: ProviderPollResult,
): ProviderBootstrapEvent {
  if (!isRecord(poll.payload)) {
    throw new Error(
      "THE_ODDS_BOOTSTRAP_PAYLOAD_INVALID",
    );
  }

  const eventOdds =
    poll.payload.eventOdds;

  if (!isRecord(eventOdds)) {
    throw new Error(
      "THE_ODDS_BOOTSTRAP_EVENT_ODDS_MISSING",
    );
  }

  const id =
    eventOdds.id;

  const homeTeam =
    eventOdds.home_team;

  const awayTeam =
    eventOdds.away_team;

  const commenceTime =
    eventOdds.commence_time;

  if (
    typeof id !== "string" ||
    id.trim() === "" ||
    typeof homeTeam !== "string" ||
    homeTeam.trim() === "" ||
    typeof awayTeam !== "string" ||
    awayTeam.trim() === "" ||
    typeof commenceTime !== "string" ||
    commenceTime.trim() === ""
  ) {
    throw new Error(
      "THE_ODDS_BOOTSTRAP_EVENT_CONTRACT_INVALID",
    );
  }

  if (
    id.trim() !==
    poll.externalMatchId.trim()
  ) {
    throw new Error(
      "THE_ODDS_BOOTSTRAP_POLL_EVENT_ID_MISMATCH",
    );
  }

  requireIsoMs(
    commenceTime,
    "PROVIDER_KICKOFF",
  );

  return {
    externalMatchId:
      id.trim(),
    homeTeam:
      homeTeam.trim(),
    awayTeam:
      awayTeam.trim(),
    commenceTime:
      commenceTime.trim(),
    homeNorm:
      normalizeTheOddsTeamName(homeTeam),
    awayNorm:
      normalizeTheOddsTeamName(awayTeam),
  };
}

export function buildTheOddsRoundBootstrapMapping(
  input: {
    targets:
      TheOddsBootstrapCanonicalTarget[];
    polls:
      ProviderPollResult[];
    maximumKickoffDeltaSeconds?: number;
  },
): TheOddsBootstrapMapping[] {
  const maximumKickoffDeltaSeconds =
    input.maximumKickoffDeltaSeconds ?? 60;

  if (
    !Number.isFinite(
      maximumKickoffDeltaSeconds,
    ) ||
    maximumKickoffDeltaSeconds < 0
  ) {
    throw new Error(
      "THE_ODDS_BOOTSTRAP_INVALID_KICKOFF_TOLERANCE",
    );
  }

  if (input.targets.length === 0) {
    throw new Error(
      "THE_ODDS_BOOTSTRAP_TARGETS_REQUIRED",
    );
  }

  const targetIds =
    new Set(
      input.targets.map(
        (target) =>
          target.matchId,
      ),
    );

  const slots =
    new Set(
      input.targets.map(
        (target) =>
          target.slotNumber,
      ),
    );

  if (
    targetIds.size !== input.targets.length ||
    slots.size !== input.targets.length
  ) {
    throw new Error(
      "THE_ODDS_BOOTSTRAP_CANONICAL_TARGET_DUPLICATE",
    );
  }

  const providerEvents =
    input.polls.map(
      providerEventFromPoll,
    );

  const providerIds =
    new Set(
      providerEvents.map(
        (event) =>
          event.externalMatchId,
      ),
    );

  if (
    providerIds.size !==
    providerEvents.length
  ) {
    throw new Error(
      "THE_ODDS_BOOTSTRAP_PROVIDER_EVENT_DUPLICATE",
    );
  }

  const mappings:
    TheOddsBootstrapMapping[] = [];

  for (const target of input.targets) {
    const homeNorm =
      normalizeTheOddsTeamName(
        target.homeTeam,
      );

    const awayNorm =
      normalizeTheOddsTeamName(
        target.awayTeam,
      );

    const candidates =
      providerEvents.filter(
        (event) =>
          event.homeNorm === homeNorm &&
          event.awayNorm === awayNorm,
      );

    if (candidates.length !== 1) {
      throw new Error(
        [
          "THE_ODDS_BOOTSTRAP_FIXTURE_IDENTITY_NOT_UNIQUE",
          target.matchId,
          target.slotNumber,
          candidates.length,
        ].join(":"),
      );
    }

    const provider =
      candidates[0];

    const canonicalMs =
      requireIsoMs(
        target.kickoffAt,
        "CANONICAL_KICKOFF",
      );

    const providerMs =
      requireIsoMs(
        provider.commenceTime,
        "PROVIDER_KICKOFF",
      );

    const kickoffDeltaSeconds =
      Math.abs(
        providerMs -
          canonicalMs,
      ) / 1000;

    if (
      kickoffDeltaSeconds >
      maximumKickoffDeltaSeconds
    ) {
      throw new Error(
        [
          "THE_ODDS_BOOTSTRAP_KICKOFF_MISMATCH",
          target.matchId,
          kickoffDeltaSeconds,
        ].join(":"),
      );
    }

    mappings.push({
      matchId:
        target.matchId,
      slotNumber:
        target.slotNumber,
      externalMatchId:
        provider.externalMatchId,
      canonicalHomeTeam:
        target.homeTeam,
      canonicalAwayTeam:
        target.awayTeam,
      providerHomeTeam:
        provider.homeTeam,
      providerAwayTeam:
        provider.awayTeam,
      canonicalKickoffAt:
        target.kickoffAt,
      providerKickoffAt:
        provider.commenceTime,
      kickoffDeltaSeconds,
    });
  }

  const mappedInternal =
    new Set(
      mappings.map(
        (mapping) =>
          mapping.matchId,
      ),
    );

  const mappedExternal =
    new Set(
      mappings.map(
        (mapping) =>
          mapping.externalMatchId,
      ),
    );

  if (
    mappings.length !==
      input.targets.length ||
    mappedInternal.size !==
      input.targets.length ||
    mappedExternal.size !==
      input.targets.length
  ) {
    throw new Error(
      "THE_ODDS_BOOTSTRAP_EXACT_COVERAGE_FAILED",
    );
  }

  return [...mappings].sort(
    (left, right) =>
      left.slotNumber -
      right.slotNumber,
  );
}

export async function persistTheOddsRoundBootstrapMapping(
  input: {
    client: SupabaseClient;
    fantagolRoundId: string;
    mappings:
      TheOddsBootstrapMapping[];
  },
): Promise<{
  provider_code: string;
  required_match_count: number;
  mapped_match_count: number;
  distinct_external_match_count: number;
  inserted_match_count: number;
  idempotent: boolean;
}> {
  const { data, error } =
    await input.client.rpc(
      "persist_the_odds_round_mapping_bootstrap_internal",
      {
        p_fantagol_round_id:
          input.fantagolRoundId,
        p_mappings:
          input.mappings.map(
            (mapping) => ({
              match_id:
                mapping.matchId,
              slot_number:
                mapping.slotNumber,
              external_id:
                mapping.externalMatchId,
            }),
          ),
      },
    );

  if (error) {
    throw new Error(
      `THE_ODDS_BOOTSTRAP_MAPPING_PERSIST_FAILED:${error.message}`,
    );
  }

  if (
    !data ||
    typeof data !== "object" ||
    Array.isArray(data)
  ) {
    throw new Error(
      "THE_ODDS_BOOTSTRAP_MAPPING_PERSIST_RESULT_INVALID",
    );
  }

  return data as {
    provider_code: string;
    required_match_count: number;
    mapped_match_count: number;
    distinct_external_match_count: number;
    inserted_match_count: number;
    idempotent: boolean;
  };
}
