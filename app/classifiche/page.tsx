"use client";

import { useEffect, useState } from "react";
import FantaGolLogo from "../../components/FantaGolLogo";
import HamburgerDrawer from "../../components/app/HamburgerDrawer";
import { supabase } from "../../lib/supabaseClient";

type Mode = "puntipuri" | "fantacalcio" | "onetoone";

type LeagueInfo = {
  leagueName: string;
  displayName: string;
  inviteCode: string;
  role: string;
};

const standings = {
  puntipuri: [
    { pos: 1, club: "Real Exact", pts: 362 },
    { pos: 2, club: "FantaGol United", pts: 358 },
    { pos: 3, club: "Bonus Show", pts: 351 },
  ],

  fantacalcio: [
    { pos: 1, club: "FantaGol United", pts: 48 },
    { pos: 2, club: "Real Exact", pts: 45 },
    { pos: 3, club: "Bonus Show", pts: 42 },
  ],

  onetoone: [
    { pos: 1, club: "Bonus Show", pts: 17 },
    { pos: 2, club: "FantaGol United", pts: 15 },
    { pos: 3, club: "Real Exact", pts: 14 },
  ],
};

const modeDescriptions = {
  puntipuri: "Classifica assoluta basata sulla somma dei punti FantaGol.",
  fantacalcio: "I punti FantaGol vengono convertiti in gol tramite le fasce ufficiali.",
  onetoone: "Campionato a scontri diretti con calendario andata e ritorno.",
};

export default function ClassifichePage() {
  const [mode, setMode] = useState<Mode>("puntipuri");
  const [menuOpen, setMenuOpen] = useState(false);
  const [leagueInfo, setLeagueInfo] = useState<LeagueInfo>({
    leagueName: "FantaGol",
    displayName: "Club FantaGol",
    inviteCode: "",
    role: "member",
  });

  useEffect(() => {
    async function loadLeagueInfo() {
      const {
        data: { session },
      } = await supabase.auth.getSession();

      if (!session?.user) {
        window.location.href = "/login";
        return;
      }

      const { data, error } = await supabase.rpc("get_my_leagues_rpc");

      if (error) return;

      const firstLeague = (data || [])[0];

      if (firstLeague) {
        setLeagueInfo({
          leagueName: firstLeague.league_name || "Lega FantaGol",
          displayName: firstLeague.display_name || "Club FantaGol",
          inviteCode: firstLeague.invite_code || firstLeague.league_id || "",
          role: firstLeague.role || "member",
        });
      }
    }

    loadLeagueInfo();
  }, []);

  return (
    <main className="min-h-screen bg-black pt-14 text-white">
      <header className="fixed inset-x-0 top-0 z-[80] border-b border-[#A6E824]/25 bg-gradient-to-r from-[#2a2f32] via-[#1f2427] to-[#2a2f32] shadow-2xl shadow-black/80 backdrop-blur">
        <div className="mx-auto flex h-14 max-w-6xl items-center justify-between px-4 md:px-6">
          <div className="pointer-events-none relative z-0 block -translate-x-8 translate-y-5 md:-translate-x-20 md:translate-y-6">
            <FantaGolLogo />
          </div>

          <button
            type="button"
            onClick={() => setMenuOpen(true)}
            aria-label="Apri menu"
            className="rounded-lg border border-gray-600 bg-[#2b2f31] px-3 py-2 text-2xl leading-none text-white transition hover:border-[#A6E824]"
          >
            ☰
          </button>
        </div>
      </header>

      <HamburgerDrawer
        open={menuOpen}
        leagueName={leagueInfo.leagueName}
        displayName={leagueInfo.displayName}
        inviteCode={leagueInfo.inviteCode}
        role={leagueInfo.role}
        onClose={() => setMenuOpen(false)}
      />

      <section className="mx-auto max-w-6xl px-6 py-10">
        <p className="text-sm font-semibold uppercase tracking-[0.3em] text-[#A6E824]">
          Lega
        </p>

        <h1 className="mt-3 text-5xl font-black">Classifiche</h1>

        <p className="mt-4 max-w-2xl text-gray-400">
          Le tre classifiche ufficiali della lega: Punti Puri, Fantacalcio e One to One.
        </p>

        <div className="mt-8 flex flex-wrap gap-3">
          <button
            onClick={() => setMode("puntipuri")}
            className={`rounded-xl px-5 py-3 font-bold transition ${
              mode === "puntipuri"
                ? "bg-[#A6E824] text-black"
                : "bg-[#1f2427] text-white hover:bg-[#2a3033]"
            }`}
          >
            ⭐ Punti Puri
          </button>

          <button
            onClick={() => setMode("fantacalcio")}
            className={`rounded-xl px-5 py-3 font-bold transition ${
              mode === "fantacalcio"
                ? "bg-[#A6E824] text-black"
                : "bg-[#1f2427] text-white hover:bg-[#2a3033]"
            }`}
          >
            🏆 Fantacalcio
          </button>

          <button
            onClick={() => setMode("onetoone")}
            className={`rounded-xl px-5 py-3 font-bold transition ${
              mode === "onetoone"
                ? "bg-[#A6E824] text-black"
                : "bg-[#1f2427] text-white hover:bg-[#2a3033]"
            }`}
          >
            ⚔️ One to One
          </button>
        </div>

        <div className="mt-6 rounded-3xl border border-gray-700 bg-[#111111] p-6">
          <div className="flex flex-col gap-2 md:flex-row md:items-end md:justify-between">
            <div>
              <h2 className="text-2xl font-black">
                {mode === "puntipuri"
                  ? "Punti Puri"
                  : mode === "fantacalcio"
                    ? "Fantacalcio"
                    : "One to One"}
              </h2>

              <p className="mt-2 text-sm leading-6 text-gray-400">
                {modeDescriptions[mode]}
              </p>
            </div>

            <div className="rounded-2xl bg-black px-4 py-3 text-sm font-black text-[#A6E824]">
              Giornata 1
            </div>
          </div>

          <div className="mt-6 overflow-hidden rounded-3xl border border-gray-700">
            <table className="w-full">
              <thead className="bg-[#1f2427]">
                <tr>
                  <th className="px-5 py-4 text-left">#</th>
                  <th className="px-5 py-4 text-left">Club</th>
                  <th className="px-5 py-4 text-right">Punti</th>
                </tr>
              </thead>

              <tbody>
                {standings[mode].map((club) => (
                  <tr key={club.pos} className="border-t border-gray-800">
                    <td className="px-5 py-4 font-black text-gray-400">
                      {club.pos}
                    </td>

                    <td className="px-5 py-4 font-bold">
                      {club.club}
                    </td>

                    <td className="px-5 py-4 text-right font-black text-[#A6E824]">
                      {club.pts}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      </section>
    </main>
  );
}
