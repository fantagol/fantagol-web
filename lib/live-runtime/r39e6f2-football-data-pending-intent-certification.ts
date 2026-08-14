import assert from "node:assert/strict";

type PendingJob = {
  id: string;
  scheduledAt: string;
  createdAt: string;
  providerCode: "football_data";
  mode: "prematch" | "live";
  pollingBand: string;
  pollingReason: string;
  attemptCount: number;
  claimed: boolean;
};

function selectAuthoritativePending(
  jobs: PendingJob[],
  input: {
    providerCode: "football_data";
    mode: "prematch" | "live";
    pollingBand: string;
    pollingReason: string;
  },
): PendingJob | null {
  const compatible =
    jobs
      .filter(
        (job) =>
          job.providerCode ===
            input.providerCode &&
          job.mode ===
            input.mode &&
          job.pollingBand ===
            input.pollingBand &&
          job.pollingReason ===
            input.pollingReason &&
          job.attemptCount === 0 &&
          !job.claimed,
      )
      .sort(
        (a, b) =>
          a.scheduledAt.localeCompare(
            b.scheduledAt,
          ) ||
          a.createdAt.localeCompare(
            b.createdAt,
          ) ||
          a.id.localeCompare(b.id),
      );

  return compatible[0] ?? null;
}

const jobs: PendingJob[] = [
  {
    id: "20-40",
    scheduledAt:
      "2026-08-14T20:40:00.000Z",
    createdAt:
      "2026-08-14T14:40:02.541Z",
    providerCode:
      "football_data",
    mode:
      "prematch",
    pollingBand:
      "bootstrap_dormant",
    pollingReason:
      "pre_season_bootstrap_until_2026_08_16",
    attemptCount:
      0,
    claimed:
      false,
  },
  {
    id: "20-41",
    scheduledAt:
      "2026-08-14T20:41:00.000Z",
    createdAt:
      "2026-08-14T14:41:02.776Z",
    providerCode:
      "football_data",
    mode:
      "prematch",
    pollingBand:
      "bootstrap_dormant",
    pollingReason:
      "pre_season_bootstrap_until_2026_08_16",
    attemptCount:
      0,
    claimed:
      false,
  },
  {
    id: "20-42",
    scheduledAt:
      "2026-08-14T20:42:00.000Z",
    createdAt:
      "2026-08-14T14:42:02.345Z",
    providerCode:
      "football_data",
    mode:
      "prematch",
    pollingBand:
      "bootstrap_dormant",
    pollingReason:
      "pre_season_bootstrap_until_2026_08_16",
    attemptCount:
      0,
    claimed:
      false,
  },
  {
    id: "20-43",
    scheduledAt:
      "2026-08-14T20:43:00.000Z",
    createdAt:
      "2026-08-14T14:43:02.168Z",
    providerCode:
      "football_data",
    mode:
      "prematch",
    pollingBand:
      "bootstrap_dormant",
    pollingReason:
      "pre_season_bootstrap_until_2026_08_16",
    attemptCount:
      0,
    claimed:
      false,
  },
];

const selected =
  selectAuthoritativePending(
    jobs,
    {
      providerCode:
        "football_data",
      mode:
        "prematch",
      pollingBand:
        "bootstrap_dormant",
      pollingReason:
        "pre_season_bootstrap_until_2026_08_16",
    },
  );

assert.ok(selected);
assert.equal(
  selected.id,
  "20-40",
);

assert.equal(
  selected.scheduledAt,
  "2026-08-14T20:40:00.000Z",
);

const incompatibleBand =
  selectAuthoritativePending(
    jobs,
    {
      providerCode:
        "football_data",
      mode:
        "prematch",
      pollingBand:
        "prematch_dense",
      pollingReason:
        "kickoff_within_24_hours",
    },
  );

assert.equal(
  incompatibleBand,
  null,
);

const attempted =
  selectAuthoritativePending(
    [
      {
        ...jobs[0],
        attemptCount: 1,
      },
    ],
    {
      providerCode:
        "football_data",
      mode:
        "prematch",
      pollingBand:
        "bootstrap_dormant",
      pollingReason:
        "pre_season_bootstrap_until_2026_08_16",
    },
  );

assert.equal(
  attempted,
  null,
);

console.log(
  "[PASS] earliest compatible pending job is authoritative",
);

console.log(
  "[PASS] polling-policy changes create a new semantic intent",
);

console.log(
  "[PASS] attempted jobs are not reusable pending intents",
);

console.log(
  "[PASS] R39-E6-F2 pending-intent reuse regression contract",
);