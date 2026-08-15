type PendingPackage = {
  id: string;
  scheduledAt: string;
  attemptCount: number;
  claimed: boolean;
  providerCode: string;
  mode: string;
  snapshotSource: string;
  operatingMode: string;
  policyReason: string;
};

type Intent = {
  operatingMode: string;
  policyReason: string;
};

function selectEarliestCompatible(
  rows: PendingPackage[],
  intent: Intent,
): PendingPackage | null {
  return (
    rows
      .filter(
        (row) =>
          row.attemptCount === 0 &&
          !row.claimed &&
          row.providerCode === "the_odds_api" &&
          row.mode === "prematch" &&
          row.snapshotSource === "PACKAGE" &&
          row.operatingMode === intent.operatingMode &&
          row.policyReason === intent.policyReason,
      )
      .sort(
        (a, b) =>
          Date.parse(a.scheduledAt) -
          Date.parse(b.scheduledAt),
      )[0] ?? null
  );
}

function assert(
  condition: boolean,
  message: string,
): void {
  if (!condition) {
    throw new Error(message);
  }
}

const rows: PendingPackage[] = [
  {
    id: "20-40",
    scheduledAt: "2026-08-14T20:40:00.000Z",
    attemptCount: 0,
    claimed: false,
    providerCode: "the_odds_api",
    mode: "prematch",
    snapshotSource: "PACKAGE",
    operatingMode: "commissioning",
    policyReason: "commissioning_sparse_package_due",
  },
  {
    id: "20-41",
    scheduledAt: "2026-08-14T20:41:00.000Z",
    attemptCount: 0,
    claimed: false,
    providerCode: "the_odds_api",
    mode: "prematch",
    snapshotSource: "PACKAGE",
    operatingMode: "commissioning",
    policyReason: "commissioning_sparse_package_due",
  },
];

const selected =
  selectEarliestCompatible(
    rows,
    {
      operatingMode: "commissioning",
      policyReason:
        "commissioning_sparse_package_due",
    },
  );

assert(
  selected?.id === "20-40",
  "EARLIEST_PACKAGE_NOT_AUTHORITATIVE",
);

console.log(
  "[PASS] earliest compatible PACKAGE pending intent is authoritative",
);

const policyChange =
  selectEarliestCompatible(
    rows,
    {
      operatingMode: "normal",
      policyReason: "package_snapshot_due",
    },
  );

assert(
  policyChange === null,
  "POLICY_CHANGE_MUST_NOT_REUSE_OLD_INTENT",
);

console.log(
  "[PASS] policy changes create a distinct semantic PACKAGE intent",
);

const attempted =
  selectEarliestCompatible(
    [
      {
        ...rows[0],
        attemptCount: 1,
      },
    ],
    {
      operatingMode: "commissioning",
      policyReason:
        "commissioning_sparse_package_due",
    },
  );

assert(
  attempted === null,
  "ATTEMPTED_PACKAGE_MUST_NOT_BE_REUSED",
);

console.log(
  "[PASS] attempted PACKAGE jobs are not reusable",
);

const claimed =
  selectEarliestCompatible(
    [
      {
        ...rows[0],
        claimed: true,
      },
    ],
    {
      operatingMode: "commissioning",
      policyReason:
        "commissioning_sparse_package_due",
    },
  );

assert(
  claimed === null,
  "CLAIMED_PACKAGE_MUST_NOT_BE_REUSED",
);

console.log(
  "[PASS] claimed PACKAGE jobs are not reusable",
);

console.log(
  "[PASS] R39-E6-G2 PACKAGE pending-intent reuse regression contract",
);