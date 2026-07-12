import { ProviderError } from "../core/errors";
import type {
  NormalizedCompetition,
  NormalizedEdition,
  NormalizedMatch,
  NormalizedMatchStatus,
  NormalizedProviderRound,
  NormalizedStage,
  NormalizedTeam,
} from "../types/normalized";
import type {
  FootballDataCompetition,
  FootballDataMatch,
  FootballDataSeason,
  FootballDataTeam,
} from "./types";

const PROVIDER_CODE = "football_data" as const;

export function buildEditionExternalId(
  competitionExternalId: string,
  seasonStartYear: number,
): string {
  return `${competitionExternalId}:${seasonStartYear}`;
}

export function parseEditionExternalId(value: string): {
  competitionExternalId: string;
  seasonStartYear: number;
} {
  const separatorIndex = value.lastIndexOf(":");

  if (separatorIndex <= 0) {
    throw new ProviderError({
      code: "PROVIDER_RESPONSE_INVALID",
      providerCode: PROVIDER_CODE,
      message: `Invalid football-data edition external id: ${value}`,
      retryable: false,
    });
  }

  const competitionExternalId = value.slice(0, separatorIndex);
  const seasonStartYear = Number(value.slice(separatorIndex + 1));

  if (!Number.isInteger(seasonStartYear)) {
    throw new ProviderError({
      code: "PROVIDER_RESPONSE_INVALID",
      providerCode: PROVIDER_CODE,
      message: `Invalid football-data season in edition id: ${value}`,
      retryable: false,
    });
  }

  return { competitionExternalId, seasonStartYear };
}

export function normalizeCompetition(
  competition: FootballDataCompetition,
): NormalizedCompetition {
  return {
    providerCode: PROVIDER_CODE,
    externalId: String(competition.id),
    code: competition.code || null,
    name: competition.name,
    countryCode: competition.area?.code || null,
    competitionType:
      competition.type === "LEAGUE" ? "league" : "domestic_cup",
    scope: "domestic",
    raw: competition,
  };
}

export function normalizeEdition(args: {
  competition: FootballDataCompetition;
  season: FootballDataSeason;
}): NormalizedEdition {
  const yearStart = Number(args.season.startDate.slice(0, 4));
  const yearEnd = Number(args.season.endDate.slice(0, 4));
  const now = Date.now();
  const start = Date.parse(`${args.season.startDate}T00:00:00Z`);
  const end = Date.parse(`${args.season.endDate}T23:59:59Z`);

  let status: NormalizedEdition["status"] = "scheduled";
  if (now >= start && now <= end) status = "active";
  if (now > end) status = "completed";

  return {
    providerCode: PROVIDER_CODE,
    externalId: buildEditionExternalId(
      String(args.competition.id),
      yearStart,
    ),
    competitionExternalId: String(args.competition.id),
    label: yearStart === yearEnd ? String(yearStart) : `${yearStart}/${String(yearEnd).slice(-2)}`,
    yearStart,
    yearEnd,
    startsAt: `${args.season.startDate}T00:00:00Z`,
    endsAt: `${args.season.endDate}T23:59:59Z`,
    status,
    raw: args.season,
  };
}

export function normalizeStage(
  editionExternalId: string,
): NormalizedStage {
  return {
    providerCode: PROVIDER_CODE,
    externalId: `${editionExternalId}:REGULAR_SEASON`,
    editionExternalId,
    code: "regular_season",
    name: "Regular Season",
    stageType: "regular_season",
    sequence: 1,
    raw: { providerStage: "REGULAR_SEASON" },
  };
}

export function normalizeTeam(
  team: FootballDataTeam,
  fallbackCountryCode: string | null,
): NormalizedTeam {
  return {
    providerCode: PROVIDER_CODE,
    externalId: String(team.id),
    name: team.name,
    shortName: team.shortName || null,
    code: team.tla || null,
    teamType: "club",
    countryCode: team.area?.code || fallbackCountryCode,
    crestUrl: team.crest || null,
    raw: team,
  };
}

function normalizeStatus(status: string): NormalizedMatchStatus {
  switch (status) {
    case "SCHEDULED":
    case "TIMED":
      return "scheduled";
    case "IN_PLAY":
      return "live_first_half";
    case "PAUSED":
      return "halftime";
    case "FINISHED":
      return "finished";
    case "POSTPONED":
      return "postponed";
    case "CANCELLED":
      return "cancelled";
    case "SUSPENDED":
      return "abandoned";
    default:
      return "scheduled";
  }
}

export function normalizeMatch(
  match: FootballDataMatch,
): NormalizedMatch {
  const editionExternalId = buildEditionExternalId(
    String(match.competition.id),
    Number(match.season.startDate.slice(0, 4)),
  );

  return {
    providerCode: PROVIDER_CODE,
    externalId: String(match.id),
    editionExternalId,
    stageExternalId: match.stage
      ? `${editionExternalId}:${match.stage}`
      : null,
    providerRoundExternalId:
      match.matchday === null
        ? null
        : `${editionExternalId}:matchday:${match.matchday}`,
    homeTeamExternalId: String(match.homeTeam.id),
    awayTeamExternalId: String(match.awayTeam.id),
    kickoffAt: match.utcDate,
    status: normalizeStatus(match.status),
    homeScore: match.score.fullTime.home,
    awayScore: match.score.fullTime.away,
    minute: null,
    period: match.status,
    providerUpdatedAt: match.lastUpdated,
    raw: match,
  };
}

export function normalizeRounds(args: {
  editionExternalId: string;
  matches: FootballDataMatch[];
}): NormalizedProviderRound[] {
  const grouped = new Map<number, FootballDataMatch[]>();

  for (const match of args.matches) {
    if (match.matchday === null) continue;
    const bucket = grouped.get(match.matchday) ?? [];
    bucket.push(match);
    grouped.set(match.matchday, bucket);
  }

  return [...grouped.entries()]
    .sort(([a], [b]) => a - b)
    .map(([number, matches]) => {
      const kickoffDates = matches
        .map((match) => Date.parse(match.utcDate))
        .filter(Number.isFinite);

      return {
        providerCode: PROVIDER_CODE,
        externalId: `${args.editionExternalId}:matchday:${number}`,
        editionExternalId: args.editionExternalId,
        stageExternalId: `${args.editionExternalId}:REGULAR_SEASON`,
        name: `Matchday ${number}`,
        number,
        startsAt:
          kickoffDates.length > 0
            ? new Date(Math.min(...kickoffDates)).toISOString()
            : null,
        endsAt:
          kickoffDates.length > 0
            ? new Date(Math.max(...kickoffDates)).toISOString()
            : null,
        raw: {
          matchday: number,
          matchIds: matches.map((match) => match.id),
        },
      };
    });
}
