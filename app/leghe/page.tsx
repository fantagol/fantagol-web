"use client";

import { useEffect, useState } from "react";
import { supabase } from "../../lib/supabaseClient";

const LAST_LEAGUE_STORAGE_KEY = "fantagol:last-league-id";

type MyLeagueRpcRow = {
  league_id: string;
  membership_id?: string | null;
  league_name?: string | null;
  display_name?: string | null;
  invite_code?: string | null;
  role?: string | null;
  status?: string | null;
};

export default function LeghePage() {
  const [errorMessage, setErrorMessage] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;

    async function resolveLeagueEntry() {
      const {
        data: { session },
      } = await supabase.auth.getSession();

      if (cancelled) return;

      if (!session?.user) {
        window.location.replace("/login");
        return;
      }

      const { data, error } = await supabase.rpc("get_my_leagues_rpc");

      if (cancelled) return;

      if (error) {
        setErrorMessage(error.message);
        return;
      }

      const leagues = ((data || []) as MyLeagueRpcRow[]).filter(
        (row) => Boolean(row.league_id)
      );

      if (leagues.length === 0) {
        window.location.replace("/crea-lega");
        return;
      }

      const storedLeagueId = window.localStorage.getItem(
        LAST_LEAGUE_STORAGE_KEY
      );

      const targetLeague =
        leagues.find((row) => row.league_id === storedLeagueId) || leagues[0];

      window.localStorage.setItem(
        LAST_LEAGUE_STORAGE_KEY,
        targetLeague.league_id
      );

      window.location.replace(`/leghe/${targetLeague.league_id}`);
    }

    void resolveLeagueEntry();

    return () => {
      cancelled = true;
    };
  }, []);

  return (
    <main className="flex min-h-screen items-center justify-center bg-black px-6 text-white">
      <div className="w-full max-w-md rounded-3xl border border-white/10 bg-[#111417] p-8 text-center shadow-2xl shadow-black/70">
        <p className="text-xs font-black uppercase tracking-[0.25em] text-[#A6E824]">
          FantaGol
        </p>

        {errorMessage ? (
          <>
            <h1 className="mt-4 text-2xl font-black">
              Impossibile aprire la lega
            </h1>
            <p className="mt-3 text-sm leading-6 text-red-200">
              {errorMessage}
            </p>
            <button
              type="button"
              onClick={() => window.location.reload()}
              className="mt-6 rounded-xl bg-[#A6E824] px-5 py-3 text-sm font-black text-black transition hover:brightness-110"
            >
              Riprova
            </button>
          </>
        ) : (
          <>
            <h1 className="mt-4 text-2xl font-black">
              Accesso alla tua lega...
            </h1>
            <p className="mt-3 text-sm text-gray-400">
              Stiamo aprendo automaticamente l&apos;ultima lega utilizzata.
            </p>
            <div className="mx-auto mt-6 h-8 w-8 animate-spin rounded-full border-2 border-white/15 border-t-[#A6E824]" />
          </>
        )}
      </div>
    </main>
  );
}
