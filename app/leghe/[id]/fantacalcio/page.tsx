"use client";


import { getMyLeagueIdentity } from "../../../../lib/league-identity/client";
import { useEffect, useMemo, useRef, useState, type TouchEvent } from "react";
import { useParams, useRouter } from "next/navigation";
import HamburgerDrawer from "../../../../components/app/HamburgerDrawer";
import SubmissionModal from "../../../../components/app/SubmissionModal";
import StrategyAvailabilityModal from "../../../../components/app/StrategyAvailabilityModal";
import RoundSubmissionButton from "../../../../components/app/RoundSubmissionButton";
import TeamCrest from "../../../../components/app/TeamCrest";
import FantaGolModeIcon from "../../../../components/app/FantaGolModeIcon";
import KitPreview from "../../../../components/club/KitPreview";
import { supabase } from "../../../../lib/supabaseClient";
import { leaguePath } from "../../../../lib/navigation/league-paths";
import ClubAvatar from "@/components/app/ClubAvatar";
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

type CanonicalMatchupRow = {
  fixture_id: string;
  mode: "fantacalcio" | "one_to_one";
  current_member_id: string;
  opponent_member_id: string | null;
  opponent_display_name: string | null;
  is_bye: boolean;
};

type CanonicalSwipeFixtureRow = {
  id: string;
  schedule_version_id: string;
  league_id: string;
  league_round_id: string;
  mode: string;
  pairing_round_number: number;
  home_member_id: string;
  away_member_id: string | null;
  is_bye: boolean;
};

type CanonicalSwipeScreen = {
  fixtureId: string;
  pairingRoundNumber: number;
  isBye: boolean;
  isCurrentUser: boolean;
  currentMemberId: string | null;
  homeMemberId: string;
  awayMemberId: string | null;
  homeMember: CanonicalLeagueMemberRow | null;
  awayMember: CanonicalLeagueMemberRow | null;
};
type CanonicalLeagueMemberRow = {
  membership_id: string;
  display_name: string | null;
  club_name: string | null;
  motto: string | null;
  avatar_url: string | null;
  crest_url: string | null;
  avatar_zoom: number | string | null;
  avatar_x: number | string | null;
  avatar_y: number | string | null;
  kit_template: string | null;
  kit_primary_color: string | null;
  kit_secondary_color: string | null;
  kit_third_color: string | null;
  kit_logo_mode: string | null;
  kit_crest_position: string | null;
  stars_count: number | null;
};
type ClubInfo = {
  name: string;
  motto?: string | null;
  crest_url: string | null;
  avatar_zoom: number;
  avatar_x: number;
  avatar_y: number;
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
  homeCrestLabel: string;
  awayCrestLabel: string;
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

type R40LivePredictionResult = {
  league_member_id: string;
  match_id: string;
  home_prediction: number | null;
  away_prediction: number | null;
  missing?: boolean | null;
  is_exact?: boolean | null;
  is_sign?: boolean | null;
  is_over_under?: boolean | null;
  is_goal_no_goal?: boolean | null;
  is_surprise?: boolean | null;
  is_goal_show?: boolean | null;
  is_grand_slam?: boolean | null;
  is_cantonata?: boolean | null;
  is_opposite_sign?: boolean | null;
};

type R40LivePointsMember = {
  league_member_id: string;
  pure_points?: number | string | null;
};

type R40LiveStrategy = {
  strategy_id: string;
  league_member_id: string;
  league_fixture_id: string;
  mode: "fantacalcio" | "one_to_one";
  payload?: {
    allocations?: Array<{
      match_id: string;
      department: "attack" | "defense";
    }>;
    pairings?: Array<{
      position: number;
      own_match_id: string;
      opponent_match_id: string;
    }>;
  } | null;
};

type R40FantacalcioContribution = {
  match_id: string;
  department: "attack" | "defense";
  points?: number | string | null;
  provisional?: boolean | null;
};

type R40FantacalcioFixtureSide = {
  member_id: string;
  display_name?: string | null;
  strategy_id?: string | null;
  strategy_valid?: boolean | null;
  strategy_version?: number | null;
  points?: number | string | null;
  goals?: number | string | null;
  contributions?: R40FantacalcioContribution[];
};

type R40FantacalcioFixture = {
  fixture_id: string;
  fixture_phase?: string | null;
  status?: string | null;
  is_bye?: boolean | null;
  home: R40FantacalcioFixtureSide;
  away: R40FantacalcioFixtureSide | null;
  result?: {
    authority?: "normal" | "single_forfeit" | "double_forfeit" | string | null;
    winner?: "home" | "away" | null;
    home_goals?: number | string | null;
    away_goals?: number | string | null;
  } | null;
  forfeit?: {
    type?: "single" | "double" | string | null;
    winner?: "home" | "away" | null;
    home_score?: string | null;
    away_score?: string | null;
    home_outcome?: string | null;
    away_outcome?: string | null;
  } | null;
};

type R40OneToOneMiniChallenge = {
  position: number;
  own_match_id: string;
  opponent_match_id: string;
  result?: string | null;
};

type R40OneToOneMatrix = {
  owner_member_id: string;
  strategy_id?: string | null;
  strategy_version?: number | null;
  home_wins?: number | null;
  away_wins?: number | null;
  draws?: number | null;
  mini_challenges?: R40OneToOneMiniChallenge[];
};

type R40OneToOneFixture = {
  fixture_id: string;
  fixture_phase?: string | null;
  status?: string | null;
  is_bye?: boolean | null;
  home_member_id: string;
  away_member_id: string | null;
  home?: {
    member_id: string;
    display_name?: string | null;
  } | null;
  away?: {
    member_id: string;
    display_name?: string | null;
  } | null;
  aggregate?: {
    home_wins?: number | null;
    away_wins?: number | null;
    draws?: number | null;
    winner?: string | null;
  } | null;
  matrix_home?: R40OneToOneMatrix | null;
  matrix_away?: R40OneToOneMatrix | null;
};

type R40LeagueLiveFrontendProjection = {
  simulation_id: string;
  simulation_version: number;
  simulation_status: string;

  points_preview?: {
    members?: R40LivePointsMember[];
    prediction_results?: R40LivePredictionResult[];
  } | null;

  fantacalcio_preview?: {
    fixtures?: R40FantacalcioFixture[];
  } | null;

  one_to_one_preview?: {
    fixtures?: R40OneToOneFixture[];
  } | null;

  ui_snapshot?: {
    strategies_live?: R40LiveStrategy[];
  } | null;
};

function r40LivePrediction(
  row: R40LivePredictionResult | null | undefined,
) {
  if (
    !row ||
    row.home_prediction === null ||
    row.away_prediction === null
  ) {
    return "—";
  }

  return `${row.home_prediction}-${row.away_prediction}`;
}

function r40LiveRuleKeys(
  row: R40LivePredictionResult | null | undefined,
) {
  if (!row) return [] as string[];

  const active: string[] = [];

  if (row.is_exact) active.push("exact");
  if (row.is_sign) active.push("sign");
  if (row.is_over_under) active.push("uo");
  if (row.is_goal_no_goal) active.push("gg");
  if (row.is_surprise) active.push("surprise");
  if (row.is_goal_show) active.push("show");
  if (row.is_grand_slam) active.push("slam");
  if (row.is_cantonata) active.push("bad");
  if (row.is_opposite_sign) active.push("opposite");

  return active;
}

function r40LiveNumber(
  value: number | string | null | undefined,
) {
  if (typeof value === "number") {
    return Number.isFinite(value) ? value : 0;
  }

  if (typeof value === "string") {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : 0;
  }

  return 0;
}

function r40IsRecoveryMember(
  memberId: string | null | undefined,
  results: R40LivePredictionResult[],
) {
  if (!memberId) return false;

  const memberResults = results.filter(
    (result) =>
      result.league_member_id === memberId,
  );

  return (
    memberResults.length === 10 &&
    memberResults.every(
      (result) => result.missing === true,
    )
  );
}


const ruleItems: RuleItem[] = [
  {
    key: "exact",
    label: "Exact",
    short: "EX",
    points: "+6",
    icon: "◎",
    tone: "muted",
  },
  {
    key: "sign",
    label: "Segno",
    short: "1X2",
    points: "+3",
    icon: "✓",
    tone: "green",
  },
  {
    key: "uo",
    label: "Over/Under",
    short: "U/O",
    points: "+1",
    icon: "%",
    tone: "muted",
  },
  {
    key: "gg",
    label: "Gol/NoGol",
    short: "G/NG",
    points: "+1",
    icon: "▣",
    tone: "green",
  },
  {
    key: "surprise",
    label: "Sorpresa",
    short: "SOR",
    points: "+2",
    icon: "☆",
    tone: "orange",
  },
  {
    key: "show",
    label: "Gol Show",
    short: "SHOW",
    points: "+1",
    icon: "✴",
    tone: "orange",
  },
  {
    key: "slam",
    label: "Grande Slam",
    short: "SLAM",
    points: "+1",
    icon: "◇",
    tone: "violet",
  },
  {
    key: "bad",
    label: "Cantonata",
    short: "CAN",
    points: "-2",
    icon: "×",
    tone: "red",
  },
  {
    key: "opposite",
    label: "Segno opposto",
    short: "OPP",
    points: "-1",
    icon: "↔",
    tone: "red",
  },
];

function TeamBadge({
  label,
  crestReference,
  logoUrl,
}: {
  label: string;
  crestReference?: string | null;
  logoUrl?: string | null;
}) {
  return (
    <TeamCrest
      crestReference={crestReference}
      logoUrl={logoUrl}
      alt={`${label} stemma`}
      fallbackLabel={label}
      size="xs"
      className="sm:h-8 sm:w-8 lg:h-11 lg:w-11"
    />
  );
}

function Avatar({
  name,
  avatarUrl,
  avatarZoom = 1,
  avatarX = 0,
  avatarY = 0,
  disabled = false,
}: {
  name: string;
  avatarUrl?: string | null;
  avatarZoom?: number;
  avatarX?: number;
  avatarY?: number;
  disabled?: boolean;
}) {
  return (
    <ClubAvatar
      src={avatarUrl}
      alt={name}
      fallbackLabel={name}
      zoom={avatarZoom}
      x={avatarX}
      y={avatarY}
      className={`h-12 w-12 min-[380px]:h-[52px] min-[380px]:w-[52px] shrink-0 border text-xl shadow-xl shadow-black/40 sm:h-20 sm:w-20 sm:text-3xl ${
        disabled
          ? "border-white/5 opacity-30"
          : "border-white/15"
      }`}
      imageClassName={disabled ? "grayscale saturate-0" : ""}
    />
  );
}

function ClubKitMini({
  club,
  align = "left",
}: {
  club: ClubInfo | null;
  align?: "left" | "right";
}) {
  const name =
    club?.name || (align === "right" ? "Avversario" : "Club FantaGol");
  const motto =
    club?.motto || "Il tuo Club FantaGol sta per iniziare la sua storia.";

  return (
    <div
      className={`flex min-w-0 items-center gap-3 ${align === "right" ? "flex-row-reverse text-right" : "text-left"}`}
    >
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

function RuleIcon({
  item,
  active = false,
  compact = false,
}: {
  item: RuleItem;
  active?: boolean;
  compact?: boolean;
}) {
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
        <p className="text-[10px] font-black uppercase tracking-[0.12em] text-white sm:text-sm">
          Bonus/Malus
        </p>
        <p className="hidden text-[9px] font-bold uppercase text-gray-500 sm:block sm:text-xs">
          Legenda punteggi
        </p>
      </div>
      <div className="grid grid-cols-9 gap-1 sm:gap-2">
        {ruleItems.map((item) => (
          <div
            key={item.key}
            className="flex min-w-0 flex-col items-center justify-center rounded-xl border border-white/5 bg-black/20 px-0.5 py-1.5 sm:px-2 sm:py-2"
          >
            <RuleIcon item={item} active compact />
            <p className="mt-1 max-w-full truncate text-[7px] font-black uppercase text-gray-300 sm:text-[9px]">
              {item.short}
            </p>
            <p
              className={`text-[9px] font-black sm:text-xs ${item.points.startsWith("-") ? "text-red-400" : item.tone === "orange" ? "text-orange-300" : item.tone === "violet" ? "text-violet-300" : "text-[#A6E824]"}`}
            >
              {item.points}
            </p>
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
  homeName,
  awayName,
}: {
  score: string;
  active: string[];
  side: Side;
  homeName: string;
  awayName: string;
}) {
  const activeKeys = new Set(active);
  const [homeScore = "—", awayScore = "—"] =
    score === "—" ? ["—", "—"] : score.split("-");

  return (
    <div
      className={`flex min-w-0 flex-col items-center ${
        side === "left" ? "sm:items-start" : "sm:items-end"
      }`}
    >
      <div className="grid w-full min-w-0 grid-cols-[minmax(0,1fr)_auto_auto_auto_minmax(0,1fr)] items-center gap-0.5 sm:gap-1">
        <span className="min-w-0 truncate text-right text-[9px] font-black uppercase text-gray-400 sm:text-xs">
          {homeName}
        </span>

        <span className="text-lg font-black leading-none text-white sm:text-3xl">
          {homeScore}
        </span>

        <span className="px-0.5 text-base font-black leading-none text-gray-500 sm:px-1 sm:text-2xl">
          -
        </span>

        <span className="text-lg font-black leading-none text-white sm:text-3xl">
          {awayScore}
        </span>

        <span className="min-w-0 truncate text-left text-[9px] font-black uppercase text-gray-400 sm:text-xs">
          {awayName}
        </span>
      </div>

      <div className="mt-1 grid grid-cols-5 gap-0.5 sm:mt-3 sm:flex sm:gap-1.5">
        {ruleItems.slice(0, 5).map((item) => (
          <RuleIcon
            key={item.key}
            item={item}
            active={activeKeys.has(item.key)}
            compact
          />
        ))}
      </div>

      <div className="mt-0.5 grid grid-cols-4 gap-0.5 sm:mt-1 sm:flex sm:gap-1.5">
        {ruleItems.slice(5).map((item) => (
          <RuleIcon
            key={item.key}
            item={item}
            active={activeKeys.has(item.key)}
            compact
          />
        ))}
      </div>
    </div>
  );
}

type SwapIndicatorState =
  | "idle"
  | "selected"
  | "candidate"
  | "disabled";

type SwapIndicatorTone = "red" | "green";

function SwapIndicator({
  state,
  tone,
}: {
  state: SwapIndicatorState;
  tone: SwapIndicatorTone;
}) {
  const active = state === "selected";
  const candidate = state === "candidate";
  const disabled = state === "disabled";
  const redTone = tone === "red";

  const activeClasses = redTone
    ? "border-red-300/90 bg-gradient-to-br from-red-300 via-red-500 to-red-900 text-white shadow-[inset_0_2px_3px_rgba(255,255,255,0.48),inset_0_-4px_6px_rgba(69,10,10,0.75),0_4px_0_rgba(69,10,10,0.92),0_7px_14px_rgba(239,68,68,0.45)]"
    : "border-[#d9ff7a]/90 bg-gradient-to-br from-[#e5ff9d] via-[#A6E824] to-[#456b08] text-[#101806] shadow-[inset_0_2px_3px_rgba(255,255,255,0.58),inset_0_-4px_6px_rgba(38,61,5,0.72),0_4px_0_rgba(38,61,5,0.95),0_7px_14px_rgba(166,232,36,0.42)]";

  const candidateClasses = redTone
    ? "border-red-400/85 bg-gradient-to-br from-red-300/90 via-red-500/85 to-red-900/90 text-white shadow-[inset_0_2px_3px_rgba(255,255,255,0.38),inset_0_-4px_6px_rgba(69,10,10,0.65),0_3px_0_rgba(69,10,10,0.88),0_0_18px_rgba(239,68,68,0.48)] motion-safe:animate-pulse"
    : "border-[#d9ff7a]/85 bg-gradient-to-br from-[#e5ff9d]/90 via-[#A6E824]/90 to-[#456b08]/95 text-[#101806] shadow-[inset_0_2px_3px_rgba(255,255,255,0.46),inset_0_-4px_6px_rgba(38,61,5,0.68),0_3px_0_rgba(38,61,5,0.9),0_0_18px_rgba(166,232,36,0.46)] motion-safe:animate-pulse";

  const pingClasses = redTone
    ? "border-red-400/45"
    : "border-[#A6E824]/45";

  return (
    <span
      className={`relative flex h-[22px] w-[22px] min-[370px]:h-[25px] min-[370px]:w-[25px] min-[390px]:h-[27px] min-[390px]:w-[27px] translate-y-[8px] items-center justify-center rounded-full border transition-all duration-200 sm:h-9 sm:w-9 ${
        active
          ? activeClasses
          : candidate
            ? candidateClasses
            : disabled
              ? "border-white/5 bg-gradient-to-br from-gray-700/30 to-black/50 text-gray-700 opacity-20 shadow-[inset_0_1px_2px_rgba(255,255,255,0.05)]"
              : "border-white/20 bg-gradient-to-br from-gray-400/25 via-gray-700/25 to-black/50 text-gray-300 opacity-55 shadow-[inset_0_2px_2px_rgba(255,255,255,0.12),inset_0_-3px_5px_rgba(0,0,0,0.6),0_3px_0_rgba(0,0,0,0.65),0_5px_10px_rgba(0,0,0,0.38)]"
      }`}
      aria-hidden="true"
    >
      <svg
        viewBox="0 0 32 32"
        className="h-[14px] w-[14px] min-[370px]:h-4 min-[370px]:w-4 min-[390px]:h-[18px] min-[390px]:w-[18px] drop-shadow-[0_1px_1px_rgba(0,0,0,0.55)] sm:h-5 sm:w-5"
        fill="currentColor"
      >
        <path d="M25.3 8.2a11.2 11.2 0 0 0-16.8-1L6.2 4.9a1.35 1.35 0 0 0-2.3.96v7.02c0 .75.6 1.35 1.35 1.35h7.02a1.35 1.35 0 0 0 .96-2.3l-2.4-2.4a7.95 7.95 0 0 1 11.73.77 1.65 1.65 0 1 0 2.74-2.1Z" />
        <path d="M26.75 17.77h-7.02a1.35 1.35 0 0 0-.96 2.3l2.4 2.4a7.95 7.95 0 0 1-11.73-.77 1.65 1.65 0 1 0-2.74 2.1 11.2 11.2 0 0 0 16.8 1l2.3 2.3a1.35 1.35 0 0 0 2.3-.96v-7.02c0-.75-.6-1.35-1.35-1.35Z" />
      </svg>

      <span className="pointer-events-none absolute inset-[3px] rounded-full border border-white/15" />

      {candidate && (
        <span
          className={`absolute inset-[-6px] rounded-full border ${pingClasses} motion-safe:animate-ping`}
        />
      )}
    </span>
  );
}

function r40FantacalcioContributionPoints(
  side: R40FantacalcioFixtureSide | null | undefined,
  matchId: string,
) {
  if (side?.strategy_valid !== true) return "—";

  const contribution =
    side.contributions?.find(
      (candidate) => candidate.match_id === matchId,
    ) ?? null;

  return contribution
    ? String(r40LiveNumber(contribution.points))
    : "—";
}

function LiveResultPointsCard({
  match,
  points,
  side,
}: {
  match: DuelMatch;
  points: string;
  side: Side;
}) {
  const score =
    Number.isFinite(match.liveHome) &&
    Number.isFinite(match.liveAway)
      ? `${match.liveHome}-${match.liveAway}`
      : "—";

  const matchPhase = match.minute.trim().toUpperCase();
  const isFinished = matchPhase === "FT";
  const isLive =
    /^\d{1,3}'?$/.test(matchPhase) ||
    ["LIVE", "HT", "1H", "2H", "ET", "BT", "P"].includes(matchPhase);
  const statusLabel = isFinished ? "FT" : isLive ? match.minute : "PM";

  return (
    <div
      className={`relative flex min-w-0 flex-col rounded-xl border bg-black/25 px-1.5 py-1.5 sm:px-2.5 sm:py-2 ${
        isLive
          ? "border-[#A6E824]/70 shadow-[0_0_18px_rgba(166,232,36,0.12)] motion-safe:animate-pulse"
          : "border-white/10"
      } ${
        side === "left" ? "items-center sm:items-end" : "items-center sm:items-start"
      }`}
    >
      <div
        className={`flex w-full min-w-0 items-center gap-1.5 ${
          side === "left" ? "justify-end" : "justify-start"
        }`}
      >
        <span
          className={`shrink-0 text-[9px] font-black uppercase tracking-[0.14em] sm:text-[11px] ${
            isFinished
              ? "text-[#A6E824]"
              : isLive
                ? "text-[#A6E824]"
                : "text-white"
          }`}
        >
          {statusLabel}
        </span>

        <span className="shrink-0 text-sm font-black leading-none text-white sm:text-lg">
          {score}
        </span>
      </div>

      <div
        className={`mt-1 flex w-full items-end gap-1.5 border-t border-white/[0.06] pt-1 ${
          side === "left" ? "justify-end" : "justify-start"
        }`}
      >
        <span className="pb-px text-[8px] font-black uppercase tracking-[0.12em] text-gray-500 sm:text-[10px]">
          PT
        </span>
        <span className="text-base font-black leading-none text-[#A6E824] sm:text-xl">
          {points}
        </span>
      </div>
    </div>
  );
}

function LiveMatchCenter({
  match,
  swapState = "idle",
  swapTone = "green",
}: {
  match: DuelMatch;
  swapState?: SwapIndicatorState;
  swapTone?: SwapIndicatorTone;
}) {
  return (
    <div className="relative grid min-w-0 grid-cols-[minmax(0,1fr)_auto_minmax(70px,auto)_auto_minmax(0,1fr)] items-center gap-x-1 sm:grid-cols-[minmax(0,1fr)_auto_minmax(120px,auto)_auto_minmax(0,1fr)] sm:gap-x-2">
      <span className="col-start-1 row-start-1 min-w-0 truncate text-right text-[9px] font-black uppercase text-gray-300 sm:text-xs">
        {match.home}
      </span>

      <div className="col-start-2 row-start-1">
        <TeamBadge
        label={match.homeCrestLabel}
        crestReference={match.homeCrestReference}
        logoUrl={match.homeLogoUrl}
        />
      </div>

      <div className="pointer-events-none col-span-2 col-start-1 row-start-1 z-10 flex h-full items-end justify-center pr-2 sm:pr-5">
        <SwapIndicator
          state={swapState}
          tone={swapTone}
        />
      </div>

      <div className="col-start-3 row-start-1 flex min-w-0 flex-col items-center px-0.5">
        <span className="rounded-md bg-[#A6E824]/15 px-1.5 py-0.5 text-[9px] font-black leading-none text-[#A6E824] sm:text-xs">
          {match.minute}
        </span>

        <div className="mt-1 flex items-center justify-center gap-1.5 sm:gap-2.5">
          <span className="text-3xl font-black leading-none text-[#A6E824] sm:text-5xl">
            {match.liveHome}
          </span>
          <span className="text-2xl font-black leading-none text-[#A6E824] sm:text-4xl">
            -
          </span>
          <span className="text-3xl font-black leading-none text-white sm:text-5xl">
            {match.liveAway}
          </span>
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

      <div className="col-start-4 row-start-1">
        <TeamBadge
        label={match.awayCrestLabel}
        crestReference={match.awayCrestReference}
        logoUrl={match.awayLogoUrl}
        />
      </div>

      <span className="col-start-5 row-start-1 min-w-0 truncate text-left text-[9px] font-black uppercase text-gray-300 sm:text-xs">
        {match.away}
      </span>
    </div>
  );
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
    .replace(
      /^(?:A\.?\s*C\.?\s*F?\.?|F\.?\s*C\.?|S\.?\s*S\.?\s*C\.?|S\.?\s*S\.?|U\.?\s*S\.?|U\.?\s*C\.?|A\.?\s*S\.?|C\.?\s*F\.?\s*C\.?)\s+/i,
      "",
    )
    .replace(
      /\s+(?:Football Club|Calcio|F\.?\s*C\.?|C\.?\s*F\.?\s*C\.?|B\.?\s*C\.?|S\.?\s*C\.?)$/i,
      "",
    )
    .replace(/\s+(?:19|20)\d{2}$/i, "")
    .trim();
}

function getTeamCode(
  providerShortName: string | null,
  providerFullName: string,
): string {
  const source =
    providerShortName?.trim() || cleanTeamDisplayName(providerFullName);

  return source
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/[^A-Za-z]/g, "")
    .slice(0, 3)
    .toUpperCase();
}


function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function findNestedRecord(
  value: unknown,
  predicate: (record: Record<string, unknown>) => boolean,
): Record<string, unknown> | null {
  if (Array.isArray(value)) {
    for (const item of value) {
      const found = findNestedRecord(item, predicate);
      if (found) return found;
    }
    return null;
  }

  if (!isRecord(value)) return null;
  if (predicate(value)) return value;

  for (const nested of Object.values(value)) {
    const found = findNestedRecord(nested, predicate);
    if (found) return found;
  }

  return null;
}

function toFiniteNumber(value: unknown): number {
  const numeric = typeof value === "number" ? value : Number(value);
  return Number.isFinite(numeric) ? numeric : 0;
}

function isMissingActiveFixtureError(message?: string | null) {
  return Boolean(message?.includes("STRATEGY_ACTIVE_FIXTURE_NOT_FOUND"));
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
  const [canonicalSwipeScreens, setCanonicalSwipeScreens] = useState<
    CanonicalSwipeScreen[]
  >([]);
  const [opponentClubInfo, setOpponentClubInfo] = useState<ClubInfo | null>(
    null,
  );
  const [leagueRoundId, setLeagueRoundId] = useState<string | null>(null);
  const [roundNumber, setRoundNumber] = useState<number | null>(null);
  const [strategyExists, setStrategyExists] = useState(false);
  const [hasOfficialSubmission, setHasOfficialSubmission] = useState(false);
  const [hasUnconfirmedChanges, setHasUnconfirmedChanges] = useState(false);
  const [strategyLocked, setStrategyLocked] = useState(false);

  const [strategySubmittable, setStrategySubmittable] = useState(false);
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
  const [
    leagueLiveProjection,
    setLeagueLiveProjection,
  ] = useState<R40LeagueLiveFrontendProjection | null>(
    null,
  );
  const [leftPoints, setLeftPoints] = useState(0);
  const [rightPoints, setRightPoints] = useState(0);
  const [leftGoals, setLeftGoals] = useState(0);
  const [rightGoals, setRightGoals] = useState(0);

  const [strategyPendingSchedule, setStrategyPendingSchedule] = useState(false);
  const [strategyAvailabilityModalOpen, setStrategyAvailabilityModalOpen] = useState(false);

  useEffect(() => {
    async function loadLeagueInfo() {
      const { data, error } = await supabase.rpc("get_my_leagues_rpc");
      if (error) return;

      const current = ((data || []) as MyLeagueRpcRow[]).find(
        (row) => row.league_id === leagueId,
      );
      if (!current) return;

      setLeagueInfo({
        name: current.league_name || "Lega FantaGol",
        displayName: current.display_name || "Club FantaGol",
        inviteCode: current.invite_code || leagueId,
        role: current.role || "member",
      });


      const identity = await getMyLeagueIdentity(
        supabase,
        leagueId,
      );

      setLeagueInfo({
        name: current.league_name || "Lega FantaGol",
        displayName:
          identity.display_name ||
          current.display_name ||
          "Club FantaGol",
        inviteCode: current.invite_code || leagueId,
        role:
          identity.membership_role ||
          current.role ||
          "member",
      });

      const currentClub = {
        name:
          identity.club_name ||
          identity.display_name ||
          current.display_name ||
          "Club FantaGol",
        motto: identity.motto || null,
        crest_url:
          identity.crest_url ||
          identity.avatar_url ||
          null,
        avatar_zoom:
          Number(identity.avatar_zoom || 1),
        avatar_x:
          Number(identity.avatar_x || 0),
        avatar_y:
          Number(identity.avatar_y || 0),
        kit_template:
          identity.kit_template || "solid",
        kit_primary_color:
          identity.kit_primary_color || "#FFFFFF",
        kit_secondary_color:
          identity.kit_secondary_color || "#111417",
        kit_third_color:
          identity.kit_third_color || "#A6E824",
        kit_logo_mode:
          identity.kit_logo_mode ||
          "center_horizontal",
        kit_crest_position:
          identity.kit_crest_position ||
          "left_chest",
        stars_count: identity.stars_count || 0,
      };

      setClubInfo(currentClub);
      setOpponentClubInfo(null);

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
        { p_league_id: leagueId },
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
        { data: previewData },
      ] = await Promise.all([
        supabase.rpc("get_my_round_predictions_rpc", {
          p_league_round_id: currentLeagueRoundId,
        }),
        supabase.rpc("get_my_strategy_status_rpc", {
          p_league_round_id: currentLeagueRoundId,
          p_mode: "fantacalcio",
        }),
        supabase.rpc("get_my_fantacalcio_preview_rpc", {
          p_league_round_id: currentLeagueRoundId,
        }),
      ]);

      if (cancelled) return;

      if (predictionError) {
        setStrategyError(predictionError.message);
        setStrategyLoading(false);
        return;
      }

      if (strategyStatusError) {
        if (isMissingActiveFixtureError(strategyStatusError.message)) {
          setStrategyPendingSchedule(true);
          setStrategyError(null);
          setStrategyExists(false);
          setHasOfficialSubmission(false);
          setHasUnconfirmedChanges(false);
        } else {
          setStrategyPendingSchedule(false);
          setStrategyError(strategyStatusError.message);
          setStrategyLoading(false);
          return;
        }
      } else {
        setStrategyPendingSchedule(false);
      }

      const { data: matchupData, error: matchupError } =
        await supabase.rpc("get_my_dashboard_matchups_rpc", {
          p_league_round_id: currentLeagueRoundId,
        });

      if (matchupError) {
        setStrategyError(matchupError.message);
        setStrategyLoading(false);
        return;
      }

      const canonicalMatchup =
        ((matchupData || []) as CanonicalMatchupRow[]).find(
          (row) => row.mode === "fantacalcio",
        ) || null;

      if (canonicalMatchup?.opponent_member_id) {
        const [
          { data: memberData, error: memberError },
          { data: scheduleData, error: scheduleError },
        ] = await Promise.all([
          supabase.rpc("get_current_league_members_v2_rpc", {
            target_league_id: leagueId,
          }),
          supabase
            .from("league_schedule_versions")
            .select("id")
            .eq("league_id", leagueId)
            .eq("active", true)
            .order("version", { ascending: false })
            .limit(1)
            .maybeSingle(),
        ]);

        if (scheduleError) {
          setStrategyError(scheduleError.message);
          setStrategyLoading(false);
          return;
        }

        if (memberError) {
          setStrategyError(memberError.message);
          setStrategyLoading(false);
          return;
        }

        const members =
          (memberData || []) as CanonicalLeagueMemberRow[];

        if (!scheduleData?.id) {
          setCanonicalSwipeScreens([]);
        } else {
          const { data: fixtureData, error: fixtureError } =
            await supabase
              .from("league_fixtures")
              .select(
                "id,schedule_version_id,league_id,league_round_id,mode,pairing_round_number,home_member_id,away_member_id,is_bye",
              )
              .eq("schedule_version_id", scheduleData.id)
              .eq("league_round_id", currentLeagueRoundId)
              .eq("mode", "fantacalcio")
              .order("pairing_round_number", { ascending: true })
              .order("id", { ascending: true });

          if (fixtureError) {
            setStrategyError(fixtureError.message);
            setStrategyLoading(false);
            return;
          }

          const memberById = new Map(
            members.map((member) => [
              member.membership_id,
              member,
            ]),
          );

          const currentMemberId =
            canonicalMatchup?.current_member_id || null;

          const screens =
            ((fixtureData || []) as CanonicalSwipeFixtureRow[])
              .map((fixture) => ({
                fixtureId: fixture.id,
                pairingRoundNumber:
                  fixture.pairing_round_number,
                isBye: fixture.is_bye,
                isCurrentUser: Boolean(
                  currentMemberId &&
                    (fixture.home_member_id === currentMemberId ||
                      fixture.away_member_id === currentMemberId),
                ),
                currentMemberId,
                homeMemberId: fixture.home_member_id,
                awayMemberId: fixture.away_member_id,
                homeMember:
                  memberById.get(fixture.home_member_id) || null,
                awayMember: fixture.away_member_id
                  ? memberById.get(fixture.away_member_id) || null
                  : null,
              }))
              .sort((left, right) => {
                if (left.isCurrentUser !== right.isCurrentUser) {
                  return left.isCurrentUser ? -1 : 1;
                }

                if (
                  left.pairingRoundNumber !==
                  right.pairingRoundNumber
                ) {
                  return (
                    left.pairingRoundNumber -
                    right.pairingRoundNumber
                  );
                }

                return left.fixtureId.localeCompare(
                  right.fixtureId,
                );
              });

          setCanonicalSwipeScreens(screens);
        }
        const opponentMember =
          ((memberData || []) as CanonicalLeagueMemberRow[]).find(
            (member) =>
              member.membership_id ===
              canonicalMatchup.opponent_member_id,
          ) || null;

        if (!opponentMember) {
          setStrategyError(
            "L'avversario della giornata non è presente tra i membri attivi della lega.",
          );
          setStrategyLoading(false);
          return;
        }

        setOpponentClubInfo({
          name:
            opponentMember.club_name ||
            opponentMember.display_name ||
            canonicalMatchup.opponent_display_name ||
            "Avversario",
          motto: opponentMember.motto || null,
          crest_url:
            opponentMember.crest_url ||
            opponentMember.avatar_url ||
            null,
          avatar_zoom: Number(opponentMember.avatar_zoom || 1),
          avatar_x: Number(opponentMember.avatar_x || 0),
          avatar_y: Number(opponentMember.avatar_y || 0),
          kit_template:
            opponentMember.kit_template || "solid",
          kit_primary_color:
            opponentMember.kit_primary_color || "#FFFFFF",
          kit_secondary_color:
            opponentMember.kit_secondary_color || "#111417",
          kit_third_color:
            opponentMember.kit_third_color || "#A6E824",
          kit_logo_mode:
            opponentMember.kit_logo_mode ||
            "center_horizontal",
          kit_crest_position:
            opponentMember.kit_crest_position ||
            "left_chest",
          stars_count:
            opponentMember.stars_count || 0,
        });
      } else {
        setOpponentClubInfo(null);
      }

      const rows = (predictionData || []) as RoundPredictionRow[];
      if (rows.length !== 10) {
        setStrategyError(
          "La giornata Fantacalcio deve contenere esattamente 10 partite.",
        );
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

          const homeName = getTeamCode(
            row.home_team_short_name,
            row.home_team_name,
          );
          const awayName = getTeamCode(
            row.away_team_short_name,
            row.away_team_name,
          );
          const homeCrestLabel = cleanTeamDisplayName(row.home_team_name);
          const awayCrestLabel = cleanTeamDisplayName(row.away_team_name);

          return {
            id: row.match_id,
            slotNumber: row.slot_number,
            home: homeName,
            away: awayName,
            homeCrestLabel,
            awayCrestLabel,
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

      const strategyStatus = ((strategyData || [])[0] ||
        null) as StrategyStatusRow | null;
      let orderedRows = baseRows;

      if (strategyStatus?.workspace_payload) {
        try {
          const restored = fromFantacalcioStrategyPayload(
            strategyStatus.workspace_payload,
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
          setStrategyError(
            "La strategia salvata non è compatibile con il formato corrente.",
          );
        }
      }

      const preview = findNestedRecord(
        previewData,
        (record) => "home_goals" in record && "away_goals" in record,
      );
      setLeftGoals(toFiniteNumber(preview?.home_goals));
      setRightGoals(toFiniteNumber(preview?.away_goals));
      setLeftPoints(toFiniteNumber(preview?.home_points));
      setRightPoints(toFiniteNumber(preview?.away_points));

      setLeagueRoundId(currentLeagueRoundId);
      setRoundNumber(rows[0]?.round_number ?? null);
      setIsByeRound(Boolean(strategyStatus?.is_bye));
      setLiveRows(orderedRows);
      setStrategyExists(Boolean(strategyStatus?.strategy_exists));
      setHasOfficialSubmission(Boolean(strategyStatus?.has_official_snapshot));
      setHasUnconfirmedChanges(
        Boolean(strategyStatus?.has_unconfirmed_changes),
      );
      setStrategyLocked(strategyStatus?.is_editable !== true);
      setStrategySubmittable(strategyStatus?.is_submittable === true);
      setStrategyLoading(false);
    }

    void loadFantacalcioStrategy();

    return () => {
      cancelled = true;
    };
  }, [leagueId]);

  const locked = strategyLocked;
  const isLiveForSwipe = strategyLocked;
      const swipeProfiles = canonicalSwipeScreens.map((screen) => {
    const currentUserIsAway = Boolean(
      screen.isCurrentUser &&
        screen.currentMemberId &&
        screen.awayMemberId === screen.currentMemberId,
    );

    const leftMember = currentUserIsAway
      ? screen.awayMember
      : screen.homeMember;

    const rightMember = currentUserIsAway
      ? screen.homeMember
      : screen.awayMember;

    const leftClub: ClubInfo = {
      name:
        leftMember?.club_name ||
        leftMember?.display_name ||
        "Club FantaGol",
      motto: leftMember?.motto || null,
      crest_url:
        leftMember?.crest_url ||
        leftMember?.avatar_url ||
        null,
      avatar_zoom: Number(leftMember?.avatar_zoom || 1),
      avatar_x: Number(leftMember?.avatar_x || 0),
      avatar_y: Number(leftMember?.avatar_y || 0),
      kit_template: leftMember?.kit_template || "solid",
      kit_primary_color:
        leftMember?.kit_primary_color || "#FFFFFF",
      kit_secondary_color:
        leftMember?.kit_secondary_color || "#111417",
      kit_third_color:
        leftMember?.kit_third_color || "#A6E824",
      kit_logo_mode:
        leftMember?.kit_logo_mode || "center_horizontal",
      kit_crest_position:
        leftMember?.kit_crest_position || "left_chest",
      stars_count: leftMember?.stars_count || 0,
    };

    const rightClub: ClubInfo | null = screen.isBye
      ? null
      : {
          name:
            rightMember?.club_name ||
            rightMember?.display_name ||
            "Club FantaGol",
          motto: rightMember?.motto || null,
          crest_url:
            rightMember?.crest_url ||
            rightMember?.avatar_url ||
            null,
          avatar_zoom: Number(rightMember?.avatar_zoom || 1),
          avatar_x: Number(rightMember?.avatar_x || 0),
          avatar_y: Number(rightMember?.avatar_y || 0),
          kit_template:
            rightMember?.kit_template || "solid",
          kit_primary_color:
            rightMember?.kit_primary_color || "#FFFFFF",
          kit_secondary_color:
            rightMember?.kit_secondary_color || "#111417",
          kit_third_color:
            rightMember?.kit_third_color || "#A6E824",
          kit_logo_mode:
            rightMember?.kit_logo_mode || "center_horizontal",
          kit_crest_position:
            rightMember?.kit_crest_position || "left_chest",
          stars_count: rightMember?.stars_count || 0,
        };

    return {
      id: screen.fixtureId,
      isCurrentUser: screen.isCurrentUser,

      clubName: leftClub.name,
      motto: leftClub.motto,
      avatarUrl: leftClub.crest_url,
      avatarZoom: leftClub.avatar_zoom,
      avatarX: leftClub.avatar_x,
      avatarY: leftClub.avatar_y,
      kitTemplate: leftClub.kit_template,
      kitPrimaryColor: leftClub.kit_primary_color,
      kitSecondaryColor: leftClub.kit_secondary_color,
      kitThirdColor: leftClub.kit_third_color,
      kitLogoMode: leftClub.kit_logo_mode,
      kitCrestPosition: leftClub.kit_crest_position,
      starsCount: leftClub.stars_count,

      leftClub,
      rightClub,
      fixture: screen,
    };
  });
  const activeProfile =
    swipeProfiles[Math.min(activeSwipeIndex, swipeProfiles.length - 1)];

  const isFirstProfile = activeSwipeIndex === 0;
  const isLastProfile =
    activeSwipeIndex === swipeProfiles.length - 1;

  const isViewingSelf =
    activeProfile?.isCurrentUser === true;

  const interactionLocked =
    strategyLocked || !isViewingSelf || (isViewingSelf && isByeRound);

  const viewedIsByeRound =
    activeProfile?.fixture.isBye === true;

  const viewedClubInfo: ClubInfo =
    activeProfile?.leftClub || {
      name: "Club FantaGol",
      motto: null,
      crest_url: null,
      avatar_zoom: 1,
      avatar_x: 0,
      avatar_y: 0,
      kit_template: "solid",
      kit_primary_color: "#FFFFFF",
      kit_secondary_color: "#111417",
      kit_third_color: "#A6E824",
      kit_logo_mode: "center_horizontal",
      kit_crest_position: "left_chest",
      stars_count: 0,
    };

  const viewedOpponentClubInfo: ClubInfo | null =
    activeProfile?.rightClub || null;

  const canViewProfileContent = isViewingSelf || isLiveForSwipe;

  useEffect(() => {
    let cancelled = false;

    async function loadLeagueLiveProjection() {
      if (!leagueRoundId || !isLiveForSwipe) {
        setLeagueLiveProjection(null);
        return;
      }

      const {
        data,
        error,
      } = await supabase.rpc(
        "get_league_live_frontend_projection_rpc",
        {
          p_league_round_id: leagueRoundId,
        },
      );

      if (cancelled) return;

      if (error) {
        console.error(
          "LIVE_FRONTEND_PROJECTION_ERROR",
          error,
        );

        setLeagueLiveProjection(null);
        return;
      }

      const projection =
        (((data || [])[0] || null) as unknown as
          R40LeagueLiveFrontendProjection | null);

      setLeagueLiveProjection(projection);
    }

    void loadLeagueLiveProjection();

    return () => {
      cancelled = true;
    };
  }, [leagueRoundId, isLiveForSwipe]);


  const r40FantacalcioView = (() => {
    if (
      !isLiveForSwipe ||
      !activeProfile ||
      !leagueLiveProjection
    ) {
      return null;
    }

    const screen = activeProfile.fixture;

    /*
     * currentMemberId is the authenticated league member and is
     * intentionally shared by every fixture screen.
     *
     * LIVE projection needs the member rendered on the LEFT side
     * of this particular swipe screen.
     *
     * Canonical UI orientation:
     * - own fixture: authenticated member is kept on the left;
     * - every other fixture: home member is on the left.
     *
     * Ownership continues to use currentMemberId elsewhere.
     */
    const viewedMemberId =
      screen.isCurrentUser &&
      screen.currentMemberId &&
      screen.awayMemberId === screen.currentMemberId
        ? screen.awayMemberId
        : screen.homeMemberId;

    if (!viewedMemberId) return null;

    const fixture =
      leagueLiveProjection
        .fantacalcio_preview
        ?.fixtures
        ?.find(
          (candidate) =>
            candidate.fixture_id === screen.fixtureId,
        ) ?? null;

    if (!fixture) return null;

    const viewedIsHome =
      fixture.home.member_id === viewedMemberId;

    const leftSide = viewedIsHome
      ? fixture.home
      : fixture.away;

    const rightSide = viewedIsHome
      ? fixture.away
      : fixture.home;

    const opponentMemberId =
      rightSide?.member_id ?? null;

    return {
      fixture,
      viewedMemberId,
      opponentMemberId,
      viewedIsHome,
      leftSide,
      rightSide,
    };
  })();

  /*
   * R53 competitive result authority.
   * Strategy validity continues to govern points/contributions and row
   * transparency. A forfeit, however, is a fixture-level result and must
   * render 3-0 / 0-3 even when the forfeiting side has no valid strategy.
   */
  const fantacalcioForfeitScore = (() => {
    if (!r40FantacalcioView) return null;

    const authority =
      r40FantacalcioView.fixture.result?.authority ?? null;

    if (authority === "single_forfeit") {
      const homeGoals = r40LiveNumber(
        r40FantacalcioView.fixture.result?.home_goals ??
          r40FantacalcioView.fixture.home.goals,
      );
      const awayGoals = r40LiveNumber(
        r40FantacalcioView.fixture.result?.away_goals ??
          r40FantacalcioView.fixture.away?.goals,
      );

      return r40FantacalcioView.viewedIsHome
        ? { left: homeGoals, right: awayGoals }
        : { left: awayGoals, right: homeGoals };
    }

    if (authority === "double_forfeit") {
      // No shared winner exists; backend keeps both technical losses.
      return { left: "—", right: "—" };
    }

    return null;
  })();

  const fantacalcioIsForfeit =
    fantacalcioForfeitScore !== null;

  const displayedLeftPoints = canViewProfileContent
    ? r40FantacalcioView?.leftSide
      ? r40FantacalcioView.leftSide.strategy_valid === true
        ? r40LiveNumber(
            r40FantacalcioView.leftSide.points,
          )
        : "—"
      : isViewingSelf && !isLiveForSwipe
        ? leftPoints
        : "—"
    : "—";

  const displayedRightPoints = canViewProfileContent
    ? r40FantacalcioView?.rightSide
      ? r40FantacalcioView.rightSide.strategy_valid === true
        ? r40LiveNumber(
            r40FantacalcioView.rightSide.points,
          )
        : "—"
      : isViewingSelf && !isLiveForSwipe
        ? rightPoints
        : "—"
    : "—";

  const displayedLeftGoals = fantacalcioForfeitScore
    ? fantacalcioForfeitScore.left
    : canViewProfileContent
      ? r40FantacalcioView?.leftSide
        ? r40FantacalcioView.leftSide.strategy_valid === true
          ? r40LiveNumber(
              r40FantacalcioView.leftSide.goals,
            )
          : "—"
        : isViewingSelf && !isLiveForSwipe
          ? leftGoals
          : "—"
      : "—";

  const displayedRightGoals = fantacalcioForfeitScore
    ? fantacalcioForfeitScore.right
    : canViewProfileContent
      ? r40FantacalcioView?.rightSide
        ? r40FantacalcioView.rightSide.strategy_valid === true
          ? r40LiveNumber(
              r40FantacalcioView.rightSide.goals,
            )
          : "—"
        : isViewingSelf && !isLiveForSwipe
          ? rightGoals
          : "—"
      : "—";

  function completeProfileSwipe(nextIndex: number, direction: "next" | "prev") {
    const bounded = Math.min(Math.max(nextIndex, 0), swipeProfiles.length - 1);
    const viewportWidth =
      typeof window !== "undefined" ? window.innerWidth : 420;
    const exitX = direction === "next" ? -viewportWidth : viewportWidth;
    const enterX =
      direction === "next" ? viewportWidth * 0.30 : -viewportWidth * 0.30;

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
    if (swipeStartXRef.current === null || swipeStartYRef.current === null)
      return;

    const currentX = event.touches[0]?.clientX ?? swipeStartXRef.current;
    const currentY = event.touches[0]?.clientY ?? swipeStartYRef.current;
    const deltaX = currentX - swipeStartXRef.current;
    const deltaY = currentY - swipeStartYRef.current;

    if (!swipeLockRef.current) {
      if (Math.abs(deltaX) < 10 && Math.abs(deltaY) < 10) return;
      swipeLockRef.current =
        Math.abs(deltaX) > Math.abs(deltaY) * 1.25 ? "x" : "y";
    }

    if (swipeLockRef.current !== "x") return;

    if (event.cancelable) {
      event.preventDefault();
    }
    event.stopPropagation();

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
    const wasHorizontalSwipe = swipeLockRef.current === "x";

    if (wasHorizontalSwipe) {
      if (event.cancelable) {
        event.preventDefault();
      }
      event.stopPropagation();
    }

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

  const [selectedMatchIndex, setSelectedMatchIndex] = useState<number | null>(
    null,
  );
  const [submissionModalOpen, setSubmissionModalOpen] = useState(false);

  type FantacalcioDisplayRow = {
    leftMatch: DuelMatch;
    rightMatch: DuelMatch | null;
  };

  const displayedLiveRows: FantacalcioDisplayRow[] = (() => {
    const rowsById =
      new Map(
        liveRows.map(
          (match) => [match.id, match],
        ),
      );

    const neutralRows = () =>
      liveRows.map((match) => ({
        leftMatch: {
          ...match,
          leftPrediction: "—",
          rightPrediction: "—",
          leftActive: [],
          rightActive: [],
        },
        rightMatch: null,
      }));

    /*
     * PRE-LIVE PRIVACY / OWNERSHIP CONTRACT:
     *
     * liveRows is the authenticated member's editable Strategy workspace.
     * It is authoritative only while rendering that member's own card.
     *
     * Other swipe cards must never inherit SELF predictions before LIVE.
     * Until the publication-backed cross-member projection becomes active,
     * those cards remain neutral.
     */
    if (!isLiveForSwipe) {
      return isViewingSelf
        ? liveRows.map((match) => ({
            leftMatch: match,
            rightMatch: match,
          }))
        : neutralRows();
    }

    if (!canViewProfileContent) {
      return neutralRows();
    }

    if (
      !leagueLiveProjection ||
      !r40FantacalcioView
    ) {
      return isViewingSelf
        ? liveRows.map((match) => ({
            leftMatch: match,
            rightMatch: match,
          }))
        : neutralRows();
    }

    const {
      viewedMemberId,
      opponentMemberId,
    } = r40FantacalcioView;

    const results =
      leagueLiveProjection
        .points_preview
        ?.prediction_results ?? [];

    const byMemberAndMatch =
      new Map<string, R40LivePredictionResult>();

    for (const result of results) {
      byMemberAndMatch.set(
        `${result.league_member_id}:${result.match_id}`,
        result,
      );
    }

    const viewedMemberIsRecovery =
      r40IsRecoveryMember(
        viewedMemberId,
        results,
      );

    if (viewedMemberIsRecovery) {
      return neutralRows();
    }

    const strategies =
      leagueLiveProjection
        .ui_snapshot
        ?.strategies_live ?? [];

    const viewedStrategy =
      strategies.find(
        (candidate) =>
          candidate.mode === "fantacalcio" &&
          candidate.league_member_id ===
            viewedMemberId &&
          candidate.league_fixture_id ===
            activeProfile?.fixture.fixtureId,
      ) ?? null;

    const opponentStrategy =
      opponentMemberId
        ? (
            strategies.find(
              (candidate) =>
                candidate.mode === "fantacalcio" &&
                candidate.league_member_id ===
                  opponentMemberId &&
                candidate.league_fixture_id ===
                  activeProfile?.fixture.fixtureId,
            ) ?? null
          )
        : null;

    const viewedAllocations =
      viewedStrategy?.payload?.allocations ?? [];

    const opponentAllocations =
      opponentStrategy?.payload?.allocations ?? [];

    const viewedHasOfficialStrategy =
      r40FantacalcioView.leftSide
        ?.strategy_valid === true &&
      viewedStrategy !== null &&
      viewedAllocations.length === 10;

    const opponentHasOfficialStrategy =
      r40FantacalcioView.rightSide
        ?.strategy_valid === true &&
      opponentStrategy !== null &&
      opponentAllocations.length === 10;

    const allocationIds = (
      allocations: NonNullable<
        NonNullable<R40LiveStrategy["payload"]>["allocations"]
      >,
      department: "attack" | "defense",
    ) =>
      allocations
        .filter(
          (allocation) =>
            allocation.department === department,
        )
        .map((allocation) => allocation.match_id);

    const viewedAttackIds =
      allocationIds(viewedAllocations, "attack");

    const viewedDefenseIds =
      allocationIds(viewedAllocations, "defense");

    const opponentAttackIds =
      allocationIds(opponentAllocations, "attack");

    const opponentDefenseIds =
      allocationIds(opponentAllocations, "defense");

    const viewedHasCompleteAllocation =
      viewedHasOfficialStrategy &&
      viewedAttackIds.length === 5 &&
      viewedDefenseIds.length === 5;

    const opponentHasCompleteAllocation =
      opponentHasOfficialStrategy &&
      opponentAttackIds.length === 5 &&
      opponentDefenseIds.length === 5;

    const neutralOrder =
      liveRows.map((match) => match.id);

    const viewedOrder =
      viewedHasCompleteAllocation
        ? [
            ...viewedAttackIds,
            ...viewedDefenseIds,
          ]
        : neutralOrder;

    const opponentOrder =
      opponentHasCompleteAllocation
        ? [
            ...opponentAttackIds,
            ...opponentDefenseIds,
          ]
        : neutralOrder;

    return viewedOrder
      .map((leftMatchId, index) => {
        const leftBase =
          rowsById.get(leftMatchId);

        if (!leftBase) return null;

        const rightMatchId =
          opponentOrder[index] ?? null;

        const rightBase =
          rightMatchId
            ? rowsById.get(rightMatchId) ?? null
            : null;

        const leftResult =
          viewedHasCompleteAllocation
            ? byMemberAndMatch.get(
                `${viewedMemberId}:${leftMatchId}`,
              )
            : undefined;

        const rightResult =
          opponentHasCompleteAllocation &&
          opponentMemberId &&
          rightMatchId
            ? byMemberAndMatch.get(
                `${opponentMemberId}:${rightMatchId}`,
              )
            : undefined;

        const leftMatch: DuelMatch = {
          ...leftBase,
          leftPrediction:
            viewedHasCompleteAllocation
              ? r40LivePrediction(leftResult)
              : "—",
          rightPrediction: "—",
          leftActive:
            viewedHasCompleteAllocation
              ? r40LiveRuleKeys(leftResult)
              : [],
          rightActive: [],
        };

        const rightMatch: DuelMatch | null =
          rightBase
            ? {
                ...rightBase,
                leftPrediction: "—",
                rightPrediction:
                  opponentHasCompleteAllocation
                    ? r40LivePrediction(rightResult)
                    : "—",
                leftActive: [],
                rightActive:
                  opponentHasCompleteAllocation
                    ? r40LiveRuleKeys(rightResult)
                    : [],
              }
            : null;

        return {
          leftMatch,
          rightMatch,
        };
      })
      .filter(
        (
          row,
        ): row is FantacalcioDisplayRow =>
          row !== null,
      );
  })();
  function renderLiveDepartmentSplitCards(
    rows: FantacalcioDisplayRow[],
  ) {
    return (
      <div className="grid grid-cols-2 gap-2 p-2 sm:gap-4 sm:p-4">
        <section className="min-w-0 overflow-hidden rounded-2xl border border-white/10 bg-[#081217]/95 shadow-xl shadow-black/30">
          <div className="border-b border-white/10 px-2.5 py-2 sm:px-4 sm:py-2.5">
            <p className="truncate text-[10px] font-black uppercase tracking-[0.14em] text-white sm:text-xs">
              {viewedClubInfo.name}
            </p>
          </div>

          {rows.map(({ leftMatch }) => (
            <article
              key={`live-left-${leftMatch.id}`}
              className="border-b border-white/[0.08] px-1.5 py-2 last:border-b-0 sm:px-3 sm:py-3"
            >
              <div className="grid min-w-0 grid-cols-[minmax(0,1.35fr)_minmax(72px,0.75fr)] items-center gap-1.5 sm:grid-cols-[minmax(0,1.35fr)_minmax(112px,0.75fr)] sm:gap-3">
                <PredictionSide
                  score={leftMatch.leftPrediction}
                  active={leftMatch.leftActive}
                  side="left"
                  homeName={leftMatch.home}
                  awayName={leftMatch.away}
                />

                <LiveResultPointsCard
                  match={leftMatch}
                  points={r40FantacalcioContributionPoints(
                    r40FantacalcioView?.leftSide,
                    leftMatch.id,
                  )}
                  side="left"
                />
              </div>
            </article>
          ))}
        </section>

        <section className="min-w-0 overflow-hidden rounded-2xl border border-white/10 bg-[#081217]/95 shadow-xl shadow-black/30">
          <div className="border-b border-white/10 px-2.5 py-2 text-right sm:px-4 sm:py-2.5">
            <p className="truncate text-[10px] font-black uppercase tracking-[0.14em] text-white sm:text-xs">
              {viewedOpponentClubInfo?.name || "Avversario"}
            </p>
          </div>

          {rows.map(({ leftMatch, rightMatch }) => (
            <article
              key={`live-right-${leftMatch.id}`}
              className="border-b border-white/[0.08] px-1.5 py-2 last:border-b-0 sm:px-3 sm:py-3"
            >
              {rightMatch ? (
                <div className="grid min-w-0 grid-cols-[minmax(72px,0.75fr)_minmax(0,1.35fr)] items-center gap-1.5 sm:grid-cols-[minmax(112px,0.75fr)_minmax(0,1.35fr)] sm:gap-3">
                  <LiveResultPointsCard
                    match={rightMatch}
                    points={r40FantacalcioContributionPoints(
                      r40FantacalcioView?.rightSide,
                      rightMatch.id,
                    )}
                    side="right"
                  />

                  <PredictionSide
                    score={rightMatch.rightPrediction}
                    active={rightMatch.rightActive}
                    side="right"
                    homeName={rightMatch.home}
                    awayName={rightMatch.away}
                  />
                </div>
              ) : (
                <div className="grid min-h-[52px] grid-cols-2 items-center gap-1.5 sm:min-h-[70px] sm:gap-3">
                  <div className="rounded-xl border border-dashed border-white/10 bg-black/20 py-3 text-center text-sm font-black text-gray-700">
                    —
                  </div>
                  <div className="rounded-xl border border-dashed border-white/10 bg-black/20 py-3 text-center text-sm font-black text-gray-700">
                    —
                  </div>
                </div>
              )}
            </article>
          ))}
        </section>
      </div>
    );
  }

  async function persistStrategy(nextRows: DuelMatch[]) {
    if (

      strategyLocked ||
      !isViewingSelf ||
      strategyPendingSchedule ||
      isByeRound ||
      !leagueRoundId ||
      nextRows.length !== 10
    ) {
      return;
    }

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
      setStrategyError(
        error.message || "Salvataggio della strategia non riuscito.",
      );
      return;
    }

    const result = (data || [])[0];
    setStrategyExists(true);
    setHasOfficialSubmission(Boolean(result?.submitted_version));
    setHasUnconfirmedChanges(Boolean(result?.has_unconfirmed_changes));
    setStrategyError(null);
  }

  function handleSwapMatch(index: number) {
    if (
      !isViewingSelf ||
      interactionLocked ||
      strategyLoading ||
      savingStrategy
    ) {
      return;
    }

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
      !strategySubmittable ||
      strategyPendingSchedule) {
      setStrategyAvailabilityModalOpen(true);
      return;
    }

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
        },
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
      className="min-h-screen overflow-x-hidden bg-[#061014] text-white [touch-action:pan-y] [overscroll-behavior-x:none]"
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
        <header className="grid w-full min-w-0 grid-cols-[minmax(0,1fr)_54px_66px] gap-1.5 border-b border-white/10 py-3 sm:grid-cols-[minmax(0,1fr)_120px_120px] sm:gap-3 sm:py-5">
          <section className="min-w-0 overflow-hidden rounded-2xl border border-white/10 bg-[#0b1419] p-2 shadow-2xl shadow-black/40 sm:p-3">
            <div className="grid min-w-0 grid-cols-[auto_minmax(0,1fr)_auto] items-center gap-1 sm:grid-cols-[84px_minmax(104px,1fr)_84px] sm:gap-3">
              <div className="flex shrink-0 flex-col items-center">
                <Avatar
                  name={viewedClubInfo.name}
                  avatarUrl={viewedClubInfo.crest_url}
                  avatarZoom={viewedClubInfo.avatar_zoom}
                  avatarX={viewedClubInfo.avatar_x}
                  avatarY={viewedClubInfo.avatar_y}
                />
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

                {fantacalcioIsForfeit && (
                  <span className="mt-1 rounded-full border border-orange-400/30 bg-orange-400/10 px-1.5 py-0.5 text-[7px] font-black uppercase tracking-[0.08em] text-orange-300 sm:text-[8px]">
                    A tavolino
                  </span>
                )}
              </div>

              <div className="flex min-w-0 flex-col items-center justify-self-center">
                <Avatar
                  name={
                    viewedIsByeRound
                      ? "Riposo"
                      : viewedOpponentClubInfo?.name || "Avversario"
                  }
                  avatarUrl={
                    viewedIsByeRound ? null : viewedOpponentClubInfo?.crest_url
                  }
                  avatarZoom={1}
                  avatarX={0}
                  avatarY={0}
                  disabled={viewedIsByeRound}
                />
                <p
                  className={`mt-1 max-w-[54px] truncate text-[9px] font-black uppercase leading-none sm:max-w-[72px] sm:text-[10px] ${
                    viewedIsByeRound ? "text-gray-600" : "text-white"
                  }`}
                >
                  {viewedIsByeRound
                    ? "Riposo"
                    : viewedOpponentClubInfo?.name || "Avversario"}
                </p>
              </div>
            </div>
          </section>

          <div className="rounded-2xl border border-white/10 bg-black/25 p-2 text-center sm:p-3">
            <div className="flex h-full flex-col items-center justify-center">
              <p className="text-[8px] font-bold uppercase tracking-[-0.02em] text-gray-500 sm:text-xs">
                Giornata
              </p>
              <p className="text-2xl font-black text-white sm:text-3xl">
                {roundNumber ?? "—"}
              </p>
            </div>
          </div>

          <button
            type="button"
            onClick={() => router.push(leaguePath.statistics(leagueId))}
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
                {viewedIsByeRound
                  ? "Turno di riposo"
                  : locked
                    ? "Pronostici chiusi"
                    : "Pronostici aperti"}
              </p>
              <p className="text-xs text-gray-300 sm:text-sm">
                {viewedIsByeRound
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
                <p className="text-[10px] font-bold uppercase tracking-[0.16em] text-gray-500 sm:text-xs">
                  Modalità
                </p>
                <p className="text-base font-black uppercase sm:text-lg">
                  Fantacalcio
                </p>
                <p className="text-[11px] font-semibold text-gray-500">
                  Duello live
                </p>
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
                    <span className="block text-sm font-black uppercase text-white sm:text-base">
                      Modalità Punti Puri
                    </span>
                    <span className="block text-[11px] font-semibold text-gray-500">
                      Vai alla giornata punti
                    </span>
                  </span>
                  <span className="flex h-10 w-10 shrink-0 items-center justify-center">
                    <FantaGolModeIcon mode="punti-puri" />
                  </span>
                </button>

                <button
                  type="button"
                  onClick={() => router.push(`/leghe/${leagueId}/onetoone`)}
                  className="flex w-full items-center justify-between border-t border-white/10 px-4 py-3 text-left transition hover:bg-white/5"
                >
                  <span>
                    <span className="block text-sm font-black uppercase text-white sm:text-base">
                      Modalità One To One
                    </span>
                    <span className="block text-[11px] font-semibold text-gray-500">
                      Vai alla sfida diretta
                    </span>
                  </span>
                  <span className="flex h-10 w-10 shrink-0 items-center justify-center">
                    <FantaGolModeIcon mode="one-to-one" />
                  </span>
                </button>
              </div>
            )}
          </div>
        </section>

        <div
          className={
            viewedIsByeRound ? "pointer-events-none opacity-30 grayscale" : ""
          }
        >
          <RuleStrip />
        </div>

        {viewedIsByeRound ? (
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
                Le funzioni di questa modalità sono disattivate. Puoi
                pianificare la strategia della modalità One-to-One.
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

            <ClubKitMini club={viewedOpponentClubInfo} align="right" />
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
          <section
            className={`mt-3 grid gap-4 sm:mt-4 ${
              viewedIsByeRound
                ? "pointer-events-none select-none opacity-25 grayscale"
                : ""
            }`}
          >
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
                    group.tone === "red"
                      ? "border-red-500/20"
                      : "border-[#A6E824]/20"
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

                {!isLiveForSwipe ? (
group.rows.map((displayRow, groupIndex) => {
                  const match = displayRow.leftMatch;
                  const opponentMatch = displayRow.rightMatch;
                  const matchIndex = group.offset + groupIndex;
                  const selected = selectedMatchIndex === matchIndex;

                  const selectedGroup =
                    selectedMatchIndex === null
                      ? null
                      : selectedMatchIndex < 5
                        ? "attacco"
                        : "difesa";

                  const currentGroup =
                    matchIndex < 5 ? "attacco" : "difesa";

                  const swapCandidate =
                    selectedMatchIndex !== null &&
                    !selected &&
                    selectedGroup !== currentGroup;

                  const swapIndicatorState: SwapIndicatorState =
                    interactionLocked || strategyLoading || savingStrategy
                      ? "disabled"
                      : selected
                        ? "selected"
                        : swapCandidate
                          ? "candidate"
                          : "idle";

                  const swapIndicatorTone: SwapIndicatorTone =
                    currentGroup === "attacco"
                      ? "red"
                      : "green";

                  return (
                    <article
                      key={`${match.id}:${opponentMatch?.id ?? "none"}:${matchIndex}`}
                      className={`border-b border-white/10 px-2 py-2 transition-all duration-200 last:border-b-0 sm:px-5 sm:py-4 ${
                        selected && !interactionLocked
                          ? currentGroup === "attacco"
                            ? "bg-red-500/[0.09] ring-1 ring-inset ring-red-400/55 shadow-[inset_0_0_24px_rgba(239,68,68,0.07)]"
                            : "bg-[#A6E824]/[0.09] ring-1 ring-inset ring-[#A6E824]/55 shadow-[inset_0_0_24px_rgba(166,232,36,0.07)]"
                          : swapCandidate
                            ? currentGroup === "attacco"
                              ? "bg-red-500/[0.045] ring-1 ring-inset ring-red-500/15 motion-safe:animate-pulse"
                              : "bg-[#A6E824]/[0.045] ring-1 ring-inset ring-[#A6E824]/15 motion-safe:animate-pulse"
                            : ""
                      }`}
                    >
                      {!isLiveForSwipe ? (
                        <div className="grid grid-cols-[75%_25%] items-center gap-1 sm:grid-cols-[2.35fr_1fr] sm:gap-5">
                          <button
                            type="button"
                            onClick={() => handleSwapMatch(matchIndex)}
                            className={`grid min-w-0 grid-cols-[33%_67%] items-center gap-1 rounded-xl text-left transition sm:grid-cols-[1fr_1.35fr] sm:gap-5 ${
                              interactionLocked
                                ? "cursor-default"
                                : "hover:bg-white/[0.03]"
                            }`}
                            title={
                              interactionLocked
                                ? "Swap disattivato dopo il lock ufficiale"
                                : "Clicca una partita di Attacco e una di Difesa per scambiarle di posto"
                            }
                          >
                            <PredictionSide
                              score={match.leftPrediction}
                              active={match.leftActive}
                              side="left"
                              homeName={match.home}
                              awayName={match.away}
                            />
                            <LiveMatchCenter
                              match={match}
                              swapState={swapIndicatorState}
                              swapTone={swapIndicatorTone}
                            />
                          </button>

                          {interactionLocked && opponentMatch ? (
                            <PredictionSide
                              score={opponentMatch.rightPrediction}
                              active={opponentMatch.rightActive}
                              side="right"
                              homeName={opponentMatch.home}
                              awayName={opponentMatch.away}
                            />
                          ) : (
                            <div className="flex min-w-0 flex-col items-center text-center sm:items-end">
                              <p className="text-[10px] font-black uppercase tracking-[0.12em] text-gray-600 sm:text-xs">
                                Avversario
                              </p>
                              <p className="mt-2 text-lg font-black leading-none text-gray-700 sm:text-3xl">
                                —
                              </p>
                              <div className="mt-2 h-6 w-full rounded-xl border border-dashed border-white/10 bg-black/20 sm:h-8" />
                            </div>
                          )}
                        </div>
                      ) : (
                        <div className="grid min-w-0 grid-cols-[minmax(0,1.25fr)_minmax(72px,0.75fr)_minmax(72px,0.75fr)_minmax(0,1.25fr)] items-center gap-x-1.5 sm:grid-cols-[minmax(0,1.35fr)_minmax(112px,0.75fr)_minmax(112px,0.75fr)_minmax(0,1.35fr)] sm:gap-x-3">

                          <PredictionSide
                            score={match.leftPrediction}
                            active={match.leftActive}
                            side="left"
                            homeName={match.home}
                            awayName={match.away}
                          />

                          <LiveResultPointsCard
                            match={match}
                            points={r40FantacalcioContributionPoints(
                              r40FantacalcioView?.leftSide,
                              match.id,
                            )}
                            side="left"
                          />

                          <div className="ml-2 min-w-0 sm:ml-8">
                            {opponentMatch ? (
                              <LiveResultPointsCard
                                match={opponentMatch}
                                points={r40FantacalcioContributionPoints(
                                  r40FantacalcioView?.rightSide,
                                  opponentMatch.id,
                                )}
                                side="right"
                              />
                            ) : (
                              <div className="flex min-h-12 items-center justify-center rounded-xl border border-dashed border-white/10 bg-black/20 text-sm font-black text-gray-700 sm:min-h-16">
                                —
                              </div>
                            )}
                          </div>

                          {opponentMatch ? (
                            <PredictionSide
                              score={opponentMatch.rightPrediction}
                              active={opponentMatch.rightActive}
                              side="right"
                              homeName={opponentMatch.home}
                              awayName={opponentMatch.away}
                            />
                          ) : (
                            <div className="flex min-w-0 flex-col items-center text-center sm:items-end">
                              <p className="text-[10px] font-black uppercase tracking-[0.12em] text-gray-600 sm:text-xs">
                                Avversario
                              </p>
                              <p className="mt-2 text-lg font-black leading-none text-gray-700 sm:text-3xl">
                                —
                              </p>
                              <div className="mt-2 h-6 w-full rounded-xl border border-dashed border-white/10 bg-black/20 sm:h-8" />
                            </div>
                          )}
                        </div>
                      )}
                    </article>
                  );
                })) : (
                  renderLiveDepartmentSplitCards(group.rows)
                )}
              </section>
            ))}
          </section>
        )}

        {!viewedIsByeRound && (
          <section className="mt-5 flex justify-center">
            <RoundSubmissionButton
              locked={locked}
              isViewingSelf={isViewingSelf}
              hasOfficialSubmission={hasOfficialSubmission}
              hasUnconfirmedChanges={hasUnconfirmedChanges}
              submitting={submitting || savingStrategy || strategyLoading}
              disabled={!isViewingSelf || liveRows.length !== 10}
              onClick={submitStrategy}
            />
          </section>
        )}
      </section>

      <SubmissionModal
        open={submissionModalOpen}
        title="Strategia Fantacalcio inviata"
        description={
          "La disposizione Attacco/Difesa è ora ufficiale.\nPuoi modificarla e reinviarla fino al lock ufficiale."
        }
        primaryLabel="Vai a One To One"
        onPrimary={() => router.push(`/leghe/${leagueId}/onetoone`)}
        onClose={() => setSubmissionModalOpen(false)}
      />
      <StrategyAvailabilityModal
        open={strategyAvailabilityModalOpen}
        onClose={() => setStrategyAvailabilityModalOpen(false)}
      />

    </main>
  );
}
