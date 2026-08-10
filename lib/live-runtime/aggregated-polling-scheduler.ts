export type AggregatedPollingTarget = {
  providerCode: string;
  externalMatchId: string;
  kickoffAt: string;

  /**
   * Canonical/internal Match status when available.
   *
   * live / in_play / paused:
   *   belongs to the LIVE aggregate request.
   *
   * scheduled / timed / postponed / suspended / cancelled:
   *   remains observable through PREMATCH/date-window collection
   *   until the scheduler removes it from its active target set.
   */
  matchStatus?: string;
};

export type AggregatedPollingPlan =
  | {
      mode: "live";
      providerCode: string;
      externalMatchIds: string[];
      competitionCode: string;
    }
  | {
      mode: "prematch";
      providerCode: string;
      externalMatchIds: string[];
      competitionCode: string;
      dateFrom: string;
      dateTo: string;
    };

function toIsoDate(
  value: string,
): string {
  return value.slice(0, 10);
}

function addUtcDays(
  isoDate: string,
  days: number,
): string {
  const date =
    new Date(
      `${isoDate}T00:00:00.000Z`,
    );

  date.setUTCDate(
    date.getUTCDate() + days,
  );

  return date
    .toISOString()
    .slice(0, 10);
}

function isLiveStatus(
  value: string | undefined,
): boolean {
  if (!value) {
    return false;
  }

  const normalized =
    value
      .trim()
      .toLowerCase();

  return (
    normalized === "live" ||
    normalized === "in_play" ||
    normalized === "paused" ||
    normalized === "live_first_half" ||
    normalized === "live_second_half" ||
    normalized === "extra_time" ||
    normalized === "penalties"
  );
}

function uniqueExternalIds(
  targets: AggregatedPollingTarget[],
): string[] {
  return [
    ...new Set(
      targets.map(
        (target) =>
          target.externalMatchId,
      ),
    ),
  ];
}

function buildPrematchPlan(input: {
  providerCode: string;
  targets: AggregatedPollingTarget[];
  competitionCode: string;
}): AggregatedPollingPlan | null {
  if (input.targets.length === 0) {
    return null;
  }

  const kickoffDates =
    input.targets
      .map(
        (target) =>
          toIsoDate(
            target.kickoffAt,
          ),
      )
      .sort();

  const dateFrom =
    kickoffDates[0];

  const lastKickoffDate =
    kickoffDates[
      kickoffDates.length - 1
    ];

  if (
    !dateFrom ||
    !lastKickoffDate
  ) {
    return null;
  }

  return {
    mode: "prematch",
    providerCode:
      input.providerCode,
    externalMatchIds:
      uniqueExternalIds(
        input.targets,
      ),
    competitionCode:
      input.competitionCode,
    dateFrom,
    /*
     * Football Data dateTo is the upper boundary of the requested
     * calendar window. Extend one UTC day past the final kickoff date
     * so the final scheduled date remains inside the collection.
     */
    dateTo:
      addUtcDays(
        lastKickoffDate,
        1,
      ),
  };
}

/**
 * Canonical dual aggregate planner.
 *
 * A Serie A round can span several calendar days.
 *
 * Therefore LIVE and PREMATCH are NOT mutually exclusive:
 *
 *   LIVE:
 *     Match targets explicitly known as live/in_play/paused.
 *
 *   PREMATCH:
 *     every remaining active target.
 *
 * This allows a Saturday live Match to be followed while Sunday/Monday
 * fixtures remain observed for kickoff/status changes.
 */
export function buildAggregatedPollingPlans(input: {
  providerCode: string;
  targets: AggregatedPollingTarget[];
  now: Date;
  competitionCode?: string;
}): AggregatedPollingPlan[] {
  if (input.targets.length === 0) {
    return [];
  }

  const competitionCode =
    input.competitionCode ?? "SA";

  const liveTargets =
    input.targets.filter(
      (target) =>
        isLiveStatus(
          target.matchStatus,
        ),
    );

  const prematchTargets =
    input.targets.filter(
      (target) =>
        !isLiveStatus(
          target.matchStatus,
        ),
    );

  const plans:
    AggregatedPollingPlan[] = [];

  if (liveTargets.length > 0) {
    plans.push({
      mode: "live",
      providerCode:
        input.providerCode,
      externalMatchIds:
        uniqueExternalIds(
          liveTargets,
        ),
      competitionCode,
    });
  }

  const prematchPlan =
    buildPrematchPlan({
      providerCode:
        input.providerCode,
      targets:
        prematchTargets,
      competitionCode,
    });

  if (prematchPlan) {
    plans.push(
      prematchPlan,
    );
  }

  return plans;
}

/**
 * Compatibility helper retained for callers created during A8D.6.2.
 *
 * It returns the first canonical plan only.
 * Production scheduling must migrate to buildAggregatedPollingPlans()
 * before activation.
 */
export function buildAggregatedPollingPlan(input: {
  providerCode: string;
  targets: AggregatedPollingTarget[];
  now: Date;
  competitionCode?: string;
}): AggregatedPollingPlan | null {
  return (
    buildAggregatedPollingPlans(
      input,
    )[0] ?? null
  );
}