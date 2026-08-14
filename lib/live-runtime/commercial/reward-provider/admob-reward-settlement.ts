import "server-only";

import type {
  SupabaseClient,
} from "@supabase/supabase-js";

import {
  getSupabaseServiceClient,
} from "@/lib/supabase/service";

import type {
  VerifiedAdMobClaimBinding,
} from "./admob-claim-binding";

export type AdMobRewardSettlementFailureCode =
  | "ADMOB_SETTLEMENT_BINDING_REQUIRED"
  | "ADMOB_SETTLEMENT_RESPONSE_INVALID"
  | "ADMOB_SETTLEMENT_RPC_FAILED"
  | "ADMOB_SETTLEMENT_REJECTED";

export class AdMobRewardSettlementError
  extends Error {
  readonly code:
    AdMobRewardSettlementFailureCode;

  readonly retryable: boolean;

  readonly databaseErrorCode:
    string | null;

  readonly settlementErrorCode:
    string | null;

  constructor(
    code:
      AdMobRewardSettlementFailureCode,
    message: string,
    options: {
      retryable?: boolean;
      databaseErrorCode?: string | null;
      settlementErrorCode?: string | null;
    } = {},
  ) {
    super(message);

    this.name =
      "AdMobRewardSettlementError";

    this.code = code;

    this.retryable =
      options.retryable ?? false;

    this.databaseErrorCode =
      options.databaseErrorCode ?? null;

    this.settlementErrorCode =
      options.settlementErrorCode ?? null;
  }
}

export interface AdMobRewardSettlementResult {
  readonly settled: true;

  readonly alreadySettled:
    boolean;

  readonly claimId: string;

  readonly ledgerTransactionId:
    string;

  readonly rewardType:
    string | null;

  readonly passesAwarded:
    number;

  readonly availablePasses:
    number | null;

  readonly settledAt:
    string | null;
}

export interface AdMobRewardSettlementDependencies {
  readonly getServiceClient?:
    () => SupabaseClient;
}

type SettlementRpcPayload = {
  settled?: unknown;
  already_settled?: unknown;
  claim_id?: unknown;
  ledger_id?: unknown;
  reward_type?: unknown;
  passes_awarded?: unknown;
  available_passes?: unknown;
  settled_at?: unknown;
  error_code?: unknown;
  claim_status?: unknown;
};

function requireString(
  value: unknown,
  field: string,
): string {
  if (
    typeof value !== "string" ||
    !value.trim()
  ) {
    throw new AdMobRewardSettlementError(
      "ADMOB_SETTLEMENT_RESPONSE_INVALID",
      `Invalid settlement field: ${field}.`,
      {
        retryable: true,
      },
    );
  }

  return value.trim();
}

function optionalString(
  value: unknown,
): string | null {
  if (
    value === null ||
    typeof value === "undefined"
  ) {
    return null;
  }

  if (typeof value !== "string") {
    throw new AdMobRewardSettlementError(
      "ADMOB_SETTLEMENT_RESPONSE_INVALID",
      "Invalid optional settlement string.",
      {
        retryable: true,
      },
    );
  }

  const normalized =
    value.trim();

  return normalized || null;
}

function requireInteger(
  value: unknown,
  field: string,
): number {
  if (
    typeof value !== "number" ||
    !Number.isSafeInteger(value)
  ) {
    throw new AdMobRewardSettlementError(
      "ADMOB_SETTLEMENT_RESPONSE_INVALID",
      `Invalid settlement integer: ${field}.`,
      {
        retryable: true,
      },
    );
  }

  return value;
}

function optionalInteger(
  value: unknown,
  field: string,
): number | null {
  if (
    value === null ||
    typeof value === "undefined"
  ) {
    return null;
  }

  return requireInteger(
    value,
    field,
  );
}

function ensureBinding(
  binding:
    VerifiedAdMobClaimBinding,
): void {
  if (
    binding.claimBindingVerified !==
      true ||
    !binding.claimId ||
    !binding.providerEventDatabaseId ||
    !binding.externalClaimReference
  ) {
    throw new AdMobRewardSettlementError(
      "ADMOB_SETTLEMENT_BINDING_REQUIRED",
      "A verified AdMob claim binding is required.",
      {
        retryable: false,
      },
    );
  }

  if (
    binding.sourceCode !==
      "REWARDED_AD" ||
    binding.campaignCode !==
      "REWARDED_AD_FOUNDATION" ||
    binding.rewardType !==
      "PASS_REWARD" ||
    binding.passesAwarded !== 1
  ) {
    throw new AdMobRewardSettlementError(
      "ADMOB_SETTLEMENT_BINDING_REQUIRED",
      "AdMob claim binding does not match the certified rewarded contract.",
      {
        retryable: false,
      },
    );
  }
}

export async function settleVerifiedAdMobRewardClaim(
  binding:
    VerifiedAdMobClaimBinding,
  dependencies:
    AdMobRewardSettlementDependencies = {},
): Promise<
  AdMobRewardSettlementResult
> {
  ensureBinding(
    binding,
  );

  const serviceClient =
    (
      dependencies.getServiceClient ??
      getSupabaseServiceClient
    )();

  const metadata = {
    settlementSource:
      "ADMOB_SSV",

    claimBindingVerified:
      true,

    sourceCode:
      binding.sourceCode,

    campaignCode:
      binding.campaignCode,

    providerEventId:
      binding.providerEventId,

    providerEventDatabaseId:
      binding.providerEventDatabaseId,

    externalClaimReference:
      binding.externalClaimReference,
  };

  const {
    data,
    error,
  } =
    await serviceClient.rpc(
      "settle_reward_claim_internal",
      {
        p_claim_id:
          binding.claimId,

        p_provider_event_id:
          binding.providerEventDatabaseId,

        p_external_claim_reference:
          binding.externalClaimReference,

        p_metadata:
          metadata,
      },
    );

  if (error) {
    const databaseErrorCode =
      typeof error.code === "string"
        ? error.code
        : null;

    const message =
      typeof error.message === "string"
        ? error.message
        : "Reward settlement RPC failed.";

    const retryable =
      databaseErrorCode === null ||
      databaseErrorCode.startsWith("08") ||
      databaseErrorCode === "40001" ||
      databaseErrorCode === "40P01";

    throw new AdMobRewardSettlementError(
      "ADMOB_SETTLEMENT_RPC_FAILED",
      message,
      {
        retryable,
        databaseErrorCode,
      },
    );
  }

  if (
    !data ||
    typeof data !== "object" ||
    Array.isArray(data)
  ) {
    throw new AdMobRewardSettlementError(
      "ADMOB_SETTLEMENT_RESPONSE_INVALID",
      "Reward settlement returned an invalid response.",
      {
        retryable: true,
      },
    );
  }

  const payload =
    data as
      SettlementRpcPayload;

  if (payload.settled !== true) {
    const settlementErrorCode =
      optionalString(
        payload.error_code,
      );

    throw new AdMobRewardSettlementError(
      "ADMOB_SETTLEMENT_REJECTED",
      settlementErrorCode
        ? `Reward settlement rejected: ${settlementErrorCode}.`
        : "Reward settlement was rejected.",
      {
        retryable: false,
        settlementErrorCode,
      },
    );
  }

  const claimId =
    requireString(
      payload.claim_id,
      "claim_id",
    );

  if (
    claimId !==
    binding.claimId
  ) {
    throw new AdMobRewardSettlementError(
      "ADMOB_SETTLEMENT_RESPONSE_INVALID",
      "Settlement response claim does not match the certified binding.",
      {
        retryable: true,
      },
    );
  }

  const ledgerTransactionId =
    requireString(
      payload.ledger_id,
      "ledger_id",
    );

  const passesAwarded =
    requireInteger(
      payload.passes_awarded,
      "passes_awarded",
    );

  if (
    passesAwarded !==
    binding.passesAwarded
  ) {
    throw new AdMobRewardSettlementError(
      "ADMOB_SETTLEMENT_RESPONSE_INVALID",
      "Settlement Pass amount differs from the certified claim binding.",
      {
        retryable: true,
      },
    );
  }

  const alreadySettled =
    payload.already_settled ===
      true;

  return Object.freeze({
    settled:
      true,

    alreadySettled,

    claimId,

    ledgerTransactionId,

    rewardType:
      optionalString(
        payload.reward_type,
      ),

    passesAwarded,

    availablePasses:
      optionalInteger(
        payload.available_passes,
        "available_passes",
      ),

    settledAt:
      optionalString(
        payload.settled_at,
      ),
  });
}
