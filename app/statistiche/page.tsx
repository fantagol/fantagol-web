"use client";

import { useEffect, useMemo, useState } from "react";
import FantaGolLogo from "../../components/FantaGolLogo";
import HamburgerDrawer from "../../components/app/HamburgerDrawer";
import { supabase } from "../../lib/supabaseClient";
import KitPreview from "../../components/club/KitPreview";

type LeagueInfo = {
  leagueName: string;
  displayName: string;
  inviteCode: string;
  role: string;
};

type MemberStats = {
  id: string;
  clubName: string;
  realName: string | null;
  kitTemplate?: string;
  kitPrimaryColor?: string;
  kitSecondaryColor?: string;
  kitThirdColor?: string;
  kitLogoMode?: string;
  kitCrestPosition?: string;
  starsCount?: number;
  avatarUrl: string | null;
  totalPoints: number;
  exact: number;
  surprise: number;
  show: number;
  slam: number;
  bad: number;
  opposite: number;
  averagePoints: number;
  bestRound: number;
  worstRound: number;
  bestTeam: string;
  bestTeamRate: number;
  worstTeam: string;
  worstTeamRate: number;
};

const demoStats: MemberStats[] = [
  {
    id: "1",
    clubName: "Real Exact",
    realName: "Mario Rossi",
    avatarUrl: null,
    totalPoints: 362,
    exact: 18,
    surprise: 7,
    show: 11,
    slam: 2,
    bad: 5,
    opposite: 4,
    averagePoints: 36.2,
    bestRound: 52,
    worstRound: 14,
    bestTeam: "Inter",
    bestTeamRate: 78,
    worstTeam: "Lazio",
    worstTeamRate: 31,
  },
  {
    id: "2",
    clubName: "FantaGol United",
    realName: "Luca Bianchi",
    avatarUrl: null,
    totalPoints: 358,
    exact: 16,
    surprise: 9,
    show: 8,
    slam: 1,
    bad: 7,
    opposite: 5,
    averagePoints: 35.8,
    bestRound: 49,
    worstRound: 11,
    bestTeam: "Milan",
    bestTeamRate: 74,
    worstTeam: "Roma",
    worstTeamRate: 28,
  },
  {
    id: "3",
    clubName: "Bonus Show",
    realName: "Andrea Verdi",
    avatarUrl: null,
    totalPoints: 351,
    exact: 14,
    surprise: 12,
    show: 13,
    slam: 3,
    bad: 9,
    opposite: 6,
    averagePoints: 35.1,
    bestRound: 55,
    worstRound: 8,
    bestTeam: "Napoli",
    bestTeamRate: 81,
    worstTeam: "Torino",
    worstTeamRate: 26,
  },
];

function StatPill({
  label,
  value,
  tone = "green",
}: {
  label: string;
  value: string | number;
  tone?: "green" | "orange" | "red" | "violet" | "muted";
}) {
  const color =
    tone === "orange"
      ? "text-orange-300 border-orange-400/25 bg-orange-950/20"
      : tone === "red"
        ? "text-red-400 border-red-500/25 bg-red-950/20"
        : tone === "violet"
          ? "text-violet-300 border-violet-400/25 bg-violet-950/20"
          : tone === "muted"
            ? "text-gray-300 border-white/10 bg-black/30"
            : "text-[#A6E824] border-[#A6E824]/25 bg-[#A6E824]/10";

  return (
    <div className={`rounded-2xl border px-3 py-3 ${color}`}>
      <div className="text-[10px] font-black uppercase tracking-[0.16em] opacity-70">
        {label}
      </div>
      <div className="mt-1 text-2xl font-black leading-none">{value}</div>
    </div>
  );
}

function TeamRate({
  label,
  team,
  rate,
  tone,
}: {
  label: string;
  team: string;
  rate: number;
  tone: "green" | "red";
}) {
  return (
    <div className="rounded-2xl border border-white/10 bg-black/30 p-4">
      <div className="text-[10px] font-black uppercase tracking-[0.16em] text-gray-500">
        {label}
      </div>

      <div className="mt-2 flex items-center justify-between gap-3">
        <div className="min-w-0">
          <div className="truncate text-lg font-black text-white">{team}</div>
          <div className="mt-1 text-xs font-semibold text-gray-500">
            Precisione pronostici squadra
          </div>
        </div>

        <div className={`text-2xl font-black ${tone === "green" ? "text-[#A6E824]" : "text-red-400"}`}>
          {rate}%
        </div>
      </div>
    </div>
  );
}

function MemberCard({ member }: { member: MemberStats }) {
  return (
    <a href={`/statistiche/${member.id}`} className="block rounded-3xl border border-gray-700 bg-[#111111] p-5 shadow-2xl shadow-black/30 transition hover:border-[#A6E824]/60 hover:brightness-110">
      <div className="flex items-center gap-4">
        <div className="flex h-20 w-14 shrink-0 items-center justify-center overflow-hidden rounded-xl bg-[#111417]">
          <div className="scale-[0.38]">
            <KitPreview
              primary={member.kitPrimaryColor || "#FFFFFF"}
              secondary={member.kitSecondaryColor || "#A6E824"}
              third={member.kitThirdColor || "#FFFFFF"}
              template={member.kitTemplate || "solid"}
              logoMode={member.kitLogoMode || "center_horizontal"}
              crestPosition={member.kitCrestPosition || "left_chest"}
              starsCount={member.starsCount || 0}
            />
          </div>
        </div>

        <div className="min-w-0 flex-1">
          <h2 className="truncate text-2xl font-black">{member.clubName}</h2>
          <p className="mt-1 truncate text-sm font-semibold text-gray-500">
            {member.realName || "Nome reale non inserito"}
          </p>
        </div>

        <div className="rounded-2xl bg-[#A6E824] px-4 py-3 text-center text-black">
          <div className="text-[10px] font-black uppercase tracking-[0.16em]">
            Totale
          </div>
          <div className="text-2xl font-black leading-none">{member.totalPoints}</div>
        </div>
      </div>

      <div className="mt-5 grid grid-cols-2 gap-2 md:grid-cols-6">
        <StatPill label="Exact" value={member.exact} />
        <StatPill label="Sorpresa" value={member.surprise} tone="orange" />
        <StatPill label="Show" value={member.show} tone="orange" />
        <StatPill label="Slam" value={member.slam} tone="violet" />
        <StatPill label="Cantonate" value={member.bad} tone="red" />
        <StatPill label="Opposti" value={member.opposite} tone="red" />
      </div>

      <div className="mt-4 grid gap-3 md:grid-cols-3">
        <div className="rounded-2xl border border-white/10 bg-black/30 p-4">
          <div className="text-[10px] font-black uppercase tracking-[0.16em] text-gray-500">
            Media giornata
          </div>
          <div className="mt-2 text-2xl font-black text-[#A6E824]">
            {member.averagePoints}
          </div>
        </div>

        <div className="rounded-2xl border border-white/10 bg-black/30 p-4">
          <div className="text-[10px] font-black uppercase tracking-[0.16em] text-gray-500">
            Miglior giornata
          </div>
          <div className="mt-2 text-2xl font-black text-[#A6E824]">
            {member.bestRound}
          </div>
        </div>

        <div className="rounded-2xl border border-white/10 bg-black/30 p-4">
          <div className="text-[10px] font-black uppercase tracking-[0.16em] text-gray-500">
            Peggior giornata
          </div>
          <div className="mt-2 text-2xl font-black text-red-400">
            {member.worstRound}
          </div>
        </div>
      </div>

      <div className="mt-4 grid gap-3 md:grid-cols-2">
        <TeamRate
          label="Squadra letta meglio"
          team={member.bestTeam}
          rate={member.bestTeamRate}
          tone="green"
        />

        <TeamRate
          label="Squadra letta peggio"
          team={member.worstTeam}
          rate={member.worstTeamRate}
          tone="red"
        />
      </div>
      <div className="mt-6 flex items-center justify-between border-t border-[#A6E824]/20 pt-4">
        <span className="text-xs font-bold uppercase tracking-[0.18em] text-gray-500">
          Tocca la card
        </span>
        <div className="flex items-center gap-2 rounded-full border border-[#A6E824]/40 bg-[#A6E824]/10 px-3 py-2">
          <span className="text-sm font-black text-[#A6E824]">Apri dettaglio</span>
          <span className="text-lg font-black text-[#A6E824]">→</span>
        </div>
      </div>

    </a>
  );
}

export default function StatistichePage() {
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

      /*
        Collegamento definitivo:
        questa page leggerà dati aggregati dalle giornate chiuse:
        - risultati Punti Puri per giornata
        - bonus/malus per singola partita
        - exact e altri eventi per utente
        - rendimento per squadra pronosticata
        - classifiche finali/parziali delle tre modalità

        RPC prevista:
        get_league_member_statistics_rpc(target_league_id uuid)
      */
    }

    loadLeagueInfo();
  }, []);

  const sortedStats = useMemo(
    () => [...demoStats].sort((a, b) => b.totalPoints - a.totalPoints),
    []
  );

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
          Lega
        </p>

        <h1 className="mt-3 text-5xl font-black">Statistiche</h1>

        <p className="mt-4 max-w-3xl text-gray-400">
          Schede sintetiche dei membri. Tocca una card per il dettaglio completo.
        </p>

        <div className="mt-8 space-y-5">
          {sortedStats.map((member) => (
            <MemberCard key={member.id} member={member} />
          ))}
        </div>
      </section>
    </main>
  );
}

