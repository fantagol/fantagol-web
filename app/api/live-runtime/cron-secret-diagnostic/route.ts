import { createHash } from "node:crypto";

import {
  NextResponse,
} from "next/server";

export async function GET() {
  const secret =
    process.env.CRON_SECRET ?? "";

  const normalized =
    secret.trim();

  return NextResponse.json(
    {
      configured:
        normalized.length > 0,

      rawLength:
        secret.length,

      trimmedLength:
        normalized.length,

      sha256:
        normalized.length > 0
          ? createHash("sha256")
              .update(
                normalized,
                "utf8",
              )
              .digest("hex")
          : null,
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