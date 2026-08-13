import {
  createHash,
} from "node:crypto";

import {
  NextRequest,
  NextResponse,
} from "next/server";

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

function diagnostic(
  request?: NextRequest,
) {
  const secretRaw =
    process.env.CRON_SECRET ?? "";

  const secret =
    secretRaw.trim();

  const authorization =
    request
      ?.headers
      .get(
        "authorization",
      ) ?? null;

  const bearerPrefix =
    "Bearer ";

  const bearer =
    authorization?.startsWith(
      bearerPrefix,
    )
      ? authorization
          .slice(
            bearerPrefix.length,
          )
      : null;

  return NextResponse.json(
    {
      configured:
        secret.length > 0,

      runtime: {
        rawLength:
          secretRaw.length,

        trimmedLength:
          secret.length,

        sha256:
          secret.length > 0
            ? sha256(
                secret,
              )
            : null,
      },

      request: {
        authorizationPresent:
          authorization !== null,

        authorizationLength:
          authorization?.length ??
          null,

        bearerSchemeValid:
          bearer !== null,

        bearerLength:
          bearer?.length ??
          null,

        bearerSha256:
          bearer !== null
            ? sha256(
                bearer,
              )
            : null,

        bearerMatchesRuntime:
          bearer !== null &&
          secret.length > 0 &&
          bearer === secret,
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

export async function GET(
  request: NextRequest,
) {
  return diagnostic(
    request,
  );
}

export async function POST(
  request: NextRequest,
) {
  return diagnostic(
    request,
  );
}