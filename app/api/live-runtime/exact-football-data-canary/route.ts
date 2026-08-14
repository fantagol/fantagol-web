import {
  NextRequest,
  NextResponse,
} from "next/server";

import {
  getSupabaseServiceClient,
} from "@/lib/supabase/service";

import {
  runLiveRuntimeWorkerOnce,
} from "@/lib/live-runtime/worker";

const EXACT_JOB_ID =
  "d2d6fc32-ac12-449c-8ed1-97ef414d44fc";

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

  if (
    !process.env.FOOTBALL_DATA_TOKEN?.trim()
  ) {
    return NextResponse.json(
      {
        ok: false,
        stage: "provider_configuration",
        footballDataTokenConfigured: false,
      },
      {
        status: 503,
      },
    );
  }

  try {
    const client =
      getSupabaseServiceClient();

    const worker =
      await runLiveRuntimeWorkerOnce({
        client,

        workerId:
          "r39-e6-e3-b-r2-vercel",

        jobId:
          EXACT_JOB_ID,

        retryDelaySeconds:
          3600,
      });

    const exactJobMatched =
      worker.claimed === true &&
      worker.jobId === EXACT_JOB_ID;

    return NextResponse.json(
      {
        ok:
          exactJobMatched &&
          worker.completed === true,

        exactJobId:
          EXACT_JOB_ID,

        exactJobMatched,

        worker,
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
  catch {
    return NextResponse.json(
      {
        ok: false,
        exactJobId:
          EXACT_JOB_ID,
        stage:
          "worker_exception",
      },
      {
        status: 500,
      },
    );
  }
}