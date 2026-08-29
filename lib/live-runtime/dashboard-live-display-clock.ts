export type DashboardLiveClockInput = {
  status: string | null | undefined;
  providerMinute?: number | null;
  kickoffAt?: string | null;
  livePhaseStartedAt?: string | null;
  liveHalf?: number | null;
  now?: Date;
};

export type DashboardLiveClockResult = {
  status: string;
  minute: number | null;
  label: string;
  source: "provider" | "synthetic" | "status" | "kickoff";
};

function normalizeStatus(value: string | null | undefined) {
  return String(value || "").trim().toLowerCase();
}

function parseIso(value: string | null | undefined) {
  if (!value) return null;
  const ms = Date.parse(value);
  return Number.isFinite(ms) ? ms : null;
}

function elapsedWholeMinutes(fromMs: number, toMs: number) {
  return Math.max(0, Math.floor((toMs - fromMs) / 60000));
}

function formatMinute(minute: number, liveHalf: number | null | undefined) {
  if (minute > 90) {
    return `90+${minute - 90}′`;
  }

  if (liveHalf === 1 && minute > 45) {
    return `45+${minute - 45}′`;
  }

  return `${minute}′`;
}

export function resolveDashboardLiveDisplayClock(
  input: DashboardLiveClockInput,
): DashboardLiveClockResult {
  const status = normalizeStatus(input.status);
  const now = input.now ?? new Date();

  if (status === "finished" || status === "awarded") {
    return { status, minute: null, label: "FT", source: "status" };
  }

  if (status === "halftime" || status === "paused") {
    return { status, minute: 45, label: "HT", source: "status" };
  }

  const activelyPlaying =
    status.startsWith("live_") ||
    status === "live" ||
    status === "in_play" ||
    status === "extra_time" ||
    status === "penalties";

  if (!activelyPlaying) {
    return { status, minute: null, label: "", source: "kickoff" };
  }


  const nowMs = now.getTime();

  if (input.liveHalf === 2) {
    const phaseStartMs = parseIso(input.livePhaseStartedAt);
    if (phaseStartMs !== null) {
      const syntheticMinute = 46 + elapsedWholeMinutes(phaseStartMs, nowMs);
      return {
        status,
        minute: syntheticMinute,
        label: formatMinute(syntheticMinute, 2),
        source: "synthetic",
      };
    }
  }

  const kickoffMs = parseIso(input.kickoffAt);
  if (kickoffMs !== null) {
    const syntheticMinute = 1 + elapsedWholeMinutes(kickoffMs, nowMs);
    return {
      status,
      minute: syntheticMinute,
      label: formatMinute(syntheticMinute, 1),
      source: "synthetic",
    };
  }


  if (
    Number.isInteger(input.providerMinute) &&
    Number(input.providerMinute) > 0
  ) {
    const minute = Number(input.providerMinute);
    return {
      status,
      minute,
      label: formatMinute(minute, input.liveHalf),
      source: "provider",
    };
  }

  return { status, minute: null, label: "LIVE", source: "status" };
}