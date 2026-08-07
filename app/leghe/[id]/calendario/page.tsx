"use client";

import { useEffect, useMemo, useState } from "react";
import { useParams, useRouter } from "next/navigation";
import FantaGolLogo from "../../../../components/FantaGolLogo";
import HamburgerDrawer from "../../../../components/app/HamburgerDrawer";
import { supabase } from "../../../../lib/supabaseClient";

const LAST_LEAGUE_STORAGE_KEY = "fantagol:last-league-id";

type CalendarMode = "fantacalcio" | "one_to_one";

type LeagueInfo = {
  id: string;
  name: string;
  displayName: string;
  inviteCode: string;
  role: string;
  visibility: "private" | "public";
};

type MyLeagueRpcRow = {
  league_id: string;
  league_name?: string | null;
  display_name?: string | null;
  invite_code?: string | null;
  role?: string | null;
};

type PublicLeagueRpcRow = {
  league_id: string;
  visibility?: string | null;
};

type CurrentLeagueRoundRpcRow = {
  league_round_id: string;
  league_round_number?: number | null;
  status?: string | null;
};

type LeagueRoundRow = {
  id: string;
  league_id: string;
  fantagol_round_id: string;
  league_round_number: number;
  status: string;
  enabled: boolean;
  opens_at?: string | null;
  lock_at?: string | null;
  created_at?: string | null;
  updated_at?: string | null;
};

type ScheduleVersionRow = {
  id: string;
  league_id: string;
  version: number;
  member_count: number;
  has_bye: boolean;
  reason: string;
  active: boolean;
  generated_at: string | null;
  locked_at: string | null;
};

type LeagueFixtureRow = {
  id: string;
  league_id: string;
  league_round_id: string;
  schedule_version_id: string;
  mode: string;
  cycle_number: number;
  leg_number: number;
  pairing_round_number: number;
  home_member_id: string | null;
  away_member_id: string | null;
  is_bye: boolean;
  created_at?: string | null;
};

type LeagueMemberRow = {
  membership_id: string;
  display_name?: string | null;
  club_name?: string | null;
  status?: string | null;
  crest_url?: string | null;
};

type CalendarRound = {
  id: string;
  number: number;
  status: string;
  enabled: boolean;
};

function normalizeMode(value: string): CalendarMode | null {
  if (value === "fantacalcio") return "fantacalcio";

  if (
    value === "one_to_one" ||
    value === "one-to-one" ||
    value === "onetoone"
  ) {
    return "one_to_one";
  }

  return null;
}

function getClubName(
  memberId: string | null,
  membersById: Map<string, LeagueMemberRow>,
) {
  if (!memberId) return "Riposo";

  const member = membersById.get(memberId);

  return member?.club_name || member?.display_name || "Club FantaGol";
}

function getInitialRound(rounds: CalendarRound[]) {
  const liveRound = rounds.find((round) =>
    ["live", "waiting_postponed", "final_calculable", "scoring"].includes(
      round.status,
    ),
  );

  if (liveRound) return liveRound.id;

  const openRound = rounds.find((round) => round.status === "predictions_open");

  if (openRound) return openRound.id;

  const scheduledRound = rounds.find(
    (round) =>
      round.enabled &&
      ["scheduled", "predictions_locked"].includes(round.status),
  );

  if (scheduledRound) return scheduledRound.id;

  return rounds.find((round) => round.enabled)?.id || rounds[0]?.id || "";
}

function modeLabel(mode: CalendarMode) {
  return mode === "fantacalcio" ? "Fantacalcio" : "One-to-One";
}

type RoundVisualState = "disabled" | "closed" | "live" | "upcoming";

function getRoundVisualState(
  round: CalendarRound,
  currentRoundId: string | null,
  currentRoundNumber: number | null,
): RoundVisualState {
  if (!round.enabled) return "disabled";

  if (
    [
      "official",
      "recalculated",
      "archived",
      "cancelled",
      "certified",
      "closed",
      "completed",
      "published",
      "round_certified",
    ].includes(round.status)
  ) {
    return "closed";
  }

  if (currentRoundId && round.id === currentRoundId) {
    return "live";
  }

  if (currentRoundNumber !== null && round.number < currentRoundNumber) {
    return "closed";
  }

  if (
    [
      "predictions_open",
      "predictions_locked",
      "live",
      "waiting_postponed",
      "final_calculable",
      "scoring",
    ].includes(round.status)
  ) {
    return "live";
  }

  return "upcoming";
}

function getRoundStatusLabel(state: RoundVisualState) {
  if (state === "disabled") return "Non utilizzata";
  if (state === "closed") return "Chiusa";
  if (state === "live") return "In corso";

  return "Da giocare";
}

export default function LeagueCalendarPage() {
  const params = useParams<{ id: string }>();
  const router = useRouter();
  const leagueId = params.id;

  const [menuOpen, setMenuOpen] = useState(false);
  const [loading, setLoading] = useState(true);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);

  const [league, setLeague] = useState<LeagueInfo | null>(null);
  const [rounds, setRounds] = useState<CalendarRound[]>([]);
  const [currentRoundId, setCurrentRoundId] = useState<string | null>(null);
  const [currentRoundNumber, setCurrentRoundNumber] = useState<number | null>(
    null,
  );
  const [fixtures, setFixtures] = useState<LeagueFixtureRow[]>([]);
  const [members, setMembers] = useState<LeagueMemberRow[]>([]);

  const [selectedRoundId, setSelectedRoundId] = useState("");
  const [activeMode, setActiveMode] = useState<CalendarMode>("fantacalcio");

  useEffect(() => {
    let cancelled = false;

    async function loadCalendar() {
      setLoading(true);
      setErrorMessage(null);

      const {
        data: { session },
      } = await supabase.auth.getSession();

      if (cancelled) return;

      if (!session?.user) {
        window.location.assign("/login");
        return;
      }

      const [
        myLeaguesResult,
        publicLeaguesResult,
        roundsResult,
        schedulesResult,
        membersResult,
        currentRoundResult,
      ] = await Promise.all([
        supabase.rpc("get_my_leagues_rpc"),
        supabase.rpc("get_public_leagues_rpc", {
          page_size: 100,
          cursor_created_at: null,
          cursor_league_id: null,
          roster_filter: "all",
        }),
        supabase
          .from("league_rounds")
          .select("*")
          .eq("league_id", leagueId)
          .order("league_round_number", { ascending: true }),
        supabase
          .from("league_schedule_versions")
          .select("*")
          .eq("league_id", leagueId)
          .eq("active", true)
          .order("version", { ascending: false })
          .limit(1),
        supabase.rpc("get_current_league_members_v2_rpc", {
          target_league_id: leagueId,
        }),
        supabase.rpc("get_my_current_league_round_rpc", {
          p_league_id: leagueId,
        }),
      ]);

      if (cancelled) return;

      if (myLeaguesResult.error) {
        setErrorMessage(myLeaguesResult.error.message);
        setLoading(false);
        return;
      }

      const currentLeague = (
        (myLeaguesResult.data || []) as MyLeagueRpcRow[]
      ).find((row) => row.league_id === leagueId);

      if (!currentLeague) {
        window.location.assign("/leghe");
        return;
      }

      const publicLeagueIds = new Set(
        publicLeaguesResult.error
          ? []
          : ((publicLeaguesResult.data || []) as PublicLeagueRpcRow[])
              .filter((row) => row.visibility === "public")
              .map((row) => row.league_id),
      );

      const nextLeague: LeagueInfo = {
        id: currentLeague.league_id,
        name: currentLeague.league_name || "Lega FantaGol",
        displayName: currentLeague.display_name || "Club FantaGol",
        inviteCode: currentLeague.invite_code || currentLeague.league_id,
        role: currentLeague.role || "member",
        visibility: publicLeagueIds.has(currentLeague.league_id)
          ? "public"
          : "private",
      };

      setLeague(nextLeague);

      window.localStorage.setItem(
        LAST_LEAGUE_STORAGE_KEY,
        currentLeague.league_id,
      );

      if (roundsResult.error) {
        setErrorMessage(roundsResult.error.message);
        setLoading(false);
        return;
      }

      if (schedulesResult.error) {
        setErrorMessage(schedulesResult.error.message);
        setLoading(false);
        return;
      }

      if (membersResult.error) {
        setErrorMessage(membersResult.error.message);
        setLoading(false);
        return;
      }

      if (currentRoundResult.error) {
        setErrorMessage(currentRoundResult.error.message);
        setLoading(false);
        return;
      }

      const nextRounds = ((roundsResult.data || []) as LeagueRoundRow[]).map(
        (row) => ({
          id: row.id,
          number: row.league_round_number,
          status: row.status,
          enabled: row.enabled,
        }),
      );

      const activeSchedule =
        ((schedulesResult.data || []) as ScheduleVersionRow[])[0] || null;

      const currentRound =
        ((currentRoundResult.data || []) as CurrentLeagueRoundRpcRow[])[0] ||
        null;

      const resolvedCurrentRound = currentRound?.league_round_id
        ? nextRounds.find((round) => round.id === currentRound.league_round_id) ||
          null
        : null;

      const resolvedCurrentRoundNumber =
        currentRound?.league_round_number ??
        resolvedCurrentRound?.number ??
        null;

      setRounds(nextRounds);
      setCurrentRoundId(resolvedCurrentRound?.id || null);
      setCurrentRoundNumber(resolvedCurrentRoundNumber);

      setMembers((membersResult.data || []) as LeagueMemberRow[]);
      setSelectedRoundId(
        resolvedCurrentRound?.id || getInitialRound(nextRounds),
      );

      if (activeSchedule?.id) {
        const fixturesResult = await supabase
          .from("league_fixtures")
          .select("*")
          .eq("league_id", leagueId)
          .eq("schedule_version_id", activeSchedule.id)
          .order("pairing_round_number", { ascending: true })
          .order("mode", { ascending: true })
          .order("home_member_id", { ascending: true });

        if (cancelled) return;

        if (fixturesResult.error) {
          setErrorMessage(fixturesResult.error.message);
          setLoading(false);
          return;
        }

        setFixtures((fixturesResult.data || []) as LeagueFixtureRow[]);
      } else {
        setFixtures([]);
      }

      setLoading(false);
    }

    void loadCalendar();

    return () => {
      cancelled = true;
    };
  }, [leagueId]);

  const activeRound = useMemo(
    () =>
      rounds.find((round) => round.id === selectedRoundId) || rounds[0] || null,
    [rounds, selectedRoundId],
  );

  const membersById = useMemo(
    () => new Map(members.map((member) => [member.membership_id, member])),
    [members],
  );

  const activeFixtures = useMemo(() => {
    if (!activeRound) return [];

    return fixtures
      .filter(
        (fixture) =>
          fixture.league_round_id === activeRound.id &&
          normalizeMode(fixture.mode) === activeMode,
      )
      .sort((left, right) => {
        if (left.pairing_round_number !== right.pairing_round_number) {
          return left.pairing_round_number - right.pairing_round_number;
        }

        return left.id.localeCompare(right.id);
      });
  }, [activeMode, activeRound, fixtures]);

  if (loading) {
    return (
      <main className="flex min-h-screen items-center justify-center bg-black text-white">
        <div className="text-center">
          <div className="mx-auto h-10 w-10 animate-spin rounded-full border-2 border-white/15 border-t-[#A6E824]" />
          <p className="mt-4 text-sm font-bold text-gray-400">
            Caricamento calendario reale...
          </p>
        </div>
      </main>
    );
  }

  if (!league) return null;

  const isPublicLeague = league.visibility === "public";

  const headerAccentClass = isPublicLeague
    ? "border-[#38BDF8]/30"
    : "border-[#A6E824]/25";

  const interactiveAccentClass = isPublicLeague
    ? "hover:border-[#38BDF8]"
    : "hover:border-[#A6E824]";

  const selectedRoundAccentClass = isPublicLeague
    ? "border-[#38BDF8] bg-[#38BDF8] text-black"
    : "border-[#A6E824] bg-[#A6E824] text-black";

  const activeModeAccentClass = isPublicLeague
    ? "bg-[#38BDF8] text-black"
    : "bg-[#A6E824] text-black";

  const versusAccentClass = isPublicLeague
    ? "bg-[#38BDF8]/10 text-[#38BDF8]"
    : "bg-[#A6E824]/10 text-[#A6E824]";

  function getRoundCardClass(visualState: RoundVisualState, selected: boolean) {
    if (selected) {
      const selectedLiveAnimation =
        visualState === "live"
          ? "animate-[pulse_2.8s_ease-in-out_infinite]"
          : "";

      return `${selectedRoundAccentClass} shadow-lg shadow-black/30 ${selectedLiveAnimation}`;
    }

    if (visualState === "disabled") {
      return "border-gray-800 bg-[#111111]/60 text-gray-500 opacity-60";
    }

    if (visualState === "closed") {
      return "border-gray-800 bg-[#0b0d0e] text-gray-500 shadow-inner shadow-black/70";
    }

    if (visualState === "live") {
      return `border-white/20 bg-[#171a1c] text-white ring-1 ring-white/10 shadow-lg shadow-black/40 animate-[pulse_2.8s_ease-in-out_infinite] ${interactiveAccentClass}`;
    }

    return `border-gray-700 bg-gradient-to-b from-[#1a1d1f] to-[#101214] text-white shadow-[0_5px_12px_rgba(0,0,0,0.45)] hover:-translate-y-0.5 hover:shadow-[0_8px_16px_rgba(0,0,0,0.55)] ${interactiveAccentClass}`;
  }

  return (
    <main className="min-h-screen bg-black pt-14 text-white">
      <header
        className={`fixed inset-x-0 top-0 z-[80] border-b bg-[#1f2427] shadow-2xl shadow-black/80 ${headerAccentClass}`}
      >
        <div className="mx-auto flex h-14 max-w-6xl items-center justify-between px-4 md:px-6">
          <button
            type="button"
            onClick={() => router.push(`/leghe/${leagueId}`)}
            className="pointer-events-auto relative z-0 block -translate-x-8 translate-y-5 md:-translate-x-20 md:translate-y-6"
            aria-label="Torna alla dashboard della lega"
          >
            <FantaGolLogo />
          </button>

          <button
            type="button"
            onClick={() => setMenuOpen(true)}
            aria-label="Apri menu"
            className={`rounded-lg border border-gray-600 bg-[#2b2f31] px-3 py-2 text-2xl leading-none text-white transition ${interactiveAccentClass}`}
          >
            ☰
          </button>
        </div>
      </header>

      <HamburgerDrawer
        open={menuOpen}
        leagueName={league.name}
        displayName={league.displayName}
        inviteCode={league.inviteCode}
        role={league.role}
        onClose={() => setMenuOpen(false)}
      />

      <section className="mx-auto max-w-6xl px-4 py-10 sm:px-6">
        <h1 className="text-4xl font-black sm:text-5xl">Calendario</h1>

        {errorMessage && (
          <div className="mt-6 rounded-2xl border border-red-500/30 bg-red-500/10 px-4 py-4 text-sm font-semibold text-red-200">
            {errorMessage}
          </div>
        )}

        {!errorMessage && rounds.length === 0 && (
          <div className="mt-8 rounded-3xl border border-white/10 bg-[#111417] p-8 text-center">
            <h2 className="text-2xl font-black">
              Calendario non ancora disponibile
            </h2>
            <p className="mx-auto mt-3 max-w-xl text-sm leading-6 text-gray-500">
              La lega non possiede ancora giornate materializzate. Il calendario
              sarà disponibile dopo l&apos;attivazione della competizione.
            </p>
          </div>
        )}

        {rounds.length > 0 && (
          <div className="mt-8 grid grid-cols-3 gap-2 sm:grid-cols-4 md:grid-cols-6 lg:grid-cols-8">
            {rounds.map((round) => {
              const selected = selectedRoundId === round.id;
              const visualState = getRoundVisualState(
                round,
                currentRoundId,
                currentRoundNumber,
              );
              const statusLabel = getRoundStatusLabel(visualState);

              return (
                <button
                  key={round.id}
                  type="button"
                  onClick={() => setSelectedRoundId(round.id)}
                  className={`rounded-2xl border px-3 py-3 text-left transition duration-200 ${getRoundCardClass(
                    visualState,
                    selected,
                  )}`}
                >
                  <div className="text-sm font-black">G{round.number}</div>

                  <div
                    className={`mt-1 inline-flex items-center rounded px-1.5 py-0.5 text-[9px] font-black uppercase tracking-[0.12em] ${
                      selected
                        ? visualState === "live"
                          ? "bg-black/10 text-black/65 animate-[pulse_2.2s_ease-in-out_infinite]"
                          : "bg-black/10 text-black/65"
                        : visualState === "disabled"
                          ? "border border-red-300/20 bg-red-950/20 text-red-300/80"
                          : visualState === "closed"
                            ? "-rotate-2 border border-gray-600/60 bg-black/30 text-gray-500"
                            : visualState === "live"
                              ? "border border-white/15 bg-white/5 text-white animate-[pulse_2.2s_ease-in-out_infinite]"
                              : "border border-white/10 bg-white/5 text-gray-300 shadow-sm shadow-black/40"
                    }`}
                  >
                    {statusLabel}
                  </div>
                </button>
              );
            })}
          </div>
        )}

        {activeRound && (
          <div className="mt-8 rounded-3xl border border-gray-700 bg-[#111111] p-4 sm:p-6">
            <div className="flex flex-col gap-4 md:flex-row md:items-end md:justify-between">
              <div>
                <h2 className="text-3xl font-black">
                  Giornata {activeRound.number}
                </h2>
              </div>

              <div className="flex flex-wrap gap-2">
                {(["fantacalcio", "one_to_one"] as CalendarMode[]).map(
                  (mode) => (
                    <button
                      key={mode}
                      type="button"
                      onClick={() => setActiveMode(mode)}
                      className={`rounded-xl px-4 py-2 text-sm font-black ${
                        activeMode === mode
                          ? activeModeAccentClass
                          : "bg-black text-gray-300"
                      }`}
                    >
                      {modeLabel(mode)}
                    </button>
                  ),
                )}
              </div>
            </div>

            {!activeRound.enabled ? (
              <div className="mt-6 rounded-3xl border border-gray-800 bg-black p-6 text-center">
                <div className="mx-auto flex h-14 w-14 items-center justify-center rounded-full border border-red-300/30 bg-red-950/20 text-2xl">
                  ⛔
                </div>

                <h3 className="mt-4 text-2xl font-black">
                  Giornata non utilizzata
                </h3>

                <p className="mx-auto mt-3 max-w-xl text-sm leading-6 text-gray-400">
                  Questa giornata non partecipa alla competizione della lega.
                </p>
              </div>
            ) : activeFixtures.length === 0 ? (
              <div className="mt-6 rounded-3xl border border-gray-800 bg-black p-6 text-center">
                <h3 className="text-xl font-black">Nessun abbinamento</h3>

                <p className="mt-2 text-sm leading-6 text-gray-500">
                  Non risultano fixture della modalità {modeLabel(activeMode)}{" "}
                  per questa giornata.
                </p>
              </div>
            ) : (
              <div className="mt-6 grid gap-3">
                {activeFixtures.map((fixture) => {
                  const homeName = getClubName(
                    fixture.home_member_id,
                    membersById,
                  );

                  const awayName = getClubName(
                    fixture.away_member_id,
                    membersById,
                  );

                  const bye = fixture.is_bye || !fixture.away_member_id;

                  return (
                    <article
                      key={fixture.id}
                      className={`rounded-3xl border p-4 ${
                        bye
                          ? "border-white/5 bg-black/50 opacity-60"
                          : "border-gray-800 bg-black"
                      }`}
                    >
                      <div className="grid items-center gap-3 sm:grid-cols-[minmax(0,1fr)_72px_minmax(0,1fr)]">
                        <div className="min-w-0 text-left">
                          <p className="truncate text-sm font-black sm:text-base">
                            {homeName}
                          </p>
                        </div>

                        <div
                          className={`rounded-xl px-4 py-2 text-center text-sm font-black ${
                            bye
                              ? "bg-gray-700/20 text-gray-500"
                              : versusAccentClass
                          }`}
                        >
                          {bye ? "RIPOSO" : "VS"}
                        </div>

                        <div className="min-w-0 text-left sm:text-right">
                          <p
                            className={`truncate text-sm font-black sm:text-base ${
                              bye ? "text-gray-500" : "text-white"
                            }`}
                          >
                            {awayName}
                          </p>
                        </div>
                      </div>
                    </article>
                  );
                })}
              </div>
            )}
          </div>
        )}
      </section>
    </main>
  );
}
