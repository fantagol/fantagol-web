import type {
  LiveRuntimeAuthorityState,
} from "./live-primary-authority";

export type FootballDataAuthorityWindow =
  | "pre_live"
  | "awaiting_official"
  | "blocked";

const TUTTO_ACTIVE_LIVE_PHASES =
  new Set<
    LiveRuntimeAuthorityState["phase"]
  >([
    "FIRST_HALF",
    "HALFTIME",
    "SECOND_HALF",
  ]);

const FOOTBALL_DATA_OPERATIONAL_LIVE_STATUSES =
  new Set([
    "live",
    "in_play",
    "live_first_half",
    "halftime",
    "live_second_half",
    "extra_time",
    "penalties",
  ]);

const FOOTBALL_DATA_OFFICIAL_TERMINAL_STATUSES =
  new Set([
    "finished",
    "awarded",
  ]);

export function isTuttoActiveLiveAuthority(
  authority:
    LiveRuntimeAuthorityState | null,
): boolean {
  return (
    authority?.authority === "primary_live" &&
    authority.source === "tuttoilcalcio" &&
    TUTTO_ACTIVE_LIVE_PHASES.has(
      authority.phase,
    )
  );
}

export function isTuttoTerminalPendingAuthority(
  authority:
    LiveRuntimeAuthorityState | null,
): boolean {
  return (
    authority?.authority === "primary_live" &&
    authority.source === "tuttoilcalcio" &&
    authority.phase === "END_PENDING"
  );
}

export function isFootballDataOperationalLiveStatus(
  status: string,
): boolean {
  return (
    FOOTBALL_DATA_OPERATIONAL_LIVE_STATUSES
      .has(status)
  );
}

export function isFootballDataOfficialTerminalStatus(
  status: string,
): boolean {
  return (
    FOOTBALL_DATA_OFFICIAL_TERMINAL_STATUSES
      .has(status)
  );
}

/**
 * Exclusive provider ownership contract.
 *
 * Football-Data:
 *   - PRE-LIVE only before kickoff;
 *   - blocked from kickoff through Tutto operational LIVE;
 *   - re-enters only when Tutto is END_PENDING, exclusively to obtain the
 *     official terminal result/evidence used by FantaGol certification.
 *
 * There is deliberately no automatic degraded-live fallback.
 */
export function resolveFootballDataAuthorityWindow(
  input: {
    authority:
      LiveRuntimeAuthorityState | null;
    kickoffAt: string;
    now: Date;
  },
): FootballDataAuthorityWindow {
  if (
    input.authority?.authority ===
    "degraded_live"
  ) {
    return "blocked";
  }

  if (
    isTuttoTerminalPendingAuthority(
      input.authority,
    )
  ) {
    return "awaiting_official";
  }

  if (
    isTuttoActiveLiveAuthority(
      input.authority,
    )
  ) {
    return "blocked";
  }

  /*
   * Any unexpected primary-live owner fails closed. Tutto PRE_MATCH should
   * normally not promote primary_live at all; if it ever does, Football-Data
   * must not silently become a concurrent writer.
   */
  if (
    input.authority?.authority ===
    "primary_live"
  ) {
    return "blocked";
  }

  const kickoffMs =
    Date.parse(input.kickoffAt);

  if (!Number.isFinite(kickoffMs)) {
    return "blocked";
  }

  return (
    input.now.getTime() < kickoffMs
      ? "pre_live"
      : "blocked"
  );
}
export type FootballDataIngestionAdmission =
  | "allow_pre_live"
  | "allow_official_terminal"
  | "suppress";

export function resolveFootballDataIngestionAdmission(
  input: {
    authority:
      LiveRuntimeAuthorityState | null;
    kickoffAt: string;
    receivedAt: Date;
    normalizedStatus: string;
  },
): FootballDataIngestionAdmission {
  const window =
    resolveFootballDataAuthorityWindow({
      authority: input.authority,
      kickoffAt: input.kickoffAt,
      now: input.receivedAt,
    });

  if (window === "blocked") {
    return "suppress";
  }

  if (window === "awaiting_official") {
    return (
      isFootballDataOfficialTerminalStatus(
        input.normalizedStatus,
      )
        ? "allow_official_terminal"
        : "suppress"
    );
  }

  /*
   * PRE-LIVE accepts schedule/kickoff/postponement/cancellation evidence,
   * but never a provisional LIVE state or an official terminal result.
   */
  if (
    isFootballDataOperationalLiveStatus(
      input.normalizedStatus,
    ) ||
    isFootballDataOfficialTerminalStatus(
      input.normalizedStatus,
    )
  ) {
    return "suppress";
  }

  return "allow_pre_live";
}