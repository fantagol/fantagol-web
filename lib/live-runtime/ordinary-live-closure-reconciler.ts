import type { SupabaseClient } from "@supabase/supabase-js";
/**
 * FANTAGOL R41-R5J-R25 — OFFLINE CANDIDATE, NOT DEPLOYED.
 * Independent of the frontend current-round resolver and pre-LIVE flag.
 * This worker never changes round statuses, match results, scores or predictions.
 * The RPC is provided by the UNDEPLOYED R22 SQL candidate.
 */

export type OrdinaryClosureRow = {
  closure_round_id: string;
  was_inserted: boolean;
  recorded_anchor_at: string | null;
  recorded_handoff_at: string | null;
  outcome: string;
};

type RoundRow = { id: string; starts_at: string | null; status: string };

type QueryResult<T> = { data: T | null; error: { message: string } | null };

export type OrdinaryClosureClient = {
  from(table: 'fantagol_rounds'): {
    select(columns: string): {
      eq(column: string, value: boolean): {
        in(column: string, values: string[]): {
          gte(column: string, value: string): {
            lte(column: string, value: string): {
              order(column: string, opts: { ascending: boolean }): {
                limit(count: number): PromiseLike<QueryResult<RoundRow[]>>;
              };
            };
          };
        };
      };
    };
  };
  rpc(name: string, params: { p_fantagol_round_id: string }): PromiseLike<QueryResult<OrdinaryClosureRow[]>>;
};

export type OrdinaryClosureResult = {
  attempted: string[];
  recorded: string[];
  alreadyRecorded: string[];
  notEligible: string[];
  retryReasons: string[];
};

const STATUSES = [
  'predictions_locked', 'live', 'waiting_postponed',
  'final_calculable', 'final_official', 'scoring', 'official', 'recalculated',
];
const MAX_ROUNDS = 16;
const LOOKBACK_DAYS = 30;

export async function reconcileOrdinaryLiveClosures(input: {
  client: SupabaseClient;
  now: Date;
  enabled: boolean;
}): Promise<OrdinaryClosureResult> {
  const result: OrdinaryClosureResult = {
    attempted: [], recorded: [], alreadyRecorded: [], notEligible: [], retryReasons: [],
  };
  if (!input.enabled) return result;
  if (!Number.isFinite(input.now.getTime())) {
    return { ...result, retryReasons: ['ordinary_closure_invalid_clock'] };
  }

  const since = new Date(input.now.getTime() - LOOKBACK_DAYS * 86_400_000);
  let rows: RoundRow[];
  try {
    const query = await input.client.from('fantagol_rounds')
      .select('id,starts_at,status')
      .eq('active', true)
      .in('status', STATUSES)
      .gte('starts_at', since.toISOString())
      .lte('starts_at', input.now.toISOString())
      .order('starts_at', { ascending: false })
      .limit(MAX_ROUNDS);
    if (query.error) throw new Error(query.error.message);
    if (!Array.isArray(query.data)) throw new Error('invalid_rounds_payload');
    rows = query.data;
  } catch (error) {
    console.error('ORDINARY_CLOSURE_ROUND_DISCOVERY_FAILED', error);
    result.retryReasons.push('ordinary_closure_discovery_failed');
    return result;
  }

  for (const row of rows) {
    if (!row || typeof row.id !== 'string' || !row.id) {
      result.retryReasons.push('ordinary_closure_invalid_round_row');
      continue;
    }
    result.attempted.push(row.id);
    try {
      const answer = await input.client.rpc('record_round_ordinary_live_closure_internal', {
        p_fantagol_round_id: row.id,
      });
      if (answer.error) throw new Error(answer.error.message);
      if (!Array.isArray(answer.data) || answer.data.length !== 1) {
        throw new Error('invalid_closure_rpc_payload');
      }
      const record = answer.data[0];
      if (record.closure_round_id !== row.id) throw new Error('round_identity_mismatch');
      switch (record.outcome) {
        case 'RECORDED': result.recorded.push(row.id); break;
        case 'ALREADY_RECORDED': result.alreadyRecorded.push(row.id); break;
        case 'NOT_ELIGIBLE':
        case 'ROUND_NOT_STARTED':
        case 'FUTURE_FT_BLOCKED': result.notEligible.push(row.id); break;
        default: throw new Error('unknown_closure_outcome');
      }
    } catch (error) {
      console.error('ORDINARY_CLOSURE_ROUND_FAILED', { roundId: row.id, error });
      result.retryReasons.push('ordinary_closure_round_failed');
    }
  }
  result.retryReasons = [...new Set(result.retryReasons)];
  return result;
}
