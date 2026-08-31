"use client";


import { getMyLeagueIdentity } from "../../../../lib/league-identity/client";
import {
  useEffect,
  useMemo,
  useRef,
  useState,
  type PointerEvent,
  type TouchEvent,
} from "react";
import { createPortal } from "react-dom";
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
  exact_points?: number | string | null;
  sign_points?: number | string | null;
  over_under_points?: number | string | null;
  goal_no_goal_points?: number | string | null;
  surprise_points?: number | string | null;
  goal_show_points?: number | string | null;
  grand_slam_points?: number | string | null;
  cantonata_points?: number | string | null;
  opposite_sign_points?: number | string | null;
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
  void?: boolean | null;
  exact_points?: number | null;
  sign_points?: number | null;
  over_under_points?: number | null;
  goal_no_goal_points?: number | null;
  surprise_points?: number | null;
  goal_show_points?: number | null;
  grand_slam_points?: number | null;
  cantonata_points?: number | null;
  opposite_sign_points?: number | null;
  result_phase?: string | null;
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

type R40FantacalcioFixtureSide = {
  member_id: string;
  display_name?: string | null;
  strategy_id?: string | null;
  strategy_valid?: boolean | null;
  strategy_version?: number | null;
  points?: number | string | null;
  goals?: number | string | null;
};

type R40FantacalcioFixture = {
  fixture_id: string;
  fixture_phase?: string | null;
  status?: string | null;
  is_bye?: boolean | null;
  home: R40FantacalcioFixtureSide;
  away: R40FantacalcioFixtureSide | null;
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
    authority?: "normal" | "single_forfeit" | "double_forfeit" | string | null;
    home_wins?: number | null;
    away_wins?: number | null;
    draws?: number | null;
    winner?: string | null;
    home_score?: number | null;
    away_score?: number | null;
  } | null;
  forfeit?: {
    type?: "single" | "double" | string | null;
    winner?: string | null;
    home_score?: string | null;
    away_score?: string | null;
    home_outcome?: string | null;
    away_outcome?: string | null;
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

function r40LivePredictionPoints(
  result: R40LivePredictionResult | undefined,
): number {
  if (!result || result.void) {
    return 0;
  }

  return (
    (result.exact_points ?? 0) +
    (result.sign_points ?? 0) +
    (result.over_under_points ?? 0) +
    (result.goal_no_goal_points ?? 0) +
    (result.surprise_points ?? 0) +
    (result.goal_show_points ?? 0) +
    (result.grand_slam_points ?? 0) +
    (result.cantonata_points ?? 0) +
    (result.opposite_sign_points ?? 0)
  );
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
  points?: number;
  opponentPoints?: number;
  determined?: boolean;
};

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
            className="flex min-w-0 flex-col items-center justify-center rounded-xl border border-white/5 bg-black/20 px-1 py-1.5 sm:px-2 sm:py-2"
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

function formatPredictionScore(score: string) {
  const compact = score.replace(/\s+/g, "");
  const match = compact.match(/^(\d+)-(\d+)$/);
  return match ? `${match[1]} - ${match[2]}` : score;
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
        <span className="text-[7px] font-black uppercase text-gray-500 sm:text-xs">
          {homeBadge}
        </span>
        <span className="whitespace-nowrap text-[13px] font-black leading-none text-white sm:text-2xl">
          {formatPredictionScore(score)}
        </span>
        <span className="text-[7px] font-black uppercase text-gray-500 sm:text-xs">
          {awayBadge}
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

function StaticMemoryIndicator() {
  return (
    <span
      className="relative flex h-[22px] w-[22px] min-[370px]:h-[25px] min-[370px]:w-[25px] min-[390px]:h-[27px] min-[390px]:w-[27px] translate-y-[8px] items-center justify-center rounded-full border border-white/20 bg-gradient-to-br from-gray-300/30 via-gray-600/30 to-black/60 text-gray-200 opacity-55 shadow-[inset_0_2px_2px_rgba(255,255,255,0.14),inset_0_-4px_6px_rgba(0,0,0,0.68),0_3px_0_rgba(0,0,0,0.72),0_6px_12px_rgba(0,0,0,0.42)] sm:h-9 sm:w-9"
      aria-hidden="true"
    >
      <svg
        viewBox="0 0 32 32"
        className="h-[14px] w-[14px] min-[370px]:h-4 min-[370px]:w-4 min-[390px]:h-[18px] min-[390px]:w-[18px] drop-shadow-[0_1px_1px_rgba(0,0,0,0.60)] sm:h-5 sm:w-5"
        fill="currentColor"
      >
        <path d="M25.3 8.2a11.2 11.2 0 0 0-16.8-1L6.2 4.9a1.35 1.35 0 0 0-2.3.96v7.02c0 .75.6 1.35 1.35 1.35h7.02a1.35 1.35 0 0 0 .96-2.3l-2.4-2.4a7.95 7.95 0 0 1 11.73.77 1.65 1.65 0 1 0 2.74-2.1Z" />
        <path d="M26.75 17.77h-7.02a1.35 1.35 0 0 0-.96 2.3l2.4 2.4a7.95 7.95 0 0 1-11.73-.77 1.65 1.65 0 1 0-2.74 2.1 11.2 11.2 0 0 0 16.8 1l2.3 2.3a1.35 1.35 0 0 0 2.3-.96v-7.02c0-.75-.6-1.35-1.35-1.35Z" />
      </svg>

      <span className="pointer-events-none absolute inset-[3px] rounded-full border border-white/15" />
    </span>
  );
}

function LiveMatchCenter({
  match,
  leftPoints = 0,
  rightPoints = 0,
}: {
  match: DuelMatch;
  leftPoints?: number;
  rightPoints?: number;
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
        <StaticMemoryIndicator />
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
            {leftPoints}
          </span>

          <span className="text-[10px] font-black uppercase tracking-[0.18em] text-gray-500 sm:text-xs">
            PT
          </span>

          <span className="text-lg font-black leading-none text-white sm:text-2xl">
            {rightPoints}
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
  const [canonicalSwipeScreens, setCanonicalSwipeScreens] = useState<
    CanonicalSwipeScreen[]
  >([]);
  const [opponentClubInfo, setOpponentClubInfo] = useState<ClubInfo | null>(
    null,
  );
  const [leagueRoundId, setLeagueRoundId] = useState<string | null>(null);
  const [roundNumber, setRoundNumber] = useState<number | null>(null);
  const [leagueFixtureId, setLeagueFixtureId] = useState<string | null>(null);
  const [hasOfficialSubmission, setHasOfficialSubmission] = useState(false);
  const [hasUnconfirmedChanges, setHasUnconfirmedChanges] = useState(false);
  const [strategyExists, setStrategyExists] = useState(false);
  const [strategyLocked, setStrategyLocked] = useState(false);

  const [strategySubmittable, setStrategySubmittable] = useState(false);
  const [isByeRound, setIsByeRound] = useState(false);
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
  const [liveRows, setLiveRows] = useState<DuelMatch[]>([]);
  const [
    leagueLiveProjection,
    setLeagueLiveProjection,
  ] = useState<R40LeagueLiveFrontendProjection | null>(
    null,
  );
  const [leftSlots, setLeftSlots] = useState<(PredictionSlot | null)[]>([]);
  const [storedSlots, setStoredSlots] = useState<PredictionSlot[]>([]);
  const [leftPoints, setLeftPoints] = useState(0);
  const [rightPoints, setRightPoints] = useState(0);
  const [leftGoals, setLeftGoals] = useState(0);
  const [rightGoals, setRightGoals] = useState(0);

  const [strategyPendingSchedule, setStrategyPendingSchedule] = useState(false);
  const [strategyAvailabilityModalOpen, setStrategyAvailabilityModalOpen] = useState(false);

  useEffect(() => {
    const frame = window.requestAnimationFrame(() => {
      setMounted(true);
    });

    return () => window.cancelAnimationFrame(frame);
  }, []);

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

      setClubInfo({
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
          identity.kit_secondary_color || "#A6E824",
        kit_third_color:
          identity.kit_third_color || "#FFFFFF",
        kit_logo_mode:
          identity.kit_logo_mode ||
          "center_horizontal",
        kit_crest_position:
          identity.kit_crest_position ||
          "left_chest",
        stars_count: identity.stars_count || 0,
      });

      setOpponentClubInfo(null);

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
          p_mode: "one_to_one",
        }),
        supabase.rpc("get_my_one_to_one_preview_rpc", {
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
          (row) => row.mode === "one_to_one",
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
              .eq("mode", "one_to_one")
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
          "La giornata One-to-One deve contenere esattamente 10 partite.",
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
            homeBadge: homeName,
            awayBadge: awayName,
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
      const status = ((strategyData || [])[0] ||
        null) as StrategyStatusRow | null;
      let restoredSlots: (PredictionSlot | null)[] = baseSlots;

      if (status?.strategy_exists && status.workspace_payload) {
        try {
          const matrix = fromOneToOneStrategyPayload(
            status.workspace_payload,
            status.league_fixture_id,
          );
          const slotsByMatchId = new Map(
            baseSlots.map((slot) => [slot.matchId, slot]),
          );
          const sourceByTarget = new Map(
            matrix.pairs.map((pair) => [
              pair.targetMatchId,
              pair.sourceMatchId,
            ]),
          );

          restoredSlots = baseRows.map((targetMatch) => {
            const sourceMatchId = sourceByTarget.get(targetMatch.id);
            return sourceMatchId
              ? slotsByMatchId.get(sourceMatchId) || null
              : null;
          });
        } catch (error) {
          setStrategyError(
            error instanceof Error
              ? error.message
              : "La strategia One-to-One salvata non è leggibile.",
          );
        }
      }

      const preview = findNestedRecord(
        previewData,
        (record) =>
          ("home_wins" in record && "away_wins" in record) ||
          ("mini_wins" in record && "mini_losses" in record),
      );
      setLeftGoals(
        toFiniteNumber(preview?.home_wins ?? preview?.mini_wins),
      );
      setRightGoals(
        toFiniteNumber(preview?.away_wins ?? preview?.mini_losses),
      );
      setLeftPoints(toFiniteNumber(preview?.home_points));
      setRightPoints(toFiniteNumber(preview?.away_points));

      setLeagueRoundId(currentLeagueRoundId);
      setRoundNumber(rows[0]?.round_number ?? null);
      setIsByeRound(Boolean(status?.is_bye));
      setLeagueFixtureId(status?.league_fixture_id || null);
      setLiveRows(baseRows);
      setLeftSlots(restoredSlots);
      setStoredSlots(
        baseSlots.filter(
          (slot) =>
            !restoredSlots.some(
              (assigned) => assigned?.matchId === slot.matchId,
            ),
        ),
      );
      setStrategyExists(Boolean(status?.strategy_exists));
      setHasOfficialSubmission(Boolean(status?.has_official_snapshot));
      setHasUnconfirmedChanges(Boolean(status?.has_unconfirmed_changes));
      setStrategyLocked(status?.is_editable !== true);
      setStrategySubmittable(status?.is_submittable === true);
      setStrategyLoading(false);
    }

    void loadOneToOneStrategy();

    return () => {
      cancelled = true;
    };
  }, [leagueId]);

  const locked = strategyLocked;
  const interactionLocked = strategyLocked || isByeRound;

  const isLiveForSwipe = !isByeRound && strategyLocked;
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


  const r40OneToOneView = (() => {
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
        .one_to_one_preview
        ?.fixtures
        ?.find(
          (candidate) =>
            candidate.fixture_id === screen.fixtureId,
        ) ?? null;

    if (!fixture) return null;

    const viewedIsHome =
      fixture.home_member_id === viewedMemberId;

    const opponentMemberId = viewedIsHome
      ? fixture.away_member_id
      : fixture.home_member_id;

    const matrix =
      fixture.matrix_home?.owner_member_id ===
        viewedMemberId
        ? fixture.matrix_home
        : fixture.matrix_away?.owner_member_id ===
            viewedMemberId
          ? fixture.matrix_away
          : null;

    const opponentMatrix =
      opponentMemberId &&
      fixture.matrix_home?.owner_member_id ===
        opponentMemberId
        ? fixture.matrix_home
        : opponentMemberId &&
            fixture.matrix_away?.owner_member_id ===
              opponentMemberId
          ? fixture.matrix_away
          : null;

    const strategies =
      leagueLiveProjection
        .ui_snapshot
        ?.strategies_live ?? [];

    const viewedOfficialStrategy =
      strategies.find(
        (candidate) =>
          candidate.mode === "one_to_one" &&
          candidate.league_member_id ===
            viewedMemberId &&
          candidate.league_fixture_id ===
            fixture.fixture_id,
      ) ?? null;

    const opponentOfficialStrategy =
      opponentMemberId
        ? strategies.find(
            (candidate) =>
              candidate.mode === "one_to_one" &&
              candidate.league_member_id ===
                opponentMemberId &&
              candidate.league_fixture_id ===
                fixture.fixture_id,
          ) ?? null
        : null;

    const viewedHasOfficialStrategy =
      Boolean(
        matrix ||
        (
          viewedOfficialStrategy?.payload
            ?.pairings?.length === 10
        ),
      );

    const opponentHasOfficialStrategy =
      Boolean(
        opponentMatrix ||
        (
          opponentOfficialStrategy?.payload
            ?.pairings?.length === 10
        ),
      );

    return {
      fixture,
      viewedMemberId,
      opponentMemberId,
      viewedIsHome,
      matrix,
      opponentMatrix,
      viewedOfficialStrategy,
      opponentOfficialStrategy,
      viewedHasOfficialStrategy,
      opponentHasOfficialStrategy,
    };
  })();

  function completeProfileSwipe(nextIndex: number, direction: "next" | "prev") {
    closeMemoryPopup();

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

  const r40OneToOneDisplay = (() => {
    const hiddenSlots =
      leftSlots.map(() => null);

    if (!canViewProfileContent) {
      return {
        rows: liveRows.map((match) => ({
          ...match,
          rightPrediction: "—",
          rightActive: [],
        })),
        slots: hiddenSlots,
        rightSlots: hiddenSlots,
      };
    }

    if (!isLiveForSwipe) {
      return {
        rows: liveRows,
        slots: leftSlots,
        rightSlots: hiddenSlots,
      };
    }

    if (
      !leagueLiveProjection ||
      !r40OneToOneView
    ) {
      return {
        rows: isViewingSelf
          ? liveRows
          : liveRows.map((match) => ({
              ...match,
              rightPrediction: "—",
              rightActive: [],
            })),
        slots: isViewingSelf
          ? leftSlots
          : hiddenSlots,
        rightSlots: hiddenSlots,
      };
    }

    const {
      viewedMemberId,
      opponentMemberId,
      matrix,
      opponentMatrix,
    } = r40OneToOneView;

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
      /*
       * ONE-SIDED RECOVERY CONTRACT:
       *
       * Recovery/missing belongs only to the viewed member.
       * Do not blank the valid opponent: the normal opponent
       * strategy path below must remain available.
       */
    }

    const strategies =
      leagueLiveProjection
        .ui_snapshot
        ?.strategies_live ?? [];

    const strategy =
      strategies.find(
        (candidate) =>
          candidate.mode === "one_to_one" &&
          candidate.league_member_id ===
            viewedMemberId &&
          candidate.league_fixture_id ===
            r40OneToOneView.fixture.fixture_id,
      ) ?? null;

    /*
     * Materialized matrix already contains the exact LIVE pairing.
     * If the fixture is strategy_incomplete because the opponent is
     * Recovery, the viewed user's submitted pairings remain usable.
     */
    const officialPairings =
      strategy?.payload?.pairings ?? [];

    const hasMaterializedOwnMatrix =
      Boolean(
        matrix?.owner_member_id ===
          viewedMemberId &&
        matrix?.mini_challenges?.length === 10,
      );

    const hasOfficialPairings =
      strategy !== null &&
      officialPairings.length === 10;

    /*
     * RECOVERY ROUND CONTRACT:
     *
     * no matrix + no official submitted Strategy
     * means Strategy participation is blocked for
     * the entire round.
     */
    const challenges =
      hasMaterializedOwnMatrix
        ? matrix?.mini_challenges ?? []
        : hasOfficialPairings
          ? officialPairings
          : [];

    const hasOfficialOneToOneStrategy =
      hasMaterializedOwnMatrix ||
      hasOfficialPairings;

    const challengeByTarget =
      new Map(
        challenges.map(
          (challenge) => [
            challenge.opponent_match_id,
            challenge,
          ],
        ),
      );

    const baseRowsById =
      new Map(
        liveRows.map(
          (match) => [match.id, match],
        ),
      );

    const slots = liveRows.map(
      (targetMatch) => {
        if (!hasOfficialOneToOneStrategy) {
          return null;
        }

        const challenge =
          challengeByTarget.get(
            targetMatch.id,
          );

        if (!challenge) return null;

        const ownMatch =
          baseRowsById.get(
            challenge.own_match_id,
          );

        if (!ownMatch) return null;

        const ownResult =
          byMemberAndMatch.get(
            `${viewedMemberId}:${challenge.own_match_id}`,
          );

        const pairedOpponentResult =
          r40OneToOneView.opponentHasOfficialStrategy &&
          opponentMemberId
            ? byMemberAndMatch.get(
                `${opponentMemberId}:${challenge.opponent_match_id}`,
              )
            : undefined;

        return {
          ...toPredictionSlot(ownMatch),
          score:
            r40LivePrediction(ownResult),
          active:
            r40LiveRuleKeys(ownResult),
          points: r40LivePredictionPoints(ownResult),
          opponentPoints: r40LivePredictionPoints(pairedOpponentResult),
          determined:
            ownResult?.result_phase === "post_live" &&
            (!r40OneToOneView.opponentHasOfficialStrategy ||
              pairedOpponentResult?.result_phase === "post_live"),
        };
      },
    );

    const opponentStrategy =
      opponentMemberId
        ? strategies.find(
            (candidate) =>
              candidate.mode === "one_to_one" &&
              candidate.league_member_id ===
                opponentMemberId &&
              candidate.league_fixture_id ===
                r40OneToOneView.fixture.fixture_id,
          ) ?? null
        : null;

    const opponentOfficialPairings =
      opponentStrategy?.payload?.pairings ?? [];

    const hasMaterializedOpponentMatrix =
      Boolean(
        opponentMatrix?.owner_member_id ===
          opponentMemberId &&
        opponentMatrix?.mini_challenges?.length === 10,
      );

    const hasOpponentOfficialPairings =
      opponentStrategy !== null &&
      opponentOfficialPairings.length === 10;

    const opponentChallenges =
      hasMaterializedOpponentMatrix
        ? opponentMatrix?.mini_challenges ?? []
        : hasOpponentOfficialPairings
          ? opponentOfficialPairings
          : [];

    const opponentChallengeByTarget =
      new Map(
        opponentChallenges.map(
          (challenge) => [
            challenge.opponent_match_id,
            challenge,
          ],
        ),
      );

    const rightSlots = liveRows.map(
      (targetMatch) => {
        if (
          !r40OneToOneView
            .opponentHasOfficialStrategy ||
          !opponentMemberId
        ) {
          return null;
        }

        const challenge =
          opponentChallengeByTarget.get(
            targetMatch.id,
          );

        if (!challenge) return null;

        const ownMatch =
          baseRowsById.get(
            challenge.own_match_id,
          );

        if (!ownMatch) return null;

        const opponentResult =
          byMemberAndMatch.get(
            `${opponentMemberId}:${challenge.own_match_id}`,
          );

        const pairedViewedResult =
          r40OneToOneView.viewedHasOfficialStrategy
            ? byMemberAndMatch.get(
                `${viewedMemberId}:${challenge.opponent_match_id}`,
              )
            : undefined;

        return {
          ...toPredictionSlot(ownMatch),
          score:
            r40LivePrediction(opponentResult),
          active:
            r40LiveRuleKeys(opponentResult),
          points: r40LivePredictionPoints(opponentResult),
          opponentPoints: r40LivePredictionPoints(pairedViewedResult),
          determined:
            opponentResult?.result_phase === "post_live" &&
            (!r40OneToOneView.viewedHasOfficialStrategy ||
              pairedViewedResult?.result_phase === "post_live"),
        };
      },
    );

    const rows = liveRows.map(
      (targetMatch, index) => {
        const rightSlot = rightSlots[index];

        return {
          ...targetMatch,

          rightPrediction:
            rightSlot?.score ?? "—",

          rightActive:
            rightSlot?.active ?? [],
        };
      },
    );

    return {
      rows,
      slots,
      rightSlots,
    };
  })();
  const displayedLeftSlots =
    r40OneToOneDisplay.slots;

  const displayedRightSlots =
    r40OneToOneDisplay.rightSlots;

  const displayedLiveRows =
    r40OneToOneDisplay.rows;

  const liveMiniChallengeSummary = (() => {
    if (!r40OneToOneView || !canViewProfileContent) {
      return null;
    }

    let viewedWins = 0;
    let opponentWins = 0;

    const leftMatrixWeight =
      r40OneToOneView.viewedHasOfficialStrategy &&
      !r40OneToOneView.opponentHasOfficialStrategy
        ? 2
        : 1;

    for (const slot of displayedLeftSlots) {
      if (!slot?.determined) continue;

      if ((slot.points ?? 0) > (slot.opponentPoints ?? 0)) {
        viewedWins += leftMatrixWeight;
      } else if ((slot.points ?? 0) < (slot.opponentPoints ?? 0)) {
        opponentWins += leftMatrixWeight;
      }
    }

    const rightMatrixWeight =
      r40OneToOneView.opponentHasOfficialStrategy &&
      !r40OneToOneView.viewedHasOfficialStrategy
        ? 2
        : 1;

    for (const slot of displayedRightSlots) {
      if (!slot?.determined) continue;

      if ((slot.points ?? 0) > (slot.opponentPoints ?? 0)) {
        opponentWins += rightMatrixWeight;
      } else if ((slot.points ?? 0) < (slot.opponentPoints ?? 0)) {
        viewedWins += rightMatrixWeight;
      }
    }

    return {
      viewedWins,
      opponentWins,
    };
  })();

  const oneToOneCompetitionScore = (() => {
    if (!r40OneToOneView) return null;

    const { fixture, viewedIsHome } = r40OneToOneView;
    const authority = fixture.aggregate?.authority ?? null;

    if (authority === "single_forfeit") {
      const homeScore = Number(fixture.aggregate?.home_score);
      const awayScore = Number(fixture.aggregate?.away_score);

      if (!Number.isFinite(homeScore) || !Number.isFinite(awayScore)) {
        return null;
      }

      return viewedIsHome
        ? { viewed: homeScore, opponent: awayScore }
        : { viewed: awayScore, opponent: homeScore };
    }

    if (authority === "double_forfeit") {
      // No shared winner exists; backend keeps both technical losses.
      return { viewed: "—", opponent: "—" };
    }

    return null;
  })();

  const oneToOneForfeitBadge =
    canViewProfileContent &&
    r40OneToOneView &&
    (
      r40OneToOneView.fixture.aggregate?.authority === "single_forfeit" ||
      r40OneToOneView.fixture.aggregate?.authority === "double_forfeit"
    )
      ? "A tavolino"
      : null;

  const displayedLeftGoals = canViewProfileContent
    ? r40OneToOneView
      ? oneToOneCompetitionScore?.viewed ??
        liveMiniChallengeSummary?.viewedWins ??
        0
      : isViewingSelf && !isLiveForSwipe
        ? leftGoals
        : "—"
    : "—";

  const displayedRightGoals = canViewProfileContent
    ? r40OneToOneView?.opponentMemberId
      ? oneToOneCompetitionScore?.opponent ??
        liveMiniChallengeSummary?.opponentWins ??
        0
      : isViewingSelf && !isLiveForSwipe
        ? rightGoals
        : "—"
    : "—";

  const [openMemoryIndex, setOpenMemoryIndex] = useState<number | null>(null);
  const [, setMemoryPopupFloating] = useState(false);
  const [memoryPopupPosition, setMemoryPopupPosition] = useState({
    x: 12,
    y: 250,
  });
  const [memoryPopupWidth, setMemoryPopupWidth] = useState<number | null>(null);
  const [memoryDragOffset, setMemoryDragOffset] = useState<{
    x: number;
    y: number;
  } | null>(null);
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
      Math.max(8, window.innerWidth - popupWidth - 8),
    );
    const y = Math.min(
      Math.max(8, rect.bottom + 8),
      Math.max(8, window.innerHeight - 140),
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

      strategyLocked ||
      strategyPendingSchedule ||
      isByeRound ||
      !leagueRoundId ||
      !leagueFixtureId ||
      liveRows.length !== 10 ||
      nextSlots.some((slot) => slot === null)
    ) {
      return;
    }

    const activeLeagueFixtureId = leagueFixtureId;
    const completeSlots = nextSlots as PredictionSlot[];
    const payload = toOneToOneStrategyPayload({
      fixtureId: activeLeagueFixtureId,
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
      setStrategyError(
        error.message || "Salvataggio degli abbinamenti non riuscito.",
      );
      return;
    }

    const result = (data || [])[0];
    setStrategyExists(true);
    setHasOfficialSubmission(Boolean(result?.submitted_version));
    setHasUnconfirmedChanges(Boolean(result?.has_unconfirmed_changes));
    setStrategyError(null);
  }

  function removePredictionSlot(index: number, anchor: HTMLElement) {
    if (interactionLocked || strategyLoading || savingStrategy) return;

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
    setLeftSlots((current) =>
      current.map((item, itemIndex) => (itemIndex === index ? null : item)),
    );
    closeMemoryPopup();
  }

  function restorePredictionSlot(targetIndex: number, storedIndex: number) {
    if (interactionLocked || strategyLoading || savingStrategy) return;

    const slot = storedSlots[storedIndex];
    if (!slot) return;

    const nextSlots = leftSlots.map((item, itemIndex) =>
      itemIndex === targetIndex ? slot : item,
    );
    setLeftSlots(nextSlots);
    setStoredSlots((current) =>
      current.filter((_, itemIndex) => itemIndex !== storedIndex),
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

    const popup = event.currentTarget.closest(
      "[data-memory-popup='true']",
    ) as HTMLDivElement | null;
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
    const popup = event.currentTarget.closest(
      "[data-memory-popup='true']",
    ) as HTMLDivElement | null;
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

    if (event && event.currentTarget.hasPointerCapture(event.pointerId)) {
      event.currentTarget.releasePointerCapture(event.pointerId);
    }

    setMemoryDragOffset(null);
  }

  async function submitStrategy() {
    if (
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

    if (!leagueFixtureId) {
      setStrategyAvailabilityModalOpen(true);
      return;
    }

    const activeLeagueFixtureId = leagueFixtureId;

    if (!allSlotsComplete) {
      alert("Completa tutti gli abbinamenti prima di inviare.");
      return;
    }

    setSubmitting(true);

    if (!strategyExists) {
      const completeSlots = leftSlots as PredictionSlot[];
      const payload = toOneToOneStrategyPayload({
        fixtureId: activeLeagueFixtureId,
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
        },
      );

      if (saveError) {
        setSubmitting(false);
        alert(
          saveError.message || "Salvataggio degli abbinamenti non riuscito.",
        );
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
                {oneToOneForfeitBadge && (
                  <div className="mt-1 flex justify-center">
                    <span className="rounded-full border border-amber-300/30 bg-amber-300/10 px-2 py-0.5 text-[8px] font-black uppercase tracking-[0.12em] text-amber-200 sm:text-[9px]">
                      {oneToOneForfeitBadge}
                    </span>
                  </div>
                )}
              </div>

              <div className="flex min-w-0 flex-col items-center justify-self-center">
                <Avatar
                  name={
                    isByeRound
                      ? "Riposo"
                      : viewedOpponentClubInfo?.name || "Avversario"
                  }
                  avatarUrl={isByeRound ? null : viewedOpponentClubInfo?.crest_url}
                  avatarZoom={1}
                  avatarX={0}
                  avatarY={0}
                  disabled={isByeRound}
                />
                <p
                  className={`mt-1 max-w-[54px] truncate text-[9px] font-black uppercase leading-none sm:max-w-[72px] sm:text-[10px] ${
                    isByeRound ? "text-gray-600" : "text-white"
                  }`}
                >
                  {isByeRound
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
                {isByeRound
                  ? "Turno di riposo"
                  : locked
                    ? "Abbinamenti chiusi"
                    : "Abbinamenti aperti"}
              </p>
              <p className="text-xs text-gray-300 sm:text-sm">
                {isByeRound
                  ? "Le funzioni One-to-One sono disattivate per questa giornata"
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
                  One To One
                </p>
                <p className="text-[11px] font-semibold text-gray-500">
                  Sfida diretta
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
                  onClick={() => router.push(`/leghe/${leagueId}/fantacalcio`)}
                  className="flex w-full items-center justify-between border-t border-white/10 px-4 py-3 text-left transition hover:bg-white/5"
                >
                  <span>
                    <span className="block text-sm font-black uppercase text-white sm:text-base">
                      Modalità Fantacalcio
                    </span>
                    <span className="block text-[11px] font-semibold text-gray-500">
                      Vai al duello live
                    </span>
                  </span>
                  <span className="flex h-10 w-10 shrink-0 items-center justify-center">
                    <FantaGolModeIcon mode="fantacalcio" />
                  </span>
                </button>
              </div>
            )}
          </div>
        </section>

        <div
          className={
            isByeRound ? "pointer-events-none opacity-30 grayscale" : ""
          }
        >
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
                In questo turno riposi in One-to-One
              </p>
              <p className="mt-1 text-xs font-semibold leading-5 text-gray-500 sm:text-sm">
                Le funzioni di questa modalità sono disattivate. Puoi
                pianificare la strategia della modalità Fantacalcio.
              </p>
              <button
                type="button"
                onClick={() => router.push(`/leghe/${leagueId}/fantacalcio`)}
                className="mt-4 rounded-xl border border-[#A6E824]/35 bg-[#A6E824]/10 px-4 py-2.5 text-xs font-black uppercase tracking-[0.08em] text-[#A6E824] transition hover:border-[#A6E824]/70 hover:bg-[#A6E824]/15 sm:text-sm"
              >
                Pianifica Fantacalcio
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
          interactionLocked && canViewProfileContent && !isByeRound ? (
            <div className="mt-3 grid gap-3 sm:mt-4 lg:grid-cols-2 lg:gap-4">
              <section className="overflow-hidden rounded-2xl border border-white/10 bg-[#0b1419] shadow-2xl shadow-black/40">
                <header className="border-b border-white/10 px-3 py-2 text-center sm:px-5 sm:py-3">
                  <p className="truncate text-xs font-black uppercase tracking-[0.12em] text-[#A6E824] sm:text-sm">
                    {viewedClubInfo.name}
                  </p>
                </header>

                {displayedLiveRows.map((match, index) => {
                  const leftSlot = displayedLeftSlots[index];
                  const rightSlot = displayedRightSlots[index];

                  return (
                    <article
                      key={`left-matrix-${match.id}`}
                      className="border-b border-white/10 px-2 py-2 last:border-b-0 sm:px-3 sm:py-3"
                    >
                      <div className="grid grid-cols-[38%_62%] items-center gap-1 sm:grid-cols-[0.9fr_1.4fr] sm:gap-3">
                        {leftSlot ? (
                          <PredictionSide
                            score={leftSlot.score}
                            active={leftSlot.active}
                            side="left"
                            homeBadge={leftSlot.homeBadge}
                            awayBadge={leftSlot.awayBadge}
                          />
                        ) : (
                          <div className="flex min-h-[64px] min-w-0 flex-col items-center justify-center rounded-xl border border-dashed border-white/10 bg-black/25 px-1.5 py-2 text-center shadow-inner shadow-white/5">
                            <p className="text-[10px] font-black uppercase tracking-[0.12em] text-gray-600 sm:text-xs">
                              Vuota
                            </p>
                            <p className="mt-1 text-lg font-black leading-none text-gray-700 sm:text-3xl">
                              —
                            </p>
                          </div>
                        )}

                        <LiveMatchCenter
                          match={match}
                          leftPoints={leftSlot?.points ?? 0}
                          rightPoints={
                            leftSlot?.opponentPoints ??
                            (!r40OneToOneView?.viewedHasOfficialStrategy
                              ? rightSlot?.points ?? 0
                              : 0)
                          }
                        />
                      </div>
                    </article>
                  );
                })}
              </section>

              <section className="overflow-hidden rounded-2xl border border-white/10 bg-[#0b1419] shadow-2xl shadow-black/40">
                <header className="border-b border-white/10 px-3 py-2 text-center sm:px-5 sm:py-3">
                  <p className="truncate text-xs font-black uppercase tracking-[0.12em] text-white sm:text-sm">
                    {viewedOpponentClubInfo?.name ?? "Avversario"}
                  </p>
                </header>

                {displayedLiveRows.map((match, index) => {
                  const leftSlot = displayedLeftSlots[index];
                  const rightSlot = displayedRightSlots[index];

                  return (
                    <article
                      key={`right-matrix-${match.id}`}
                      className="border-b border-white/10 px-2 py-2 last:border-b-0 sm:px-3 sm:py-3"
                    >
                      <div className="grid grid-cols-[62%_38%] items-center gap-1 sm:grid-cols-[1.4fr_0.9fr] sm:gap-3">
                        <LiveMatchCenter
                          match={match}
                          leftPoints={rightSlot?.points ?? 0}
                          rightPoints={
                            rightSlot?.opponentPoints ??
                            (!r40OneToOneView?.opponentHasOfficialStrategy
                              ? leftSlot?.points ?? 0
                              : 0)
                          }
                        />

                        {rightSlot ? (
                          <PredictionSide
                            score={rightSlot.score}
                            active={rightSlot.active}
                            side="right"
                            homeBadge={rightSlot.homeBadge}
                            awayBadge={rightSlot.awayBadge}
                          />
                        ) : (
                          <div className="flex min-h-[64px] min-w-0 flex-col items-center justify-center rounded-xl border border-dashed border-white/10 bg-black/25 px-1.5 py-2 text-center shadow-inner shadow-white/5">
                            <p className="text-[10px] font-black uppercase tracking-[0.12em] text-gray-600 sm:text-xs">
                              Vuota
                            </p>
                            <p className="mt-1 text-lg font-black leading-none text-gray-700 sm:text-3xl">
                              —
                            </p>
                          </div>
                        )}
                      </div>
                    </article>
                  );
                })}
              </section>
            </div>
          ) : (
            <section
              className={`mt-3 overflow-hidden rounded-2xl border border-white/10 bg-[#0b1419] shadow-2xl shadow-black/40 sm:mt-4 ${
                isByeRound
                  ? "pointer-events-none select-none opacity-25 grayscale"
                  : ""
              }`}
            >
              {displayedLiveRows.map((match, index) => {
                const leftSlot = displayedLeftSlots[index];

                return (
                  <article
                    key={match.id}
                    className="border-b border-white/10 px-2 py-2 last:border-b-0 sm:px-5 sm:py-4"
                  >
                    <div className="grid grid-cols-[23%_54%_23%] items-center gap-0.5 sm:grid-cols-[1fr_1.35fr_1fr] sm:gap-5">
                      <div className="relative">
                        <button
                          type="button"
                          onClick={(event) =>
                            removePredictionSlot(index, event.currentTarget)
                          }
                          disabled={interactionLocked || !isViewingSelf}
                          className={`w-full text-left transition ${interactionLocked ? "cursor-default" : "hover:scale-[1.01]"}`}
                          title={
                            interactionLocked
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
                              <p className="text-[10px] font-black uppercase tracking-[0.12em] text-gray-600 sm:text-xs">
                                Vuota
                              </p>
                              <p className="mt-1 text-lg font-black leading-none text-gray-700 sm:text-3xl">
                                —
                              </p>
                            </div>
                          )}
                        </button>
                      </div>

                      <LiveMatchCenter match={match} />

                      <div className="flex min-w-0 flex-col items-center text-center sm:items-end">
                        <p className="text-[10px] font-black uppercase tracking-[0.12em] text-gray-600 sm:text-xs">
                          Avversario
                        </p>
                        <p className="mt-2 text-lg font-black leading-none text-gray-700 sm:text-3xl">
                          —
                        </p>
                        <div className="mt-2 h-6 w-full rounded-xl border border-dashed border-white/10 bg-black/20 sm:h-8" />
                      </div>
                    </div>
                  </article>
                );
              })}
            </section>
          )
        )}

        {!isByeRound && (
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
        )}
      </section>

      {mounted &&
        openMemoryIndex !== null &&
        !interactionLocked &&
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
                      {formatPredictionScore(stored.score)}
                    </span>
                    <span className="text-right text-[10px] uppercase tracking-[-0.02em] text-gray-500 transition group-hover:text-[#A6E824] sm:tracking-[0.02em] sm:text-xs">
                      {stored.awayBadge}
                    </span>
                  </button>
                ))}
              </div>
            )}
          </div>,
          document.body,
        )}

      <SubmissionModal
        open={submissionModalOpen}
        title="Sfida pianificata"
        description={
          "Pronostici e abbinamenti salvati.\nPotrai modificarli fino al lock ufficiale."
        }
        primaryLabel="Vai ai Punti Puri"
        secondaryLabel="Vai a Fantacalcio"
        onPrimary={() => router.push(`/leghe/${leagueId}/giornata`)}
        onSecondary={() => router.push(`/leghe/${leagueId}/fantacalcio`)}
        onClose={() => setSubmissionModalOpen(false)}
      />
      <StrategyAvailabilityModal
        open={strategyAvailabilityModalOpen}
        onClose={() => setStrategyAvailabilityModalOpen(false)}
      />

    </main>
  );
}
