import { loadEnvConfig } from "@next/env";
import { createClient } from "@supabase/supabase-js";

import {
  enqueueLiveRuntimeJob,
  runLiveRuntimeWorkerOnce,
  type LiveRuntimeJobType,
} from "../lib/live-runtime";

type HarnessMode = "enqueue" | "once" | "drain";

loadEnvConfig(process.cwd());

function requiredEnv(name: string, fallbacks: string[] = []): string {
  for (const key of [name, ...fallbacks]) {
    const value = process.env[key]?.trim();
    if (value) return value;
  }

  throw new Error(
    `Missing environment variable ${[name, ...fallbacks].join(" or ")}`,
  );
}

function optionalEnv(name: string): string | null {
  const value = process.env[name]?.trim();
  return value ? value : null;
}

function csvEnv(name: string): string[] {
  const value = optionalEnv(name);
  if (!value) return [];

  return value
    .split(",")
    .map((entry) => entry.trim())
    .filter(Boolean);
}

function integerEnv(name: string, fallback: number): number {
  const raw = optionalEnv(name);
  if (!raw) return fallback;

  const parsed = Number.parseInt(raw, 10);
  if (!Number.isFinite(parsed) || parsed < 1) {
    throw new Error(`${name} must be a positive integer`);
  }

  return parsed;
}

function parseMode(): HarnessMode {
  const raw = (process.argv[2] ?? "once").trim().toLowerCase();
  if (raw === "enqueue" || raw === "once" || raw === "drain") {
    return raw;
  }

  throw new Error(
    `Unsupported mode '${raw}'. Use enqueue, once, or drain.`,
  );
}

function createRuntimeClient() {
  const url = requiredEnv("SUPABASE_URL", ["NEXT_PUBLIC_SUPABASE_URL"]);
  const serviceRoleKey = requiredEnv("SUPABASE_SERVICE_ROLE_KEY");

  return createClient(url, serviceRoleKey, {
    auth: {
      autoRefreshToken: false,
      persistSession: false,
    },
  });
}

async function enqueueFootballDataPoll() {
  const client = createRuntimeClient();
  const matchId = requiredEnv("FANTAGOL_MATCH_ID");
  const externalMatchId = requiredEnv("FOOTBALL_DATA_MATCH_ID");
  const fantagolRoundId = optionalEnv("FANTAGOL_ROUND_ID");
  const leagueRoundIds = csvEnv("LEAGUE_ROUND_IDS");
  const correlationId = optionalEnv("LIVE_RUNTIME_CORRELATION_ID");

  const result = await enqueueLiveRuntimeJob(client, {
    jobType: "poll_match",
    scopeType: "match",
    scopeId: matchId,
    idempotencyKey:
      optionalEnv("LIVE_RUNTIME_IDEMPOTENCY_KEY") ??
      [
        "live",
        "poll-match",
        "football_data",
        matchId,
        externalMatchId,
        new Date().toISOString(),
      ].join(":"),
    priority: integerEnv("LIVE_RUNTIME_PRIORITY", 20),
    maxAttempts: integerEnv("LIVE_RUNTIME_MAX_ATTEMPTS", 5),
    payload: {
      match_id: matchId,
      provider_code: "football_data",
      external_match_id: externalMatchId,
      fantagol_round_id: fantagolRoundId,
      league_round_ids: leagueRoundIds,
    },
    correlationId,
  });

  console.log(JSON.stringify({ mode: "enqueue", ...result }, null, 2));
}

async function runWorkerOnce() {
  const client = createRuntimeClient();
  const workerId =
    optionalEnv("LIVE_RUNTIME_WORKER_ID") ??
    `manual-worker-${process.pid}`;
  const jobTypes = csvEnv("LIVE_RUNTIME_JOB_TYPES") as LiveRuntimeJobType[];

  const result = await runLiveRuntimeWorkerOnce({
    client,
    workerId,
    jobTypes: jobTypes.length > 0 ? jobTypes : ["poll_match"],
    retryDelaySeconds: integerEnv("LIVE_RUNTIME_RETRY_DELAY_SECONDS", 30),
  });

  console.log(JSON.stringify({ mode: "once", workerId, ...result }, null, 2));
  return result;
}

async function drainWorker() {
  const maxJobs = integerEnv("LIVE_RUNTIME_MAX_JOBS", 20);
  const results: unknown[] = [];

  for (let index = 0; index < maxJobs; index += 1) {
    const result = await runWorkerOnce();
    results.push(result);

    if (!result.claimed) break;
  }

  console.log(
    JSON.stringify(
      {
        mode: "drain",
        attempted: results.length,
        stoppedBecauseQueueEmpty:
          results.length > 0 &&
          !(results[results.length - 1] as { claimed: boolean }).claimed,
      },
      null,
      2,
    ),
  );
}

async function main() {
  const mode = parseMode();

  if (mode === "enqueue") {
    await enqueueFootballDataPoll();
    return;
  }

  if (mode === "once") {
    await runWorkerOnce();
    return;
  }

  await drainWorker();
}

main().catch((error: unknown) => {
  const serialized =
    error instanceof Error
      ? { name: error.name, message: error.message, stack: error.stack }
      : { name: "UnknownError", message: String(error) };

  console.error(JSON.stringify(serialized, null, 2));
  process.exitCode = 1;
});
