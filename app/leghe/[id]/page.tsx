"use client";

import { useEffect, useMemo, useState, type ReactNode } from "react";
import { useParams, useRouter } from "next/navigation";
import { supabase } from "../../../lib/supabaseClient";
import { leaguePath } from "../../../lib/navigation/league-paths";

import Badge from "../../../components/ui/Badge";
import DashboardCard from "../../../components/ui/DashboardCard";
import HamburgerDrawer from "../../../components/app/HamburgerDrawer";
import FantaGolModeIcon from "../../../components/app/FantaGolModeIcon";
import TeamCrest from "../../../components/app/TeamCrest";
import ClubAvatar from "@/components/app/ClubAvatar";

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

type LeagueMemberRow = {
  membership_id: string;
  user_id?: string | null;
  display_name?: string | null;
  club_name?: string | null;
  crest_url?: string | null;
  avatar_zoom?: number | null;
  avatar_x?: number | null;
  avatar_y?: number | null;
};

type FixtureSide = {
  member_id?: string | null;
  display_name?: string | null;
  points?: number | null;
  goals?: number | null;
};

type FantacalcioFixture = {
  fixture_phase?: string | null;
  is_bye?: boolean | null;
  home_member_id?: string | null;
  away_member_id?: string | null;
  home_display_name?: string | null;
  away_display_name?: string | null;
  home_points?: number | null;
  away_points?: number | null;
  home_goals?: number | null;
  away_goals?: number | null;
  home?: FixtureSide | null;
  away?: FixtureSide | null;
  result?: {
    home_goals?: number | null;
    away_goals?: number | null;
  } | null;
};

type OneToOneFixture = {
  fixture_phase?: string | null;
  is_bye?: boolean | null;
  home_member_id?: string | null;
  away_member_id?: string | null;
  home_display_name?: string | null;
  away_display_name?: string | null;
  home_wins?: number | null;
  away_wins?: number | null;
  draws?: number | null;
  mini_wins?: number | null;
  mini_losses?: number | null;
  mini_draws?: number | null;
  home?: FixtureSide | null;
  away?: FixtureSide | null;
  aggregate?: {
    home_wins?: number | null;
    draws?: number | null;
    away_wins?: number | null;
  } | null;
  aggregate_result?: {
    home_wins?: number | null;
    draws?: number | null;
    away_wins?: number | null;
  } | null;
};

type PreviewRpcRow<TFixture> = TFixture & {
  fixture?: TFixture | null;
  preview?: TFixture | null;
};

type DashboardMatchupRow = {
  league_round_id: string;
  league_round_number: number;
  league_round_status: string;
  schedule_version_id: string;
  schedule_version: number;
  fixture_id: string;
  mode: "fantacalcio" | "one_to_one";
  cycle_number: number;
  leg_number: number;
  pairing_round_number: number;
  current_member_id: string;
  current_side: "home" | "away" | null;
  home_member_id: string;
  home_display_name: string | null;
  away_member_id: string | null;
  away_display_name: string | null;
  opponent_member_id: string | null;
  opponent_display_name: string | null;
  is_bye: boolean;
  fixture_phase: string;
};

type StandingsPreviewRow = {
  member_view?: { league_member_id?: string | null } | null;
  standings_preview?: {
    member?: { league_member_id?: string | null } | null;
    modes?: {
      pure_points?: {
        ranking?: Array<{
          league_member_id?: string | null;
          round_points?: number | null;
        }>;
      };
    };
  } | null;
};

type Duelist = {
  memberId: string;
  name: string;
  avatarUrl: string | null;
  avatarZoom: number;
  avatarX: number;
  avatarY: number;
};

type DuelSummary = {
  left: Duelist;
  right: Duelist | null;
  leftScore: number;
  rightScore: number;
  secondaryLabel: string | null;
  pending: boolean;
  bye: boolean;
};

type LiveModeSummary = {
  purePoints: number;
  currentClub: Duelist | null;
  fantacalcio: DuelSummary | null;
  oneToOne: DuelSummary | null;
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
      "",
    )
    .replace(
      /\s+(?:Football Club|Calcio|F\.?\s*C\.?|C\.?\s*F\.?\s*C\.?|B\.?\s*C\.?|S\.?\s*C\.?)$/i,
      "",
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

function compareDashboardMatchKickoff(
  left: DashboardMatch,
  right: DashboardMatch,
) {
  if (!left.kickoff && !right.kickoff) return left.id.localeCompare(right.id);
  if (!left.kickoff) return 1;
  if (!right.kickoff) return -1;

  const delta =
    new Date(left.kickoff).getTime() - new Date(right.kickoff).getTime();

  return delta !== 0 ? delta : left.id.localeCompare(right.id);
}

function isDashboardMatchLive(match: DashboardMatch) {
  const status = match.status.toLowerCase();

  return (
    status === "live" ||
    status === "in_play" ||
    status.startsWith("live_") ||
    ["halftime", "extra_time", "penalties", "paused"].includes(status)
  );
}

function isDashboardMatchTerminal(match: DashboardMatch) {
  return ["finished", "awarded", "cancelled", "postponed"].includes(
    match.status.toLowerCase(),
  );
}

function buildDashboardMatchGroups(matches: DashboardMatch[]) {
  const sortedMatches = [...matches].sort(compareDashboardMatchKickoff);
  const scheduledMatches = sortedMatches.filter((match) => match.kickoff);
  const unscheduledMatches = sortedMatches.filter((match) => !match.kickoff);

  const matchesByDate = new Map<string, DashboardMatch[]>();

  for (const match of scheduledMatches) {
    const dateKey = getLocalDateKey(match.kickoff as string);
    const dateMatches = matchesByDate.get(dateKey) ?? [];
    dateMatches.push(match);
    matchesByDate.set(dateKey, dateMatches);
  }

  const dayGroups = Array.from(matchesByDate.entries())
    .sort(([leftDate], [rightDate]) => leftDate.localeCompare(rightDate))
    .map(([, dayMatches]) => dayMatches);

  let groups: DashboardMatch[][];

  if (dayGroups.length <= 3) {
    groups = dayGroups;
  } else {
    groups = [[], [], []];

    dayGroups.forEach((dayMatches, dayIndex) => {
      const bucket = Math.min(
        2,
        Math.floor((dayIndex * 3) / dayGroups.length),
      );

      groups[bucket].push(...dayMatches);
    });
  }

  if (unscheduledMatches.length > 0) {
    if (groups.length === 0) {
      groups = [unscheduledMatches];
    } else {
      groups[groups.length - 1].push(...unscheduledMatches);
    }
  }

  return groups.filter((group) => group.length > 0);
}

function getProviderScoreLabel(match: DashboardMatch) {
  return `${match.homeScore ?? 0} - ${match.awayScore ?? 0}`;
}

function MatchMiniRow({ match }: { match: DashboardMatch }) {
  return (
    <div className="grid grid-cols-[minmax(0,1fr)_auto_minmax(64px,auto)_auto_minmax(0,1fr)] items-center gap-x-1 rounded-xl border border-white/10 bg-black/35 px-2.5 py-3 max-[429px]:grid-cols-[minmax(0,1fr)_auto_minmax(58px,auto)_auto_minmax(0,1fr)] max-[429px]:gap-x-0.5 max-[399px]:grid-cols-[minmax(0,1fr)_auto_minmax(54px,auto)_auto_minmax(0,1fr)] max-[381px]:grid-cols-[minmax(0,1fr)_auto_minmax(50px,auto)_auto_minmax(0,1fr)] max-[381px]:gap-x-0 sm:gap-x-1.5 sm:px-3">
      <span className="min-w-0 truncate pr-0.5 text-right text-sm font-black text-white max-[429px]:text-[13px] max-[399px]:text-xs max-[381px]:text-[11px] max-[381px]:tracking-[-0.02em] sm:text-base">
        {match.home}
      </span>

      <TeamCrest
        crestReference={match.homeCrestReference}
        logoUrl={match.homeLogoUrl}
        alt={`${match.home} stemma`}
        fallbackLabel={match.home}
        size="sm"
        className="h-8 w-8 max-[429px]:h-7 max-[429px]:w-7 max-[399px]:h-[26px] max-[399px]:w-[26px] max-[381px]:h-6 max-[381px]:w-6 sm:h-9 sm:w-9"
      />

      <div className="min-w-[64px] text-center max-[429px]:min-w-[58px] max-[399px]:min-w-[54px] max-[381px]:min-w-[50px]">
        <div className="text-xl font-black leading-none text-[#A6E824] max-[429px]:text-lg max-[399px]:text-[17px] max-[381px]:text-base sm:text-2xl">
          {getProviderScoreLabel(match)}
        </div>

        <div className="mt-1 flex flex-col items-center whitespace-nowrap text-[9px] font-semibold leading-[1.15] text-gray-500 sm:text-[10px]">
          <span>{match.kickoffDay}</span>
          <span>{match.kickoffHour}</span>
        </div>
      </div>

      <TeamCrest
        crestReference={match.awayCrestReference}
        logoUrl={match.awayLogoUrl}
        alt={`${match.away} stemma`}
        fallbackLabel={match.away}
        size="sm"
        className="h-8 w-8 max-[429px]:h-7 max-[429px]:w-7 max-[399px]:h-[26px] max-[399px]:w-[26px] max-[381px]:h-6 max-[381px]:w-6 sm:h-9 sm:w-9"
      />

      <span className="min-w-0 truncate pl-0.5 text-left text-sm font-black text-white max-[429px]:text-[13px] max-[399px]:text-xs max-[381px]:text-[11px] max-[381px]:tracking-[-0.02em] sm:text-base">
        {match.away}
      </span>
    </div>
  );
}

function DayMatchRow({ match }: { match: DashboardMatch }) {
  return (
    <div className="grid grid-cols-[minmax(0,1fr)_auto_minmax(0,1fr)] items-center gap-3 rounded-2xl border border-white/10 bg-black px-3 py-4 max-[429px]:gap-2">
      <div className="flex min-w-0 items-center justify-end gap-2">
        <span className="min-w-0 truncate text-right text-sm font-black max-[429px]:text-[13px] max-[399px]:text-xs max-[381px]:text-[11px] max-[381px]:tracking-[-0.02em] sm:text-base">
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

      <div className="min-w-[68px] rounded-xl bg-[#A6E824]/10 px-3 py-2 text-center text-sm font-black text-[#A6E824] max-[429px]:min-w-[60px] max-[429px]:px-2 max-[399px]:min-w-[56px] max-[399px]:px-1.5 max-[381px]:min-w-[52px] max-[381px]:px-1">
        {isDashboardMatchLive(match)
          ? getProviderScoreLabel(match)
          : match.kickoffHour}
      </div>

      <div className="flex min-w-0 items-center gap-2">
        <TeamCrest
          crestReference={match.awayCrestReference}
          logoUrl={match.awayLogoUrl}
          alt={`${match.away} stemma`}
          fallbackLabel={match.away}
          size="sm"
        />
        <span className="min-w-0 truncate text-sm font-black max-[429px]:text-[13px] max-[399px]:text-xs max-[381px]:text-[11px] max-[381px]:tracking-[-0.02em] sm:text-base">
          {match.away}
        </span>
      </div>
    </div>
  );
}

function toFiniteNumber(value: unknown) {
  const number = Number(value);
  return Number.isFinite(number) ? number : 0;
}

function formatLivePoints(value: number) {
  return new Intl.NumberFormat("it-IT", {
    maximumFractionDigits: 2,
  }).format(value);
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

function getFixtureMemberIds(record: Record<string, unknown>) {
  const home = isRecord(record.home) ? record.home : null;
  const away = isRecord(record.away) ? record.away : null;

  const homeMemberId =
    typeof record.home_member_id === "string"
      ? record.home_member_id
      : typeof home?.member_id === "string"
        ? home.member_id
        : null;

  const awayMemberId =
    typeof record.away_member_id === "string"
      ? record.away_member_id
      : typeof away?.member_id === "string"
        ? away.member_id
        : null;

  return { homeMemberId, awayMemberId };
}

function findCurrentMemberFixture<TFixture>({
  value,
  currentMemberId,
  isFixture,
}: {
  value: unknown;
  currentMemberId: string;
  isFixture: (record: Record<string, unknown>) => boolean;
}): TFixture | null {
  let fallback: Record<string, unknown> | null = null;

  function visit(node: unknown): Record<string, unknown> | null {
    if (Array.isArray(node)) {
      for (const item of node) {
        const found = visit(item);
        if (found) return found;
      }
      return null;
    }

    if (!isRecord(node)) return null;

    if (isFixture(node)) {
      fallback ||= node;

      const { homeMemberId, awayMemberId } = getFixtureMemberIds(node);
      if (
        currentMemberId &&
        (homeMemberId === currentMemberId || awayMemberId === currentMemberId)
      ) {
        return node;
      }
    }

    for (const nested of Object.values(node)) {
      const found = visit(nested);
      if (found) return found;
    }

    return null;
  }

  return (visit(value) || fallback) as TFixture | null;
}

function extractFantacalcioFixture(
  value: unknown,
  currentMemberId: string,
): FantacalcioFixture | null {
  return findCurrentMemberFixture<FantacalcioFixture>({
    value,
    currentMemberId,
    isFixture: (record) =>
      ("home_goals" in record ||
        "away_goals" in record ||
        "is_bye" in record) &&
      ("home_member_id" in record ||
        "away_member_id" in record ||
        "home" in record ||
        "away" in record),
  });
}

function extractOneToOneFixture(
  value: unknown,
  currentMemberId: string,
): OneToOneFixture | null {
  return findCurrentMemberFixture<OneToOneFixture>({
    value,
    currentMemberId,
    isFixture: (record) =>
      (("home_wins" in record && "away_wins" in record) ||
        ("mini_wins" in record && "mini_losses" in record) ||
        "aggregate" in record ||
        "aggregate_result" in record ||
        "is_bye" in record) &&
      ("home_member_id" in record ||
        "away_member_id" in record ||
        "home" in record ||
        "away" in record),
  });
}

function extractLeagueMembers(value: unknown): LeagueMemberRow[] {
  const members: LeagueMemberRow[] = [];
  const seen = new Set<string>();

  function visit(node: unknown) {
    if (Array.isArray(node)) {
      node.forEach(visit);
      return;
    }
    if (!isRecord(node)) return;

    const membershipId =
      typeof node.membership_id === "string"
        ? node.membership_id
        : typeof node.league_member_id === "string"
          ? node.league_member_id
          : null;

    if (membershipId && !seen.has(membershipId)) {
      seen.add(membershipId);
      members.push({
        membership_id: membershipId,
        user_id: typeof node.user_id === "string" ? node.user_id : null,
        display_name:
          typeof node.display_name === "string" ? node.display_name : null,
        club_name: typeof node.club_name === "string" ? node.club_name : null,
        crest_url: typeof node.crest_url === "string" ? node.crest_url : null,
        avatar_zoom:
          typeof node.avatar_zoom === "number"
            ? node.avatar_zoom
            : Number(node.avatar_zoom || 1),
        avatar_x:
          typeof node.avatar_x === "number"
            ? node.avatar_x
            : Number(node.avatar_x || 0),
        avatar_y:
          typeof node.avatar_y === "number"
            ? node.avatar_y
            : Number(node.avatar_y || 0),
      });
    }

    Object.values(node).forEach(visit);
  }

  visit(value);
  return members;
}

function buildDuelSummary({
  currentMemberId,
  fixture,
  membersById,
  mode,
}: {
  currentMemberId: string;
  fixture: FantacalcioFixture | OneToOneFixture | null;
  membersById: Map<string, LeagueMemberRow>;
  mode: "fantacalcio" | "one_to_one";
}): DuelSummary | null {
  if (!fixture) return null;

  const homeId = fixture.home_member_id || fixture.home?.member_id || "";
  const awayId = fixture.away_member_id || fixture.away?.member_id || "";
  const currentIsHome = Boolean(currentMemberId && currentMemberId === homeId);
  const currentIsAway = Boolean(currentMemberId && currentMemberId === awayId);
  const orientFromHome = currentIsHome || !currentIsAway;

  const homeSide: FixtureSide = {
    ...fixture.home,
    member_id: homeId,
    display_name:
      fixture.home?.display_name || fixture.home_display_name || null,
  };
  const awaySide: FixtureSide | null = awayId
    ? {
        ...fixture.away,
        member_id: awayId,
        display_name:
          fixture.away?.display_name || fixture.away_display_name || null,
      }
    : null;
  const leftSide = orientFromHome ? homeSide : awaySide;
  const rightSide = orientFromHome ? awaySide : homeSide;
  const leftId = leftSide?.member_id || currentMemberId || "home";
  const rightId = rightSide?.member_id || "";
  const leftMember = membersById.get(leftId);
  const rightMember = rightId ? membersById.get(rightId) : undefined;
  const bye = fixture.is_bye === true || !rightId;

  let homeScore = 0;
  let awayScore = 0;
  let secondaryLabel: string | null = null;

  if (mode === "fantacalcio") {
    const fantacalcioFixture = fixture as FantacalcioFixture;
    homeScore = toFiniteNumber(
      fantacalcioFixture.home_goals ??
        fantacalcioFixture.result?.home_goals ??
        fantacalcioFixture.home?.goals,
    );
    awayScore = toFiniteNumber(
      fantacalcioFixture.away_goals ??
        fantacalcioFixture.result?.away_goals ??
        fantacalcioFixture.away?.goals,
    );

    const homePoints = toFiniteNumber(
      fantacalcioFixture.home_points ?? fantacalcioFixture.home?.points,
    );
    const awayPoints = toFiniteNumber(
      fantacalcioFixture.away_points ?? fantacalcioFixture.away?.points,
    );
    secondaryLabel = bye
      ? null
      : `${formatLivePoints(currentIsHome ? homePoints : awayPoints)} - ${formatLivePoints(
          currentIsHome ? awayPoints : homePoints,
        )} pt`;
  } else {
    const oneToOneFixture = fixture as OneToOneFixture;
    homeScore = toFiniteNumber(
      oneToOneFixture.home_wins ??
        oneToOneFixture.aggregate_result?.home_wins ??
        oneToOneFixture.aggregate?.home_wins ??
        oneToOneFixture.mini_wins,
    );
    awayScore = toFiniteNumber(
      oneToOneFixture.away_wins ??
        oneToOneFixture.aggregate_result?.away_wins ??
        oneToOneFixture.aggregate?.away_wins ??
        oneToOneFixture.mini_losses,
    );
    const draws = toFiniteNumber(
      oneToOneFixture.draws ??
        oneToOneFixture.aggregate_result?.draws ??
        oneToOneFixture.aggregate?.draws ??
        oneToOneFixture.mini_draws,
    );
    secondaryLabel = bye
      ? null
      : draws === 1
        ? "1 pareggio"
        : `${draws} pareggi`;
  }

  return {
    left: {
      memberId: leftId,
      name:
        leftMember?.club_name ||
        leftMember?.display_name ||
        leftSide?.display_name ||
        "Club FantaGol",
      avatarUrl: leftMember?.crest_url || null,
      avatarZoom: Number(leftMember?.avatar_zoom || 1),
      avatarX: Number(leftMember?.avatar_x || 0),
      avatarY: Number(leftMember?.avatar_y || 0),
    },
    right: bye
      ? null
      : {
          memberId: rightId,
          name:
            rightMember?.club_name ||
            rightMember?.display_name ||
            rightSide?.display_name ||
            "Avversario",
          avatarUrl: rightMember?.crest_url || null,
          avatarZoom: Number(rightMember?.avatar_zoom || 1),
          avatarX: Number(rightMember?.avatar_x || 0),
          avatarY: Number(rightMember?.avatar_y || 0),
        },
    leftScore: orientFromHome ? homeScore : awayScore,
    rightScore: orientFromHome ? awayScore : homeScore,
    secondaryLabel,
    pending: fixture.fixture_phase !== "ready" && !bye,
    bye,
  };
}
function DuelAvatar({
  duelist,
  muted = false,
}: {
  duelist: Duelist | null;
  muted?: boolean;
}) {
  const name = duelist?.name || "Riposo";

  return (
    <div className="flex min-w-0 flex-col items-center">
      <ClubAvatar
        src={duelist?.avatarUrl || null}
        alt={`${name} avatar`}
        fallbackLabel={name}
        zoom={duelist?.avatarZoom || 1}
        x={duelist?.avatarX || 0}
        y={duelist?.avatarY || 0}
        className={`h-11 w-11 shrink-0 border bg-gradient-to-br from-white to-gray-300 text-sm text-black shadow-lg shadow-black/30 ${
          muted ? "border-white/10 opacity-45" : "border-[#A6E824]/45"
        }`}
        imageClassName={muted ? "grayscale" : ""}
      />

      <span
        className={`mt-1 max-w-[72px] truncate text-[10px] font-black uppercase ${
          muted ? "text-gray-600" : "text-gray-300"
        }`}
      >
        {name}
      </span>
    </div>
  );
}

function DashboardModeCard({
  icon,
  title,
  value,
  currentClub,
  duel,
}: {
  icon: ReactNode;
  title: string;
  value?: string;
  currentClub?: Duelist | null;
  duel?: DuelSummary | null;
}) {
  const isBye = duel?.bye === true;

  return (
    <div
      className={`h-full rounded-2xl border p-5 shadow-lg shadow-black/20 transition ${
        isBye
          ? "border-white/5 bg-[#0b0e10] opacity-55 grayscale"
          : "border-white/10 bg-[#111417] hover:border-[#A6E824]/60"
      }`}
    >
      <div className="flex items-start justify-between gap-4">
        <div className="flex min-w-0 items-center gap-3">
          <div className={`shrink-0 ${isBye ? "opacity-40" : ""}`}>{icon}</div>

          <h2 className="truncate text-xl font-black text-white sm:text-2xl">
            {title}
          </h2>
        </div>

        <svg
          aria-hidden="true"
          viewBox="0 0 24 24"
          fill="none"
          className="mt-1 h-6 w-6 shrink-0 text-[#A6E824]"
        >
          <path
            d="M5 12h14M13 6l6 6-6 6"
            stroke="currentColor"
            strokeWidth="2.4"
            strokeLinecap="round"
            strokeLinejoin="round"
          />
        </svg>
      </div>

      {duel || title !== "Punti Puri" ? (
        <div className="mt-5 grid grid-cols-[minmax(0,1fr)_auto_minmax(0,1fr)] items-center gap-3">
          <DuelAvatar
            duelist={duel?.left || currentClub || null}
            muted={isBye}
          />

          <div className="min-w-[92px] text-center">
            <div className="flex items-center justify-center gap-2 text-4xl font-black leading-none">
              <span className={isBye ? "text-gray-600" : "text-[#A6E824]"}>
                {isBye ? 0 : (duel?.leftScore ?? 0)}
              </span>
              <span
                className={`text-2xl ${isBye ? "text-gray-700" : "text-white"}`}
              >
                -
              </span>
              <span className={isBye ? "text-gray-600" : "text-white"}>
                {isBye ? 0 : (duel?.rightScore ?? 0)}
              </span>
            </div>

            <div className="mt-2 text-[10px] font-black uppercase tracking-[0.12em] text-gray-500">
              {duel?.bye
                ? "Riposo"
                : duel?.pending || !duel
                  ? "In attesa"
                  : "Live"}
            </div>

            {!isBye && duel?.secondaryLabel && (
              <div className="mt-1 text-[10px] font-semibold text-gray-600">
                {duel.secondaryLabel}
              </div>
            )}
          </div>

          <DuelAvatar
            duelist={isBye ? null : duel?.right || null}
            muted={isBye || !duel}
          />
        </div>
      ) : (
        <div className="mt-5 flex items-center gap-4">
          <DuelAvatar duelist={currentClub || null} />
          <div>
            <div className="text-4xl font-black leading-none text-[#A6E824]">
              {value ?? "0"}
            </div>
            <div className="mt-2 text-[10px] font-black uppercase tracking-[0.12em] text-gray-500">
              Punti live di giornata
            </div>
          </div>
        </div>
      )}
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
      <div
        className={`mt-2 text-sm font-black ${special ? "text-[#A6E824]" : "text-white"}`}
      >
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
  const [currentLeagueRoundId, setCurrentLeagueRoundId] = useState<string | null>(
    null,
  );
  const [predictionWindowState, setPredictionWindowState] =
    useState<string>("unknown");
  const [recoveryCanOpen, setRecoveryCanOpen] = useState(false);
  const [recoveryWorkspaceOpen, setRecoveryWorkspaceOpen] = useState(false);
  const [recoveryMissingMemberCount, setRecoveryMissingMemberCount] =
    useState(0);
  const [
    recoveryExistingAuthorizationCount,
    setRecoveryExistingAuthorizationCount,
  ] = useState(0);
  const [recoveryOpening, setRecoveryOpening] = useState(false);
  const [liveModeSummary, setLiveModeSummary] = useState<LiveModeSummary>({
    purePoints: 0,
    currentClub: null,
    fantacalcio: null,
    oneToOne: null,
  });

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

      const current = (data || []).find(
        (row: MyLeagueRpcRow) => row.league_id === leagueId,
      );

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

      setCurrentLeagueRoundId(
        currentRound.league_round_id,
      );

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

      const loadedPredictionWindowState =
        rows[0]?.prediction_window_state ?? "unknown";

      setPredictionWindowState(
        loadedPredictionWindowState,
      );

      setRoundNumber(
        currentRound.league_round_number ??
          rows[0]?.league_round_number ??
          null,
      );
      setRoundLabel(
        loadedPredictionWindowState === "open"
          ? "Pronostici aperti"
          : loadedPredictionWindowState === "not_open"
            ? "Pronostici non ancora aperti"
            : "Pronostici chiusi",
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
        }).sort(compareDashboardMatchKickoff),
      );

      const [recoveryAdminResult, recoveryWorkspaceResult] = await Promise.all([
        supabase.rpc("get_prediction_recovery_admin_status_rpc", {
          p_league_round_id: currentRound.league_round_id,
        }),
        supabase.rpc("get_my_prediction_recovery_workspace_rpc", {
          p_league_round_id: currentRound.league_round_id,
        }),
      ]);

      if (recoveryAdminResult.error) {
        console.error(
          "Prediction Recovery admin status failed:",
          recoveryAdminResult.error,
        );
        setRecoveryCanOpen(false);
        setRecoveryMissingMemberCount(0);
        setRecoveryExistingAuthorizationCount(0);
      } else {
        const recoveryAdminRows = (recoveryAdminResult.data || []) as Array<{
          can_open_recovery?: boolean | null;
          missing_member_count?: number | null;
          existing_authorization_count?: number | null;
        }>;

        setRecoveryCanOpen(
          recoveryAdminRows[0]?.can_open_recovery === true,
        );
        setRecoveryMissingMemberCount(
          Number(recoveryAdminRows[0]?.missing_member_count ?? 0),
        );
        setRecoveryExistingAuthorizationCount(
          Number(recoveryAdminRows[0]?.existing_authorization_count ?? 0),
        );
      }

      if (recoveryWorkspaceResult.error) {
        setRecoveryWorkspaceOpen(false);
      } else {
        setRecoveryWorkspaceOpen(
          (recoveryWorkspaceResult.data || []).length > 0,
        );
      }

      const [
        standingsResult,
        matchupResult,
        fantacalcioResult,
        oneToOneResult,
        membersResult,
      ] = await Promise.all([
        supabase.rpc("get_my_standings_preview_rpc", {
          p_league_round_id: currentRound.league_round_id,
        }),
        supabase.rpc("get_my_dashboard_matchups_rpc", {
          p_league_round_id: currentRound.league_round_id,
        }),
        supabase.rpc("get_my_fantacalcio_preview_rpc", {
          p_league_round_id: currentRound.league_round_id,
        }),
        supabase.rpc("get_my_one_to_one_preview_rpc", {
          p_league_round_id: currentRound.league_round_id,
        }),
        supabase.rpc("get_current_league_members_v2_rpc", {
          target_league_id: leagueId,
        }),
      ]);

      if (matchupResult.error) {
        setRoundError(matchupResult.error.message);
        setLoading(false);
        return;
      }

      const members = extractLeagueMembers(membersResult.data || []);
      const membersById = new Map(
        members.map((member) => [member.membership_id, member]),
      );
      const currentMember = members.find(
        (member) => member.user_id === session.user.id,
      );
      const standingsRow = (
        (standingsResult.data || []) as StandingsPreviewRow[]
      )[0];
      const currentMemberId =
        currentMember?.membership_id ||
        standingsRow?.standings_preview?.member?.league_member_id ||
        standingsRow?.member_view?.league_member_id ||
        current.membership_id ||
        "";
      const purePointsRow =
        standingsRow?.standings_preview?.modes?.pure_points?.ranking?.find(
          (row) => row.league_member_id === currentMemberId,
        );
      const matchupRows = (matchupResult.data || []) as DashboardMatchupRow[];

      const scheduledFantacalcioFixture =
        matchupRows.find((row) => row.mode === "fantacalcio") || null;
      const scheduledOneToOneFixture =
        matchupRows.find((row) => row.mode === "one_to_one") || null;

      const fantacalcioPreviewFixture = extractFantacalcioFixture(
        fantacalcioResult.data || [],
        currentMemberId,
      );
      const oneToOnePreviewFixture = extractOneToOneFixture(
        oneToOneResult.data || [],
        currentMemberId,
      );

      const compatibleFantacalcioPreview =
        scheduledFantacalcioFixture &&
        fantacalcioPreviewFixture &&
        (fantacalcioPreviewFixture.home_member_id ||
          fantacalcioPreviewFixture.home?.member_id ||
          "") === scheduledFantacalcioFixture.home_member_id &&
        (fantacalcioPreviewFixture.away_member_id ||
          fantacalcioPreviewFixture.away?.member_id ||
          null) === scheduledFantacalcioFixture.away_member_id
          ? fantacalcioPreviewFixture
          : null;

      const compatibleOneToOnePreview =
        scheduledOneToOneFixture &&
        oneToOnePreviewFixture &&
        (oneToOnePreviewFixture.home_member_id ||
          oneToOnePreviewFixture.home?.member_id ||
          "") === scheduledOneToOneFixture.home_member_id &&
        (oneToOnePreviewFixture.away_member_id ||
          oneToOnePreviewFixture.away?.member_id ||
          null) === scheduledOneToOneFixture.away_member_id
          ? oneToOnePreviewFixture
          : null;

      const fantacalcioFixture: FantacalcioFixture | null =
        scheduledFantacalcioFixture
          ? {
              ...(compatibleFantacalcioPreview || {}),
              fixture_phase: scheduledFantacalcioFixture.fixture_phase,
              is_bye: scheduledFantacalcioFixture.is_bye,
              home_member_id: scheduledFantacalcioFixture.home_member_id,
              home_display_name: scheduledFantacalcioFixture.home_display_name,
              away_member_id: scheduledFantacalcioFixture.away_member_id,
              away_display_name: scheduledFantacalcioFixture.away_display_name,
              home: {
                ...(compatibleFantacalcioPreview?.home || {}),
                member_id: scheduledFantacalcioFixture.home_member_id,
                display_name:
                  scheduledFantacalcioFixture.home_display_name,
              },
              away: scheduledFantacalcioFixture.away_member_id
                ? {
                    ...(compatibleFantacalcioPreview?.away || {}),
                    member_id: scheduledFantacalcioFixture.away_member_id,
                    display_name:
                      scheduledFantacalcioFixture.away_display_name,
                  }
                : null,
            }
          : null;

      const oneToOneFixture: OneToOneFixture | null =
        scheduledOneToOneFixture
          ? {
              ...(compatibleOneToOnePreview || {}),
              fixture_phase: scheduledOneToOneFixture.fixture_phase,
              is_bye: scheduledOneToOneFixture.is_bye,
              home_member_id: scheduledOneToOneFixture.home_member_id,
              home_display_name: scheduledOneToOneFixture.home_display_name,
              away_member_id: scheduledOneToOneFixture.away_member_id,
              away_display_name: scheduledOneToOneFixture.away_display_name,
              home: {
                ...(compatibleOneToOnePreview?.home || {}),
                member_id: scheduledOneToOneFixture.home_member_id,
                display_name:
                  scheduledOneToOneFixture.home_display_name,
              },
              away: scheduledOneToOneFixture.away_member_id
                ? {
                    ...(compatibleOneToOnePreview?.away || {}),
                    member_id: scheduledOneToOneFixture.away_member_id,
                    display_name:
                      scheduledOneToOneFixture.away_display_name,
                  }
                : null,
            }
          : null;

      setLiveModeSummary({
        purePoints: toFiniteNumber(purePointsRow?.round_points),
        currentClub: currentMemberId
          ? {
              memberId: currentMemberId,
              name:
                currentMember?.club_name ||
                currentMember?.display_name ||
                current.display_name ||
                "Club FantaGol",
              avatarUrl: currentMember?.crest_url || null,
              avatarZoom: Number(currentMember?.avatar_zoom || 1),
              avatarX: Number(currentMember?.avatar_x || 0),
              avatarY: Number(currentMember?.avatar_y || 0),
            }
          : null,
        fantacalcio: buildDuelSummary({
          currentMemberId,
          fixture: fantacalcioFixture,
          membersById,
          mode: "fantacalcio",
        }),
        oneToOne: buildDuelSummary({
          currentMemberId,
          fixture: oneToOneFixture,
          membersById,
          mode: "one_to_one",
        }),
      });

      setLoading(false);
    }

    loadDashboard();
  }, [leagueId]);

  const matchGroups = useMemo(
    () => buildDashboardMatchGroups(matches),
    [matches],
  );

  const todayFocusMatch = useMemo(() => {
    const todayKey = getLocalDateKey(new Date());

    const todayCandidates = matches
      .filter(
        (match) =>
          match.kickoff &&
          getLocalDateKey(match.kickoff) === todayKey &&
          !isDashboardMatchTerminal(match),
      )
      .sort(compareDashboardMatchKickoff);

    return (
      todayCandidates.find((match) => isDashboardMatchLive(match)) ??
      todayCandidates[0] ??
      null
    );
  }, [matches]);

  const predictionWindowOpen = predictionWindowState === "open";

  const recoveryWaitingForMissingPredictions =
    !predictionWindowOpen &&
    !recoveryWorkspaceOpen &&
    !recoveryCanOpen &&
    recoveryExistingAuthorizationCount > 0 &&
    recoveryMissingMemberCount > 0;

  const predictionCtaLabel = recoveryOpening
    ? "Riapertura in corso..."
    : predictionWindowOpen
      ? "Inserisci pronostici"
      : recoveryWorkspaceOpen
        ? "Completa i pronostici"
        : recoveryCanOpen
          ? "Riapri pronostici"
          : recoveryWaitingForMissingPredictions
            ? "⏳ Attesa pronostici mancanti"
            : "🔒 Pronostici bloccati";

  const predictionCtaDisabled =
    recoveryOpening ||
    recoveryWaitingForMissingPredictions ||
    (!predictionWindowOpen && !recoveryWorkspaceOpen && !recoveryCanOpen);
  async function refreshPredictionRecoveryState(leagueRoundId: string) {
    const [adminResult, workspaceResult] = await Promise.all([
      supabase.rpc("get_prediction_recovery_admin_status_rpc", {
        p_league_round_id: leagueRoundId,
      }),
      supabase.rpc("get_my_prediction_recovery_workspace_rpc", {
        p_league_round_id: leagueRoundId,
      }),
    ]);

    if (adminResult.error) {
      console.error(
        "Prediction Recovery admin refresh failed:",
        adminResult.error,
      );
      setRecoveryCanOpen(false);
      setRecoveryMissingMemberCount(0);
      setRecoveryExistingAuthorizationCount(0);
    } else {
      const adminRows = (adminResult.data || []) as Array<{
        can_open_recovery?: boolean | null;
          missing_member_count?: number | null;
          existing_authorization_count?: number | null;
      }>;

      setRecoveryCanOpen(
        adminRows[0]?.can_open_recovery === true,
      );
      setRecoveryMissingMemberCount(
        Number(adminRows[0]?.missing_member_count ?? 0),
      );
      setRecoveryExistingAuthorizationCount(
        Number(adminRows[0]?.existing_authorization_count ?? 0),
      );
    }

    if (workspaceResult.error) {
      setRecoveryWorkspaceOpen(false);
    } else {
      setRecoveryWorkspaceOpen(
        (workspaceResult.data || []).length > 0,
      );
    }
  }

  async function handlePredictionCtaClick() {
    if (predictionWindowOpen || recoveryWorkspaceOpen) {
      router.push(`/leghe/${leagueId}/giornata`);
      return;
    }

    if (
      !recoveryCanOpen ||
      !currentLeagueRoundId ||
      recoveryOpening
    ) {
      return;
    }

    setRecoveryOpening(true);
    setRoundError(null);

    try {
      const { error: openRecoveryError } = await supabase.rpc(
        "open_missing_predictions_recovery_rpc",
        {
          p_league_round_id: currentLeagueRoundId,
          p_reason: "dashboard_recovery",
        },
      );

      if (openRecoveryError) {
        setRoundError(openRecoveryError.message);
        return;
      }

      // Server authority determines the missing members and eligible matches.
      // Do not assume the Admin personally receives a Recovery workspace.
      setRecoveryCanOpen(false);

      await refreshPredictionRecoveryState(
        currentLeagueRoundId,
      );
    } finally {
      setRecoveryOpening(false);
    }
  }

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

          <div
            className={`mt-5 grid grid-cols-1 gap-3 ${
              matchGroups.length === 1
                ? ""
                : matchGroups.length === 2
                  ? "md:grid-cols-2"
                  : "md:grid-cols-3"
            }`}
          >
            {matchGroups.map((group, groupIndex) => (
              <div
                key={`round-match-group-${groupIndex}`}
                className="space-y-2 rounded-2xl border border-white/10 bg-white/[0.03] p-3"
              >
                {group.map((match) => (
                  <MatchMiniRow key={match.id} match={match} />
                ))}
              </div>
            ))}
          </div>

          <button
            type="button"
            onClick={handlePredictionCtaClick}
            disabled={predictionCtaDisabled}
            aria-label={predictionCtaLabel}
            className={`mt-6 w-full rounded-2xl px-6 py-4 font-black transition ${
              predictionCtaDisabled
                ? "cursor-not-allowed border border-white/10 bg-[#1a1d1f] text-gray-500"
                : "bg-[#A6E824] text-black shadow-lg shadow-[#A6E824]/20 hover:brightness-110"
            }`}
          >
            {predictionCtaLabel}
          </button>
        </DashboardCard>

        <DashboardCard className="mt-6">
          <div className="flex items-center justify-between gap-4">
            <p className="text-sm font-semibold uppercase tracking-[0.2em] text-gray-400">
              Partita del giorno
            </p>

            <Badge>
              {todayFocusMatch
                ? isDashboardMatchLive(todayFocusMatch)
                  ? "Live"
                  : "Prossima"
                : "—"}
            </Badge>
          </div>

          <div className="mt-4">
            {todayFocusMatch ? (
              <DayMatchRow
                key={todayFocusMatch.id}
                match={todayFocusMatch}
              />
            ) : (
              <div className="rounded-2xl bg-black p-5 text-center text-sm font-semibold text-gray-500">
                Nessuna partita da seguire oggi.
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
            <DashboardModeCard
              icon={<FantaGolModeIcon mode="fantacalcio" />}
              title="Fantacalcio"
              duel={liveModeSummary.fantacalcio}
            />
          </button>

          <button
            type="button"
            onClick={() => router.push(`/leghe/${leagueId}/onetoone`)}
            className="block w-full text-left transition hover:-translate-y-0.5 hover:brightness-110 focus:outline-none focus:ring-2 focus:ring-[#A6E824]/70 focus:ring-offset-2 focus:ring-offset-black"
            aria-label="Apri modalità One To One"
          >
            <DashboardModeCard
              icon={<FantaGolModeIcon mode="one-to-one" />}
              title="One To One"
              duel={liveModeSummary.oneToOne}
            />
          </button>

          <button
            type="button"
            onClick={() => router.push(`/leghe/${leagueId}/giornata`)}
            className="block w-full text-left transition hover:-translate-y-0.5 hover:brightness-110 focus:outline-none focus:ring-2 focus:ring-[#A6E824]/70 focus:ring-offset-2 focus:ring-offset-black"
            aria-label="Apri modalità Punti Puri"
          >
            <DashboardModeCard
              icon={<FantaGolModeIcon mode="punti-puri" />}
              title="Punti Puri"
              value={formatLivePoints(liveModeSummary.purePoints)}
              currentClub={liveModeSummary.currentClub}
            />
          </button>
        </div>

        <div className="mt-6 grid grid-cols-2 gap-4 md:grid-cols-6">
          <DashboardQuickAction
            icon="control"
            label="Control Room"
            href="/control-room"
            special
          />
          <DashboardQuickAction
            icon="target"
            label="Pronostici"
            href={`/leghe/${leagueId}/giornata`}
          />
          <DashboardQuickAction
            icon="live"
            label="Live"
            href={`/leghe/${leagueId}/giornata`}
          />
          <DashboardQuickAction
            icon="ranking"
            label="Classifiche"
            href={leaguePath.rankings(leagueId)}
          />
          <DashboardQuickAction
            icon="calendar"
            label="Calendario"
            href={leaguePath.calendar(leagueId)}
          />
          <DashboardQuickAction
            icon="members"
            label="Membri"
            href={leaguePath.members(leagueId)}
          />
        </div>
      </section>
    </main>
  );
}
