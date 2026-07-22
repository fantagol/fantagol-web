"use client";

import { useEffect, useMemo, useState } from "react";
import FantaGolLogo from "../../components/FantaGolLogo";
import HamburgerDrawer from "../../components/app/HamburgerDrawer";
import { supabase } from "../../lib/supabaseClient";
import KitPreview from "../../components/club/KitPreview";

type LeagueInfo = {
  leagueId: string;
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
    leagueId: "",
    leagueName: "FantaGol",
    displayName: "Club FantaGol",
    inviteCode: "",
    role: "member",
  });
  const [stats, setStats] = useState<MemberStats[]>([]);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;

    async function loadStatistics() {
      setLoading(true);
      setLoadError(null);

      const {
        data: { session },
      } = await supabase.auth.getSession();

      if (!session?.user) {
        window.location.href = "/login";
        return;
      }

      const { data: leagues, error: leaguesError } =
        await supabase.rpc("get_my_leagues_rpc");

      if (leaguesError) {
        if (!cancelled) {
          setLoadError(leaguesError.message);
          setLoading(false);
        }
        return;
      }

      const availableLeagues = leagues || [];
      const rememberedLeagueId =
        typeof window !== "undefined"
          ? window.localStorage.getItem("fantagol:lastLeagueId")
          : null;

      const selectedLeague =
        availableLeagues.find(
          (league: { league_id?: string }) =>
            league.league_id === rememberedLeagueId
        ) || availableLeagues[0];

      if (!selectedLeague?.league_id) {
        if (!cancelled) {
          setStats([]);
          setLoading(false);
        }
        return;
      }

      const selectedLeagueInfo: LeagueInfo = {
        leagueId: selectedLeague.league_id,
        leagueName: selectedLeague.league_name || "Lega FantaGol",
        displayName: selectedLeague.display_name || "Club FantaGol",
        inviteCode:
          selectedLeague.invite_code || selectedLeague.league_id || "",
        role: selectedLeague.role || "member",
      };

      const { data, error } = await supabase.rpc(
        "get_league_member_statistics_rpc",
        { target_league_id: selectedLeague.league_id }
      );

      if (cancelled) return;

      setLeagueInfo(selectedLeagueInfo);

      if (error) {
        setLoadError(error.message);
        setStats([]);
        setLoading(false);
        return;
      }

      const mappedStats: MemberStats[] = (data || []).map(
        (row: Record<string, unknown>) => ({
          id: String(row.member_id),
          clubName: String(row.club_name || "Club FantaGol"),
          realName: row.real_name ? String(row.real_name) : null,
          avatarUrl: row.avatar_url ? String(row.avatar_url) : null,
          kitTemplate: String(row.kit_template || "solid"),
          kitPrimaryColor: String(row.kit_primary_color || "#FFFFFF"),
          kitSecondaryColor: String(row.kit_secondary_color || "#A6E824"),
          kitThirdColor: String(row.kit_third_color || "#FFFFFF"),
          kitLogoMode: String(row.kit_logo_mode || "center_horizontal"),
          kitCrestPosition: String(
            row.kit_crest_position || "left_chest"
          ),
          starsCount: Number(row.stars_count || 0),
          totalPoints: Number(row.total_points || 0),
          exact: Number(row.exact_count || 0),
          surprise: Number(row.surprise_count || 0),
          show: Number(row.goal_show_count || 0),
          slam: Number(row.grand_slam_count || 0),
          bad: Number(row.cantonata_count || 0),
          opposite: Number(row.opposite_sign_count || 0),
          averagePoints: Number(row.average_points || 0),
          bestRound: Number(row.best_round || 0),
          worstRound: Number(row.worst_round || 0),
          bestTeam: String(row.best_team || "—"),
          bestTeamRate: Number(row.best_team_rate || 0),
          worstTeam: String(row.worst_team || "—"),
          worstTeamRate: Number(row.worst_team_rate || 0),
        })
      );

      setStats(mappedStats);
      setLoading(false);
    }

    loadStatistics();

    return () => {
      cancelled = true;
    };
  }, []);

  const sortedStats = useMemo(
    () =>
      [...stats].sort(
        (a, b) =>
          b.totalPoints - a.totalPoints ||
          b.exact - a.exact ||
          a.clubName.localeCompare(b.clubName)
      ),
    [stats]
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
          {loading ? (
            <div className="rounded-3xl border border-gray-700 bg-[#111111] p-6 text-gray-400">
              Caricamento statistiche reali…
            </div>
          ) : loadError ? (
            <div className="rounded-3xl border border-red-500/30 bg-red-950/20 p-6 text-red-300">
              Impossibile caricare le statistiche: {loadError}
            </div>
          ) : sortedStats.length === 0 ? (
            <div className="rounded-3xl border border-gray-700 bg-[#111111] p-6 text-gray-400">
              Nessun membro disponibile per questa lega.
            </div>
          ) : (
            sortedStats.map((member) => (
              <MemberCard key={member.id} member={member} />
            ))
          )}
        </div>
      </section>
    </main>
  );
}

