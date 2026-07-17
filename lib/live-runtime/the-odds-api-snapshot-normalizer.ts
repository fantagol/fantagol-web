import {
  buildOneXTwoConsensus,
  createCanonicalBookmakerOneXTwo,
  type CanonicalBookmakerOneXTwo,
  type CanonicalOddsSnapshot,
} from "./odds-snapshot";

type UnknownRecord = Record<string, unknown>;

function isRecord(value: unknown): value is UnknownRecord {
  return typeof value === "object" && value !== null;
}

function requiredString(record: UnknownRecord, field: string): string {
  const value = record[field];
  if (typeof value !== "string" || value.trim() === "") {
    throw new Error(`Missing or invalid '${field}' in The Odds API payload.`);
  }
  return value.trim();
}

function optionalString(
  record: UnknownRecord,
  field: string,
): string | null {
  const value = record[field];
  return typeof value === "string" && value.trim() !== ""
    ? value.trim()
    : null;
}

function outcomePrice(outcomes: unknown[], name: string): number | null {
  for (const candidate of outcomes) {
    if (!isRecord(candidate) || candidate.name !== name) continue;
    const price = candidate.price;
    return typeof price === "number" && Number.isFinite(price)
      ? price
      : null;
  }
  return null;
}

function extractEventOdds(payload: unknown): UnknownRecord {
  if (!isRecord(payload) || !isRecord(payload.eventOdds)) {
    throw new Error("Missing eventOdds in The Odds API provider payload.");
  }
  return payload.eventOdds;
}

export function normalizeTheOddsApiSnapshot(input: {
  providerCode: string;
  externalMatchId: string;
  fetchedAt: string;
  payload: unknown;
}): CanonicalOddsSnapshot {
  const event = extractEventOdds(input.payload);
  const homeTeam = requiredString(event, "home_team");
  const awayTeam = requiredString(event, "away_team");
  const rows = Array.isArray(event.bookmakers) ? event.bookmakers : [];
  const bookmakers: CanonicalBookmakerOneXTwo[] = [];

  for (const candidate of rows) {
    if (!isRecord(candidate)) continue;

    const markets = Array.isArray(candidate.markets) ? candidate.markets : [];
    const h2h = markets.find(
      (market) => isRecord(market) && market.key === "h2h",
    );

    if (!isRecord(h2h) || !Array.isArray(h2h.outcomes)) continue;

    const home = outcomePrice(h2h.outcomes, homeTeam);
    const draw = outcomePrice(h2h.outcomes, "Draw");
    const away = outcomePrice(h2h.outcomes, awayTeam);

    if (home === null || draw === null || away === null) continue;

    try {
      bookmakers.push(createCanonicalBookmakerOneXTwo({
        bookmakerKey: requiredString(candidate, "key"),
        bookmakerTitle: requiredString(candidate, "title"),
        lastUpdate: optionalString(candidate, "last_update"),
        home,
        draw,
        away,
      }));
    } catch {
      // Exclude only the malformed bookmaker and retain valid peers.
    }
  }

  const consensus = buildOneXTwoConsensus(bookmakers);

  return {
    schemaVersion: "fantagol_odds_snapshot_v1",
    providerCode: input.providerCode,
    externalMatchId: input.externalMatchId,
    homeTeam,
    awayTeam,
    commenceTime: optionalString(event, "commence_time"),
    collectedAt: input.fetchedAt,
    market: "h2h",
    oddsFormat: "decimal",
    bookmakers,
    consensus,
    quality: {
      validBookmakers: bookmakers.length,
      hasConsensus: consensus !== null,
      reason: consensus === null
        ? "no_complete_h2h_bookmaker_market"
        : null,
    },
  };
}
