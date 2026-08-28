import type {
  SupabaseClient,
} from "@supabase/supabase-js";

import {
  DEFAULT_ODDS_MONTHLY_BUDGET,
  MEASURED_ADVANCED_EVENT_COST,
  MEASURED_PACKAGE_COST,
  type CreditBudgetInput,
} from "../market-intelligence/credit-governor";

export const PACKAGE_HARD_BUCKET_CREDITS =
  60 as const;

export const ADVANCED_NOMINAL_BUCKET_CREDITS =
  440 as const;

export type MarketCreditBucket =
  | "PACKAGE"
  | "ADVANCED";

export type ProviderQuotaState = {
  requestsUsed: number;
  requestsRemaining: number;
  requestsLast: number;
  observedAt: string;
  sourceJobId: string;
};

export type FixedMonthlyMarketCreditState = {
  monthlyBudget: number;

  packageBucketTotal: number;
  packageCreditsUsed: number;
  packageCreditsRemaining: number;
  guaranteedPackageCallsRemaining: number;

  advancedBucketTotal: number;
  advancedCreditsUsed: number;
  advancedBucketRemaining: number;

  providerRequestsUsed: number;
  providerRequestsRemaining: number;

  attributedMarketCreditsUsed: number;
  externalOrPreexistingUsageGap: number;

  providerSafeAdvancedCredits: number;
  advancedCreditsAvailable: number;

  maximumAdvancedCallsByBucket: number;

  governorBudgetInput: CreditBudgetInput;

  quota: ProviderQuotaState;
};

type RuntimeJobRow = {
  id: string;
  job_type: string;
  status: string;
  payload: unknown;
  result: unknown;
  completed_at: string | null;
};

function asRecord(
  value: unknown,
): Record<string, unknown> | null {
  if (
    value === null ||
    typeof value !== "object" ||
    Array.isArray(value)
  ) {
    return null;
  }

  return value as Record<string, unknown>;
}

function nestedRecord(
  record: Record<string, unknown> | null,
  key: string,
): Record<string, unknown> | null {
  return asRecord(
    record?.[key],
  );
}

function stringValue(
  record: Record<string, unknown> | null,
  key: string,
): string | null {
  const value =
    record?.[key];

  return typeof value === "string"
    ? value
    : null;
}

function requiredNonNegativeInteger(
  value: unknown,
  code: string,
): number {
  if (
    typeof value !== "number" ||
    !Number.isInteger(value) ||
    value < 0
  ) {
    throw new Error(code);
  }

  return value;
}

function resolveProvider(
  row: RuntimeJobRow,
): string | null {
  const payload =
    asRecord(row.payload);

  const result =
    asRecord(row.result);

  const transport =
    nestedRecord(
      result,
      "transport",
    );

  return (
    stringValue(
      payload,
      "provider_code",
    ) ??
    stringValue(
      result,
      "provider_code",
    ) ??
    stringValue(
      transport,
      "provider",
    )
  );
}

function resolveBucket(
  row: RuntimeJobRow,
): MarketCreditBucket {
  const payload =
    asRecord(row.payload);

  const result =
    asRecord(row.result);

  const signals:
    MarketCreditBucket[] = [];

  for (const candidate of [
    stringValue(
      payload,
      "market_snapshot_source",
    ),
    stringValue(
      result,
      "market_snapshot_source",
    ),
  ]) {
    if (candidate === null) {
      continue;
    }

    if (
      candidate !== "PACKAGE" &&
      candidate !== "ADVANCED"
    ) {
      throw new Error(
        `MARKET_CREDIT_INVALID_BUCKET:${row.id}:${candidate}`,
      );
    }

    signals.push(
      candidate,
    );
  }

  const branch =
    stringValue(
      result,
      "branch",
    );

  if (
    branch ===
    "official_odds_market_intelligence_batch"
  ) {
    signals.push(
      "PACKAGE",
    );
  }

  if (
    branch ===
    "official_odds_market_intelligence_event"
  ) {
    signals.push(
      "ADVANCED",
    );
  }

  const unique =
    [...new Set(signals)];

  if (unique.length === 0) {
    throw new Error(
      `MARKET_CREDIT_UNATTRIBUTED_JOB:${row.id}`,
    );
  }

  if (unique.length !== 1) {
    throw new Error(
      `MARKET_CREDIT_CONFLICTING_ATTRIBUTION:${row.id}`,
    );
  }

  return unique[0];
}

function readQuota(
  row: RuntimeJobRow,
): ProviderQuotaState {
  const result =
    asRecord(row.result);

  const transport =
    nestedRecord(
      result,
      "transport",
    );

  if (
    stringValue(
      transport,
      "provider",
    ) !== "the_odds_api"
  ) {
    throw new Error(
      `MARKET_CREDIT_QUOTA_PROVIDER_INVALID:${row.id}`,
    );
  }

  const quota =
    nestedRecord(
      transport,
      "quota",
    );

  if (!quota) {
    throw new Error(
      `MARKET_CREDIT_QUOTA_MISSING:${row.id}`,
    );
  }

  if (!row.completed_at) {
    throw new Error(
      `MARKET_CREDIT_COMPLETED_AT_MISSING:${row.id}`,
    );
  }

  return {
    requestsUsed:
      requiredNonNegativeInteger(
        quota.requestsUsed,
        `MARKET_CREDIT_REQUESTS_USED_INVALID:${row.id}`,
      ),

    requestsRemaining:
      requiredNonNegativeInteger(
        quota.requestsRemaining,
        `MARKET_CREDIT_REQUESTS_REMAINING_INVALID:${row.id}`,
      ),

    requestsLast:
      requiredNonNegativeInteger(
        quota.requestsLast,
        `MARKET_CREDIT_REQUESTS_LAST_INVALID:${row.id}`,
      ),

    observedAt:
      row.completed_at,

    sourceJobId:
      row.id,
  };
}

function expectedBucketCost(
  bucket: MarketCreditBucket,
): number {
  return bucket === "PACKAGE"
    ? MEASURED_PACKAGE_COST
    : MEASURED_ADVANCED_EVENT_COST;
}

export function resolveFixedMonthlyMarketCreditState(
  input: {
    providerRequestsUsed: number;
    providerRequestsRemaining: number;
    packageCreditsUsed: number;
    advancedCreditsUsed: number;
    quota?: ProviderQuotaState;
  },
): Omit<
  FixedMonthlyMarketCreditState,
  "quota"
> & {
  quota?: ProviderQuotaState;
} {
  const providerRequestsUsed =
    requiredNonNegativeInteger(
      input.providerRequestsUsed,
      "MARKET_CREDIT_PROVIDER_USED_INVALID",
    );

  const providerRequestsRemaining =
    requiredNonNegativeInteger(
      input.providerRequestsRemaining,
      "MARKET_CREDIT_PROVIDER_REMAINING_INVALID",
    );

  const packageCreditsUsed =
    requiredNonNegativeInteger(
      input.packageCreditsUsed,
      "MARKET_CREDIT_PACKAGE_USED_INVALID",
    );

  const advancedCreditsUsed =
    requiredNonNegativeInteger(
      input.advancedCreditsUsed,
      "MARKET_CREDIT_ADVANCED_USED_INVALID",
    );

  const observedMonthlyBudget =
    providerRequestsUsed +
    providerRequestsRemaining;

  if (
    observedMonthlyBudget !==
    DEFAULT_ODDS_MONTHLY_BUDGET
  ) {
    throw new Error(
      [
        "MARKET_CREDIT_PROVIDER_BUDGET_MISMATCH",
        observedMonthlyBudget,
        DEFAULT_ODDS_MONTHLY_BUDGET,
      ].join(":"),
    );
  }

  const attributedMarketCreditsUsed =
    packageCreditsUsed +
    advancedCreditsUsed;

  if (
    attributedMarketCreditsUsed >
    providerRequestsUsed
  ) {
    throw new Error(
      "MARKET_CREDIT_ATTRIBUTED_EXCEEDS_PROVIDER_USAGE",
    );
  }

  const externalOrPreexistingUsageGap =
    providerRequestsUsed -
    attributedMarketCreditsUsed;

  const packageCreditsRemaining =
    Math.max(
      PACKAGE_HARD_BUCKET_CREDITS -
        packageCreditsUsed,
      0,
    );

  if (
    packageCreditsRemaining %
      MEASURED_PACKAGE_COST !==
    0
  ) {
    throw new Error(
      "MARKET_CREDIT_PACKAGE_REMAINDER_NOT_DIVISIBLE",
    );
  }

  const guaranteedPackageCallsRemaining =
    packageCreditsRemaining /
    MEASURED_PACKAGE_COST;

  const advancedBucketRemaining =
    Math.max(
      ADVANCED_NOMINAL_BUCKET_CREDITS -
        advancedCreditsUsed,
      0,
    );

  const providerSafeAdvancedCredits =
    Math.max(
      providerRequestsRemaining -
        packageCreditsRemaining,
      0,
    );

  const advancedCreditsAvailable =
    Math.min(
      advancedBucketRemaining,
      providerSafeAdvancedCredits,
    );

  const maximumAdvancedCallsByBucket =
    Math.floor(
      advancedCreditsAvailable /
        MEASURED_ADVANCED_EVENT_COST,
    );

  return {
    monthlyBudget:
      DEFAULT_ODDS_MONTHLY_BUDGET,

    packageBucketTotal:
      PACKAGE_HARD_BUCKET_CREDITS,

    packageCreditsUsed,
    packageCreditsRemaining,
    guaranteedPackageCallsRemaining,

    advancedBucketTotal:
      ADVANCED_NOMINAL_BUCKET_CREDITS,

    advancedCreditsUsed,
    advancedBucketRemaining,

    providerRequestsUsed,
    providerRequestsRemaining,

    attributedMarketCreditsUsed,
    externalOrPreexistingUsageGap,

    providerSafeAdvancedCredits,
    advancedCreditsAvailable,

    maximumAdvancedCallsByBucket,

    governorBudgetInput: {
      monthlyBudget:
        DEFAULT_ODDS_MONTHLY_BUDGET,

      creditsUsed:
        providerRequestsUsed,

      guaranteedPackageCallsRemaining,

      safetyReserveCredits:
        0,
    },

    quota:
      input.quota,
  };
}

export async function loadCanonicalMonthlyMarketCreditState(
  input: {
    client: SupabaseClient;
    now?: Date;
  },
): Promise<FixedMonthlyMarketCreditState> {
  const now =
    input.now ??
    new Date();

  const monthStart =
    new Date(
      Date.UTC(
        now.getUTCFullYear(),
        now.getUTCMonth(),
        1,
        0,
        0,
        0,
        0,
      ),
    ).toISOString();

  const {
    data,
    error,
  } =
    await input.client
      .from(
        "live_runtime_jobs",
      )
      .select(
        [
          "id",
          "job_type",
          "status",
          "payload",
          "result",
          "completed_at",
        ].join(","),
      )
      .eq(
        "status",
        "completed",
      )
      .gte(
        "completed_at",
        monthStart,
      )
      /*
       * Keep the monthly ledger provider-scoped at the database boundary.
       *
       * A global completed-job limit is unsafe because unrelated runtime
       * traffic can push valid monthly Odds jobs outside the result window.
       * Provider identity is canonical in the persisted payload for the
       * market jobs governed here, including bootstrap-discovery rows.
       */
      .eq(
        "payload->>provider_code",
        "the_odds_api",
      )
      .order(
        "completed_at",
        {
          ascending: false,
          nullsFirst: false,
        },
      );

  if (error) {
    throw new Error(
      `MARKET_CREDIT_LEDGER_LOAD_FAILED:${error.message}`,
    );
  }

  const rows =
    (data ?? []) as unknown as
      RuntimeJobRow[];

  let packageCreditsUsed =
    0;

  let advancedCreditsUsed =
    0;

  let latestQuota:
    ProviderQuotaState |
    null =
      null;

  for (const row of rows) {
    if (
      resolveProvider(row) !==
      "the_odds_api"
    ) {
      continue;
    }

    const payload =
      asRecord(row.payload);

    /*
     * Mapping bootstrap jobs identify the provider but do not
     * consume a canonical market-credit bucket themselves.
     *
     * Their provider quota is intentionally absent because the
     * actual billable PACKAGE/ADVANCED poll follows separately.
     * Keep real market jobs fail-closed in readQuota().
     */
    if (
      payload?.bootstrap_discovery ===
      true
    ) {
      continue;
    }

    const bucket =
      resolveBucket(
        row,
      );

    const quota =
      readQuota(
        row,
      );

    const expectedCost =
      expectedBucketCost(
        bucket,
      );

    if (
      quota.requestsLast !==
      expectedCost
    ) {
      throw new Error(
        [
          "MARKET_CREDIT_COST_DRIFT",
          row.id,
          bucket,
          quota.requestsLast,
          expectedCost,
        ].join(":"),
      );
    }

    if (bucket === "PACKAGE") {
      packageCreditsUsed +=
        quota.requestsLast;
    } else {
      advancedCreditsUsed +=
        quota.requestsLast;
    }

    if (!latestQuota) {
      latestQuota =
        quota;
    }
  }

  if (!latestQuota) {
    throw new Error(
      "MARKET_CREDIT_PROVIDER_QUOTA_NOT_FOUND",
    );
  }

  const resolved =
    resolveFixedMonthlyMarketCreditState({
      providerRequestsUsed:
        latestQuota.requestsUsed,

      providerRequestsRemaining:
        latestQuota.requestsRemaining,

      packageCreditsUsed,
      advancedCreditsUsed,

      quota:
        latestQuota,
    });

  if (!resolved.quota) {
    throw new Error(
      "MARKET_CREDIT_INTERNAL_QUOTA_MISSING",
    );
  }

  return {
    ...resolved,
    quota:
      resolved.quota,
  };
}