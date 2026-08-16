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

type MarketExactItem = {
  score: string;
  probability: number;
  prediction_percent: number;
};
type ControlRoomMarketRoundMatch = {
  match_id: string;
  slot_number: number;
  snapshot_id: string;
  match_snapshot_id: string;
  captured_at: string;
  snapshot_source: string;
  sign: {
    home: number;
    draw: number;
    away: number;
  };
  totals: {
    over_25: number | null;
    under_25: number | null;
  };
  btts: {
    goal: number | null;
    no_goal: number | null;
  };
  expected_goals: {
    home: number | null;
    away: number | null;
  };
  confidence: {
    market: number | null;
    final: number | null;
    model_loss: number | null;
  };
  primary_outcome: "1" | "X" | "2";
  output_payload: Record<string, unknown>;
};

type ControlRoomMarketRoundPayload = {
  available: boolean;
  error_code?: string;
  fantagol_round_id?: string;
  match_count?: number;
  latest_captured_at?: string | null;
  matches?: ControlRoomMarketRoundMatch[];
};

type ControlRoomMarketMovement = {
  movement_id: string;
  previous_match_snapshot_id: string;
  current_match_snapshot_id: string;
  signal_type: string;
  signal_key: string;
  previous_probability: number | null;
  current_probability: number | null;
  delta_probability: number | null;
  delta_percentage_points: number | null;
  previous_rank: number | null;
  current_rank: number | null;
  rank_delta: number | null;
  movement_magnitude: number;
  direction: "UP" | "DOWN" | "FLAT";
  created_at: string;
};

type ControlRoomMarketMatchPayload = {
  available: boolean;
  error_code?: string;
  fantagol_round_id?: string;
  match_id?: string;
  snapshot_id?: string;
  match_snapshot_id?: string;
  captured_at?: string;
  snapshot_source?: string;
  sign?: {
    home: number;
    draw: number;
    away: number;
  };
  totals?: {
    over_25: number | null;
    under_25: number | null;
  };
  btts?: {
    goal: number | null;
    no_goal: number | null;
  };
  expected_goals?: {
    home: number | null;
    away: number | null;
  };
  confidence?: {
    market: number | null;
    final: number | null;
    model_loss: number | null;
  };
  primary_outcome?: "1" | "X" | "2";
  output_payload?: Record<string, unknown>;
  movements?: ControlRoomMarketMovement[];
};

function numberOrNull(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value)) {
    return value;
  }

  if (typeof value === "string" && value.trim() !== "") {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : null;
  }

  return null;
}

function probabilityToFairOdd(value: number | null): number | undefined {
  if (value === null || value <= 0) return undefined;
  return 1 / value;
}

function asRecord(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {};
}

function marketExactRows(
  outputPayload: Record<string, unknown> | undefined,
): MarketExactItem[] {
  const exact = outputPayload?.exact;

  if (!Array.isArray(exact)) {
    return [];
  }

  const rows: MarketExactItem[] = [];

  for (const item of exact) {
    const row = asRecord(item);
    const score =
      typeof row.score === "string"
        ? row.score
        : null;
    const probability =
      numberOrNull(row.probability);

    if (
      !score ||
      probability === null
    ) {
      continue;
    }

    rows.push({
      score,
      probability,
      prediction_percent:
        probability <= 1
          ? probability * 100
          : probability,
    });
  }

  return rows.sort(
    (first, second) =>
      second.prediction_percent -
      first.prediction_percent,
  );
}
function mergeMarketRoundMatch(
  match: ControlRoomMatch,
  market: ControlRoomMarketRoundMatch | undefined,
): ControlRoomMatch {
  if (!market) {
    return {
      ...match,
      market_available: false,
      market_context: null,
    };
  }

  const home = numberOrNull(market.sign.home);
  const draw = numberOrNull(market.sign.draw);
  const away = numberOrNull(market.sign.away);
  const over25 = numberOrNull(market.totals.over_25);
  const under25 = numberOrNull(market.totals.under_25);
  const goal = numberOrNull(market.btts.goal);
  const noGoal = numberOrNull(market.btts.no_goal);

  const existingContext =
    match.market_context ?? {};

  const exact =
    marketExactRows(market.output_payload);

  return {
    ...match,
    market_available: true,
    market_context: {
      ...existingContext,
      market_available: true,
      market_snapshot_id:
        market.snapshot_id,
      odds_market_snapshot_id:
        existingContext.odds_market_snapshot_id ??
        null,
      consensus: {
        ...(existingContext.consensus ?? {}),
        probabilities: {
          home: home ?? 0,
          draw: draw ?? 0,
          away: away ?? 0,
        },
        fairDecimalOdds: {
          home:
            probabilityToFairOdd(home),
          draw:
            probabilityToFairOdd(draw),
          away:
            probabilityToFairOdd(away),
        },
      },
      quality: {
        ...(existingContext.quality ?? {}),
      },
      bm_interpolated: {
        snapshotId:
          market.snapshot_id,
        matchSnapshotId:
          market.match_snapshot_id,
        capturedAt:
          market.captured_at,
        snapshotSource:
          market.snapshot_source,
        primaryOutcome:
          market.primary_outcome,
        totals: {
          over25,
          under25,
        },
        btts: {
          goal,
          noGoal,
        },
        expectedGoals: {
          home:
            numberOrNull(
              market.expected_goals.home,
            ),
          away:
            numberOrNull(
              market.expected_goals.away,
            ),
        },
        confidence: {
          market:
            numberOrNull(
              market.confidence.market,
            ),
          final:
            numberOrNull(
              market.confidence.final,
            ),
          modelLoss:
            numberOrNull(
              market.confidence.model_loss,
            ),
        },
        exact,
        outputPayload:
          market.output_payload,
      },
    } as MarketContext,
  };
}
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
  bm_interpolated?: {
    snapshotId: string;
    matchSnapshotId: string;
    capturedAt: string;
    snapshotSource: string;
    primaryOutcome: "1" | "X" | "2";
    totals: {
      over25: number | null;
      under25: number | null;
    };
    btts: {
      goal: number | null;
      noGoal: number | null;
    };
    expectedGoals: {
      home: number | null;
      away: number | null;
    };
    confidence: {
      market: number | null;
      final: number | null;
      modelLoss: number | null;
    };
    exact: MarketExactItem[];
    outputPayload: Record<string, unknown>;
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

type DailyIntelligenceMetricsPayload = {
  available: boolean;
  error_code?: string;
  fantagol_round_id?: string;
  required_match_count?: number;
  eligible_member_count?: number;
  market_quality_score?: number | null;
  market_quality_status?: string | null;
  market_captured_match_count?: number;
  market_required_match_count?: number;
  market_captured_at?: string | null;
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
  outcome_code?: string | null;
  window_code?: string | null;
  from_value?: number | null;
  to_value?: number | null;
  delta_value?: number | null;
  delta_percent?: number | null;
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
  market?: ControlRoomMarketMatchPayload | null;};

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

function marketProbability(
  match: ControlRoomMatch,
  outcome: "home" | "draw" | "away",
): number | null {
  const value = match.market_context?.consensus?.probabilities?.[outcome];
  return typeof value === "number" ? value * 100 : null;
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

function CommunityBookmakersComparison({
  match,
}: {
  match: ControlRoomMatch;
}) {
  const communityExact =
    match.exact_distribution?.[0] ?? null;
  const marketExact =
    topMarketExact(match);

  const communitySign =
    topCommunityOutcome(match);
  const marketSign =
    topMarketOutcome(match);

  const communityOver =
    toNumber(match.over_2_5_percent);
  const communityUnder =
    Math.max(0, 100 - communityOver);
  const communityTotals =
    communityOver >= communityUnder
      ? {
          label: "Over 2.5",
          probability: communityOver,
        }
      : {
          label: "Under 2.5",
          probability: communityUnder,
        };

  const marketTotals =
    topMarketTotals(match);

  const communityGoal =
    toNumber(match.goal_percent);
  const communityNoGoal =
    Math.max(0, 100 - communityGoal);
  const communityBtts =
    communityGoal >= communityNoGoal
      ? {
          label: "Goal",
          probability: communityGoal,
        }
      : {
          label: "No Goal",
          probability: communityNoGoal,
        };

  const marketBtts =
    topMarketBtts(match);

  const rows = [
    {
      label: "Exact",
      communityLabel: communityExact
        ? `${communityExact.home_prediction}-${communityExact.away_prediction}`
        : "—",
      communityPercent: communityExact
        ? toNumber(communityExact.prediction_percent)
        : null,
      marketLabel:
        marketExact?.score ?? "—",
      marketPercent:
        marketExact?.prediction_percent ?? null,
    },
    {
      label: "Segno",
      communityLabel:
        communitySign.label,
      communityPercent:
        communitySign.percent,
      marketLabel:
        marketSign?.label ?? "—",
      marketPercent:
        marketSign?.probability ?? null,
    },
    {
      label: "U/O",
      communityLabel:
        communityTotals.label,
      communityPercent:
        communityTotals.probability,
      marketLabel:
        marketTotals?.label ?? "—",
      marketPercent:
        marketTotals?.probability ?? null,
    },
    {
      label: "G/NG",
      communityLabel:
        communityBtts.label,
      communityPercent:
        communityBtts.probability,
      marketLabel:
        marketBtts?.label ?? "—",
      marketPercent:
        marketBtts?.probability ?? null,
    },
  ];

  return (
    <div className="overflow-hidden rounded-2xl border border-white/10 bg-black/20">
      <div className="grid grid-cols-[minmax(76px,0.85fr)_1fr_1fr] border-b border-white/10 bg-black/25 px-3 py-2.5 text-[10px] font-black uppercase tracking-[0.12em] max-[381px]:grid-cols-[66px_1fr_1fr] max-[381px]:px-2">
        <span className="text-gray-600 max-[394px]:text-[9px] max-[374px]:text-[8.5px] max-[350px]:text-[8px] max-[394px]:tracking-[0.04em] max-[350px]:tracking-normal">
          Parametro
        </span>
        <span className="text-right text-[#A6E824] max-[394px]:text-[9px] max-[374px]:text-[8.5px] max-[350px]:text-[8px] max-[394px]:tracking-[0.04em] max-[350px]:tracking-normal">
          Community
        </span>
        <span className="text-right text-sky-300 max-[394px]:text-[9px] max-[374px]:text-[8.5px] max-[350px]:text-[8px] max-[394px]:tracking-[0.04em] max-[350px]:tracking-normal">
          Bookmakers
        </span>
      </div>

      {rows.map((row) => (
        <div
          key={row.label}
          className="grid grid-cols-[minmax(76px,0.85fr)_1fr_1fr] items-center gap-2 border-b border-white/[0.06] px-3 py-2.5 last:border-b-0 max-[381px]:grid-cols-[66px_1fr_1fr] max-[381px]:gap-1.5 max-[381px]:px-2"
        >
          <span className="text-[10px] font-black uppercase tracking-[0.1em] text-gray-500">
            {row.label}
          </span>

          <span className="min-w-0 text-right text-xs font-black text-[#A6E824] max-[381px]:text-[10px]">
            <span className="block truncate">
              {row.communityLabel}
            </span>
            <span className="tabular-nums text-white">
              {row.communityPercent === null
                ? "N/D"
                : pct(row.communityPercent)}
            </span>
          </span>

          <span className="min-w-0 text-right text-xs font-black text-sky-300 max-[381px]:text-[10px]">
            <span className="block truncate">
              {row.marketLabel}
            </span>
            <span className="tabular-nums text-white">
              {row.marketPercent === null
                ? "N/D"
                : pct(row.marketPercent)}
            </span>
          </span>
        </div>
      ))}
    </div>
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

function countFromPercent(match: ControlRoomMatch, value: number): number {
  return Math.max(
    0,
    Math.round((toNumber(match.prediction_count) * clamp(toNumber(value))) / 100),
  );
}

function topCommunityOutcome(match: ControlRoomMatch) {
  const rows = [
    { label: "1", percent: match.home_pick_percent },
    { label: "X", percent: match.draw_pick_percent },
    { label: "2", percent: match.away_pick_percent },
  ].sort((a, b) => b.percent - a.percent);

  return rows[0];
}

function topMarketOutcome(match: ControlRoomMatch) {
  const probabilities = match.market_context?.consensus?.probabilities;
  const odds = match.market_context?.consensus?.fairDecimalOdds;

  if (!match.market_available || !probabilities) return null;

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
  ].sort((a, b) => b.probability - a.probability);

  return rows[0];
}

const MARKET_COHERENCE_HARD_THRESHOLD_PERCENT = 55;

function parseMarketExactScore(
  score: string,
): { home: number; away: number } | null {
  const match = /^(\d+)-(\d+)$/.exec(score.trim());

  if (!match) return null;

  const home = Number.parseInt(match[1] ?? "", 10);
  const away = Number.parseInt(match[2] ?? "", 10);

  if (!Number.isInteger(home) || !Number.isInteger(away)) {
    return null;
  }

  return { home, away };
}

function coherentMarketExactRows(
  match: ControlRoomMatch,
): MarketExactItem[] {
  const exactRows =
    match.market_context?.bm_interpolated?.exact ?? [];

  if (exactRows.length === 0) return [];

  const sign = topMarketOutcome(match);
  if (!sign) return [];

  const totals = topMarketTotals(match);
  const btts = topMarketBtts(match);

  const hardTotals =
    totals !== null &&
    totals.probability >=
      MARKET_COHERENCE_HARD_THRESHOLD_PERCENT;

  const hardBtts =
    btts !== null &&
    btts.probability >=
      MARKET_COHERENCE_HARD_THRESHOLD_PERCENT;

  return exactRows
    .filter((exact) => {
      const score =
        parseMarketExactScore(exact.score);

      if (!score) return false;

      const signCompatible =
        sign.label === "1"
          ? score.home > score.away
          : sign.label === "X"
            ? score.home === score.away
            : score.home < score.away;

      if (!signCompatible) {
        return false;
      }

      if (hardTotals && totals) {
        const totalGoals =
          score.home + score.away;

        const totalsCompatible =
          totals.label === "Over 2.5"
            ? totalGoals >= 3
            : totalGoals <= 2;

        if (!totalsCompatible) {
          return false;
        }
      }

      if (hardBtts && btts) {
        const bothScored =
          score.home > 0 &&
          score.away > 0;

        const bttsCompatible =
          btts.label === "Goal"
            ? bothScored
            : !bothScored;

        if (!bttsCompatible) {
          return false;
        }
      }

      return true;
    })
    .sort(
      (first, second) =>
        second.prediction_percent -
        first.prediction_percent,
    );
}

function topMarketExact(
  match: ControlRoomMatch,
): MarketExactItem | null {
  return coherentMarketExactRows(match)[0] ?? null;
}

function topMarketTotals(match: ControlRoomMatch) {
  const totals = match.market_context?.bm_interpolated?.totals;
  if (!totals) return null;

  const over = numberOrNull(totals.over25);
  const under = numberOrNull(totals.under25);
  if (over === null || under === null) return null;

  return over >= under
    ? {
        label: "Over 2.5",
        probability: over * 100,
        odd: probabilityToFairOdd(over),
      }
    : {
        label: "Under 2.5",
        probability: under * 100,
        odd: probabilityToFairOdd(under),
      };
}

function topMarketBtts(match: ControlRoomMatch) {
  const btts = match.market_context?.bm_interpolated?.btts;
  if (!btts) return null;

  const goal = numberOrNull(btts.goal);
  const noGoal = numberOrNull(btts.noGoal);
  if (goal === null || noGoal === null) return null;

  return goal >= noGoal
    ? {
        label: "Goal",
        probability: goal * 100,
        odd: probabilityToFairOdd(goal),
      }
    : {
        label: "No Goal",
        probability: noGoal * 100,
        odd: probabilityToFairOdd(noGoal),
      };
}

function normalizeMovementKey(value: string): string {
  return value
    .trim()
    .toUpperCase()
    .replaceAll("-", "_")
    .replaceAll(".", "_")
    .replaceAll(" ", "_");
}

function marketMovementChange(
  movements: ControlRoomMarketMovement[] | undefined,
  signalType: string,
  signalKeys: string[],
): number | null {
  if (!movements?.length) return null;

  const expectedType = normalizeMovementKey(signalType);
  const expectedKeys = new Set(signalKeys.map(normalizeMovementKey));

  const latest = [...movements]
    .filter(
      (movement) =>
        normalizeMovementKey(movement.signal_type) === expectedType &&
        expectedKeys.has(normalizeMovementKey(movement.signal_key)),
    )
    .sort(
      (first, second) =>
        new Date(second.created_at).getTime() -
        new Date(first.created_at).getTime(),
    )[0];

  if (!latest) return null;
  if (latest.delta_percentage_points !== null) {
    return toNumber(latest.delta_percentage_points);
  }
  if (latest.delta_probability !== null) {
    return toNumber(latest.delta_probability) * 100;
  }
  return null;
}

function marketSynthesis(
  match: ControlRoomMatch,
): string {
  const sign = topMarketOutcome(match);
  const totals = topMarketTotals(match);
  const btts = topMarketBtts(match);

  if (!sign) {
    return "Mercato non disponibile";
  }

  const signMaterial =
    sign.probability >=
      MARKET_COHERENCE_HARD_THRESHOLD_PERCENT;

  const totalsMaterial =
    totals !== null &&
    totals.probability >=
      MARKET_COHERENCE_HARD_THRESHOLD_PERCENT;

  const bttsMaterial =
    btts !== null &&
    btts.probability >=
      MARKET_COHERENCE_HARD_THRESHOLD_PERCENT;

  const materialCount =
    Number(signMaterial) +
    Number(totalsMaterial) +
    Number(bttsMaterial);

  const signLead =
    sign.label === "1"
      ? signMaterial
        ? "Padroni di casa favoriti"
        : "Leggera prevalenza dei padroni di casa"
      : sign.label === "2"
        ? signMaterial
          ? "Ospiti favoriti"
          : "Leggera prevalenza degli ospiti"
        : signMaterial
          ? "Partita equilibrata"
          : "Equilibrio senza una direzione netta";

  if (materialCount === 0) {
    return `${signLead} · quadro complessivamente incerto`;
  }

  if (
    totalsMaterial &&
    bttsMaterial &&
    totals &&
    btts
  ) {
    if (
      totals.label === "Over 2.5" &&
      btts.label === "Goal"
    ) {
      return sign.label === "X"
        ? "Partita equilibrata e ricca di gol"
        : `${signLead} in una partita aperta e ricca di gol`;
    }

    if (
      totals.label === "Under 2.5" &&
      btts.label === "No Goal"
    ) {
      return sign.label === "X"
        ? "Partita equilibrata, chiusa e con poche reti"
        : `${signLead} in una partita chiusa e con poche reti`;
    }

    if (
      totals.label === "Under 2.5" &&
      btts.label === "Goal"
    ) {
      return sign.label === "X"
        ? "Partita equilibrata e da punteggio contenuto"
        : `${signLead} con punteggio probabilmente contenuto`;
    }

    if (
      totals.label === "Over 2.5" &&
      btts.label === "No Goal"
    ) {
      return sign.label === "X"
        ? "Equilibrio incerto con possibile punteggio ampio"
        : `${signLead} con possibile margine ampio`;
    }
  }

  if (totalsMaterial && totals) {
    return totals.label === "Over 2.5"
      ? `${signLead} · prevale uno scenario ricco di gol`
      : `${signLead} · prevale uno scenario da poche reti`;
  }

  if (bttsMaterial && btts) {
    return btts.label === "Goal"
      ? `${signLead} · entrambe le squadre possono trovare il gol`
      : `${signLead} · prevale lo scenario No Goal`;
  }

  if (signMaterial) {
    return `${signLead} · incertezza sul numero di reti`;
  }

  return `${signLead} · quadro complessivamente incerto`;
}

function matchVerdict(match: ControlRoomMatch): string {
  return marketSynthesis(match);
}

function CompactSignal({
  label,
  value,
  detail,
  tone,
}: {
  label: string;
  value: string;
  detail: string;
  tone: "community" | "market";
}) {
  return (
    <div className="rounded-2xl border border-white/10 bg-black/25 px-3 py-3.5 sm:px-4">
      <p
        className={`text-[9px] font-black uppercase tracking-[0.16em] ${
          tone === "community" ? "text-[#A6E824]" : "text-sky-300"
        }`}
      >
        {label}
      </p>
      <p className="mt-2 truncate text-xl font-black text-white sm:text-2xl">
        {value}
      </p>
      <p className="mt-1 truncate text-[11px] font-bold text-gray-500">
        {detail}
      </p>
    </div>
  );
}

function DailyExactRow({
  rank,
  match,
  result,
  detail,
  tone,
}: {
  rank: number;
  match: ControlRoomMatch | null;
  result: string;
  detail: string;
  tone: "community" | "market";
}) {
  const homeName = match
    ? cleanTeamName(
        match.home_team_short_name ||
          match.home_team_name,
      )
    : "—";

  const awayName = match
    ? cleanTeamName(
        match.away_team_short_name ||
          match.away_team_name,
      )
    : "—";

  const accent =
    tone === "community"
      ? "text-[#A6E824]"
      : "text-sky-300";

  return (
    <div className="relative grid grid-cols-[minmax(0,1fr)_auto_minmax(64px,auto)_auto_minmax(0,1fr)] items-center gap-x-1 rounded-xl border border-white/10 bg-black/35 px-2.5 py-3 max-[429px]:grid-cols-[minmax(0,1fr)_auto_minmax(58px,auto)_auto_minmax(0,1fr)] max-[429px]:gap-x-0.5 max-[399px]:grid-cols-[minmax(0,1fr)_auto_minmax(54px,auto)_auto_minmax(0,1fr)] max-[381px]:grid-cols-[minmax(0,1fr)_auto_minmax(50px,auto)_auto_minmax(0,1fr)] max-[381px]:gap-x-0 sm:gap-x-1.5 sm:px-3">
      <span
        className={`absolute left-2 top-1.5 text-[9px] font-black ${accent}`}
      >
        #{rank}
      </span>

      <span className="min-w-0 truncate pr-0.5 text-right text-sm font-black text-white max-[429px]:text-[13px] max-[399px]:text-xs max-[381px]:text-[11px] max-[381px]:tracking-[-0.02em] sm:text-base">
        {homeName}
      </span>

      {match ? (
        <TeamCrest
          crestReference={
            match.home_team_crest_reference
          }
          logoUrl={
            match.home_team_logo_url
          }
          alt={`${homeName} stemma`}
          fallbackLabel={homeName}
          size="sm"
          className="h-8 w-8 max-[429px]:h-7 max-[429px]:w-7 max-[399px]:h-[26px] max-[399px]:w-[26px] max-[381px]:h-6 max-[381px]:w-6 sm:h-9 sm:w-9"
        />
      ) : (
        <span className="h-8 w-8 shrink-0 rounded-full border border-sky-300/20 bg-sky-400/5 max-[429px]:h-7 max-[429px]:w-7 max-[399px]:h-[26px] max-[399px]:w-[26px] max-[381px]:h-6 max-[381px]:w-6 sm:h-9 sm:w-9" />
      )}

      <div className="min-w-[64px] text-center max-[429px]:min-w-[58px] max-[399px]:min-w-[54px] max-[381px]:min-w-[50px]">
        <div
          className={`text-xl font-black leading-none max-[429px]:text-lg max-[399px]:text-[17px] max-[381px]:text-base sm:text-2xl ${accent}`}
        >
          {result}
        </div>

        <div className="mt-1 whitespace-nowrap text-[9px] font-semibold leading-[1.15] text-gray-500 max-[381px]:text-[8px] sm:text-[10px]">
          {detail}
        </div>
      </div>

      {match ? (
        <TeamCrest
          crestReference={
            match.away_team_crest_reference
          }
          logoUrl={
            match.away_team_logo_url
          }
          alt={`${awayName} stemma`}
          fallbackLabel={awayName}
          size="sm"
          className="h-8 w-8 max-[429px]:h-7 max-[429px]:w-7 max-[399px]:h-[26px] max-[399px]:w-[26px] max-[381px]:h-6 max-[381px]:w-6 sm:h-9 sm:w-9"
        />
      ) : (
        <span className="h-8 w-8 shrink-0 rounded-full border border-sky-300/20 bg-sky-400/5 max-[429px]:h-7 max-[429px]:w-7 max-[399px]:h-[26px] max-[399px]:w-[26px] max-[381px]:h-6 max-[381px]:w-6 sm:h-9 sm:w-9" />
      )}

      <span className="min-w-0 truncate pl-0.5 text-left text-sm font-black text-white max-[429px]:text-[13px] max-[399px]:text-xs max-[381px]:text-[11px] max-[381px]:tracking-[-0.02em] sm:text-base">
        {awayName}
      </span>
    </div>
  );
}


function DailyIntelligenceCard({
  matches,
  matchDetails,
  expanded,
  onToggle,
}: {
  matches: ControlRoomMatch[];
  matchDetails: Record<string, MatchPayload>;
  expanded: boolean;
  onToggle: () => void;
}) {
  const rankedExact = matches
    .map((match) => {
      const exact =
        [...(match.exact_distribution ?? [])]
          .sort(
            (first, second) =>
              first.rank - second.rank ||
              second.prediction_count -
                first.prediction_count ||
              first.home_prediction -
                second.home_prediction ||
              first.away_prediction -
                second.away_prediction,
          )[0] ?? null;

      return exact
        ? {
            match,
            exact,
          }
        : null;
    })
    .filter(
      (
        item,
      ): item is {
        match: ControlRoomMatch;
        exact: NonNullable<
          ControlRoomMatch["exact_distribution"]
        >[number];
      } => item !== null,
    )
    .sort(
      (first, second) =>
        second.exact.prediction_count -
          first.exact.prediction_count ||
        second.exact.prediction_percent -
          first.exact.prediction_percent ||
        first.match.slot_number -
          second.match.slot_number,
    )
    .slice(0, 5);

  const rankedMarketExact = matches
    .map((match) => ({
      match,
      exact: topMarketExact(match),
    }))
    .filter(
      (
        item,
      ): item is {
        match: ControlRoomMatch;
        exact: MarketExactItem;
      } => item.exact !== null,
    )
    .sort(
      (first, second) =>
        second.exact.prediction_percent -
        first.exact.prediction_percent,
    )
    .slice(0, 5);

  const marketExactCoverage = matches.filter(
    (match) => topMarketExact(match) !== null,
  ).length;
  const marketTotalsCoverage = matches.filter(
    (match) => topMarketTotals(match) !== null,
  ).length;
  const marketBttsCoverage = matches.filter(
    (match) => topMarketBtts(match) !== null,
  ).length;

  const comparisons = matches
    .map((match) => {
      const community =
        topCommunityOutcome(match);

      const market =
        topMarketOutcome(match);

      return market
        ? {
            community,
            market,
          }
        : null;
    })
    .filter(
      (
        item,
      ): item is {
        community: ReturnType<
          typeof topCommunityOutcome
        >;
        market: NonNullable<
          ReturnType<typeof topMarketOutcome>
        >;
      } => Boolean(item),
    );

  const aligned =
    comparisons.filter(
      (item) =>
        item.community.label ===
        item.market.label,
    ).length;

  const divergent =
    comparisons.length - aligned;

  return (
    <section className="rounded-[30px] border border-[#A6E824]/25 bg-[#0b1419] shadow-[0_24px_70px_rgba(0,0,0,0.55),0_0_0_1px_rgba(166,232,36,0.055)]">
      <div className="p-5 sm:p-7">
        <p className="text-xs font-black uppercase tracking-[0.24em] text-[#A6E824]">
          Intelligence della giornata
        </p>

        <h2 className="mt-2 text-3xl font-black text-white sm:text-4xl">
          Top 3 Exact
        </h2>

        <div className="mt-6 grid gap-4 lg:grid-cols-2">
          <section className="rounded-3xl border border-[#A6E824]/20 bg-[#A6E824]/[0.055] p-3 sm:p-4">
            <p className="px-1 text-xs font-black uppercase tracking-[0.18em] text-[#A6E824]">
              Community
            </p>

            <div className="mt-3 space-y-2">
              {[0, 1, 2].map((index) => {
                const item =
                  rankedExact[index];

                return (
                  <DailyExactRow
                    key={
                      item
                        ? `${item.match.match_id}-${item.exact.home_prediction}-${item.exact.away_prediction}`
                        : `community-${index}`
                    }
                    rank={index + 1}
                    match={
                      item?.match ?? null
                    }
                    result={
                      item
                        ? `${item.exact.home_prediction}-${item.exact.away_prediction}`
                        : "—"
                    }
                    detail={
                      item
                        ? `${item.exact.prediction_count} persone`
                        : "N/D"
                    }
                    tone="community"
                  />
                );
              })}
            </div>
          </section>

          <section className="rounded-3xl border border-sky-400/20 bg-sky-500/[0.055] p-3 sm:p-4">
            <p className="px-1 text-xs font-black uppercase tracking-[0.18em] text-sky-300">
              Bookmakers
            </p>

            <div className="mt-3 space-y-2">
              {[0, 1, 2].map((index) => {
                const item = rankedMarketExact[index];

                return (
                  <DailyExactRow
                    key={
                      item
                        ? `market-${item.match.match_id}-${item.exact.score}`
                        : `market-${index}`
                    }
                    rank={index + 1}
                    match={item?.match ?? null}
                    result={item?.exact.score ?? "—"}
                    detail={
                      item
                        ? pct(item.exact.prediction_percent)
                        : "N/D"
                    }
                    tone="market"
                  />
                );
              })}
            </div>
          </section>
        </div>

        <button
          type="button"
          onClick={onToggle}
          className="mt-4 ml-auto block rounded-xl border border-[#A6E824]/30 bg-[#A6E824]/10 px-4 py-2.5 text-xs font-black text-[#A6E824] transition hover:border-[#A6E824]"
        >
          {expanded
            ? "Chiudi analisi"
            : "Apri analisi"}
        </button>
      </div>

      {expanded && (
        <div className="border-t border-[#A6E824]/20 bg-black/20 p-4 sm:p-6">
          <div className="grid gap-4">
            <section className="rounded-3xl border border-[#A6E824]/20 bg-[#A6E824]/[0.045] p-3 sm:p-5">
              <p className="text-xs font-black uppercase tracking-[0.18em] text-[#A6E824]">
                Community · Trend Top 5 Exact
              </p>

              <div className="mt-4 space-y-2">
                {rankedExact.length ? (
                  rankedExact.map(
                    (
                      {
                        match,
                        exact,
                      },
                      index,
                    ) => {
                      const change =
                        exact.change_from_previous ===
                        null
                          ? null
                          : toNumber(
                              exact.change_from_previous,
                            );

                      return (
                        <div
                          key={`${match.match_id}-${exact.home_prediction}-${exact.away_prediction}`}
                          className="grid grid-cols-[24px_minmax(0,1fr)_auto_auto] items-center gap-2 rounded-xl border border-white/10 bg-black/20 px-2.5 py-2.5 max-[429px]:grid-cols-[20px_minmax(0,1fr)_auto_auto] max-[429px]:gap-1.5 max-[399px]:gap-1 max-[381px]:px-2 sm:px-3"
                        >
                          <span className="text-[10px] font-black text-gray-600 max-[381px]:text-[9px]">
                            #{index + 1}
                          </span>

                          <span className="min-w-0 truncate text-xs font-black text-gray-300 max-[429px]:text-[11px] max-[399px]:text-[10px] max-[381px]:text-[9px]">
                            {cleanTeamName(
                              match.home_team_short_name ||
                                match.home_team_name,
                            )}{" "}
                            –{" "}
                            {cleanTeamName(
                              match.away_team_short_name ||
                                match.away_team_name,
                            )}
                          </span>

                          <span className="shrink-0 text-sm font-black text-white max-[399px]:text-xs max-[381px]:text-[11px]">
                            {exact.home_prediction}-
                            {exact.away_prediction}
                          </span>

                          <span className="min-w-[62px] shrink-0 whitespace-nowrap text-right text-[11px] font-black text-[#A6E824] max-[429px]:min-w-[56px] max-[429px]:text-[10px] max-[399px]:min-w-[52px] max-[399px]:text-[9px] max-[381px]:min-w-[48px] max-[381px]:text-[8px]">
                            {trendDirection(
                              change,
                            )}{" "}
                            {change === null
                              ? "N/D"
                              : `${Math.abs(
                                  change,
                                ).toFixed(
                                  1,
                                )}%`}
                          </span>
                        </div>
                      );
                    },
                  )
                ) : (
                  <p className="py-4 text-center text-xs font-bold text-gray-600">
                    N/D
                  </p>
                )}
              </div>
            </section>

            <section className="rounded-3xl border border-sky-400/20 bg-sky-500/[0.045] p-3 sm:p-5">
              <p className="text-xs font-black uppercase tracking-[0.18em] text-sky-300">
                Bookmakers · Trend Top 5 Exact
              </p>

              <div className="mt-4 space-y-2">
                {rankedMarketExact.length ? (
                  rankedMarketExact.map(({ match, exact }, index) => {
                    const movements =
                      matchDetails[match.match_id]?.market?.movements ?? [];

                    const change = marketMovementChange(
                      movements,
                      "EXACT",
                      [exact.score],
                    );

                    return (
                    <div
                      key={`${match.match_id}-${exact.score}`}
                      className="grid grid-cols-[24px_minmax(0,1fr)_auto_auto] items-center gap-2 rounded-xl border border-white/10 bg-black/20 px-2.5 py-2.5 max-[429px]:grid-cols-[20px_minmax(0,1fr)_auto_auto] max-[429px]:gap-1.5 max-[399px]:gap-1 max-[381px]:px-2 sm:px-3"
                    >
                      <span className="text-[10px] font-black text-gray-600 max-[381px]:text-[9px]">
                        #{index + 1}
                      </span>
                      <span className="min-w-0 truncate text-xs font-black text-gray-300 max-[429px]:text-[11px] max-[399px]:text-[10px] max-[381px]:text-[9px]">
                        {cleanTeamName(match.home_team_short_name || match.home_team_name)} –{" "}
                        {cleanTeamName(match.away_team_short_name || match.away_team_name)}
                      </span>
                      <span className="shrink-0 text-sm font-black text-white max-[399px]:text-xs">
                        {exact.score}
                      </span>
                      <span className="min-w-[62px] shrink-0 whitespace-nowrap text-right text-[11px] font-black text-sky-300 max-[429px]:min-w-[56px] max-[429px]:text-[10px] max-[399px]:min-w-[52px] max-[399px]:text-[9px] max-[381px]:min-w-[48px] max-[381px]:text-[8px]">
                        {pct(exact.prediction_percent)}{" "}
                        <span className="text-gray-500">
                          {trendDirection(change)}{" "}
                          {change === null
                            ? "N/D"
                            : `${Math.abs(change).toFixed(1)}%`}
                        </span>
                      </span>
                    </div>
                    );
                  })
                ) : (
                  <p className="py-4 text-center text-xs font-bold text-gray-600">
                    N/D
                  </p>
                )}
              </div>
            </section>

            <section
              className="rounded-3xl border border-amber-400/30 bg-amber-400/[0.05] p-3 sm:p-5"
              data-r38c6c7-detail-comparison="TOP3_CANONICAL_MATCH_COMPARISON"
            >
              <p className="text-xs font-black uppercase tracking-[0.18em] text-amber-300">
                Community vs Bookmakers
              </p>

              <p className="mt-2 text-xs font-bold text-gray-500">
                Confronto coerente sulle stesse partite del Top 3
              </p>

              <div className="mt-4 space-y-4">
                {rankedExact
                  .slice(0, 3)
                  .map(
                    (
                      {
                        match,
                      },
                      index,
                    ) => (
                      <div
                        key={`top3-comparison-${match.match_id}`}
                        className="overflow-hidden rounded-2xl border border-white/10 bg-black/20"
                      >
                        <div className="flex items-center gap-2 border-b border-white/10 px-3 py-2.5">
                          <span className="shrink-0 text-[10px] font-black text-gray-600">
                            #{index + 1}
                          </span>

                          <span className="min-w-0 truncate text-xs font-black text-white">
                            {cleanTeamName(
                              match.home_team_short_name ||
                                match.home_team_name,
                            )}{" "}
                            –{" "}
                            {cleanTeamName(
                              match.away_team_short_name ||
                                match.away_team_name,
                            )}
                          </span>
                        </div>

                        <div className="p-2.5 sm:p-3">
                          <CommunityBookmakersComparison
                            match={match}
                          />
                        </div>
                      </div>
                    ),
                  )}
              </div>
            </section>
          </div>

          <button
            type="button"
            onClick={onToggle}
            className="mt-5 ml-auto block rounded-xl border border-[#A6E824]/30 bg-[#A6E824]/10 px-4 py-2.5 text-xs font-black text-[#A6E824] transition hover:border-[#A6E824]"
            data-r39-r4-l-final-daily-bottom-close="true"
          >
            Chiudi analisi
          </button>
        </div>
      )}
    </section>
  );
}

function trendCurrentValue(
  trend: TrendItem,
): number {
  return toNumber(
    trend.to_value ??
      trend.metric_value,
  );
}


function trendChange(
  trend: TrendItem,
): number | null {
  const value =
    trend.delta_percent ??
    trend.percentage_change;

  if (
    value === null ||
    value === undefined
  ) {
    return null;
  }

  return toNumber(value);
}


function trendDirection(
  change: number | null,
): string {
  if (
    change === null ||
    Math.abs(change) < 0.0001
  ) {
    return "–";
  }

  return change > 0
    ? "↑"
    : "↓";
}


function trendLabel(
  value: string | null | undefined,
): string {
  if (!value) return "—";

  const upper =
    value.toUpperCase();

  if (
    upper === "HOME" ||
    upper === "1"
  ) {
    return "1";
  }

  if (
    upper === "DRAW" ||
    upper === "X"
  ) {
    return "X";
  }

  if (
    upper === "AWAY" ||
    upper === "2"
  ) {
    return "2";
  }

  if (
    upper.includes("OVER") &&
    upper.includes("2")
  ) {
    return "Over 2.5";
  }

  if (
    upper.includes("UNDER") &&
    upper.includes("2")
  ) {
    return "Under 2.5";
  }

  if (
    upper === "GOAL" ||
    upper === "GG"
  ) {
    return "Goal";
  }

  if (
    upper.includes("NO_GOAL") ||
    upper === "NG"
  ) {
    return "No Goal";
  }

  return value.replaceAll("_", " ");
}


function latestMetricRows(
  trends: TrendItem[],
  metricCode: string,
): TrendItem[] {
  const rows =
    trends
      .filter(
        (trend) =>
          trend.metric_code === metricCode,
      )
      .sort(
        (first, second) =>
          new Date(
            second.created_at ?? 0,
          ).getTime() -
          new Date(
            first.created_at ?? 0,
          ).getTime(),
      );

  const unique =
    new Map<string, TrendItem>();

  for (const row of rows) {
    const key =
      row.outcome_code ??
      "__TOTAL__";

    if (!unique.has(key)) {
      unique.set(key, row);
    }
  }

  return [...unique.values()].sort(
    (first, second) =>
      trendCurrentValue(second) -
      trendCurrentValue(first),
  );
}


function TrendRow({
  rank,
  label,
  value,
  change,
  tone,
}: {
  rank?: number;
  label: string;
  value: string;
  change: number | null;
  tone: "community" | "market";
}) {
  return (
    <div className="grid grid-cols-[auto_minmax(0,1fr)_auto_auto] items-center gap-2 rounded-xl border border-white/10 bg-black/20 px-3 py-2.5 max-[429px]:gap-1.5 max-[429px]:px-2.5 max-[399px]:gap-1 max-[381px]:px-2">
      {rank !== undefined ? (
        <span className="w-5 shrink-0 text-[10px] font-black text-gray-600 max-[399px]:w-4 max-[381px]:text-[9px]">
          #{rank}
        </span>
      ) : (
        <span className="hidden" />
      )}

      <span className="min-w-0 truncate text-sm font-black text-white max-[429px]:text-xs max-[399px]:text-[11px] max-[381px]:text-[10px]">
        {label}
      </span>

      <span
        className={`shrink-0 whitespace-nowrap text-xs font-black max-[399px]:text-[10px] max-[381px]:text-[9px] ${
          tone === "community"
            ? "text-[#A6E824]"
            : "text-sky-300"
        } ml-auto min-w-[4.5rem] text-right tabular-nums`}
       data-r38c6c6="R38C6C6_TREND_VALUE_COLUMN">
        {value}
      </span>

      <span className="min-w-[62px] shrink-0 whitespace-nowrap text-right text-[11px] font-black text-gray-400 max-[429px]:min-w-[56px] max-[429px]:text-[10px] max-[399px]:min-w-[50px] max-[399px]:text-[9px] max-[381px]:min-w-[46px] max-[381px]:text-[8px]">
        {trendDirection(change)}{" "}
        {change === null
          ? "N/D"
          : `${Math.abs(
              change,
            ).toFixed(1)}%`}
      </span>
    </div>
  );
}

function CommunityTrendPanel({
  trends,
  heatmap,
}: {
  trends: TrendItem[];
  heatmap: HeatmapItem[];
}) {
  const exactRows =
    latestMetricRows(
      trends,
      "exact_share",
    );

  const signRows =
    latestMetricRows(
      trends,
      "sign_share",
    );

  const overUnderRows =
    latestMetricRows(
      trends,
      "over_under_share",
    );

  const goalRows =
    latestMetricRows(
      trends,
      "goal_no_goal_share",
    );

  const exactFallback =
    heatmap
      .slice(0, 3)
      .map((item) => ({
        label:
          `${item.home_prediction}-${item.away_prediction}`,
        value:
          pct(
            item.prediction_percent,
            1,
          ),
        change:
          item.change_from_previous === null
            ? null
            : toNumber(
                item.change_from_previous,
              ),
      }));

  return (
    <section className="rounded-3xl border border-[#A6E824]/20 bg-[#A6E824]/[0.045] p-4 sm:p-5">
      <p className="text-xs font-black uppercase tracking-[0.18em] text-[#A6E824]">
        Community · Trend settimanale
      </p>

      <div className="mt-4 grid gap-5 lg:grid-cols-2">
        <div>
          <p className="mb-2 text-[10px] font-black uppercase tracking-[0.14em] text-gray-500">
            Exact · Top 3
          </p>

          <div className="space-y-2">
            {(exactRows.length
              ? exactRows
                  .slice(0, 3)
                  .map((row) => ({
                    label:
                      trendLabel(
                        row.outcome_code,
                      ),
                    value:
                      pct(
                        trendCurrentValue(row),
                        1,
                      ),
                    change:
                      trendChange(row),
                  }))
              : exactFallback
            ).map((row, index) => (
              <TrendRow
                key={`${row.label}-${index}`}
                rank={index + 1}
                label={row.label}
                value={row.value}
                change={row.change}
                tone="community"
              />
            ))}
          </div>
        </div>

        <div>
          <p className="mb-2 text-[10px] font-black uppercase tracking-[0.14em] text-gray-500">
            Segno
          </p>

          <div className="space-y-2">
            {signRows.length ? (
              signRows
                .slice(0, 3)
                .map((row, index) => (
                  <TrendRow
                    key={`${row.outcome_code}-${index}`}
                    label={
                      trendLabel(
                        row.outcome_code,
                      )
                    }
                    value={
                      pct(
                        trendCurrentValue(row),
                        1,
                      )
                    }
                    change={
                      trendChange(row)
                    }
                    tone="community"
                  />
                ))
            ) : (
              <p className="py-3 text-xs font-bold text-gray-600">
                N/D
              </p>
            )}
          </div>
        </div>

        <div>
          <p className="mb-2 text-[10px] font-black uppercase tracking-[0.14em] text-gray-500">
            U/O
          </p>

          <div className="space-y-2">
            {overUnderRows.length ? (
              overUnderRows
                .slice(0, 2)
                .map((row, index) => (
                  <TrendRow
                    key={`${row.outcome_code}-${index}`}
                    label={
                      trendLabel(
                        row.outcome_code,
                      )
                    }
                    value={
                      pct(
                        trendCurrentValue(row),
                        1,
                      )
                    }
                    change={
                      trendChange(row)
                    }
                    tone="community"
                  />
                ))
            ) : (
              <p className="py-3 text-xs font-bold text-gray-600">
                N/D
              </p>
            )}
          </div>
        </div>

        <div>
          <p className="mb-2 text-[10px] font-black uppercase tracking-[0.14em] text-gray-500">
            G/NG
          </p>

          <div className="space-y-2">
            {goalRows.length ? (
              goalRows
                .slice(0, 2)
                .map((row, index) => (
                  <TrendRow
                    key={`${row.outcome_code}-${index}`}
                    label={
                      trendLabel(
                        row.outcome_code,
                      )
                    }
                    value={
                      pct(
                        trendCurrentValue(row),
                        1,
                      )
                    }
                    change={
                      trendChange(row)
                    }
                    tone="community"
                  />
                ))
            ) : (
              <p className="py-3 text-xs font-bold text-gray-600">
                N/D
              </p>
            )}
          </div>
        </div>
      </div>
    </section>
  );
}


function MarketTrendPanel({
  match,
  movements,
}: {
  match: ControlRoomMatch;
  movements?: ControlRoomMarketMovement[];
}) {
  const market = topMarketOutcome(match);
  const exactRows =
    coherentMarketExactRows(match).slice(0, 3);
  const totals = topMarketTotals(match);
  const btts = topMarketBtts(match);

  const signChange = market
    ? marketMovementChange(movements, "SIGN", [market.label])
    : null;
  const totalsChange = totals
    ? marketMovementChange(
        movements,
        "TOTALS",
        totals.label === "Over 2.5"
          ? ["OVER_25", "OVER_2_5", "OVER"]
          : ["UNDER_25", "UNDER_2_5", "UNDER"],
      )
    : null;
  const bttsChange = btts
    ? marketMovementChange(
        movements,
        "BTTS",
        btts.label === "Goal"
          ? ["GOAL", "GG"]
          : ["NO_GOAL", "NOGOAL", "NG"],
      )
    : null;

  return (
    <section className="rounded-3xl border border-sky-400/20 bg-sky-500/[0.045] p-4 sm:p-5">
      <p className="text-xs font-black uppercase tracking-[0.18em] text-sky-300">
        Bookmakers · Trend settimanale
      </p>

      <div className="mt-4 grid gap-5 lg:grid-cols-2">
        <div>
          <p className="mb-2 text-[10px] font-black uppercase tracking-[0.14em] text-gray-500">
            Exact · Top 3
          </p>
          <div className="space-y-2">
            {exactRows.length ? (
              exactRows.map((exact, index) => (
                <TrendRow
                  key={exact.score}
                  rank={index + 1}
                  label={exact.score}
                  value={pct(exact.prediction_percent)}
                  change={marketMovementChange(
                    movements,
                    "EXACT",
                    [exact.score],
                  )}
                  tone="market"
                />
              ))
            ) : (
              <p className="py-3 text-xs font-bold text-gray-600">N/D</p>
            )}
          </div>
        </div>

        <div>
          <p className="mb-2 text-[10px] font-black uppercase tracking-[0.14em] text-gray-500">
            Segno
          </p>
          {market ? (
            <TrendRow
              label={market.label}
              value={pct(market.probability)}
              change={signChange}
              tone="market"
            />
          ) : (
            <p className="py-3 text-xs font-bold text-gray-600">N/D</p>
          )}
        </div>

        <div>
          <p className="mb-2 text-[10px] font-black uppercase tracking-[0.14em] text-gray-500">
            U/O
          </p>
          {totals ? (
            <TrendRow
              label={totals.label}
              value={pct(totals.probability)}
              change={totalsChange}
              tone="market"
            />
          ) : (
            <p className="py-3 text-xs font-bold text-gray-600">N/D</p>
          )}
        </div>

        <div>
          <p className="mb-2 text-[10px] font-black uppercase tracking-[0.14em] text-gray-500">
            G/NG
          </p>
          {btts ? (
            <TrendRow
              label={btts.label}
              value={pct(btts.probability)}
              change={bttsChange}
              tone="market"
            />
          ) : (
            <p className="py-3 text-xs font-bold text-gray-600">N/D</p>
          )}
        </div>
      </div>
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
    match.home_team_short_name ||
      match.home_team_name,
  );

  const awayName = cleanTeamName(
    match.away_team_short_name ||
      match.away_team_name,
  );

  const topExact =
    match.exact_distribution?.[0];

  const communityOutcome =
    topCommunityOutcome(match);

  const marketOutcome =
    topMarketOutcome(match);

  const marketExact =
    topMarketExact(match);

  const marketOver =
    topMarketTotals(match);

  const marketGoal =
    topMarketBtts(match);

  const heatmap =
    detail?.heatmap ??
    match.exact_distribution ??
    [];

  const trends =
    detail?.trend ??
    [];

  const communityOver =
    match.over_2_5_percent >=
    match.under_2_5_percent
      ? {
          value: "Over 2.5",
          percent:
            match.over_2_5_percent,
        }
      : {
          value: "Under 2.5",
          percent:
            match.under_2_5_percent,
        };

  const communityGoal =
    match.goal_percent >=
    match.no_goal_percent
      ? {
          value: "Goal",
          percent:
            match.goal_percent,
        }
      : {
          value: "No Goal",
          percent:
            match.no_goal_percent,
        };

  return (
    <article className="overflow-hidden rounded-[30px] border border-white/15 bg-[#0b1419] shadow-[0_28px_80px_rgba(0,0,0,0.62),0_0_0_1px_rgba(255,255,255,0.045),0_0_30px_rgba(166,232,36,0.03)]">
      <div className="p-5 sm:p-7">
        <div className="flex items-center justify-between gap-4">
          <span className="text-[10px] font-black uppercase tracking-[0.18em] text-gray-600">
            Partita {match.slot_number}
          </span>

          <span className="text-xs font-bold text-gray-500">
            {formatDateTime(match.kickoff)}
          </span>
        </div>

        <div className="mt-4 grid grid-cols-[1fr_auto_1fr] items-center gap-3 border-b border-white/10 pb-5 sm:gap-5">
          <div className="flex min-w-0 flex-col items-center gap-2.5 text-center sm:flex-row sm:text-left">
            <TeamCrest
              crestReference={
                match.home_team_crest_reference
              }
              logoUrl={
                match.home_team_logo_url
              }
              alt={`${homeName} stemma`}
              fallbackLabel={homeName}
              size="xs"
              className="h-12 w-12 sm:h-14 sm:w-14 lg:h-16 lg:w-16"
            />

            <p className="truncate text-lg font-black sm:text-2xl">
              {homeName}
            </p>
          </div>

          <div className="rounded-xl border border-white/10 bg-black/35 px-3 py-2 text-sm font-black text-gray-400 sm:px-4">
            VS
          </div>

          <div className="flex min-w-0 flex-col items-center gap-2.5 text-center sm:flex-row-reverse sm:text-right">
            <TeamCrest
              crestReference={
                match.away_team_crest_reference
              }
              logoUrl={
                match.away_team_logo_url
              }
              alt={`${awayName} stemma`}
              fallbackLabel={awayName}
              size="xs"
              className="h-12 w-12 sm:h-14 sm:w-14 lg:h-16 lg:w-16"
            />

            <p className="truncate text-lg font-black sm:text-2xl">
              {awayName}
            </p>
          </div>
        </div>

        <div className="mt-5 grid gap-4 lg:grid-cols-2">
          <section className="rounded-3xl border border-[#A6E824]/20 bg-[#A6E824]/[0.055] p-4">
            <p className="text-xs font-black uppercase tracking-[0.18em] text-[#A6E824]">
              Community
            </p>

            <div className="mt-3 grid grid-cols-2 gap-2.5">
              <CompactSignal
                tone="community"
                label="Exact"
                value={
                  topExact
                    ? `${topExact.home_prediction}-${topExact.away_prediction}`
                    : "—"
                }
                detail={
                  topExact
                    ? `${topExact.prediction_count} persone`
                    : "N/D"
                }
              />

              <CompactSignal
                tone="community"
                label="Segno"
                value={
                  communityOutcome.label
                }
                detail={`${countFromPercent(
                  match,
                  communityOutcome.percent,
                )} persone`}
              />

              <CompactSignal
                tone="community"
                label="U/O"
                value={
                  communityOver.value
                }
                detail={`${countFromPercent(
                  match,
                  communityOver.percent,
                )} persone`}
              />

              <CompactSignal
                tone="community"
                label="G/NG"
                value={
                  communityGoal.value
                }
                detail={`${countFromPercent(
                  match,
                  communityGoal.percent,
                )} persone`}
              />
            </div>
          </section>

          <section className="rounded-3xl border border-sky-400/20 bg-sky-500/[0.055] p-4">
            <p className="text-xs font-black uppercase tracking-[0.18em] text-sky-300">
              Bookmakers
            </p>

            <div className="mt-3 grid grid-cols-2 gap-2.5">
              <CompactSignal
                tone="market"
                label="Exact"
                value={marketExact?.score ?? "—"}
                detail={
                  marketExact
                    ? pct(marketExact.prediction_percent)
                    : "N/D"
                }
              />

              <CompactSignal
                tone="market"
                label="Segno"
                value={marketOutcome?.label ?? "—"}
                detail={
                  marketOutcome
                    ? pct(marketOutcome.probability)
                    : "N/D"
                }
              />

              <CompactSignal
                tone="market"
                label="U/O"
                value={marketOver?.label ?? "—"}
                detail={
                  marketOver
                    ? pct(marketOver.probability)
                    : "N/D"
                }
              />

              <CompactSignal
                tone="market"
                label="G/NG"
                value={marketGoal?.label ?? "—"}
                detail={
                  marketGoal
                    ? pct(marketGoal.probability)
                    : "N/D"
                }
              />
            </div>
          </section>
        </div>

        <section className="mt-4 rounded-2xl border border-amber-400/30 bg-amber-400/[0.07] px-4 py-3.5">
          <div className="flex items-center justify-between gap-4">
            

            <span className="text-sm font-black text-white">
              {matchVerdict(match)}
            </span>
          </div>
        </section>

        <div className="mt-4 flex items-center justify-between gap-4">
          <div className="text-[11px] font-bold text-gray-600">
            {match.prediction_count} pronostici
            {" · "}
            {match.member_count} utenti
          </div>

          <button
            type="button"
            onClick={onToggle}
            className="shrink-0 rounded-xl border border-[#A6E824]/30 bg-[#A6E824]/10 px-4 py-2.5 text-xs font-black text-[#A6E824] transition hover:border-[#A6E824]"
          >
            {expanded
              ? "Chiudi analisi"
              : "Apri analisi"}
          </button>
        </div>
      </div>

      {expanded && (
        <div className="border-t border-[#A6E824]/20 bg-black/20 p-5 sm:p-6">
          {detailLoading ? (
            <LoadingPanel label="Caricamento trend partita" />
          ) : (
            <div className="grid gap-4">
              <CommunityTrendPanel
                trends={trends}
                heatmap={heatmap}
              />

              <MarketTrendPanel
                match={match}
                movements={detail?.market?.movements ?? []}
              />

              <CommunityBookmakersComparison
                match={match}
              />
            </div>
          )}

          <button
            type="button"
            onClick={onToggle}
            className="mt-5 ml-auto block rounded-xl border border-[#A6E824]/30 bg-[#A6E824]/10 px-4 py-2.5 text-xs font-black text-[#A6E824] transition hover:border-[#A6E824]"
            data-r39-r4-l-r4-bottom-close="true"
          >
            Chiudi analisi
          </button>
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
  const [dailyIntelligenceMetrics, setDailyIntelligenceMetrics] =
    useState<DailyIntelligenceMetricsPayload | null>(null);
  const [loading, setLoading] = useState(true);
  const [, setRefreshing] = useState(false);
  const [errorMessage, setErrorMessage] = useState("");
  const [sortBy] = useState<MatchSort>("kickoff");
  const [filterBy] = useState<MatchFilter>("all");
  const [dailyAnalysisOpen, setDailyAnalysisOpen] = useState(false);
  const [expandedMatchId, setExpandedMatchId] = useState<string | null>(null);
  const [matchDetails, setMatchDetails] = useState<
    Record<string, MatchPayload>
  >({});
  const [detailLoadingId, setDetailLoadingId] = useState<string | null>(null);
  const [remainingSeconds, setRemainingSeconds] = useState(0);
  const [premiumAccessReady, setPremiumAccessReady] = useState(false);

  useEffect(() => {
    let cancelled = false;
    let redirected = false;
    let syncInFlight = false;
    let accessConfirmed = false;
    let currentRemainingSeconds = 0;

    const isLocalDevelopment =
      process.env.NODE_ENV === "development" &&
      (window.location.hostname === "localhost" ||
        window.location.hostname === "127.0.0.1");

    if (isLocalDevelopment) {
      accessConfirmed = true;
      currentRemainingSeconds = 15 * 60;
      setRemainingSeconds(currentRemainingSeconds);
      setPremiumAccessReady(true);

      return () => {
        cancelled = true;
      };
    }

    const match = window.location.pathname.match(
      /^\/control-room\/([^/]+)\/?$/,
    );

    const requestedSessionId = match
      ? decodeURIComponent(match[1])
      : null;

    const redirectExpired = () => {
      if (cancelled || redirected) return;

      redirected = true;
      accessConfirmed = false;
      setPremiumAccessReady(false);
      setRemainingSeconds(0);

      window.location.replace("/control-room?access=expired");
    };

    const syncPremiumStatus = async () => {
      if (cancelled || redirected || syncInFlight) return;

      syncInFlight = true;

      try {
        const { data, error } = await supabase.rpc(
          "get_my_premium_access_status_rpc",
          {
            p_resource_code: "CONTROL_ROOM",
          },
        );

        if (error) {
          throw error;
        }

        if (cancelled || redirected) return;

        const status =
          data && typeof data === "object" && !Array.isArray(data)
            ? (data as Record<string, unknown>)
            : null;

        const activeSessionId =
          typeof status?.session_id === "string"
            ? status.session_id
            : null;

        const backendRemainingSeconds = Number(
          status?.remaining_seconds ?? 0,
        );

        const hasValidRemainingSeconds =
          Number.isFinite(backendRemainingSeconds) &&
          backendRemainingSeconds > 0;

        if (
          status?.authorized !== true ||
          !requestedSessionId ||
          activeSessionId !== requestedSessionId ||
          !hasValidRemainingSeconds
        ) {
          redirectExpired();
          return;
        }

        currentRemainingSeconds = Math.max(
          0,
          Math.trunc(backendRemainingSeconds),
        );

        accessConfirmed = true;
        setRemainingSeconds(currentRemainingSeconds);
        setPremiumAccessReady(true);
      } catch (error) {
        console.error(
          "[Control Room] Premium access verification failed.",
          error,
        );

        if (!accessConfirmed) {
          redirectExpired();
        }
      } finally {
        syncInFlight = false;
      }
    };

    void syncPremiumStatus();

    const countdownIntervalId = window.setInterval(() => {
      if (cancelled || redirected || !accessConfirmed) {
        return;
      }

      currentRemainingSeconds = Math.max(
        0,
        currentRemainingSeconds - 1,
      );

      setRemainingSeconds(currentRemainingSeconds);

      if (currentRemainingSeconds === 0) {
        accessConfirmed = false;
        void syncPremiumStatus();
      }
    }, 1000);

    const serverSyncIntervalId = window.setInterval(() => {
      void syncPremiumStatus();
    }, 30000);

    const handleVisibilityChange = () => {
      if (document.visibilityState === "visible") {
        void syncPremiumStatus();
      }
    };

    document.addEventListener(
      "visibilitychange",
      handleVisibilityChange,
    );

    return () => {
      cancelled = true;

      window.clearInterval(countdownIntervalId);
      window.clearInterval(serverSyncIntervalId);

      document.removeEventListener(
        "visibilitychange",
        handleVisibilityChange,
      );
    };
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

      const resolvedRoundId =
        nextPayload?.overview?.fantagol_round_id ??
        nextPayload?.matches?.[0]?.fantagol_round_id ??
        null;

      if (resolvedRoundId) {
        const metricsResult = await supabase.rpc(
          "get_control_room_daily_intelligence_metrics_rpc",
          {
            p_fantagol_round_id: resolvedRoundId,
          },
        );

        if (metricsResult.error) {
          console.error(
            "Daily intelligence metrics load failed:",
            metricsResult.error,
          );
          setDailyIntelligenceMetrics(null);
        } else {
          setDailyIntelligenceMetrics(
            metricsResult.data as DailyIntelligenceMetricsPayload,
          );
        }
      } else {
        setDailyIntelligenceMetrics(null);
      }
        setErrorMessage(
          nextPayload?.error_code === "COMMUNITY_ROUND_NOT_FOUND"
            ? "Non è stata trovata una giornata attiva con dati Community Intelligence."
            : "Lo snapshot Community Intelligence non è ancora disponibile.",
        );
        return;
      }

      const communityMatches =
        Array.isArray(nextPayload.matches)
          ? nextPayload.matches
          : [];

      const marketRoundId =
        communityMatches[0]?.fantagol_round_id ??
        null;

      let mergedMatches =
        communityMatches;

      if (marketRoundId) {
        const marketRoundResult =
          await supabase.rpc(
            "get_control_room_market_round_rpc",
            {
              p_fantagol_round_id:
                marketRoundId,
            },
          );

        if (marketRoundResult.error) {
          console.error(
            "Control Room market round load failed:",
            marketRoundResult.error,
          );
        } else {
          const marketRound =
            marketRoundResult.data as
              | ControlRoomMarketRoundPayload
              | null;

          if (
            marketRound?.available &&
            Array.isArray(
              marketRound.matches,
            )
          ) {
            const marketByMatchId =
              new Map(
                marketRound.matches.map(
                  (item) => [
                    item.match_id,
                    item,
                  ] as const,
                ),
              );

            mergedMatches =
              communityMatches.map(
                (match) =>
                  mergeMarketRoundMatch(
                    match,
                    marketByMatchId.get(
                      match.match_id,
                    ),
                  ),
              );
          } else {
            mergedMatches =
              communityMatches.map(
                (match) =>
                  mergeMarketRoundMatch(
                    match,
                    undefined,
                  ),
              );
          }
        }
      }

      setPayload({
        ...nextPayload,
        matches: mergedMatches,
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
    if (!premiumAccessReady) return;

    void loadControlRoom();
  }, [loadControlRoom, premiumAccessReady]);

  const overview = payload?.overview;
  const sourceMatches = useMemo(
    () => payload?.matches ?? [],
    [payload?.matches],
  );

  useEffect(() => {
    let cancelled = false;

    async function loadDailyIntelligenceMetrics() {
      const roundId =
        sourceMatches.find(
          (match) =>
            Boolean(match.fantagol_round_id),
        )?.fantagol_round_id ?? null;

      if (!roundId) {
        if (!cancelled) {
          setDailyIntelligenceMetrics(null);
        }
        return;
      }

      const metricsResult = await supabase.rpc(
        "get_control_room_daily_intelligence_metrics_rpc",
        {
          p_fantagol_round_id: roundId,
        },
      );

      if (cancelled) return;

      if (metricsResult.error) {
        console.error(
          "Daily intelligence metrics load failed:",
          metricsResult.error,
        );
        setDailyIntelligenceMetrics(null);
        return;
      }

      const metricsPayload =
        metricsResult.data as DailyIntelligenceMetricsPayload | null;

      setDailyIntelligenceMetrics(
        metricsPayload?.available
          ? metricsPayload
          : null,
      );
    }

    void loadDailyIntelligenceMetrics();

    return () => {
      cancelled = true;
    };
  }, [sourceMatches]);

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

  const DAILY_UNCERTAINTY_MINIMUM = 20;

  const communityMaturity = useMemo(() => {
    if (!overview) return 0;

    const requiredMatches = Math.max(
      sourceMatches.length,
      1,
    );
    const eligibleBaseline =
      toNumber(
        dailyIntelligenceMetrics?.eligible_member_count,
      );

    if (eligibleBaseline <= 0) {
      return 0;
    }

    const participationComponent =
      Math.min(
        toNumber(overview.member_count) /
          eligibleBaseline,
        1,
      );

    const volumeComponent =
      Math.min(
        toNumber(overview.prediction_count) /
          (eligibleBaseline * requiredMatches),
        1,
      );

    const leagueComponent =
      Math.min(
        toNumber(overview.league_count) / 5,
        1,
      );

    const coverageComponent =
      Math.min(
        sourceMatches.length /
          requiredMatches,
        1,
      );

    return (
      0.45 * participationComponent +
      0.25 * volumeComponent +
      0.20 * leagueComponent +
      0.10 * coverageComponent
    );
  }, [
    dailyIntelligenceMetrics?.eligible_member_count,
    overview,
    sourceMatches.length,
  ]);

  const communityWeight = useMemo(
    () =>
      Math.min(
        0.5,
        Math.max(
          0.1,
          0.1 + 0.4 * communityMaturity,
        ),
      ),
    [communityMaturity],
  );

  const weightedUncertainMatch = useMemo(() => {
    const candidates = sourceMatches
      .map((match) => {
        const marketFinalConfidence =
          numberOrNull(
            match.market_context
              ?.bm_interpolated
              ?.confidence
              ?.final,
          );

        if (marketFinalConfidence === null) {
          return null;
        }

        const normalizedMarketConfidence =
          marketFinalConfidence <= 1
            ? marketFinalConfidence * 100
            : marketFinalConfidence;

        const bmUncertainty =
          Math.max(
            0,
            Math.min(
              100,
              100 - normalizedMarketConfidence,
            ),
          );

        const mergedUncertainty =
          communityWeight *
            toNumber(match.chaos_index) +
          (1 - communityWeight) *
            bmUncertainty;

        return {
          match,
          mergedUncertainty,
        };
      })
      .filter(
        (
          candidate,
        ): candidate is {
          match: ControlRoomMatch;
          mergedUncertainty: number;
        } => candidate !== null,
      )
      .sort(
        (first, second) =>
          second.mergedUncertainty -
            first.mergedUncertainty ||
          first.match.slot_number -
            second.match.slot_number,
      );

    const strongestCandidate =
      candidates[0] ?? null;

    if (
      !strongestCandidate ||
      strongestCandidate.mergedUncertainty <
        DAILY_UNCERTAINTY_MINIMUM
    ) {
      return null;
    }

    return strongestCandidate;
  }, [communityWeight, sourceMatches]);

  const dailyAnalysisCoverage = useMemo(() => {
    if (!dailyIntelligenceMetrics?.available) {
      return {
        requiredMatches: Math.max(
          sourceMatches.length,
          1,
        ),
        jointCovered: 0,
        percent: null as number | null,
      };
    }

    const requiredMatches = Math.max(
      toNumber(
        dailyIntelligenceMetrics.required_match_count,
      ),
      sourceMatches.length,
      1,
    );

    const marketCaptured = Math.max(
      0,
      toNumber(
        dailyIntelligenceMetrics
          .market_captured_match_count,
      ),
    );

    const jointCovered = Math.min(
      sourceMatches.length,
      marketCaptured,
      requiredMatches,
    );

    return {
      requiredMatches,
      jointCovered,
      percent:
        (jointCovered / requiredMatches) * 100,
    };
  }, [
    dailyIntelligenceMetrics,
    sourceMatches.length,
  ]);

  const dailySolidity = useMemo(() => {
    if (!overview) return null;

    const communityQuality =
      Math.max(
        0,
        Math.min(
          100,
          toNumber(overview.quality_score),
        ),
      ) / 100;

    const marketQualityRaw =
      numberOrNull(
        dailyIntelligenceMetrics?.market_quality_score,
      );

    if (marketQualityRaw === null) {
      return null;
    }

    const marketQuality =
      Math.max(
        0,
        Math.min(
          1,
          marketQualityRaw <= 1
            ? marketQualityRaw
            : marketQualityRaw / 100,
        ),
      );

    const communityEvidenceReliability =
      0.6 * communityMaturity +
      0.4 * communityQuality;

    if (
      dailyAnalysisCoverage.percent === null
    ) {
      return null;
    }

    const coverage =
      dailyAnalysisCoverage.percent / 100;

    return (
      coverage *
      (
        communityWeight *
          communityEvidenceReliability +
        (1 - communityWeight) *
          marketQuality
      ) *
      100
    );
  }, [
    communityMaturity,
    communityWeight,
    dailyAnalysisCoverage.percent,
    dailyIntelligenceMetrics?.market_quality_score,
    overview,
  ]);

  const dailyConvergence = useMemo(() => {
    if (!dailyIntelligenceMetrics?.available) {
      return null;
    }

    let agreements = 0;
    let considered = 0;

    for (const match of sourceMatches) {
      const marketOutcome =
        topMarketOutcome(match);

      const marketTotals =
        topMarketTotals(match);

      const marketBtts =
        topMarketBtts(match);

      const communitySign =
        topCommunityOutcome(match);

      if (marketOutcome) {
        considered += 1;

        if (
          communitySign.label ===
          marketOutcome.label
        ) {
          agreements += 1;
        }
      }

      const communityOver =
        toNumber(match.over_2_5_percent);

      const communityUnder =
        toNumber(match.under_2_5_percent);

      const communityUo =
        communityOver >= communityUnder
          ? {
              label: "Over 2.5",
              probability: communityOver,
            }
          : {
              label: "Under 2.5",
              probability: communityUnder,
            };

      if (
        marketTotals &&
        communityUo.probability >=
          MARKET_COHERENCE_HARD_THRESHOLD_PERCENT &&
        marketTotals.probability >=
          MARKET_COHERENCE_HARD_THRESHOLD_PERCENT
      ) {
        considered += 1;

        if (
          communityUo.label ===
          marketTotals.label
        ) {
          agreements += 1;
        }
      }

      const communityGoal =
        toNumber(match.goal_percent);

      const communityNoGoal =
        toNumber(match.no_goal_percent);

      const communityBtts =
        communityGoal >= communityNoGoal
          ? {
              label: "Goal",
              probability: communityGoal,
            }
          : {
              label: "No Goal",
              probability: communityNoGoal,
            };

      if (
        marketBtts &&
        communityBtts.probability >=
          MARKET_COHERENCE_HARD_THRESHOLD_PERCENT &&
        marketBtts.probability >=
          MARKET_COHERENCE_HARD_THRESHOLD_PERCENT
      ) {
        considered += 1;

        if (
          communityBtts.label ===
          marketBtts.label
        ) {
          agreements += 1;
        }
      }
    }

    if (considered === 0) {
      return null;
    }

    const rawConvergence =
      (agreements / considered) * 100;

    return (
      50 +
      communityMaturity *
        (rawConvergence - 50)
    );
  }, [
    communityMaturity,
    dailyIntelligenceMetrics?.available,
    sourceMatches,
  ]);

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

  const ensureMatchDetailLoaded = useCallback(
    async (match: ControlRoomMatch) => {
      if (matchDetails[match.match_id]) return;

      setDetailLoadingId(match.match_id);

      try {
        const [communityDetailResult, marketDetailResult] =
          await Promise.all([
            supabase.rpc(
              "get_control_room_match_rpc",
              {
                p_fantagol_round_id:
                  match.fantagol_round_id,
                p_match_id:
                  match.match_id,
              },
            ),
            supabase.rpc(
              "get_control_room_market_match_rpc",
              {
                p_fantagol_round_id:
                  match.fantagol_round_id,
                p_match_id:
                  match.match_id,
              },
            ),
          ]);

        if (communityDetailResult.error) {
          throw communityDetailResult.error;
        }

        if (marketDetailResult.error) {
          console.error(
            "Control Room market match detail failed:",
            marketDetailResult.error,
          );
        }

        const nextDetail =
          communityDetailResult.data as MatchPayload;

        const marketDetail =
          marketDetailResult.error
            ? null
            : (
                marketDetailResult.data as
                  | ControlRoomMarketMatchPayload
                  | null
              );

        setMatchDetails((current) => ({
          ...current,
          [match.match_id]: {
            ...nextDetail,
            market:
              marketDetail?.available
                ? marketDetail
                : null,
          } as MatchPayload & {
            market:
              | ControlRoomMarketMatchPayload
              | null;
          },
        }));
      } catch (error) {
        console.error(
          "Control Room match detail failed:",
          error,
        );

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
    [matchDetails],
  );

  const loadMatchDetail = useCallback(
    async (match: ControlRoomMatch) => {
      if (expandedMatchId === match.match_id) {
        setExpandedMatchId(null);
        return;
      }

      setExpandedMatchId(match.match_id);

      await ensureMatchDetailLoaded(match);
    },
    [
      ensureMatchDetailLoaded,
      expandedMatchId,
    ],
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

          <div>
            <div className="flex flex-col gap-5 pr-20 sm:flex-row sm:items-center sm:pr-24">
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

          </div>

          {overview && (

            <div className="mt-7 flex flex-wrap gap-2">
              <span className="rounded-full border border-[#A6E824]/30 bg-[#A6E824]/10 px-3 py-2 text-xs font-black text-[#A6E824]">
                {overview.round_name}
              </span>
              <span className="rounded-full border border-white/10 bg-black/25 px-5 py-2 text-xs font-black text-gray-300">
                {phaseLabel(overview.phase)} · Kick off {formatDateTime(overview.starts_at)}
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
              <DailyIntelligenceCard
                matches={sourceMatches}
                expanded={dailyAnalysisOpen}
                matchDetails={matchDetails}
                onToggle={() => {
                  const opening = !dailyAnalysisOpen;

                  setDailyAnalysisOpen(opening);

                  if (opening) {
                    const topMarketMatches = sourceMatches
                      .map((match) => ({
                        match,
                        exact: topMarketExact(match),
                      }))
                      .filter(
                        (
                          item,
                        ): item is {
                          match: ControlRoomMatch;
                          exact: MarketExactItem;
                        } => Boolean(item.exact),
                      )
                      .sort(
                        (first, second) =>
                          second.exact.prediction_percent -
                          first.exact.prediction_percent,
                      )
                      .slice(0, 5);

                    for (const { match } of topMarketMatches) {
                      void ensureMatchDetailLoaded(match);
                    }
                  }
                }}
              />

              <section className="mt-10">
                <div className="flex flex-col justify-between gap-4 lg:flex-row lg:items-end">
                  <div>
                    <p className="text-sm font-black uppercase tracking-[0.22em] text-[#A6E824]">
                      Quadro giornata
                    </p>
                    <h2 className="mt-1 text-3xl font-black">
                      Intelligence partita per partita
                    </h2>
                    <p className="mt-2 text-sm text-gray-500">
                      {visibleMatches.length} di {sourceMatches.length} partite visibili
                    </p>
                  </div>


                </div>

                <div className="mt-6 grid gap-7 sm:gap-8">
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

              <section className="mt-12 border-t border-white/10 pt-9">
                <div>
                  <p className="text-sm font-black uppercase tracking-[0.22em] text-gray-500">
                    Approfondimento giornata
                  </p>
                  <h2 className="mt-1 text-3xl font-black text-white">
                    Analisi avanzata
                  </h2>
                </div>

                <div className="mt-5 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
                  <MetricCard
                    label="Pronostici"
                    value={overview.prediction_count.toLocaleString("it-IT")}
                    detail={`${overview.member_count} utenti · ${overview.league_count} leghe`}
                    emphasis
                  />
                  <MetricCard
                    label="Copertura analisi"
                    value={
                      dailyAnalysisCoverage.percent === null
                        ? "—"
                        : `${dailyAnalysisCoverage.percent.toFixed(0)}%`
                    }
                    detail={
                      dailyAnalysisCoverage.percent === null
                        ? "Dati di analisi in caricamento"
                        : `${dailyAnalysisCoverage.jointCovered}/${dailyAnalysisCoverage.requiredMatches} partite · Community + BM`
                    }
                  />
                  <MetricCard
                    label="Solidità del quadro"
                    value={
                      dailySolidity === null
                        ? "—"
                        : `${dailySolidity.toFixed(0)}/100`
                    }
                    detail={
                      dailySolidity === null
                        ? "Dati di analisi in caricamento"
                        : communityMaturity < 0.25
                        ? "Community embrionale · BM prevalente"
                        : communityMaturity < 0.45
                          ? "Community in crescita · quadro combinato"
                          : communityMaturity < 0.7
                            ? "Community consistente · quadro combinato"
                            : "Community matura · quadro combinato"
                    }
                  />
                  <MetricCard
                    label="Convergenza Community–Mercato"
                    value={
                      dailyConvergence === null
                        ? "—"
                        : `${dailyConvergence.toFixed(0)}%`
                    }
                    detail={
                      dailyConvergence === null
                        ? "Dati insufficienti"
                        : dailyConvergence >= 65
                          ? "Letture fortemente allineate"
                          : dailyConvergence >= 55
                            ? "Letture abbastanza allineate"
                            : dailyConvergence >= 45
                              ? "Quadro ancora misto"
                              : "Letture divergenti"
                    }
                  />
                </div>

                <div className="mt-4 grid gap-4 lg:grid-cols-3">
                  <div className="rounded-3xl border border-white/10 bg-[#0b1419] p-5 shadow-xl shadow-black/30">
                    <p className="text-[10px] font-black uppercase tracking-[0.18em] text-gray-500">Segnale più forte</p>
                    {summary.strongest && (
                      <>
                        <p className="mt-3 text-xl font-black">
                          {cleanTeamName(summary.strongest.home_team_short_name || summary.strongest.home_team_name)} – {cleanTeamName(summary.strongest.away_team_short_name || summary.strongest.away_team_name)}
                        </p>
                        <p className="mt-2 text-sm text-gray-400">
                          Consenso <strong className="text-[#A6E824]">{summary.strongest.consensus_outcome} · {pct(summary.strongest.consensus_percent)}</strong>
                        </p>
                      </>
                    )}
                  </div>

                  <div className="rounded-3xl border border-white/10 bg-[#0b1419] p-5 shadow-xl shadow-black/30">
                  <p className="text-[10px] font-black uppercase tracking-[0.18em] text-gray-500">
                    Massima incertezza
                  </p>
                  {weightedUncertainMatch ? (
                    <>
                      <p className="mt-3 text-xl font-black">
                        {cleanTeamName(
                          weightedUncertainMatch.match
                            .home_team_short_name ||
                            weightedUncertainMatch.match
                              .home_team_name,
                        )}{" "}
                        –{" "}
                        {cleanTeamName(
                          weightedUncertainMatch.match
                            .away_team_short_name ||
                            weightedUncertainMatch.match
                              .away_team_name,
                        )}
                      </p>
                      <p className="mt-2 text-sm text-gray-400">
                        Pronostico particolarmente aperto
                      </p>
                    </>
                  ) : (
                    <>
                      <p className="mt-3 text-xl font-black">
                        —
                      </p>
                      <p className="mt-2 text-sm text-gray-400">
                        Non emergono partite particolarmente aperte
                      </p>
                    </>
                  )}
                </div>

                  <div className="rounded-3xl border border-white/10 bg-[#0b1419] p-5 shadow-xl shadow-black/30">
                    <p className="text-[10px] font-black uppercase tracking-[0.18em] text-gray-500">Profilo giornata</p>
                    <p className="mt-3 text-xl font-black">
                      {summary.compactCount} compatte · {summary.dividedCount} incerte
                    </p>
                    <p className="mt-2 text-sm text-gray-400">
                      Media gol prevista <strong className="text-white">{toNumber(summary.avgGoals).toFixed(1)}</strong>
                    </p>
                  </div>
                </div>

                <div className="mt-4 grid gap-4 lg:grid-cols-3">
                  <div className="rounded-3xl border border-white/10 bg-[#0b1419] p-5">
                    <h3 className="text-sm font-black uppercase tracking-[0.14em] text-gray-400">Orientamento 1-X-2</h3>
                    <div className="mt-4 space-y-3">
                      <PercentBar label="1" value={globalDistribution.home} />
                      <PercentBar label="X" value={globalDistribution.draw} />
                      <PercentBar label="2" value={globalDistribution.away} />
                    </div>
                  </div>

                  <div className="rounded-3xl border border-white/10 bg-[#0b1419] p-5">
                    <h3 className="text-sm font-black uppercase tracking-[0.14em] text-gray-400">Profilo gol</h3>
                    <div className="mt-4 space-y-3">
                      <PercentBar label="Over 2.5" value={globalDistribution.over} />
                      <PercentBar label="Under 2.5" value={100 - globalDistribution.over} />
                      <PercentBar label="Goal" value={globalDistribution.goal} />
                      <PercentBar label="No Goal" value={100 - globalDistribution.goal} />
                    </div>
                  </div>

                  <div className="rounded-3xl border border-white/10 bg-[#0b1419] p-5">
                    <h3 className="text-sm font-black uppercase tracking-[0.14em] text-gray-400">Stato snapshot</h3>
                    <div className="mt-4 grid gap-3">
                      <MetricCard label="Fase" value={phaseLabel(overview.phase)} detail={overview.snapshot_status} />
                      <MetricCard label="Prima partita" value={formatDateTime(overview.starts_at)} detail={`${overview.match_count} partite monitorate`} />
                    </div>
                  </div>
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

