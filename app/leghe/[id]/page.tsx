"use client";

import { useEffect, useMemo, useState } from "react";
import { useParams, useRouter } from "next/navigation";
import { supabase } from "../../../lib/supabaseClient";

import Badge from "../../../components/ui/Badge";
import DashboardCard from "../../../components/ui/DashboardCard";
import HamburgerDrawer from "../../../components/app/HamburgerDrawer";
import FantaGolModeIcon from "../../../components/app/FantaGolModeIcon";
import TeamCrest from "../../../components/app/TeamCrest";
import ModeSummaryCard from "../../../components/app/ModeSummaryCard";

const LAST_LEAGUE_STORAGE_KEY = "fantagol:last-league-id";

type League = {
  id: string;
  name: string;
  invite_code: string;
  display_name: string;
  role: string;
};

type MyLeagueRpcRow = {
  league_id: string;
  membership_id?: string | null;
  league_name?: string | null;
  display_name?: string | null;
  invite_code?: string | null;
  role?: string | null;
  status?: string | null;
};

type RoundPredictionRow = {
  league_round_id: string;
  league_round_number: number;
  prediction_window_state: string;
  match_id: string;
  kickoff: string | null;
  match_status: string;
  home_score: number | null;
  away_score: number | null;
  home_team_name: string;
  home_team_logo_url: string | null;
  home_team_crest_reference: string | null;
  away_team_name: string;
  away_team_logo_url: string | null;
  away_team_crest_reference: string | null;
};

type DashboardMatch = {
  id: string;
  home: string;
  away: string;
  kickoff: string | null;
  kickoffDay: string;
  kickoffHour: string;
  status: string;
  homeScore: number | null;
  awayScore: number | null;
  homeCrestReference: string | null;
  homeLogoUrl: string | null;
  awayCrestReference: string | null;
  awayLogoUrl: string | null;
};

function cleanTeamDisplayName(name: string) {
  const knownNames: Record<string, string> = {
    "FC Internazionale Milano": "Inter",
    "Internazionale Milano": "Inter",
    "AC Milan": "Milan",
    "Juventus FC": "Juventus",
    "SSC Napoli": "Napoli",
    "AS Roma": "Roma",
    "SS Lazio": "Lazio",
    "ACF Fiorentina": "Fiorentina",
    "Atalanta BC": "Atalanta",
    "Bologna FC 1909": "Bologna",
    "Genoa CFC": "Genoa",
    "Hellas Verona FC": "Hellas Verona",
    "Parma Calcio 1913": "Parma",
    "Torino FC": "Torino",
    "Udinese Calcio": "Udinese",
    "US Lecce": "Lecce",
    "US Sassuolo Calcio": "Sassuolo",
    "US Cremonese": "Cremonese",
    "Pisa SC": "Pisa",
    "Como 1907": "Como",
    "Cagliari Calcio": "Cagliari",
    "AC Monza": "Monza",
    "Empoli FC": "Empoli",
    "Frosinone Calcio": "Frosinone",
    "Venezia FC": "Venezia",
    "Spezia Calcio": "Spezia",
    "UC Sampdoria": "Sampdoria",
  };

  const normalized = name.trim().replace(/\s+/g, " ");
  if (knownNames[normalized]) return knownNames[normalized];

  return normalized
    .replace(
      /^(?:A\.?\s*C\.?\s*F?\.?|F\.?\s*C\.?|S\.?\s*S\.?\s*C\.?|S\.?\s*S\.?|U\.?\s*S\.?|U\.?\s*C\.?|A\.?\s*S\.?|C\.?\s*F\.?\s*C\.?)\s+/i,
      ""
    )
    .replace(
      /\s+(?:Football Club|Calcio|F\.?\s*C\.?|C\.?\s*F\.?\s*C\.?|B\.?\s*C\.?|S\.?\s*C\.?)$/i,
      ""
    )
    .replace(/\s+(?:19|20)\d{2}$/i, "")
    .trim();
}

function formatKickoff(kickoff: string | null) {
  if (!kickoff) {
    return { day: "Data da definire", hour: "--:--" };
  }

  const date = new Date(kickoff);

  return {
    day: new Intl.DateTimeFormat("it-IT", {
      weekday: "short",
      day: "2-digit",
      month: "short",
    }).format(date),
    hour: new Intl.DateTimeFormat("it-IT", {
      hour: "2-digit",
      minute: "2-digit",
    }).format(date),
  };
}

function getLocalDateKey(value: Date | string) {
  const date = typeof value === "string" ? new Date(value) : value;

  return new Intl.DateTimeFormat("en-CA", {
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(date);
}


function getProviderScoreLabel(match: DashboardMatch) {
  return `${match.homeScore ?? 0} - ${match.awayScore ?? 0}`;
}

function MatchMiniRow({
  match,
  index,
}: {
  match: DashboardMatch;
  index: number;
}) {
  return (
    <div className="grid grid-cols-[22px_1fr_auto] items-center gap-2 rounded-xl border border-white/10 bg-black/35 px-3 py-2">
      <div className="flex h-6 w-6 items-center justify-center rounded-full bg-[#A6E824]/10 text-[11px] font-black text-[#A6E824]">
        {index}
      </div>

      <div className="min-w-0">
        <div className="flex min-w-0 items-center gap-1.5">
          <TeamCrest
            crestReference={match.homeCrestReference}
            logoUrl={match.homeLogoUrl}
            alt={`${match.home} stemma`}
            fallbackLabel={match.home}
            size="xs"
            className="h-5 w-5"
          />
          <span className="min-w-0 truncate text-sm font-black text-white">
            {match.home}
          </span>
          <span className="shrink-0 text-xs font-black text-gray-600">-</span>
          <TeamCrest
            crestReference={match.awayCrestReference}
            logoUrl={match.awayLogoUrl}
            alt={`${match.away} stemma`}
            fallbackLabel={match.away}
            size="xs"
            className="h-5 w-5"
          />
          <span className="min-w-0 truncate text-sm font-black text-white">
            {match.away}
          </span>
        </div>

        <div className="mt-0.5 text-[11px] font-semibold text-gray-500">
          {match.kickoffDay} · {match.kickoffHour}
        </div>
      </div>

      <div className="rounded-lg border border-white/10 bg-[#0b0d0e] px-2 py-1 text-[10px] font-black text-gray-400">
        {getProviderScoreLabel(match)}
      </div>
    </div>
  );
}

function DayMatchRow({ match }: { match: DashboardMatch }) {
  return (
    <div className="grid grid-cols-[1fr_auto_1fr] items-center gap-3 rounded-2xl border border-white/10 bg-black px-3 py-4">
      <div className="flex min-w-0 items-center justify-end gap-2">
        <span className="truncate text-right text-sm font-black sm:text-base">
          {match.home}
        </span>
        <TeamCrest
          crestReference={match.homeCrestReference}
          logoUrl={match.homeLogoUrl}
          alt={`${match.home} stemma`}
          fallbackLabel={match.home}
          size="sm"
        />
      </div>

      <div className="min-w-[68px] rounded-xl bg-[#A6E824]/10 px-3 py-2 text-center text-sm font-black text-[#A6E824]">
        {getProviderScoreLabel(match)}
      </div>

      <div className="flex min-w-0 items-center gap-2">
        <TeamCrest
          crestReference={match.awayCrestReference}
          logoUrl={match.awayLogoUrl}
          alt={`${match.away} stemma`}
          fallbackLabel={match.away}
          size="sm"
        />
        <span className="truncate text-sm font-black sm:text-base">
          {match.away}
        </span>
      </div>
    </div>
  );
}


function DashboardQuickIcon({ icon }: { icon: string }) {
  const base =
    "flex h-10 w-10 shrink-0 items-center justify-center rounded-xl border border-white/10 bg-[#071015]";

  if (icon === "control") {
    return (
      <span className="flex h-10 w-10 shrink-0 items-center justify-center rounded-xl border border-[#A6E824]/35 bg-[#A6E824]/10 shadow-[0_0_16px_rgba(166,232,36,0.18)]">
        <span className="relative h-7 w-7 rounded-lg border border-[#A6E824]/70 bg-black/40">
          <span className="absolute left-1 top-1 h-1.5 w-1.5 rounded-full bg-[#A6E824]" />
          <span className="absolute bottom-1 left-1 right-1 flex items-end gap-0.5">
            <span className="h-2 flex-1 rounded-t bg-[#A6E824]/50" />
            <span className="h-4 flex-1 rounded-t bg-[#A6E824]" />
            <span className="h-3 flex-1 rounded-t bg-[#A6E824]/70" />
          </span>
        </span>
      </span>
    );
  }

  if (icon === "target") {
    return (
      <span className={base}>
        <span className="flex h-6 w-6 items-center justify-center rounded-full border-2 border-[#A6E824]/80">
          <span className="flex h-3.5 w-3.5 items-center justify-center rounded-full border border-[#A6E824]/70">
            <span className="h-1.5 w-1.5 rounded-full bg-[#A6E824]" />
          </span>
        </span>
      </span>
    );
  }

  if (icon === "live") {
    return (
      <span className={base}>
        <span className="relative h-6 w-6 rounded-full border-2 border-[#A6E824]/80">
          <span className="absolute left-1/2 top-1/2 h-2 w-2 -translate-x-1/2 -translate-y-1/2 rounded-full bg-[#A6E824]" />
          <span className="absolute -right-1 -top-1 h-2.5 w-2.5 rounded-full bg-red-400" />
        </span>
      </span>
    );
  }

  if (icon === "ranking") {
    return (
      <span className={base}>
        <span className="relative h-7 w-7">
          <span className="absolute left-1/2 top-0 h-2 w-2 -translate-x-1/2 rounded-full bg-[#A6E824]" />
          <span className="absolute bottom-0 left-1/2 h-5 w-2.5 -translate-x-1/2 rounded-t bg-[#A6E824]" />
          <span className="absolute bottom-0 left-0 h-3.5 w-2.5 rounded-t bg-[#A6E824]/55" />
          <span className="absolute bottom-0 right-0 h-4 w-2.5 rounded-t bg-[#A6E824]/75" />
        </span>
      </span>
    );
  }

  if (icon === "calendar") {
    return (
      <span className={base}>
        <span className="h-6 w-6 overflow-hidden rounded-md border border-[#A6E824]/70">
          <span className="block h-2 bg-[#A6E824]" />
          <span className="grid grid-cols-3 gap-0.5 p-1">
            <span className="h-1 rounded bg-white/40" />
            <span className="h-1 rounded bg-white/40" />
            <span className="h-1 rounded bg-white/40" />
            <span className="h-1 rounded bg-white/40" />
            <span className="h-1 rounded bg-[#A6E824]" />
            <span className="h-1 rounded bg-white/40" />
          </span>
        </span>
      </span>
    );
  }

  if (icon === "members") {
    return (
      <span className={base}>
        <span className="relative h-6 w-7">
          <span className="absolute left-2 top-0 h-3 w-3 rounded-full bg-[#A6E824]" />
          <span className="absolute bottom-0 left-1 h-3 w-5 rounded-t-full bg-[#A6E824]/80" />
          <span className="absolute right-0 top-2 h-2.5 w-2.5 rounded-full bg-white/50" />
          <span className="absolute bottom-0 right-0 h-2.5 w-4 rounded-t-full bg-white/30" />
        </span>
      </span>
    );
  }

  return <span className={base} />;
}

function DashboardQuickAction({
  icon,
  label,
  href,
  special = false,
}: {
  icon: string;
  label: string;
  href: string;
  special?: boolean;
}) {
  return (
    <a
      href={href}
      className={`rounded-2xl p-4 text-left shadow-lg shadow-black/20 transition hover:-translate-y-0.5 hover:brightness-110 ${
        special
          ? "border border-[#A6E824]/40 bg-[#A6E824]/10 shadow-[0_0_22px_rgba(166,232,36,0.10)] animate-pulse hover:border-[#A6E824]/80"
          : "border border-white/10 bg-[#111417] hover:border-[#A6E824]/60"
      }`}
    >
      <DashboardQuickIcon icon={icon} />
      <div className={`mt-2 text-sm font-black ${special ? "text-[#A6E824]" : "text-white"}`}>
        {label}
      </div>
    </a>
  );
}

export default function LeagueDashboardPage() {
  const router = useRouter();
  const params = useParams();
  const leagueId = params.id as string;

  const [league, setLeague] = useState<League | null>(null);
  const [menuOpen, setMenuOpen] = useState(false);
  const [loading, setLoading] = useState(true);
  const [matches, setMatches] = useState<DashboardMatch[]>([]);
  const [roundNumber, setRoundNumber] = useState<number | null>(null);
  const [roundLabel, setRoundLabel] = useState("Giornata non disponibile");
  const [roundError, setRoundError] = useState<string | null>(null);

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

      const current = (data || []).find((row: MyLeagueRpcRow) => row.league_id === leagueId);

      if (!current) {
        window.location.href = "/leghe";
        return;
      }

      window.localStorage.setItem(LAST_LEAGUE_STORAGE_KEY, current.league_id);

      setLeague({
        id: current.league_id,
        name: current.league_name,
        invite_code: current.invite_code,
        display_name: current.display_name,
        role: current.role,
      });

      const { data: currentRoundData, error: currentRoundError } =
        await supabase.rpc("get_my_current_league_round_rpc", {
          p_league_id: leagueId,
        });

      if (currentRoundError) {
        setRoundError(currentRoundError.message);
        setLoading(false);
        return;
      }

      const currentRound = (currentRoundData || [])[0];

      if (!currentRound?.league_round_id) {
        setRoundError("Nessuna giornata disponibile per questa lega.");
        setLoading(false);
        return;
      }

      const { data: predictionData, error: predictionError } =
        await supabase.rpc("get_my_round_predictions_rpc", {
          p_league_round_id: currentRound.league_round_id,
        });

      if (predictionError) {
        setRoundError(predictionError.message);
        setLoading(false);
        return;
      }

      const rows = (predictionData || []) as RoundPredictionRow[];

      setRoundNumber(currentRound.league_round_number ?? rows[0]?.league_round_number ?? null);
      setRoundLabel(
        rows[0]?.prediction_window_state === "open"
          ? "Pronostici aperti"
          : rows[0]?.prediction_window_state === "not_open"
            ? "Pronostici non ancora aperti"
            : "Pronostici chiusi"
      );

      setMatches(
        rows.map((row) => {
          const kickoff = formatKickoff(row.kickoff);

          return {
            id: row.match_id,
            home: cleanTeamDisplayName(row.home_team_name),
            away: cleanTeamDisplayName(row.away_team_name),
            kickoff: row.kickoff,
            kickoffDay: kickoff.day,
            kickoffHour: kickoff.hour,
            status: row.match_status,
            homeScore: row.home_score,
            awayScore: row.away_score,
            homeCrestReference: row.home_team_crest_reference,
            homeLogoUrl: row.home_team_logo_url,
            awayCrestReference: row.away_team_crest_reference,
            awayLogoUrl: row.away_team_logo_url,
          };
        })
      );

      setLoading(false);
    }

    loadDashboard();
  }, [leagueId]);



  const todayMatches = useMemo(() => {
    const todayKey = getLocalDateKey(new Date());

    return matches.filter(
      (match) => match.kickoff && getLocalDateKey(match.kickoff) === todayKey
    );
  }, [matches]);

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
              Giornata {roundNumber ?? "-"}
            </p>

            <Badge variant="success">{roundLabel}</Badge>
          </div>

          {roundError && (
            <div className="mt-5 rounded-2xl border border-red-400/20 bg-red-500/10 px-4 py-3 text-sm font-semibold text-red-200">
              {roundError}
            </div>
          )}

          <div className="mt-5 grid grid-cols-1 gap-3 md:grid-cols-2">
            <div className="space-y-2 rounded-2xl border border-white/10 bg-white/[0.03] p-3">
              {matches.slice(0, 5).map((match, index) => (
                <MatchMiniRow key={match.id} match={match} index={index + 1} />
              ))}
            </div>

            <div className="space-y-2 rounded-2xl border border-white/10 bg-white/[0.03] p-3">
              {matches.slice(5, 10).map((match, index) => (
                <MatchMiniRow key={match.id} match={match} index={index + 6} />
              ))}
            </div>
          </div>

          <button
            type="button"
            onClick={() => router.push(`/leghe/${leagueId}/giornata`)}
            className="mt-6 w-full rounded-2xl bg-[#A6E824] px-6 py-4 font-black text-black shadow-lg shadow-[#A6E824]/20 transition hover:brightness-110"
          >
            Inserisci pronostici
          </button>
        </DashboardCard>

        <DashboardCard className="mt-6">
          <div className="flex items-center justify-between gap-4">
            <p className="text-sm font-semibold uppercase tracking-[0.2em] text-gray-400">
              Partite del giorno
            </p>

            <Badge>
              {todayMatches.length === 1
                ? "1 incontro"
                : `${todayMatches.length} incontri`}
            </Badge>
          </div>

          <div className="mt-4 space-y-3">
            {todayMatches.length > 0 ? (
              todayMatches.map((match) => (
                <DayMatchRow key={match.id} match={match} />
              ))
            ) : (
              <div className="rounded-2xl bg-black p-5 text-center text-sm font-semibold text-gray-500">
                Nessuna partita in programma oggi.
              </div>
            )}
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
              icon={<FantaGolModeIcon mode="fantacalcio" />}
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
              icon={<FantaGolModeIcon mode="one-to-one" />}
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
              icon={<FantaGolModeIcon mode="punti-puri" />}
              title="Punti Puri"
              value="0"
              description="Totale stagione"
            />
          </button>
        </div>

        <div className="mt-6 grid grid-cols-2 gap-4 md:grid-cols-6">
          <DashboardQuickAction icon="control" label="Control Room" href="/control-room" special />
          <DashboardQuickAction icon="target" label="Pronostici" href={`/leghe/${leagueId}/giornata`} />
          <DashboardQuickAction icon="live" label="Live" href={`/leghe/${leagueId}/giornata`} />
          <DashboardQuickAction icon="ranking" label="Classifiche" href="/classifiche" />
          <DashboardQuickAction icon="calendar" label="Calendario" href="/calendario" />
          <DashboardQuickAction icon="members" label="Membri" href="/membri" />
        </div>
      </section>

    </main>
  );
}
