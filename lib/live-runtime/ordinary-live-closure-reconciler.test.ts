import { describe, expect, it, vi } from 'vitest';
import type { SupabaseClient } from '@supabase/supabase-js';
import { reconcileOrdinaryLiveClosures } from './ordinary-live-closure-reconciler';

const NOW = new Date('2026-10-29T23:00:00Z');
function mockClient(roundIds: string[], outcomes: Record<string, string> = {}) {
  const rpc = vi.fn(async (_name: string, args: { p_fantagol_round_id: string }): Promise<{ data: { closure_round_id: string; was_inserted: boolean; recorded_anchor_at: string; recorded_handoff_at: string; outcome: string }[] | null; error: { message: string } | null }> => ({
    data: [{ closure_round_id: args.p_fantagol_round_id,
      was_inserted: outcomes[args.p_fantagol_round_id] === 'RECORDED',
      recorded_anchor_at: NOW.toISOString(), recorded_handoff_at: NOW.toISOString(),
      outcome: outcomes[args.p_fantagol_round_id] ?? 'NOT_ELIGIBLE' }], error: null,
  }));
  const limit = vi.fn(async (): Promise<{ data: { id: string; starts_at: string; status: string }[] | null; error: { message: string } | null }> => ({ data: roundIds.map(id => ({ id, starts_at: NOW.toISOString(), status: 'live' })), error: null }));
  type MockQueryChain = {
  select: () => MockQueryChain;
  eq: () => MockQueryChain;
  in: () => MockQueryChain;
  gte: () => MockQueryChain;
  lte: () => MockQueryChain;
  order: () => MockQueryChain;
  limit: typeof limit;
};
const chain: MockQueryChain = { select: () => chain, eq: () => chain, in: () => chain,
    gte: () => chain, lte: () => chain, order: () => chain, limit };
  return { client: { from: () => chain, rpc } as unknown as SupabaseClient, rpc, limit };
}

describe('R25 ordinary closure runtime', () => {
  it('disabled gate does not query or write', async () => {
    const m = mockClient(['g9']);
    expect((await reconcileOrdinaryLiveClosures({client:m.client, now:NOW, enabled:false})).attempted).toEqual([]);
    expect(m.rpc).not.toHaveBeenCalled(); expect(m.limit).not.toHaveBeenCalled();
  });
  it('discovers rounds independently from frontend owner and handles outcomes', async () => {
    const m = mockClient(['g10','g9'], { g9:'RECORDED', g10:'NOT_ELIGIBLE' });
    const r = await reconcileOrdinaryLiveClosures({client:m.client, now:NOW, enabled:true});
    expect(r.attempted).toEqual(['g10','g9']); expect(r.recorded).toEqual(['g9']);
    expect(r.notEligible).toEqual(['g10']);
  });
  it('recognizes existing closure with no extra state mutation', async () => {
    const m = mockClient(['g9'], {g9:'ALREADY_RECORDED'});
    expect((await reconcileOrdinaryLiveClosures({client:m.client, now:NOW, enabled:true})).alreadyRecorded).toEqual(['g9']);
  });
  it('keeps processing after a per-round RPC failure', async () => {
    const m = mockClient(['g9','g10'], {g10:'RECORDED'});
    m.rpc.mockImplementationOnce(async () => ({data:null, error:{message:'temporary'}}));
    const r = await reconcileOrdinaryLiveClosures({client:m.client, now:NOW, enabled:true});
    expect(r.recorded).toEqual(['g10']); expect(r.retryReasons).toContain('ordinary_closure_round_failed');
  });
  it('fails closed on discovery failure', async () => {
    const m = mockClient(['g9']);
    m.limit.mockImplementationOnce(async () => ({data:null,error:{message:'query failed'}}));
    const r = await reconcileOrdinaryLiveClosures({client:m.client, now:NOW, enabled:true});
    expect(r.retryReasons).toEqual(['ordinary_closure_discovery_failed']);
    expect(m.rpc).not.toHaveBeenCalled();
  });
  it('does not run for invalid clock', async () => {
    const m = mockClient(['g9']);
    const r = await reconcileOrdinaryLiveClosures({client:m.client, now:new Date('invalid'), enabled:true});
    expect(r.retryReasons).toContain('ordinary_closure_invalid_clock');
    expect(m.limit).not.toHaveBeenCalled();
  });
});
