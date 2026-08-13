import {
  NextRequest,
  NextResponse,
} from "next/server";

import {
  getSupabaseServiceClient,
} from "@/lib/supabase/service";

import {
  resolveProductionRoundContext,
  loadFootballDataProductionTargets,
  loadMarketRoundProductionTargets,
} from "@/lib/live-runtime/production-target-loader";

import {
  loadCanonicalMarketPolicyInput,
  resolveCanonicalCommunityDecision,
} from "@/lib/live-runtime/production-runtime-state-resolvers";

import {
  loadCanonicalMonthlyMarketCreditState,
} from "@/lib/live-runtime/market-credit-governance-resolver";

type TraceStep = {
  stage: string;
  ok: boolean;
  detail?: unknown;
  error?: string;
};

function serializeError(
  error: unknown,
): string {
  if (error instanceof Error) {
    return error.message;
  }

  try {
    return JSON.stringify(
      error,
    );
  } catch {
    return String(
      error,
    );
  }
}

function authorized(
  request: NextRequest,
): boolean {
  const secret =
    process.env.CRON_SECRET?.trim();

  if (!secret) {
    return false;
  }

  return (
    request.headers.get(
      "authorization",
    ) ===
    `Bearer ${secret}`
  );
}

export async function GET() {
  return NextResponse.json(
    {
      ok: true,
      mode: "R39-E6-D2-B-R9",
      purpose:
        "authenticated heartbeat read trace",
    },
    {
      status: 200,
      headers: {
        "Cache-Control":
          "no-store, max-age=0",
      },
    },
  );
}

export async function POST(
  request: NextRequest,
) {
  if (
    !process.env.CRON_SECRET?.trim()
  ) {
    return NextResponse.json(
      {
        ok: false,
        stage: "configuration",
      },
      {
        status: 503,
      },
    );
  }

  if (!authorized(request)) {
    return NextResponse.json(
      {
        ok: false,
        stage: "authorization",
      },
      {
        status: 401,
      },
    );
  }

  const trace:
    TraceStep[] = [];

  const now =
    new Date();

  let round:
    Awaited<
      ReturnType<
        typeof resolveProductionRoundContext
      >
    >;

  let marketTargets:
    Awaited<
      ReturnType<
        typeof loadMarketRoundProductionTargets
      >
    > = [];

  try {
    const client =
      getSupabaseServiceClient();

    trace.push({
      stage:
        "service_client",
      ok: true,
    });

    try {
      round =
        await resolveProductionRoundContext(
          client,
        );

      trace.push({
        stage:
          "resolve_round_context",
        ok: true,
        detail: {
          fantagolRoundId:
            round.fantagolRoundId,
          status:
            round.status,
          opensAt:
            round.opensAt,
          lockAt:
            round.lockAt,
          startsAt:
            round.startsAt,
          endsAt:
            round.endsAt,
        },
      });
    } catch (error) {
      trace.push({
        stage:
          "resolve_round_context",
        ok: false,
        error:
          serializeError(
            error,
          ),
      });

      return NextResponse.json(
        {
          ok: false,
          failedStage:
            "resolve_round_context",
          trace,
        },
        {
          status: 200,
        },
      );
    }

    try {
      const footballTargets =
        await loadFootballDataProductionTargets(
          client,
          round.fantagolRoundId,
        );

      trace.push({
        stage:
          "load_football_data_targets",
        ok: true,
        detail: {
          count:
            footballTargets.length,
        },
      });
    } catch (error) {
      trace.push({
        stage:
          "load_football_data_targets",
        ok: false,
        error:
          serializeError(
            error,
          ),
      });

      return NextResponse.json(
        {
          ok: false,
          failedStage:
            "load_football_data_targets",
          trace,
        },
        {
          status: 200,
        },
      );
    }

    try {
      marketTargets =
        await loadMarketRoundProductionTargets(
          client,
          round.fantagolRoundId,
        );

      trace.push({
        stage:
          "load_market_targets",
        ok: true,
        detail: {
          count:
            marketTargets.length,
        },
      });
    } catch (error) {
      trace.push({
        stage:
          "load_market_targets",
        ok: false,
        error:
          serializeError(
            error,
          ),
      });

      return NextResponse.json(
        {
          ok: false,
          failedStage:
            "load_market_targets",
          trace,
        },
        {
          status: 200,
        },
      );
    }

    try {
      const marketPolicyInput =
        await loadCanonicalMarketPolicyInput(
          {
            client,
            round,
            targets:
              marketTargets,
            now,
          },
        );

      trace.push({
        stage:
          "load_market_policy_input",
        ok: true,
        detail: {
          collectionStartsAt:
            marketPolicyInput
              .collectionStartsAt,
          opensAt:
            marketPolicyInput
              .opensAt,
          firstKickoffAt:
            marketPolicyInput
              .firstKickoffAt,
          lastPackageSnapshotAt:
            marketPolicyInput
              .lastPackageSnapshotAt ??
            null,
          earlyAdvancedCompleted:
            marketPolicyInput
              .earlyAdvancedCompleted ??
            false,
          finalAdvancedCompleted:
            marketPolicyInput
              .finalAdvancedCompleted ??
            false,
          surpriseReferenceReady:
            marketPolicyInput
              .surpriseReferenceReady ??
            false,
          freshSnapshotAvailable:
            marketPolicyInput
              .freshSnapshotAvailable ??
            false,
          fallbackCandidateAvailable:
            marketPolicyInput
              .fallbackCandidateAvailable ??
            false,
        },
      });
    } catch (error) {
      trace.push({
        stage:
          "load_market_policy_input",
        ok: false,
        error:
          serializeError(
            error,
          ),
      });

      return NextResponse.json(
        {
          ok: false,
          failedStage:
            "load_market_policy_input",
          trace,
        },
        {
          status: 200,
        },
      );
    }

    try {
      const monthlyCreditState =
        await loadCanonicalMonthlyMarketCreditState(
          {
            client,
            now,
          },
        );

      trace.push({
        stage:
          "load_monthly_market_credit_state",
        ok: true,
        detail: {
          monthlyBudget:
            monthlyCreditState
              .monthlyBudget,
          packageCreditsUsed:
            monthlyCreditState
              .packageCreditsUsed,
          packageCreditsRemaining:
            monthlyCreditState
              .packageCreditsRemaining,
          advancedCreditsUsed:
            monthlyCreditState
              .advancedCreditsUsed,
          advancedCreditsAvailable:
            monthlyCreditState
              .advancedCreditsAvailable,
          maximumAdvancedCallsByBucket:
            monthlyCreditState
              .maximumAdvancedCallsByBucket,
          providerRequestsUsed:
            monthlyCreditState
              .providerRequestsUsed,
          providerRequestsRemaining:
            monthlyCreditState
              .providerRequestsRemaining,
        },
      });
    } catch (error) {
      trace.push({
        stage:
          "load_monthly_market_credit_state",
        ok: false,
        error:
          serializeError(
            error,
          ),
      });

      return NextResponse.json(
        {
          ok: false,
          failedStage:
            "load_monthly_market_credit_state",
          trace,
        },
        {
          status: 200,
        },
      );
    }

    try {
      const communityDecision =
        await resolveCanonicalCommunityDecision(
          {
            client,
            round,
            now,
          },
        );

      trace.push({
        stage:
          "resolve_community_decision",
        ok: true,
        detail: {
          action:
            communityDecision.action,
          reason:
            communityDecision.reason,
        },
      });
    } catch (error) {
      trace.push({
        stage:
          "resolve_community_decision",
        ok: false,
        error:
          serializeError(
            error,
          ),
      });

      return NextResponse.json(
        {
          ok: false,
          failedStage:
            "resolve_community_decision",
          trace,
        },
        {
          status: 200,
        },
      );
    }

    return NextResponse.json(
      {
        ok: true,
        failedStage:
          null,
        trace,
        schedulerExecution:
          false,
        enqueueExecution:
          false,
        providerExecution:
          false,
        workerExecution:
          false,
      },
      {
        status: 200,
        headers: {
          "Cache-Control":
            "no-store, max-age=0",
        },
      },
    );
  } catch (error) {
    trace.push({
      stage:
        "unexpected_outer_exception",
      ok: false,
      error:
        serializeError(
          error,
        ),
    });

    return NextResponse.json(
      {
        ok: false,
        failedStage:
          "unexpected_outer_exception",
        trace,
      },
      {
        status: 200,
      },
    );
  }
}