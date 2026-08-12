import { NextRequest, NextResponse } from "next/server";

import { getSupabaseServiceClient } from "@/lib/supabase/service";

function getOperatorUserIds() {
  return new Set(
    (process.env.SUPPORT_CONSOLE_OPERATOR_USER_IDS || "")
      .split(",")
      .map((value) => value.trim().toLowerCase())
      .filter(Boolean),
  );
}

export async function GET(request: NextRequest) {
  const authorization = request.headers.get("authorization");

  if (!authorization?.startsWith("Bearer ")) {
    return NextResponse.json(
      { authorized: false },
      {
        status: 401,
        headers: {
          "Cache-Control": "private, no-store",
        },
      },
    );
  }

  const accessToken = authorization.slice("Bearer ".length).trim();

  if (!accessToken) {
    return NextResponse.json(
      { authorized: false },
      {
        status: 401,
        headers: {
          "Cache-Control": "private, no-store",
        },
      },
    );
  }

  const supabase = getSupabaseServiceClient();

  const {
    data: { user },
    error,
  } = await supabase.auth.getUser(accessToken);

  if (error || !user?.id) {
    return NextResponse.json(
      { authorized: false },
      {
        status: 401,
        headers: {
          "Cache-Control": "private, no-store",
        },
      },
    );
  }

  const authorized = getOperatorUserIds().has(
    user.id.toLowerCase(),
  );

  return NextResponse.json(
    { authorized },
    {
      status: authorized ? 200 : 403,
      headers: {
        "Cache-Control": "private, no-store",
      },
    },
  );
}