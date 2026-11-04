"use client";

import { Capacitor } from "@capacitor/core";

export type WebPushEnableResult = { deviceId: string; endpoint: string };
export type WebPushErrorCode =
  | "PUSH_NATIVE_APP_UNSUPPORTED" | "PUSH_BROWSER_UNSUPPORTED"
  | "PUSH_PERMISSION_DENIED" | "PUSH_AUTH_REQUIRED"
  | "PUSH_PUBLIC_KEY_UNAVAILABLE" | "PUSH_SUBSCRIBE_FAILED"
  | "PUSH_REGISTRATION_FAILED";

export class WebPushActivationError extends Error {
  constructor(public readonly code: WebPushErrorCode) {
    super(code);
    this.name = "WebPushActivationError";
  }
}

function fromBase64Url(key: string): Uint8Array<ArrayBuffer> {
  const raw = atob(key.replace(/-/g, "+").replace(/_/g, "/") +
    "=".repeat((4 - (key.length % 4)) % 4));
  const bytes = new Uint8Array(new ArrayBuffer(raw.length));
  for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
  if (bytes.byteLength !== 65 || bytes[0] !== 4) {
    throw new WebPushActivationError("PUSH_PUBLIC_KEY_UNAVAILABLE");
  }
  return bytes;
}

/** Invoke from a direct user click; permission prompt must remain tied to that gesture. */
export async function enableFantagolWebPush(
  getAccessToken: () => Promise<string | null>,
): Promise<WebPushEnableResult> {
  if (Capacitor.isNativePlatform()) {
    throw new WebPushActivationError("PUSH_NATIVE_APP_UNSUPPORTED");
  }
  if (typeof window === "undefined" || !window.isSecureContext ||
      !("serviceWorker" in navigator) || !("PushManager" in window) ||
      !("Notification" in window)) {
    throw new WebPushActivationError("PUSH_BROWSER_UNSUPPORTED");
  }

  // Request immediately, before any awaits that could lose user activation.
  const permission = await Notification.requestPermission();
  if (permission !== "granted") {
    throw new WebPushActivationError("PUSH_PERMISSION_DENIED");
  }

  const accessToken = await getAccessToken();
  if (!accessToken) throw new WebPushActivationError("PUSH_AUTH_REQUIRED");

  const response = await fetch("/api/push/vapid-public-key", {
    method: "GET", credentials: "same-origin", cache: "no-store",
  });
  if (!response.ok) throw new WebPushActivationError("PUSH_PUBLIC_KEY_UNAVAILABLE");
  const data: unknown = await response.json();
  if (!data || typeof data !== "object" || !("publicKey" in data) ||
      typeof data.publicKey !== "string") {
    throw new WebPushActivationError("PUSH_PUBLIC_KEY_UNAVAILABLE");
  }

  const registration = await navigator.serviceWorker.register("/fantagol-push-sw.js", { scope: "/" });
  await navigator.serviceWorker.ready;

  let subscription: PushSubscription;
  try {
    subscription = (await registration.pushManager.getSubscription()) ??
      await registration.pushManager.subscribe({
        userVisibleOnly: true,
        applicationServerKey: fromBase64Url(data.publicKey),
      });
  } catch {
    throw new WebPushActivationError("PUSH_SUBSCRIBE_FAILED");
  }

  const json = subscription.toJSON();
  if (!json.endpoint || !json.keys?.p256dh || !json.keys?.auth) {
    throw new WebPushActivationError("PUSH_SUBSCRIBE_FAILED");
  }

  const registered = await fetch("/api/push/devices", {
    method: "POST",
    cache: "no-store",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${accessToken}`,
    },
    body: JSON.stringify({
      channel: "web_push",
      credential: {
        endpoint: json.endpoint,
        keys: { p256dh: json.keys.p256dh, auth: json.keys.auth },
      },
    }),
  });
  if (registered.status !== 201) {
    throw new WebPushActivationError("PUSH_REGISTRATION_FAILED");
  }
  const payload: unknown = await registered.json();
  if (!payload || typeof payload !== "object" || !("deviceId" in payload) ||
      typeof payload.deviceId !== "string") {
    throw new WebPushActivationError("PUSH_REGISTRATION_FAILED");
  }
  return { deviceId: payload.deviceId, endpoint: json.endpoint };
}

/** Diagnostic only: local notification, not a server-delivered push. */
export async function showLocalFantagolTestNotification(): Promise<void> {
  if (Capacitor.isNativePlatform() || !("serviceWorker" in navigator) ||
      !("Notification" in window) || Notification.permission !== "granted") {
    throw new WebPushActivationError("PUSH_BROWSER_UNSUPPORTED");
  }
  const registration = await navigator.serviceWorker.getRegistration("/");
  if (!registration) throw new WebPushActivationError("PUSH_BROWSER_UNSUPPORTED");
  await registration.showNotification("FantaGol — prova locale", {
    body: "Le notifiche sono abilitate su questo browser.",
    icon: "/icon.png",
    data: { url: "/leghe" },
  });
}
