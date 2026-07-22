"use client";

import Link from "next/link";
import { useEffect, useMemo, useState } from "react";
import { useParams } from "next/navigation";
import FantaGolLogo from "../../../components/FantaGolLogo";
import HamburgerDrawer from "../../../components/app/HamburgerDrawer";
import KitPreview from "../../../components/club/KitPreview";
import { supabase } from "../../../lib/supabaseClient";

type LeagueInfo = {
  leagueId: string;
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

type StatisticsSplits = {
  signAccuracy: number;
  overUnderAccuracy: number;
  goalNoGoalAccuracy: number;
  homeExact: number;
  awayExact: number;
  underdogAccuracy: number;
  standardAccuracy: number;
  evaluatedPredictions: number;
  surpriseCandidates: number;
  officialRounds: number;
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
  splits: StatisticsSplits;
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
    leagueId: "",
    leagueName: "FantaGol",
    displayName: "Club FantaGol",
    inviteCode: "",
    role: "member",
  });
  const [member, setMember] = useState<MemberDetail | null>(null);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;

    async function loadMemberStatistics() {
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
          setLoadError("Nessuna lega disponibile.");
          setLoading(false);
        }
        return;
      }

      const { data, error } = await supabase.rpc(
        "get_member_deep_statistics_rpc",
        {
          target_league_id: selectedLeague.league_id,
          target_member_id: params.id,
        }
      );

      if (cancelled) return;

      setLeagueInfo({
        leagueId: selectedLeague.league_id,
        leagueName: selectedLeague.league_name || "Lega FantaGol",
        displayName: selectedLeague.display_name || "Club FantaGol",
        inviteCode:
          selectedLeague.invite_code || selectedLeague.league_id || "",
        role: selectedLeague.role || "member",
      });

      if (error) {
        setLoadError(error.message);
        setMember(null);
        setLoading(false);
        return;
      }

      const payload = (data || {}) as {
        member?: Record<string, unknown>;
        bestTeam?: TeamStat;
        worstTeam?: TeamStat;
        teamStats?: TeamStat[];
        roundTrend?: RoundTrend[];
        splits?: Partial<StatisticsSplits>;
      };

      if (!payload.member) {
        setLoadError("Statistiche del membro non disponibili.");
        setMember(null);
        setLoading(false);
        return;
      }

      const rawMember = payload.member;
      const zeroTeam: TeamStat = {
        team: "—",
        matches: 0,
        points: 0,
        accuracy: 0,
        exact: 0,
        sign: 0,
        overUnder: 0,
        goalNoGoal: 0,
        surprise: 0,
        bad: 0,
        homeAccuracy: 0,
        awayAccuracy: 0,
        homeExact: 0,
        awayExact: 0,
        homePoints: 0,
        awayPoints: 0,
        trend: "stable",
      };

      setMember({
        id: String(rawMember.id || params.id),
        clubName: String(rawMember.clubName || "Club FantaGol"),
        realName: String(rawMember.realName || ""),
        kitTemplate: String(rawMember.kitTemplate || "solid"),
        kitPrimaryColor: String(
          rawMember.kitPrimaryColor || "#FFFFFF"
        ),
        kitSecondaryColor: String(
          rawMember.kitSecondaryColor || "#A6E824"
        ),
        kitThirdColor: String(rawMember.kitThirdColor || "#FFFFFF"),
        kitLogoMode: String(
          rawMember.kitLogoMode || "center_horizontal"
        ),
        kitCrestPosition: String(
          rawMember.kitCrestPosition || "left_chest"
        ),
        starsCount: Number(rawMember.starsCount || 0),
        totalPoints: Number(rawMember.totalPoints || 0),
        averagePoints: Number(rawMember.averagePoints || 0),
        exact: Number(rawMember.exact || 0),
        surprise: Number(rawMember.surprise || 0),
        show: Number(rawMember.show || 0),
        slam: Number(rawMember.slam || 0),
        bad: Number(rawMember.bad || 0),
        opposite: Number(rawMember.opposite || 0),
        bestTeam: payload.bestTeam || zeroTeam,
        worstTeam: payload.worstTeam || zeroTeam,
        teamStats: payload.teamStats || [],
        roundTrend: payload.roundTrend || [],
        splits: {
          signAccuracy: Number(payload.splits?.signAccuracy || 0),
          overUnderAccuracy: Number(
            payload.splits?.overUnderAccuracy || 0
          ),
          goalNoGoalAccuracy: Number(
            payload.splits?.goalNoGoalAccuracy || 0
          ),
          homeExact: Number(payload.splits?.homeExact || 0),
          awayExact: Number(payload.splits?.awayExact || 0),
          underdogAccuracy: Number(
            payload.splits?.underdogAccuracy || 0
          ),
          standardAccuracy: Number(
            payload.splits?.standardAccuracy || 0
          ),
          evaluatedPredictions: Number(
            payload.splits?.evaluatedPredictions || 0
          ),
          surpriseCandidates: Number(
            payload.splits?.surpriseCandidates || 0
          ),
          officialRounds: Number(payload.splits?.officialRounds || 0),
        },
      });
      setLoading(false);
    }

    loadMemberStatistics();

    return () => {
      cancelled = true;
    };
  }, [params.id]);

  const bestTeams = useMemo(
    () =>
      member
        ? [...member.teamStats]
            .sort((a, b) => b.accuracy - a.accuracy)
            .slice(0, 3)
        : [],
    [member]
  );

  const riskyTeams = useMemo(
    () =>
      member
        ? [...member.teamStats]
            .sort((a, b) => a.accuracy - b.accuracy)
            .slice(0, 3)
        : [],
    [member]
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

      {loading ? (
        <section className="mx-auto max-w-6xl px-4 pb-16 pt-10 sm:px-6">
          <div className="rounded-3xl border border-gray-700 bg-[#111111] p-6 text-gray-400">
            Caricamento statistiche reali…
          </div>
        </section>
      ) : loadError || !member ? (
        <section className="mx-auto max-w-6xl px-4 pb-16 pt-10 sm:px-6">
          <Link
            href="/statistiche"
            className="text-sm font-black text-[#A6E824] hover:underline"
          >
            ← Torna alle statistiche
          </Link>
          <div className="mt-6 rounded-3xl border border-red-500/30 bg-red-950/20 p-6 text-red-300">
            {loadError || "Statistiche del membro non disponibili."}
          </div>
        </section>
      ) : (
      <section className="mx-auto max-w-6xl px-4 pb-16 pt-10 sm:px-6">
        <Link href="/statistiche" className="text-sm font-black text-[#A6E824] hover:underline">
          ← Torna alle statistiche
        </Link>

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
            {member.teamStats.length > 0 ? (
              member.teamStats.map((stat) => (
                <TeamDeepCard key={stat.team} stat={stat} />
              ))
            ) : (
              <div className="rounded-2xl border border-white/10 bg-black/30 p-5 text-gray-500">
                Nessuna giornata ufficiale disponibile.
              </div>
            )}
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
            <MiniMetric
              label="Precisione 1X2"
              value={`${member.splits.signAccuracy}%`}
            />
            <MiniMetric
              label="Precisione U/O"
              value={`${member.splits.overUnderAccuracy}%`}
              tone="muted"
            />
            <MiniMetric
              label="Precisione G/NG"
              value={`${member.splits.goalNoGoalAccuracy}%`}
              tone="muted"
            />
            <MiniMetric label="Exact casa" value={member.splits.homeExact} />
            <MiniMetric
              label="Exact trasferta"
              value={member.splits.awayExact}
            />
            <MiniMetric
              label="Pronostici valutati"
              value={member.splits.evaluatedPredictions}
              tone="orange"
            />
            <MiniMetric
              label="Lettura standard"
              value={`${member.splits.standardAccuracy}%`}
            />
            <MiniMetric
              label="Giornate ufficiali"
              value={member.splits.officialRounds}
              tone="orange"
            />
            <MiniMetric
              label="Underdog"
              value={`${member.splits.underdogAccuracy}%`}
              tone="violet"
            />
          </div>
        </section>
      </section>
      )}
    </main>
  );
}
