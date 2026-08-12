import { NextRequest, NextResponse } from "next/server";

import { getSupabaseServiceClient } from "@/lib/supabase/service";

const SUPPORT_SCREENSHOT_BUCKET = "support-screenshots";
const RETENTION_DAYS = 30;
const RETENTION_BATCH_SIZE = 100;

type RetentionCandidate = {
  id: string;
  screenshot_path: string;
  created_at: string;
};

function cronAuthorized(request: NextRequest) {
  const secret = process.env.CRON_SECRET?.trim();

  if (!secret) {
    return false;
  }

  return (
    request.headers.get("authorization") ===
    `Bearer ${secret}`
  );
}

export async function GET(request: NextRequest) {
  if (!process.env.CRON_SECRET?.trim()) {
    return NextResponse.json(
      { error: "Support retention cron is not configured." },
      { status: 503 },
    );
  }

  if (!cronAuthorized(request)) {
    return NextResponse.json(
      { error: "Unauthorized." },
      { status: 401 },
    );
  }

  const serviceClient = getSupabaseServiceClient();
  const cutoff = new Date(
    Date.now() - RETENTION_DAYS * 24 * 60 * 60 * 1000,
  ).toISOString();

  const { data, error } = await serviceClient
    .from("support_requests")
    .select("id,screenshot_path,created_at")
    .not("screenshot_path", "is", null)
    .lte("created_at", cutoff)
    .order("created_at", { ascending: true })
    .limit(RETENTION_BATCH_SIZE);

  if (error) {
    console.error("Support retention candidate query error", error);

    return NextResponse.json(
      { error: "Unable to read retention candidates." },
      { status: 500 },
    );
  }

  const candidates = (data || []).filter(
    (row): row is RetentionCandidate =>
      typeof row.id === "string" &&
      typeof row.screenshot_path === "string" &&
      row.screenshot_path.length > 0 &&
      typeof row.created_at === "string",
  );

  let deleted = 0;
  let failed = 0;

  const failures: Array<{
    requestId: string;
    stage: "storage" | "database";
  }> = [];

  for (const candidate of candidates) {
    const { error: storageError } =
      await serviceClient.storage
        .from(SUPPORT_SCREENSHOT_BUCKET)
        .remove([candidate.screenshot_path]);

    if (storageError) {
      failed += 1;
      failures.push({
        requestId: candidate.id,
        stage: "storage",
      });

      console.error(
        "Support retention Storage deletion error",
        candidate.id,
        storageError,
      );

      continue;
    }

    const { data: finalized, error: finalizeError } =
      await serviceClient.rpc(
        "finalize_support_screenshot_retention_internal",
        {
          p_support_request_id: candidate.id,
          p_expected_screenshot_path:
            candidate.screenshot_path,
        },
      );

    if (finalizeError || finalized !== true) {
      failed += 1;
      failures.push({
        requestId: candidate.id,
        stage: "database",
      });

      console.error(
        "Support retention DB finalization error",
        candidate.id,
        finalizeError,
      );

      continue;
    }

    deleted += 1;
  }

  return NextResponse.json({
    retentionDays: RETENTION_DAYS,
    cutoff,
    scanned: candidates.length,
    deleted,
    failed,
    failures,
  });
}