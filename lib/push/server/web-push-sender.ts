import "server-only";
import webpush from "web-push";
import { decryptPushCredential, type PushChannel } from "@/lib/push/server/crypto";

type Subscription = {
  endpoint: string;
  keys: { p256dh: string; auth: string };
};

type DeliveryInput = {
  userId: string;
  channel: PushChannel;
  endpointFingerprint: string;
  encryptedCredentials: Buffer;
  message: { title: string; body: string; url: string; tag?: string };
};

export type PushDeliveryOutcome =
  | { ok: true; statusCode: number }
  | { ok: false; reason: "GONE" | "TEMPORARY" | "UNAVAILABLE"; statusCode: number | null };

const text = (v: string, max: number): string => v.trim().slice(0, max);

function vapidConfig(): { subject: string; publicKey: string; privateKey: string } {
  const subject = process.env.FANTAGOL_WEB_PUSH_VAPID_SUBJECT;
  const publicKey = process.env.FANTAGOL_WEB_PUSH_VAPID_PUBLIC_KEY;
  const privateKey = process.env.FANTAGOL_WEB_PUSH_VAPID_PRIVATE_KEY;
  if (!subject || !/^mailto:[^\s@]+@[^\s@]+$|^https:\/\/[^\s]+$/.test(subject) ||
      !publicKey || !privateKey ||
      !/^[A-Za-z0-9_-]+$/.test(publicKey) || !/^[A-Za-z0-9_-]+$/.test(privateKey)) {
    throw new Error("PUSH_VAPID_CONFIG_UNAVAILABLE");
  }
  return { subject, publicKey, privateKey };
}

function readSubscription(value: string): Subscription {
  let parsed: unknown;
  try { parsed = JSON.parse(value); } catch { throw new Error("PUSH_SUBSCRIPTION_INVALID"); }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error("PUSH_SUBSCRIPTION_INVALID");
  }
  const record = parsed as Record<string, unknown>;
  const keys = record.keys;
  if (typeof record.endpoint !== "string" || !record.endpoint.startsWith("https://") ||
      !keys || typeof keys !== "object" || Array.isArray(keys) ||
      typeof (keys as Record<string, unknown>).p256dh !== "string" ||
      typeof (keys as Record<string, unknown>).auth !== "string") {
    throw new Error("PUSH_SUBSCRIPTION_INVALID");
  }
  return { endpoint: record.endpoint, keys: {
    p256dh: (keys as Record<string, string>).p256dh,
    auth: (keys as Record<string, string>).auth,
  } };
}

/**
 * Server-side delivery primitive. Never expose this function to a public route without
 * authentication, authorization, rate limiting and an explicit recipient selection.
 * It does NOT query the database, mutate devices or retry deliveries.
 */
export async function sendFantagolWebPush(input: DeliveryInput): Promise<PushDeliveryOutcome> {
  if (input.channel !== "web_push") throw new Error("PUSH_CHANNEL_NOT_SUPPORTED");
  if (process.env.FANTAGOL_PUSH_DELIVERY_ENABLED !== "true") {
    throw new Error("PUSH_DELIVERY_DISABLED");
  }
  const { subject, publicKey, privateKey } = vapidConfig();
  let plaintext: string;
  try {
    plaintext = decryptPushCredential({
      userId: input.userId,
      channel: input.channel,
      fingerprint: input.endpointFingerprint,
      envelope: input.encryptedCredentials,
    });
  } catch (error: unknown) {
    if (error instanceof Error && [
      "PUSH_KEY_NOT_CONFIGURED",
      "PUSH_CONTEXT_INVALID",
      "PUSH_ENVELOPE_INVALID",
    ].includes(error.message)) {
      throw error;
    }
    throw new Error("PUSH_DECRYPT_FAILED");
  }
  const subscription = readSubscription(plaintext);
  // Avoid leaking endpoints, keys and payload in errors or logs.
  const payload = JSON.stringify({
    title: text(input.message.title, 120) || "FantaGol",
    body: text(input.message.body, 400) || "Hai una nuova notifica.",
    url: input.message.url.startsWith("/") && !input.message.url.startsWith("//") &&
      !input.message.url.includes("\\") ? input.message.url : "/leghe",
    ...(input.message.tag ? { tag: text(input.message.tag, 80) } : {}),
  });
  try {
    const result = await webpush.sendNotification(subscription, payload, {
      vapidDetails: { subject, publicKey, privateKey },
      TTL: 120,
      urgency: "normal",
      timeout: 10000,
    });
    return { ok: true, statusCode: result.statusCode };
  } catch (error: unknown) {
    const code = error && typeof error === "object" && "statusCode" in error &&
      typeof error.statusCode === "number" ? error.statusCode : null;
    if (code === 404 || code === 410) return { ok: false, reason: "GONE", statusCode: code };
    if (code === 429 || (code !== null && code >= 500)) {
      return { ok: false, reason: "TEMPORARY", statusCode: code };
    }
    return { ok: false, reason: "UNAVAILABLE", statusCode: code };
  }
}
