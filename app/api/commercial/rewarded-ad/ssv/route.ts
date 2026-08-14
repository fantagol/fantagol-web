import {
  NextRequest,
  NextResponse,
} from "next/server";

import {
  AdMobClaimBindingError,
  verifyAdMobClaimOwnershipBinding,
} from "@/lib/live-runtime/commercial/reward-provider/admob-claim-binding";

import {
  registerVerifiedAdMobProviderEvent,
} from "@/lib/live-runtime/commercial/reward-provider/admob-provider-event-registration";

import {
  AdMobRewardSettlementError,
  settleVerifiedAdMobRewardClaim,
} from "@/lib/live-runtime/commercial/reward-provider/admob-reward-settlement";

import {
  AdMobSsvVerificationError,
  verifyAdMobRewardedSsv,
} from "@/lib/live-runtime/commercial/reward-provider/admob-ssv-verifier";

export const runtime =
  "nodejs";

export const dynamic =
  "force-dynamic";

type RouteDependencies = {
  verify:
    typeof verifyAdMobRewardedSsv;

  register:
    typeof registerVerifiedAdMobProviderEvent;

  bindClaim:
    typeof verifyAdMobClaimOwnershipBinding;

  settle:
    typeof settleVerifiedAdMobRewardClaim;
};

const defaultDependencies:
  RouteDependencies = {
    verify:
      verifyAdMobRewardedSsv,

    register:
      registerVerifiedAdMobProviderEvent,

    bindClaim:
      verifyAdMobClaimOwnershipBinding,

    settle:
      settleVerifiedAdMobRewardClaim,
  };

function noStoreHeaders() {
  return {
    "cache-control":
      "no-store",
  };
}

export function createAdMobSsvGetHandler(
  dependencies:
    RouteDependencies =
      defaultDependencies,
) {
  return async function GET(
    request: NextRequest,
  ) {
    try {
      const verified =
        await dependencies.verify(
          request.url,
        );

      const registration =
        await dependencies.register(
          verified,
        );

      const binding =
        await dependencies.bindClaim(
          verified,
        );

      const settlement =
        await dependencies.settle(
          binding,
        );

      return NextResponse.json(
        {
          received: true,
          verified: true,

          providerEventId:
            verified.providerEventId,

          sourceCode:
            verified.sourceCode,

          registered:
            registration.registered,

          duplicate:
            registration.duplicate,

          eventId:
            registration.eventId,

          processingStatus:
            registration.processingStatus,

          signatureVerified:
            registration.signatureVerified,

          claimBindingVerified:
            binding.claimBindingVerified,

          claimId:
            binding.claimId,

          campaignCode:
            binding.campaignCode,

          settled:
            settlement.settled,

          alreadySettled:
            settlement.alreadySettled,

          ledgerTransactionId:
            settlement.ledgerTransactionId,

          passesAwarded:
            settlement.passesAwarded,

          availablePasses:
            settlement.availablePasses,

          settledAt:
            settlement.settledAt,

          economicallyAuthoritative:
            true,
        },
        {
          status: 200,
          headers:
            noStoreHeaders(),
        },
      );
    }
    catch (error) {
      if (
        error instanceof
        AdMobSsvVerificationError
      ) {
        return NextResponse.json(
          {
            received: true,
            verified: false,
            errorCode:
              error.code,
            retryable:
              error.retryable,
            economicallyAuthoritative:
              false,
          },
          {
            status:
              error.retryable
                ? 503
                : 400,
            headers:
              noStoreHeaders(),
          },
        );
      }

      if (
        error instanceof
        AdMobClaimBindingError
      ) {
        return NextResponse.json(
          {
            received: true,
            verified: true,
            claimBindingVerified:
              false,
            errorCode:
              error.code,
            retryable:
              error.retryable,
            economicallyAuthoritative:
              false,
          },
          {
            status:
              error.retryable
                ? 503
                : 409,
            headers:
              noStoreHeaders(),
          },
        );
      }

      if (
        error instanceof
        AdMobRewardSettlementError
      ) {
        return NextResponse.json(
          {
            received: true,
            verified: true,
            claimBindingVerified:
              true,
            settled: false,
            errorCode:
              error.code,
            settlementErrorCode:
              error.settlementErrorCode,
            retryable:
              error.retryable,
            economicallyAuthoritative:
              false,
          },
          {
            status:
              error.retryable
                ? 503
                : 409,
            headers:
              noStoreHeaders(),
          },
        );
      }

      const message =
        error instanceof Error
          ? error.message
          : "";

      if (
        message ===
        "ADMOB_PROVIDER_EVENT_IDEMPOTENCY_CONFLICT"
      ) {
        return NextResponse.json(
          {
            received: true,
            verified: true,
            registered: false,
            duplicate: false,
            errorCode:
              "PROVIDER_EVENT_IDEMPOTENCY_CONFLICT",
            retryable: false,
            economicallyAuthoritative:
              false,
          },
          {
            status: 409,
            headers:
              noStoreHeaders(),
          },
        );
      }

      return NextResponse.json(
        {
          received: true,
          verified: false,
          errorCode:
            "ADMOB_SSV_PIPELINE_FAILED",
          retryable: true,
          economicallyAuthoritative:
            false,
        },
        {
          status: 503,
          headers:
            noStoreHeaders(),
        },
      );
    }
  };
}

export const GET =
  createAdMobSsvGetHandler();
