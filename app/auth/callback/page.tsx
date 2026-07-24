"use client";

import { useEffect, useState } from "react";
import { supabase } from "../../../lib/supabaseClient";

const PENDING_AUTH_DESTINATION_KEY = "fantagol.pendingAuthDestination.v1";

function normalizeInternalDestination(
  candidate: string | null | undefined,
): string {
  if (!candidate) return "/inizia";

  const value = candidate.trim();

  if (!value.startsWith("/") || value.startsWith("//")) {
    return "/inizia";
  }

  try {
    const url = new URL(value, "https://fantagol.local");

    if (url.origin !== "https://fantagol.local") {
      return "/inizia";
    }

    return `${url.pathname}${url.search}${url.hash}`;
  } catch {
    return "/inizia";
  }
}

export default function AuthCallbackPage() {
  const [message, setMessage] = useState("Accesso in corso...");

  useEffect(() => {
    let cancelled = false;

    async function finishLogin() {
      const searchParams = new URLSearchParams(window.location.search);
      const authError = searchParams.get("error_description");

      if (authError) {
        setMessage(authError);
        return;
      }

      const code = searchParams.get("code");

      if (code) {
        const { error } = await supabase.auth.exchangeCodeForSession(code);

        if (error) {
          setMessage(error.message);
          return;
        }
      } else {
        const { error } = await supabase.auth.getSession();

        if (error) {
          setMessage(error.message);
          return;
        }
      }

      if (cancelled) return;

      const stored = window.localStorage.getItem(PENDING_AUTH_DESTINATION_KEY);

      if (stored) {
        window.localStorage.removeItem(PENDING_AUTH_DESTINATION_KEY);
      }

      const destination = normalizeInternalDestination(
        searchParams.get("returnTo") ?? stored,
      );

      window.location.replace(destination);
    }

    void finishLogin();

    return () => {
      cancelled = true;
    };
  }, []);

  return (
    <main className="min-h-screen bg-black text-white flex items-center justify-center">
      {message}
    </main>
  );
}
