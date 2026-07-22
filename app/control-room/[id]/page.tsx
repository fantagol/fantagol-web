"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import FantaGolLogo from "../../../components/FantaGolLogo";
import HamburgerDrawer from "../../../components/app/HamburgerDrawer";
import TeamCrest from "../../../components/app/TeamCrest";
import { supabase } from "../../../lib/supabaseClient";

type LeagueInfo = {
  leagueName: string;
  displayName: string;
  inviteCode: string;
  role: string;
};

type ExactDistributionItem = {
  rank: number;
  is_top_exact: boolean;
  home_prediction: number;
  away_prediction: number;
  prediction_count: number;
  prediction_percent: number;
  change_from_previous: number | null;
};

type InsightItem = {
  priority: number;
  severity: string;
  parameters: Record<string, unknown>;
  message_key: string;
  insight_code: string;
};

type MarketConsensus = {
  method?: string;
  bookmakersCount?: number;
  probabilities?: {
    home?: number;
    draw?: number;
    away?: number;
  };
  fairDecimalOdds?: {
    home?: number;
    draw?: number;
    away?: number;
  };
};

type MarketContext = {
  market_available?: boolean;
  collected_at?: string | null;
  frozen_at?: string | null;
  policy_version?: string | null;
  official_snapshot_id?: string | null;
  odds_market_snapshot_id?: string | null;
  consensus?: MarketConsensus;
  quality?: {
    reason?: string | null;
    synthetic?: boolean;
    testScope?: string | null;
    hasConsensus?: boolean;
    validBookmakers?: number;
  };
};

type ControlRoomMatch = {
  match_id: string;
  fantagol_round_id: string;
  community_snapshot_id: string;
  market_snapshot_id: string | null;
  slot_number: number;
  kickoff: string | null;
  match_status: string;
  phase: string;
  snapshot_status: string;
  snapshot_version: number;
  built_at: string;
  home_team_name: string;
  away_team_name: string;
  home_team_short_name: string;
  away_team_short_name: string;
  home_team_crest_reference: string | null;
  away_team_crest_reference: string | null;
  home_team_logo_url: string | null;
  away_team_logo_url: string | null;
  home_score: number | null;
  away_score: number | null;
  prediction_count: number;
  member_count: number;
  league_count: number;
  home_pick_percent: number;
  draw_pick_percent: number;
  away_pick_percent: number;
  consensus_outcome: string;
  consensus_percent: number;
  consensus_index: number;
  confidence_index: number;
  chaos_index: number;
  exact_dispersion_index: number;
  over_2_5_percent: number;
  under_2_5_percent: number;
  goal_percent: number;
  no_goal_percent: number;
  avg_home_goals: number;
  avg_away_goals: number;
  avg_total_goals: number;
  sample_quality_status: string;
  sample_quality_score: number;
  market_available: boolean;
  market_context: MarketContext | null;
  trend_context: Record<string, unknown>;
  exact_distribution: ExactDistributionItem[];
  insights: InsightItem[];
};

type ControlRoomOverview = {
  fantagol_round_id: string;
  community_snapshot_id: string;
  round_name: string;
  round_sequence: number;
  round_status: string;
  phase: string;
  snapshot_status: string;
  snapshot_version: number;
  built_at: string;
  opens_at: string | null;
  lock_at: string | null;
  starts_at: string | null;
  prediction_count: number;
  member_count: number;
  league_count: number;
  match_count: number;
  market_snapshot_count: number;
  quality_status: string;
  quality_score: number;
  minimum_sample_satisfied: boolean;
  safest_match: {
    match_id: string;
    slot_number: number;
    value: number;
  } | null;
  most_uncertain_match: {
    match_id: string;
    slot_number: number;
    value: number;
  } | null;
  strongest_trend: Record<string, unknown> | null;
  most_concentrated_exact: Record<string, unknown> | null;
};

type OverviewPayload = {
  available: boolean;
  error_code?: string;
  overview?: ControlRoomOverview;
  matches?: ControlRoomMatch[];
};

type HeatmapItem = ExactDistributionItem & {
  match_id?: string;
  fantagol_round_id?: string;
};

type TrendItem = {
  id?: string;
  match_id?: string;
  metric_code?: string;
  metric_value?: number;
  previous_value?: number | null;
  absolute_change?: number | null;
  percentage_change?: number | null;
  direction?: string | null;
  created_at?: string;
  [key: string]: unknown;
};

type MatchPayload = {
  available: boolean;
  error_code?: string;
  match?: ControlRoomMatch;
  heatmap?: HeatmapItem[];
  trend?: TrendItem[];
};

type MatchSort =
  | "slot"
  | "consensus"
  | "uncertainty"
  | "confidence"
  | "kickoff";

type MatchFilter = "all" | "compact" | "divided" | "market";

const EMPTY_LEAGUE_INFO: LeagueInfo = {
  leagueName: "FantaGol",
  displayName: "Club FantaGol",
  inviteCode: "",
  role: "member",
};

const CONTROL_ROOM_ACCESS_SECONDS = 15 * 60;
const CONTROL_ROOM_ACCESS_STORAGE_PREFIX = "fantagol-control-room-access";

/**
 * Temporary inspection mode.
 *
 * While true:
 * - every page entry starts a fresh 15-minute session;
 * - an expired local timer is automatically replaced;
 * - reaching 00:00 renews the local inspection session instead of redirecting.
 *
 * Set to false when the server-side pass validation and kick-out flow are ready.
 */
const CONTROL_ROOM_SERVICE_ACCESS = true;

function toNumber(value: unknown, fallback = 0): number {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function clamp(value: number): number {
  return Math.max(0, Math.min(100, value));
}

function pct(value: unknown, digits = 0): string {
  return `${toNumber(value).toFixed(digits)}%`;
}

function formatRemainingTime(totalSeconds: number): string {
  const safeSeconds = Math.max(0, totalSeconds);
  const minutes = Math.floor(safeSeconds / 60);
  const seconds = safeSeconds % 60;

  return `${String(minutes).padStart(2, "0")}:${String(seconds).padStart(
    2,
    "0",
  )}`;
}

function formatDateTime(value: string | null | undefined): string {
  if (!value) return "Da definire";

  return new Intl.DateTimeFormat("it-IT", {
    day: "2-digit",
    month: "short",
    hour: "2-digit",
    minute: "2-digit",
  }).format(new Date(value));
}

function cleanTeamName(value: string): string {
  return value
    .replace(/\b(FC|AC|AS|SS|US|CFC|BC)\b/gi, "")
    .replace(/\bCalcio\b/gi, "")
    .replace(/\s+/g, " ")
    .trim();
}

function phaseLabel(value: string): string {
  switch (value) {
    case "pre_live":
      return "Pre-live";
    case "live":
      return "Live";
    case "post_live":
      return "Post-live";
    case "historical":
      return "Storico";
    default:
      return value.replaceAll("_", " ");
  }
}

function qualityLabel(value: string): string {
  switch (value) {
    case "insufficient":
      return "Campione ridotto";
    case "emerging":
      return "Campione emergente";
    case "reliable":
      return "Campione affidabile";
    case "strong":
      return "Campione forte";
    default:
      return value.replaceAll("_", " ");
  }
}

function insightLabel(value: string): string {
  switch (value) {
    case "HIGH_UNCERTAINTY":
      return "Alta incertezza";
    case "COMMUNITY_DIVIDED":
      return "Community divisa";
    case "COMMUNITY_COMPACT":
      return "Community compatta";
    case "EXACT_DISPERSED":
      return "Exact dispersi";
    default:
      return value.replaceAll("_", " ").toLowerCase();
  }
}

function insightDescription(insight: InsightItem): string {
  const parameters = insight.parameters ?? {};

  switch (insight.insight_code) {
    case "HIGH_UNCERTAINTY":
      return `Indice caos ${toNumber(parameters.chaos_index).toFixed(0)}/100`;
    case "COMMUNITY_DIVIDED":
      return `Fiducia ${toNumber(parameters.confidence_index).toFixed(0)}/100`;
    case "COMMUNITY_COMPACT":
      return `Fiducia ${toNumber(parameters.confidence_index).toFixed(0)}/100`;
    case "EXACT_DISPERSED":
      return `Dispersione exact ${toNumber(
        parameters.exact_dispersion_index,
      ).toFixed(0)}/100`;
    default:
      return "Insight calcolato dal motore";
  }
}

function outcomeLabel(value: string): string {
  if (value === "1") return "Casa";
  if (value === "X") return "Pareggio";
  if (value === "2") return "Trasferta";
  return value;
}

function marketProbability(
  match: ControlRoomMatch,
  outcome: "home" | "draw" | "away",
): number | null {
  const value = match.market_context?.consensus?.probabilities?.[outcome];
  return typeof value === "number" ? value * 100 : null;
}

function communityMarketGap(
  match: ControlRoomMatch,
  communityValue: number,
  outcome: "home" | "draw" | "away",
): number | null {
  const market = marketProbability(match, outcome);
  return market === null ? null : communityValue - market;
}

function ControlRoomIcon() {
  return (
    <span className="flex h-16 w-16 shrink-0 items-center justify-center rounded-2xl border border-[#A6E824]/35 bg-[#A6E824]/10 shadow-[0_0_28px_rgba(166,232,36,0.18)]">
      <span className="relative h-11 w-11 rounded-xl border border-[#A6E824]/70 bg-black/40">
        <span className="absolute left-2 top-2 h-2 w-2 rounded-full bg-[#A6E824]" />
        <span className="absolute right-2 top-2 h-2 w-2 rounded-full bg-[#A6E824]/45" />
        <span className="absolute bottom-2 left-2 right-2 flex items-end gap-1">
          <span className="h-3 flex-1 rounded-t bg-[#A6E824]/50" />
          <span className="h-7 flex-1 rounded-t bg-[#A6E824]" />
          <span className="h-5 flex-1 rounded-t bg-[#A6E824]/70" />
        </span>
      </span>
    </span>
  );
}

function MetricCard({
  label,
  value,
  detail,
  emphasis = false,
}: {
  label: string;
  value: string;
  detail: string;
  emphasis?: boolean;
}) {
  return (
    <div
      className={`rounded-2xl border p-4 ${
        emphasis
          ? "border-[#A6E824]/30 bg-[#A6E824]/10"
          : "border-white/10 bg-black/30"
      }`}
    >
      <p className="text-[10px] font-black uppercase tracking-[0.16em] text-gray-500">
        {label}
      </p>
      <p
        className={`mt-2 text-xl font-black ${
          emphasis ? "text-[#A6E824]" : "text-white"
        }`}
      >
        {value}
      </p>
      <p className="mt-1 text-xs leading-5 text-gray-500">{detail}</p>
    </div>
  );
}

function PercentBar({
  label,
  value,
  secondaryValue,
  highlighted = false,
}: {
  label: string;
  value: number;
  secondaryValue?: number | null;
  highlighted?: boolean;
}) {
  const safeValue = clamp(toNumber(value));

  return (
    <div>
      <div className="mb-1 flex items-center justify-between gap-3 text-xs font-black">
        <span className={highlighted ? "text-[#A6E824]" : "text-white"}>
          {label}
        </span>
        <div className="flex items-center gap-2">
          {secondaryValue !== undefined && secondaryValue !== null && (
            <span className="text-[10px] text-gray-500">
              Mercato {pct(secondaryValue)}
            </span>
          )}
          <span className={highlighted ? "text-[#A6E824]" : "text-gray-300"}>
            {pct(safeValue)}
          </span>
        </div>
      </div>
      <div className="h-2 overflow-hidden rounded-full bg-white/10">
        <div
          className={`h-full rounded-full ${
            highlighted ? "bg-[#A6E824]" : "bg-gray-500"
          }`}
          style={{ width: `${safeValue}%` }}
        />
      </div>
    </div>
  );
}


function formatOdd(value: unknown): string {
  const odd = toNumber(value);
  return odd > 1 ? odd.toFixed(2) : "N/D";
}

function BookmakersPanel({ match }: { match: ControlRoomMatch }) {
  const consensus = match.market_context?.consensus;
  const probabilities = consensus?.probabilities;
  const odds = consensus?.fairDecimalOdds;
  const bookmakersCount = toNumber(consensus?.bookmakersCount);
  const collectedAt = match.market_context?.collected_at;
  const frozenAt = match.market_context?.frozen_at;

  if (!match.market_available || !probabilities) {
    return (
      <section className="rounded-2xl border border-sky-400/20 bg-sky-500/[0.06] p-5">
        <p className="text-[10px] font-black uppercase tracking-[0.18em] text-sky-300">
          Bookmakers
        </p>
        <h4 className="mt-2 text-xl font-black text-white">
          Dato non disponibile
        </h4>
        <p className="mt-2 text-sm leading-6 text-gray-400">
          Lo snapshot ufficiale dei bookmakers non è ancora disponibile per
          questa partita.
        </p>
      </section>
    );
  }

  const rows = [
    {
      label: "1",
      probability: toNumber(probabilities.home) * 100,
      odd: odds?.home,
    },
    {
      label: "X",
      probability: toNumber(probabilities.draw) * 100,
      odd: odds?.draw,
    },
    {
      label: "2",
      probability: toNumber(probabilities.away) * 100,
      odd: odds?.away,
    },
  ];

  return (
    <section className="rounded-2xl border border-sky-400/35 bg-gradient-to-br from-sky-500/[0.12] to-blue-950/30 p-5 shadow-[0_0_24px_rgba(56,189,248,0.08)]">
      <div className="flex flex-col justify-between gap-3 sm:flex-row sm:items-start">
        <div>
          <p className="text-[10px] font-black uppercase tracking-[0.18em] text-sky-300">
            Bookmakers
          </p>
          <h4 className="mt-2 text-xl font-black text-white">
            Probabilità e quote ufficiali
          </h4>
        </div>

        <span className="rounded-full border border-sky-300/25 bg-sky-400/10 px-3 py-1.5 text-[10px] font-black uppercase tracking-[0.12em] text-sky-200">
          {bookmakersCount > 0
            ? `${bookmakersCount} bookmaker`
            : "Snapshot ufficiale"}
        </span>
      </div>

      <div className="mt-5 grid gap-3 sm:grid-cols-3">
        {rows.map((row) => (
          <div
            key={row.label}
            className="rounded-xl border border-sky-300/15 bg-black/25 p-4"
          >
            <div className="flex items-center justify-between">
              <span className="text-lg font-black text-white">{row.label}</span>
              <span className="text-xs font-black text-sky-300">
                Quota {formatOdd(row.odd)}
              </span>
            </div>
            <p className="mt-3 text-3xl font-black text-sky-200">
              {pct(row.probability)}
            </p>
            <p className="mt-1 text-[10px] font-black uppercase tracking-[0.12em] text-gray-500">
              Probabilità bookmakers
            </p>
          </div>
        ))}
      </div>

      <div className="mt-4 flex flex-wrap gap-x-5 gap-y-2 border-t border-sky-300/15 pt-4 text-xs text-gray-400">
        <span>
          Raccolto:{" "}
          <strong className="text-white">{formatDateTime(collectedAt)}</strong>
        </span>
        {frozenAt && (
          <span>
            Congelato:{" "}
            <strong className="text-white">{formatDateTime(frozenAt)}</strong>
          </span>
        )}
      </div>
    </section>
  );
}

function CommunityBookmakersComparison({
  match,
}: {
  match: ControlRoomMatch;
}) {
  const items = [
    {
      label: "1",
      community: match.home_pick_percent,
      bookmakers: marketProbability(match, "home"),
    },
    {
      label: "X",
      community: match.draw_pick_percent,
      bookmakers: marketProbability(match, "draw"),
    },
    {
      label: "2",
      community: match.away_pick_percent,
      bookmakers: marketProbability(match, "away"),
    },
  ];

  const validItems = items.filter(
    (item): item is { label: string; community: number; bookmakers: number } =>
      item.bookmakers !== null,
  );

  const averageGap = validItems.length
    ? validItems.reduce(
        (sum, item) => sum + Math.abs(item.community - item.bookmakers),
        0,
      ) / validItems.length
    : null;

  const alignment =
    averageGap === null ? null : Math.max(0, 100 - averageGap * 3);

  return (
    <section className="rounded-2xl border border-amber-400/30 bg-amber-400/[0.07] p-5">
      <div className="flex flex-col justify-between gap-3 sm:flex-row sm:items-start">
        <div>
          <p className="text-[10px] font-black uppercase tracking-[0.18em] text-amber-300">
            Community vs Bookmakers
          </p>
          <h4 className="mt-2 text-xl font-black text-white">
            Allineamento e divergenze
          </h4>
        </div>

        <div className="rounded-xl border border-amber-300/20 bg-black/20 px-4 py-3 text-right">
          <p className="text-[10px] font-black uppercase tracking-[0.12em] text-gray-500">
            Indice di allineamento
          </p>
          <p className="mt-1 text-2xl font-black text-amber-200">
            {alignment === null ? "N/D" : `${alignment.toFixed(0)}/100`}
          </p>
        </div>
      </div>

      <div className="mt-5 grid gap-3 sm:grid-cols-3">
        {items.map((item) => {
          const gap =
            item.bookmakers === null
              ? null
              : item.community - item.bookmakers;

          return (
            <div
              key={item.label}
              className="rounded-xl border border-amber-300/15 bg-black/25 p-4"
            >
              <div className="flex items-center justify-between">
                <span className="text-lg font-black text-white">
                  {item.label}
                </span>
                <span
                  className={`text-sm font-black ${
                    gap === null
                      ? "text-gray-500"
                      : gap >= 0
                        ? "text-[#A6E824]"
                        : "text-amber-300"
                  }`}
                >
                  {gap === null
                    ? "N/D"
                    : `${gap > 0 ? "+" : ""}${gap.toFixed(1)} pt`}
                </span>
              </div>
              <div className="mt-3 space-y-1 text-xs">
                <div className="flex justify-between">
                  <span className="font-black text-[#A6E824]">Community</span>
                  <span className="font-black text-white">
                    {pct(item.community)}
                  </span>
                </div>
                <div className="flex justify-between">
                  <span className="font-black text-sky-300">Bookmakers</span>
                  <span className="font-black text-white">
                    {item.bookmakers === null ? "N/D" : pct(item.bookmakers)}
                  </span>
                </div>
              </div>
            </div>
          );
        })}
      </div>
    </section>
  );
}

function InsightPill({ insight }: { insight: InsightItem }) {
  const high = insight.severity === "high";

  return (
    <span
      title={insightDescription(insight)}
      className={`rounded-full border px-3 py-1.5 text-[10px] font-black uppercase tracking-[0.12em] ${
        high
          ? "border-amber-400/30 bg-amber-400/10 text-amber-300"
          : "border-white/10 bg-black/25 text-gray-300"
      }`}
    >
      {insightLabel(insight.insight_code)}
    </span>
  );
}

function LoadingPanel({ label }: { label: string }) {
  return (
    <section className="rounded-3xl border border-white/10 bg-[#0b1419] p-10 text-center shadow-xl shadow-black/30">
      <div className="mx-auto h-10 w-10 animate-spin rounded-full border-4 border-white/10 border-t-[#A6E824]" />
      <p className="mt-5 text-sm font-black uppercase tracking-[0.16em] text-gray-400">
        {label}
      </p>
    </section>
  );
}

function MatchCard({
  match,
  expanded,
  detailLoading,
  detail,
  onToggle,
}: {
  match: ControlRoomMatch;
  expanded: boolean;
  detailLoading: boolean;
  detail: MatchPayload | null;
  onToggle: () => void;
}) {
  const homeName = cleanTeamName(
    match.home_team_short_name || match.home_team_name,
  );
  const awayName = cleanTeamName(
    match.away_team_short_name || match.away_team_name,
  );
  const topExact = match.exact_distribution?.[0];
  const heatmap = detail?.heatmap ?? match.exact_distribution ?? [];
  const trends = detail?.trend ?? [];

  return (
    <article className="overflow-hidden rounded-3xl border border-white/10 bg-[#0b1419] shadow-xl shadow-black/30">
      <div className="p-5 sm:p-6">
        <div className="flex flex-col justify-between gap-4 lg:flex-row lg:items-start lg:grid-cols-[minmax(0,1fr)_112px]">
          <div className="min-w-0 flex-1">
            <div className="flex items-center justify-between gap-4">
              <span className="rounded-full border border-white/10 bg-black/30 px-3 py-1.5 text-[10px] font-black uppercase tracking-[0.16em] text-gray-400">
                Partita {match.slot_number}
              </span>
              <span className="text-xs font-bold text-gray-500">
                {formatDateTime(match.kickoff)}
              </span>
            </div>

            <div className="mt-5 grid grid-cols-[1fr_auto_1fr] items-center gap-3">
              <div className="flex min-w-0 flex-col items-center gap-2 text-center sm:flex-row sm:text-left">
                <TeamCrest
                  crestReference={match.home_team_crest_reference}
                  logoUrl={match.home_team_logo_url}
                  alt={`${homeName} stemma`}
                  fallbackLabel={homeName}
                  size="xs"
                  className="h-8 w-8 sm:h-10 sm:w-10 lg:h-11 lg:w-11"
                />
                <p className="truncate text-sm font-black sm:text-lg">
                  {homeName}
                </p>
              </div>

              <div className="rounded-xl border border-white/10 bg-black/35 px-3 py-2 text-sm font-black text-gray-300">
                VS
              </div>

              <div className="flex min-w-0 flex-col items-center gap-2 text-center sm:flex-row-reverse sm:text-right">
                <TeamCrest
                  crestReference={match.away_team_crest_reference}
                  logoUrl={match.away_team_logo_url}
                  alt={`${awayName} stemma`}
                  fallbackLabel={awayName}
                  size="xs"
                  className="h-8 w-8 sm:h-10 sm:w-10 lg:h-11 lg:w-11"
                />
                <p className="truncate text-sm font-black sm:text-lg">
                  {awayName}
                </p>
              </div>
            </div>

            <div className="mt-6 rounded-2xl border border-[#A6E824]/25 bg-[#A6E824]/[0.06] p-4">
              <div className="mb-4">
                <p className="text-[10px] font-black uppercase tracking-[0.18em] text-[#A6E824]">
                  Community FantaGol
                </p>
                <p className="mt-1 text-xs text-gray-500">
                  Distribuzione aggregata e anonima dei pronostici
                </p>
              </div>

              <div className="grid gap-3 sm:grid-cols-3">
              <PercentBar
                label="1"
                value={match.home_pick_percent}
                highlighted={match.consensus_outcome === "1"}
              />
              <PercentBar
                label="X"
                value={match.draw_pick_percent}
                highlighted={match.consensus_outcome === "X"}
              />
              <PercentBar
                label="2"
                value={match.away_pick_percent}
                highlighted={match.consensus_outcome === "2"}
              />
              </div>
            </div>
          </div>

          <div className="grid shrink-0 grid-cols-2 gap-3 lg:w-[330px]">
            <MetricCard
              label="Consenso"
              value={`${match.consensus_outcome} · ${pct(
                match.consensus_percent,
              )}`}
              detail={outcomeLabel(match.consensus_outcome)}
              emphasis
            />
            <MetricCard
              label="Top exact"
              value={
                topExact
                  ? `${topExact.home_prediction}-${topExact.away_prediction}`
                  : "—"
              }
              detail={
                topExact
                  ? `${pct(topExact.prediction_percent)} della community`
                  : "Nessun dato"
              }
            />
            <MetricCard
              label="Fiducia"
              value={`${toNumber(match.confidence_index).toFixed(0)}/100`}
              detail="Concentrazione delle scelte"
            />
            <MetricCard
              label="Caos"
              value={`${toNumber(match.chaos_index).toFixed(0)}/100`}
              detail="Incertezza della community"
            />
          </div>
        </div>

        <div className="mt-5 flex flex-wrap gap-2">
          {(match.insights ?? []).map((insight) => (
            <InsightPill
              key={`${match.match_id}-${insight.insight_code}`}
              insight={insight}
            />
          ))}
        </div>

        <div className="mt-5 grid gap-3 border-t border-white/10 pt-5 sm:grid-cols-2 lg:grid-cols-4">
          <MetricCard
            label="Over 2.5"
            value={pct(match.over_2_5_percent)}
            detail={`Under ${pct(match.under_2_5_percent)}`}
          />
          <MetricCard
            label="Goal"
            value={pct(match.goal_percent)}
            detail={`No Goal ${pct(match.no_goal_percent)}`}
          />
          <MetricCard
            label="Media gol"
            value={toNumber(match.avg_total_goals).toFixed(1)}
            detail={`${toNumber(match.avg_home_goals).toFixed(
              1,
            )} casa · ${toNumber(match.avg_away_goals).toFixed(1)} trasferta`}
          />
          <MetricCard
            label="Campione"
            value={qualityLabel(match.sample_quality_status)}
            detail={`${toNumber(match.sample_quality_score).toFixed(
              0,
            )}/100 · ${match.prediction_count} pronostici`}
          />
        </div>

        <div className="mt-5 grid gap-4">
          <BookmakersPanel match={match} />
          <CommunityBookmakersComparison match={match} />
        </div>

        <div className="mt-5 flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
          <div className="flex flex-wrap gap-x-5 gap-y-2 text-xs text-gray-500">
            <span>
              Bookmakers:{" "}
              <strong
                className={
                  match.market_available ? "text-[#A6E824]" : "text-gray-400"
                }
              >
                {match.market_available ? "disponibile" : "non disponibile"}
              </strong>
            </span>
            <span>{match.member_count} utenti</span>
            <span>{match.league_count} leghe</span>
          </div>

          <button
            type="button"
            onClick={onToggle}
            className="rounded-xl border border-[#A6E824]/30 bg-[#A6E824]/10 px-4 py-2.5 text-xs font-black text-[#A6E824] transition hover:border-[#A6E824]"
          >
            {expanded ? "Chiudi analisi" : "Apri analisi completa"}
          </button>
        </div>
      </div>

      {expanded && (
        <div className="border-t border-[#A6E824]/20 bg-black/20 p-5 sm:p-6">
          {detailLoading ? (
            <LoadingPanel label="Caricamento dettaglio partita" />
          ) : (
            <div className="grid gap-5">
              <section>
                <h4 className="text-lg font-black text-white">
                  Heatmap risultati esatti
                </h4>
                <p className="mt-1 text-sm text-gray-500">
                  Distribuzione ordinata dei risultati esatti scelti dalla
                  community.
                </p>

                <div className="mt-4 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
                  {heatmap.length ? (
                    heatmap.slice(0, 8).map((item) => (
                      <div
                        key={`${match.match_id}-${item.home_prediction}-${item.away_prediction}`}
                        className="rounded-2xl border border-white/10 bg-black/30 p-4"
                      >
                        <div className="flex items-center justify-between">
                          <span className="text-xs font-black text-gray-500">
                            #{item.rank}
                          </span>
                          <span className="text-xs font-black text-[#A6E824]">
                            {pct(item.prediction_percent)}
                          </span>
                        </div>
                        <p className="mt-3 text-3xl font-black">
                          {item.home_prediction}-{item.away_prediction}
                        </p>
                        <p className="mt-1 text-xs text-gray-500">
                          {item.prediction_count} pronostici
                        </p>
                      </div>
                    ))
                  ) : (
                    <p className="text-sm text-gray-500">
                      Heatmap non ancora disponibile.
                    </p>
                  )}
                </div>
              </section>

              <section className="grid gap-4 lg:grid-cols-2">
                <div className="rounded-2xl border border-white/10 bg-black/30 p-5">
                  <h4 className="text-sm font-black uppercase tracking-[0.14em] text-gray-400">
                    Dettaglio divergenza Community / Bookmakers
                  </h4>

                  <div className="mt-4 space-y-3">
                    {[
                      {
                        label: "1",
                        gap: communityMarketGap(
                          match,
                          match.home_pick_percent,
                          "home",
                        ),
                      },
                      {
                        label: "X",
                        gap: communityMarketGap(
                          match,
                          match.draw_pick_percent,
                          "draw",
                        ),
                      },
                      {
                        label: "2",
                        gap: communityMarketGap(
                          match,
                          match.away_pick_percent,
                          "away",
                        ),
                      },
                    ].map((item) => (
                      <div
                        key={item.label}
                        className="flex items-center justify-between rounded-xl border border-white/10 bg-black/25 px-4 py-3"
                      >
                        <span className="font-black">{item.label}</span>
                        <span
                          className={`font-black ${
                            item.gap === null
                              ? "text-gray-500"
                              : item.gap > 0
                                ? "text-[#A6E824]"
                                : "text-amber-300"
                          }`}
                        >
                          {item.gap === null
                            ? "N/D"
                            : `${item.gap > 0 ? "+" : ""}${item.gap.toFixed(
                                1,
                              )} pt`}
                        </span>
                      </div>
                    ))}
                  </div>

                  <p className="mt-4 text-xs leading-5 text-gray-500">
                    Il valore descrive la differenza tra quota di scelta della
                    community e probabilità ufficiale normalizzata dei bookmakers.
                   
                  </p>
                </div>

                <div className="rounded-2xl border border-white/10 bg-black/30 p-5">
                  <h4 className="text-sm font-black uppercase tracking-[0.14em] text-gray-400">
                    Cronologia trend
                  </h4>

                  {trends.length ? (
                    <div className="mt-4 space-y-3">
                      {trends.slice(-8).map((trend, index) => (
                        <div
                          key={
                            trend.id ??
                            `${trend.metric_code}-${trend.created_at}-${index}`
                          }
                          className="rounded-xl border border-white/10 bg-black/25 px-4 py-3"
                        >
                          <div className="flex items-center justify-between gap-3">
                            <span className="text-xs font-black uppercase tracking-[0.12em] text-gray-400">
                              {String(
                                trend.metric_code ?? "trend",
                              ).replaceAll("_", " ")}
                            </span>
                            <span className="text-xs text-gray-500">
                              {formatDateTime(trend.created_at)}
                            </span>
                          </div>
                          <p className="mt-2 text-lg font-black text-white">
                            {toNumber(trend.metric_value).toFixed(1)}
                          </p>
                        </div>
                      ))}
                    </div>
                  ) : (
                    <p className="mt-4 text-sm leading-6 text-gray-500">
                      Il primo snapshot non dispone ancora di variazioni
                      temporali. I trend compariranno con i successivi refresh.
                    </p>
                  )}
                </div>
              </section>
            </div>
          )}
        </div>
      )}
    </article>
  );
}

export default function ControlRoomDetailPage() {
  const [menuOpen, setMenuOpen] = useState(false);
  const [leagueInfo, setLeagueInfo] =
    useState<LeagueInfo>(EMPTY_LEAGUE_INFO);
  const [payload, setPayload] = useState<OverviewPayload | null>(null);
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [errorMessage, setErrorMessage] = useState("");
  const [sortBy, setSortBy] = useState<MatchSort>("slot");
  const [filterBy, setFilterBy] = useState<MatchFilter>("all");
  const [expandedMatchId, setExpandedMatchId] = useState<string | null>(null);
  const [matchDetails, setMatchDetails] = useState<
    Record<string, MatchPayload>
  >({});
  const [detailLoadingId, setDetailLoadingId] = useState<string | null>(null);
  const [remainingSeconds, setRemainingSeconds] = useState(
    CONTROL_ROOM_ACCESS_SECONDS,
  );

  useEffect(() => {
    const pathname = window.location.pathname;
    const storageKey = `${CONTROL_ROOM_ACCESS_STORAGE_PREFIX}:${pathname}`;
    const createExpiry = () =>
      Date.now() + CONTROL_ROOM_ACCESS_SECONDS * 1000;

    const storedExpiry = Number(sessionStorage.getItem(storageKey));
    const storedExpiryIsValid =
      Number.isFinite(storedExpiry) && storedExpiry > Date.now();

    let expiry =
      CONTROL_ROOM_SERVICE_ACCESS || !storedExpiryIsValid
        ? createExpiry()
        : storedExpiry;

    sessionStorage.setItem(storageKey, String(expiry));

    const updateCountdown = () => {
      const seconds = Math.max(0, Math.ceil((expiry - Date.now()) / 1000));
      setRemainingSeconds(seconds);

      if (seconds > 0) return;

      if (CONTROL_ROOM_SERVICE_ACCESS) {
        expiry = createExpiry();
        sessionStorage.setItem(storageKey, String(expiry));
        setRemainingSeconds(CONTROL_ROOM_ACCESS_SECONDS);
        console.info(
          "[Control Room] Sessione locale di servizio rinnovata per l'ispezione.",
        );
        return;
      }

      sessionStorage.removeItem(storageKey);
      window.location.replace("/control-room?access=expired");
    };

    updateCountdown();
    const intervalId = window.setInterval(updateCountdown, 1000);

    return () => window.clearInterval(intervalId);
  }, []);

  const loadControlRoom = useCallback(async (manualRefresh = false) => {
    if (manualRefresh) {
      setRefreshing(true);
    } else {
      setLoading(true);
    }

    setErrorMessage("");

    try {
      const {
        data: { session },
        error: sessionError,
      } = await supabase.auth.getSession();

      if (sessionError) throw sessionError;

      if (!session?.user) {
        window.location.href = "/login";
        return;
      }

      const [leagueResult, overviewResult] = await Promise.all([
        supabase.rpc("get_my_leagues_rpc"),
        supabase.rpc("get_control_room_overview_rpc", {
          p_fantagol_round_id: null,
        }),
      ]);

      if (!leagueResult.error) {
        const firstLeague = Array.isArray(leagueResult.data)
          ? leagueResult.data[0]
          : null;

        if (firstLeague) {
          setLeagueInfo({
            leagueName: firstLeague.league_name || "Lega FantaGol",
            displayName: firstLeague.display_name || "Club FantaGol",
            inviteCode:
              firstLeague.invite_code || firstLeague.league_id || "",
            role: firstLeague.role || "member",
          });
        }
      }

      if (overviewResult.error) throw overviewResult.error;

      const nextPayload = overviewResult.data as OverviewPayload | null;

      if (!nextPayload?.available) {
        setPayload(nextPayload);
        setErrorMessage(
          nextPayload?.error_code === "COMMUNITY_ROUND_NOT_FOUND"
            ? "Non è stata trovata una giornata attiva con dati Community Intelligence."
            : "Lo snapshot Community Intelligence non è ancora disponibile.",
        );
        return;
      }

      setPayload({
        ...nextPayload,
        matches: Array.isArray(nextPayload.matches)
          ? nextPayload.matches
          : [],
      });
    } catch (error) {
      console.error("Control Room load failed:", error);
      setPayload(null);
      setErrorMessage(
        "Non è stato possibile caricare i dati della Control Room. Verifica la connessione e riprova.",
      );
    } finally {
      setLoading(false);
      setRefreshing(false);
    }
  }, []);

  useEffect(() => {
    void loadControlRoom();
  }, [loadControlRoom]);

  const overview = payload?.overview;
  const sourceMatches = useMemo(
    () => payload?.matches ?? [],
    [payload?.matches],
  );

  const visibleMatches = useMemo(() => {
    const filtered = sourceMatches.filter((match) => {
      if (filterBy === "compact") {
        return match.insights?.some(
          (insight) => insight.insight_code === "COMMUNITY_COMPACT",
        );
      }

      if (filterBy === "divided") {
        return match.insights?.some(
          (insight) =>
            insight.insight_code === "COMMUNITY_DIVIDED" ||
            insight.insight_code === "HIGH_UNCERTAINTY",
        );
      }

      if (filterBy === "market") {
        return match.market_available;
      }

      return true;
    });

    return [...filtered].sort((first, second) => {
      if (sortBy === "consensus") {
        return second.consensus_percent - first.consensus_percent;
      }

      if (sortBy === "uncertainty") {
        return second.chaos_index - first.chaos_index;
      }

      if (sortBy === "confidence") {
        return second.confidence_index - first.confidence_index;
      }

      if (sortBy === "kickoff") {
        return (
          new Date(first.kickoff ?? 0).getTime() -
          new Date(second.kickoff ?? 0).getTime()
        );
      }

      return first.slot_number - second.slot_number;
    });
  }, [filterBy, sortBy, sourceMatches]);

  const summary = useMemo(() => {
    if (!sourceMatches.length) {
      return {
        avgConsensus: 0,
        avgChaos: 0,
        avgGoals: 0,
        strongest: null as ControlRoomMatch | null,
        uncertain: null as ControlRoomMatch | null,
        compactCount: 0,
        dividedCount: 0,
      };
    }

    return {
      avgConsensus:
        sourceMatches.reduce(
          (sum, match) => sum + toNumber(match.consensus_percent),
          0,
        ) / sourceMatches.length,
      avgChaos:
        sourceMatches.reduce(
          (sum, match) => sum + toNumber(match.chaos_index),
          0,
        ) / sourceMatches.length,
      avgGoals:
        sourceMatches.reduce(
          (sum, match) => sum + toNumber(match.avg_total_goals),
          0,
        ) / sourceMatches.length,
      strongest: [...sourceMatches].sort(
        (first, second) =>
          second.consensus_percent - first.consensus_percent,
      )[0],
      uncertain: [...sourceMatches].sort(
        (first, second) => second.chaos_index - first.chaos_index,
      )[0],
      compactCount: sourceMatches.filter((match) =>
        match.insights?.some(
          (insight) => insight.insight_code === "COMMUNITY_COMPACT",
        ),
      ).length,
      dividedCount: sourceMatches.filter((match) =>
        match.insights?.some(
          (insight) =>
            insight.insight_code === "COMMUNITY_DIVIDED" ||
            insight.insight_code === "HIGH_UNCERTAINTY",
        ),
      ).length,
    };
  }, [sourceMatches]);

  const globalDistribution = useMemo(() => {
    if (!sourceMatches.length) {
      return { home: 0, draw: 0, away: 0, over: 0, goal: 0 };
    }

    const divisor = sourceMatches.length;

    return {
      home:
        sourceMatches.reduce(
          (sum, match) => sum + toNumber(match.home_pick_percent),
          0,
        ) / divisor,
      draw:
        sourceMatches.reduce(
          (sum, match) => sum + toNumber(match.draw_pick_percent),
          0,
        ) / divisor,
      away:
        sourceMatches.reduce(
          (sum, match) => sum + toNumber(match.away_pick_percent),
          0,
        ) / divisor,
      over:
        sourceMatches.reduce(
          (sum, match) => sum + toNumber(match.over_2_5_percent),
          0,
        ) / divisor,
      goal:
        sourceMatches.reduce(
          (sum, match) => sum + toNumber(match.goal_percent),
          0,
        ) / divisor,
    };
  }, [sourceMatches]);

  const topExactAcrossRound = useMemo(
    () =>
      sourceMatches
        .map((match) => ({
          match,
          exact: match.exact_distribution?.[0],
        }))
        .filter(
          (
            item,
          ): item is {
            match: ControlRoomMatch;
            exact: ExactDistributionItem;
          } => Boolean(item.exact),
        )
        .sort(
          (first, second) =>
            second.exact.prediction_percent -
            first.exact.prediction_percent,
        )
        .slice(0, 3),
    [sourceMatches],
  );

  const loadMatchDetail = useCallback(
    async (match: ControlRoomMatch) => {
      if (expandedMatchId === match.match_id) {
        setExpandedMatchId(null);
        return;
      }

      setExpandedMatchId(match.match_id);

      if (matchDetails[match.match_id]) return;

      setDetailLoadingId(match.match_id);

      try {
        const { data, error } = await supabase.rpc(
          "get_control_room_match_rpc",
          {
            p_fantagol_round_id: match.fantagol_round_id,
            p_match_id: match.match_id,
          },
        );

        if (error) throw error;

        const nextDetail = data as MatchPayload;

        setMatchDetails((current) => ({
          ...current,
          [match.match_id]: nextDetail,
        }));
      } catch (error) {
        console.error("Control Room match detail failed:", error);

        setMatchDetails((current) => ({
          ...current,
          [match.match_id]: {
            available: false,
            error_code: "MATCH_DETAIL_LOAD_FAILED",
            match,
            heatmap: match.exact_distribution ?? [],
            trend: [],
          },
        }));
      } finally {
        setDetailLoadingId(null);
      }
    },
    [expandedMatchId, matchDetails],
  );

  return (
    <main className="min-h-screen overflow-x-hidden bg-[#061014] pt-14 text-white">
      <header className="fixed inset-x-0 top-0 z-[80] border-b border-[#A6E824]/25 bg-[#1f2427] shadow-2xl shadow-black/80">
        <div className="mx-auto flex h-14 w-full max-w-6xl items-center justify-between overflow-visible px-4 md:px-6">
          <div className="pointer-events-none relative z-0 block min-w-0 -translate-x-8 translate-y-5 md:-translate-x-20 md:translate-y-6">
            <FantaGolLogo />
          </div>

          <button
            type="button"
            onClick={() => setMenuOpen(true)}
            aria-label="Apri menu"
            className="shrink-0 rounded-lg border border-gray-600 bg-[#2b2f31] px-3 py-2 text-2xl leading-none text-white transition hover:border-[#A6E824]"
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

      <section className="mx-auto w-full max-w-6xl px-4 pb-16 pt-8 sm:px-6 sm:pt-10">
        <section className="relative rounded-3xl border border-[#A6E824]/30 bg-gradient-to-br from-[#263033] via-[#15191b] to-[#080909] p-6 shadow-2xl shadow-black/70 sm:p-8">
          <div
            className={`absolute right-6 top-6 z-10 flex h-16 w-16 flex-col items-center justify-center rounded-2xl border text-center shadow-[0_0_28px_rgba(166,232,36,0.18)] backdrop-blur sm:right-8 sm:top-8 ${
              remainingSeconds <= 120
                ? "border-red-400/50 bg-red-950/90 text-red-200"
                : "border-[#A6E824]/35 bg-[#A6E824]/10 text-[#A6E824]"
            }`}
            aria-live="polite"
            aria-label={`Tempo di accesso residuo ${formatRemainingTime(
              remainingSeconds,
            )}`}
          >
            <p className="font-mono text-base font-black leading-none">
              {formatRemainingTime(remainingSeconds)}
            </p>
            <p className="mt-1 text-[6px] font-black uppercase leading-tight tracking-[0.08em] opacity-80">
              Sessione
              <br />
              Premium
            </p>
          </div>

          <div className="grid gap-6 lg:grid-cols-[1fr_auto] lg:items-start">
            <div className="flex flex-col gap-5 pr-20 sm:flex-row sm:items-center sm:pr-24 lg:pr-0">
              <ControlRoomIcon />

              <div className="min-w-0">
                <p className="text-sm font-black uppercase tracking-[0.3em] text-[#A6E824]">
                  Accesso attivo · 15 minuti
                </p>

                <h1 className="mt-2 text-5xl font-black tracking-tight sm:text-6xl">
                  Control Room
                </h1>

                <p className="mt-4 max-w-3xl text-base leading-7 text-gray-300 sm:text-lg sm:leading-8">
                  La piattaforma di Community Intelligence di FantaGol:
                  consenso, incertezza, risultati esatti, trend e divergenze
                  rispetto al mercato, sempre in forma aggregata e anonima.
                </p>
              </div>
            </div>

            <div className="flex flex-col items-end justify-start gap-3 self-start">
              <button
                type="button"
                onClick={() => void loadControlRoom(true)}
                disabled={refreshing}
                className="rounded-2xl border border-[#A6E824]/35 bg-[#A6E824]/10 px-5 py-3 text-sm font-black text-[#A6E824] transition hover:border-[#A6E824] disabled:cursor-wait disabled:opacity-60"
              >
                {refreshing ? "Aggiornamento…" : "Aggiorna snapshot"}
              </button>
            </div>
          </div>

          {overview && (
            <div className="mt-7 flex flex-wrap gap-2">
              <span className="rounded-full border border-[#A6E824]/30 bg-[#A6E824]/10 px-3 py-2 text-xs font-black text-[#A6E824]">
                {overview.round_name}
              </span>
              <span className="rounded-full border border-white/10 bg-black/25 px-3 py-2 text-xs font-black text-gray-300">
                {phaseLabel(overview.phase)}
              </span>
              <span className="rounded-full border border-white/10 bg-black/25 px-3 py-2 text-xs font-black text-gray-300">
                Snapshot v{overview.snapshot_version}
              </span>
              <span className="rounded-full border border-white/10 bg-black/25 px-3 py-2 text-xs font-black text-gray-300">
                Aggiornato {formatDateTime(overview.built_at)}
              </span>
            </div>
          )}
        </section>

        <div className="mt-6">
          {loading ? (
            <LoadingPanel label="Caricamento Community Intelligence" />
          ) : !payload?.available || !overview ? (
            <section className="rounded-3xl border border-white/10 bg-[#0b1419] p-8 text-center shadow-xl shadow-black/30">
              <h2 className="text-2xl font-black">
                Control Room non disponibile
              </h2>
              <p className="mx-auto mt-3 max-w-xl text-sm leading-6 text-gray-400">
                {errorMessage}
              </p>
              <button
                type="button"
                onClick={() => void loadControlRoom()}
                className="mt-6 rounded-2xl border border-[#A6E824]/35 bg-[#A6E824]/10 px-5 py-3 text-sm font-black text-[#A6E824]"
              >
                Riprova
              </button>
            </section>
          ) : (
            <>
              <section className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
                <MetricCard
                  label="Pronostici"
                  value={overview.prediction_count.toLocaleString("it-IT")}
                  detail={`${overview.member_count} utenti · ${overview.league_count} leghe`}
                  emphasis
                />
                <MetricCard
                  label="Copertura mercato"
                  value={`${overview.market_snapshot_count}/${overview.match_count}`}
                  detail="Partite con snapshot quote"
                />
                <MetricCard
                  label="Qualità campione"
                  value={`${toNumber(overview.quality_score).toFixed(0)}/100`}
                  detail={qualityLabel(overview.quality_status)}
                />
                <MetricCard
                  label="Media consenso"
                  value={pct(summary.avgConsensus)}
                  detail={`Caos medio ${toNumber(summary.avgChaos).toFixed(
                    0,
                  )}/100`}
                />
              </section>

              <section className="mt-6 grid gap-4 lg:grid-cols-3">
                <div className="rounded-3xl border border-white/10 bg-[#0b1419] p-5 shadow-xl shadow-black/30">
                  <p className="text-[10px] font-black uppercase tracking-[0.18em] text-gray-500">
                    Segnale più forte
                  </p>
                  {summary.strongest ? (
                    <>
                      <p className="mt-3 text-xl font-black">
                        {cleanTeamName(
                          summary.strongest.home_team_short_name ||
                            summary.strongest.home_team_name,
                        )}{" "}
                        –{" "}
                        {cleanTeamName(
                          summary.strongest.away_team_short_name ||
                            summary.strongest.away_team_name,
                        )}
                      </p>
                      <p className="mt-2 text-sm text-gray-400">
                        Consenso{" "}
                        <strong className="text-[#A6E824]">
                          {summary.strongest.consensus_outcome} ·{" "}
                          {pct(summary.strongest.consensus_percent)}
                        </strong>
                      </p>
                    </>
                  ) : null}
                </div>

                <div className="rounded-3xl border border-white/10 bg-[#0b1419] p-5 shadow-xl shadow-black/30">
                  <p className="text-[10px] font-black uppercase tracking-[0.18em] text-gray-500">
                    Massima incertezza
                  </p>
                  {summary.uncertain ? (
                    <>
                      <p className="mt-3 text-xl font-black">
                        {cleanTeamName(
                          summary.uncertain.home_team_short_name ||
                            summary.uncertain.home_team_name,
                        )}{" "}
                        –{" "}
                        {cleanTeamName(
                          summary.uncertain.away_team_short_name ||
                            summary.uncertain.away_team_name,
                        )}
                      </p>
                      <p className="mt-2 text-sm text-gray-400">
                        Indice caos{" "}
                        <strong className="text-amber-300">
                          {toNumber(summary.uncertain.chaos_index).toFixed(0)}
                          /100
                        </strong>
                      </p>
                    </>
                  ) : null}
                </div>

                <div className="rounded-3xl border border-white/10 bg-[#0b1419] p-5 shadow-xl shadow-black/30">
                  <p className="text-[10px] font-black uppercase tracking-[0.18em] text-gray-500">
                    Profilo giornata
                  </p>
                  <p className="mt-3 text-xl font-black">
                    {summary.compactCount} compatte · {summary.dividedCount}{" "}
                    incerte
                  </p>
                  <p className="mt-2 text-sm text-gray-400">
                    Media gol prevista{" "}
                    <strong className="text-white">
                      {toNumber(summary.avgGoals).toFixed(1)}
                    </strong>
                  </p>
                </div>
              </section>

              <section className="mt-6 grid gap-4 lg:grid-cols-3">
                <div className="rounded-3xl border border-white/10 bg-[#0b1419] p-5">
                  <h2 className="text-sm font-black uppercase tracking-[0.14em] text-gray-400">
                    Orientamento 1-X-2
                  </h2>
                  <div className="mt-4 space-y-3">
                    <PercentBar label="1" value={globalDistribution.home} />
                    <PercentBar label="X" value={globalDistribution.draw} />
                    <PercentBar label="2" value={globalDistribution.away} />
                  </div>
                </div>

                <div className="rounded-3xl border border-white/10 bg-[#0b1419] p-5">
                  <h2 className="text-sm font-black uppercase tracking-[0.14em] text-gray-400">
                    Profilo gol
                  </h2>
                  <div className="mt-4 space-y-3">
                    <PercentBar
                      label="Over 2.5"
                      value={globalDistribution.over}
                    />
                    <PercentBar
                      label="Under 2.5"
                      value={100 - globalDistribution.over}
                    />
                    <PercentBar
                      label="Goal"
                      value={globalDistribution.goal}
                    />
                    <PercentBar
                      label="No Goal"
                      value={100 - globalDistribution.goal}
                    />
                  </div>
                </div>

                <div className="rounded-3xl border border-white/10 bg-[#0b1419] p-5">
                  <h2 className="text-sm font-black uppercase tracking-[0.14em] text-gray-400">
                    Stato snapshot
                  </h2>
                  <div className="mt-4 grid gap-3">
                    <MetricCard
                      label="Fase"
                      value={phaseLabel(overview.phase)}
                      detail={overview.snapshot_status}
                    />
                    <MetricCard
                      label="Prima partita"
                      value={formatDateTime(overview.starts_at)}
                      detail={`${overview.match_count} partite monitorate`}
                    />
                  </div>
                </div>
              </section>

              <section className="mt-6 rounded-3xl border border-white/10 bg-[#0b1419] p-5 shadow-xl shadow-black/30 sm:p-6">
                <div>
                  <h2 className="text-2xl font-black text-white">
                    Exact più concentrati
                  </h2>
                  <p className="mt-1 text-sm text-gray-500">
                    I risultati esatti con la quota di scelta più alta nella
                    giornata.
                  </p>
                </div>

                <div className="mt-5 grid gap-3 md:grid-cols-3">
                  {topExactAcrossRound.map(({ match, exact }, index) => (
                    <div
                      key={match.match_id}
                      className="rounded-2xl border border-white/10 bg-black/30 p-4"
                    >
                      <div className="flex items-center justify-between">
                        <span className="flex h-8 w-8 items-center justify-center rounded-full bg-[#A6E824]/10 text-sm font-black text-[#A6E824]">
                          {index + 1}
                        </span>
                        <span className="text-xs font-black text-[#A6E824]">
                          {pct(exact.prediction_percent)}
                        </span>
                      </div>
                      <p className="mt-4 text-4xl font-black">
                        {exact.home_prediction}-{exact.away_prediction}
                      </p>
                      <p className="mt-2 truncate text-sm font-semibold text-gray-400">
                        {cleanTeamName(
                          match.home_team_short_name || match.home_team_name,
                        )}{" "}
                        –{" "}
                        {cleanTeamName(
                          match.away_team_short_name || match.away_team_name,
                        )}
                      </p>
                      <p className="mt-1 text-xs text-gray-600">
                        {exact.prediction_count} pronostici
                      </p>
                    </div>
                  ))}
                </div>
              </section>

              <section className="mt-8">
                <div className="flex flex-col justify-between gap-4 lg:flex-row lg:items-end">
                  <div>
                    <p className="text-sm font-black uppercase tracking-[0.22em] text-[#A6E824]">
                      Quadro giornata
                    </p>
                    <h2 className="mt-1 text-3xl font-black">
                      Intelligence partita per partita
                    </h2>
                    <p className="mt-2 text-sm text-gray-500">
                      {visibleMatches.length} di {sourceMatches.length} partite
                      visibili
                    </p>
                  </div>

                  <div className="grid gap-3 sm:grid-cols-2">
                    <label className="text-xs font-black uppercase tracking-[0.12em] text-gray-500">
                      Filtro
                      <select
                        value={filterBy}
                        onChange={(event) =>
                          setFilterBy(event.target.value as MatchFilter)
                        }
                        className="mt-2 w-full rounded-xl border border-white/10 bg-[#111417] px-4 py-3 text-sm font-black normal-case tracking-normal text-white outline-none focus:border-[#A6E824]"
                      >
                        <option value="all">Tutte le partite</option>
                        <option value="compact">Community compatta</option>
                        <option value="divided">Community divisa</option>
                        <option value="market">Mercato disponibile</option>
                      </select>
                    </label>

                    <label className="text-xs font-black uppercase tracking-[0.12em] text-gray-500">
                      Ordina
                      <select
                        value={sortBy}
                        onChange={(event) =>
                          setSortBy(event.target.value as MatchSort)
                        }
                        className="mt-2 w-full rounded-xl border border-white/10 bg-[#111417] px-4 py-3 text-sm font-black normal-case tracking-normal text-white outline-none focus:border-[#A6E824]"
                      >
                        <option value="slot">Ordine giornata</option>
                        <option value="consensus">Consenso più alto</option>
                        <option value="uncertainty">
                          Incertezza più alta
                        </option>
                        <option value="confidence">Fiducia più alta</option>
                        <option value="kickoff">Orario</option>
                      </select>
                    </label>
                  </div>
                </div>

                <div className="mt-5 grid gap-4">
                  {visibleMatches.map((match) => (
                    <MatchCard
                      key={match.match_id}
                      match={match}
                      expanded={expandedMatchId === match.match_id}
                      detailLoading={detailLoadingId === match.match_id}
                      detail={matchDetails[match.match_id] ?? null}
                      onToggle={() => void loadMatchDetail(match)}
                    />
                  ))}
                </div>
              </section>

              <section className="mt-8 rounded-3xl border border-white/10 bg-[#0b1419] p-5 text-sm leading-6 text-gray-400">
                <strong className="text-white">Nota metodologica:</strong> la
                Control Room elabora esclusivamente pronostici ufficialmente
                inviati o bloccati, aggregati in forma anonima. Non legge bozze,
                non mostra dati personali. Le
                differenze con il mercato descrivono soltanto divergenze
                statistiche.
              </section>
            </>
          )}
        </div>
      </section>
    </main>
  );
}

