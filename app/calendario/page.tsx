"use client";

import { useEffect, useMemo, useState } from "react";
import FantaGolLogo from "../../components/FantaGolLogo";
import HamburgerDrawer from "../../components/app/HamburgerDrawer";
import { supabase } from "../../lib/supabaseClient";

type RoundStatus = "unused" | "closed" | "live" | "future";
type Mode = "puntipuri" | "fantacalcio" | "onetoone";

type LeagueInfo = {
  leagueName: string;
  displayName: string;
  inviteCode: string;
  role: string;
};

type Round = {
  round: number;
  label: string;
  status: RoundStatus;
};

const LEAGUE_START_ROUND = 3;

const rounds: Round[] = Array.from({ length: 38 }, (_, index) => {
  const round = index + 1;

  if (round < LEAGUE_START_ROUND) {
    return { round, label: `Giornata ${round}`, status: "unused" };
  }

  if (round <= 3) {
    return { round, label: `Giornata ${round}`, status: "closed" };
  }

  if (round === 4) {
    return { round, label: `Giornata ${round}`, status: "live" };
  }

  return { round, label: `Giornata ${round}`, status: "future" };
});

const roundData = {
  unused: {
    puntipuri: [],
    fantacalcio: [],
    onetoone: [],
  },

  closed: {
    puntipuri: [
      { pos: 1, club: "Real Exact", pts: 38 },
      { pos: 2, club: "FantaGol United", pts: 34 },
      { pos: 3, club: "Bonus Show", pts: 31 },
    ],
    fantacalcio: [
      { home: "Real Exact", away: "Bonus Show", score: "3-1", points: "38 - 31" },
      { home: "FantaGol United", away: "Club Sorpresa", score: "2-2", points: "34 - 33" },
      { home: "Gol Show FC", away: "Exact Boys", score: "1-0", points: "25 - 18" },
    ],
    onetoone: [
      { home: "Real Exact", away: "Bonus Show", score: "6-4" },
      { home: "FantaGol United", away: "Club Sorpresa", score: "5-5" },
      { home: "Gol Show FC", away: "Exact Boys", score: "7-3" },
    ],
  },

  live: {
    puntipuri: [
      { pos: 1, club: "Bonus Show", pts: 21 },
      { pos: 2, club: "Real Exact", pts: 19 },
      { pos: 3, club: "FantaGol United", pts: 17 },
    ],
    fantacalcio: [
      { home: "Bonus Show", away: "Real Exact", score: "2-1", points: "21 - 19" },
      { home: "FantaGol United", away: "Club Sorpresa", score: "1-1", points: "17 - 16" },
      { home: "Gol Show FC", away: "Exact Boys", score: "0-0", points: "9 - 8" },
    ],
    onetoone: [
      { home: "Bonus Show", away: "Real Exact", score: "4-3" },
      { home: "FantaGol United", away: "Club Sorpresa", score: "3-3" },
      { home: "Gol Show FC", away: "Exact Boys", score: "2-2" },
    ],
  },

  future: {
    puntipuri: [
      { pos: 1, club: "Real Exact", pts: "—" },
      { pos: 2, club: "FantaGol United", pts: "—" },
      { pos: 3, club: "Bonus Show", pts: "—" },
    ],
    fantacalcio: [
      { home: "Real Exact", away: "Bonus Show", score: "—", points: "—" },
      { home: "FantaGol United", away: "Club Sorpresa", score: "—", points: "—" },
      { home: "Gol Show FC", away: "Exact Boys", score: "—", points: "—" },
    ],
    onetoone: [
      { home: "Real Exact", away: "Bonus Show", score: "—" },
      { home: "FantaGol United", away: "Club Sorpresa", score: "—" },
      { home: "Gol Show FC", away: "Exact Boys", score: "—" },
    ],
  },
};

function statusLabel(status: RoundStatus) {
  if (status === "unused") return "Non utilizzata";
  if (status === "closed") return "Chiusa";
  if (status === "live") return "In corso";
  return "Da giocare";
}

function statusClass(status: RoundStatus, selected: boolean) {
  if (selected) return "text-black/70";

  if (status === "unused") return "text-red-300/80";
  if (status === "closed") return "text-gray-400";
  if (status === "live") return "text-[#A6E824]";
  return "text-gray-500";
}

export default function CalendarioPage() {
  const [selectedRound, setSelectedRound] = useState(4);
  const [activeMode, setActiveMode] = useState<Mode>("puntipuri");
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

      const { data } = await supabase.rpc("get_my_leagues_rpc");
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

  const activeRound = useMemo(
    () => rounds.find((round) => round.round === selectedRound) || rounds[0],
    [selectedRound]
  );

  const data = roundData[activeRound.status];

  return (
    <main className="min-h-screen bg-black pt-14 text-white">
      <header className="fixed inset-x-0 top-0 z-[80] border-b border-[#A6E824]/25 bg-[#1f2427] shadow-2xl shadow-black/80">
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
          Calendario
        </p>

        <h1 className="mt-3 text-5xl font-black">Giornate</h1>

        <p className="mt-4 max-w-2xl text-gray-400">
          Seleziona una giornata per vedere punti puri, risultati Fantacalcio e scontri One to One.
        </p>

        <div className="mt-8 grid grid-cols-3 gap-2 sm:grid-cols-4 md:grid-cols-6 lg:grid-cols-8">
          {rounds.map((round) => {
            const selected = selectedRound === round.round;

            return (
              <button
                key={round.round}
                type="button"
                onClick={() => {
                  setSelectedRound(round.round);
                  setActiveMode("puntipuri");
                }}
                className={`rounded-2xl border px-3 py-3 text-left transition ${
                  selected
                    ? "border-[#A6E824] bg-[#A6E824] text-black"
                    : round.status === "unused"
                      ? "border-gray-800 bg-[#111111]/60 text-gray-500 opacity-70 hover:border-red-300/40"
                      : "border-gray-800 bg-[#111111] text-white hover:border-[#A6E824]"
                }`}
              >
                <div className="text-sm font-black">G{round.round}</div>
                <div className={`mt-1 text-[10px] font-black uppercase ${statusClass(round.status, selected)}`}>
                  {statusLabel(round.status)}
                </div>
              </button>
            );
          })}
        </div>

        <div className="mt-8 rounded-3xl border border-gray-700 bg-[#111111] p-6">
          <div className="flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
            <div>
              <p className="text-sm font-semibold uppercase tracking-[0.25em] text-[#A6E824]">
                {statusLabel(activeRound.status)}
              </p>
              <h2 className="mt-2 text-3xl font-black">{activeRound.label}</h2>
              <p className="mt-2 text-sm leading-6 text-gray-400">
                {activeRound.status === "unused" &&
                  "Questa giornata è precedente all'inizio della lega e non verrà conteggiata."}
                {activeRound.status === "closed" &&
                  "Risultati ufficiali della giornata conclusa."}
                {activeRound.status === "live" &&
                  "Dati live aggiornati al momento. I risultati sono provvisori."}
                {activeRound.status === "future" &&
                  "Giornata programmata. I campi resteranno vuoti fino all'inizio del turno."}
              </p>
            </div>

            <div className="flex flex-wrap gap-2">
              <button
                type="button"
                onClick={() => setActiveMode("puntipuri")}
                className={`rounded-xl px-4 py-2 text-sm font-black ${
                  activeMode === "puntipuri"
                    ? "bg-[#A6E824] text-black"
                    : "bg-black text-gray-300"
                }`}
              >
                Punti Puri
              </button>

              <button
                type="button"
                onClick={() => setActiveMode("fantacalcio")}
                className={`rounded-xl px-4 py-2 text-sm font-black ${
                  activeMode === "fantacalcio"
                    ? "bg-[#A6E824] text-black"
                    : "bg-black text-gray-300"
                }`}
              >
                Fantacalcio
              </button>

              <button
                type="button"
                onClick={() => setActiveMode("onetoone")}
                className={`rounded-xl px-4 py-2 text-sm font-black ${
                  activeMode === "onetoone"
                    ? "bg-[#A6E824] text-black"
                    : "bg-black text-gray-300"
                }`}
              >
                One to One
              </button>
            </div>
          </div>

          {activeRound.status === "unused" && (
            <div className="mt-6 rounded-3xl border border-gray-800 bg-black p-6 text-center">
              <div className="mx-auto flex h-14 w-14 items-center justify-center rounded-full border border-red-300/30 bg-red-950/20 text-2xl">
                ⛔
              </div>
              <h3 className="mt-4 text-2xl font-black">Giornata non utilizzata</h3>
              <p className="mx-auto mt-3 max-w-xl text-sm leading-6 text-gray-400">
                La lega è stata avviata a campionato già iniziato. Questa giornata resta
                congelata: non ci sono pronostici, punti puri, risultati Fantacalcio o
                scontri One to One da visualizzare.
              </p>
            </div>
          )}

          {activeRound.status !== "unused" && activeMode === "puntipuri" && (
            <div className="mt-6 overflow-hidden rounded-3xl border border-gray-800 bg-black">
              {data.puntipuri.map((row) => (
                <div
                  key={row.pos}
                  className="grid grid-cols-[42px_1fr_auto] items-center gap-3 border-b border-white/10 px-4 py-4 last:border-b-0"
                >
                  <div className="text-lg font-black text-gray-500">{row.pos}</div>
                  <div className="font-black">{row.club}</div>
                  <div className="text-2xl font-black text-[#A6E824]">{row.pts}</div>
                </div>
              ))}
            </div>
          )}

          {activeRound.status !== "unused" && activeMode === "fantacalcio" && (
            <div className="mt-6 grid gap-3">
              {data.fantacalcio.map((match) => (
                <div
                  key={`${match.home}-${match.away}`}
                  className="rounded-3xl border border-gray-800 bg-black p-4"
                >
                  <div className="grid grid-cols-[1fr_auto_1fr] items-center gap-2 sm:gap-3">
                    <div className="whitespace-normal break-words text-right text-xs font-black leading-tight sm:text-sm">
                      {match.home}
                    </div>
                    <div className="rounded-xl bg-[#A6E824]/10 px-3 py-2 text-center text-base font-black text-[#A6E824] sm:px-4 sm:text-xl">
                      {match.score}
                    </div>
                    <div className="whitespace-normal break-words text-left text-xs font-black leading-tight sm:text-sm">
                      {match.away}
                    </div>
                  </div>

                  <div className="mt-3 text-center text-xs font-bold text-gray-500">
                    Punti FantaGol: {match.points}
                  </div>
                </div>
              ))}
            </div>
          )}

          {activeRound.status !== "unused" && activeMode === "onetoone" && (
            <div className="mt-6 grid gap-3">
              {data.onetoone.map((match) => (
                <div
                  key={`${match.home}-${match.away}`}
                  className="rounded-3xl border border-gray-800 bg-black p-4"
                >
                  <div className="grid grid-cols-[1fr_auto_1fr] items-center gap-2 sm:gap-3">
                    <div className="whitespace-normal break-words text-right text-xs font-black leading-tight sm:text-sm">
                      {match.home}
                    </div>
                    <div className="rounded-xl bg-[#A6E824]/10 px-3 py-2 text-center text-base font-black text-[#A6E824] sm:px-4 sm:text-xl">
                      {match.score}
                    </div>
                    <div className="whitespace-normal break-words text-left text-xs font-black leading-tight sm:text-sm">
                      {match.away}
                    </div>
                  </div>

                  <div className="mt-3 text-center text-xs font-bold text-gray-500">
                    Mini-sfide vinte nella giornata
                  </div>
                </div>
              ))}
            </div>
          )}
        </div>
      </section>
    </main>
  );
}

