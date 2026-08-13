import {
  runProductionHeartbeat,
} from "@/lib/live-runtime/production-heartbeat-orchestrator";

import {
  createProductionHeartbeatPostHandler,
} from "@/lib/live-runtime/production-heartbeat-http-boundary";

import {
  getSupabaseServiceClient,
} from "@/lib/supabase/service";

export const POST =
  createProductionHeartbeatPostHandler({
    readCronSecret:
      () =>
        process.env
          .CRON_SECRET
          ?.trim(),

    getServiceClient:
      getSupabaseServiceClient,

    runHeartbeat:
      runProductionHeartbeat,
  });