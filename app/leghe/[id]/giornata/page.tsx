"use client";

import { useEffect, useMemo, useRef, useState, type TouchEvent } from "react";
import { useParams, useRouter } from "next/navigation";
import HamburgerDrawer from "../../../../components/app/HamburgerDrawer";
import SubmissionModal from "../../../../components/app/SubmissionModal";
import RoundSubmissionButton from "../../../../components/app/RoundSubmissionButton";
import KitPreview from "../../../../components/club/KitPreview";
import TeamCrest from "../../../../components/app/TeamCrest";
import { supabase } from "../../../../lib/supabaseClient";

type Prediction = { home: string; away: string };

type PredictionSaveState = "idle" | "saving" | "saved" | "error";

type LeagueInfo = {
  name: string;
  displayName: string;
  inviteCode: string;
  role: string;
};

type ClubInfo = {
  name: string;
  motto?: string | null;
  crest_url: string | null;
  kit_template: string;
  kit_primary_color: string;
  kit_secondary_color: string;
  kit_third_color: string;
  kit_logo_mode: string;
  kit_crest_position: string;
  stars_count: number;
};

type Match = {
  id: string;
  home: string;
  away: string;
  homeCrestReference: string | null;
  homeLogoUrl: string | null;
  awayCrestReference: string | null;
  awayLogoUrl: string | null;
  kickoffDay: string;
  kickoffHour: string;
  status: string;
  liveHome?: number;
  liveAway?: number;
  minute?: string;
  bonusActive?: string[];
  malusActive?: string[];
};

type RoundPredictionRow = {
  league_round_id: string;
  league_id: string;
  league_round_number: number;
  league_round_status: string;
  league_round_enabled: boolean;
  fantagol_round_id: string;
  round_opens_at: string;
  round_lock_at: string;
  prediction_window_state: string;
  can_edit: boolean;
  seconds_to_lock: number;
  league_member_id: string;
  slot_number: number;
  required: boolean;
  match_id: string;
  kickoff: string | null;
  match_status: string;
  home_score: number | null;
  away_score: number | null;
  home_team_id: string;
  home_team_name: string;
  home_team_short_name: string | null;
  home_team_logo_url: string | null;
  home_team_crest_reference: string | null;
  away_team_id: string;
  away_team_name: string;
  away_team_short_name: string | null;
  away_team_logo_url: string | null;
  away_team_crest_reference: string | null;
  prediction_id: string | null;
  home_prediction: number | null;
  away_prediction: number | null;
  prediction_status: string;
  prediction_version: number | null;
  prediction_submitted_at: string | null;
  prediction_locked_at: string | null;
  prediction_updated_at: string | null;
  filled_prediction_count: number;
  required_prediction_count: number;
  is_complete: boolean;
  has_official_submission: boolean;
  has_unconfirmed_changes: boolean;
  official_home_prediction: number | null;
  official_away_prediction: number | null;
  official_submitted_at: string | null;
};

type RoundView = {
  id: string;
  number: number;
  status: string;
  windowState: string;
  canEdit: boolean;
  opensAt: string;
  lockAt: string;
  isOpen: boolean;
  isLocked: boolean;
  isLive: boolean;
  isFinished: boolean;
  label: string;
  helper: string;
};

type RuleItem = {
  key: string;
  label: string;
  short: string;
  points: string;
  icon: string;
  tone: "green" | "orange" | "red" | "violet" | "muted";
};

const ruleItems: RuleItem[] = [
  { key: "exact", label: "Exact", short: "EX", points: "+6", icon: "◎", tone: "muted" },
  { key: "sign", label: "Segno", short: "1X2", points: "+3", icon: "✓", tone: "green" },
  { key: "uo", label: "Over/Under", short: "U/O", points: "+1", icon: "%", tone: "muted" },
  { key: "gg", label: "Gol/NoGol", short: "G/NG", points: "+1", icon: "▣", tone: "green" },
  { key: "surprise", label: "Sorpresa", short: "SOR", points: "+2", icon: "☆", tone: "orange" },
  { key: "show", label: "Gol Show", short: "SHOW", points: "+1", icon: "✴", tone: "orange" },
  { key: "slam", label: "Grande Slam", short: "SLAM", points: "+1", icon: "◇", tone: "violet" },
  { key: "bad", label: "Cantonata", short: "CAN", points: "-2", icon: "×", tone: "red" },
  { key: "opposite", label: "Segno opposto", short: "OPP", points: "-1", icon: "↔", tone: "red" },
];

function cleanGoal(value: string) {
  if (!/^\d?$/.test(value)) return null;
  return value.slice(0, 1);
}

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
    .replace(/^(?:A\.?\s*C\.?\s*F?\.?|F\.?\s*C\.?|S\.?\s*S\.?\s*C\.?|S\.?\s*S\.?|U\.?\s*S\.?|U\.?\s*C\.?|A\.?\s*S\.?|C\.?\s*F\.?\s*C\.?)\s+/i, "")
    .replace(/\s+(?:Football Club|Calcio|F\.?\s*C\.?|C\.?\s*F\.?\s*C\.?|B\.?\s*C\.?|S\.?\s*C\.?)$/i, "")
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

function buildRoundView(row: RoundPredictionRow): RoundView {
  const isLocked = ["closed", "disabled", "cancelled"].includes(row.prediction_window_state);
  const isLive = ["live", "waiting_postponed", "final_calculable", "scoring"].includes(
    row.league_round_status
  );
  const isFinished = ["official", "recalculated", "archived"].includes(row.league_round_status);

  const label =
    row.prediction_window_state === "open"
      ? "Pronostici aperti"
      : row.prediction_window_state === "not_open"
        ? "Pronostici non ancora aperti"
        : row.prediction_window_state === "cancelled"
          ? "Giornata annullata"
          : row.prediction_window_state === "disabled"
            ? "Giornata disabilitata"
            : "Pronostici chiusi";

  const helper =
    row.prediction_window_state === "open"
      ? "Inserisci o modifica i pronostici fino al lock ufficiale"
      : row.prediction_window_state === "not_open"
        ? "La finestra di inserimento non è ancora iniziata"
        : row.prediction_window_state === "cancelled"
          ? "La giornata non è disponibile"
          : "I pronostici non sono più modificabili";

  return {
    id: row.league_round_id,
    number: row.league_round_number,
    status: row.league_round_status,
    windowState: row.prediction_window_state,
    canEdit: row.can_edit,
    opensAt: row.round_opens_at,
    lockAt: row.round_lock_at,
    isOpen: row.prediction_window_state === "open",
    isLocked,
    isLive,
    isFinished,
    label,
    helper,
  };
}


function RuleIcon({ item, active = false, compact = false }: { item: RuleItem; active?: boolean; compact?: boolean }) {
  const toneClass = active
    ? item.tone === "red"
      ? "border-red-500/70 text-red-400 shadow-[0_0_10px_rgba(239,68,68,0.24)]"
      : item.tone === "orange"
        ? "border-orange-400/80 text-orange-300 shadow-[0_0_10px_rgba(251,146,60,0.24)]"
        : item.tone === "violet"
          ? "border-violet-400/80 text-violet-300 shadow-[0_0_10px_rgba(167,139,250,0.24)]"
          : "border-[#A6E824]/80 text-[#A6E824] shadow-[0_0_10px_rgba(166,232,36,0.24)]"
    : "border-white/10 text-gray-600";

  return (
    <span
      className={`${compact ? "h-[18px] w-[18px] text-[11px] sm:h-6 sm:w-6 sm:text-sm" : "h-7 w-7 text-base sm:h-8 sm:w-8 sm:text-lg"} flex items-center justify-center rounded-full border bg-black/30 font-black ${toneClass}`}
      title={item.label}
    >
      {item.icon}
    </span>
  );
}

function RuleStrip() {
  return (
    <section className="mt-3 rounded-2xl border border-white/10 bg-[#0b1419] p-2 shadow-xl shadow-black/30 sm:mt-4 sm:p-3">
      <div className="mb-2 flex items-center justify-between gap-2 px-1">
        <p className="text-[10px] font-black uppercase tracking-[0.16em] text-white sm:text-sm">Bonus & Malus</p>
        <p className="text-[9px] font-bold uppercase text-gray-500 sm:text-xs">Legenda punteggi</p>
      </div>
      <div className="grid grid-cols-9 gap-1 sm:gap-2">
        {ruleItems.map((item) => (
          <div key={item.key} className="flex min-w-0 flex-col items-center justify-center rounded-xl border border-white/5 bg-black/20 px-0.5 py-1.5 sm:px-2 sm:py-2">
            <RuleIcon item={item} active={item.tone !== "muted" && item.key !== "bad" && item.key !== "opposite"} compact />
            <p className="mt-1 max-w-full truncate text-[7px] font-black uppercase text-gray-300 sm:text-[9px]">{item.short}</p>
            <p className={`text-[9px] font-black sm:text-xs ${item.points.startsWith("-") ? "text-red-400" : item.tone === "orange" ? "text-orange-300" : item.tone === "violet" ? "text-violet-300" : "text-[#A6E824]"}`}>{item.points}</p>
          </div>
        ))}
      </div>
    </section>
  );
}

function getMatchPoints(activeKeys: Set<string>) {
  if (activeKeys.has("bad")) return "-2";
  if (activeKeys.has("exact")) return "11";
  if (activeKeys.has("sign")) return activeKeys.has("uo") || activeKeys.has("gg") ? "5" : "3";
  if (activeKeys.has("uo") || activeKeys.has("gg")) return "1";
  if (activeKeys.has("opposite")) return "-1";
  return "-";
}

export default function GiornataPage() {
  const router = useRouter();
  const params = useParams<{ id: string }>();
  const leagueId = params.id;

  const [menuOpen, setMenuOpen] = useState(false);
  const [modeOpen, setModeOpen] = useState(false);
  const [clubInfo, setClubInfo] = useState<ClubInfo | null>(null);
  const [activeSwipeIndex, setActiveSwipeIndex] = useState(0);
  const swipeStartXRef = useRef<number | null>(null);
  const swipeStartYRef = useRef<number | null>(null);
  const swipeLockRef = useRef<"x" | "y" | null>(null);
  const [swipeDragX, setSwipeDragX] = useState(0);
  const [swipeTransition, setSwipeTransition] = useState(false);
  const [leagueInfo, setLeagueInfo] = useState<LeagueInfo>({
    name: "Lega FantaGol",
    displayName: "Club FantaGol",
    inviteCode: leagueId,
    role: "member",
  });

  const [submitted, setSubmitted] = useState(false);
  const [hasUnconfirmedChanges, setHasUnconfirmedChanges] = useState(false);
  const [submitting, setSubmitting] = useState(false);
  const [submissionModalOpen, setSubmissionModalOpen] = useState(false);
  const [matches, setMatches] = useState<Match[]>([]);
  const [predictions, setPredictions] = useState<Prediction[]>([]);
  const [round, setRound] = useState<RoundView | null>(null);
  const [roundLoading, setRoundLoading] = useState(true);
  const [roundError, setRoundError] = useState<string | null>(null);
  const [predictionSaveStates, setPredictionSaveStates] = useState<PredictionSaveState[]>([]);
  const [predictionSaveErrors, setPredictionSaveErrors] = useState<Array<string | null>>([]);
  const predictionInputRefs = useRef<Array<HTMLInputElement | null>>([]);
  const predictionSaveTimersRef = useRef<Array<number | null>>([]);

  useEffect(() => {
    async function loadLeagueInfo() {
      const { data, error } = await supabase.rpc("get_my_leagues_rpc");
      if (error) return;

      const current = (data || []).find((row: any) => row.league_id === leagueId);
      if (!current) return;

      setLeagueInfo({
        name: current.league_name || "Lega FantaGol",
        displayName: current.display_name || "Club FantaGol",
        inviteCode: current.invite_code || leagueId,
        role: current.role || "member",
      });

      const { data: clubData } = await supabase.rpc("get_my_club_rpc");
      const club = (clubData || [])[0];

      if (club) {
        setClubInfo({
          name: club.name || current.display_name || "Club FantaGol",
          motto: club.motto || null,
          crest_url: club.crest_url || null,
          kit_template: club.kit_template || "solid",
          kit_primary_color: club.kit_primary_color || "#FFFFFF",
          kit_secondary_color: club.kit_secondary_color || "#111417",
          kit_third_color: club.kit_third_color || "#A6E824",
          kit_logo_mode: club.kit_logo_mode || "center_horizontal",
          kit_crest_position: club.kit_crest_position || "left_chest",
          stars_count: club.stars_count || 0,
        });
      }
    }

    loadLeagueInfo();
  }, [leagueId]);

  useEffect(() => {
    let cancelled = false;

    async function loadRoundPredictions() {
      setRoundLoading(true);
      setRoundError(null);

      const { data: currentRoundData, error: currentRoundError } = await supabase.rpc(
        "get_my_current_league_round_rpc",
        { p_league_id: leagueId }
      );

      if (cancelled) return;

      if (currentRoundError) {
        setRoundError(currentRoundError.message);
        setRoundLoading(false);
        return;
      }

      const currentRound = (currentRoundData || [])[0];
      if (!currentRound?.league_round_id) {
        setRoundError("Nessuna giornata disponibile per questa lega.");
        setRoundLoading(false);
        return;
      }

      const { data: predictionData, error: predictionError } = await supabase.rpc(
        "get_my_round_predictions_rpc",
        { p_league_round_id: currentRound.league_round_id }
      );

      if (cancelled) return;

      if (predictionError) {
        setRoundError(predictionError.message);
        setRoundLoading(false);
        return;
      }

      const rows = (predictionData || []) as RoundPredictionRow[];
      if (!rows.length) {
        setRoundError("Il calendario della giornata non contiene partite.");
        setRoundLoading(false);
        return;
      }

      setRound(buildRoundView(rows[0]));
      setMatches(
        rows.map((row) => {
          const kickoff = formatKickoff(row.kickoff);
          const isFinished = ["finished", "awarded"].includes(row.match_status);
          const isLive = row.match_status.startsWith("live_") || [
            "halftime",
            "extra_time",
            "penalties",
          ].includes(row.match_status);

          return {
            id: row.match_id,
            home: cleanTeamDisplayName(row.home_team_name),
            away: cleanTeamDisplayName(row.away_team_name),
            homeCrestReference: row.home_team_crest_reference,
            homeLogoUrl: row.home_team_logo_url,
            awayCrestReference: row.away_team_crest_reference,
            awayLogoUrl: row.away_team_logo_url,
            kickoffDay: kickoff.day,
            kickoffHour: kickoff.hour,
            status: row.match_status,
            liveHome: row.home_score ?? undefined,
            liveAway: row.away_score ?? undefined,
            minute: isFinished ? "FT" : isLive ? "LIVE" : undefined,
            bonusActive: [],
            malusActive: [],
          };
        })
      );
      setPredictions(
        rows.map((row) => ({
          home: row.home_prediction === null ? "" : String(row.home_prediction),
          away: row.away_prediction === null ? "" : String(row.away_prediction),
        }))
      );
      setPredictionSaveStates(rows.map(() => "idle"));
      setPredictionSaveErrors(rows.map(() => null));
      setSubmitted(rows.some((row) => row.has_official_submission));
      setHasUnconfirmedChanges(rows.some((row) => row.has_unconfirmed_changes));
      setRoundLoading(false);
    }

    void loadRoundPredictions();

    return () => {
      cancelled = true;
      predictionSaveTimersRef.current.forEach((timer) => {
        if (timer) window.clearTimeout(timer);
      });
    };
  }, [leagueId]);

  const submittedCount = useMemo(
    () => predictions.filter((prediction) => prediction.home !== "" && prediction.away !== "").length,
    [predictions]
  );

  const allComplete = matches.length > 0 && submittedCount === matches.length;
  const locked = round?.isLocked ?? true;
  const currentPoints = 0;

  const isLiveForSwipe = round?.isLive === true || round?.isFinished === true;
  const swipeProfiles = useMemo(() => [
    {
      id: "me",
      clubName: clubInfo?.name || leagueInfo.displayName || "Club FantaGol",
      motto: clubInfo?.motto || "Il tuo Club FantaGol sta per iniziare la sua storia.",
      avatarUrl: clubInfo?.crest_url || null,
      kitTemplate: clubInfo?.kit_template || "solid",
      kitPrimaryColor: clubInfo?.kit_primary_color || "#FFFFFF",
      kitSecondaryColor: clubInfo?.kit_secondary_color || "#111417",
      kitThirdColor: clubInfo?.kit_third_color || "#A6E824",
      kitLogoMode: clubInfo?.kit_logo_mode || "center_horizontal",
      kitCrestPosition: clubInfo?.kit_crest_position || "left_chest",
      starsCount: clubInfo?.stars_count || 0,
      isCurrentUser: true,
    },
    {
      id: "demo-1",
      clubName: "Real Exact",
      motto: "Precisione, coraggio e pronostici al millimetro.",
      avatarUrl: null,
      kitTemplate: "vertical_3",
      kitPrimaryColor: "#A6E824",
      kitSecondaryColor: "#111417",
      kitThirdColor: "#FFFFFF",
      kitLogoMode: "center_horizontal",
      kitCrestPosition: "left_chest",
      starsCount: 2,
    },
    {
      id: "demo-2",
      clubName: "Bonus Show",
      motto: "Ogni bonus è una dichiarazione di intenti.",
      avatarUrl: null,
      kitTemplate: "diagonal",
      kitPrimaryColor: "#1f2427",
      kitSecondaryColor: "#A6E824",
      kitThirdColor: "#FFFFFF",
      kitLogoMode: "wordmark_only",
      kitCrestPosition: "left_chest",
      starsCount: 1,
    },
  ], [clubInfo, leagueInfo.displayName]);

  const activeProfile = swipeProfiles[Math.min(activeSwipeIndex, swipeProfiles.length - 1)];
  const isFirstProfile = activeSwipeIndex === 0;
  const isLastProfile = activeSwipeIndex === swipeProfiles.length - 1;
  const isViewingSelf = activeProfile?.isCurrentUser === true;
  const viewedClubInfo: ClubInfo = {
    name: activeProfile?.clubName || "Club FantaGol",
    motto: activeProfile?.motto || null,
    crest_url: activeProfile?.avatarUrl || null,
    kit_template: activeProfile?.kitTemplate || "solid",
    kit_primary_color: activeProfile?.kitPrimaryColor || "#FFFFFF",
    kit_secondary_color: activeProfile?.kitSecondaryColor || "#111417",
    kit_third_color: activeProfile?.kitThirdColor || "#A6E824",
    kit_logo_mode: activeProfile?.kitLogoMode || "center_horizontal",
    kit_crest_position: activeProfile?.kitCrestPosition || "left_chest",
    stars_count: activeProfile?.starsCount || 0,
  };
  const canEdit = round?.canEdit === true && isViewingSelf;
  const canViewProfileContent = isViewingSelf || isLiveForSwipe;
  const displayedPredictions = canViewProfileContent
    ? predictions
    : matches.map(() => ({ home: "", away: "" }));
  const displayedCurrentPoints = canViewProfileContent ? currentPoints : 0;

  function completeProfileSwipe(nextIndex: number, direction: "next" | "prev") {
    const bounded = Math.min(Math.max(nextIndex, 0), swipeProfiles.length - 1);
    const viewportWidth = typeof window !== "undefined" ? window.innerWidth : 420;
    const exitX = direction === "next" ? -viewportWidth : viewportWidth;
    const enterX = direction === "next" ? viewportWidth * 0.18 : -viewportWidth * 0.18;

    setSwipeTransition(true);
    setSwipeDragX(exitX);

    window.setTimeout(() => {
      setActiveSwipeIndex(bounded);
      setSwipeTransition(false);
      setSwipeDragX(enterX);

      window.requestAnimationFrame(() => {
        setSwipeTransition(true);
        setSwipeDragX(0);

        window.setTimeout(() => {
          setSwipeTransition(false);
        }, 280);
      });
    }, 170);
  }

  function bounceSwipe() {
    setSwipeTransition(true);
    setSwipeDragX(0);

    window.setTimeout(() => {
      setSwipeTransition(false);
    }, 240);
  }

  function goToProfile(nextIndex: number) {
    const bounded = Math.min(Math.max(nextIndex, 0), swipeProfiles.length - 1);

    if (bounded === activeSwipeIndex) {
      bounceSwipe();
      return;
    }

    completeProfileSwipe(bounded, bounded > activeSwipeIndex ? "next" : "prev");
  }

  function goPrevProfile() {
    if (!isFirstProfile) goToProfile(activeSwipeIndex - 1);
    else bounceSwipe();
  }

  function goNextProfile() {
    if (!isLastProfile) goToProfile(activeSwipeIndex + 1);
    else bounceSwipe();
  }

  function handlePageSwipeStart(event: TouchEvent<HTMLElement>) {
    const target = event.target as HTMLElement;
    if (target.closest("input, textarea, select")) return;

    swipeStartXRef.current = event.touches[0]?.clientX ?? null;
    swipeStartYRef.current = event.touches[0]?.clientY ?? null;
    swipeLockRef.current = null;
    setSwipeTransition(false);
  }

  function handlePageSwipeMove(event: TouchEvent<HTMLElement>) {
    if (swipeStartXRef.current === null || swipeStartYRef.current === null) return;

    const currentX = event.touches[0]?.clientX ?? swipeStartXRef.current;
    const currentY = event.touches[0]?.clientY ?? swipeStartYRef.current;
    const deltaX = currentX - swipeStartXRef.current;
    const deltaY = currentY - swipeStartYRef.current;

    if (!swipeLockRef.current) {
      if (Math.abs(deltaX) < 10 && Math.abs(deltaY) < 10) return;
      swipeLockRef.current = Math.abs(deltaX) > Math.abs(deltaY) * 1.25 ? "x" : "y";
    }

    if (swipeLockRef.current !== "x") return;

    const blockedAtStart = isFirstProfile && deltaX > 0;
    const blockedAtEnd = isLastProfile && deltaX < 0;
    const resistance = blockedAtStart || blockedAtEnd ? 0.22 : 1;

    setSwipeDragX(deltaX * resistance);
  }

  function handlePageSwipeEnd(event: TouchEvent<HTMLElement>) {
    if (swipeStartXRef.current === null) return;

    const endX = event.changedTouches[0]?.clientX ?? swipeStartXRef.current;
    const deltaX = endX - swipeStartXRef.current;
    const threshold = 70;

    swipeStartXRef.current = null;
    swipeStartYRef.current = null;
    swipeLockRef.current = null;

    if (Math.abs(deltaX) < threshold) {
      bounceSwipe();
      return;
    }

    if (deltaX < 0 && !isLastProfile) {
      completeProfileSwipe(activeSwipeIndex + 1, "next");
      return;
    }

    if (deltaX > 0 && !isFirstProfile) {
      completeProfileSwipe(activeSwipeIndex - 1, "prev");
      return;
    }

    bounceSwipe();
  }

  const swipeAbs = Math.min(Math.abs(swipeDragX), 180);
  const swipeScale = 1 - Math.min(swipeAbs / 7000, 0.026);
  const swipeOpacity = 1 - Math.min(swipeAbs / 3600, 0.045);
  const swipeGlowOpacity = Math.min(swipeAbs / 130, 1);
  const swipeNextPreview =
    swipeDragX < -8 && !isLastProfile
      ? swipeProfiles[activeSwipeIndex + 1]
      : swipeDragX > 8 && !isFirstProfile
        ? swipeProfiles[activeSwipeIndex - 1]
        : null;

  function getPredictionInputPosition(index: number, field: keyof Prediction) {
    return index * 2 + (field === "away" ? 1 : 0);
  }

  function focusPredictionInput(position: number) {
    predictionInputRefs.current[position]?.focus();
    predictionInputRefs.current[position]?.select();
  }

  function setPredictionSaveState(
    index: number,
    state: PredictionSaveState,
    errorMessage: string | null = null
  ) {
    setPredictionSaveStates((current) =>
      current.map((value, currentIndex) => (currentIndex === index ? state : value))
    );
    setPredictionSaveErrors((current) =>
      current.map((value, currentIndex) =>
        currentIndex === index ? errorMessage : value
      )
    );
  }

  function schedulePredictionDraftSave(index: number, prediction: Prediction) {
    const match = matches[index];
    if (!round?.id || !match?.id) return;
    if (prediction.home === "" || prediction.away === "") return;

    const previousTimer = predictionSaveTimersRef.current[index];
    if (previousTimer) window.clearTimeout(previousTimer);

    setPredictionSaveState(index, "saving");

    predictionSaveTimersRef.current[index] = window.setTimeout(async () => {
      const { error } = await supabase.rpc("save_prediction_draft_rpc", {
        p_league_round_id: round.id,
        p_match_id: match.id,
        p_home_prediction: Number(prediction.home),
        p_away_prediction: Number(prediction.away),
      });

      if (error) {
        setPredictionSaveState(index, "error", error.message);
        return;
      }

      setPredictionSaveState(index, "saved");

      window.setTimeout(() => {
        setPredictionSaveStates((current) =>
          current.map((value, currentIndex) =>
            currentIndex === index && value === "saved" ? "idle" : value
          )
        );
      }, 1400);
    }, 450);
  }

  function updatePrediction(index: number, field: keyof Prediction, value: string) {
    if (!canEdit) return;

    const previousValue = predictions[index]?.[field] ?? "";
    const nextGoal = cleanGoal(value);
    if (nextGoal === null) return;

    const nextPrediction = {
      ...(predictions[index] ?? { home: "", away: "" }),
      [field]: nextGoal,
    };

    setPredictions((current) =>
      current.map((prediction, currentIndex) =>
        currentIndex === index ? nextPrediction : prediction
      )
    );

    setPredictionSaveState(index, "idle");
    if (submitted && previousValue !== nextGoal) {
      setHasUnconfirmedChanges(true);
    }
    schedulePredictionDraftSave(index, nextPrediction);

    if (previousValue === "" && nextGoal.length === 1) {
      const nextPosition = getPredictionInputPosition(index, field) + 1;
      window.requestAnimationFrame(() => focusPredictionInput(nextPosition));
    }
  }

  function handlePredictionKeyDown(
    event: React.KeyboardEvent<HTMLInputElement>,
    index: number,
    field: keyof Prediction
  ) {
    if (event.key !== "Backspace" || event.currentTarget.value !== "") return;

    const previousPosition = getPredictionInputPosition(index, field) - 1;
    if (previousPosition < 0) return;

    event.preventDefault();
    focusPredictionInput(previousPosition);
  }

  async function submitPredictions() {
    if (locked || submitting || !round?.id) return;

    if (predictionSaveStates.some((state) => state === "saving")) {
      alert("Attendi il completamento del salvataggio dei pronostici.");
      return;
    }

    if (predictionSaveStates.some((state) => state === "error")) {
      alert("Correggi gli errori di salvataggio prima di inviare.");
      return;
    }

    if (!allComplete) {
      alert("Completa tutti i 10 pronostici prima di inviare.");
      return;
    }

    setSubmitting(true);

    const { data, error } = await supabase.rpc("submit_round_predictions_rpc", {
      p_league_round_id: round.id,
    });

    if (error) {
      setSubmitting(false);
      alert(error.message || "Invio dei pronostici non riuscito.");
      return;
    }

    const result = (data || [])[0];

    if (!result || result.submitted_prediction_count !== result.required_prediction_count) {
      setSubmitting(false);
      alert("La conferma dell'invio non è coerente con il numero di pronostici richiesti.");
      return;
    }

    setSubmitted(true);
    setHasUnconfirmedChanges(false);
    setSubmitting(false);
    setSubmissionModalOpen(true);
  }

  return (
    <main
      className="min-h-screen overflow-x-hidden bg-[#061014] text-white"
      onTouchStart={handlePageSwipeStart}
      onTouchMove={handlePageSwipeMove}
      onTouchEnd={handlePageSwipeEnd}
    >

      <HamburgerDrawer
        open={menuOpen}
        leagueName={leagueInfo.name}
        displayName={viewedClubInfo.name}
        inviteCode={leagueInfo.inviteCode}
        role={leagueInfo.role}
        onClose={() => setMenuOpen(false)}
      />

      {!isFirstProfile && (
        <button
          type="button"
          onClick={goPrevProfile}
          className="fixed left-4 top-1/2 z-[90] hidden h-14 w-14 -translate-y-1/2 items-center justify-center rounded-full border border-[#A6E824]/35 bg-black/60 text-4xl font-black text-[#A6E824] shadow-2xl shadow-black/70 transition hover:border-[#A6E824] hover:bg-[#A6E824]/10 md:flex"
          aria-label="Profilo precedente"
        >
          ‹
        </button>
      )}

      {!isLastProfile && (
        <button
          type="button"
          onClick={goNextProfile}
          className="fixed right-4 top-1/2 z-[90] hidden h-14 w-14 -translate-y-1/2 items-center justify-center rounded-full border border-[#A6E824]/35 bg-black/60 text-4xl font-black text-[#A6E824] shadow-2xl shadow-black/70 transition hover:border-[#A6E824] hover:bg-[#A6E824]/10 md:flex"
          aria-label="Profilo successivo"
        >
          ›
        </button>
      )}

      {swipeNextPreview && (
        <div
          className={`pointer-events-none fixed inset-y-0 z-[10] hidden w-[16vw] max-w-[190px] items-center px-3 md:flex ${
            swipeDragX < 0 ? "right-0 justify-end" : "left-0 justify-start"
          }`}
          style={{ opacity: swipeGlowOpacity }}
        >
          <div className="w-full rounded-[2rem] border border-[#A6E824]/25 bg-[#0b1419] p-4 shadow-[0_0_50px_rgba(166,232,36,0.10)]">
            <div className="text-[10px] font-black uppercase tracking-[0.16em] text-[#A6E824]">
              {swipeDragX < 0 ? "Prossimo" : "Precedente"}
            </div>
            <div className="mt-2 truncate text-sm font-black text-white">
              {swipeNextPreview.clubName}
            </div>
          </div>
        </div>
      )}

      <section
        className="mx-auto max-w-6xl px-2 pb-12 pt-2 sm:px-5 sm:pb-16 sm:pt-3"
        style={{
          transform: `translate3d(${swipeDragX}px, 0, 0) scale(${swipeScale})`,
          opacity: swipeOpacity,
          transition: swipeTransition
            ? "transform 260ms cubic-bezier(.22,.61,.36,1), opacity 260ms cubic-bezier(.22,.61,.36,1), filter 260ms cubic-bezier(.22,.61,.36,1)"
            : "none",
          filter: swipeDragX !== 0 ? "drop-shadow(0 28px 70px rgba(0,0,0,0.55))" : "none",
          willChange: "transform, opacity, filter",
        }}
      >
        <header className="grid grid-cols-[1.35fr_1fr_1fr_1fr] gap-2 border-b border-white/10 py-3 sm:gap-3 sm:py-5">
          <div className="rounded-2xl border border-white/10 bg-black/25 p-3">
            <div className="flex h-full items-center gap-2">
              <div className="flex h-8 w-8 shrink-0 items-center justify-center rounded-xl border border-white/10 bg-black/30 text-base">
                🏆
              </div>
              <div className="min-w-0">
                <p className="text-[9px] font-black uppercase text-gray-500 sm:text-xs">Punti</p>
                <div className="flex items-end gap-1">
                  <span className="text-[1.7rem] font-black leading-none text-[#A6E824] sm:text-4xl">
                    {displayedCurrentPoints}
                  </span>
                  <span className="pb-0.5 text-xs font-black text-white sm:text-sm">pt</span>
                </div>
              </div>
            </div>
          </div>

          <div className="rounded-2xl border border-white/10 bg-black/25 p-2">
            <div className="mx-auto flex h-16 w-12 items-center justify-center overflow-hidden rounded-xl bg-[#111417]">
              {viewedClubInfo && (
                <div className="scale-[0.32]">
                  <KitPreview
                    primary={viewedClubInfo.kit_primary_color}
                    secondary={viewedClubInfo.kit_secondary_color}
                    third={viewedClubInfo.kit_third_color}
                    template={viewedClubInfo.kit_template}
                    logoMode={viewedClubInfo.kit_logo_mode}
                    crestPosition={viewedClubInfo.kit_crest_position}
                    starsCount={viewedClubInfo.stars_count}
                  />
                </div>
              )}
            </div>

            <p className="mt-1 truncate text-center text-[9px] font-black text-white sm:text-xs">
              {viewedClubInfo.name}
            </p>
            <p className="mx-auto mt-0.5 line-clamp-2 max-w-[88px] text-center text-[7px] font-semibold leading-3 text-gray-500 sm:max-w-[120px] sm:text-[9px]">
              {viewedClubInfo.motto || "Il tuo Club FantaGol sta per iniziare la sua storia."}
            </p>
          </div>

          <div className="rounded-2xl border border-white/10 bg-black/25 p-3 text-center">
            <div className="flex items-center justify-center gap-2">
              <button className="hidden h-8 w-8 items-center justify-center rounded-xl border border-white/10 bg-black/30 text-xl text-gray-400 sm:flex">
                ‹
              </button>

              <div>
                <p className="text-[9px] font-bold uppercase text-gray-500 sm:text-xs">Giornata</p>
                <p className="text-2xl font-black text-white sm:text-3xl">{round?.number ?? "-"}</p>
              </div>

              <button className="hidden h-8 w-8 items-center justify-center rounded-xl border border-white/10 bg-black/30 text-xl text-gray-400 sm:flex">
                ›
              </button>
            </div>
          </div>

          <button
            type="button"
            onClick={() => router.push("/statistiche")}
            className="rounded-2xl border border-white/10 bg-black/25 p-3 text-center transition hover:border-[#A6E824]/60 hover:bg-white/[0.03]"
          >
            <div className="mx-auto flex h-10 w-14 items-end gap-1 rounded-xl border border-white/10 bg-[#071015] px-2 pb-2 sm:h-12 sm:w-16">
              <span className="h-3 flex-1 rounded-t bg-[#A6E824]/50 sm:h-4" />
              <span className="h-6 flex-1 rounded-t bg-[#A6E824] sm:h-7" />
              <span className="h-4 flex-1 rounded-t bg-[#A6E824]/70 sm:h-5" />
              <span className="h-8 flex-1 rounded-t bg-[#A6E824]/90 sm:h-9" />
            </div>

            <p className="mt-1 text-[9px] font-black uppercase text-gray-500 sm:text-xs">
              Statistiche
            </p>
          </button>
        </header>

        <section className="relative z-30 mt-3 grid overflow-visible rounded-2xl border border-white/10 bg-[#0b1419] shadow-xl shadow-black/30 sm:mt-4 md:grid-cols-[1.5fr_1fr]">
          <div className="flex items-center gap-3 border-b border-white/10 p-3 sm:gap-4 sm:p-4 md:border-b-0 md:border-r">
            <div
              className={`relative flex h-12 w-12 shrink-0 items-center justify-center rounded-full border text-2xl shadow-[0_0_28px_rgba(166,232,36,0.18)] sm:h-16 sm:w-16 sm:text-3xl ${
                locked
                  ? "border-gray-500/40 bg-gray-500/10 text-gray-400 shadow-[0_0_22px_rgba(156,163,175,0.10)]"
                  : "border-[#A6E824]/40 bg-[#A6E824]/20 text-[#A6E824]"
              }`}
            >
              <span>✎</span>
              {locked && (
                <span className="absolute -bottom-1 -right-1 flex h-6 w-6 items-center justify-center rounded-full border border-gray-500/40 bg-[#071015] text-[13px] shadow-lg sm:h-7 sm:w-7 sm:text-sm">
                  🔒
                </span>
              )}
            </div>
            <div>
              <p className="text-sm font-black uppercase sm:text-lg">
                {locked ? round?.label : submitted ? "Pronostici inviati" : round?.label}
              </p>
              <p className="text-xs text-gray-300 sm:text-sm">
                {locked ? round?.helper : submitted ? "Puoi modificare e reinviare fino al lock ufficiale" : round?.helper}
              </p>
            </div>
          </div>
          <div className="relative p-3 sm:p-4">
            <button
              type="button"
              onClick={() => setModeOpen((current) => !current)}
              className="flex w-full items-center justify-between rounded-2xl border border-white/10 bg-black/20 px-3 py-3 text-left transition hover:border-[#A6E824]/50"
            >
              <div>
                <p className="text-[10px] font-bold uppercase tracking-[0.16em] text-gray-500 sm:text-xs">Modalità</p>
                <p className="text-base font-black uppercase sm:text-lg">Punti Puri</p>
              </div>
              <span className="text-2xl text-white sm:text-3xl">⌄</span>
            </button>

            {modeOpen && (
              <div className="absolute left-3 right-3 top-[calc(100%-10px)] z-50 overflow-hidden rounded-2xl border border-white/10 bg-[#10181d] shadow-2xl shadow-black/80">
                <button
                  type="button"
                  onClick={() => router.push(`/leghe/${leagueId}/fantacalcio`)}
                  className="flex w-full items-center justify-between px-4 py-3 text-left transition hover:bg-white/5"
                >
                  <span>
                    <span className="block text-sm font-black uppercase text-white sm:text-base">Modalità Fantacalcio</span>
                    <span className="block text-[11px] font-semibold text-gray-500">Vai al duello live</span>
                  </span>
                  <span className="text-xl">🏆</span>
                </button>

                <button
                  type="button"
                  onClick={() => router.push(`/leghe/${leagueId}/onetoone`)}
                  className="flex w-full items-center justify-between border-t border-white/10 px-4 py-3 text-left transition hover:bg-white/5"
                >
                  <span>
                    <span className="block text-sm font-black uppercase text-white sm:text-base">Modalità One To One</span>
                    <span className="block text-[11px] font-semibold text-gray-500">Vai alla sfida diretta</span>
                  </span>
                  <span className="text-xl">⚔️</span>
                </button>
              </div>
            )}
          </div>
        </section>

        <RuleStrip />

        <section className="mt-3 overflow-hidden rounded-2xl border border-white/10 bg-[#0b1419] shadow-2xl shadow-black/40 sm:mt-4">
          <div className="grid grid-cols-[35%_17%_14%_9%_25%] items-center gap-0 border-b border-white/10 px-1 py-2 text-center text-[8px] font-black uppercase tracking-tight text-gray-500 sm:grid-cols-[1.65fr_150px_150px_100px_190px] sm:px-4 sm:py-3 sm:text-[11px] sm:tracking-wide">
            <span>Partita</span>
            <span className="text-[#A6E824]">Pron.</span>
            <span>Ris.</span>
            <span className="text-[#A6E824]">Pt</span>
            <span>Bonus</span>
          </div>

          {roundLoading && (
            <div className="px-4 py-10 text-center text-sm font-bold text-gray-400">
              Caricamento della giornata...
            </div>
          )}

          {!roundLoading && roundError && (
            <div className="px-4 py-10 text-center">
              <p className="text-sm font-black text-red-300">Impossibile caricare la giornata</p>
              <p className="mt-2 text-xs text-gray-500">{roundError}</p>
            </div>
          )}

          {!roundLoading && !roundError && matches.map((match, index) => {
            const prediction = displayedPredictions[index];
            const activeKeys = new Set([...(match.bonusActive ?? []), ...(match.malusActive ?? [])]);
            const showLiveScore = round?.isLive === true || round?.isFinished === true;

            return (
              <article key={match.id} className="border-b border-white/10 px-1 py-2 last:border-b-0 sm:px-4 sm:py-3">
                <div className="grid grid-cols-[35%_17%_14%_9%_25%] items-center gap-0 sm:grid-cols-[1.65fr_150px_150px_100px_190px] sm:gap-3">
                  <div className="min-w-0 pr-1 sm:pr-0">
                    <div className="flex min-w-0 items-center gap-1 sm:gap-2">
                      <TeamCrest
                        crestReference={match.homeCrestReference}
                        logoUrl={match.homeLogoUrl}
                        alt={`${match.home} stemma`}
                        fallbackLabel={match.home}
                        size="xs"
                        className="sm:h-8 sm:w-8 lg:h-11 lg:w-11"
                      />
                      <p className="min-w-0 truncate text-[10px] font-black leading-tight sm:text-base lg:text-lg">{match.home}</p>
                    </div>
                    <div className="my-0.5 pl-6 text-[7px] font-bold uppercase leading-none text-gray-500 sm:my-1 sm:pl-10 sm:text-[10px]">
                      {match.kickoffDay} · {match.kickoffHour}
                      {predictionSaveStates[index] === "error" && (
                        <span
                          className="ml-1 text-red-400"
                          title={predictionSaveErrors[index] ?? "Errore di salvataggio"}
                        >
                          • errore
                        </span>
                      )}
                    </div>
                    <div className="flex min-w-0 items-center gap-1 sm:gap-2">
                      <TeamCrest
                        crestReference={match.awayCrestReference}
                        logoUrl={match.awayLogoUrl}
                        alt={`${match.away} stemma`}
                        fallbackLabel={match.away}
                        size="xs"
                        className="sm:h-8 sm:w-8 lg:h-11 lg:w-11"
                      />
                      <p className="min-w-0 truncate text-[10px] font-black leading-tight sm:text-base lg:text-lg">{match.away}</p>
                    </div>
                  </div>

                  <div className="flex items-center justify-center gap-0.5 sm:gap-2">
                    <input
                      ref={(element) => {
                        predictionInputRefs.current[getPredictionInputPosition(index, "home")] = element;
                      }}
                      value={prediction.home}
                      disabled={!canEdit}
                      inputMode="numeric"
                      maxLength={1}
                      onChange={(event) => updatePrediction(index, "home", event.target.value)}
                      onFocus={(event) => event.currentTarget.select()}
                      onClick={(event) => event.currentTarget.select()}
                      onKeyDown={(event) => handlePredictionKeyDown(event, index, "home")}
                      className="h-8 w-5 rounded-md border border-white/15 bg-black/35 text-center text-[12px] font-black outline-none focus:border-[#A6E824] disabled:opacity-80 sm:h-11 sm:w-14 sm:rounded-lg sm:text-lg"
                      placeholder="-"
                    />
                    <span className="text-[10px] font-black text-gray-500 sm:text-base">-</span>
                    <input
                      ref={(element) => {
                        predictionInputRefs.current[getPredictionInputPosition(index, "away")] = element;
                      }}
                      value={prediction.away}
                      disabled={!canEdit}
                      inputMode="numeric"
                      maxLength={1}
                      onChange={(event) => updatePrediction(index, "away", event.target.value)}
                      onFocus={(event) => event.currentTarget.select()}
                      onClick={(event) => event.currentTarget.select()}
                      onKeyDown={(event) => handlePredictionKeyDown(event, index, "away")}
                      className="h-8 w-5 rounded-md border border-white/15 bg-black/35 text-center text-[12px] font-black outline-none focus:border-[#A6E824] disabled:opacity-80 sm:h-11 sm:w-14 sm:rounded-lg sm:text-lg"
                      placeholder="-"
                    />
                  </div>

                  <div className="flex items-center justify-center">
                    {showLiveScore ? (
                      <div className="flex w-full max-w-[42px] flex-col items-center rounded-lg border border-white/10 bg-black/30 px-0.5 py-1 sm:max-w-[120px] sm:rounded-xl sm:px-3 sm:py-2">
                        <span className="text-[7px] font-bold uppercase leading-none text-[#A6E824] sm:text-[10px]">{match.minute ?? "FT"}</span>
                        <span className="mt-0.5 text-[12px] font-black leading-none sm:text-xl">{match.liveHome ?? 0}-{match.liveAway ?? 0}</span>
                      </div>
                    ) : (
                      <span className="text-lg font-black text-gray-500 sm:text-2xl">-</span>
                    )}
                  </div>

                  <div className="text-center text-[13px] font-black leading-none text-white sm:text-2xl">
                    {showLiveScore && activeKeys.size ? getMatchPoints(activeKeys) : "-"}
                  </div>

                  <div className="grid grid-cols-3 justify-items-center gap-0.5 sm:flex sm:flex-wrap sm:justify-center sm:gap-1.5">
                    {ruleItems.map((item) => (
                      <RuleIcon key={item.key} item={item} active={activeKeys.has(item.key)} compact />
                    ))}
                  </div>
                </div>
              </article>
            );
          })}
        </section>

        <section className="mt-5 flex justify-center">
          <RoundSubmissionButton
            locked={locked}
            isViewingSelf={isViewingSelf}
            hasOfficialSubmission={submitted}
            hasUnconfirmedChanges={hasUnconfirmedChanges}
            submitting={submitting}
            disabled={roundLoading || !!roundError}
            onClick={submitPredictions}
          />
        </section>
      </section>

    
      <SubmissionModal
        open={submissionModalOpen}
        title="Pronostici inviati"
        description={"Puoi passare alle modalità Fantacalcio e One To One\nper pianificare le tue sfide."}
        primaryLabel="Vai a Fantacalcio"
        secondaryLabel="Vai a One To One"
        onPrimary={() => router.push(`/leghe/${leagueId}/fantacalcio`)}
        onSecondary={() => router.push(`/leghe/${leagueId}/onetoone`)}
        onClose={() => setSubmissionModalOpen(false)}
      />
</main>
  );
}
