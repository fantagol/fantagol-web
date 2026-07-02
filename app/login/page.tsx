"use client";

import { useEffect, useState } from "react";
import Header from "../../components/Header";
import { supabase } from "../../lib/supabaseClient";

export default function LoginPage() {
  const [alreadyLogged, setAlreadyLogged] = useState(false);

  useEffect(() => {
    async function checkSession() {
      const {
        data: { session },
      } = await supabase.auth.getSession();

      if (session?.user) {
        setAlreadyLogged(true);
      }
    }

    checkSession();
  }, []);

  async function handleGoogleLogin() {
    const { error } = await supabase.auth.signInWithOAuth({
      provider: "google",
      options: {
        redirectTo: `${window.location.origin}/auth/callback`,
      },
    });

    if (error) {
      alert(error.message);
    }
  }

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

          {alreadyLogged && (
            <div className="mb-6 rounded-2xl border border-[#A6E824]/40 bg-[#A6E824]/10 p-4 text-center">
              <p className="font-semibold text-[#A6E824]">
                Sei già connesso.
              </p>

              <a
                href="/leghe"
                className="mt-3 inline-block rounded-xl bg-[#A6E824] px-5 py-2 font-semibold text-black transition hover:brightness-110"
              >
                Vai alle tue leghe
              </a>
            </div>
          )}

          {!alreadyLogged && (
            <>
              <button
                type="button"
                onClick={handleGoogleLogin}
                className="mb-6 w-full rounded-xl border border-gray-600 bg-white px-5 py-3 font-semibold text-black transition hover:bg-gray-200"
              >
                Continua con Google
              </button>

              <div className="mb-6 flex items-center gap-4 text-sm text-gray-500">
                <div className="h-px flex-1 bg-gray-700" />
                oppure
                <div className="h-px flex-1 bg-gray-700" />
              </div>

              <form className="space-y-4">
                <input
                  type="email"
                  placeholder="Email"
                  className="w-full rounded-xl border border-gray-700 bg-[#111111] px-4 py-3 text-white outline-none transition placeholder:text-gray-500 focus:border-[#A6E824]"
                />

                <input
                  type="password"
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
                  className="w-full rounded-xl bg-[#A6E824] px-5 py-3 font-semibold text-black shadow-lg shadow-[#A6E824]/20 transition hover:brightness-110"
                >
                  Accedi
                </button>

                <div className="py-1 text-center">
                  <a
                    href="/password-reset"
                    className="text-sm font-semibold text-[#A6E824] hover:brightness-110"
                  >
                    Password dimenticata?
                  </a>
                </div>
              </form>

              <p className="mt-6 text-center text-sm text-gray-400">
                Non hai un account?{" "}
                <a
                  href="/registrati"
                  className="font-semibold text-[#A6E824] hover:brightness-110"
                >
                  Registrati
                </a>
              </p>
            </>
          )}
        </div>
      </section>
    </main>
  );
}