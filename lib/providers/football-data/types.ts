export type FootballDataArea = {
  id: number;
  name: string;
  code: string | null;
  flag?: string | null;
};

export type FootballDataCompetition = {
  area: FootballDataArea;
  id: number;
  name: string;
  code: string;
  type: string;
  emblem: string | null;
  currentSeason?: FootballDataSeason | null;
  seasons?: FootballDataSeason[];
  lastUpdated?: string | null;
};

export type FootballDataSeason = {
  id: number;
  startDate: string;
  endDate: string;
  currentMatchday: number | null;
  winner: unknown | null;
};

export type FootballDataTeam = {
  area?: FootballDataArea;
  id: number;
  name: string;
  shortName: string | null;
  tla: string | null;
  crest: string | null;
  address?: string | null;
  website?: string | null;
  founded?: number | null;
  clubColors?: string | null;
  venue?: string | null;
  runningCompetitions?: Array<{
    id: number;
    name: string;
    code: string;
    type: string;
    emblem: string | null;
  }>;
  lastUpdated?: string | null;
};

export type FootballDataScore = {
  winner: "HOME_TEAM" | "AWAY_TEAM" | "DRAW" | null;
  duration: string;
  fullTime: {
    home: number | null;
    away: number | null;
  };
  halfTime: {
    home: number | null;
    away: number | null;
  };
};

export type FootballDataMatch = {
  area: FootballDataArea;
  competition: Pick<
    FootballDataCompetition,
    "id" | "name" | "code" | "type" | "emblem"
  >;
  season: FootballDataSeason;
  id: number;
  utcDate: string;
  status: string;
  matchday: number | null;
  stage: string | null;
  group: string | null;
  lastUpdated: string | null;
  homeTeam: FootballDataTeam;
  awayTeam: FootballDataTeam;
  score: FootballDataScore;
  odds?: unknown;
  referees?: unknown[];
};

export type FootballDataTeamsResponse = {
  count: number;
  filters: {
    season?: number;
  };
  competition: FootballDataCompetition;
  season: FootballDataSeason;
  teams: FootballDataTeam[];
};

export type FootballDataMatchesResponse = {
  filters: {
    season?: number;
    status?: string[];
  };
  resultSet: {
    count: number;
    first: string | null;
    last: string | null;
    played: number;
  };
  competition?: FootballDataCompetition;
  matches: FootballDataMatch[];
};
