"use client";

/* eslint-disable @next/next/no-img-element -- Dynamic external assets intentionally preserve the current crop, fallback, and sizing contracts. */
import { useEffect, useMemo, useRef, useState, type TouchEvent } from "react";
import { useParams, useRouter } from "next/navigation";
import HamburgerDrawer from "../../../../components/app/HamburgerDrawer";
import SubmissionModal from "../../../../components/app/SubmissionModal";
import RoundSubmissionButton from "../../../../components/app/RoundSubmissionButton";
import TeamCrest from "../../../../components/app/TeamCrest";
import KitPreview from "../../../../components/club/KitPreview";
import { supabase } from "../../../../lib/supabaseClient";
import {
  fromFantacalcioStrategyPayload,
  toFantacalcioStrategyPayload,
} from "../../../../lib/domain/strategy";

type Side = "left" | "right";

type RoundPredictionRow = {
  league_round_id: string;
  round_number: number | null;
  slot_number: number;
  kickoff: string;
  match_id: string;
  match_status: string;
  home_prediction: number | null;
  away_prediction: number | null;
  home_score: number | null;
  away_score: number | null;
  home_team_name: string;
  home_team_short_name: string | null;
  home_team_logo_url: string | null;
  home_team_crest_reference: string | null;
  away_team_name: string;
  away_team_short_name: string | null;
  away_team_logo_url: string | null;
  away_team_crest_reference: string | null;
};

type StrategyStatusRow = {
  league_fixture_id: string;
  is_bye: boolean;
  strategy_exists: boolean;
  strategy_status: string | null;
  workspace_payload: unknown;
  submitted_version: number | null;
  has_official_snapshot: boolean;
  has_unconfirmed_changes: boolean;
  is_editable: boolean;
  is_submittable: boolean;
  is_locked: boolean;
};

type LeagueInfo = {
  name: string;
  displayName: string;
  inviteCode: string;
  role: string;
};

type MyLeagueRpcRow = {
  league_id: string;
  league_name: string | null;
  display_name: string | null;
  invite_code: string | null;
  role: string | null;
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

type RuleItem = {
  key: string;
  label: string;
  short: string;
  points: string;
  icon: string;
  tone: "green" | "orange" | "red" | "violet" | "muted";
};

type DuelMatch = {
  id: string;
  slotNumber: number;
  home: string;
  away: string;
  homeBadge: string;
  awayBadge: string;
  homeCrestReference: string | null;
  homeLogoUrl: string | null;
  awayCrestReference: string | null;
  awayLogoUrl: string | null;
  minute: string;
  liveHome: number;
  liveAway: number;
  leftPrediction: string;
  rightPrediction: string;
  leftActive: string[];
  rightActive: string[];
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

function TeamBadge({
  label,
  crestReference,
  logoUrl,
  large = false,
}: {
  label: string;
  crestReference?: string | null;
  logoUrl?: string | null;
  large?: boolean;
}) {
  return (
    <span
      className={`${large ? "h-10 w-10 sm:h-16 sm:w-16" : "h-7 w-7 sm:h-10 sm:w-10"} flex shrink-0 items-center justify-center overflow-hidden rounded-full border border-white/10 bg-[#11181d] shadow-inner shadow-white/10`}
    >
      <TeamCrest
        crestReference={crestReference}
        logoUrl={logoUrl}
        alt={`${label} stemma`}
        fallbackLabel={label}
      />
    </span>
  );
}

function Avatar({
  name,
  avatarUrl,
  disabled = false,
}: {
  name: string;
  avatarUrl?: string | null;
  disabled?: boolean;
}) {
  return (
    <div
      className={`flex h-12 w-12 min-[380px]:h-[52px] min-[380px]:w-[52px] shrink-0 items-center justify-center overflow-hidden rounded-full border bg-gradient-to-br from-white to-gray-300 text-xl font-black text-black shadow-xl shadow-black/40 sm:h-20 sm:w-20 sm:text-3xl ${
        disabled
          ? "border-white/5 grayscale opacity-30 saturate-0"
          : "border-white/15"
      }`}
    >
      {avatarUrl ? (
        <img
          src={avatarUrl}
          alt={name}
          className="h-full w-full object-cover"
        />
      ) : (
        name.slice(0, 1).toUpperCase()
      )}
    </div>
  );
}

function ClubKitMini({
  club,
  align = "left",
}: {
  club: ClubInfo | null;
  align?: "left" | "right";
}) {
  const name = club?.name || (align === "right" ? "Avversario" : "Club FantaGol");
  const motto = club?.motto || "Il tuo Club FantaGol sta per iniziare la sua storia.";

  return (
    <div className={`flex min-w-0 items-center gap-3 ${align === "right" ? "flex-row-reverse text-right" : "text-left"}`}>
      <div className="flex h-20 w-14 shrink-0 items-center justify-center overflow-hidden rounded-xl bg-[#111417] sm:h-24 sm:w-16">
        <div className="scale-[0.38]">
          <KitPreview
            primary={club?.kit_primary_color || "#FFFFFF"}
            secondary={club?.kit_secondary_color || "#A6E824"}
            third={club?.kit_third_color || "#FFFFFF"}
            template={club?.kit_template || "solid"}
            logoMode={club?.kit_logo_mode || "center_horizontal"}
            crestPosition={club?.kit_crest_position || "left_chest"}
            starsCount={club?.stars_count || 0}
          />
        </div>
      </div>

      <div className="min-w-0">
        <p className="truncate text-sm font-black text-white sm:text-base">
          {name}
        </p>
        <p className="mt-1 line-clamp-2 text-[10px] font-semibold leading-4 text-gray-500 sm:text-xs">
          {motto}
        </p>
      </div>
    </div>
  );
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
        <p className="text-[10px] font-black uppercase tracking-[0.12em] text-white sm:text-sm">Bonus/Malus</p>
        <p className="hidden text-[9px] font-bold uppercase text-gray-500 sm:block sm:text-xs">Legenda punteggi</p>
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

function PredictionSide({ score, active, side }: { score: string; active: string[]; side: Side }) {
  const activeKeys = new Set(active);
  return (
    <div className={`flex min-w-0 flex-col items-center ${side === "left" ? "sm:items-start" : "sm:items-end"}`}>
      <p className="text-lg font-black leading-none text-white sm:text-3xl">{score}</p>
      <div className="mt-1 grid grid-cols-5 gap-0.5 sm:mt-3 sm:flex sm:gap-1.5">
        {ruleItems.slice(0, 5).map((item) => (
          <RuleIcon key={item.key} item={item} active={activeKeys.has(item.key)} compact />
        ))}
      </div>
      <div className="mt-0.5 grid grid-cols-4 gap-0.5 sm:mt-1 sm:flex sm:gap-1.5">
        {ruleItems.slice(5).map((item) => (
          <RuleIcon key={item.key} item={item} active={activeKeys.has(item.key)} compact />
        ))}
      </div>
    </div>
  );
}

function LiveMatchCenter({ match }: { match: DuelMatch }) {
  return (
    <div className="grid min-w-0 grid-cols-[1fr_56px_1fr] items-center gap-1.5 sm:grid-cols-[1fr_110px_1fr] sm:gap-4">
      <div className="flex min-w-0 flex-col items-center gap-1">
        <TeamBadge
          label={match.homeBadge}
          crestReference={match.homeCrestReference}
          logoUrl={match.homeLogoUrl}
          large
        />
      </div>
      <div className="flex min-w-0 flex-col items-center">
        <span className="rounded-md bg-[#A6E824]/15 px-1.5 py-0.5 text-[9px] font-black leading-none text-[#A6E824] sm:text-xs">{match.minute}</span>
        <div className="mt-1 flex items-center justify-center gap-1 sm:gap-2">
          <span className="text-3xl font-black leading-none text-[#A6E824] sm:text-5xl">{match.liveHome}</span>
          <span className="text-2xl font-black leading-none text-[#A6E824] sm:text-4xl">-</span>
          <span className="text-3xl font-black leading-none text-white sm:text-5xl">{match.liveAway}</span>
        </div>

        <div className="mt-2 grid w-full grid-cols-[1fr_auto_1fr] items-center text-center">
          <span className="text-lg font-black leading-none text-[#A6E824] sm:text-2xl">
            0
          </span>

          <span className="text-[10px] font-black uppercase tracking-[0.18em] text-gray-500 sm:text-xs">
            PT
          </span>

          <span className="text-lg font-black leading-none text-white sm:text-2xl">
            0
          </span>
        </div>
      </div>
      <div className="flex min-w-0 flex-col items-center gap-1">
        <TeamBadge
          label={match.awayBadge}
          crestReference={match.awayCrestReference}
          logoUrl={match.awayLogoUrl}
          large
        />
      </div>
    </div>
  );
}

function cleanTeamDisplayName(name: string): string {
  return name
    .replace(/\b(FC|AC|AS|SS|US|BC|CFC)\b/gi, "")
    .replace(/\bCalcio\b/gi, "")
    .replace(/\s{2,}/g, " ")
    .trim();
}

function getTeamBadge(name: string): string {
  return name
    .split(/\s+/)
    .filter(Boolean)
    .slice(0, 3)
    .map((part) => part[0]?.toUpperCase() || "")
    .join("");
}


export default function FantacalcioLivePage() {
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
  const [opponentClubInfo, setOpponentClubInfo] = useState<ClubInfo | null>(null);
  const [leagueRoundId, setLeagueRoundId] = useState<string | null>(null);
  const [roundNumber, setRoundNumber] = useState<number | null>(null);
  const [strategyExists, setStrategyExists] = useState(false);
  const [hasOfficialSubmission, setHasOfficialSubmission] = useState(false);
  const [hasUnconfirmedChanges, setHasUnconfirmedChanges] = useState(false);
  const [strategyLocked, setStrategyLocked] = useState(false);
  const [isByeRound, setIsByeRound] = useState(false);
  const [strategyLoading, setStrategyLoading] = useState(true);
  const [strategyError, setStrategyError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const [savingStrategy, setSavingStrategy] = useState(false);
  const [leagueInfo, setLeagueInfo] = useState<LeagueInfo>({
    name: "Lega FantaGol",
    displayName: "Club FantaGol",
    inviteCode: leagueId,
    role: "member",
  });
  const [liveRows, setLiveRows] = useState<DuelMatch[]>([]);


  useEffect(() => {
    async function loadLeagueInfo() {
      const { data, error } = await supabase.rpc("get_my_leagues_rpc");
      if (error) return;

      const current = ((data || []) as MyLeagueRpcRow[]).find((row) => row.league_id === leagueId);
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
        const currentClub = {
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
        };

        setClubInfo(currentClub);

        setOpponentClubInfo(null);
      }
    }

    loadLeagueInfo();
  }, [leagueId]);

  useEffect(() => {
    let cancelled = false;

    async function loadFantacalcioStrategy() {
      setStrategyLoading(true);
      setStrategyError(null);

      const { data: roundData, error: roundError } = await supabase.rpc(
        "get_my_current_league_round_rpc",
        { p_league_id: leagueId }
      );

      if (cancelled) return;

      if (roundError) {
        setStrategyError(roundError.message);
        setStrategyLoading(false);
        return;
      }

      const currentRound = (roundData || [])[0];
      if (!currentRound?.league_round_id) {
        setStrategyError("Nessuna giornata disponibile per questa lega.");
        setStrategyLoading(false);
        return;
      }

      const currentLeagueRoundId = currentRound.league_round_id as string;

      const [{ data: predictionData, error: predictionError }, { data: strategyData, error: strategyStatusError }] =
        await Promise.all([
          supabase.rpc("get_my_round_predictions_rpc", {
            p_league_round_id: currentLeagueRoundId,
          }),
          supabase.rpc("get_my_strategy_status_rpc", {
            p_league_round_id: currentLeagueRoundId,
            p_mode: "fantacalcio",
          }),
        ]);

      if (cancelled) return;

      if (predictionError) {
        setStrategyError(predictionError.message);
        setStrategyLoading(false);
        return;
      }

      if (strategyStatusError) {
        setStrategyError(strategyStatusError.message);
        setStrategyLoading(false);
        return;
      }

      const rows = (predictionData || []) as RoundPredictionRow[];
      if (rows.length !== 10) {
        setStrategyError("La giornata Fantacalcio deve contenere esattamente 10 partite.");
        setStrategyLoading(false);
        return;
      }

      const baseRows: DuelMatch[] = [...rows]
        .sort((left, right) => left.slot_number - right.slot_number)
        .map((row) => {
          const isFinished = ["finished", "awarded"].includes(row.match_status);
          const isLive =
            row.match_status.startsWith("live_") ||
            ["halftime", "extra_time", "penalties"].includes(row.match_status);

          const homeName = cleanTeamDisplayName(
            row.home_team_short_name || row.home_team_name
          );
          const awayName = cleanTeamDisplayName(
            row.away_team_short_name || row.away_team_name
          );

          return {
            id: row.match_id,
            slotNumber: row.slot_number,
            home: homeName,
            away: awayName,
            homeBadge: getTeamBadge(homeName),
            awayBadge: getTeamBadge(awayName),
            homeCrestReference: row.home_team_crest_reference,
            homeLogoUrl: row.home_team_logo_url,
            awayCrestReference: row.away_team_crest_reference,
            awayLogoUrl: row.away_team_logo_url,
            minute: isFinished ? "FT" : isLive ? "LIVE" : "—",
            liveHome: row.home_score ?? 0,
            liveAway: row.away_score ?? 0,
            leftPrediction:
              row.home_prediction === null || row.away_prediction === null
                ? "—"
                : `${row.home_prediction}-${row.away_prediction}`,
            rightPrediction: "—",
            leftActive: [],
            rightActive: [],
          };
        });

      const strategyStatus = ((strategyData || [])[0] || null) as StrategyStatusRow | null;
      let orderedRows = baseRows;

      if (strategyStatus?.workspace_payload) {
        try {
          const restored = fromFantacalcioStrategyPayload(
            strategyStatus.workspace_payload
          );
          const byId = new Map(baseRows.map((match) => [match.id, match]));
          const orderedIds = [
            ...restored.attackMatchIds,
            ...restored.defenseMatchIds,
          ];
          const restoredRows = orderedIds
            .map((matchId) => byId.get(matchId))
            .filter((match): match is DuelMatch => Boolean(match));

          if (restoredRows.length === 10) {
            orderedRows = restoredRows;
          }
        } catch {
          setStrategyError("La strategia salvata non è compatibile con il formato corrente.");
        }
      }

      setLeagueRoundId(currentLeagueRoundId);
      setRoundNumber(rows[0]?.round_number ?? null);
      setIsByeRound(Boolean(strategyStatus?.is_bye));
      setLiveRows(orderedRows);
      setStrategyExists(Boolean(strategyStatus?.strategy_exists));
      setHasOfficialSubmission(Boolean(strategyStatus?.has_official_snapshot));
      setHasUnconfirmedChanges(Boolean(strategyStatus?.has_unconfirmed_changes));
      setStrategyLocked(Boolean(strategyStatus?.is_locked));
      setStrategyLoading(false);
    }

    void loadFantacalcioStrategy();

    return () => {
      cancelled = true;
    };
  }, [leagueId]);


  const leftPoints = 72;
  const rightPoints = 65;
  const leftGoals = 5;
  const rightGoals = 4;

  const locked = strategyLocked;
  const interactionLocked = strategyLocked || isByeRound;
  const isLiveForSwipe = strategyLocked && !isByeRound;
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
  const canViewProfileContent = isViewingSelf || isLiveForSwipe;
  const displayedLeftPoints = canViewProfileContent ? leftPoints : 0;
  const displayedRightPoints = canViewProfileContent ? rightPoints : 0;
  const displayedLeftGoals = canViewProfileContent ? leftGoals : 0;
  const displayedRightGoals = canViewProfileContent ? rightGoals : 0;

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

  const [selectedMatchIndex, setSelectedMatchIndex] = useState<number | null>(null);
  const [submissionModalOpen, setSubmissionModalOpen] = useState(false);
  const displayedLiveRows = canViewProfileContent
    ? liveRows
    : liveRows.map((match) => ({
        ...match,
        leftPrediction: "—",
        rightPrediction: "—",
        leftActive: [],
        rightActive: [],
      }));

  async function persistStrategy(nextRows: DuelMatch[]) {
    if (isByeRound || !leagueRoundId || nextRows.length !== 10) return;

    const payload = toFantacalcioStrategyPayload({
      attackMatchIds: nextRows.slice(0, 5).map((match) => match.id),
      defenseMatchIds: nextRows.slice(5, 10).map((match) => match.id),
    });

    setSavingStrategy(true);
    const { data, error } = await supabase.rpc("save_strategy_draft_rpc", {
      p_league_round_id: leagueRoundId,
      p_mode: "fantacalcio",
      p_payload: payload,
    });
    setSavingStrategy(false);

    if (error) {
      setStrategyError(error.message || "Salvataggio della strategia non riuscito.");
      return;
    }

    const result = (data || [])[0];
    setStrategyExists(true);
    setHasOfficialSubmission(Boolean(result?.submitted_version));
    setHasUnconfirmedChanges(Boolean(result?.has_unconfirmed_changes));
    setStrategyError(null);
  }

  function handleSwapMatch(index: number) {
    if (interactionLocked || strategyLoading || savingStrategy) return;

    if (selectedMatchIndex === null) {
      setSelectedMatchIndex(index);
      return;
    }

    if (selectedMatchIndex === index) {
      setSelectedMatchIndex(null);
      return;
    }

    const firstGroup = selectedMatchIndex < 5 ? "attacco" : "difesa";
    const secondGroup = index < 5 ? "attacco" : "difesa";

    if (firstGroup === secondGroup) {
      setSelectedMatchIndex(index);
      return;
    }

    const next = [...liveRows];
    [next[selectedMatchIndex], next[index]] = [
      next[index],
      next[selectedMatchIndex],
    ];

    setLiveRows(next);
    setSelectedMatchIndex(null);
    void persistStrategy(next);
  }

  async function submitStrategy() {
    if (
      interactionLocked ||
      submitting ||
      strategyLoading ||
      savingStrategy ||
      !isViewingSelf ||
      !leagueRoundId ||
      liveRows.length !== 10 ||
      (hasOfficialSubmission && !hasUnconfirmedChanges)
    ) {
      return;
    }

    setSubmitting(true);

    if (!strategyExists) {
      const payload = toFantacalcioStrategyPayload({
        attackMatchIds: liveRows.slice(0, 5).map((match) => match.id),
        defenseMatchIds: liveRows.slice(5, 10).map((match) => match.id),
      });

      const { error: saveError } = await supabase.rpc(
        "save_strategy_draft_rpc",
        {
          p_league_round_id: leagueRoundId,
          p_mode: "fantacalcio",
          p_payload: payload,
        }
      );

      if (saveError) {
        setSubmitting(false);
        alert(saveError.message || "Salvataggio della strategia non riuscito.");
        return;
      }

      setStrategyExists(true);
    }

    const { data, error } = await supabase.rpc("submit_strategy_rpc", {
      p_league_round_id: leagueRoundId,
      p_mode: "fantacalcio",
    });

    setSubmitting(false);

    if (error) {
      alert(error.message || "Invio della strategia Fantacalcio non riuscito.");
      return;
    }

    const result = (data || [])[0];
    if (!result?.submitted_version) {
      alert("La conferma della strategia non è coerente.");
      return;
    }

    setHasOfficialSubmission(true);
    setHasUnconfirmedChanges(false);
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
        <header className="grid w-full min-w-0 grid-cols-[minmax(0,1fr)_54px_66px] gap-1.5 border-b border-white/10 py-3 sm:grid-cols-[minmax(0,1fr)_120px_120px] sm:gap-3 sm:py-5">
          <section className="min-w-0 overflow-hidden rounded-2xl border border-white/10 bg-[#0b1419] p-2 shadow-2xl shadow-black/40 sm:p-3">
            <div className="grid min-w-0 grid-cols-[auto_minmax(0,1fr)_auto] items-center gap-1 sm:grid-cols-[84px_minmax(104px,1fr)_84px] sm:gap-3">
              <div className="flex shrink-0 flex-col items-center">
                <Avatar name={viewedClubInfo.name} avatarUrl={viewedClubInfo.crest_url} />
                <p className="mt-1 max-w-[54px] truncate text-[9px] font-black uppercase leading-none text-white sm:max-w-[72px] sm:text-[10px]">
                  {viewedClubInfo.name}
                </p>
              </div>

              <div className="flex min-w-0 flex-col items-center justify-center px-0.5 sm:min-w-[104px] sm:px-2">
                <div className="relative flex w-full items-end justify-between text-center">
                  <span className="min-w-[18px] text-base font-black leading-none text-[#A6E824] sm:min-w-[24px] sm:text-xl">
                    {displayedLeftPoints}
                  </span>

                  <span className="absolute bottom-0 left-1/2 -translate-x-1/2 pb-0.5 text-[9px] font-black uppercase tracking-[0.16em] text-gray-500 sm:text-xs">
                    PT
                  </span>

                  <span className="min-w-[18px] text-base font-black leading-none text-[#A6E824] sm:min-w-[24px] sm:text-xl">
                    {displayedRightPoints}
                  </span>
                </div>

                <span className="my-1.5 flex h-6 w-6 shrink-0 items-center justify-center rounded-full border border-[#A6E824]/40 bg-black/40 text-[9px] font-black text-white sm:my-2 sm:h-8 sm:w-8 sm:text-[10px]">
                  VS
                </span>

                <div className="flex min-w-0 items-center justify-center gap-1 sm:min-w-[94px] sm:gap-2">
                  <span className="text-3xl font-black leading-none text-[#A6E824] sm:text-4xl">
                    {displayedLeftGoals}
                  </span>
                  <span className="text-2xl font-black leading-none text-white sm:text-3xl">
                    -
                  </span>
                  <span className="text-3xl font-black leading-none text-white sm:text-4xl">
                    {displayedRightGoals}
                  </span>
                </div>
              </div>

              <div className="flex min-w-0 flex-col items-center justify-self-center">
                <Avatar
                  name={isByeRound ? "Riposo" : opponentClubInfo?.name || "Avversario"}
                  avatarUrl={isByeRound ? null : opponentClubInfo?.crest_url}
                  disabled={isByeRound}
                />
                <p className={`mt-1 max-w-[54px] truncate text-[9px] font-black uppercase leading-none sm:max-w-[72px] sm:text-[10px] ${
                  isByeRound ? "text-gray-600" : "text-white"
                }`}>
                  {isByeRound ? "Riposo" : opponentClubInfo?.name || "Avversario"}
                </p>
              </div>
            </div>
          </section>

          <div className="rounded-2xl border border-white/10 bg-black/25 p-2 text-center sm:p-3">
            <div className="flex h-full flex-col items-center justify-center">
              <p className="text-[8px] font-bold uppercase tracking-[-0.02em] text-gray-500 sm:text-xs">Giornata</p>
              <p className="text-2xl font-black text-white sm:text-3xl">{roundNumber ?? "—"}</p>
            </div>
          </div>

          <button
            type="button"
            onClick={() => router.push("/statistiche")}
            className="min-w-0 overflow-hidden rounded-2xl border border-white/10 bg-black/25 p-1.5 text-center transition hover:border-[#A6E824]/60 hover:bg-white/[0.03] sm:p-3"
          >
            <div className="mx-auto flex h-9 w-11 items-end gap-0.5 rounded-xl border border-white/10 bg-[#071015] px-1.5 pb-1.5 sm:h-12 sm:w-16 sm:gap-1 sm:px-2 sm:pb-2">
              <span className="h-3 flex-1 rounded-t bg-[#A6E824]/50 sm:h-4" />
              <span className="h-6 flex-1 rounded-t bg-[#A6E824] sm:h-7" />
              <span className="h-4 flex-1 rounded-t bg-[#A6E824]/70 sm:h-5" />
              <span className="h-8 flex-1 rounded-t bg-[#A6E824]/90 sm:h-9" />
            </div>

            <p className="mt-1 whitespace-nowrap text-[8px] font-black uppercase tracking-[-0.03em] text-gray-500 sm:text-xs">
              Statistiche
            </p>
          </button>
        </header>

        <section className="relative z-30 mt-3 grid overflow-visible rounded-2xl border border-white/10 bg-[#0b1419] shadow-xl shadow-black/30 sm:mt-4 md:grid-cols-[1.5fr_1fr]">
          <div className="flex items-center gap-3 border-b border-white/10 p-3 sm:gap-4 sm:p-4 md:border-b-0 md:border-r">
            <div
              className={`relative flex h-12 w-12 shrink-0 items-center justify-center rounded-full border text-2xl shadow-[0_0_28px_rgba(166,232,36,0.18)] sm:h-16 sm:w-16 sm:text-3xl ${
                interactionLocked
                  ? "border-gray-500/40 bg-gray-500/10 text-gray-400 shadow-[0_0_22px_rgba(156,163,175,0.10)]"
                  : "border-[#A6E824]/40 bg-[#A6E824]/20 text-[#A6E824]"
              }`}
            >
              <span>✎</span>
              {interactionLocked && (
                <span className="absolute -bottom-1 -right-1 flex h-6 w-6 items-center justify-center rounded-full border border-gray-500/40 bg-[#071015] text-[13px] shadow-lg sm:h-7 sm:w-7 sm:text-sm">
                  🔒
                </span>
              )}
            </div>
            <div>
              <p className="text-sm font-black uppercase sm:text-lg">
                {isByeRound
                  ? "Turno di riposo"
                  : locked
                    ? "Pronostici chiusi"
                    : "Pronostici aperti"}
              </p>
              <p className="text-xs text-gray-300 sm:text-sm">
                {isByeRound
                  ? "Le funzioni Fantacalcio sono disattivate per questa giornata"
                  : locked
                    ? ""
                    : "Puoi reinviare fino al lock ufficiale"}
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
                <p className="text-base font-black uppercase sm:text-lg">Fantacalcio</p>
                <p className="text-[11px] font-semibold text-gray-500">Duello live</p>
              </div>
              <span className="text-2xl text-white sm:text-3xl">⌄</span>
            </button>

            {modeOpen && (
              <div className="absolute left-3 right-3 top-[calc(100%-10px)] z-50 overflow-hidden rounded-2xl border border-white/10 bg-[#10181d] shadow-2xl shadow-black/80">
                <button
                  type="button"
                  onClick={() => router.push(`/leghe/${leagueId}/giornata`)}
                  className="flex w-full items-center justify-between px-4 py-3 text-left transition hover:bg-white/5"
                >
                  <span>
                    <span className="block text-sm font-black uppercase text-white sm:text-base">Modalità Punti Puri</span>
                    <span className="block text-[11px] font-semibold text-gray-500">Vai alla giornata punti</span>
                  </span>
                  <span className="text-xl">⭐</span>
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

        <div className={isByeRound ? "pointer-events-none opacity-30 grayscale" : ""}>
          <RuleStrip />
        </div>

        {isByeRound ? (
          <section className="mt-3 grid gap-4 rounded-2xl border border-white/10 bg-[#0b1419] p-4 shadow-xl shadow-black/30 sm:mt-4 sm:grid-cols-[minmax(0,0.8fr)_minmax(0,1.2fr)] sm:items-center sm:p-5">
            <div className="pointer-events-none opacity-35 grayscale">
              <ClubKitMini club={viewedClubInfo} align="left" />
            </div>

            <div className="rounded-2xl border border-white/10 bg-black/25 p-4 text-center sm:p-5">
              <div className="mx-auto flex h-11 w-11 items-center justify-center rounded-full border border-gray-500/30 bg-gray-500/10 text-xl grayscale">
                ⏸
              </div>
              <p className="mt-3 text-base font-black uppercase text-gray-200 sm:text-lg">
                In questo turno riposi in Fantacalcio
              </p>
              <p className="mt-1 text-xs font-semibold leading-5 text-gray-500 sm:text-sm">
                Le funzioni di questa modalità sono disattivate. Puoi pianificare la strategia della modalità One-to-One.
              </p>
              <button
                type="button"
                onClick={() => router.push(`/leghe/${leagueId}/onetoone`)}
                className="mt-4 rounded-xl border border-[#A6E824]/35 bg-[#A6E824]/10 px-4 py-2.5 text-xs font-black uppercase tracking-[0.08em] text-[#A6E824] transition hover:border-[#A6E824]/70 hover:bg-[#A6E824]/15 sm:text-sm"
              >
                Pianifica One-to-One
              </button>
            </div>
          </section>
        ) : (
          <section className="mt-3 grid grid-cols-[1fr_auto_1fr] items-center gap-3 rounded-2xl border border-white/10 bg-[#0b1419] p-3 shadow-xl shadow-black/30 sm:mt-4 sm:p-4">
            <ClubKitMini club={viewedClubInfo} align="left" />

            <div className="flex h-9 w-9 items-center justify-center rounded-full border border-[#A6E824]/35 bg-black/40 text-[10px] font-black text-[#A6E824] sm:h-11 sm:w-11 sm:text-xs">
              VS
            </div>

            <ClubKitMini club={opponentClubInfo} align="right" />
          </section>
        )}

        {strategyError && (
          <section className="mt-3 rounded-2xl border border-red-500/30 bg-red-500/10 px-4 py-3 text-sm font-semibold text-red-200 sm:mt-4">
            {strategyError}
          </section>
        )}

        {strategyLoading && (
          <section className="mt-3 rounded-2xl border border-white/10 bg-[#0b1419] px-4 py-8 text-center text-sm font-bold text-gray-400 sm:mt-4">
            Caricamento strategia Fantacalcio...
          </section>
        )}

        {!strategyLoading && liveRows.length === 10 && (
        <section className={`mt-3 grid gap-4 sm:mt-4 ${
          isByeRound ? "pointer-events-none select-none opacity-25 grayscale" : ""
        }`}>
          {[
            {
              title: "Attacco",
              subtitle: "Partite con bonus aggressivi",
              rows: displayedLiveRows.slice(0, 5),
              offset: 0,
              tone: "red",
            },
            {
              title: "Difesa",
              subtitle: "Partite con protezione strategica",
              rows: displayedLiveRows.slice(5, 10),
              offset: 5,
              tone: "green",
            },
          ].map((group) => (
            <section
              key={group.title}
              className={`overflow-hidden rounded-2xl border shadow-2xl shadow-black/40 ${
                group.tone === "red"
                  ? "border-red-500/25 bg-gradient-to-br from-red-950/30 via-[#0b1419] to-[#0b1419]"
                  : "border-[#A6E824]/25 bg-gradient-to-br from-[#A6E824]/15 via-[#0b1419] to-[#0b1419]"
              }`}
            >
              <div
                className={`flex items-center justify-between border-b px-3 py-3 sm:px-5 ${
                  group.tone === "red" ? "border-red-500/20" : "border-[#A6E824]/20"
                }`}
              >
                <div>
                  <p
                    className={`text-sm font-black uppercase tracking-[0.18em] sm:text-base ${
                      group.tone === "red" ? "text-red-300" : "text-[#A6E824]"
                    }`}
                  >
                    {group.title}
                  </p>
                  <p className="text-[10px] font-semibold uppercase tracking-[0.12em] text-gray-500 sm:text-xs">
                    {group.subtitle}
                  </p>
                </div>

                <span
                  className={`rounded-full border px-3 py-1 text-[10px] font-black uppercase ${
                    group.tone === "red"
                      ? "border-red-500/30 bg-red-500/10 text-red-300"
                      : "border-[#A6E824]/30 bg-[#A6E824]/10 text-[#A6E824]"
                  }`}
                >
                  5 partite
                </span>
              </div>

              {group.rows.map((match, groupIndex) => {
                const matchIndex = group.offset + groupIndex;
                const selected = selectedMatchIndex === matchIndex;

                return (
                  <article
                    key={match.id}
                    className={`border-b border-white/10 px-2 py-2 last:border-b-0 sm:px-5 sm:py-4 ${
                      selected && !interactionLocked ? "bg-[#A6E824]/10 ring-1 ring-inset ring-[#A6E824]/60" : ""
                    }`}
                  >
                    <div className="grid grid-cols-[75%_25%] items-center gap-1 sm:grid-cols-[2.35fr_1fr] sm:gap-5">
                      <button
                        type="button"
                        onClick={() => handleSwapMatch(matchIndex)}
                        className={`grid min-w-0 grid-cols-[33%_67%] items-center gap-1 rounded-xl text-left transition sm:grid-cols-[1fr_1.35fr] sm:gap-5 ${
                          interactionLocked ? "cursor-default" : "hover:bg-white/[0.03]"
                        }`}
                        title={interactionLocked ? "Swap disattivato dopo il lock ufficiale" : "Clicca una partita di Attacco e una di Difesa per scambiarle di posto"}
                      >
                        <PredictionSide score={match.leftPrediction} active={match.leftActive} side="left" />
                        <LiveMatchCenter match={match} />
                      </button>

                      {interactionLocked ? (
                        <PredictionSide score={match.rightPrediction} active={match.rightActive} side="right" />
                      ) : (
                        <div className="flex min-w-0 flex-col items-center text-center sm:items-end">
                          <p className="text-[10px] font-black uppercase tracking-[0.12em] text-gray-600 sm:text-xs">
                            Avversario
                          </p>
                          <p className="mt-2 text-lg font-black leading-none text-gray-700 sm:text-3xl">—</p>
                          <div className="mt-2 h-6 w-full rounded-xl border border-dashed border-white/10 bg-black/20 sm:h-8" />
                        </div>
                      )}
                    </div>
                  </article>
                );
              })}
            </section>
          ))}
        </section>
        )}

        {!isByeRound && (
          <section className="mt-5 flex justify-center">
            <RoundSubmissionButton
              locked={locked}
              isViewingSelf={isViewingSelf}
              hasOfficialSubmission={hasOfficialSubmission}
              hasUnconfirmedChanges={hasUnconfirmedChanges}
              submitting={submitting || savingStrategy || strategyLoading}
              disabled={liveRows.length !== 10}
              onClick={submitStrategy}
            />
          </section>
        )}
      </section>

    
      <SubmissionModal
        open={submissionModalOpen}
        title="Strategia Fantacalcio inviata"
        description={"La disposizione Attacco/Difesa è ora ufficiale.\nPuoi modificarla e reinviarla fino al lock ufficiale."}
        primaryLabel="Vai a One To One"
        onPrimary={() => router.push(`/leghe/${leagueId}/onetoone`)}
        onClose={() => setSubmissionModalOpen(false)}
      />
</main>
  );
}
