import type { SupabaseClient } from "@supabase/supabase-js";

import {
  scheduleLivePollingBatch,
  type LivePollingTarget,
  type ScheduledLivePollingBatch,
} from "./scheduler";

export type LivePollingTargetLoader = (input: {
  client: SupabaseClient;
  now: Date;
}) => Promise<LivePollingTarget[]>;

export type RunLivePollingSchedulerInput = {
  client: SupabaseClient;
  loadTargets: LivePollingTargetLoader;
  now?: Date;
  correlationId?: string | null;
  priority?: number;
};

export async function runLivePollingScheduler(
  input: RunLivePollingSchedulerInput,
): Promise<ScheduledLivePollingBatch> {
  const now = input.now ?? new Date();
  const targets = await input.loadTargets({
    client: input.client,
    now,
  });

  return scheduleLivePollingBatch({
    client: input.client,
    targets,
    now,
    correlationId: input.correlationId ?? null,
    priority: input.priority,
  });
}
