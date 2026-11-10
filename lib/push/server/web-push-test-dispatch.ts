import "server-only";

import { getSupabaseServiceClient } from "@/lib/supabase/service";
import { sendFantagolWebPush } from "@/lib/push/server/web-push-sender";

export type TestDispatchResult =
  | { kind: "SENT" }
  | { kind: "NO_SUBSCRIPTION" | "RATE_LIMITED" | "GONE" | "UNAVAILABLE" };

type DevicePayload = {
  endpoint_fingerprint: string;
  encrypted_credentials_hex: string;
};

function parseDevicePayload(value: unknown): DevicePayload | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const data = value as Record<string, unknown>;
  if (typeof data.endpoint_fingerprint !== "string" ||
      !/^[0-9a-f]{64}$/.test(data.endpoint_fingerprint) ||
      typeof data.encrypted_credentials_hex !== "string" ||
      !/^(?:[0-9a-f]{2}){30,}$/.test(data.encrypted_credentials_hex) ||
      !data.encrypted_credentials_hex.startsWith("01")) return null;
  return {
    endpoint_fingerprint: data.endpoint_fingerprint,
    encrypted_credentials_hex: data.encrypted_credentials_hex,
  };
}

/** This test-only flow never reads the table directly or accepts a caller-supplied recipient. */
export async function dispatchOneWebPushTest(userId: string): Promise<TestDispatchResult> {
  if (process.env.FANTAGOL_PUSH_TEST_SEND_ENABLED !== "true" ||
      process.env.FANTAGOL_PUSH_DELIVERY_ENABLED !== "true") {
    throw new Error("PUSH_TEST_DISABLED");
  }
  const supabase = getSupabaseServiceClient();
  const { data, error } = await supabase.rpc("push_server_select_test_device_rpc", {
    p_user_id: userId,
  });
  if (error) throw new Error("PUSH_TEST_DEVICE_RPC_FAILED");
  if (data === null) return { kind: "NO_SUBSCRIPTION" };
  const device = parseDevicePayload(data);
  if (!device) throw new Error("PUSH_TEST_DEVICE_PAYLOAD_INVALID");

  // Transactional, per-user quota reservation in PostgreSQL. No delivery without a reservation.
  const quota = await supabase.rpc("push_server_reserve_test_delivery_rpc", {
    p_user_id: userId,
  });
  if (quota.error || typeof quota.data !== "boolean") {
    throw new Error("PUSH_TEST_QUOTA_RPC_FAILED");
  }
  if (!quota.data) return { kind: "RATE_LIMITED" };

  // M368 enforces the current user preference at device selection time.
  // Re-select after quota reservation, minimizing the opt-out race window.
  // This cannot atomically serialize revocation with an external HTTP send.
  const finalSelection = await supabase.rpc("push_server_select_test_device_rpc", {
    p_user_id: userId,
  });
  if (finalSelection.error) throw new Error("PUSH_TEST_DEVICE_RPC_FAILED");
  if (finalSelection.data === null) return { kind: "NO_SUBSCRIPTION" };
  const currentDevice = parseDevicePayload(finalSelection.data);
  if (!currentDevice) throw new Error("PUSH_TEST_DEVICE_PAYLOAD_INVALID");
  if (currentDevice.endpoint_fingerprint !== device.endpoint_fingerprint ||
      currentDevice.encrypted_credentials_hex !== device.encrypted_credentials_hex) {
    return { kind: "NO_SUBSCRIPTION" };
  }

  const result = await sendFantagolWebPush({
    userId,
    channel: "web_push",
    endpointFingerprint: device.endpoint_fingerprint,
    encryptedCredentials: Buffer.from(device.encrypted_credentials_hex, "hex"),
    message: {
      title: "FantaGol — test notifiche",
      body: "La prima notifica Web Push dal server FantaGol è arrivata!",
      url: "/leghe",
      tag: "fantagol-push-v1-test",
    },
  });
  if (result.ok) return { kind: "SENT" };
  return result.reason === "GONE" ? { kind: "GONE" } : { kind: "UNAVAILABLE" };
}
