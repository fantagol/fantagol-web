import { createHash } from "node:crypto";

export type TuttoilcalcioPhase =
  | "PRE_MATCH"
  | "FIRST_HALF"
  | "HALFTIME"
  | "SECOND_HALF"
  | "END_PENDING";

export type TuttoilcalcioLiveObservation = {
  source: "tuttoilcalcio";
  sourceFixtureId: string;
  observedAt: string;
  sourceStatus: string;
  phase: TuttoilcalcioPhase;
  minute: number | null;
  homeScore: number;
  awayScore: number;
  terminalHint: boolean;
  payloadHash: string;
  payload: unknown;
};

type UnknownRecord = Record<string, unknown>;

function asRecord(value: unknown): UnknownRecord | null {
  return value && typeof value === "object" && !Array.isArray(value)
    ? (value as UnknownRecord)
    : null;
}

function asFiniteInteger(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value)) {
    return Math.trunc(value);
  }

  if (typeof value === "string" && value.trim() !== "") {
    const parsed = Number(value);
    if (Number.isFinite(parsed)) {
      return Math.trunc(parsed);
    }
  }

  return null;
}

function readScore(payload: UnknownRecord, side: "home" | "away"): number {
  const directCandidates =
    side === "home"
      ? ["home_score", "homeScore", "score_home", "scoreHome"]
      : ["away_score", "awayScore", "score_away", "scoreAway"];

  for (const key of directCandidates) {
    const value = asFiniteInteger(payload[key]);
    if (value !== null && value >= 0) {
      return value;
    }
  }

  const scores = asRecord(payload.scores ?? payload.score);
  if (scores) {
    const nestedCandidates =
      side === "home"
        ? ["home", "home_score", "homeScore"]
        : ["away", "away_score", "awayScore"];

    for (const key of nestedCandidates) {
      const value = asFiniteInteger(scores[key]);
      if (value !== null && value >= 0) {
        return value;
      }
    }
  }

  throw new Error(`TUTTOILCALCIO_${side.toUpperCase()}_SCORE_MISSING`);
}

function normalizeStatus(payload: UnknownRecord): string {
  const raw =
    payload.status ??
    payload.state ??
    payload.match_status ??
    payload.matchStatus ??
    "";

  return String(raw).trim().toLowerCase();
}

function normalizeMinute(payload: UnknownRecord): number | null {
  const value =
    asFiniteInteger(payload.minute) ??
    asFiniteInteger(payload.match_minute) ??
    asFiniteInteger(payload.matchMinute);

  return value !== null && value >= 0 ? value : null;
}

function normalizePhase(
  status: string,
  minute: number | null,
): TuttoilcalcioPhase {
  if (
    status === "closed" ||
    status === "ended" ||
    status === "ft" ||
    status === "finished" ||
    status === "full_time"
  ) {
    return "END_PENDING";
  }

  if (
    status === "ht" ||
    status === "halftime" ||
    status === "half_time" ||
    status === "paused"
  ) {
    return "HALFTIME";
  }

  if (
    status === "not_started" ||
    status === "scheduled" ||
    status === "timed"
  ) {
    return "PRE_MATCH";
  }

  if (status === "live" || status === "in_play" || status === "inplay") {
    return minute !== null && minute >= 46
      ? "SECOND_HALF"
      : "FIRST_HALF";
  }

  // Unknown status is not silently promoted to LIVE.
  throw new Error(`TUTTOILCALCIO_UNSUPPORTED_STATUS:${status || "<empty>"}`);
}

function findFixtureId(payload: UnknownRecord): string {
  const candidates = [
    payload.id,
    payload.fixture_id,
    payload.fixtureId,
    asRecord(payload.fixture)?.id,
  ];

  for (const candidate of candidates) {
    if (
      typeof candidate === "string" ||
      typeof candidate === "number"
    ) {
      return String(candidate);
    }
  }

  throw new Error("TUTTOILCALCIO_FIXTURE_ID_MISSING");
}

export function normalizeTuttoilcalcioFixture(
  rawPayload: unknown,
  observedAt = new Date(),
): TuttoilcalcioLiveObservation {
  const payload = asRecord(rawPayload);
  if (!payload) {
    throw new Error("TUTTOILCALCIO_INVALID_PAYLOAD");
  }

  const sourceFixtureId = findFixtureId(payload);
  const sourceStatus = normalizeStatus(payload);
  const minute = normalizeMinute(payload);
  const phase = normalizePhase(sourceStatus, minute);
  const homeScore = readScore(payload, "home");
  const awayScore = readScore(payload, "away");

  const canonicalPayload = JSON.stringify(rawPayload);
  const payloadHash = createHash("sha256")
    .update(canonicalPayload)
    .digest("hex");

  return {
    source: "tuttoilcalcio",
    sourceFixtureId,
    observedAt: observedAt.toISOString(),
    sourceStatus,
    phase,
    minute,
    homeScore,
    awayScore,
    terminalHint: phase === "END_PENDING",
    payloadHash,
    payload: rawPayload,
  };
}

export async function fetchTuttoilcalcioFixture(
  sourceFixtureId: string,
  options?: {
    signal?: AbortSignal;
    locale?: string;
    baseUrl?: string;
  },
): Promise<TuttoilcalcioLiveObservation> {
  const baseUrl = options?.baseUrl ?? "https://tuttoilcalcio.com";
  const locale = options?.locale ?? "it";
  const url =
    `${baseUrl}/api/v1/fixtures/${encodeURIComponent(sourceFixtureId)}` +
    `?locale=${encodeURIComponent(locale)}`;

  const response = await fetch(url, {
    method: "GET",
    headers: {
      accept: "application/json",
    },
    cache: "no-store",
    signal: options?.signal,
  });

  if (!response.ok) {
    throw new Error(
      `TUTTOILCALCIO_HTTP_${response.status}:${sourceFixtureId}`,
    );
  }

  const payload: unknown = await response.json();
  return normalizeTuttoilcalcioFixture(payload, new Date());
}
