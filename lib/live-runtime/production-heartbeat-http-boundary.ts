import {
  NextRequest,
  NextResponse,
} from "next/server";

type HeartbeatRunner =
  typeof import(
    "./production-heartbeat-orchestrator"
  ).runProductionHeartbeat;

type ServiceClientFactory =
  typeof import(
    "../supabase/service"
  ).getSupabaseServiceClient;

type ProductionHeartbeatRequestBody = {
  source?: string;
  leaseToken?: string;
};

type FinalizeHeartbeatResult = {
  finalized?: boolean;
  success?: boolean;
  next_wakeup_at?: string;
  next_wakeup_reason?: string;
};

export type ProductionHeartbeatHttpDependencies = {
  readCronSecret:
    () => string | undefined;

  getServiceClient:
    ServiceClientFactory;

  runHeartbeat:
    HeartbeatRunner;
};

async function readHeartbeatRequestBody(
  request: NextRequest,
): Promise<ProductionHeartbeatRequestBody> {
  try {
    const parsed = await request.json();

    if (
      !parsed ||
      typeof parsed !== "object" ||
      Array.isArray(parsed)
    ) {
      return {};
    }

    const body =
      parsed as Record<string, unknown>;

    return {
      source:
        typeof body.source === "string"
          ? body.source
          : undefined,
      leaseToken:
        typeof body.leaseToken === "string" &&
        body.leaseToken.trim().length > 0
          ? body.leaseToken.trim()
          : undefined,
    };
  } catch {
    return {};
  }
}

async function finalizeHeartbeatLease(input: {
  client: ReturnType<ServiceClientFactory>;
  leaseToken: string;
  success: boolean;
  reason: string;
}): Promise<FinalizeHeartbeatResult> {
  const { data, error } =
    await input.client.rpc(
      "finalize_production_heartbeat_wakeup_rpc",
      {
        p_lease_token: input.leaseToken,
        p_success: input.success,
        p_reason: input.reason,
      },
    );

  if (error) {
    throw new Error(
      `PRODUCTION_HEARTBEAT_FINALIZE_FAILED:${error.message}`,
    );
  }

  if (
    !data ||
    typeof data !== "object" ||
    Array.isArray(data)
  ) {
    return {};
  }

  return data as FinalizeHeartbeatResult;
}

function bearerAuthorized(
  input: {
    request: NextRequest;
    secret: string;
  },
): boolean {
  return (
    input.request.headers.get(
      "authorization",
    ) ===
    `Bearer ${input.secret}`
  );
}

export function createProductionHeartbeatPostHandler(
  dependencies:
    ProductionHeartbeatHttpDependencies,
) {
  return async function handleProductionHeartbeatPost(
    request: NextRequest,
  ) {
    const secret =
      dependencies
        .readCronSecret()
        ?.trim();

    if (!secret) {
      return NextResponse.json(
        {
          error:
            "Live runtime heartbeat is not configured.",
        },
        {
          status: 503,
        },
      );
    }

    if (
      !bearerAuthorized({
        request,
        secret,
      })
    ) {
      return NextResponse.json(
        {
          error:
            "Unauthorized.",
        },
        {
          status: 401,
        },
      );
    }

    const body =
      await readHeartbeatRequestBody(
        request,
      );

    try {
      const client =
        dependencies
          .getServiceClient();

      const result =
        await dependencies
          .runHeartbeat({
            client,

            workerId:
              "production-heartbeat",

            /*
             * Governed worker activation boundary.
             *
             * Each heartbeat may drain a bounded set of
             * canonical live-chain jobs: poll_batch,
             * refresh_round and rebuild_league_round.
             * Match-result certification, round certification,
             * publication and achievement certification terminal jobs
             * are admitted by the governed heartbeat.
             */
            maxWorkerJobs:
              8,
            workerJobTypes:
              [
                "poll_batch",
                "poll_match",
                "refresh_round",
                "rebuild_league_round",
                "evaluate_certification_readiness",
                "certify_match_result",
                "evaluate_round_certification_readiness",
                "certify_round",
                "publish_snapshot",
                "retry_publication",
                "certify_achievement_state",
              ],
          });

      let heartbeatFinalize:
        FinalizeHeartbeatResult | null =
          null;

      if (body.leaseToken) {
        heartbeatFinalize =
          await finalizeHeartbeatLease({
            client,
            leaseToken:
              body.leaseToken,
            success:
              !result.retryRecommended,
            reason:
              result.retryRecommended
                ? `retry:${result.retryReasons.join(",")}`
                : "heartbeat_completed",
          });
      }

      return NextResponse.json(
        {
          ok: true,

          workerExecutionEnabled:
            true,

          leaseManaged:
            Boolean(body.leaseToken),

          heartbeatFinalize,

          result,
        },
        {
          status: 200,
        },
      );
    } catch (error) {
      console.error(
        "Production heartbeat execution failed",
        error,
      );

      if (body.leaseToken) {
        try {
          const client =
            dependencies
              .getServiceClient();

          await finalizeHeartbeatLease({
            client,
            leaseToken:
              body.leaseToken,
            success: false,
            reason:
              "heartbeat_http_boundary_failed",
          });
        } catch (finalizeError) {
          console.error(
            "Production heartbeat failure finalize failed",
            finalizeError,
          );
        }
      }

      return NextResponse.json(
        {
          ok: false,

          error:
            "Production heartbeat execution failed.",
        },
        {
          status: 500,
        },
      );
    }
  };
}