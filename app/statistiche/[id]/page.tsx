"use client";

import { useEffect, useMemo, useState } from "react";
import { useParams } from "next/navigation";
import FantaGolLogo from "../../../components/FantaGolLogo";
import HamburgerDrawer from "../../../components/app/HamburgerDrawer";
import KitPreview from "../../../components/club/KitPreview";
import { supabase } from "../../../lib/supabaseClient";

type LeagueInfo = {
  leagueName: string;
  displayName: string;
  inviteCode: string;
  role: string;
};

type TeamStat = {
  team: string;
  matches: number;
  points: number;
  accuracy: number;
  exact: number;
  sign: number;
  overUnder: number;
  goalNoGoal: number;
  surprise: number;
  bad: number;
  homeAccuracy: number;
  awayAccuracy: number;
  homeExact: number;
  awayExact: number;
  homePoints: number;
  awayPoints: number;
  trend: "up" | "down" | "stable";
};

type RoundTrend = {
  round: number;
  points: number;
  exact: number;
  bad: number;
};

type MemberDetail = {
  id: string;
  clubName: string;
  realName: string;
  kitTemplate: string;
  kitPrimaryColor: string;
  kitSecondaryColor: string;
  kitThirdColor: string;
  kitLogoMode: string;
  kitCrestPosition: string;
  starsCount: number;
  totalPoints: number;
  averagePoints: number;
  exact: number;
  surprise: number;
  show: number;
  slam: number;
  bad: number;
  opposite: number;
  bestTeam: TeamStat;
  worstTeam: TeamStat;
  teamStats: TeamStat[];
  roundTrend: RoundTrend[];
};

const demoMember: MemberDetail = {
  id: "1",
  clubName: "Real Exact",
  realName: "Mario Rossi",
  kitTemplate: "solid",
  kitPrimaryColor: "#FFFFFF",
  kitSecondaryColor: "#A6E824",
  kitThirdColor: "#111417",
  kitLogoMode: "center_horizontal",
  kitCrestPosition: "left_chest",
  starsCount: 2,
  totalPoints: 362,
  averagePoints: 36.2,
  exact: 18,
  surprise: 7,
  show: 11,
  slam: 2,
  bad: 5,
  opposite: 4,
  bestTeam: {
    team: "Inter",
    matches: 10,
    points: 74,
    accuracy: 78,
    exact: 5,
    sign: 8,
    overUnder: 7,
    goalNoGoal: 8,
    surprise: 1,
    bad: 0,
    homeAccuracy: 84,
    awayAccuracy: 71,
    homeExact: 3,
    awayExact: 2,
    homePoints: 37,
    awayPoints: 37,
    trend: "up",
  },
  worstTeam: {
    team: "Lazio",
    matches: 10,
    points: 21,
    accuracy: 31,
    exact: 0,
    sign: 3,
    overUnder: 2,
    goalNoGoal: 3,
    surprise: 0,
    bad: 3,
    homeAccuracy: 37,
    awayAccuracy: 24,
    homeExact: 0,
    awayExact: 0,
    homePoints: 11,
    awayPoints: 10,
    trend: "down",
  },
  teamStats: [
    { team: "Inter", matches: 10, points: 74, accuracy: 78, exact: 5, sign: 8, overUnder: 7, goalNoGoal: 8, surprise: 1, bad: 0,
    homeAccuracy: 84,
    awayAccuracy: 71,
    homeExact: 3,
    awayExact: 2,
    homePoints: 37,
    awayPoints: 37, trend: "up" },
    { team: "Napoli", matches: 10, points: 68, accuracy: 74, exact: 4, sign: 8, overUnder: 6, goalNoGoal: 7, surprise: 2, bad: 1,
    homeAccuracy: 80,
    awayAccuracy: 67,
    homeExact: 2,
    awayExact: 2,
    homePoints: 34,
    awayPoints: 34, trend: "up" },
    { team: "Milan", matches: 10, points: 63, accuracy: 70, exact: 3, sign: 7, overUnder: 7, goalNoGoal: 6, surprise: 1, bad: 1,
    homeAccuracy: 76,
    awayAccuracy: 63,
    homeExact: 2,
    awayExact: 1,
    homePoints: 32,
    awayPoints: 31, trend: "stable" },
    { team: "Juventus", matches: 10, points: 59, accuracy: 66, exact: 3, sign: 7, overUnder: 5, goalNoGoal: 6, surprise: 0, bad: 1,
    homeAccuracy: 72,
    awayAccuracy: 59,
    homeExact: 2,
    awayExact: 1,
    homePoints: 30,
    awayPoints: 29, trend: "stable" },
    { team: "Roma", matches: 10, points: 44, accuracy: 52, exact: 1, sign: 5, overUnder: 4, goalNoGoal: 5, surprise: 1, bad: 2,
    homeAccuracy: 58,
    awayAccuracy: 45,
    homeExact: 1,
    awayExact: 0,
    homePoints: 22,
    awayPoints: 22, trend: "down" },
    { team: "Torino", matches: 10, points: 39, accuracy: 47, exact: 1, sign: 4, overUnder: 5, goalNoGoal: 3, surprise: 0, bad: 2,
    homeAccuracy: 53,
    awayAccuracy: 40,
    homeExact: 1,
    awayExact: 0,
    homePoints: 20,
    awayPoints: 19, trend: "down" },
    { team: "Lazio", matches: 10, points: 21, accuracy: 31, exact: 0, sign: 3, overUnder: 2, goalNoGoal: 3, surprise: 0, bad: 3,
    homeAccuracy: 37,
    awayAccuracy: 24,
    homeExact: 0,
    awayExact: 0,
    homePoints: 11,
    awayPoints: 10, trend: "down" },
  ],
  roundTrend: [
    { round: 1, points: 32, exact: 1, bad: 0 },
    { round: 2, points: 41, exact: 2, bad: 1 },
    { round: 3, points: 28, exact: 1, bad: 0 },
    { round: 4, points: 52, exact: 3, bad: 0 },
    { round: 5, points: 34, exact: 2, bad: 1 },
    { round: 6, points: 43, exact: 2, bad: 0 },
    { round: 7, points: 37, exact: 1, bad: 1 },
    { round: 8, points: 55, exact: 3, bad: 0 },
    { round: 9, points: 25, exact: 0, bad: 2 },
    { round: 10, points: 15, exact: 0, bad: 0 },
  ],
};

function trendLabel(trend: TeamStat["trend"]) {
  if (trend === "up") return "↗ In crescita";
  if (trend === "down") return "↘ In calo";
  return "→ Stabile";
}

function trendClass(trend: TeamStat["trend"]) {
  if (trend === "up") return "text-[#A6E824]";
  if (trend === "down") return "text-red-400";
  return "text-gray-400";
}

function MiniMetric({
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
      ? "text-orange-300"
      : tone === "red"
        ? "text-red-400"
        : tone === "violet"
          ? "text-violet-300"
          : tone === "muted"
            ? "text-gray-300"
            : "text-[#A6E824]";

  return (
    <div className="rounded-2xl border border-white/10 bg-black/30 p-4">
      <div className="text-[10px] font-black uppercase tracking-[0.16em] text-gray-500">
        {label}
      </div>
      <div className={`mt-2 text-2xl font-black ${color}`}>{value}</div>
    </div>
  );
}

function TeamDeepCard({ stat }: { stat: TeamStat }) {
  return (
    <article className="rounded-3xl border border-gray-800 bg-black/30 p-4">
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <h3 className="truncate text-xl font-black text-white">{stat.team}</h3>
          <p className={`mt-1 text-xs font-black uppercase ${trendClass(stat.trend)}`}>
            {trendLabel(stat.trend)}
          </p>
        </div>

        <div className="text-right">
          <div className="text-2xl font-black text-[#A6E824]">{stat.accuracy}%</div>
          <div className="text-[10px] font-black uppercase text-gray-500">totale</div>
        </div>
      </div>

      <div className="mt-4 h-2 overflow-hidden rounded-full bg-white/10">
        <div
          className="h-full rounded-full bg-[#A6E824]"
          style={{ width: `${stat.accuracy}%` }}
        />
      </div>

      <div className="mt-4 grid gap-3 md:grid-cols-2">
        <div className="rounded-2xl border border-white/10 bg-black/30 p-4">
          <div className="text-[10px] font-black uppercase tracking-[0.16em] text-gray-500">
            Lettura in casa
          </div>
          <div className="mt-2 flex items-end justify-between gap-3">
            <div className="text-2xl font-black text-[#A6E824]">{stat.homeAccuracy}%</div>
            <div className="text-right text-xs font-bold text-gray-500">
              <div>{stat.homePoints} pt</div>
              <div>{stat.homeExact} exact</div>
            </div>
          </div>
        </div>

        <div className="rounded-2xl border border-white/10 bg-black/30 p-4">
          <div className="text-[10px] font-black uppercase tracking-[0.16em] text-gray-500">
            Lettura fuori
          </div>
          <div className="mt-2 flex items-end justify-between gap-3">
            <div className="text-2xl font-black text-[#A6E824]">{stat.awayAccuracy}%</div>
            <div className="text-right text-xs font-bold text-gray-500">
              <div>{stat.awayPoints} pt</div>
              <div>{stat.awayExact} exact</div>
            </div>
          </div>
        </div>
      </div>

      <div className="mt-4 grid grid-cols-3 gap-2">
        <MiniMetric label="Punti" value={stat.points} />
        <MiniMetric label="Exact" value={stat.exact} />
        <MiniMetric label="Segno" value={stat.sign} />
        <MiniMetric label="U/O" value={stat.overUnder} tone="muted" />
        <MiniMetric label="G/NG" value={stat.goalNoGoal} tone="muted" />
        <MiniMetric label="Cantonate" value={stat.bad} tone="red" />
      </div>
    </article>
  );
}

function RoundTrendChart({ trend }: { trend: RoundTrend[] }) {
  const max = Math.max(...trend.map((item) => item.points), 1);

  return (
    <div className="rounded-3xl border border-gray-700 bg-[#111111] p-5">
      <h2 className="text-2xl font-black">Andamento giornate</h2>
      <div className="mt-6 flex h-40 items-end gap-2 rounded-2xl border border-white/10 bg-black/30 p-4">
        {trend.map((item) => (
          <div key={item.round} className="flex h-full flex-1 flex-col justify-end gap-2">
            <div
              className="rounded-t bg-[#A6E824]"
              style={{ height: `${Math.max(10, (item.points / max) * 100)}%` }}
              title={`G${item.round}: ${item.points} pt`}
            />
            <div className="text-center text-[9px] font-black text-gray-500">
              G{item.round}
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}

export default function StatisticheMembroPage() {
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

      /*
        Collegamento definitivo:
        get_member_deep_statistics_rpc(target_member_id uuid)
        oppure get_member_deep_statistics_rpc(target_league_id uuid, target_member_id uuid)

        Da leggere da:
        - giornate chiuse
        - pronostici per partita
        - risultati reali
        - classifiche Punti Puri/Fantacalcio/One to One
        - tabella squadre e calendario ufficiale
      */
    }

    loadLeagueInfo();
  }, []);

  const member = useMemo(() => {
    return {
      ...demoMember,
      id: params.id,
    };
  }, [params.id]);

  const bestTeams = useMemo(
    () => [...member.teamStats].sort((a, b) => b.accuracy - a.accuracy).slice(0, 3),
    [member.teamStats]
  );

  const riskyTeams = useMemo(
    () => [...member.teamStats].sort((a, b) => a.accuracy - b.accuracy).slice(0, 3),
    [member.teamStats]
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

      <section className="mx-auto max-w-6xl px-4 pb-16 pt-10 sm:px-6">
        <a href="/statistiche" className="text-sm font-black text-[#A6E824] hover:underline">
          ← Torna alle statistiche
        </a>

        <div className="mt-6 grid gap-6 lg:grid-cols-[360px_1fr]">
          <aside className="rounded-3xl border border-gray-700 bg-[#111111] p-6">
            <div className="mx-auto flex h-40 w-28 items-center justify-center overflow-hidden rounded-2xl bg-[#171b1d]">
              <div className="scale-[0.68]">
                <KitPreview
                  primary={member.kitPrimaryColor}
                  secondary={member.kitSecondaryColor}
                  third={member.kitThirdColor}
                  template={member.kitTemplate}
                  logoMode={member.kitLogoMode}
                  crestPosition={member.kitCrestPosition}
                  starsCount={member.starsCount}
                />
              </div>
            </div>

            <h1 className="mt-6 text-center text-4xl font-black">{member.clubName}</h1>
            <p className="mt-2 text-center text-sm font-semibold text-gray-500">
              {member.realName}
            </p>

            <div className="mt-6 grid grid-cols-2 gap-3">
              <MiniMetric label="Totale" value={member.totalPoints} />
              <MiniMetric label="Media" value={member.averagePoints} />
              <MiniMetric label="Exact" value={member.exact} />
              <MiniMetric label="Slam" value={member.slam} tone="violet" />
            </div>
          </aside>

          <div className="space-y-6">
            <section className="rounded-3xl border border-[#A6E824]/30 bg-[#A6E824]/10 p-6">
              <h2 className="text-2xl font-black text-[#A6E824]">
                Sintesi squadre
              </h2>

              <div className="mt-5 grid gap-3 md:grid-cols-2">
                <div className="rounded-2xl border border-[#A6E824]/25 bg-black/30 p-4">
                  <div className="text-[10px] font-black uppercase tracking-[0.16em] text-gray-500">
                    Migliore lettura
                  </div>
                  <div className="mt-2 text-2xl font-black text-[#A6E824]">
                    {member.bestTeam.team}
                  </div>
                  <div className="mt-3 grid grid-cols-2 gap-2">
                    <MiniMetric label="Casa" value={`${member.bestTeam.homeAccuracy}%`} />
                    <MiniMetric label="Fuori" value={`${member.bestTeam.awayAccuracy}%`} />
                  </div>
                </div>

                <div className="rounded-2xl border border-red-500/25 bg-black/30 p-4">
                  <div className="text-[10px] font-black uppercase tracking-[0.16em] text-gray-500">
                    Peggiore lettura
                  </div>
                  <div className="mt-2 text-2xl font-black text-red-400">
                    {member.worstTeam.team}
                  </div>
                  <div className="mt-3 grid grid-cols-2 gap-2">
                    <MiniMetric label="Casa" value={`${member.worstTeam.homeAccuracy}%`} tone="red" />
                    <MiniMetric label="Fuori" value={`${member.worstTeam.awayAccuracy}%`} tone="red" />
                  </div>
                </div>
              </div>
            </section>

            <RoundTrendChart trend={member.roundTrend} />
          </div>
        </div>

        <section className="mt-6 rounded-3xl border border-gray-700 bg-[#111111] p-5">
          <h2 className="text-2xl font-black">Rendimento per squadra</h2>
          <div className="mt-5 grid gap-3">
            {member.teamStats.map((stat) => (
              <TeamDeepCard key={stat.team} stat={stat} />
            ))}
          </div>
        </section>

        <section className="mt-6 grid gap-4 md:grid-cols-2">
          <div className="rounded-3xl border border-gray-700 bg-[#111111] p-5">
            <h2 className="text-2xl font-black">Migliori letture</h2>

            <div className="mt-4 space-y-3">
              {bestTeams.map((team, index) => (
                <div key={team.team} className="flex items-center justify-between rounded-2xl bg-black/30 p-4">
                  <div className="font-black">
                    {index + 1}. {team.team}
                  </div>
                  <div className="text-right">
                    <div className="text-xl font-black text-[#A6E824]">{team.accuracy}%</div>
                    <div className="text-[10px] font-bold text-gray-500">C {team.homeAccuracy}% / F {team.awayAccuracy}%</div>
                  </div>
                </div>
              ))}
            </div>
          </div>

          <div className="rounded-3xl border border-gray-700 bg-[#111111] p-5">
            <h2 className="text-2xl font-black">Peggiori letture</h2>

            <div className="mt-4 space-y-3">
              {riskyTeams.map((team, index) => (
                <div key={team.team} className="flex items-center justify-between rounded-2xl bg-black/30 p-4">
                  <div className="font-black">
                    {index + 1}. {team.team}
                  </div>
                  <div className="text-right">
                    <div className="text-xl font-black text-red-400">{team.accuracy}%</div>
                    <div className="text-[10px] font-bold text-gray-500">C {team.homeAccuracy}% / F {team.awayAccuracy}%</div>
                  </div>
                </div>
              ))}
            </div>
          </div>
        </section>

        <section className="mt-6 rounded-3xl border border-gray-700 bg-[#111111] p-5">
          <h2 className="text-2xl font-black">Split generali</h2>
          <div className="mt-4 grid gap-3 md:grid-cols-3">
            <MiniMetric label="Precisione 1X2" value="68%" />
            <MiniMetric label="Precisione U/O" value="61%" tone="muted" />
            <MiniMetric label="Precisione G/NG" value="64%" tone="muted" />
            <MiniMetric label="Exact casa" value="11" />
            <MiniMetric label="Exact trasferta" value="7" />
            <MiniMetric label="Big match" value="72%" tone="orange" />
            <MiniMetric label="Favoriti" value="70%" />
            <MiniMetric label="Equilibrate" value="55%" tone="orange" />
            <MiniMetric label="Underdog" value="41%" tone="violet" />
          </div>
        </section>
      </section>
    </main>
  );
}
