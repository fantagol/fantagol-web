export type ProviderCode =
  | "api_football"
  | "sportmonks_football"
  | "the_odds_api";

export type NormalizedCompetition = {
  providerCode: ProviderCode;
  externalId: string;
  code: string | null;
  name: string;
  countryCode: string | null;
  competitionType: "league" | "domestic_cup" | "continental_club" | "national_team_tournament" | "qualifier" | "super_cup" | "friendly_tournament";
  scope: "domestic" | "continental" | "international";
  raw: unknown;
};

export type NormalizedEdition = {
  providerCode: ProviderCode;
  externalId: string;
  competitionExternalId: string;
  label: string;
  yearStart: number;
  yearEnd: number | null;
  startsAt: string | null;
  endsAt: string | null;
  status: "draft" | "scheduled" | "active" | "completed" | "archived" | "cancelled";
  raw: unknown;
};

export type NormalizedStage = {
  providerCode: ProviderCode;
  externalId: string;
  editionExternalId: string;
  code: string;
  name: string;
  stageType: "regular_season" | "league_phase" | "group_stage" | "playoff" | "round_of_128" | "round_of_64" | "round_of_32" | "round_of_16" | "quarter_final" | "semi_final" | "third_place" | "final" | "qualifier" | "preliminary" | "relegation" | "promotion";
  sequence: number;
  raw: unknown;
};

export type NormalizedTeam = {
  providerCode: ProviderCode;
  externalId: string;
  name: string;
  shortName: string | null;
  code: string | null;
  teamType: "club" | "national_team";
  countryCode: string | null;
  crestUrl: string | null;
  raw: unknown;
};

export type NormalizedProviderRound = {
  providerCode: ProviderCode;
  externalId: string;
  editionExternalId: string;
  stageExternalId: string | null;
  name: string;
  number: number | null;
  startsAt: string | null;
  endsAt: string | null;
  raw: unknown;
};

export type NormalizedMatchStatus =
  | "scheduled"
  | "postponed"
  | "cancelled"
  | "live_first_half"
  | "halftime"
  | "live_second_half"
  | "extra_time"
  | "penalties"
  | "finished"
  | "awarded"
  | "abandoned";

export type NormalizedMatch = {
  providerCode: ProviderCode;
  externalId: string;
  editionExternalId: string;
  stageExternalId: string | null;
  providerRoundExternalId: string | null;
  homeTeamExternalId: string;
  awayTeamExternalId: string;
  kickoffAt: string;
  status: NormalizedMatchStatus;
  homeScore: number | null;
  awayScore: number | null;
  minute: number | null;
  period: string | null;
  providerUpdatedAt: string | null;
  raw: unknown;
};

export type NormalizedOddsOutcome = {
  name: "home" | "draw" | "away";
  decimalOdds: number;
};

export type NormalizedOddsSnapshot = {
  providerCode: ProviderCode;
  matchExternalId: string;
  bookmakerExternalId: string;
  bookmakerName: string;
  market: "h2h";
  outcomes: NormalizedOddsOutcome[];
  collectedAt: string;
  raw: unknown;
};
