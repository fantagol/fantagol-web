import {
  createHash,
} from "node:crypto";

import {
  NextRequest,
  NextResponse,
} from "next/server";

import {
  getSupabaseServiceClient,
} from "@/lib/supabase/service";

function sha256(
  value: string,
): string {
  return createHash("sha256")
    .update(
      value,
      "utf8",
    )
    .digest("hex");
}

function readRuntimeEnvironment() {
  const cronSecretRaw =
    process.env.CRON_SECRET ?? "";

  const cronSecret =
    cronSecretRaw.trim();

  const serviceRoleRaw =
    process.env
      .SUPABASE_SERVICE_ROLE_KEY ??
    "";

  const serviceRole =
    serviceRoleRaw.trim();

  const supabaseUrl =
    (
      process.env.SUPABASE_URL ??
      process.env
        .NEXT_PUBLIC_SUPABASE_URL ??
      ""
    ).trim();

  return {
    cronSecretRaw,
    cronSecret,
    serviceRoleRaw,
    serviceRole,
    supabaseUrl,
  };
}

export async function GET() {
  const runtime =
    readRuntimeEnvironment();

  return NextResponse.json(
    {
      cronSecret: {
        configured:
          runtime.cronSecret.length > 0,

        rawLength:
          runtime.cronSecretRaw.length,

        trimmedLength:
          runtime.cronSecret.length,

        sha256:
          runtime.cronSecret.length > 0
            ? sha256(
                runtime.cronSecret,
              )
            : null,
      },

      supabaseServerRuntime: {
        serviceRoleConfigured:
          runtime.serviceRole.length > 0,

        serviceRoleRawLength:
          runtime.serviceRoleRaw.length,

        serviceRoleTrimmedLength:
          runtime.serviceRole.length,

        urlConfigured:
          runtime.supabaseUrl.length > 0,

        urlSource:
          process.env.SUPABASE_URL
            ?.trim()
            ? "SUPABASE_URL"
            : process.env
                .NEXT_PUBLIC_SUPABASE_URL
                ?.trim()
              ? "NEXT_PUBLIC_SUPABASE_URL"
              : null,
      },
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
  const runtime =
    readRuntimeEnvironment();

  if (!runtime.cronSecret) {
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

  const authorization =
    request.headers.get(
      "authorization",
    );

  if (
    authorization !==
    `Bearer ${runtime.cronSecret}`
  ) {
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

  let clientCreated = false;

  try {
    const supabase =
      getSupabaseServiceClient();

    clientCreated = true;

    const {
      data,
      error,
    } =
      await supabase
        .from(
          "live_runtime_jobs",
        )
        .select(
          "id",
        )
        .limit(
          1,
        );

    if (error) {
      return NextResponse.json(
        {
          ok: false,
          stage: "database_read",
          clientCreated,
          readOk: false,
          errorCode:
            error.code ?? null,
        },
        {
          status: 500,
        },
      );
    }

    return NextResponse.json(
      {
        ok: true,
        stage: "complete",
        clientCreated,
        readOk: true,
        returnedRows:
          data?.length ?? 0,
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
        stage:
          clientCreated
            ? "database_exception"
            : "client_creation",
        clientCreated,
        readOk: false,
      },
      {
        status: 500,
      },
    );
  }
}