"use client";

import { useEffect, useState } from "react";
import { useParams, useRouter } from "next/navigation";
import { supabase } from "../../../lib/supabaseClient";

import Badge from "../../../components/ui/Badge";
import DashboardCard from "../../../components/ui/DashboardCard";
import QuickActionCard from "../../../components/ui/QuickActionCard";
import HamburgerDrawer from "../../../components/app/HamburgerDrawer";
import ModeSummaryCard from "../../../components/app/ModeSummaryCard";

type League = {
  id: string;
  name: string;
  invite_code: string;
  display_name: string;
  role: string;
};

const currentRoundMatches = [
  { home: "Milan", away: "Napoli", time: "Sab 22 · 20:45" },
  { home: "Lazio", away: "Roma", time: "Dom 23 · 12:30" },
  { home: "Frosinone", away: "Juventus", time: "Dom 23 · 13:45" },
  { home: "Genoa", away: "Napoli", time: "Dom 23 · 15:00" },
  { home: "Inter", away: "Monza", time: "Dom 23 · 15:00" },
  { home: "Parma", away: "Cagliari", time: "Dom 23 · 18:00" },
  { home: "Roma", away: "Fiorentina", time: "Dom 23 · 18:00" },
  { home: "Torino", away: "Milan", time: "Dom 23 · 20:45" },
  { home: "Udinese", away: "Como", time: "Dom 23 · 20:45" },
  { home: "Pisa", away: "Cremonese", time: "Lun 24 · 20:45" },
];

function MatchMiniRow({
  home,
  away,
  time,
  index,
}: {
  home: string;
  away: string;
  time: string;
  index: number;
}) {
  return (
    <div className="grid grid-cols-[22px_1fr_auto] items-center gap-2 rounded-xl border border-white/10 bg-black/35 px-3 py-2">
      <div className="flex h-6 w-6 items-center justify-center rounded-full bg-[#A6E824]/10 text-[11px] font-black text-[#A6E824]">
        {index}
      </div>

      <div className="min-w-0">
        <div className="truncate text-sm font-black text-white">
          {home} - {away}
        </div>
        <div className="text-[11px] font-semibold text-gray-500">{time}</div>
      </div>

      <div className="rounded-lg border border-white/10 bg-[#0b0d0e] px-2 py-1 text-[10px] font-black text-gray-400">
        — : —
      </div>
    </div>
  );
}


export default function LeagueDashboardPage() {
  const router = useRouter();
  const params = useParams();
  const leagueId = params.id as string;

  const [league, setLeague] = useState<League | null>(null);
  const [menuOpen, setMenuOpen] = useState(false);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    async function loadDashboard() {
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

      const current = (data || []).find((row: any) => row.league_id === leagueId);

      if (!current) {
        window.location.href = "/leghe";
        return;
      }

      setLeague({
        id: current.league_id,
        name: current.league_name,
        invite_code: current.invite_code,
        display_name: current.display_name,
        role: current.role,
      });

      setLoading(false);
    }

    loadDashboard();
  }, [leagueId]);

  function copyInviteLink() {
    if (!league?.invite_code) return;

    const inviteLink = `${window.location.origin}/invito/${league.invite_code}`;
    navigator.clipboard.writeText(inviteLink);
    alert("Link invito copiato.");
  }

  if (loading) {
    return (
      <main className="flex min-h-screen items-center justify-center bg-black text-white">
        Caricamento dashboard...
      </main>
    );
  }

  if (!league) return null;

  return (
    <main className="min-h-screen bg-black text-white">
      <HamburgerDrawer
        open={menuOpen}
        leagueName={league.name}
        displayName={league.display_name}
        inviteCode={league.invite_code}
        role={league.role}
        onClose={() => setMenuOpen(false)}
      />

      <section className="mx-auto max-w-5xl px-4 py-6">
        <DashboardCard className="border-[#A6E824]/30 bg-gradient-to-br from-[#263033] via-[#15191b] to-[#080909] shadow-2xl shadow-black/70">
          <div className="flex items-center justify-between gap-4">
            <p className="text-sm font-semibold uppercase tracking-[0.25em] text-[#A6E824]">
              Giornata 1
            </p>

            <Badge variant="success">Pronostici aperti</Badge>
          </div>

          <div className="mt-5 grid grid-cols-1 gap-3 md:grid-cols-2">
            <div className="space-y-2 rounded-2xl border border-white/10 bg-white/[0.03] p-3">
              {currentRoundMatches.slice(0, 5).map((match, index) => (
                <MatchMiniRow
                  key={`${match.home}-${match.away}`}
                  home={match.home}
                  away={match.away}
                  time={match.time}
                  index={index + 1}
                />
              ))}
            </div>

            <div className="space-y-2 rounded-2xl border border-white/10 bg-white/[0.03] p-3">
              {currentRoundMatches.slice(5, 10).map((match, index) => (
                <MatchMiniRow
                  key={`${match.home}-${match.away}`}
                  home={match.home}
                  away={match.away}
                  time={match.time}
                  index={index + 6}
                />
              ))}
            </div>
          </div>

          <button
            type="button"
            onClick={() => router.push(`/leghe/${leagueId}/giornata`)}
            className="mt-6 w-full rounded-2xl bg-[#A6E824] px-6 py-4 font-black text-black shadow-lg shadow-[#A6E824]/20 transition hover:brightness-110"
          >
            Invia pronostici
          </button>
        </DashboardCard>

        <DashboardCard className="mt-6">
          <div className="flex items-center justify-between">
            <p className="text-sm font-semibold uppercase tracking-[0.2em] text-gray-400">
              Risultati live
            </p>

            <Badge>Prossima partita</Badge>
          </div>

          <div className="mt-4 rounded-2xl bg-black p-5 text-center">
            <div className="text-sm text-gray-400">Partita del giorno</div>

            <div className="mt-4 grid grid-cols-3 items-center text-xl font-black">
              <span>Milan</span>
              <span className="rounded-xl bg-[#A6E824]/10 px-3 py-2 text-[#A6E824]">
                20:45
              </span>
              <span>Napoli</span>
            </div>
          </div>
        </DashboardCard>

        <div className="mt-6 grid grid-cols-1 gap-4 md:grid-cols-3">
          <button
            type="button"
            onClick={() => router.push(`/leghe/${leagueId}/fantacalcio`)}
            className="block w-full text-left transition hover:-translate-y-0.5 hover:brightness-110 focus:outline-none focus:ring-2 focus:ring-[#A6E824]/70 focus:ring-offset-2 focus:ring-offset-black"
            aria-label="Apri modalità Fantacalcio"
          >
            <ModeSummaryCard
              icon="🏆"
              title="Fantacalcio"
              value="0 punti"
              description="Classifica da avviare"
            />
          </button>

          <button
            type="button"
            onClick={() => router.push(`/leghe/${leagueId}/onetoone`)}
            className="block w-full text-left transition hover:-translate-y-0.5 hover:brightness-110 focus:outline-none focus:ring-2 focus:ring-[#A6E824]/70 focus:ring-offset-2 focus:ring-offset-black"
            aria-label="Apri modalità One To One"
          >
            <ModeSummaryCard
              icon="⚔️"
              title="One To One"
              value="0-0"
              description="Sfida da generare"
            />
          </button>

          <button
            type="button"
            onClick={() => router.push(`/leghe/${leagueId}/giornata`)}
            className="block w-full text-left transition hover:-translate-y-0.5 hover:brightness-110 focus:outline-none focus:ring-2 focus:ring-[#A6E824]/70 focus:ring-offset-2 focus:ring-offset-black"
            aria-label="Apri modalità Punti Puri"
          >
            <ModeSummaryCard
              icon="⭐"
              title="Punti Puri"
              value="0"
              description="Totale stagione"
            />
          </button>
        </div>

        <div className="mt-6 grid grid-cols-2 gap-4 md:grid-cols-6">
          <QuickActionCard icon="🎯" label="Pronostici" href={`/leghe/${leagueId}/giornata`} />
          <QuickActionCard icon="⚽" label="Live" href={`/leghe/${leagueId}/giornata`} />
          <QuickActionCard icon="🏆" label="Classifiche" href="/classifiche" />
          <QuickActionCard icon="📅" label="Calendario" href="/calendario" />
          <QuickActionCard icon="👥" label="Membri" href="/membri" />

          <button
            type="button"
            onClick={copyInviteLink}
            className="rounded-2xl border border-white/10 bg-[#111417] p-4 text-left shadow-lg shadow-black/20 transition hover:-translate-y-0.5 hover:border-[#A6E824]/60 hover:brightness-110"
          >
            <div className="text-2xl">📨</div>
            <div className="mt-2 text-sm font-black text-white">Invita</div>
          </button>
        </div>
      </section>

    </main>
  );
}
