import "server-only";
import { NextResponse } from "next/server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export function GET() {
  const headers = { "Cache-Control": "no-store" };
  if (process.env.FANTAGOL_PUSH_REGISTRATION_ENABLED !== "true") {
    return NextResponse.json({ error: "PUSH_REGISTRATION_DISABLED" }, { status: 503, headers });
  }

  const key = process.env.FANTAGOL_WEB_PUSH_VAPID_PUBLIC_KEY?.trim();
  if (!key || !/^[A-Za-z0-9_-]+$/.test(key)) {
    return NextResponse.json({ error: "PUSH_CONFIG_UNAVAILABLE" }, { status: 503, headers });
  }
  const bytes = Buffer.from(key, "base64url");
  if (bytes.length !== 65 || bytes[0] !== 4 || bytes.toString("base64url") !== key) {
    return NextResponse.json({ error: "PUSH_CONFIG_UNAVAILABLE" }, { status: 503, headers });
  }
  return NextResponse.json({ publicKey: key }, { status: 200, headers });
}
