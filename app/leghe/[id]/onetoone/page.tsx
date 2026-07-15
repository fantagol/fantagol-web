"use client";

import { useEffect, useMemo, useRef, useState, type PointerEvent, type TouchEvent } from "react";
import { createPortal } from "react-dom";
import { useParams, useRouter } from "next/navigation";
import HamburgerDrawer from "../../../../components/app/HamburgerDrawer";
import SubmissionModal from "../../../../components/app/SubmissionModal";
import RoundSubmissionButton from "../../../../components/app/RoundSubmissionButton";
import TeamCrest from "../../../../components/app/TeamCrest";
import KitPreview from "../../../../components/club/KitPreview";
import { supabase } from "../../../../lib/supabaseClient";
import { getRoundState } from "../../../../lib/roundState";
import {
  fromOneToOneStrategyPayload,
  toOneToOneStrategyPayload,
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

type PredictionSlot = {
  matchId: string;
  homeBadge: string;
  awayBadge: string;
  homeCrestReference: string | null;
  homeLogoUrl: string | null;
  awayCrestReference: string | null;
  awayLogoUrl: string | null;
  score: string;
  active: string[];
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

function Avatar({ name, avatarUrl }: { name: string; avatarUrl?: string | null }) {
  return (
    <div className="flex h-14 w-14 shrink-0 items-center justify-center overflow-hidden rounded-full border border-white/15 bg-gradient-to-br from-white to-gray-300 text-xl font-black text-black shadow-xl shadow-black/40 sm:h-20 sm:w-20 sm:text-3xl">
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
      className={`${compact ? "h-[15px] w-[15px] text-[9px] sm:h-6 sm:w-6 sm:text-sm" : "h-7 w-7 text-base sm:h-8 sm:w-8 sm:text-lg"} flex items-center justify-center rounded-full border bg-black/30 font-black ${toneClass}`}
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
          <div key={item.key} className="flex min-w-0 flex-col items-center justify-center rounded-xl border border-white/5 bg-black/20 px-1 py-1.5 sm:px-2 sm:py-2">
            <RuleIcon item={item} active={item.tone !== "muted" && item.key !== "bad" && item.key !== "opposite"} compact />
            <p className="mt-1 max-w-full truncate text-[7px] font-black uppercase text-gray-300 sm:text-[9px]">{item.short}</p>
            <p className={`text-[9px] font-black sm:text-xs ${item.points.startsWith("-") ? "text-red-400" : item.tone === "orange" ? "text-orange-300" : item.tone === "violet" ? "text-violet-300" : "text-[#A6E824]"}`}>{item.points}</p>
          </div>
        ))}
      </div>
    </section>
  );
}

function PredictionSide({
  score,
  active,
  side,
  homeBadge,
  awayBadge,
}: {
  score: string;
  active: string[];
  side: Side;
  homeBadge: string;
  awayBadge: string;
}) {
  const activeKeys = new Set(active);

  return (
    <div
      className={`flex min-w-0 flex-col items-center rounded-xl border border-white/10 bg-black/25 px-1 py-1.5 shadow-inner shadow-white/5 sm:px-1.5 sm:py-2 ${
        side === "left" ? "sm:items-start" : "sm:items-end"
      }`}
    >
      <div className="flex max-w-full items-center justify-center gap-0.5 sm:gap-1.5">
        <span className="text-[7px] font-black uppercase text-gray-500 sm:text-xs">{homeBadge}</span>
        <span className="text-[13px] font-black leading-none text-white sm:text-2xl">{score}</span>
        <span className="text-[7px] font-black uppercase text-gray-500 sm:text-xs">{awayBadge}</span>
      </div>

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
          <span className="text-2xl font-black leading-none text-[#A6E824] sm:text-5xl">{match.liveHome}</span>
          <span className="text-xl font-black leading-none text-[#A6E824] sm:text-4xl">-</span>
          <span className="text-2xl font-black leading-none text-white sm:text-5xl">{match.liveAway}</span>
        </div>

        <div className="mt-2 grid w-full grid-cols-[1fr_auto_1fr] items-center text-center">
          <span className="text-lg font-black leading-none text-[#A6E824] sm:text-2xl">0</span>
          <span className="text-[10px] font-black uppercase tracking-[0.18em] text-gray-500 sm:text-xs">PT</span>
          <span className="text-lg font-black leading-none text-white sm:text-2xl">0</span>
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
    .replace(/\b(FC|AC|AS|SS|US|SSC|BC|CFC)\b/gi, "")
    .replace(/\bCalcio\b/gi, "")
    .replace(/\s+/g, " ")
    .trim();
}

function getTeamBadge(name: string): string {
  const words = name.split(/\s+/).filter(Boolean);
  if (words.length === 1) return words[0].slice(0, 3).toUpperCase();
  return words.map((word) => word[0]).join("").slice(0, 3).toUpperCase();
}

function toPredictionSlot(match: DuelMatch): PredictionSlot {
  return {
    matchId: match.id,
    homeBadge: match.homeBadge,
    awayBadge: match.awayBadge,
    homeCrestReference: match.homeCrestReference,
    homeLogoUrl: match.homeLogoUrl,
    awayCrestReference: match.awayCrestReference,
    awayLogoUrl: match.awayLogoUrl,
    score: match.leftPrediction,
    active: match.leftActive,
  };
}

export default function OneToOneLivePage() {
  const router = useRouter();
  const params = useParams<{ id: string }>();
  const leagueId = params.id;
  const [menuOpen, setMenuOpen] = useState(false);
  const [mounted, setMounted] = useState(false);
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
  const [leagueFixtureId, setLeagueFixtureId] = useState<string | null>(null);
  const [hasOfficialSubmission, setHasOfficialSubmission] = useState(false);
  const [hasUnconfirmedChanges, setHasUnconfirmedChanges] = useState(false);
  const [strategyExists, setStrategyExists] = useState(false);
  const [strategyLocked, setStrategyLocked] = useState(false);
  const [strategyLoading, setStrategyLoading] = useState(true);
  const [savingStrategy, setSavingStrategy] = useState(false);
  const [strategyError, setStrategyError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const [leagueInfo, setLeagueInfo] = useState<LeagueInfo>({
    name: "Lega FantaGol",
    displayName: "Club FantaGol",
    inviteCode: leagueId,
    role: "member",
  });

  useEffect(() => {
    setMounted(true);
  }, []);

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
          kit_secondary_color: club.kit_secondary_color || "#A6E824",
          kit_third_color: club.kit_third_color || "#FFFFFF",
          kit_logo_mode: club.kit_logo_mode || "center_horizontal",
          kit_crest_position: club.kit_crest_position || "left_chest",
          stars_count: club.stars_count || 0,
        });

        setOpponentClubInfo(null);
      }
    }

    loadLeagueInfo();
  }, [leagueId]);

  useEffect(() => {
    let cancelled = false;

    async function loadOneToOneStrategy() {
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

      const [
        { data: predictionData, error: predictionError },
        { data: strategyData, error: strategyStatusError },
      ] = await Promise.all([
        supabase.rpc("get_my_round_predictions_rpc", {
          p_league_round_id: currentLeagueRoundId,
        }),
        supabase.rpc("get_my_strategy_status_rpc", {
          p_league_round_id: currentLeagueRoundId,
          p_mode: "one_to_one",
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
        setStrategyError("La giornata One-to-One deve contenere esattamente 10 partite.");
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

      const baseSlots = baseRows.map(toPredictionSlot);
      const status = ((strategyData || [])[0] || null) as StrategyStatusRow | null;
      let restoredSlots: (PredictionSlot | null)[] = baseSlots;

      if (status?.strategy_exists && status.workspace_payload) {
        try {
          const matrix = fromOneToOneStrategyPayload(
            status.workspace_payload,
            status.league_fixture_id
          );
          const slotsByMatchId = new Map(
            baseSlots.map((slot) => [slot.matchId, slot])
          );
          const sourceByTarget = new Map(
            matrix.pairs.map((pair) => [pair.targetMatchId, pair.sourceMatchId])
          );

          restoredSlots = baseRows.map((targetMatch) => {
            const sourceMatchId = sourceByTarget.get(targetMatch.id);
            return sourceMatchId ? slotsByMatchId.get(sourceMatchId) || null : null;
          });
        } catch (error) {
          setStrategyError(
            error instanceof Error
              ? error.message
              : "La strategia One-to-One salvata non è leggibile."
          );
        }
      }

      setLeagueRoundId(currentLeagueRoundId);
      setRoundNumber(rows[0]?.round_number ?? null);
      setLeagueFixtureId(status?.league_fixture_id || null);
      setLiveRows(baseRows);
      setLeftSlots(restoredSlots);
      setStoredSlots(
        baseSlots.filter(
          (slot) => !restoredSlots.some((assigned) => assigned?.matchId === slot.matchId)
        )
      );
      setStrategyExists(Boolean(status?.strategy_exists));
      setHasOfficialSubmission(Boolean(status?.has_official_snapshot));
      setHasUnconfirmedChanges(Boolean(status?.has_unconfirmed_changes));
      setStrategyLocked(Boolean(status?.is_locked));
      setStrategyLoading(false);
    }

    void loadOneToOneStrategy();

    return () => {
      cancelled = true;
    };
  }, [leagueId]);


  const leftPoints = 72;
  const rightPoints = 65;
  const leftGoals = 5;
  const rightGoals = 4;

  // Simulazione temporanea: quando collegheremo il backend useremo currentRound.first_kick_at.
  const round = getRoundState("2026-08-23T13:44:55");
  const locked = strategyLocked;

  const isLiveForSwipe = round.isLive || round.isFinished;
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
    closeMemoryPopup();

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
    if (target.closest("[data-memory-popup='true']")) return;
    if (target.closest("input, textarea, select")) return;

    if (openMemoryIndex !== null) {
      closeMemoryPopup();
    }

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

  const [liveRows, setLiveRows] = useState<DuelMatch[]>([]);
  const [leftSlots, setLeftSlots] = useState<(PredictionSlot | null)[]>([]);
  const displayedLeftSlots = canViewProfileContent ? leftSlots : leftSlots.map(() => null);
  const [storedSlots, setStoredSlots] = useState<PredictionSlot[]>([]);
  const [openMemoryIndex, setOpenMemoryIndex] = useState<number | null>(null);
  const [memoryPopupFloating, setMemoryPopupFloating] = useState(false);
  const [memoryPopupPosition, setMemoryPopupPosition] = useState({ x: 12, y: 250 });
  const [memoryPopupWidth, setMemoryPopupWidth] = useState<number | null>(null);
  const [memoryDragOffset, setMemoryDragOffset] = useState<{ x: number; y: number } | null>(null);
  const [submissionModalOpen, setSubmissionModalOpen] = useState(false);
  const allSlotsComplete =
    leftSlots.length === 10 && leftSlots.every((slot) => slot !== null);

  function closeMemoryPopup() {
    setOpenMemoryIndex(null);
    setMemoryPopupFloating(false);
    setMemoryPopupWidth(null);
    setMemoryDragOffset(null);
  }

  function openMemoryPopup(index: number, anchor: HTMLElement) {
    const rect = anchor.getBoundingClientRect();
    const popupWidth = Math.max(106, rect.width);
    const x = Math.min(
      Math.max(8, rect.left),
      Math.max(8, window.innerWidth - popupWidth - 8)
    );
    const y = Math.min(
      Math.max(8, rect.bottom + 8),
      Math.max(8, window.innerHeight - 140)
    );

    setOpenMemoryIndex(index);
    setMemoryPopupFloating(true);
    setMemoryPopupWidth(popupWidth);
    setMemoryPopupPosition({ x, y });
    setMemoryDragOffset(null);
  }

  useEffect(() => {
    closeMemoryPopup();
  }, [activeSwipeIndex]);

  async function persistPairings(nextSlots: (PredictionSlot | null)[]) {
    if (
      !leagueRoundId ||
      !leagueFixtureId ||
      liveRows.length !== 10 ||
      nextSlots.some((slot) => slot === null)
    ) {
      return;
    }

    const completeSlots = nextSlots as PredictionSlot[];
    const payload = toOneToOneStrategyPayload({
      fixtureId: leagueFixtureId,
      pairs: completeSlots.map((slot, index) => ({
        sourceMatchId: slot.matchId,
        targetMatchId: liveRows[index].id,
      })),
    });

    setSavingStrategy(true);
    const { data, error } = await supabase.rpc("save_strategy_draft_rpc", {
      p_league_round_id: leagueRoundId,
      p_mode: "one_to_one",
      p_payload: payload,
    });
    setSavingStrategy(false);

    if (error) {
      setStrategyError(error.message || "Salvataggio degli abbinamenti non riuscito.");
      return;
    }

    const result = (data || [])[0];
    setStrategyExists(true);
    setHasOfficialSubmission(Boolean(result?.submitted_version));
    setHasUnconfirmedChanges(Boolean(result?.has_unconfirmed_changes));
    setStrategyError(null);
  }

  function removePredictionSlot(index: number, anchor: HTMLElement) {
    if (locked || strategyLoading || savingStrategy) return;

    const slot = leftSlots[index];
    if (!slot) {
      if (openMemoryIndex === index) {
        closeMemoryPopup();
      } else {
        openMemoryPopup(index, anchor);
      }
      return;
    }

    setStoredSlots((current) => [...current, slot]);
    setLeftSlots((current) => current.map((item, itemIndex) => (itemIndex === index ? null : item)));
    closeMemoryPopup();
  }

  function restorePredictionSlot(targetIndex: number, storedIndex: number) {
    if (locked || strategyLoading || savingStrategy) return;

    const slot = storedSlots[storedIndex];
    if (!slot) return;

    const nextSlots = leftSlots.map((item, itemIndex) =>
      itemIndex === targetIndex ? slot : item
    );
    setLeftSlots(nextSlots);
    setStoredSlots((current) =>
      current.filter((_, itemIndex) => itemIndex !== storedIndex)
    );
    closeMemoryPopup();
    void persistPairings(nextSlots);
  }

  function startMemoryPopupDrag(event: PointerEvent<HTMLDivElement>) {
    event.preventDefault();
    event.stopPropagation();

    swipeStartXRef.current = null;
    swipeStartYRef.current = null;
    swipeLockRef.current = null;

    const popup = event.currentTarget.closest("[data-memory-popup='true']") as HTMLDivElement | null;
    if (!popup) return;

    const rect = popup.getBoundingClientRect();

    setMemoryPopupWidth(rect.width);
    setMemoryDragOffset({
      x: event.clientX - rect.left,
      y: event.clientY - rect.top,
    });

    event.currentTarget.setPointerCapture(event.pointerId);
  }

  function moveMemoryPopup(event: PointerEvent<HTMLDivElement>) {
    if (!memoryDragOffset) return;

    event.preventDefault();
    event.stopPropagation();

    const popupWidth = memoryPopupWidth ?? 106;
    const popup = event.currentTarget.closest("[data-memory-popup='true']") as HTMLDivElement | null;
    const popupHeight = popup?.offsetHeight ?? 80;

    const maxX = Math.max(8, window.innerWidth - popupWidth - 8);
    const maxY = Math.max(8, window.innerHeight - popupHeight - 8);

    const edgeZone = 72;
    const maxScrollStep = 18;
    let scrollDelta = 0;

    if (event.clientY < edgeZone) {
      const intensity = (edgeZone - event.clientY) / edgeZone;
      scrollDelta = -Math.ceil(maxScrollStep * intensity);
    } else if (event.clientY > window.innerHeight - edgeZone) {
      const intensity =
        (event.clientY - (window.innerHeight - edgeZone)) / edgeZone;
      scrollDelta = Math.ceil(maxScrollStep * intensity);
    }

    if (scrollDelta !== 0) {
      window.scrollBy({ top: scrollDelta, behavior: "auto" });
    }

    setMemoryPopupPosition({
      x: Math.min(Math.max(8, event.clientX - memoryDragOffset.x), maxX),
      y: Math.min(Math.max(8, event.clientY - memoryDragOffset.y), maxY),
    });
  }

  function stopMemoryPopupDrag(event?: PointerEvent<HTMLDivElement>) {
    event?.preventDefault();
    event?.stopPropagation();

    if (
      event &&
      event.currentTarget.hasPointerCapture(event.pointerId)
    ) {
      event.currentTarget.releasePointerCapture(event.pointerId);
    }

    setMemoryDragOffset(null);
  }

  async function submitStrategy() {
    if (
      locked ||
      submitting ||
      strategyLoading ||
      savingStrategy ||
      !isViewingSelf ||
      !leagueRoundId ||
      !leagueFixtureId ||
      liveRows.length !== 10 ||
      (hasOfficialSubmission && !hasUnconfirmedChanges)
    ) {
      return;
    }

    if (!allSlotsComplete) {
      alert("Completa tutti gli abbinamenti prima di inviare.");
      return;
    }

    setSubmitting(true);

    if (!strategyExists) {
      const completeSlots = leftSlots as PredictionSlot[];
      const payload = toOneToOneStrategyPayload({
        fixtureId: leagueFixtureId,
        pairs: completeSlots.map((slot, index) => ({
          sourceMatchId: slot.matchId,
          targetMatchId: liveRows[index].id,
        })),
      });

      const { error: saveError } = await supabase.rpc(
        "save_strategy_draft_rpc",
        {
          p_league_round_id: leagueRoundId,
          p_mode: "one_to_one",
          p_payload: payload,
        }
      );

      if (saveError) {
        setSubmitting(false);
        alert(saveError.message || "Salvataggio degli abbinamenti non riuscito.");
        return;
      }

      setStrategyExists(true);
    }

    const { data, error } = await supabase.rpc("submit_strategy_rpc", {
      p_league_round_id: leagueRoundId,
      p_mode: "one_to_one",
    });

    setSubmitting(false);

    if (error) {
      alert(error.message || "Invio della strategia One-to-One non riuscito.");
      return;
    }

    const result = (data || [])[0];
    if (!result?.submitted_version) {
      alert("La conferma degli abbinamenti non è coerente.");
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
          filter:
            swipeDragX !== 0
              ? "drop-shadow(0 28px 70px rgba(0,0,0,0.55))"
              : "none",
          willChange: "transform, opacity, filter",
        }}
      >
        <header className="grid grid-cols-[1fr_78px_78px] gap-2 border-b border-white/10 py-3 sm:grid-cols-[1fr_120px_120px] sm:gap-3 sm:py-5">
          <section className="min-w-0 overflow-hidden rounded-2xl border border-white/10 bg-[#0b1419] p-2 shadow-2xl shadow-black/40 sm:p-3">
            <div className="grid grid-cols-[54px_1fr_54px] items-center gap-1 sm:grid-cols-[84px_1fr_84px] sm:gap-2">
              <div className="flex shrink-0 flex-col items-center">
                <Avatar name={viewedClubInfo.name} avatarUrl={viewedClubInfo.crest_url} />
                <p className="mt-1 max-w-[54px] truncate text-[9px] font-black uppercase leading-none text-white sm:max-w-[72px] sm:text-[10px]">
                  {viewedClubInfo.name}
                </p>
              </div>

              <div className="flex min-w-0 flex-col items-center justify-center">
                <div className="grid w-full grid-cols-[1fr_auto_1fr] items-end gap-1 text-center">
                  <span className="text-base font-black leading-none text-[#A6E824] sm:text-xl">
                    {displayedLeftPoints}
                  </span>

                  <span className="pb-0.5 text-[9px] font-black uppercase tracking-[0.16em] text-gray-500 sm:text-xs">
                    pt
                  </span>

                  <span className="text-base font-black leading-none text-[#A6E824] sm:text-xl">
                    {displayedRightPoints}
                  </span>
                </div>

                <span className="my-1 flex h-6 w-6 items-center justify-center rounded-full border border-[#A6E824]/40 bg-black/40 text-[9px] font-black text-white sm:h-8 sm:w-8 sm:text-[10px]">
                  VS
                </span>

                <div className="flex items-center justify-center gap-0.5 sm:gap-1">
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

              <div className="flex shrink-0 flex-col items-center">
                <Avatar name={opponentClubInfo?.name || "Avversario"} avatarUrl={opponentClubInfo?.crest_url} />
                <p className="mt-1 max-w-[54px] truncate text-[9px] font-black uppercase leading-none text-white sm:max-w-[72px] sm:text-[10px]">
                  {opponentClubInfo?.name || "Avversario"}
                </p>
              </div>
            </div>
          </section>

          <div className="rounded-2xl border border-white/10 bg-black/25 p-2 text-center sm:p-3">
            <div className="flex h-full flex-col items-center justify-center">
              <p className="text-[9px] font-bold uppercase text-gray-500 sm:text-xs">Giornata</p>
              <p className="text-2xl font-black text-white sm:text-3xl">{roundNumber ?? "—"}</p>
            </div>
          </div>

          <button
            type="button"
            onClick={() => router.push("/statistiche")}
            className="rounded-2xl border border-white/10 bg-black/25 p-2 text-center transition hover:border-[#A6E824]/60 hover:bg-white/[0.03] sm:p-3"
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
                {locked ? "Abbinamenti chiusi" : "Abbinamenti aperti"}
              </p>
              <p className="text-xs text-gray-300 sm:text-sm">
                {locked ? "" : "Puoi reinviare fino al lock ufficiale"}
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
                <p className="text-base font-black uppercase sm:text-lg">One To One</p>
                <p className="text-[11px] font-semibold text-gray-500">Sfida diretta</p>
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
                  onClick={() => router.push(`/leghe/${leagueId}/fantacalcio`)}
                  className="flex w-full items-center justify-between border-t border-white/10 px-4 py-3 text-left transition hover:bg-white/5"
                >
                  <span>
                    <span className="block text-sm font-black uppercase text-white sm:text-base">Modalità Fantacalcio</span>
                    <span className="block text-[11px] font-semibold text-gray-500">Vai al duello live</span>
                  </span>
                  <span className="text-xl">🏆</span>
                </button>
              </div>
            )}
          </div>
        </section>

        <RuleStrip />

        <section className="mt-3 grid grid-cols-[1fr_auto_1fr] items-center gap-3 rounded-2xl border border-white/10 bg-[#0b1419] p-3 shadow-xl shadow-black/30 sm:mt-4 sm:p-4">
          <ClubKitMini club={viewedClubInfo} align="left" />

          <div className="flex h-9 w-9 items-center justify-center rounded-full border border-[#A6E824]/35 bg-black/40 text-[10px] font-black text-[#A6E824] sm:h-11 sm:w-11 sm:text-xs">
            VS
          </div>

          <ClubKitMini club={opponentClubInfo} align="right" />
        </section>

        {strategyError && (
          <section className="mt-3 rounded-2xl border border-red-500/30 bg-red-950/20 p-4 text-sm font-semibold text-red-200 sm:mt-4">
            {strategyError}
          </section>
        )}

        {strategyLoading && (
          <section className="mt-3 rounded-2xl border border-white/10 bg-[#0b1419] p-6 text-center text-sm font-bold text-gray-400 sm:mt-4">
            Caricamento abbinamenti One-to-One...
          </section>
        )}

        {!strategyLoading && liveRows.length === 10 && (
        <section className="mt-3 overflow-hidden rounded-2xl border border-white/10 bg-[#0b1419] shadow-2xl shadow-black/40 sm:mt-4">
          {liveRows.map((match, index) => {
            const leftSlot = displayedLeftSlots[index];

            return (
              <article key={match.id} className="border-b border-white/10 px-2 py-2 last:border-b-0 sm:px-5 sm:py-4">
                <div className="grid grid-cols-[23%_54%_23%] items-center gap-0.5 sm:grid-cols-[1fr_1.35fr_1fr] sm:gap-5">
                  <div className="relative">
                    <button
                      type="button"
                      onClick={(event) =>
                        removePredictionSlot(index, event.currentTarget)
                      }
                      disabled={locked || !isViewingSelf}
                      className={`w-full text-left transition ${locked ? "cursor-default" : "hover:scale-[1.01]"}`}
                      title={
                        locked
                          ? "Pronostico bloccato"
                          : leftSlot
                            ? "Clicca per svuotare la casella e mettere il pronostico in memoria"
                            : "Clicca per scegliere un pronostico dalla memoria"
                      }
                    >
                      {leftSlot ? (
                        <PredictionSide
                          score={leftSlot.score}
                          active={leftSlot.active}
                          side="left"
                          homeBadge={leftSlot.homeBadge}
                          awayBadge={leftSlot.awayBadge}
                        />
                      ) : (
                        <div className="flex min-h-[64px] min-w-0 flex-col items-center justify-center rounded-xl border border-dashed border-white/10 bg-black/25 px-1.5 py-2 text-center shadow-inner shadow-white/5 sm:min-h-[104px]">
                          <p className="text-[10px] font-black uppercase tracking-[0.12em] text-gray-600 sm:text-xs">Vuota</p>
                          <p className="mt-1 text-lg font-black leading-none text-gray-700 sm:text-3xl">—</p>
                        </div>
                      )}
                    </button>

                  </div>

                  <LiveMatchCenter match={match} />

                  {locked && canViewProfileContent ? (
                    <PredictionSide
                      score={match.rightPrediction}
                      active={match.rightActive}
                      side="right"
                      homeBadge={match.homeBadge}
                      awayBadge={match.awayBadge}
                    />
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
        )}

        <section className="mt-5 flex justify-center">
          <RoundSubmissionButton
            locked={locked}
            isViewingSelf={isViewingSelf}
            hasOfficialSubmission={hasOfficialSubmission}
            hasUnconfirmedChanges={hasUnconfirmedChanges}
            submitting={submitting || savingStrategy || strategyLoading}
            disabled={!allSlotsComplete || Boolean(strategyError)}
            onClick={submitStrategy}
          />
        </section>
      </section>


      {mounted &&
        openMemoryIndex !== null &&
        !locked &&
        leftSlots[openMemoryIndex] === null &&
        createPortal(
          <div
            data-memory-popup="true"
            className="fixed z-[200] rounded-2xl border border-[#A6E824]/25 bg-[#071015] p-1 shadow-2xl shadow-[#A6E824]/10 sm:p-1.5"
            style={{
              left: memoryPopupPosition.x,
              top: memoryPopupPosition.y,
              width: memoryPopupWidth ?? 106,
            }}
            onTouchStart={(event) => event.stopPropagation()}
            onTouchMove={(event) => event.stopPropagation()}
            onTouchEnd={(event) => event.stopPropagation()}
          >
            <div
              className={`absolute left-1/2 top-0 z-10 flex h-6 w-[74px] -translate-x-1/2 -translate-y-[21px] touch-none select-none items-center justify-center border border-[#A6E824]/40 bg-[#0b1419] text-[13px] font-black text-[#A6E824] shadow-lg shadow-[#A6E824]/10 [clip-path:polygon(12%_0%,88%_0%,100%_100%,0%_100%)] sm:h-7 sm:w-[86px] sm:-translate-y-[24px] ${
                memoryDragOffset ? "cursor-grabbing" : "cursor-grab"
              }`}
              onPointerDown={startMemoryPopupDrag}
              onPointerMove={moveMemoryPopup}
              onPointerUp={stopMemoryPopupDrag}
              onPointerCancel={stopMemoryPopupDrag}
              title="Trascina memoria"
            >
              ≡
            </div>

            {storedSlots.length === 0 ? (
              <div className="h-10 rounded-xl border border-dashed border-white/10 bg-black/25" />
            ) : (
              <div className="grid gap-1.5">
                {storedSlots.map((stored, storedIndex) => (
                  <button
                    key={`${stored.matchId}-${storedIndex}`}
                    type="button"
                    onPointerDown={(event) => event.stopPropagation()}
                    onClick={() =>
                      restorePredictionSlot(openMemoryIndex, storedIndex)
                    }
                    className="group grid grid-cols-[22px_auto_22px] items-center justify-center gap-1 rounded-xl border border-[#A6E824]/25 bg-[#0b1419] px-0.5 py-1.5 text-[11px] font-black text-white shadow-inner shadow-white/5 transition hover:scale-[1.03] hover:border-[#A6E824]/70 hover:bg-[#101d18] hover:shadow-[0_0_18px_rgba(166,232,36,0.16)] sm:grid-cols-[1fr_auto_1fr] sm:gap-1.5 sm:px-2 sm:py-2 sm:text-sm"
                  >
                    <span className="text-left text-[10px] uppercase tracking-[-0.02em] text-gray-500 transition group-hover:text-[#A6E824] sm:tracking-[0.02em] sm:text-xs">
                      {stored.homeBadge}
                    </span>
                    <span className="rounded-lg bg-black/35 px-0.5 py-1 text-center text-[14px] leading-none text-white shadow-inner shadow-white/5 sm:px-2 sm:text-base">
                      {stored.score}
                    </span>
                    <span className="text-right text-[10px] uppercase tracking-[-0.02em] text-gray-500 transition group-hover:text-[#A6E824] sm:tracking-[0.02em] sm:text-xs">
                      {stored.awayBadge}
                    </span>
                  </button>
                ))}
              </div>
            )}
          </div>,
          document.body
        )}

      <SubmissionModal
        open={submissionModalOpen}
        title="Sfida pianificata"
        description={"Pronostici e abbinamenti salvati.\nPotrai modificarli fino al lock ufficiale."}
        primaryLabel="Vai ai Punti Puri"
        secondaryLabel="Vai a Fantacalcio"
        onPrimary={() => router.push(`/leghe/${leagueId}/giornata`)}
        onSecondary={() => router.push(`/leghe/${leagueId}/fantacalcio`)}
        onClose={() => setSubmissionModalOpen(false)}
      />
    </main>
  );
}
