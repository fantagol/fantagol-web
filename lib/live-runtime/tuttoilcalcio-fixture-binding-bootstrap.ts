import type { SupabaseClient } from "@supabase/supabase-js";

const TUTTO_PROVIDER_CODE = "tuttoilcalcio";
const TUTTO_SERIE_A_LEAGUE_ID = 278;
const TUTTO_BASE_URL = "https://tuttoilcalcio.com";
const BINDING_AUTHORITY = "R114_R56_AUTOMATIC_TUTTO_BINDER";

type UnknownRecord = Record<string, unknown>;

type CanonicalRoundMatch = {
  matchId: string;
  slotNumber: number;
  kickoff: string;
  status: string;
  homeTeamId: string;
  awayTeamId: string;
  homeName: string;
  homeShortName: string | null;
  awayName: string;
  awayShortName: string | null;
};

export type TuttoFixtureCandidate = {
  externalId: string;
  localDate: string;
  localKickoff: string;
  status: string;
  homeName: string;
  homeShortName: string | null;
  awayName: string;
  awayShortName: string | null;
  slug: string | null;
};

export type TuttoBindingDecision =
  | { kind: "matched"; candidate: TuttoFixtureCandidate }
  | { kind: "unresolved"; reason: string }
  | { kind: "ambiguous"; candidateCount: number };

function asRecord(value: unknown): UnknownRecord | null {
  return value && typeof value === "object" && !Array.isArray(value)
    ? (value as UnknownRecord)
    : null;
}

function text(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}

function numericText(value: unknown): string {
  if (typeof value === "number" && Number.isFinite(value)) {
    return String(Math.trunc(value));
  }
  if (typeof value === "string" && /^\d+$/.test(value.trim())) {
    return value.trim();
  }
  return "";
}

export function normalizeTuttoTeamName(value: string): string {
  return value
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/\b(?:fc|ac|ssc|as|us|calcio|1909)\b/g, " ")
    .replace(/[^a-z0-9]+/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function normalizeCode(value: string | null): string {
  return (value ?? "").trim().toUpperCase();
}

function romeParts(iso: string): { date: string; time: string } {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) {
    throw new Error(`TUTTO_BINDER_INVALID_CANONICAL_KICKOFF:${iso}`);
  }

  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: "Europe/Rome",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  }).formatToParts(date);

  const get = (type: string) =>
    parts.find((part) => part.type === type)?.value ?? "";

  return {
    date: `${get("year")}-${get("month")}-${get("day")}`,
    time: `${get("hour")}:${get("minute")}`,
  };
}

export function chooseTuttoFixtureCandidate(input: {
  canonical: CanonicalRoundMatch;
  candidates: TuttoFixtureCandidate[];
}): TuttoBindingDecision {
  const local = romeParts(input.canonical.kickoff);

  const sameKickoff = input.candidates.filter(
    (candidate) =>
      candidate.localDate === local.date &&
      candidate.localKickoff === local.time,
  );

  if (sameKickoff.length === 0) {
    return {
      kind: "unresolved",
      reason: "NO_PROVIDER_FIXTURE_AT_CANONICAL_KICKOFF",
    };
  }

  const homeCode = normalizeCode(input.canonical.homeShortName);
  const awayCode = normalizeCode(input.canonical.awayShortName);
  const homeName = normalizeTuttoTeamName(input.canonical.homeName);
  const awayName = normalizeTuttoTeamName(input.canonical.awayName);

  const matched = sameKickoff.filter((candidate) => {
    const codesMatch =
      homeCode !== "" &&
      awayCode !== "" &&
      normalizeCode(candidate.homeShortName) === homeCode &&
      normalizeCode(candidate.awayShortName) === awayCode;

    const namesMatch =
      normalizeTuttoTeamName(candidate.homeName) === homeName &&
      normalizeTuttoTeamName(candidate.awayName) === awayName;

    return codesMatch || namesMatch;
  });

  if (matched.length === 1) {
    return { kind: "matched", candidate: matched[0] };
  }

  if (matched.length === 0) {
    return {
      kind: "unresolved",
      reason: "TEAM_IDENTITY_DID_NOT_MATCH",
    };
  }

  return {
    kind: "ambiguous",
    candidateCount: matched.length,
  };
}

function parseDailySerieAFixtures(
  raw: unknown,
  requestedDate: string,
): TuttoFixtureCandidate[] {
  const root = asRecord(raw);
  if (!root) {
    throw new Error("TUTTO_BINDER_INVALID_COLLECTION_ROOT");
  }

  const payloadDate = text(root.date);
  if (payloadDate !== requestedDate) {
    throw new Error(
      `TUTTO_BINDER_COLLECTION_DATE_MISMATCH:${requestedDate}:${payloadDate}`,
    );
  }

  const leagues = Array.isArray(root.leagues) ? root.leagues : [];
  const league = leagues
    .map(asRecord)
    .find(
      (entry) =>
        entry !== null &&
        Number(entry.id) === TUTTO_SERIE_A_LEAGUE_ID,
    );

  if (!league) {
    throw new Error(
      `TUTTO_BINDER_SERIE_A_LEAGUE_MISSING:${requestedDate}`,
    );
  }

  const matches = Array.isArray(league.matches) ? league.matches : [];

  return matches.map((rawMatch) => {
    const match = asRecord(rawMatch);
    if (!match) {
      throw new Error("TUTTO_BINDER_INVALID_MATCH_ENTRY");
    }

    const home = asRecord(match.home_team);
    const away = asRecord(match.away_team);
    if (!home || !away) {
      throw new Error(
        `TUTTO_BINDER_TEAM_PAYLOAD_MISSING:${numericText(match.id)}`,
      );
    }

    const externalId = numericText(match.id);
    const localKickoff = text(match.kick_off);
    const homeName = text(home.name);
    const awayName = text(away.name);

    if (
      externalId === "" ||
      !/^\d{2}:\d{2}$/.test(localKickoff) ||
      homeName === "" ||
      awayName === ""
    ) {
      throw new Error(
        `TUTTO_BINDER_INCOMPLETE_MATCH_CONTRACT:${externalId || "<id>"}`,
      );
    }

    return {
      externalId,
      localDate: requestedDate,
      localKickoff,
      status: text(match.status).toLowerCase(),
      homeName,
      homeShortName: text(home.short_name) || null,
      awayName,
      awayShortName: text(away.short_name) || null,
      slug: text(match.slug) || null,
    };
  });
}

async function fetchDailySerieAFixtures(
  requestedDate: string,
): Promise<TuttoFixtureCandidate[]> {
  const url =
    `${TUTTO_BASE_URL}/api/v1/fixtures?date=` +
    `${encodeURIComponent(requestedDate)}&locale=it`;

  const response = await fetch(url, {
    method: "GET",
    headers: { accept: "application/json" },
    cache: "no-store",
  });

  if (!response.ok) {
    throw new Error(
      `TUTTO_BINDER_COLLECTION_HTTP_${response.status}:${requestedDate}`,
    );
  }

  const payload: unknown = await response.json();
  return parseDailySerieAFixtures(payload, requestedDate);
}

async function loadCanonicalRoundMatches(
  client: SupabaseClient,
  fantagolRoundId: string,
): Promise<CanonicalRoundMatch[]> {
  const { data: roundRows, error: roundError } = await client
    .from("fantagol_round_matches")
    .select("match_id,slot_number,required,removed_at")
    .eq("fantagol_round_id", fantagolRoundId)
    .eq("required", true)
    .is("removed_at", null)
    .order("slot_number", { ascending: true });

  if (roundError) {
    throw new Error(
      `TUTTO_BINDER_ROUND_MATCHES_FAILED:${roundError.message}`,
    );
  }

  const matchIds = (roundRows ?? [])
    .map((row) => String(row.match_id))
    .filter(Boolean);

  if (matchIds.length === 0) {
    return [];
  }

  const { data: matches, error: matchError } = await client
    .from("matches")
    .select(
      "id,kickoff,status,active,home_team_id,away_team_id",
    )
    .in("id", matchIds);

  if (matchError) {
    throw new Error(
      `TUTTO_BINDER_MATCH_LOAD_FAILED:${matchError.message}`,
    );
  }

  const matchById = new Map(
    (matches ?? []).map((row) => [String(row.id), row]),
  );

  const teamIds = Array.from(
    new Set(
      (matches ?? []).flatMap((row) => [
        String(row.home_team_id),
        String(row.away_team_id),
      ]),
    ),
  );

  const { data: teams, error: teamError } = await client
    .from("teams")
    .select("id,name,short_name")
    .in("id", teamIds);

  if (teamError) {
    throw new Error(
      `TUTTO_BINDER_TEAM_LOAD_FAILED:${teamError.message}`,
    );
  }

  const teamById = new Map(
    (teams ?? []).map((row) => [String(row.id), row]),
  );

  const terminalStatuses = new Set([
    "finished",
    "final",
    "cancelled",
    "awarded",
  ]);

  const result: CanonicalRoundMatch[] = [];

  for (const roundRow of roundRows ?? []) {
    const matchId = String(roundRow.match_id);
    const match = matchById.get(matchId);
    if (!match || match.active === false) {
      continue;
    }

    const status = String(match.status ?? "").toLowerCase();
    if (terminalStatuses.has(status)) {
      continue;
    }

    const home = teamById.get(String(match.home_team_id));
    const away = teamById.get(String(match.away_team_id));

    if (!home || !away) {
      throw new Error(`TUTTO_BINDER_CANONICAL_TEAM_MISSING:${matchId}`);
    }

    result.push({
      matchId,
      slotNumber: Number(roundRow.slot_number),
      kickoff: String(match.kickoff),
      status,
      homeTeamId: String(match.home_team_id),
      awayTeamId: String(match.away_team_id),
      homeName: String(home.name),
      homeShortName:
        typeof home.short_name === "string" ? home.short_name : null,
      awayName: String(away.name),
      awayShortName:
        typeof away.short_name === "string" ? away.short_name : null,
    });
  }

  return result;
}

export async function ensureTuttoilcalcioRoundBindings(input: {
  client: SupabaseClient;
  fantagolRoundId: string;
}): Promise<{
  eligibleMatchCount: number;
  alreadyMappedCount: number;
  insertedCount: number;
  unresolvedCount: number;
  ambiguousCount: number;
  discoveryErrorCount: number;
}> {
  const { client, fantagolRoundId } = input;

  const canonicalMatches = await loadCanonicalRoundMatches(
    client,
    fantagolRoundId,
  );

  if (canonicalMatches.length === 0) {
    return {
      eligibleMatchCount: 0,
      alreadyMappedCount: 0,
      insertedCount: 0,
      unresolvedCount: 0,
      ambiguousCount: 0,
      discoveryErrorCount: 0,
    };
  }

  const { data: provider, error: providerError } = await client
    .from("data_providers")
    .select("id,code,active")
    .eq("code", TUTTO_PROVIDER_CODE)
    .eq("active", true)
    .single();

  if (providerError || !provider) {
    throw new Error(
      `TUTTO_BINDER_PROVIDER_MISSING:${providerError?.message ?? "none"}`,
    );
  }

  const matchIds = canonicalMatches.map((match) => match.matchId);

  const { data: existing, error: existingError } = await client
    .from("provider_entity_maps")
    .select("internal_id,external_id,active")
    .eq("provider_id", provider.id)
    .eq("entity_type", "match")
    .in("internal_id", matchIds);

  if (existingError) {
    throw new Error(
      `TUTTO_BINDER_EXISTING_MAP_LOAD_FAILED:${existingError.message}`,
    );
  }

  const existingByInternal = new Map(
    (existing ?? [])
      .filter((row) => row.active !== false)
      .map((row) => [String(row.internal_id), String(row.external_id)]),
  );

  const missing = canonicalMatches.filter(
    (match) => !existingByInternal.has(match.matchId),
  );

  if (missing.length === 0) {
    return {
      eligibleMatchCount: canonicalMatches.length,
      alreadyMappedCount: canonicalMatches.length,
      insertedCount: 0,
      unresolvedCount: 0,
      ambiguousCount: 0,
      discoveryErrorCount: 0,
    };
  }

  const collectionByDate = new Map<string, TuttoFixtureCandidate[]>();
  const discoveryErrorByDate = new Map<string, string>();

  for (const match of missing) {
    const { date } = romeParts(match.kickoff);
    if (collectionByDate.has(date) || discoveryErrorByDate.has(date)) {
      continue;
    }

    try {
      collectionByDate.set(
        date,
        await fetchDailySerieAFixtures(date),
      );
    } catch (error) {
      const message =
        error instanceof Error ? error.message : String(error);
      discoveryErrorByDate.set(date, message);
      console.warn(
        `TUTTO_BINDER_DISCOVERY_DEFERRED:${date}:${message}`,
      );
    }
  }

  let insertedCount = 0;
  let unresolvedCount = 0;
  let ambiguousCount = 0;
  let discoveryErrorCount = 0;

  for (const match of missing) {
    const { date } = romeParts(match.kickoff);

    const discoveryError = discoveryErrorByDate.get(date);
    if (discoveryError) {
      discoveryErrorCount += 1;
      console.warn(
        `TUTTO_BINDER_MATCH_DEFERRED_DISCOVERY_ERROR:${match.matchId}:${date}`,
      );
      continue;
    }

    const candidates = collectionByDate.get(date) ?? [];
    const decision = chooseTuttoFixtureCandidate({
      canonical: match,
      candidates,
    });

    if (decision.kind === "unresolved") {
      unresolvedCount += 1;
      console.warn(
        `TUTTO_BINDER_UNRESOLVED_DEFERRED:${match.matchId}:${decision.reason}`,
      );
      continue;
    }

    if (decision.kind === "ambiguous") {
      ambiguousCount += 1;
      console.warn(
        `TUTTO_BINDER_AMBIGUOUS_DEFERRED:${match.matchId}:${decision.candidateCount}`,
      );
      continue;
    }

    const candidate = decision.candidate;

    const { data: persisted, error: persistError } = await client.rpc(
      "persist_tuttoilcalcio_match_binding_internal",
      {
        p_internal_match_id: match.matchId,
        p_external_id: candidate.externalId,
        p_external_parent_id: String(TUTTO_SERIE_A_LEAGUE_ID),
        p_metadata: {
          binding_authority: BINDING_AUTHORITY,
          provider_league_id: String(TUTTO_SERIE_A_LEAGUE_ID),
          discovery_date: date,
          kickoff_utc: match.kickoff,
          home_name: candidate.homeName,
          away_name: candidate.awayName,
          home_short_name: candidate.homeShortName,
          away_short_name: candidate.awayShortName,
          fixture_slug: candidate.slug,
          discovery_endpoint: "/api/v1/fixtures?date=YYYY-MM-DD&locale=it",
        },
      },
    );

    if (persistError) {
      throw new Error(
        `TUTTO_BINDER_PERSIST_FAILED:${match.matchId}:${persistError.message}`,
      );
    }

    if (Array.isArray(persisted) && persisted.length > 0) {
      const action = String(
        (persisted[0] as Record<string, unknown>).binding_action ?? "",
      );
      if (action === "inserted") {
        insertedCount += 1;
      }
    }
  }

  return {
    eligibleMatchCount: canonicalMatches.length,
    alreadyMappedCount: canonicalMatches.length - missing.length,
    insertedCount,
    unresolvedCount,
    ambiguousCount,
    discoveryErrorCount,
  };
}
