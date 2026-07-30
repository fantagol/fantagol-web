"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import Header from "../../components/Header";
import { createOAuthCallbackUrl } from "../../lib/auth/oauth-redirect";
import { supabase } from "../../lib/supabaseClient";

const PENDING_AUTH_DESTINATION_KEY = "fantagol.pendingAuthDestination.v1";

function normalizeInternalDestination(
  candidate: string | null | undefined,
): string {
  if (!candidate) {
    return "/leghe";
  }

  const value = candidate.trim();

  if (!value.startsWith("/") || value.startsWith("//")) {
    return "/leghe";
  }

  try {
    const url = new URL(value, "https://fantagol.local");

    if (url.origin !== "https://fantagol.local") {
      return "/leghe";
    }

    return `${url.pathname}${url.search}${url.hash}`;
  } catch {
    return "/leghe";
  }
}

export default function LoginPage() {
  const [returnTo, setReturnTo] = useState("/leghe");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [loading, setLoading] = useState(false);
  const [sessionChecked, setSessionChecked] = useState(false);

  useEffect(() => {
    const searchParams = new URLSearchParams(window.location.search);
    const destination = normalizeInternalDestination(
      searchParams.get("returnTo"),
    );

    queueMicrotask(() => {
      setReturnTo(destination);
    });

    window.localStorage.setItem(PENDING_AUTH_DESTINATION_KEY, destination);

    async function checkSession() {
      const {
        data: { session },
      } = await supabase.auth.getSession();

      if (session?.user) {
        window.location.replace(destination);
        return;
      }

      setSessionChecked(true);
    }

    void checkSession();
  }, []);

  async function handleGoogleLogin() {
    setLoading(true);
    window.localStorage.setItem(PENDING_AUTH_DESTINATION_KEY, returnTo);

    const callbackUrl = createOAuthCallbackUrl(returnTo);

    alert(callbackUrl);

    const { error } = await supabase.auth.signInWithOAuth({
        provider: "google",
        options: {
            redirectTo: callbackUrl,
        },
    });

    if (error) {
        setLoading(false);
        alert(error.message);
    }
}

  async function handleEmailLogin(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setLoading(true);
    window.localStorage.setItem(PENDING_AUTH_DESTINATION_KEY, returnTo);

    const { error } = await supabase.auth.signInWithPassword({
      email,
      password,
    });

    if (error) {
      setLoading(false);
      alert(error.message);
      return;
    }

    window.location.assign(returnTo);
  }

  const registrationHref = `/registrati?returnTo=${encodeURIComponent(returnTo)}`;

  return (
    <main className="min-h-screen bg-black text-white">
      <Header />

      <section className="mx-auto flex min-h-[calc(100vh-56px)] max-w-6xl items-center justify-center px-6 py-16">
        <div className="w-full max-w-md rounded-3xl border border-gray-700 bg-gradient-to-b from-[#1f1f1f] to-[#0d0d0d] p-8 shadow-2xl shadow-black/70">
          <p className="mb-3 text-sm font-semibold uppercase tracking-[0.25em] text-[#A6E824]">
            FantaGol
          </p>

          <h1 className="mb-3 text-3xl font-black">
            Accedi al tuo account
          </h1>

          <p className="mb-8 text-gray-400">
            Entra nelle tue leghe, crea nuove sfide e gestisci i tuoi
            pronostici.
          </p>

          {!sessionChecked ? (
            <div className="flex min-h-48 items-center justify-center">
              <div className="h-8 w-8 animate-spin rounded-full border-2 border-white/15 border-t-[#A6E824]" />
            </div>
          ) : (
            <>
              <button
                type="button"
                onClick={handleGoogleLogin}
                disabled={loading}
                className="mb-6 w-full rounded-xl border border-gray-600 bg-white px-5 py-3 font-semibold text-black transition hover:bg-gray-200 disabled:opacity-60"
              >
                Continua con Google
              </button>

              <div className="mb-6 flex items-center gap-4 text-sm text-gray-500">
                <div className="h-px flex-1 bg-gray-700" />
                oppure
                <div className="h-px flex-1 bg-gray-700" />
              </div>

              <form onSubmit={handleEmailLogin} className="space-y-4">
                <input
                  type="email"
                  required
                  value={email}
                  onChange={(event) => setEmail(event.target.value)}
                  placeholder="Email"
                  className="w-full rounded-xl border border-gray-700 bg-[#111111] px-4 py-3 text-white outline-none transition placeholder:text-gray-500 focus:border-[#A6E824]"
                />

                <input
                  type="password"
                  required
                  value={password}
                  onChange={(event) => setPassword(event.target.value)}
                  placeholder="Password"
                  className="w-full rounded-xl border border-gray-700 bg-[#111111] px-4 py-3 text-white outline-none transition placeholder:text-gray-500 focus:border-[#A6E824]"
                />

                <label className="flex items-center gap-3 text-sm text-gray-400">
                  <input
                    type="checkbox"
                    className="h-4 w-4 rounded border-gray-700 bg-[#111111] accent-[#A6E824]"
                  />
                  Ricordami su questo dispositivo
                </label>

                <button
                  type="submit"
                  disabled={loading}
                  className="w-full rounded-xl bg-[#A6E824] px-5 py-3 font-semibold text-black shadow-lg shadow-[#A6E824]/20 transition hover:brightness-110 disabled:opacity-60"
                >
                  {loading ? "Accesso in corso..." : "Accedi"}
                </button>

                <div className="py-1 text-center">
                  <Link
                    href="/password-reset"
                    className="text-sm font-semibold text-[#A6E824] hover:brightness-110"
                  >
                    Password dimenticata?
                  </Link>
                </div>
              </form>

              <p className="mt-6 text-center text-sm text-gray-400">
                Non hai un account?{" "}
                <Link
                  href={registrationHref}
                  className="font-semibold text-[#A6E824] hover:brightness-110"
                >
                  Registrati
                </Link>
              </p>
            </>
          )}
        </div>
      </section>
    </main>
  );
}

