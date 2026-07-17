import type {
  NormalizedMatch,
  NormalizedMatchStatus,
} from "../providers/types/normalized";
import { LiveRuntimeError } from "./errors";
import type {
  LiveRuntimeMatchPhase,
  RuntimeNormalizedMatchUpdate,
} from "./types";

const LIVE_STATUSES = new Set<NormalizedMatchStatus>([
  "live_first_half",
  "halftime",
  "live_second_half",
  "extra_time",
  "penalties",
]);

const POST_LIVE_STATUSES = new Set<NormalizedMatchStatus>([
  "finished",
  "awarded",
]);

function requireIsoDate(value: string, field: string): string {
  const date = new Date(value);

  if (Number.isNaN(date.getTime())) {
    throw new LiveRuntimeError({
      code: "LIVE_RUNTIME_INVALID_DATE",
      message: `Invalid ${field}: ${value}`,
      details: { field, value },
    });
  }

  return date.toISOString();
}

function optionalIsoDate(
  value: string | null,
  fallback: string,
): string {
  return value ? requireIsoDate(value, "providerUpdatedAt") : fallback;
}

function validateScore(
  value: number | null,
  field: "homeScore" | "awayScore",
): number | null {
  if (value === null) {
    return null;
  }

  if (!Number.isInteger(value) || value < 0) {
    throw new LiveRuntimeError({
      code: "LIVE_RUNTIME_INVALID_SCORE",
      message: `${field} must be a non-negative integer or null`,
      details: { field, value },
    });
  }

  return value;
}

export function mapMatchPhase(
  status: NormalizedMatchStatus,
): LiveRuntimeMatchPhase {
  if (LIVE_STATUSES.has(status)) {
    return "live";
  }

  if (POST_LIVE_STATUSES.has(status)) {
    return "post_live";
  }

  if (status === "postponed") {
    return "postponed";
  }

  if (status === "cancelled" || status === "abandoned") {
    return "void";
  }

  return "pre_live";
}

/**
 * Converts the provider-level NormalizedMatch into the stable payload accepted
 * by the Live Runtime receipt layer. It intentionally excludes provider `raw`
 * data from the canonical payload used by downstream change detection.
 */
export function normalizeLiveMatchUpdate(
  match: NormalizedMatch,
  receivedAt = new Date(),
): RuntimeNormalizedMatchUpdate {
  if (
    !match.externalId.trim() ||
    !match.homeTeamExternalId.trim() ||
    !match.awayTeamExternalId.trim()
  ) {
    throw new LiveRuntimeError({
      code: "LIVE_RUNTIME_INVALID_MATCH",
      message: "Live match identity is incomplete",
      details: {
        externalId: match.externalId,
        homeTeamExternalId: match.homeTeamExternalId,
        awayTeamExternalId: match.awayTeamExternalId,
      },
    });
  }

  const canonicalReceivedAt = requireIsoDate(
    receivedAt.toISOString(),
    "receivedAt",
  );
  const kickoffAt = requireIsoDate(match.kickoffAt, "kickoffAt");
  const providerUpdatedAt = optionalIsoDate(
    match.providerUpdatedAt,
    canonicalReceivedAt,
  );
  const homeScore = validateScore(match.homeScore, "homeScore");
  const awayScore = validateScore(match.awayScore, "awayScore");

  if (
    (homeScore === null) !== (awayScore === null)
  ) {
    throw new LiveRuntimeError({
      code: "LIVE_RUNTIME_INVALID_SCORE",
      message: "Home and away scores must both be null or both be present",
      details: { homeScore, awayScore },
    });
  }

  const normalizedPayload: Record<string, unknown> = {
    provider_code: match.providerCode,
    external_match_id: match.externalId,
    edition_external_id: match.editionExternalId,
    stage_external_id: match.stageExternalId,
    provider_round_external_id: match.providerRoundExternalId,
    home_team_external_id: match.homeTeamExternalId,
    away_team_external_id: match.awayTeamExternalId,
    kickoff_at: kickoffAt,
    status: match.status,
    match_phase: mapMatchPhase(match.status),
    home_score: homeScore,
    away_score: awayScore,
    minute: match.minute,
    period: match.period,
    provider_updated_at: providerUpdatedAt,
  };

  return {
    providerCode: match.providerCode,
    externalMatchId: match.externalId,
    editionExternalId: match.editionExternalId,
    stageExternalId: match.stageExternalId,
    providerRoundExternalId: match.providerRoundExternalId,
    homeTeamExternalId: match.homeTeamExternalId,
    awayTeamExternalId: match.awayTeamExternalId,
    kickoffAt,
    status: match.status,
    matchPhase: mapMatchPhase(match.status),
    homeScore,
    awayScore,
    minute: match.minute,
    period: match.period,
    providerUpdatedAt,
    receivedAt: canonicalReceivedAt,
    normalizedPayload,
  };
}
