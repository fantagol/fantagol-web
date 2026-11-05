import "server-only";

import { timingSafeEqual } from "node:crypto";
import { NextRequest, NextResponse } from "next/server";
import { requirePushUser } from "@/lib/push/server/auth";
import { dispatchOneWebPushTest } from "@/lib/push/server/web-push-test-dispatch";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

function response(status: number, code: string) {
  return NextResponse.json({ code }, {
    status,
    headers: { "Cache-Control": "no-store" },
  });
}

function validTestSecret(provided: string | null): boolean {
  const configured = process.env.FANTAGOL_PUSH_TEST_SEND_SECRET;
  if (!configured || configured.length < 32 || !provided || provided.length > 512) return false;
  const actual = Buffer.from(provided, "utf8");
  const expected = Buffer.from(configured, "utf8");
  return actual.length === expected.length && timingSafeEqual(actual, expected);
}

/** Operator-only diagnostic; never call from a browser client component. */
export async function POST(request: NextRequest) {
  if (process.env.FANTAGOL_PUSH_TEST_SEND_ENABLED !== "true" ||
      process.env.FANTAGOL_PUSH_DELIVERY_ENABLED !== "true") {
    return response(404, "NOT_FOUND");
  }
  if (!validTestSecret(request.headers.get("x-fantagol-push-test-secret"))) {
    return response(404, "NOT_FOUND");
  }
  if (request.headers.has("content-length") &&
      request.headers.get("content-length") !== "0") {
    return response(400, "BODY_NOT_ALLOWED");
  }

  let userId: string;
  try {
    userId = await requirePushUser(request.headers.get("authorization"));
  } catch {
    return response(401, "AUTH_REQUIRED");
  }

  try {
    const result = await dispatchOneWebPushTest(userId);
    if (result.kind === "SENT") return response(200, "PUSH_ACCEPTED_BY_PROVIDER");
    if (result.kind === "NO_SUBSCRIPTION") return response(404, "NO_SUBSCRIPTION");
    if (result.kind === "RATE_LIMITED") return response(429, "PUSH_TEST_RATE_LIMITED");
    if (result.kind === "GONE") return response(410, "SUBSCRIPTION_GONE");
    return response(503, "PUSH_DELIVERY_UNAVAILABLE");
  } catch (error: unknown) {
    // Operator diagnostic: fixed safe codes only.
    // Never log tokens, secrets, recipients or raw exceptions.
    const safeCodes = new Set([
      "PUSH_TEST_DISABLED",
      "PUSH_TEST_DEVICE_RPC_FAILED",
      "PUSH_TEST_DEVICE_PAYLOAD_INVALID",
      "PUSH_TEST_QUOTA_RPC_FAILED",
      "PUSH_VAPID_CONFIG_UNAVAILABLE",
      "PUSH_KEY_NOT_CONFIGURED",
      "PUSH_CONTEXT_INVALID",
      "PUSH_ENVELOPE_INVALID",
      "PUSH_DECRYPT_FAILED",
      "PUSH_SUBSCRIPTION_INVALID",
      "PUSH_CHANNEL_NOT_SUPPORTED",
      "PUSH_DELIVERY_DISABLED",
    ]);
    const message = error instanceof Error ? error.message : "";
    const code = safeCodes.has(message)
      ? message
      : "PUSH_TEST_UNCLASSIFIED_EXCEPTION";
    console.error("[FANTAGOL_PUSH_TEST_DIAGNOSTIC]", code);
    return response(503, "PUSH_TEST_UNAVAILABLE");
  }
}
