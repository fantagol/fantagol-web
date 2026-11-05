import "server-only";

import { NextRequest, NextResponse } from "next/server";
import { requirePushUser } from "@/lib/push/server/auth";
import { parsePushDevice } from "@/lib/push/server/contracts";
import {
  endpointFingerprint,
  encryptPushCredential,
} from "@/lib/push/server/crypto";
import { getSupabaseServiceClient } from "@/lib/supabase/service";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const MAX_BODY_BYTES = 32768;

function reply(status: number, code: string) {
  return NextResponse.json(
    { error: code },
    {
      status,
      headers: { "Cache-Control": "no-store" },
    },
  );
}

async function readLimitedJson(request: NextRequest): Promise<unknown> {
  const length = request.headers.get("content-length");

  if (length !== null) {
    const parsed = Number(length);
    if (!Number.isSafeInteger(parsed) || parsed < 0 || parsed > MAX_BODY_BYTES) {
      throw new Error("PUSH_BODY_INVALID");
    }
  }

  if (!request.body) {
    throw new Error("PUSH_BODY_INVALID");
  }

  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;

  try {
    while (true) {
      const result = await reader.read();

      if (result.done) break;

      total += result.value.byteLength;

      if (total > MAX_BODY_BYTES) {
        await reader.cancel();
        throw new Error("PUSH_BODY_INVALID");
      }

      chunks.push(result.value);
    }
  } finally {
    reader.releaseLock();
  }

  const body = Buffer.concat(chunks.map((chunk) => Buffer.from(chunk)));

  let json: unknown;

  try {
    json = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(body));
  } catch {
    throw new Error("PUSH_BODY_INVALID");
  }

  return json;
}

type PushRegistrationError = {
  code?: string;
  message?: string;
};

function pushRegistrationErrorResponse(
  error: PushRegistrationError,
): { status: number; code: string } {
  // Match only known PostgreSQL errors. Never return raw SQL details.
  if (error.code === "P0001") {
    switch (error.message) {
      case "PUSH_REQUEST_QUOTA_EXCEEDED":
      case "PUSH_REGISTRATION_QUOTA_EXCEEDED":
        return { status: 429, code: "PUSH_RATE_LIMITED" };

      case "PUSH_ACTIVE_DEVICE_LIMIT":
        return { status: 409, code: "PUSH_DEVICE_LIMIT_REACHED" };

      case "PUSH_ENDPOINT_OWNED_BY_ANOTHER_USER":
      case "endpoint belongs to a different user":
        return { status: 409, code: "PUSH_ENDPOINT_CONFLICT" };
    }
  }

  // Unknown, malformed or unexpected database failures stay generic.
  return { status: 503, code: "PUSH_REGISTRATION_UNAVAILABLE" };
}
export async function POST(request: NextRequest) {
  // Fail closed until SQL deployment and API certification are complete.
  if (process.env.FANTAGOL_PUSH_REGISTRATION_ENABLED !== "true") {
    return reply(503, "PUSH_REGISTRATION_DISABLED");
  }

  let userId: string;

  try {
    userId = await requirePushUser(
      request.headers.get("authorization"),
    );
  } catch (error) {
    if (
      error instanceof Error &&
      error.message === "PUSH_AUTH_REQUIRED"
    ) {
      return reply(401, "PUSH_AUTH_REQUIRED");
    }

    return reply(503, "PUSH_AUTH_UNAVAILABLE");
  }

  const contentType = request.headers.get("content-type") ?? "";

  if (!/^application\/json(?:\s*;|$)/i.test(contentType)) {
    return reply(415, "PUSH_CONTENT_TYPE_INVALID");
  }

  let device: ReturnType<typeof parsePushDevice>;

  try {
    device = parsePushDevice(await readLimitedJson(request));
  } catch {
    return reply(400, "PUSH_DEVICE_INVALID");
  }

  try {
    const fingerprint = endpointFingerprint(
      device.channel,
      device.fingerprintSource,
    );

    const encrypted = encryptPushCredential({
      userId,
      channel: device.channel,
      fingerprint,
      credential: device.credential,
    });

    // PostgreSQL bytea hex representation through PostgREST JSON.
    const encryptedHex = "\\x" + encrypted.toString("hex");

    const supabase = getSupabaseServiceClient();

    const { data, error } = await supabase.rpc(
      "push_server_register_device_with_preference_rpc",
      {
        p_user_id: userId,
        p_channel: device.channel,
        p_endpoint_fingerprint: fingerprint,
        p_encrypted_credentials: encryptedHex,
      },
    );

    if (error) {
      return reply(
        pushRegistrationErrorResponse(error).status,
        pushRegistrationErrorResponse(error).code,
      );
    }

    if (typeof data !== "string" ||
        !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(data)) {
      return reply(503, "PUSH_REGISTRATION_INVALID_RESPONSE");
    }

    return NextResponse.json(
      { deviceId: data },
      {
        status: 201,
        headers: { "Cache-Control": "no-store" },
      },
    );
  } catch {
    // No token, encryption key, endpoint or credential in error output.
    return reply(503, "PUSH_REGISTRATION_UNAVAILABLE");
  }
}