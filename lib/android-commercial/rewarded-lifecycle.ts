import {
  loadTestRewardedAd,
  showTestRewardedAd,
} from "./rewarded-ads";

import {
  createRewardedAdClaimAttempt,
  prepareRewardedAdClaim,
  type PreparedRewardedAdClaim,
  type RewardedAdClaimAttempt,
} from "./rewarded-claim";

export type RewardedLifecycleStage =
  | "preparing_claim"
  | "loading_ad"
  | "showing_ad"
  | "show_requested";

export interface RewardedLifecycleResult {
  readonly started: true;

  readonly stage:
    "show_requested";

  readonly attempt:
    RewardedAdClaimAttempt;

  readonly claim:
    PreparedRewardedAdClaim;
}

export interface RewardedLifecycleDependencies {
  readonly createAttempt?:
    () => RewardedAdClaimAttempt;

  readonly prepareClaim?:
    (
      attempt:
        RewardedAdClaimAttempt,
    ) => Promise<
      PreparedRewardedAdClaim
    >;

  readonly loadAd?:
    typeof loadTestRewardedAd;

  readonly showAd?:
    typeof showTestRewardedAd;
}

let activeAttempt:
  Promise<RewardedLifecycleResult> | null =
    null;

export function isRewardedLifecycleBusy():
  boolean {
  return activeAttempt !== null;
}

async function executeRewardedLifecycle(
  dependencies:
    RewardedLifecycleDependencies,
): Promise<
  RewardedLifecycleResult
> {
  const createAttempt =
    dependencies.createAttempt ??
    createRewardedAdClaimAttempt;

  const prepareClaim =
    dependencies.prepareClaim ??
    prepareRewardedAdClaim;

  const loadAd =
    dependencies.loadAd ??
    loadTestRewardedAd;

  const showAd =
    dependencies.showAd ??
    showTestRewardedAd;

  // Every lifecycle invocation owns one immutable attempt.
  const attempt =
    createAttempt();

  // 1. Claim FIRST.
  // prepareRewardedAdClaim also configures SSV using:
  //   auth user -> AdMob user_id
  //   external reference -> AdMob custom_data
  const claim =
    await prepareClaim(
      attempt,
    );

  if (
    claim.prepared !== true ||
    claim.externalClaimReference !==
      attempt.externalClaimReference ||
    claim.idempotencyKey !==
      attempt.idempotencyKey
  ) {
    throw new Error(
      "REWARDED_LIFECYCLE_CLAIM_BINDING_INVALID",
    );
  }

  // 2. Only after claim + SSV preparation may the ad load.
  const loadResult =
    await loadAd();

  if (
    !loadResult ||
    typeof loadResult !== "object"
  ) {
    throw new Error(
      "REWARDED_LIFECYCLE_LOAD_RESPONSE_INVALID",
    );
  }

  // Native bridge owns the precise load state contract.
  // A failed native load must throw before show.
  if (
    "loaded" in loadResult &&
    loadResult.loaded !== true
  ) {
    throw new Error(
      "REWARDED_LIFECYCLE_AD_NOT_LOADED",
    );
  }

  // 3. Show only after successful claim preparation + load.
  const showResult =
    await showAd();

  if (
    !showResult ||
    typeof showResult !== "object"
  ) {
    throw new Error(
      "REWARDED_LIFECYCLE_SHOW_RESPONSE_INVALID",
    );
  }

  if (
    "showRequested" in
      showResult &&
    showResult.showRequested !== true
  ) {
    throw new Error(
      "REWARDED_LIFECYCLE_SHOW_NOT_REQUESTED",
    );
  }

  return Object.freeze({
    started:
      true,

    stage:
      "show_requested",

    attempt,

    claim,
  });
}

export function startRewardedAdLifecycle(
  dependencies:
    RewardedLifecycleDependencies = {},
): Promise<
  RewardedLifecycleResult
> {
  if (activeAttempt) {
    return Promise.reject(
      new Error(
        "REWARDED_LIFECYCLE_ALREADY_ACTIVE",
      ),
    );
  }

  const execution =
    executeRewardedLifecycle(
      dependencies,
    );

  activeAttempt =
    execution;

  return execution.finally(() => {
    activeAttempt = null;
  });
}

export function resetRewardedLifecycleForTests():
  void {
  activeAttempt = null;
}
