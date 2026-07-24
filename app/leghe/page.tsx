"use client";

import { useCallback, useEffect, useState } from "react";
import Header from "../../components/Header";
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

type MyLeagueRpcRow = {
  membership_id: string;
  display_name: string;
  role: string;
  status: string;
  league_id: string;
  league_name: string;
  invite_code: string;
};

export default function LeghePage() {
  const [memberships, setMemberships] = useState<Membership[]>([]);
  const [loading, setLoading] = useState(true);

  const loadLeagues = useCallback(async () => {
    setLoading(true);

    const {
      data: { session },
    } = await supabase.auth.getSession();

    if (!session?.user) {
      const destination = "/leghe";

      window.localStorage.setItem(
        "fantagol.pendingAuthDestination.v1",
        destination,
      );

      window.location.replace(
        `/login?returnTo=${encodeURIComponent(destination)}`,
      );
      return;
    }

    const { data, error } = await supabase.rpc("get_my_leagues_rpc");

    if (error) {
      alert(error.message);
      setLoading(false);
      return;
    }

    const rows = (data ?? []) as MyLeagueRpcRow[];

    const loadedMemberships: Membership[] = rows.map((row) => ({
      id: row.membership_id,
      display_name: row.display_name,
      role: row.role,
      status: row.status,
      leagues: {
        id: row.league_id,
        name: row.league_name,
        invite_code: row.invite_code,
      },
    }));

    const activeMemberships = loadedMemberships.filter(
      (membership) => membership.status === "active" && membership.leagues?.id,
    );

    if (activeMemberships.length === 0) {
      window.location.replace("/inizia");
      return;
    }

    if (activeMemberships.length === 1) {
      window.location.replace(`/leghe/${activeMemberships[0].leagues!.id}`);
      return;
    }

    setMemberships(activeMemberships);
    setLoading(false);
  }, []);

  useEffect(() => {
    queueMicrotask(() => {
      void loadLeagues();
    });
  }, [loadLeagues]);

  return (
    <main className="min-h-screen bg-black text-white">
      <Header />

      <section className="mx-auto max-w-6xl px-6 py-16">
        <p className="mb-3 text-sm font-semibold uppercase tracking-[0.25em] text-[#A6E824]">
          Le mie leghe
        </p>

        <h1 className="text-4xl font-black">Scegli la lega</h1>

        <p className="mt-3 text-gray-400">
          Partecipi a più leghe. Scegli quale vuoi aprire.
        </p>

        {loading && (
          <p className="mt-10 text-gray-400">Caricamento leghe...</p>
        )}

        {!loading && memberships.length > 1 && (
          <div className="mt-10 grid gap-5 md:grid-cols-2">
            {memberships.map((membership) => (
              <a
                key={membership.id}
                href={`/leghe/${membership.leagues?.id}`}
                className="rounded-3xl border border-gray-700 bg-gradient-to-b from-[#1f2427] to-[#0d0d0d] p-6 transition hover:border-[#A6E824]"
              >
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
            ))}
          </div>
        )}

        {!loading && (
          <div className="mt-8 text-center">
            <a
              href="/inizia"
              className="text-sm font-semibold text-gray-400 transition hover:text-white"
            >
              Torna alle opzioni iniziali
            </a>
          </div>
        )}
      </section>
    </main>
  );
}
