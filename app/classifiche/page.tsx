"use client";

import { useEffect, useMemo, useState } from "react";
import FantaGolLogo from "../../components/FantaGolLogo";
import HamburgerDrawer from "../../components/app/HamburgerDrawer";
import FantaGolModeIcon from "../../components/app/FantaGolModeIcon";
import { supabase } from "../../lib/supabaseClient";

const LAST_LEAGUE_STORAGE_KEY = "fantagol:last-league-id";

type Mode = "pure_points" | "fantacalcio" | "one_to_one";

type LeagueInfo = {
  leagueId: string;
  leagueName: string;
  displayName: string;
  inviteCode: string;
  role: string;
};

type MyLeagueRpcRow = {
  league_id: string;
  league_name?: string | null;
  display_name?: string | null;
  invite_code?: string | null;
  role?: string | null;
};

type CurrentRoundRpcRow = {
  league_round_id?: string | null;
  league_round_number?: number | null;
};

type StandingStats = {
  exact_count?: number;
  bonus_count?: number;
  malus_count?: number;
  wins?: number;
  draws?: number;
  losses?: number;
  goals_for?: number;
  goals_against?: number;
  goal_difference?: number;
  mini_wins?: number;
  mini_draws?: number;
  mini_losses?: number;
  mini_difference?: number;
};

type StandingRow = {
  league_member_id: string;
  display_name: string;
  position_preview: number;
  baseline_position: number;
  movement_preview: number;
  baseline_points: number;
  round_points: number;
  projected_points: number;
  pending: boolean;
  score_phase: string;
  round_stats: StandingStats;
};

type ModePayload = {
  mode: Mode;
  preview: boolean;
  member_count: number;
  pending_member_count: number;
  ranking: StandingRow[];
};

type StandingsPayload = {
  schema_version?: number;
  builder?: string;
  builder_version?: string;
  generated_at?: string;
  preview?: boolean;
  official?: boolean;
  modes?: Partial<Record<Mode, ModePayload>>;
};

type StandingsRpcRow = {
  simulation_id: string;
  simulation_version: number;
  simulation_status: string;
  simulation_hash: string;
  manifest: Record<string, unknown> | null;
  round_view: Record<string, unknown> | null;
  member_view: Record<string, unknown> | null;
  standings_preview: StandingsPayload | null;
};

const modeDescriptions: Record<Mode, string> = {
  pure_points:
    "Somma dinamica dei punti FantaGol, comprensiva della baseline certificata e della giornata corrente.",
  fantacalcio:
    "Classifica a scontri diretti generata dalle fasce punti-gol e dalle regole Fantacalcio attive.",
  one_to_one:
    "Classifica a scontri diretti prodotta dalle mini-sfide e dagli abbinamenti One To One.",
};

const modeLabels: Record<Mode, string> = {
  pure_points: "Punti Puri",
  fantacalcio: "Fantacalcio",
  one_to_one: "One To One",
};

function toNumber(value: unknown, fallback = 0) {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function normalizeStandingRow(value: unknown): StandingRow | null {
  if (!value || typeof value !== "object") return null;

  const row = value as Record<string, unknown>;
  const memberId =
    typeof row.league_member_id === "string" ? row.league_member_id : "";

  if (!memberId) return null;

  const stats =
    row.round_stats && typeof row.round_stats === "object"
      ? (row.round_stats as Record<string, unknown>)
      : {};

  return {
    league_member_id: memberId,
    display_name:
      typeof row.display_name === "string" && row.display_name.trim()
        ? row.display_name
        : "Club FantaGol",
    position_preview: toNumber(row.position_preview),
    baseline_position: toNumber(row.baseline_position),
    movement_preview: toNumber(row.movement_preview),
    baseline_points: toNumber(row.baseline_points),
    round_points: toNumber(row.round_points),
    projected_points: toNumber(row.projected_points),
    pending: row.pending === true,
    score_phase:
      typeof row.score_phase === "string" ? row.score_phase : "waiting",
    round_stats: {
      exact_count: toNumber(stats.exact_count),
      bonus_count: toNumber(stats.bonus_count),
      malus_count: toNumber(stats.malus_count),
      wins: toNumber(stats.wins),
      draws: toNumber(stats.draws),
      losses: toNumber(stats.losses),
      goals_for: toNumber(stats.goals_for),
      goals_against: toNumber(stats.goals_against),
      goal_difference: toNumber(stats.goal_difference),
      mini_wins: toNumber(stats.mini_wins),
      mini_draws: toNumber(stats.mini_draws),
      mini_losses: toNumber(stats.mini_losses),
      mini_difference: toNumber(stats.mini_difference),
    },
  };
}

function normalizeModePayload(
  mode: Mode,
  value: unknown
): ModePayload | null {
  if (!value || typeof value !== "object") return null;

  const payload = value as Record<string, unknown>;
  const ranking = Array.isArray(payload.ranking)
    ? payload.ranking
        .map(normalizeStandingRow)
        .filter((row): row is StandingRow => row !== null)
        .sort(
          (left, right) =>
            left.position_preview - right.position_preview ||
            left.display_name.localeCompare(right.display_name, "it")
        )
    : [];

  return {
    mode,
    preview: payload.preview !== false,
    member_count: toNumber(payload.member_count, ranking.length),
    pending_member_count: toNumber(payload.pending_member_count),
    ranking,
  };
}

function formatPoints(value: number) {
  return new Intl.NumberFormat("it-IT", {
    maximumFractionDigits: 2,
  }).format(value);
}

function Movement({ value }: { value: number }) {
  if (value > 0) {
    return (
      <span
        className="inline-flex min-w-8 items-center justify-center rounded-full bg-emerald-500/10 px-2 py-1 text-xs font-black text-emerald-400"
        title={`Guadagna ${value} posizioni`}
      >
        ↑{value}
      </span>
    );
  }

  if (value < 0) {
    return (
      <span
        className="inline-flex min-w-8 items-center justify-center rounded-full bg-red-500/10 px-2 py-1 text-xs font-black text-red-400"
        title={`Perde ${Math.abs(value)} posizioni`}
      >
        ↓{Math.abs(value)}
      </span>
    );
  }

  return (
    <span
      className="inline-flex min-w-8 items-center justify-center rounded-full bg-white/5 px-2 py-1 text-xs font-black text-gray-500"
      title="Posizione invariata"
    >
      —
    </span>
  );
}

export default function ClassifichePage() {
  const [mode, setMode] = useState<Mode>("pure_points");
  const [menuOpen, setMenuOpen] = useState(false);
  const [leagueInfo, setLeagueInfo] = useState<LeagueInfo>({
    leagueId: "",
    leagueName: "FantaGol",
    displayName: "Club FantaGol",
    inviteCode: "",
    role: "member",
  });
  const [roundNumber, setRoundNumber] = useState<number | null>(null);
  const [standings, setStandings] =
    useState<Partial<Record<Mode, ModePayload>>>({});
  const [simulationStatus, setSimulationStatus] = useState("");
  const [generatedAt, setGeneratedAt] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;

    async function loadStandings() {
      setLoading(true);
      setErrorMessage(null);

      const {
        data: { session },
      } = await supabase.auth.getSession();

      if (!session?.user) {
        window.location.href = "/login";
        return;
      }

      const { data: leaguesData, error: leaguesError } = await supabase.rpc(
        "get_my_leagues_rpc"
      );

      if (cancelled) return;

      if (leaguesError) {
        setErrorMessage(leaguesError.message);
        setLoading(false);
        return;
      }

      const availableLeagues = (leaguesData || []) as MyLeagueRpcRow[];
      const rememberedLeagueId =
        window.localStorage.getItem(LAST_LEAGUE_STORAGE_KEY) || "";

      const selectedLeague =
        availableLeagues.find(
          (league) => league.league_id === rememberedLeagueId
        ) || availableLeagues[0];

      if (!selectedLeague?.league_id) {
        setErrorMessage("Nessuna lega attiva trovata.");
        setLoading(false);
        return;
      }

      window.localStorage.setItem(
        LAST_LEAGUE_STORAGE_KEY,
        selectedLeague.league_id
      );

      setLeagueInfo({
        leagueId: selectedLeague.league_id,
        leagueName: selectedLeague.league_name || "Lega FantaGol",
        displayName: selectedLeague.display_name || "Club FantaGol",
        inviteCode:
          selectedLeague.invite_code || selectedLeague.league_id,
        role: selectedLeague.role || "member",
      });

      const { data: roundData, error: roundError } = await supabase.rpc(
        "get_my_current_league_round_rpc",
        { p_league_id: selectedLeague.league_id }
      );

      if (cancelled) return;

      if (roundError) {
        setErrorMessage(roundError.message);
        setLoading(false);
        return;
      }

      const currentRound = ((roundData || []) as CurrentRoundRpcRow[])[0];

      if (!currentRound?.league_round_id) {
        setErrorMessage("Nessuna giornata disponibile per questa lega.");
        setLoading(false);
        return;
      }

      setRoundNumber(currentRound.league_round_number ?? null);

      const { data: standingsData, error: standingsError } = await supabase.rpc(
        "get_my_standings_preview_rpc",
        { p_league_round_id: currentRound.league_round_id }
      );

      if (cancelled) return;

      if (standingsError) {
        setErrorMessage(standingsError.message);
        setLoading(false);
        return;
      }

      const response = ((standingsData || []) as StandingsRpcRow[])[0];

      if (!response?.standings_preview) {
        setStandings({});
        setSimulationStatus("");
        setGeneratedAt(null);
        setLoading(false);
        return;
      }

      const rawModes = response.standings_preview.modes || {};
      const nextStandings: Partial<Record<Mode, ModePayload>> = {};

      for (const candidateMode of [
        "pure_points",
        "fantacalcio",
        "one_to_one",
      ] as const) {
        const normalized = normalizeModePayload(
          candidateMode,
          rawModes[candidateMode]
        );

        if (normalized) {
          nextStandings[candidateMode] = normalized;
        }
      }

      setStandings(nextStandings);
      setSimulationStatus(response.simulation_status || "");
      setGeneratedAt(response.standings_preview.generated_at || null);

      const firstAvailableMode = (
  ["pure_points", "fantacalcio", "one_to_one"] as Mode[]
).find((candidateMode) => nextStandings[candidateMode]);

setMode((currentMode) =>
  nextStandings[currentMode]
    ? currentMode
    : firstAvailableMode ?? currentMode
);

      setLoading(false);
    }

    void loadStandings();

    return () => {
      cancelled = true;
    };
  }, []);

  const activePayload = standings[mode] || null;
  const activeRanking = activePayload?.ranking || [];

  const generatedLabel = useMemo(() => {
    if (!generatedAt) return null;

    const date = new Date(generatedAt);
    if (Number.isNaN(date.getTime())) return null;

    return new Intl.DateTimeFormat("it-IT", {
      day: "2-digit",
      month: "2-digit",
      year: "numeric",
      hour: "2-digit",
      minute: "2-digit",
    }).format(date);
  }, [generatedAt]);

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

      <section className="mx-auto max-w-6xl px-4 py-8 sm:px-6 sm:py-10">
        <p className="text-sm font-semibold uppercase tracking-[0.3em] text-[#A6E824]">
          {leagueInfo.leagueName || "Lega"}
        </p>

        <h1 className="mt-3 text-4xl font-black sm:text-5xl">Classifiche</h1>

        <p className="mt-4 max-w-3xl text-sm leading-6 text-gray-400 sm:text-base">
          Le graduatorie vengono lette direttamente dallo Standings Engine e
          seguono il ruleset attivo della lega.
        </p>

        <div className="mt-7 grid grid-cols-3 gap-2 sm:flex sm:flex-wrap sm:gap-3">
          {(
            [
              ["pure_points", "punti-puri"],
              ["fantacalcio", "fantacalcio"],
              ["one_to_one", "one-to-one"],
            ] as const
          ).map(([candidateMode, iconMode]) => {
            const available = Boolean(standings[candidateMode]);

            return (
              <button
                key={candidateMode}
                type="button"
                onClick={() => setMode(candidateMode)}
                disabled={!loading && !available}
                className={`flex min-w-0 items-center justify-center gap-2 rounded-xl px-2 py-3 font-bold transition sm:px-5 ${
                  mode === candidateMode
                    ? "bg-[#A6E824] text-black"
                    : available || loading
                      ? "bg-[#1f2427] text-white hover:bg-[#2a3033]"
                      : "cursor-not-allowed bg-[#141719] text-gray-600"
                }`}
              >
                <span className="shrink-0 scale-75 sm:scale-90">
                  <FantaGolModeIcon mode={iconMode} />
                </span>
                <span className="truncate text-[10px] uppercase sm:text-sm">
                  {modeLabels[candidateMode]}
                </span>
              </button>
            );
          })}
        </div>

        <div className="mt-6 overflow-hidden rounded-3xl border border-gray-700 bg-[#111111]">
          <div className="flex flex-col gap-4 border-b border-gray-800 p-5 sm:flex-row sm:items-end sm:justify-between sm:p-6">
            <div>
              <h2 className="text-2xl font-black">
                {modeLabels[mode]}
              </h2>

              <p className="mt-2 max-w-3xl text-sm leading-6 text-gray-400">
                {modeDescriptions[mode]}
              </p>

              {generatedLabel && (
                <p className="mt-2 text-[11px] font-semibold text-gray-600">
                  Snapshot aggiornato il {generatedLabel}
                  {simulationStatus ? ` · ${simulationStatus}` : ""}
                </p>
              )}
            </div>

            <div className="self-start rounded-2xl bg-black px-4 py-3 text-sm font-black text-[#A6E824] sm:self-auto">
              Giornata {roundNumber ?? "—"}
            </div>
          </div>

          {loading && (
            <div className="px-6 py-16 text-center text-sm font-bold text-gray-400">
              Caricamento delle classifiche dinamiche...
            </div>
          )}

          {!loading && errorMessage && (
            <div className="px-6 py-14 text-center">
              <p className="font-black text-red-300">
                Impossibile caricare le classifiche
              </p>
              <p className="mt-2 text-sm text-gray-500">{errorMessage}</p>
            </div>
          )}

          {!loading && !errorMessage && !activePayload && (
            <div className="px-6 py-14 text-center">
              <p className="font-black text-gray-300">
                Classifica non ancora disponibile
              </p>
              <p className="mt-2 text-sm leading-6 text-gray-500">
                Il motore non ha ancora pubblicato uno snapshot per questa
                modalità e questa giornata.
              </p>
            </div>
          )}

          {!loading &&
            !errorMessage &&
            activePayload &&
            activeRanking.length === 0 && (
              <div className="px-6 py-14 text-center text-sm font-bold text-gray-500">
                Nessun partecipante presente nella classifica.
              </div>
            )}

          {!loading &&
            !errorMessage &&
            activePayload &&
            activeRanking.length > 0 && (
              <div className="overflow-x-auto">
                <table className="w-full min-w-[760px] table-fixed">
                  <thead className="bg-[#1f2427] text-[10px] uppercase tracking-[0.06em] text-gray-400 sm:text-[11px] sm:tracking-[0.08em]">
                    <tr>
                      <th className="sticky left-0 z-30 w-10 bg-[#1f2427] px-2 py-3 text-left sm:px-3 sm:py-4">#</th>
                      <th className="sticky left-10 z-30 w-10 bg-[#1f2427] px-1 py-3 text-center sm:py-4" aria-label="Avatar" />
                      <th className="sticky left-20 z-30 w-32 bg-[#1f2427] px-2 py-3 text-left sm:w-40 sm:px-3 sm:py-4">Club</th>
                      <th className="sticky left-[13rem] z-30 w-16 bg-[#1f2427] px-2 py-3 text-right text-[#A6E824] sm:left-[15rem] sm:w-20 sm:px-3 sm:py-4">Punti</th>
                      <th className="w-16 px-2 py-3 text-center sm:px-3 sm:py-4">Mov.</th>

                      {mode === "pure_points" ? (
                        <>
                          <th className="px-2 py-3 text-right sm:px-3 sm:py-4">Giornata</th>
                          <th className="px-2 py-3 text-right sm:px-3 sm:py-4">Exact</th>
                          <th className="px-2 py-3 text-right sm:px-3 sm:py-4">Bonus</th>
                          <th className="px-2 py-3 text-right sm:px-3 sm:py-4">Malus</th>
                        </>
                      ) : mode === "fantacalcio" ? (
                        <>
                          <th className="px-2 py-3 text-right sm:px-3 sm:py-4">G</th>
                          <th className="px-2 py-3 text-right sm:px-3 sm:py-4">V</th>
                          <th className="px-2 py-3 text-right sm:px-3 sm:py-4">N</th>
                          <th className="px-2 py-3 text-right sm:px-3 sm:py-4">P</th>
                          <th className="px-2 py-3 text-right sm:px-3 sm:py-4">GF</th>
                          <th className="px-2 py-3 text-right sm:px-3 sm:py-4">GS</th>
                        </>
                      ) : (
                        <>
                          <th className="px-2 py-3 text-right sm:px-3 sm:py-4">G</th>
                          <th className="px-2 py-3 text-right sm:px-3 sm:py-4">V</th>
                          <th className="px-2 py-3 text-right sm:px-3 sm:py-4">N</th>
                          <th className="px-2 py-3 text-right sm:px-3 sm:py-4">P</th>
                          <th className="px-2 py-3 text-right sm:px-3 sm:py-4">Mini V</th>
                          <th className="px-2 py-3 text-right sm:px-3 sm:py-4">Mini P</th>
                        </>
                      )}
                    </tr>
                  </thead>

                  <tbody>
                    {activeRanking.map((club) => {
                      const stats = club.round_stats;

                      return (
                        <tr
                          key={club.league_member_id}
                          className="border-t border-gray-800 transition hover:bg-white/[0.025]"
                        >
                          <td className="sticky left-0 z-20 w-10 bg-[#111111] px-2 py-3 font-black text-gray-400 sm:px-3 sm:py-4">
                            {club.position_preview}
                          </td>

                          <td className="sticky left-10 z-20 w-10 bg-[#111111] px-1 py-3 text-center sm:py-4">
                            <span
                              className="mx-auto flex h-7 w-7 items-center justify-center rounded-full border border-[#A6E824]/30 bg-[#A6E824]/10 text-[11px] font-black uppercase text-[#A6E824]"
                              title={club.display_name}
                              aria-hidden="true"
                            >
                              {club.display_name.trim().charAt(0) || "F"}
                            </span>
                          </td>

                          <td className="sticky left-20 z-20 w-32 bg-[#111111] px-2 py-3 sm:w-40 sm:px-3 sm:py-4">
                            <div className="flex min-w-0 items-center gap-1.5">
                              <span className="truncate text-sm font-bold" title={club.display_name}>
                                {club.display_name}
                              </span>
                              {club.pending && (
                                <span
                                  className="h-1.5 w-1.5 shrink-0 rounded-full bg-orange-400"
                                  title="Risultato in elaborazione"
                                />
                              )}
                            </div>
                          </td>

                          <td className="sticky left-[13rem] z-20 w-16 bg-[#111111] px-2 py-3 text-right text-base font-black text-[#A6E824] sm:left-[15rem] sm:w-20 sm:px-3 sm:py-4 sm:text-lg">
                            {formatPoints(club.projected_points)}
                          </td>

                          <td className="w-16 px-2 py-3 text-center sm:px-3 sm:py-4">
                            <Movement value={club.movement_preview} />
                          </td>

                          {mode === "pure_points" ? (
                            <>
                              <td className="px-2 py-3 text-right font-bold text-gray-300 sm:px-3 sm:py-4">
                                {formatPoints(club.round_points)}
                              </td>
                              <td className="px-2 py-3 text-right sm:px-3 sm:py-4">
                                {stats.exact_count ?? 0}
                              </td>
                              <td className="px-2 py-3 text-right sm:px-3 sm:py-4">
                                {stats.bonus_count ?? 0}
                              </td>
                              <td className="px-2 py-3 text-right sm:px-3 sm:py-4">
                                {stats.malus_count ?? 0}
                              </td>
                            </>
                          ) : mode === "fantacalcio" ? (
                            <>
                              <td className="px-2 py-3 text-right sm:px-3 sm:py-4">
                                {(stats.wins ?? 0) +
                                  (stats.draws ?? 0) +
                                  (stats.losses ?? 0)}
                              </td>
                              <td className="px-2 py-3 text-right sm:px-3 sm:py-4">
                                {stats.wins ?? 0}
                              </td>
                              <td className="px-2 py-3 text-right sm:px-3 sm:py-4">
                                {stats.draws ?? 0}
                              </td>
                              <td className="px-2 py-3 text-right sm:px-3 sm:py-4">
                                {stats.losses ?? 0}
                              </td>
                              <td className="px-2 py-3 text-right sm:px-3 sm:py-4">
                                {stats.goals_for ?? 0}
                              </td>
                              <td className="px-2 py-3 text-right sm:px-3 sm:py-4">
                                {stats.goals_against ?? 0}
                              </td>
                            </>
                          ) : (
                            <>
                              <td className="px-2 py-3 text-right sm:px-3 sm:py-4">
                                {(stats.wins ?? 0) +
                                  (stats.draws ?? 0) +
                                  (stats.losses ?? 0)}
                              </td>
                              <td className="px-2 py-3 text-right sm:px-3 sm:py-4">
                                {stats.wins ?? 0}
                              </td>
                              <td className="px-2 py-3 text-right sm:px-3 sm:py-4">
                                {stats.draws ?? 0}
                              </td>
                              <td className="px-2 py-3 text-right sm:px-3 sm:py-4">
                                {stats.losses ?? 0}
                              </td>
                              <td className="px-2 py-3 text-right sm:px-3 sm:py-4">
                                {stats.mini_wins ?? 0}
                              </td>
                              <td className="px-2 py-3 text-right sm:px-3 sm:py-4">
                                {stats.mini_losses ?? 0}
                              </td>
                            </>
                          )}
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div>
            )}
        </div>
      </section>
    </main>
  );
}
