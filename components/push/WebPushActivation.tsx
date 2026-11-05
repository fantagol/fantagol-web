"use client";

import { useEffect, useRef, useState } from "react";
import { Capacitor } from "@capacitor/core";
import {
  enableFantagolWebPush,
  WebPushActivationError,
} from "@/lib/push/client/web-push";

type Preference = {
  enabled: boolean;
  hasWebPushDevice: boolean;
  currentDeviceRegistered: boolean;
};
type ScreenState = "loading" | "ready" | "error";

function isPreference(value: unknown): value is Preference {
  return Boolean(value && typeof value === "object" &&
    "enabled" in value && typeof value.enabled === "boolean" &&
    "hasWebPushDevice" in value && typeof value.hasWebPushDevice === "boolean" &&
    "currentDeviceRegistered" in value && typeof value.currentDeviceRegistered === "boolean");
}

/** Web-only drawer control. Never requests browser permission without a user click. */
export default function WebPushActivation({
  getAccessToken,
}: {
  getAccessToken: () => Promise<string | null>;
}) {
  const tokenProvider = useRef(getAccessToken);
  tokenProvider.current = getAccessToken;
  const [status, setStatus] = useState<ScreenState>("loading");
  const [busy, setBusy] = useState(false);
  const [preference, setPreference] = useState<Preference | null>(null);
  const [currentEndpoint, setCurrentEndpoint] = useState<string | null>(null);
  const [message, setMessage] = useState("");

  async function currentBrowserEndpoint(): Promise<string | null> {
    if (Capacitor.isNativePlatform() || typeof window === "undefined" ||
      !("Notification" in window) || Notification.permission !== "granted" ||
      !("serviceWorker" in navigator)) return null;
    const registration = await navigator.serviceWorker.getRegistration("/");
    if (!registration) return null;
    const subscription = await registration.pushManager.getSubscription();
    return subscription?.endpoint ?? null;
  }

  async function preferenceRequest(method: "POST" | "PATCH", endpoint: string | null,
      enabled?: boolean): Promise<Preference> {
    const token = await tokenProvider.current();
    if (!token) throw new WebPushActivationError("PUSH_AUTH_REQUIRED");
    const response = await fetch("/api/push/preferences", {
      method,
      credentials: "same-origin",
      cache: "no-store",
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(method === "PATCH" ? { endpoint, enabled } : { endpoint }),
    });
    if (!response.ok) throw new Error("PUSH_PREFERENCE_UNAVAILABLE");
    const data: unknown = await response.json();
    if (!isPreference(data)) throw new Error("PUSH_PREFERENCE_UNAVAILABLE");
    return data;
  }

  useEffect(() => {
    let cancelled = false;
    async function load() {
      try {
        const endpoint = await currentBrowserEndpoint();
        const current = await preferenceRequest("POST", endpoint);
        if (cancelled) return;
        setCurrentEndpoint(endpoint);
        setPreference(current);
        setStatus("ready");
      } catch {
        if (cancelled) return;
        setStatus("error");
        setMessage("Impossibile verificare lo stato delle notifiche. Riprova.");
      }
    }
    void load();
    return () => { cancelled = true; };
    // Token callback is held in a ref so remount is not required when props change.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  async function act() {
    if (status === "error") { window.location.reload(); return; }
    if (busy || status !== "ready" || !preference) return;
    setBusy(true);
    setMessage("");
    try {
      if (currentEndpoint && preference.currentDeviceRegistered) {
        const updated = await preferenceRequest("PATCH", currentEndpoint, !preference.enabled);
        setPreference(updated);
        setMessage(updated.enabled ? "Notifiche FantaGol riattivate." :
          "Notifiche FantaGol disattivate per il tuo account.");
      } else {
        // Explicit click: browser permission and registration for this account.
        await enableFantagolWebPush(() => tokenProvider.current());
        const endpoint = await currentBrowserEndpoint();
        if (!endpoint) throw new Error("PUSH_SUBSCRIPTION_NOT_FOUND");
        let current = await preferenceRequest("POST", endpoint);
        if (!current.currentDeviceRegistered) throw new Error("PUSH_DEVICE_NOT_CONFIRMED");
        // A prior explicit opt-out is preserved by registration; this click opts back in.
        if (!current.enabled) current = await preferenceRequest("PATCH", endpoint, true);
        setCurrentEndpoint(endpoint);
        setPreference(current);
        setMessage("Notifiche FantaGol attive su questo browser.");
      }
    } catch (error) {
      const messages: Record<string, string> = {
        PUSH_NATIVE_APP_UNSUPPORTED: "Le notifiche native saranno disponibili con Android 2.",
        PUSH_BROWSER_UNSUPPORTED: "Questo browser non supporta Web Push.",
        PUSH_PERMISSION_DENIED: "Autorizza le notifiche nelle impostazioni del browser.",
        PUSH_AUTH_REQUIRED: "Accedi a FantaGol prima di attivare le notifiche.",
        PUSH_PUBLIC_KEY_UNAVAILABLE: "Notifiche non ancora disponibili sul server.",
        PUSH_SUBSCRIBE_FAILED: "Impossibile creare la sottoscrizione Web Push.",
        PUSH_REGISTRATION_FAILED: "Registrazione non completata. Riprova.",
      };
      setMessage(error instanceof WebPushActivationError ? messages[error.code] :
        "Operazione non completata. Riprova.");
    } finally {
      setBusy(false);
    }
  }

  const currentBrowserReady = Boolean(currentEndpoint && preference?.currentDeviceRegistered);
  const label = status === "error" ? "Ricarica stato notifiche" :
    !preference || status !== "ready" ? "Verifica notifiche…" :
    currentBrowserReady ? (preference.enabled ? "Disabilita notifiche" : "Riattiva notifiche") :
    "Attiva notifiche";

  return (
    <section aria-label="Notifiche FantaGol" className="space-y-2">
      <p className="text-xs text-gray-200">
        {status === "loading" ? "Controllo delle notifiche in corso…" :
         status === "error" ? "Stato non disponibile" :
         currentBrowserReady ? (preference?.enabled ? "Notifiche attive" : "Notifiche disattivate") :
         "Notifiche non attive su questo browser"}
      </p>
      <button type="button" onClick={act} disabled={busy || status === "loading"}>
        {busy ? "Operazione in corso…" : label}
      </button>
      {message && <p role="status" aria-live="polite">{message}</p>}
    </section>
  );
}
