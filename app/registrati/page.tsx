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
    return "/inizia";
  }

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

export default function RegistratiPage() {
  const [returnTo, setReturnTo] = useState("/inizia");
  const [username, setUsername] = useState("");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    const searchParams = new URLSearchParams(window.location.search);
    const destination = normalizeInternalDestination(
      searchParams.get("returnTo"),
    );

    queueMicrotask(() => {
      setReturnTo(destination);
    });

    window.localStorage.setItem(PENDING_AUTH_DESTINATION_KEY, destination);
  }, []);

  async function handleGoogleLogin() {
    setLoading(true);
    window.localStorage.setItem(PENDING_AUTH_DESTINATION_KEY, returnTo);

    const callbackUrl = createOAuthCallbackUrl(returnTo);

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

  async function handleRegister(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setLoading(true);
    window.localStorage.setItem(PENDING_AUTH_DESTINATION_KEY, returnTo);

    const callbackUrl = new URL("/auth/callback", window.location.origin);
    callbackUrl.searchParams.set("returnTo", returnTo);

    const { data, error } = await supabase.auth.signUp({
      email,
      password,
      options: {
        data: {
          username: username.trim(),
        },
        emailRedirectTo: callbackUrl.toString(),
      },
    });

    if (error) {
      setLoading(false);
      alert(error.message);
      return;
    }

    if (data.session?.user) {
      window.location.assign(returnTo);
      return;
    }

    setLoading(false);
    alert(
      "Registrazione completata. Controlla la tua email per confermare l'account.",
    );
  }

  const loginHref = `/login?returnTo=${encodeURIComponent(returnTo)}`;

  return (
    <main className="min-h-screen bg-black text-white">
      <Header />

      <section className="mx-auto flex min-h-[calc(100vh-56px)] max-w-6xl items-center justify-center px-6 py-16">
        <div className="w-full max-w-md rounded-3xl border border-gray-700 bg-gradient-to-b from-[#1f2427] to-[#0d0d0d] p-8 shadow-2xl shadow-black/70">
          <p className="mb-3 text-sm font-semibold uppercase tracking-[0.25em] text-[#A6E824]">
            FantaGol
          </p>

          <h1 className="mb-3 text-3xl font-black">Crea il tuo account</h1>

          <p className="mb-8 text-gray-400">
            Registrati per creare leghe, ricevere inviti e iniziare a giocare.
          </p>

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

          <form onSubmit={handleRegister} className="space-y-4">
            <input
              type="text"
              required
              placeholder="Nome utente"
              value={username}
              onChange={(event) => setUsername(event.target.value)}
              className="w-full rounded-xl border border-gray-700 bg-[#111111] px-4 py-3 text-white outline-none transition placeholder:text-gray-500 focus:border-[#A6E824]"
            />

            <input
              type="email"
              required
              placeholder="Email"
              value={email}
              onChange={(event) => setEmail(event.target.value)}
              className="w-full rounded-xl border border-gray-700 bg-[#111111] px-4 py-3 text-white outline-none transition placeholder:text-gray-500 focus:border-[#A6E824]"
            />

            <input
              type="password"
              required
              placeholder="Password"
              value={password}
              onChange={(event) => setPassword(event.target.value)}
              className="w-full rounded-xl border border-gray-700 bg-[#111111] px-4 py-3 text-white outline-none transition placeholder:text-gray-500 focus:border-[#A6E824]"
            />

            <label className="flex items-start gap-3 text-sm text-gray-400">
              <input
                type="checkbox"
                required
                className="mt-1 h-4 w-4 rounded border-gray-700 bg-[#111111] accent-[#A6E824]"
              />
              <span>
                Accetto i{" "}
                <Link
                  href="/termini"
                  className="font-semibold text-[#A6E824] hover:brightness-110"
                >
                  Termini di utilizzo
                </Link>{" "}
                e ho letto l&apos;
                <Link
                  href="/privacy"
                  className="font-semibold text-[#A6E824] hover:brightness-110"
                >
                  Informativa Privacy
                </Link>
                .
              </span>
            </label>

            <button
              type="submit"
              disabled={loading}
              className="w-full rounded-xl bg-[#A6E824] px-5 py-3 font-semibold text-black shadow-lg shadow-[#A6E824]/20 transition hover:brightness-110 disabled:opacity-60"
            >
              {loading ? "Registrazione in corso..." : "Registrati"}
            </button>
          </form>

          <p className="mt-6 text-center text-sm text-gray-400">
            Hai già un account?{" "}
            <Link
              href={loginHref}
              className="font-semibold text-[#A6E824] hover:brightness-110"
            >
              Accedi
            </Link>
          </p>
        </div>
      </section>
    </main>
  );
}

