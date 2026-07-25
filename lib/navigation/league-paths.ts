export type LeagueScopedDestination =
  | "dashboard"
  | "round"
  | "fantasy"
  | "oneToOne"
  | "settings"
  | "calendar"
  | "rankings"
  | "members"
  | "statistics";

function normalizeRouteSegment(value: string, label: string): string {
  const normalized = value.trim();

  if (!normalized) {
    throw new Error(`A non-empty ${label} is required to build the route.`);
  }

  return encodeURIComponent(normalized);
}

function leagueBasePath(leagueId: string): string {
  return `/leghe/${normalizeRouteSegment(leagueId, "league id")}`;
}

export const leaguePath = {
  dashboard: (leagueId: string): string => leagueBasePath(leagueId),

  round: (leagueId: string): string => `${leagueBasePath(leagueId)}/giornata`,

  fantasy: (leagueId: string): string =>
    `${leagueBasePath(leagueId)}/fantacalcio`,

  oneToOne: (leagueId: string): string =>
    `${leagueBasePath(leagueId)}/onetoone`,

  settings: (leagueId: string): string =>
    `${leagueBasePath(leagueId)}/impostazioni`,

  calendar: (leagueId: string): string =>
    `${leagueBasePath(leagueId)}/calendario`,

  rankings: (leagueId: string): string =>
    `${leagueBasePath(leagueId)}/classifiche`,

  members: (leagueId: string): string => `${leagueBasePath(leagueId)}/membri`,

  statistics: (leagueId: string): string =>
    `${leagueBasePath(leagueId)}/statistiche`,

  memberStatistics: (leagueId: string, memberId: string): string =>
    `${leagueBasePath(leagueId)}/statistiche/${normalizeRouteSegment(
      memberId,
      "member id",
    )}`,
} as const;

export function getLeaguePath(
  destination: LeagueScopedDestination,
  leagueId: string,
): string {
  return leaguePath[destination](leagueId);
}
