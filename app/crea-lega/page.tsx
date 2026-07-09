"use client";

import { useState } from "react";
import Header from "../../components/Header";
import { supabase } from "../../lib/supabaseClient";

export default function CreaLegaPage() {
  const [leagueName, setLeagueName] = useState("");
  const [displayName, setDisplayName] = useState("");
  const [inviteLink, setInviteLink] = useState("");
  const [loading, setLoading] = useState(false);

  async function handleCreateLeague(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setLoading(true);

    const { data, error } = await supabase.rpc("create_league_rpc", {
      league_name: leagueName,
      member_display_name: displayName,
    });

    if (error) {
      setLoading(false);
      alert(error.message);
      return;
    }

    const result = data?.[0];

    if (!result) {
      setLoading(false);
      alert("Errore nella creazione della lega.");
      return;
    }

    setInviteLink(`${window.location.origin}/invito/${result.invite_code}`);
    setLoading(false);
  }

  return (
    <main className="min-h-screen bg-black text-white">
      <Header />

      <section className="mx-auto flex min-h-[calc(100vh-56px)] max-w-6xl items-center justify-center px-6 py-16">
        <div className="w-full max-w-xl rounded-3xl border border-gray-700 bg-gradient-to-b from-[#1f2427] to-[#0d0d0d] p-8 shadow-2xl shadow-black/70">
          <p className="mb-3 text-sm font-semibold uppercase tracking-[0.25em] text-[#A6E824]">
            Nuova Lega
          </p>

          <h1 className="mb-3 text-3xl font-black">Crea la tua lega</h1>

          <p className="mb-8 text-gray-400">
            Dai un nome alla lega, scegli il tuo nome dentro questa lega e genera
            il link invito da condividere.
          </p>

          <form onSubmit={handleCreateLeague} className="space-y-5">
            <div>
              <label className="mb-2 block text-sm font-semibold text-gray-300">
                Nome lega
              </label>
              <input
                type="text"
                required
                value={leagueName}
                onChange={(e) => setLeagueName(e.target.value)}
                placeholder="Es. Amici del Bar"
                className="w-full rounded-xl border border-gray-700 bg-[#111111] px-4 py-3 text-white outline-none transition placeholder:text-gray-500 focus:border-[#A6E824]"
              />
            </div>

            <div>
              <label className="mb-2 block text-sm font-semibold text-gray-300">
                Il tuo nome in questa lega
              </label>
              <input
                type="text"
                required
                value={displayName}
                onChange={(e) => setDisplayName(e.target.value)}
                placeholder="Es. Cesare"
                className="w-full rounded-xl border border-gray-700 bg-[#111111] px-4 py-3 text-white outline-none transition placeholder:text-gray-500 focus:border-[#A6E824]"
              />
            </div>

            <button
              type="submit"
              disabled={loading}
              className="w-full rounded-xl bg-[#A6E824] px-5 py-3 font-semibold text-black shadow-lg shadow-[#A6E824]/20 transition hover:brightness-110 disabled:opacity-60"
            >
              {loading ? "Creazione in corso..." : "Crea Lega"}
            </button>
          </form>

          {inviteLink && (
            <div className="mt-8 rounded-2xl border border-gray-700 bg-[#111111] p-5">
              <p className="mb-2 text-sm font-semibold text-gray-300">
                Link invito generato
              </p>

              <div className="rounded-xl border border-gray-700 bg-black px-4 py-3 text-sm text-gray-300">
                {inviteLink}
              </div>

              <button
                type="button"
                onClick={() => navigator.clipboard.writeText(inviteLink)}
                className="mt-4 w-full rounded-xl border border-[#A6E824]/50 px-5 py-3 font-semibold text-[#A6E824] transition hover:border-[#A6E824]"
              >
                Copia Link
              </button>
            </div>
          )}
        </div>
      </section>
    </main>
  );
}
