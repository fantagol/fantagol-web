import { describe, expect, it } from 'vitest';
import { classifyTerminalSweepRetryReasons } from './terminal-sweep-retry-policy';

describe('R26 terminal sweep review versus heartbeat retry', () => {
  it('does not immediately retry for manual rebuild review alone', () => {
    expect(classifyTerminalSweepRetryReasons(['terminal_round_rebuild_review_required'])).toEqual({
      retryRecommended: false,
      reviewReasons: ['terminal_round_rebuild_review_required'],
    });
  });
  it('retries on transient sweep failure', () => {
    expect(classifyTerminalSweepRetryReasons(['terminal_round_sweep_failed'])).toEqual({
      retryRecommended: true,
      reviewReasons: [],
    });
  });
  it('retries when manual review coexists with transient failure', () => {
    expect(classifyTerminalSweepRetryReasons([
      'terminal_round_rebuild_review_required',
      'terminal_round_sweep_partial_failed',
    ])).toEqual({
      retryRecommended: true,
      reviewReasons: ['terminal_round_rebuild_review_required'],
    });
  });
  it('does not retry when there are no reasons', () => {
    expect(classifyTerminalSweepRetryReasons([])).toEqual({
      retryRecommended: false,
      reviewReasons: [],
    });
  });
  it('continues retrying certification review and unknown errors', () => {
    expect(classifyTerminalSweepRetryReasons([
      'terminal_round_certification_review_required',
      'round_context_failed',
    ]).retryRecommended).toBe(true);
  });
});