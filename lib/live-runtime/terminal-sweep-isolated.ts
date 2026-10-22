/**
 * R79 terminal sweep response observer (DB-owned canonical enqueue).
 * Database RPC owns the lifecycle transition, durable intents and queue writes.
 * This module never enqueues or retries jobs itself.
 */
export type TerminalSweepRun = {
  attempted: boolean;
  durablyEnqueuedRoundIds: string[];
  retryReasons: string[];
};

export type TerminalSweepDependencies = {
  sweep: () => Promise<unknown>;
};

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function isNonNegativeInteger(value: unknown): value is number {
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= 0;
}

const ROUND_ID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const ALLOWED_OUTCOMES = new Set([
  'durably_enqueued',
  'blocked_job_review',
  'certification_review_required',
  'failed',
]);

export async function runIsolatedTerminalSweep(input: {
  enabled: boolean;
  dependencies: TerminalSweepDependencies;
}): Promise<TerminalSweepRun> {
  const result: TerminalSweepRun = {
    attempted: false,
    durablyEnqueuedRoundIds: [],
    retryReasons: [],
  };
  if (!input.enabled) return result;
  result.attempted = true;

  let raw: unknown;
  try {
    raw = await input.dependencies.sweep();
  } catch {
    result.retryReasons.push('terminal_round_sweep_failed');
    return result;
  }

  if (!isRecord(raw) || !Array.isArray(raw.results) ||
      !isNonNegativeInteger(raw.evaluated) ||
      !isNonNegativeInteger(raw.failures) ||
      raw.results.length !== raw.evaluated ||
      raw.failures > raw.evaluated) {
    result.retryReasons.push('terminal_round_sweep_invalid_result');
    return result;
  }

  const enqueued = new Set<string>();
  const retryReasons = new Set<string>();
  let actualFailures = 0;
  // Validate the complete response before reporting any success.
  for (const item of raw.results) {
    if (!isRecord(item) || typeof item.outcome !== 'string' ||
        !ALLOWED_OUTCOMES.has(item.outcome) ||
        typeof item.round_id !== 'string' ||
        !ROUND_ID_PATTERN.test(item.round_id)) {
      result.retryReasons.push('terminal_round_sweep_invalid_result');
      return result;
    }
    if (item.outcome === 'failed') {
      actualFailures++;
    } else if (item.outcome === 'durably_enqueued') {
      enqueued.add(item.round_id.toLowerCase());
    } else if (item.outcome === 'blocked_job_review') {
      retryReasons.add('terminal_round_rebuild_review_required');
    } else if (item.outcome === 'certification_review_required') {
      retryReasons.add('terminal_round_certification_review_required');
    }
  }
  if (actualFailures !== raw.failures) {
    result.retryReasons.push('terminal_round_sweep_invalid_result');
    return result;
  }
  if (actualFailures > 0) retryReasons.add('terminal_round_sweep_partial_failed');
  result.durablyEnqueuedRoundIds = [...enqueued];
  result.retryReasons = [...retryReasons];
  return result;
}