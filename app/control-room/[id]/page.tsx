"use client";

import { useEffect, useMemo, useState } from "react";
import { useParams } from "next/navigation";
import FantaGolLogo from "../../../components/FantaGolLogo";
import HamburgerDrawer from "../../../components/app/HamburgerDrawer";
import { supabase } from "../../../lib/supabaseClient";

type LeagueInfo = {
  leagueName: string;
  displayName: string;
  inviteCode: string;
  role: string;
};

type ExactStat = {
  score: string;
  match: string;
  count: number;
  pct: number;
};

type ChoiceStat = {
  label: string;
  count: number;
  pct: number;
};

type MatchStat = {
  id: string;
  home: string;
  away: string;
  totalPredictions: number;
  topExact: string;
  topExactPct: number;
  sign: ChoiceStat[];
  overUnder: ChoiceStat[];
  goalNoGoal: ChoiceStat[];
  surprisePickPct: number;
  showPickPct: number;
};

const topExact: ExactStat[] = [
  { score: "1-1", match: "Roma - Fiorentina", count: 1842, pct: 18 },
  { score: "2-1", match: "Inter - Monza", count: 1630, pct: 16 },
  { score: "1-0", match: "Genoa - Cagliari", count: 1488, pct: 14 },
];

const globalSigns: ChoiceStat[] = [
  { label: "1", count: 8420, pct: 46 },
  { label: "X", count: 4120, pct: 22 },
  { label: "2", count: 5900, pct: 32 },
];

const globalOverUnder: ChoiceStat[] = [
  { label: "Over 2.5", count: 9830, pct: 54 },
  { label: "Under 2.5", count: 8610, pct: 46 },
];

const globalGoalNoGoal: ChoiceStat[] = [
  { label: "Gol", count: 11220, pct: 61 },
  { label: "No Gol", count: 7220, pct: 39 },
];

const matchStats: MatchStat[] = [
  {
    id: "1",
    home: "Milan",
    away: "Napoli",
    totalPredictions: 2310,
    topExact: "1-1",
    topExactPct: 17,
    sign: [
      { label: "1", count: 830, pct: 36 },
      { label: "X", count: 620, pct: 27 },
      { label: "2", count: 860, pct: 37 },
    ],
    overUnder: [
      { label: "Over", count: 1420, pct: 61 },
      { label: "Under", count: 890, pct: 39 },
    ],
    goalNoGoal: [
      { label: "Gol", count: 1670, pct: 72 },
      { label: "No Gol", count: 640, pct: 28 },
    ],
    surprisePickPct: 22,
    showPickPct: 31,
  },
  {
    id: "2",
    home: "Lazio",
    away: "Roma",
    totalPredictions: 2108,
    topExact: "1-1",
    topExactPct: 21,
    sign: [
      { label: "1", count: 730, pct: 35 },
      { label: "X", count: 760, pct: 36 },
      { label: "2", count: 618, pct: 29 },
    ],
    overUnder: [
      { label: "Over", count: 920, pct: 44 },
      { label: "Under", count: 1188, pct: 56 },
    ],
    goalNoGoal: [
      { label: "Gol", count: 1390, pct: 66 },
      { label: "No Gol", count: 718, pct: 34 },
    ],
    surprisePickPct: 18,
    showPickPct: 19,
  },
  {
    id: "3",
    home: "Inter",
    away: "Monza",
    totalPredictions: 2680,
    topExact: "2-0",
    topExactPct: 24,
    sign: [
      { label: "1", count: 2150, pct: 80 },
      { label: "X", count: 310, pct: 12 },
      { label: "2", count: 220, pct: 8 },
    ],
    overUnder: [
      { label: "Over", count: 1710, pct: 64 },
      { label: "Under", count: 970, pct: 36 },
    ],
    goalNoGoal: [
      { label: "Gol", count: 980, pct: 37 },
      { label: "No Gol", count: 1700, pct: 63 },
    ],
    surprisePickPct: 7,
    showPickPct: 29,
  },
  {
    id: "4",
    home: "Torino",
    away: "Juventus",
    totalPredictions: 1988,
    topExact: "0-1",
    topExactPct: 20,
    sign: [
      { label: "1", count: 420, pct: 21 },
      { label: "X", count: 690, pct: 35 },
      { label: "2", count: 878, pct: 44 },
    ],
    overUnder: [
      { label: "Over", count: 870, pct: 44 },
      { label: "Under", count: 1118, pct: 56 },
    ],
    goalNoGoal: [
      { label: "Gol", count: 1080, pct: 54 },
      { label: "No Gol", count: 908, pct: 46 },
    ],
    surprisePickPct: 26,
    showPickPct: 16,
  },
];

function ControlRoomIcon() {
  return (
    <span className="flex h-14 w-14 shrink-0 items-center justify-center rounded-2xl border border-[#A6E824]/35 bg-[#A6E824]/10 shadow-[0_0_28px_rgba(166,232,36,0.18)]">
      <span className="relative h-10 w-10 rounded-xl border border-[#A6E824]/70 bg-black/40">
        <span className="absolute left-2 top-2 h-2 w-2 rounded-full bg-[#A6E824]" />
        <span className="absolute right-2 top-2 h-2 w-2 rounded-full bg-[#A6E824]/45" />
        <span className="absolute bottom-2 left-2 right-2 flex items-end gap-1">
          <span className="h-3 flex-1 rounded-t bg-[#A6E824]/50" />
          <span className="h-6 flex-1 rounded-t bg-[#A6E824]" />
          <span className="h-4 flex-1 rounded-t bg-[#A6E824]/70" />
        </span>
      </span>
    </span>
  );
}

function StatBlock({ label, value, sub }: { label: string; value: string; sub: string }) {
  return (
    <div className="rounded-2xl border border-white/10 bg-black/30 p-4">
      <p className="text-[10px] font-black uppercase tracking-[0.16em] text-gray-500">
        {label}
      </p>
      <p className="mt-2 text-3xl font-black text-[#A6E824]">{value}</p>
      <p className="mt-1 text-xs font-semibold text-gray-500">{sub}</p>
    </div>
  );
}

function PercentBar({ item }: { item: ChoiceStat }) {
  return (
    <div>
      <div className="mb-1 flex items-center justify-between text-xs font-black">
        <span className="text-white">{item.label}</span>
        <span className="text-[#A6E824]">{item.pct}%</span>
      </div>
      <div className="h-2 overflow-hidden rounded-full bg-white/10">
        <div
          className="h-full rounded-full bg-[#A6E824]"
          style={{ width: `${item.pct}%` }}
        />
      </div>
    </div>
  );
}

function ChoicePanel({ title, items }: { title: string; items: ChoiceStat[] }) {
  return (
    <div className="rounded-2xl border border-white/10 bg-black/30 p-4">
      <h3 className="text-sm font-black uppercase tracking-[0.14em] text-gray-400">
        {title}
      </h3>

      <div className="mt-4 space-y-3">
        {items.map((item) => (
          <PercentBar key={item.label} item={item} />
        ))}
      </div>
    </div>
  );
}

function ExactCard({ item, index }: { item: ExactStat; index: number }) {
  return (
    <div className="rounded-2xl border border-white/10 bg-black/30 p-4">
      <div className="flex items-center justify-between">
        <span className="flex h-8 w-8 items-center justify-center rounded-full bg-[#A6E824]/10 text-sm font-black text-[#A6E824]">
          {index + 1}
        </span>
        <span className="text-xs font-black uppercase tracking-[0.14em] text-gray-500">
          {item.pct}%
        </span>
      </div>

      <p className="mt-4 text-4xl font-black text-white">{item.score}</p>
      <p className="mt-2 truncate text-sm font-semibold text-gray-400">{item.match}</p>
      <p className="mt-1 text-xs font-bold text-gray-600">{item.count.toLocaleString("it-IT")} giocate</p>
    </div>
  );
}

function MatchControlCard({ match }: { match: MatchStat }) {
  return (
    <article className="rounded-3xl border border-white/10 bg-[#0b1419] p-4 shadow-xl shadow-black/30 sm:p-5">
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <h3 className="truncate text-2xl font-black text-white">
            {match.home} - {match.away}
          </h3>
          <p className="mt-1 text-xs font-black uppercase tracking-[0.16em] text-gray-500">
            {match.totalPredictions.toLocaleString("it-IT")} pronostici aggregati
          </p>
        </div>

        <div className="shrink-0 rounded-2xl border border-[#A6E824]/25 bg-[#A6E824]/10 px-3 py-2 text-right">
          <p className="text-[10px] font-black uppercase tracking-[0.12em] text-gray-500">
            Exact top
          </p>
          <p className="text-xl font-black text-[#A6E824]">{match.topExact}</p>
          <p className="text-[10px] font-bold text-gray-500">{match.topExactPct}%</p>
        </div>
      </div>

      <div className="mt-5 grid gap-3 lg:grid-cols-3">
        <ChoicePanel title="Segno 1X2" items={match.sign} />
        <ChoicePanel title="Under/Over 2.5" items={match.overUnder} />
        <ChoicePanel title="Gol/No Gol" items={match.goalNoGoal} />
      </div>

      <div className="mt-4 grid gap-3 sm:grid-cols-2">
        <StatBlock label="Sorpresa scelta" value={`${match.surprisePickPct}%`} sub="giocate orientate all'underdog" />
        <StatBlock label="Gol Show atteso" value={`${match.showPickPct}%`} sub="partite previste con molti gol" />
      </div>
    </article>
  );
}

export default function ControlRoomDetailPage() {
  const params = useParams<{ id: string }>();
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

  const exactTotal = useMemo(
    () => topExact.reduce((sum, item) => sum + item.count, 0),
    []
  );

  return (
    <main className="min-h-screen overflow-x-hidden bg-[#061014] pt-14 text-white">
      <header className="fixed inset-x-0 top-0 z-[80] border-b border-[#A6E824]/25 bg-[#1f2427] shadow-2xl shadow-black/80">
        <div className="mx-auto flex h-14 w-full max-w-6xl items-center justify-between overflow-visible px-4 md:px-6">
          <div className="pointer-events-none relative z-0 block min-w-0 -translate-x-8 translate-y-5 md:-translate-x-20 md:translate-y-6">
            <FantaGolLogo />
          </div>

          <button
            type="button"
            onClick={() => setMenuOpen(true)}
            aria-label="Apri menu"
            className="shrink-0 rounded-lg border border-gray-600 bg-[#2b2f31] px-3 py-2 text-2xl leading-none text-white transition hover:border-[#A6E824]"
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

      <section className="mx-auto w-full max-w-6xl px-4 pb-16 pt-8 sm:px-6 sm:pt-10">
        <section className="rounded-3xl border border-[#A6E824]/30 bg-gradient-to-br from-[#263033] via-[#15191b] to-[#080909] p-6 shadow-2xl shadow-black/70 sm:p-8">
          <div className="flex flex-col gap-5 sm:flex-row sm:items-center">
            <ControlRoomIcon />

            <div className="min-w-0">
              <p className="text-sm font-black uppercase tracking-[0.3em] text-[#A6E824]">
                Accesso attivo
              </p>

              <h1 className="mt-2 text-5xl font-black tracking-tight sm:text-6xl">
                Control Room
              </h1>

              <p className="mt-4 max-w-3xl text-base leading-7 text-gray-300 sm:text-lg sm:leading-8">
                Statistiche aggregate e anonime sulle giocate FantaGol. Questa schermata mostra
                l&apos;orientamento globale della community sui pronostici, sulle squadre, sui risultati
                esatti e sulle principali metriche di lettura.
              </p>

              <p className="mt-3 text-xs font-black uppercase tracking-[0.18em] text-gray-500">
                Sessione #{params.id}
              </p>
            </div>
          </div>
        </section>

        <section className="mt-6 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
          <StatBlock label="Pronostici globali" value="18.440" sub="giocate aggregate nella giornata" />
          <StatBlock label="Exact analizzati" value={exactTotal.toLocaleString("it-IT")} sub="scelte sui risultati esatti top" />
          <StatBlock label="Partite monitorate" value="10" sub="calendario giornata attiva" />
          <StatBlock label="Indice community" value="LIVE" sub="trend aggiornabili in tempo reale" />
        </section>

        <section className="mt-6 rounded-3xl border border-white/10 bg-[#0b1419] p-5 shadow-xl shadow-black/30 sm:p-6">
          <div className="flex items-center justify-between gap-4">
            <div>
              <h2 className="text-2xl font-black text-white">Exact più giocati</h2>
              <p className="mt-1 text-sm text-gray-500">
                I tre risultati esatti più scelti dagli utenti FantaGol.
              </p>
            </div>
          </div>

          <div className="mt-5 grid gap-3 md:grid-cols-3">
            {topExact.map((item, index) => (
              <ExactCard key={`${item.match}-${item.score}`} item={item} index={index} />
            ))}
          </div>
        </section>

        <section className="mt-6 grid gap-4 lg:grid-cols-3">
          <ChoicePanel title="Distribuzione segni" items={globalSigns} />
          <ChoicePanel title="Under/Over 2.5 globale" items={globalOverUnder} />
          <ChoicePanel title="Gol/No Gol globale" items={globalGoalNoGoal} />
        </section>

        <section className="mt-6 rounded-3xl border border-white/10 bg-[#0b1419] p-5 shadow-xl shadow-black/30 sm:p-6">
          <h2 className="text-2xl font-black text-white">Statistiche per partita</h2>
          <p className="mt-2 max-w-3xl text-sm leading-6 text-gray-500">
            Lettura aggregata anonima sulle singole partite: risultati esatti più giocati,
            orientamento 1X2, Under/Over 2.5, Gol/No Gol, sorpresa e Gol Show attesi.
          </p>

          <div className="mt-5 grid gap-4">
            {matchStats.map((match) => (
              <MatchControlCard key={match.id} match={match} />
            ))}
          </div>
        </section>
      </section>
    </main>
  );
}
