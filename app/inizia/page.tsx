"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import Header from "../../components/Header";
import { supabase } from "../../lib/supabaseClient";

function extractInviteCode(value: string): string {
  const normalized = value.trim();

  if (!normalized) {
    return "";
  }

  try {
    const url = new URL(normalized);
    const match = url.pathname.match(/^\/invito\/([^/?#]+)\/?$/i);

    if (match?.[1]) {
      return decodeURIComponent(match[1]).trim();
    }
  } catch {
    // Il valore non è un URL completo: viene trattato come codice invito.
  }

  const relativeMatch = normalized.match(
    /^(?:https?:\/\/[^/]+)?\/?invito\/([^/?#]+)\/?$/i,
  );

  if (relativeMatch?.[1]) {
    return decodeURIComponent(relativeMatch[1]).trim();
  }

  return normalized;
}

export default function IniziaPage() {
  const [inviteValue, setInviteValue] = useState("");
  const [sessionChecked, setSessionChecked] = useState(false);

  useEffect(() => {
    let cancelled = false;

    async function verifySession() {
      const {
        data: { session },
      } = await supabase.auth.getSession();

      if (cancelled) {
        return;
      }

      if (!session?.user) {
        const destination = "/inizia";
        window.localStorage.setItem(
          "fantagol.pendingAuthDestination.v1",
          destination,
        );
        window.location.replace(
          `/login?returnTo=${encodeURIComponent(destination)}`,
        );
        return;
      }

      setSessionChecked(true);
    }

    void verifySession();

    return () => {
      cancelled = true;
    };
  }, []);

  function handleInviteSubmit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();

    const inviteCode = extractInviteCode(inviteValue);

    if (!inviteCode) {
      alert("Inserisci un link o un codice invito valido.");
      return;
    }

    window.location.assign(`/invito/${encodeURIComponent(inviteCode)}`);
  }

  return (
    <main className="min-h-screen bg-black text-white">
      <Header />

      <section className="mx-auto max-w-6xl px-6 py-16">
        <p className="mb-3 text-sm font-semibold uppercase tracking-[0.25em] text-[#A6E824]">
          Inizia
        </p>

        <h1 className="text-4xl font-black">Come vuoi entrare in gioco?</h1>

        <p className="mt-3 max-w-2xl text-gray-400">
          Usa un invito, crea una nuova lega oppure scopri le leghe pubbliche
          disponibili.
        </p>

        <div className="mt-10 grid gap-6 lg:grid-cols-3">
          <article className="rounded-3xl border border-gray-700 bg-gradient-to-b from-[#1f2427] to-[#0d0d0d] p-6">
            <p className="text-sm font-semibold uppercase tracking-[0.18em] text-[#A6E824]">
              Invito
            </p>

            <h2 className="mt-3 text-2xl font-black">
              Accedi con link o codice
            </h2>

            <p className="mt-3 text-sm leading-6 text-gray-400">
              Incolla il link ricevuto oppure inserisci direttamente il codice
              invito della lega.
            </p>

            <form onSubmit={handleInviteSubmit} className="mt-6 space-y-4">
              <input
                type="text"
                required
                value={inviteValue}
                onChange={(event) => setInviteValue(event.target.value)}
                placeholder="FG-ABC123 oppure link invito"
                disabled={!sessionChecked}
                className="w-full rounded-xl border border-gray-700 bg-[#111111] px-4 py-3 text-white outline-none transition placeholder:text-gray-500 focus:border-[#A6E824] disabled:opacity-60"
              />

              <button
                type="submit"
                disabled={!sessionChecked}
                className="w-full rounded-xl bg-[#A6E824] px-5 py-3 font-semibold text-black transition hover:brightness-110 disabled:opacity-60"
              >
                Accedi alla lega
              </button>
            </form>
          </article>

          <article className="flex rounded-3xl border border-gray-700 bg-gradient-to-b from-[#1f2427] to-[#0d0d0d] p-6">
            <div className="flex w-full flex-col">
              <p className="text-sm font-semibold uppercase tracking-[0.18em] text-[#A6E824]">
                Nuova lega
              </p>

              <h2 className="mt-3 text-2xl font-black">Crea una lega</h2>

              <p className="mt-3 text-sm leading-6 text-gray-400">
                Configura una nuova competizione e scegli se renderla privata o
                pubblica.
              </p>

              <Link
                href="/crea-lega"
                aria-disabled={!sessionChecked}
                className={`mt-auto block rounded-xl border px-5 py-3 text-center font-semibold transition ${
                  sessionChecked
                    ? "border-[#A6E824] text-[#A6E824] hover:bg-[#A6E824]/10"
                    : "pointer-events-none border-gray-700 text-gray-600"
                }`}
              >
                Crea una lega
              </Link>
            </div>
          </article>

          <article className="flex rounded-3xl border border-gray-700 bg-gradient-to-b from-[#1f2427] to-[#0d0d0d] p-6">
            <div className="flex w-full flex-col">
              <p className="text-sm font-semibold uppercase tracking-[0.18em] text-[#A6E824]">
                Catalogo pubblico
              </p>

              <h2 className="mt-3 text-2xl font-black">
                Vai alle leghe pubbliche
              </h2>

              <p className="mt-3 text-sm leading-6 text-gray-400">
                Esplora le leghe pubbliche, consulta quelle aperte o chiuse e
                associati alle competizioni ancora disponibili.
              </p>

              <Link
                href="/leghe/pubbliche"
                aria-disabled={!sessionChecked}
                className={`mt-auto block rounded-xl border px-5 py-3 text-center font-semibold transition ${
                  sessionChecked
                    ? "border-[#A6E824] text-[#A6E824] hover:bg-[#A6E824]/10"
                    : "pointer-events-none border-gray-700 text-gray-600"
                }`}
              >
                Esplora le leghe pubbliche
              </Link>
            </div>
          </article>
        </div>

        <div className="mt-8 text-center">
          <Link
            href="/leghe"
            className="text-sm font-semibold text-gray-400 transition hover:text-white"
          >
            Vai alle mie leghe
          </Link>
        </div>
      </section>
    </main>
  );
}
