"use client";

import { useEffect, useState } from "react";
import { supabase } from "../../lib/supabaseClient";

type Membership = {
  id: string;
  display_name: string;
  role: string;
  status: string;
  leagues: {
    id: string;
    name: string;
    invite_code: string;
  } | null;
};

export default function LeghePage() {
  const [memberships, setMemberships] = useState<Membership[]>([]);
  const [loading, setLoading] = useState(true);

  async function loadLeagues() {
    setLoading(true);

    const {
      data: { session },
    } = await supabase.auth.getSession();

    if (!session?.user) {
      window.location.href = "/login";
      return;
    }

    const { data, error } = await supabase.rpc("get_my_leagues_rpc");

    if (error) {
      alert(error.message);
      setLoading(false);
      return;
    }

    setMemberships(
      (data || []).map((row: any) => ({
        id: row.membership_id,
        display_name: row.display_name,
        role: row.role,
        status: row.status,
        leagues: {
          id: row.league_id,
          name: row.league_name,
          invite_code: row.invite_code,
        },
      }))
    );

    setLoading(false);
  }

  async function handleArchiveLeague(leagueId: string, leagueName: string) {
    const confirmed = window.confirm(
      `Vuoi archiviare la lega "${leagueName}"?\n\nLa lega non sarà più visibile ai membri, ma i dati resteranno conservati.`
    );

    if (!confirmed) return;

    const { error } = await supabase.rpc("delete_league_rpc", {
      target_league_id: leagueId,
    });

    if (error) {
      alert(error.message);
      return;
    }

    await loadLeagues();
  }

  useEffect(() => {
    loadLeagues();
  }, []);

  return (
    <main className="min-h-screen bg-black text-white">

      <section className="mx-auto max-w-6xl px-6 py-16">
        <p className="mb-3 text-sm font-semibold uppercase tracking-[0.25em] text-[#A6E824]">
          Le mie leghe
        </p>

        <h1 className="text-4xl font-black">Scegli la lega</h1>

        <p className="mt-3 text-gray-400">
          Qui trovi tutte le leghe a cui partecipi.
        </p>

        {loading && (
          <p className="mt-10 text-gray-400">Caricamento leghe...</p>
        )}

        {!loading && memberships.length === 0 && (
          <div className="mt-10 rounded-3xl border border-gray-700 bg-[#111111] p-6">
            <p className="text-gray-300">Non partecipi ancora a nessuna lega.</p>

            <a
              href="/crea-lega"
              className="mt-5 inline-block rounded-xl bg-[#A6E824] px-6 py-3 font-semibold text-black transition hover:brightness-110"
            >
              Crea la tua prima lega
            </a>
          </div>
        )}

        {!loading && memberships.length > 0 && (
          <div className="mt-10 grid gap-5 md:grid-cols-2">
            {memberships.map((membership) => (
              <div
                key={membership.id}
                className="rounded-3xl border border-gray-700 bg-gradient-to-b from-[#1f2427] to-[#0d0d0d] p-6 transition hover:border-[#A6E824]"
              >
                <a href={`/leghe/${membership.leagues?.id}`}>
                  <h2 className="text-2xl font-black">
                    {membership.leagues?.name}
                  </h2>

                  <p className="mt-2 text-gray-400">
                    Nome nella lega: {membership.display_name}
                  </p>

                  <p className="mt-1 text-sm text-gray-500">
                    Ruolo: {membership.role}
                  </p>

                  <p className="mt-4 text-sm font-semibold text-[#A6E824]">
                    Entra nella lega →
                  </p>
                </a>

                {membership.role === "owner" && membership.leagues && (
                  <button
                    type="button"
                    onClick={() =>
                      handleArchiveLeague(
                        membership.leagues!.id,
                        membership.leagues!.name
                      )
                    }
                    className="mt-5 w-full rounded-xl border border-red-500/40 px-4 py-2 text-sm font-semibold text-red-400 transition hover:border-red-400 hover:bg-red-950/30"
                  >
                    Archivia lega
                  </button>
                )}
              </div>
            ))}
          </div>
        )}
      </section>
    </main>
  );
}

