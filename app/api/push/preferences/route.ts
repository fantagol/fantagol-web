import "server-only";

import { NextRequest, NextResponse } from "next/server";
import { requirePushUser } from "@/lib/push/server/auth";
import { endpointFingerprint } from "@/lib/push/server/crypto";
import { getSupabaseServiceClient } from "@/lib/supabase/service";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const MAX_BODY_BYTES = 8192;
type PreferenceState = {
  enabled: boolean;
  hasWebPushDevice: boolean;
  currentDeviceRegistered: boolean;
};

function reply(status: number, code: string) {
  return NextResponse.json({ error: code }, {
    status, headers: { "Cache-Control": "no-store" },
  });
}

function isPreference(value: unknown): value is PreferenceState {
  return Boolean(value && typeof value === "object" &&
    "enabled" in value && typeof value.enabled === "boolean" &&
    "hasWebPushDevice" in value && typeof value.hasWebPushDevice === "boolean" &&
    "currentDeviceRegistered" in value && typeof value.currentDeviceRegistered === "boolean");
}

async function getUserOrResponse(request: NextRequest): Promise<string | NextResponse> {
  try {
    return await requirePushUser(request.headers.get("authorization"));
  } catch (error) {
    if (error instanceof Error && error.message === "PUSH_AUTH_REQUIRED") {
      return reply(401, "PUSH_AUTH_REQUIRED");
    }
    return reply(503, "PUSH_AUTH_UNAVAILABLE");
  }
}

async function readBody(request: NextRequest): Promise<unknown> {
  if (!/^application\/json(?:\s*;|$)/i.test(request.headers.get("content-type") ?? "")) {
    throw new Error("PUSH_CONTENT_TYPE_INVALID");
  }
  const declared = request.headers.get("content-length");
  if (declared !== null && (!Number.isSafeInteger(Number(declared)) ||
    Number(declared) < 0 || Number(declared) > MAX_BODY_BYTES)) {
    throw new Error("PUSH_BODY_INVALID");
  }
  const raw = await request.text();
  if (Buffer.byteLength(raw, "utf8") > MAX_BODY_BYTES) {
    throw new Error("PUSH_BODY_INVALID");
  }
  return JSON.parse(raw) as unknown;
}

function validateInput(value: unknown, requireEnabled: boolean): {
  fingerprint: string | null; enabled?: boolean;
} | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const keys = Object.keys(value);
  if (requireEnabled) {
    if (keys.length !== 2 || !keys.includes("enabled") || !keys.includes("endpoint") ||
      !("enabled" in value) || typeof value.enabled !== "boolean") return null;
  } else if (keys.length !== 1 || !keys.includes("endpoint")) return null;
  if (!("endpoint" in value)) return null;
  if (value.endpoint !== null && (typeof value.endpoint !== "string" ||
    value.endpoint.length > 4096 || value.endpoint.length < 8)) return null;
  let fingerprint: string | null = null;
  if (typeof value.endpoint === "string") {
    try {
      const url = new URL(value.endpoint);
      if (url.protocol !== "https:" || url.username || url.password || url.hash) return null;
      fingerprint = endpointFingerprint("web_push", value.endpoint);
    } catch {
      return null;
    }
  }
  if (requireEnabled && !fingerprint) return null;
  return { fingerprint, ...(requireEnabled && "enabled" in value ? { enabled: value.enabled as boolean } : {}) };
}

async function handle(request: NextRequest, change: boolean) {
  if (process.env.FANTAGOL_PUSH_REGISTRATION_ENABLED !== "true") {
    return reply(503, "PUSH_REGISTRATION_DISABLED");
  }
  const userId = await getUserOrResponse(request);
  if (typeof userId !== "string") return userId;
  let body: unknown;
  try {
    body = await readBody(request);
  } catch (error) {
    return reply(error instanceof Error && error.message === "PUSH_CONTENT_TYPE_INVALID" ? 415 : 400,
      "PUSH_BODY_INVALID");
  }
  const parsed = validateInput(body, change);
  if (!parsed) return reply(400, "PUSH_PREFERENCE_INVALID");
  try {
    const { data, error } = change
      ? await getSupabaseServiceClient().rpc("push_server_update_preference_rpc", {
        p_user_id: userId,
        p_enabled: parsed.enabled!,
        p_endpoint_fingerprint: parsed.fingerprint!,
      })
      : await getSupabaseServiceClient().rpc("push_server_read_preference_rpc", {
        p_user_id: userId,
        p_endpoint_fingerprint: parsed.fingerprint,
      });
    if (error?.message === "PUSH_R13_CURRENT_DEVICE_NOT_OWNED") {
      return reply(409, "PUSH_CURRENT_DEVICE_REQUIRED");
    }
    if (error || !isPreference(data)) return reply(503, "PUSH_PREFERENCE_UNAVAILABLE");
    return NextResponse.json(data, { headers: { "Cache-Control": "no-store" } });
  } catch {
    return reply(503, "PUSH_PREFERENCE_UNAVAILABLE");
  }
}

/** POST reads state without exposing the subscription endpoint in the URL/query logs. */
export async function POST(request: NextRequest) {
  return handle(request, false);
}

export async function PATCH(request: NextRequest) {
  return handle(request, true);
}
