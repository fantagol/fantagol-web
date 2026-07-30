"use client";

import { useEffect, useState } from "react";
import { supabase } from "../../../lib/supabaseClient";

const PENDING_AUTH_DESTINATION_KEY =
  "fantagol.pendingAuthDestination.v1";

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

function readHashParameters(): URLSearchParams {
  const hash = window.location.hash.replace(/^#/, "");
  return new URLSearchParams(hash);
}

export default function AuthCallbackPage() {
  const [message, setMessage] = useState("Accesso in corso...");

  useEffect(() => {
    let cancelled = false;

    async function finishLogin() {
      const searchParams = new URLSearchParams(window.location.search);
      const hashParams = readHashParameters();

      const authError =
        searchParams.get("error_description") ??
        hashParams.get("error_description") ??
        searchParams.get("error") ??
        hashParams.get("error");

      if (authError) {
        setMessage(authError);
        return;
      }

      const accessToken = hashParams.get("access_token");
      const refreshToken = hashParams.get("refresh_token");
      const code = searchParams.get("code");

      if (accessToken && refreshToken) {
        const { error } = await supabase.auth.setSession({
          access_token: accessToken,
          refresh_token: refreshToken,
        });

        if (error) {
          setMessage(error.message);
          return;
        }
      } else if (code) {
        const { error } =
          await supabase.auth.exchangeCodeForSession(code);

        if (error) {
          setMessage(error.message);
          return;
        }
      } else {
        const {
          data: { session },
          error,
        } = await supabase.auth.getSession();

        if (error) {
          setMessage(error.message);
          return;
        }

        if (!session) {
          setMessage(
            "La risposta di accesso non contiene una sessione valida.",
          );
          return;
        }
      }

      if (cancelled) return;

      const stored = window.localStorage.getItem(
        PENDING_AUTH_DESTINATION_KEY,
      );

      if (stored) {
        window.localStorage.removeItem(
          PENDING_AUTH_DESTINATION_KEY,
        );
      }

      const destination = normalizeInternalDestination(
        searchParams.get("returnTo") ?? stored,
      );

      window.history.replaceState(
        null,
        "",
        window.location.pathname,
      );

      window.location.replace(destination);
    }

    void finishLogin();

    return () => {
      cancelled = true;
    };
  }, []);

  return (
    <main className="flex min-h-screen items-center justify-center bg-black text-white">
      {message}
    </main>
  );
}
