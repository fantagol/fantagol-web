import { strict as assert } from "node:assert";

import {
  isFootballDataOfficialTerminalStatus,
  isFootballDataOperationalLiveStatus,
  isTuttoActiveLiveAuthority,
  isTuttoTerminalPendingAuthority,
  resolveFootballDataAuthorityWindow,
  resolveFootballDataIngestionAdmission,
} from "./football-data-authority-policy";
import type {
  LiveRuntimeAuthorityState,
} from "./live-primary-authority";

function authority(
  input: Partial<LiveRuntimeAuthorityState> &
    Pick<
      LiveRuntimeAuthorityState,
      "authority" | "source" | "phase"
    >,
): LiveRuntimeAuthorityState {
  return {
    match_id: "match-1",
    source_observation_id: "observation-1",
    minute: null,
    home_score: 0,
    away_score: 0,
    observed_at: "2026-09-18T18:45:00Z",
    version: 1,
    ...input,
  };
}

const kickoffAt =
  "2026-09-18T18:45:00Z";

assert.equal(
  resolveFootballDataAuthorityWindow({
    authority: null,
    kickoffAt,
    now:
      new Date("2026-09-18T18:44:59Z"),
  }),
  "pre_live",
);

assert.equal(
  resolveFootballDataAuthorityWindow({
    authority: null,
    kickoffAt,
    now:
      new Date("2026-09-18T18:45:00Z"),
  }),
  "blocked",
);

/*
 * A PRE-LIVE FD job can already be queued before kickoff. If it executes at
 * kickoff or later, it must be suppressed even when Tutto primary_live has
 * not been persisted yet.
 */
assert.equal(
  resolveFootballDataIngestionAdmission({
    authority: null,
    kickoffAt,
    receivedAt:
      new Date("2026-09-18T18:44:59Z"),
    normalizedStatus:
      "scheduled",
  }),
  "allow_pre_live",
);

assert.equal(
  resolveFootballDataIngestionAdmission({
    authority: null,
    kickoffAt,
    receivedAt:
      new Date("2026-09-18T18:45:00Z"),
    normalizedStatus:
      "scheduled",
  }),
  "suppress",
);

for (
  const phase of [
    "FIRST_HALF",
    "HALFTIME",
    "SECOND_HALF",
  ] as const
) {
  const active =
    authority({
      authority: "primary_live",
      source: "tuttoilcalcio",
      phase,
    });

  assert.equal(
    isTuttoActiveLiveAuthority(active),
    true,
  );

  assert.equal(
    resolveFootballDataAuthorityWindow({
      authority: active,
      kickoffAt,
      now:
        new Date("2026-09-18T19:00:00Z"),
    }),
    "blocked",
  );
}

const terminal =
  authority({
    authority: "primary_live",
    source: "tuttoilcalcio",
    phase: "END_PENDING",
  });

assert.equal(
  isTuttoTerminalPendingAuthority(
    terminal,
  ),
  true,
);

assert.equal(
  resolveFootballDataAuthorityWindow({
    authority: terminal,
    kickoffAt,
    now:
      new Date("2026-09-18T20:40:00Z"),
  }),
  "awaiting_official",
);

assert.equal(
  resolveFootballDataIngestionAdmission({
    authority: terminal,
    kickoffAt,
    receivedAt:
      new Date("2026-09-18T20:40:00Z"),
    normalizedStatus:
      "live_second_half",
  }),
  "suppress",
);

assert.equal(
  resolveFootballDataIngestionAdmission({
    authority: terminal,
    kickoffAt,
    receivedAt:
      new Date("2026-09-18T20:40:00Z"),
    normalizedStatus:
      "finished",
  }),
  "allow_official_terminal",
);

const degraded =
  authority({
    authority: "degraded_live",
    source: "football_data",
    phase: "SECOND_HALF",
  });

assert.equal(
  resolveFootballDataAuthorityWindow({
    authority: degraded,
    kickoffAt,
    now:
      new Date("2026-09-18T19:30:00Z"),
  }),
  "blocked",
);

const unexpectedFootballDataPrimary =
  authority({
    authority: "primary_live",
    source: "football_data",
    phase: "FIRST_HALF",
  });

assert.equal(
  resolveFootballDataAuthorityWindow({
    authority:
      unexpectedFootballDataPrimary,
    kickoffAt,
    now:
      new Date("2026-09-18T18:40:00Z"),
  }),
  "blocked",
);

assert.equal(
  resolveFootballDataAuthorityWindow({
    authority: null,
    kickoffAt: "NOT_A_DATE",
    now:
      new Date("2026-09-18T18:00:00Z"),
  }),
  "blocked",
);

for (
  const status of [
    "live",
    "in_play",
    "live_first_half",
    "halftime",
    "live_second_half",
    "extra_time",
    "penalties",
  ]
) {
  assert.equal(
    isFootballDataOperationalLiveStatus(
      status,
    ),
    true,
  );
}

assert.equal(
  isFootballDataOperationalLiveStatus(
    "scheduled",
  ),
  false,
);

assert.equal(
  isFootballDataOfficialTerminalStatus(
    "finished",
  ),
  true,
);

assert.equal(
  isFootballDataOfficialTerminalStatus(
    "awarded",
  ),
  true,
);

assert.equal(
  isFootballDataOfficialTerminalStatus(
    "live_second_half",
  ),
  false,
);

console.log("");
console.log(
  "[PASS] R114 TUTTO EXCLUSIVE LIVE AUTHORITY POLICY",
);
console.log("");
console.log(
  "[PASS] Football-Data allowed only before kickoff",
);
console.log(
  "[PASS] Football-Data blocked from kickoff through Tutto active LIVE",
);
console.log(
  "[PASS] queued PRE-LIVE Football-Data jobs are suppressed at/after kickoff",
);
console.log(
  "[PASS] degraded/Football-Data primary LIVE fallback fails closed",
);
console.log(
  "[PASS] Tutto END_PENDING opens awaiting_official only",
);
console.log(
  "[PASS] only FINISHED/AWARDED qualify as official terminal statuses",
);