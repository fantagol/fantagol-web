import type {
  NormalizedMatch,
  NormalizedMatchStatus,
  ProviderCode,
} from "../providers/types/normalized";

export type LiveRuntimeChangeType =
  | "NO_CHANGE"
  | "MATCH_STATE_CHANGED"
  | "MATCH_SCORE_CHANGED"
  | "MATCH_KICKOFF_CHANGED"
  | "MATCH_POSTPONED"
  | "MATCH_CANCELLED"
  | "MATCH_FINISHED"
  | "MATCH_AWARDED";

export type LiveRuntimeMatchPhase =
  | "pre_live"
  | "live"
  | "post_live"
  | "postponed"
  | "void";

export type LiveRuntimePollingBand =
  | "dormant"
  | "day_ahead"
  | "approaching"
  | "imminent"
  | "live"
  | "halftime"
  | "post_live_stabilizing"
  | "post_live_stable"
  | "stopped";

export type RuntimeNormalizedMatchUpdate = {
  providerCode: ProviderCode;
  externalMatchId: string;
  editionExternalId: string;
  stageExternalId: string | null;
  providerRoundExternalId: string | null;
  homeTeamExternalId: string;
  awayTeamExternalId: string;
  kickoffAt: string;
  status: NormalizedMatchStatus;
  matchPhase: LiveRuntimeMatchPhase;
  homeScore: number | null;
  awayScore: number | null;
  minute: number | null;
  period: string | null;
  providerUpdatedAt: string;
  receivedAt: string;
  normalizedPayload: Record<string, unknown>;
};

export type RuntimePersistedMatchState = Pick<
  RuntimeNormalizedMatchUpdate,
  | "kickoffAt"
  | "status"
  | "homeScore"
  | "awayScore"
  | "minute"
  | "period"
  | "providerUpdatedAt"
>;

export type LiveRuntimeChangeDetection = {
  meaningfulChange: boolean;
  changeType: LiveRuntimeChangeType;
  changedFields: Array<
    | "status"
    | "score"
    | "kickoffAt"
    | "minute"
    | "period"
    | "providerUpdatedAt"
  >;
  previous: RuntimePersistedMatchState | null;
  current: RuntimeNormalizedMatchUpdate;
};

export type PollingPolicyInput = {
  status: NormalizedMatchStatus;
  kickoffAt: string;
  now?: Date;
  postLiveStable?: boolean;
  roundCertified?: boolean;
};

export type PollingPolicyDecision = {
  band: LiveRuntimePollingBand;
  intervalSeconds: number | null;
  shouldPoll: boolean;
  reason: string;
};

export type LiveProviderMatch = NormalizedMatch;
