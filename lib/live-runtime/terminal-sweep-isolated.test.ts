import { describe, expect, it, vi } from 'vitest';
import { runIsolatedTerminalSweep } from './terminal-sweep-isolated';

const ROUND_A = '15a27bbe-862b-4efb-b40a-c23a74174b70';
const ROUND_B = '43e943c7-df99-4c0b-8732-e6f505694271';
const response = (results: unknown[], failures = 0) => ({ evaluated: results.length, failures, results });
const deps = (value: unknown) => ({ sweep: vi.fn(async () => value) });

// No JS enqueue dependency exists: only the database sweep may write queue records.
describe('R41-M58 R79 database-owned terminal sweep observer', () => {
  it('feature flag OFF performs no RPC', async () => {
    const dependencies = deps(response([]));
    const result = await runIsolatedTerminalSweep({ enabled: false, dependencies });
    expect(result).toEqual({ attempted: false, durablyEnqueuedRoundIds: [], retryReasons: [] });
    expect(dependencies.sweep).not.toHaveBeenCalled();
  });
  it('empty sweep is valid', async () => {
    const result = await runIsolatedTerminalSweep({ enabled: true, dependencies: deps(response([])) });
    expect(result).toEqual({ attempted: true, durablyEnqueuedRoundIds: [], retryReasons: [] });
  });
  it('recognizes durable DB enqueue without any JS enqueue capability', async () => {
    const result = await runIsolatedTerminalSweep({ enabled: true, dependencies: deps(response([
      { round_id: ROUND_A, outcome: 'durably_enqueued', canonical_jobs_present: 9, blocked_jobs: 0 },
    ])) });
    expect(result.durablyEnqueuedRoundIds).toEqual([ROUND_A]);
    expect(result.retryReasons).toEqual([]);
  });
  it('deduplicates durable round ids in reporting', async () => {
    const result = await runIsolatedTerminalSweep({ enabled: true, dependencies: deps(response([
      { round_id: ROUND_A, outcome: 'durably_enqueued' },
      { round_id: ROUND_A, outcome: 'durably_enqueued' },
    ])) });
    expect(result.durablyEnqueuedRoundIds).toEqual([ROUND_A]);
  });
  it('reports blocked jobs for explicit review, never replay', async () => {
    const result = await runIsolatedTerminalSweep({ enabled: true, dependencies: deps(response([
      { round_id: ROUND_A, outcome: 'blocked_job_review', blocked_jobs: 1 },
    ])) });
    expect(result.durablyEnqueuedRoundIds).toEqual([]);
    expect(result.retryReasons).toEqual(['terminal_round_rebuild_review_required']);
  });
  it('reports certification continuity review without rebuild', async () => {
    const result = await runIsolatedTerminalSweep({ enabled: true, dependencies: deps(response([
      { round_id: ROUND_B, outcome: 'certification_review_required', certification_review_count: 1 },
    ])) });
    expect(result.retryReasons).toEqual(['terminal_round_certification_review_required']);
  });
  it('preserves successful outcomes while flagging bounded per-round failure', async () => {
    const result = await runIsolatedTerminalSweep({ enabled: true, dependencies: deps(response([
      { round_id: ROUND_A, outcome: 'durably_enqueued' },
      { round_id: ROUND_B, outcome: 'failed', error: 'TEST_FAILURE' },
    ], 1)) });
    expect(result.durablyEnqueuedRoundIds).toEqual([ROUND_A]);
    expect(result.retryReasons).toEqual(['terminal_round_sweep_partial_failed']);
  });
  it('isolates transport failure', async () => {
    const dependencies = deps(null);
    dependencies.sweep.mockRejectedValueOnce(new Error('unavailable'));
    const result = await runIsolatedTerminalSweep({ enabled: true, dependencies });
    expect(result.retryReasons).toEqual(['terminal_round_sweep_failed']);
  });
  it.each([
    null,
    {},
    { evaluated: -1, failures: 0, results: [] },
    { evaluated: 2, failures: 0, results: [] },
    { evaluated: 1, failures: 0, results: [{ outcome: 'advanced', round_id: ROUND_A }] },
    { evaluated: 1, failures: 0, results: [{ outcome: 'rebuild_required', round_id: ROUND_A }] },
    { evaluated: 1, failures: 0, results: [{ outcome: 'durably_enqueued', round_id: 42 }] },
    { evaluated: 1, failures: 1, results: [{ outcome: 'durably_enqueued', round_id: ROUND_A }] },
    { evaluated: 1, failures: 0, results: [{ outcome: 'failed', round_id: ROUND_A }] },
  ])('rejects malformed or deprecated contract response %#', async (value) => {
    const result = await runIsolatedTerminalSweep({ enabled: true, dependencies: deps(value) });
    expect(result.durablyEnqueuedRoundIds).toEqual([]);
    expect(result.retryReasons).toEqual(['terminal_round_sweep_invalid_result']);
  });
});