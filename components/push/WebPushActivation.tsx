"use client";

import { useState } from "react";
import {
  enableFantagolWebPush,
  showLocalFantagolTestNotification,
  WebPushActivationError,
} from "@/lib/push/client/web-push";

/** Render only in a signed-in website screen; NOT in the Capacitor native shell. */
export default function WebPushActivation({
  getAccessToken,
}: {
  getAccessToken: () => Promise<string | null>;
}) {
  const [busy, setBusy] = useState(false);
  const [registered, setRegistered] = useState(false);
  const [message, setMessage] = useState("");

  async function activate() {
    if (busy) return;
    setBusy(true);
    setMessage("");
    try {
      await enableFantagolWebPush(getAccessToken);
      setRegistered(true);
      setMessage("Browser registrato per le notifiche FantaGol.");
    } catch (error) {
      setMessage(error instanceof WebPushActivationError ?
        ({
          PUSH_NATIVE_APP_UNSUPPORTED: "Le notifiche native arriveranno con Android 2.",
          PUSH_BROWSER_UNSUPPORTED: "Questo browser non supporta le notifiche Web Push.",
          PUSH_PERMISSION_DENIED: "Autorizza le notifiche nelle impostazioni del browser.",
          PUSH_AUTH_REQUIRED: "Accedi a FantaGol prima di attivare le notifiche.",
          PUSH_PUBLIC_KEY_UNAVAILABLE: "Notifiche non ancora attive sul server.",
          PUSH_SUBSCRIBE_FAILED: "Impossibile creare la sottoscrizione su questo browser.",
          PUSH_REGISTRATION_FAILED: "Registrazione non completata. Riprova più tardi.",
        } as const)[error.code] : "Attivazione non disponibile.");
    } finally {
      setBusy(false);
    }
  }

  async function localTest() {
    try {
      await showLocalFantagolTestNotification();
      setMessage("Notifica di prova locale inviata al browser.");
    } catch {
      setMessage("Non è stato possibile mostrare la notifica locale.");
    }
  }

  return (
    <section aria-label="Notifiche FantaGol">
      <button type="button" disabled={busy} onClick={activate}>
        {busy ? "Attivazione…" : "Attiva notifiche"}
      </button>
      {registered && (
        <button type="button" onClick={localTest}>
          Prova notifica locale
        </button>
      )}
      {message && <p role="status" aria-live="polite">{message}</p>}
    </section>
  );
}
