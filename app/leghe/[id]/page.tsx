"use client";

import { useEffect, useState } from "react";
import { useParams } from "next/navigation";
import { supabase } from "../../../lib/supabaseClient";

import Badge from "../../../components/ui/Badge";
import DashboardCard from "../../../components/ui/DashboardCard";
import ProgressBar from "../../../components/ui/ProgressBar";
import QuickActionCard from "../../../components/ui/QuickActionCard";
import BottomNav from "../../../components/app/BottomNav";
import HamburgerDrawer from "../../../components/app/HamburgerDrawer";
import LeagueTopBar from "../../../components/app/LeagueTopBar";
import ModeSummaryCard from "../../../components/app/ModeSummaryCard";

type League = {
  id: string;
  name: string;
  invite_code: string;
  display_name: string;
  role: string;
};

export default function LeagueDashboardPage() {
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

  if (loading) {
    return (
      <main className="flex min-h-screen items-center justify-center bg-black text-white">
        Caricamento dashboard...
      </main>
    );
  }

  if (!league) return null;

  return (
    <main className="min-h-screen bg-black pb-24 text-white">
      <LeagueTopBar
        leagueName={league.name}
        seasonName="Serie A 2026/27"
        onMenuClick={() => setMenuOpen(true)}
      />

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

          <h1 className="mt-4 text-4xl font-black leading-tight">
            Invia pronostico
          </h1>

          <p className="mt-3 text-gray-300">
            Pronostici inseriti:{" "}
            <span className="font-bold text-white">0 / 10</span>
          </p>

          <div className="mt-5">
            <ProgressBar value={0} max={10} />
          </div>

          <button
            type="button"
            className="mt-6 w-full rounded-2xl bg-[#A6E824] px-6 py-4 font-black text-black shadow-lg shadow-[#A6E824]/20 transition hover:brightness-110"
          >
            Compila giornata
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
          <ModeSummaryCard
            icon="🏆"
            title="Fantacalcio"
            value="0 punti"
            description="Classifica da avviare"
          />

          <ModeSummaryCard
            icon="⚔️"
            title="One To One"
            value="0-0"
            description="Sfida da generare"
          />

          <ModeSummaryCard
            icon="⭐"
            title="Punti Puri"
            value="0"
            description="Totale stagione"
          />
        </div>

        <div className="mt-6 grid grid-cols-2 gap-4 md:grid-cols-6">
          <QuickActionCard icon="🎯" label="Pronostici" href="#" />
          <QuickActionCard icon="⚽" label="Live" href="#" />
          <QuickActionCard icon="🏆" label="Classifiche" href="#" />
          <QuickActionCard icon="📅" label="Calendario" href="#" />
          <QuickActionCard icon="👥" label="Membri" href="#" />
          <QuickActionCard icon="📨" label="Invita" href={`/invito/${league.invite_code}`} />
        </div>
      </section>

      <BottomNav onMenuClick={() => setMenuOpen(true)} />
    </main>
  );
}