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

export type ProductionHeartbeatHttpDependencies = {
  readCronSecret:
    () => string | undefined;

  getServiceClient:
    ServiceClientFactory;

  runHeartbeat:
    HeartbeatRunner;
};

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
             * Worker execution remains disabled
             * at the HTTP activation boundary.
             *
             * pg_cron may invoke the heartbeat
             * later, but it cannot drain jobs
             * through this boundary while this
             * value remains zero.
             */
            maxWorkerJobs:
              0,
          });

      return NextResponse.json(
        {
          ok: true,

          workerExecutionEnabled:
            false,

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