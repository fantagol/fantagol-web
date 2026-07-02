"use client";

import { useState } from "react";
import { useParams } from "next/navigation";
import Header from "../../../components/Header";
import { supabase } from "../../../lib/supabaseClient";

export default function InvitoPage() {
  const params = useParams();
  const codice = params.codice as string;

  const [displayName, setDisplayName] = useState("");
  const [loading, setLoading] = useState(false);

  async function handleJoinLeague(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setLoading(true);

    const {
      data: { session },
    } = await supabase.auth.getSession();

    if (!session?.user) {
      setLoading(false);
      alert("Devi accedere prima di entrare in una lega.");
      window.location.href = "/login";
      return;
    }

    const { data, error } = await supabase.rpc("join_league_rpc", {
      target_invite_code: codice,
      member_display_name: displayName,
    });

    if (error) {
      setLoading(false);
      alert(error.message);
      return;
    }

    const leagueId = data?.[0]?.joined_league_id;

    if (!leagueId) {
      setLoading(false);
      alert("Errore durante l'ingresso nella lega.");
      return;
    }

    window.location.href = `/leghe/${leagueId}`;
  }

  return (
    <main className="min-h-screen bg-black text-white">
      <Header />

      <section className="mx-auto flex min-h-[calc(100vh-56px)] max-w-6xl items-center justify-center px-6 py-16">
        <div className="w-full max-w-md rounded-3xl border border-gray-700 bg-gradient-to-b from-[#1f2427] to-[#0d0d0d] p-8 shadow-2xl shadow-black/70">
          <p className="mb-3 text-sm font-semibold uppercase tracking-[0.25em] text-[#A6E824]">
            Invito lega
          </p>

          <h1 className="mb-3 text-3xl font-black">Entra nella lega</h1>

          <p className="mb-6 text-gray-400">
            Hai ricevuto un invito FantaGol. Scegli il nome con cui vuoi apparire
            in questa lega.
          </p>

          <div className="mb-6 rounded-2xl border border-gray-700 bg-black p-4 text-sm text-gray-300">
            Codice invito:{" "}
            <span className="font-bold text-[#A6E824]">{codice}</span>
          </div>

          <form onSubmit={handleJoinLeague} className="space-y-5">
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
              {loading ? "Ingresso in corso..." : "Entra nella lega"}
            </button>
          </form>

          <p className="mt-6 text-center text-sm text-gray-500">
            Ogni utente può scegliere un nome diverso per ogni lega.
          </p>
        </div>
      </section>
    </main>
  );
}