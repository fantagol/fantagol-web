import { randomUUID } from "node:crypto";

import { loadEnvConfig } from "@next/env";
import { createClient } from "@supabase/supabase-js";

import {
  enqueueLiveRuntimeJob,
} from "../lib/live-runtime/job-service";
import {
  scheduleFootballDataAggregatedPolling,
  type LivePollingTarget,
} from "../lib/live-runtime/scheduler";
import {
  runLiveRuntimeWorkerOnce,
} from "../lib/live-runtime/worker";

loadEnvConfig(process.cwd());

function requireEnv(name: string): string {
  const value =
    process.env[name]?.trim();

  if (!value) {
    throw new Error(
      `Missing environment variable ${name}`,
    );
  }

  return value;
}

function isoDate(
  value: string,
): string {
  return value.slice(0, 10);
}

function addUtcDay(
  value: string,
): string {
  const date =
    new Date(
      `${value}T00:00:00.000Z`,
    );

  date.setUTCDate(
    date.getUTCDate() + 1,
  );

  return date
    .toISOString()
    .slice(0, 10);
}

async function main() {
  const url =
    process.env.SUPABASE_URL?.trim() ||
    requireEnv(
      "NEXT_PUBLIC_SUPABASE_URL",
    );

  const serviceRoleKey =
    requireEnv(
      "SUPABASE_SERVICE_ROLE_KEY",
    );

  /*
   * Explicit local service client.
   * No credential is logged.
   */
  const client =
    createClient(
      url,
      serviceRoleKey,
      {
        auth: {
          autoRefreshToken:
            false,
          detectSessionInUrl:
            false,
          persistSession:
            false,
        },
        global: {
          headers: {
            "X-Client-Info":
              "fantagol-a8d67e-real-cycle",
          },
        },
      },
    );

  console.log("");
  console.log(
    "=== 1. LOAD ACTIVE FANTAGOL ROUND 1 ===",
  );

  const {
    data: rounds,
    error: roundError,
  } =
    await client
      .from("fantagol_rounds")
      .select("id,name,sequence,status,starts_at,ends_at")
      .eq(
        "sequence",
        1,
      )
      .eq(
        "active",
        true,
      )
      .order(
        "created_at",
        {
          ascending: false,
        },
      )
      .limit(1);

  if (roundError) {
    throw roundError;
  }

  const round =
    rounds?.[0];

  if (!round) {
    throw new Error(
      "Active FantaGol Round 1 not found",
    );
  }

  console.log(
    `[PASS] ${round.name} | ${round.id}`,
  );

  console.log("");
  console.log(
    "=== 2. LOAD 10 CANONICAL MATCHES ===",
  );

  const {
    data: roundMatches,
    error: roundMatchesError,
  } =
    await client
      .from(
        "fantagol_round_matches",
      )
      .select("slot_number,match_id")
      .eq(
        "fantagol_round_id",
        round.id,
      )
      .eq(
        "required",
        true,
      )
      .is(
        "removed_at",
        null,
      )
      .order(
        "slot_number",
        {
          ascending: true,
        },
      );

  if (roundMatchesError) {
    throw roundMatchesError;
  }

  if (
    !roundMatches ||
    roundMatches.length !== 10
  ) {
    throw new Error(
      `Expected 10 canonical Matches, got ${roundMatches?.length ?? 0}`,
    );
  }

  console.log(
    "[PASS] Canonical matches: 10",
  );

  const matchIds =
    roundMatches.map(
      (row) =>
        row.match_id,
    );

  const {
    data: matches,
    error: matchesError,
  } =
    await client
      .from("matches")
      .select("id,kickoff,status,active")
      .in(
        "id",
        matchIds,
      );

  if (matchesError) {
    throw matchesError;
  }

  if (
    !matches ||
    matches.length !== 10
  ) {
    throw new Error(
      `Expected 10 Match rows, got ${matches?.length ?? 0}`,
    );
  }

  const matchById =
    new Map(
      matches.map(
        (match) => [
          match.id,
          match,
        ],
      ),
    );

  console.log("");
  console.log(
    "=== 3. LOAD FOOTBALL DATA PROVIDER + MAPPINGS ===",
  );

  const {
    data: providers,
    error: providerError,
  } =
    await client
      .from("data_providers")
      .select(
        "id,code,active,priority,rate_limit_per_minute",
      )
      .eq(
        "code",
        "football_data",
      )
      .limit(1);

  if (providerError) {
    throw providerError;
  }

  const provider =
    providers?.[0];

  if (
    !provider ||
    provider.active !== true
  ) {
    throw new Error(
      "football_data provider is not active",
    );
  }

  console.log(
    `[PASS] football_data active | limit=${provider.rate_limit_per_minute}/min`,
  );

  const {
    data: mappings,
    error: mappingError,
  } =
    await client
      .from(
        "provider_entity_maps",
      )
      .select(
        "internal_id,external_id,active",
      )
      .eq(
        "provider_id",
        provider.id,
      )
      .eq(
        "entity_type",
        "match",
      )
      .eq(
        "active",
        true,
      )
      .in(
        "internal_id",
        matchIds,
      );

  if (mappingError) {
    throw mappingError;
  }

  if (
    !mappings ||
    mappings.length !== 10
  ) {
    throw new Error(
      `Expected 10 Football Data mappings, got ${mappings?.length ?? 0}`,
    );
  }

  const mappingByMatchId =
    new Map(
      mappings.map(
        (mapping) => [
          mapping.internal_id,
          mapping.external_id,
        ],
      ),
    );

  console.log(
    "[PASS] Football Data mappings: 10",
  );

  console.log("");
  console.log(
    "=== 4. LOAD LEAGUE ROUND SCOPES ===",
  );

  const {
    data: leagueRounds,
    error: leagueRoundError,
  } =
    await client
      .from("league_rounds")
      .select("id")
      .eq(
        "fantagol_round_id",
        round.id,
      )
      .eq(
        "enabled",
        true,
      );

  if (leagueRoundError) {
    throw leagueRoundError;
  }

  const leagueRoundIds =
    (leagueRounds ?? []).map(
      (row) => row.id,
    );

  console.log(
    `[PASS] Enabled league rounds: ${leagueRoundIds.length}`,
  );

  const targets:
    LivePollingTarget[] =
    roundMatches.map(
      (row) => {
        const match =
          matchById.get(
            row.match_id,
          );

        const externalMatchId =
          mappingByMatchId.get(
            row.match_id,
          );

        if (
          !match ||
          !match.kickoff ||
          !externalMatchId
        ) {
          throw new Error(
            `Incomplete target at slot ${row.slot_number}`,
          );
        }

        return {
          matchId:
            row.match_id,
          providerCode:
            "football_data",
          externalMatchId,
          kickoffAt:
            match.kickoff,
          status:
            match.status,
          fantagolRoundId:
            round.id,
          leagueRoundIds,
        };
      },
    );

  const uniqueExternalIds =
    new Set(
      targets.map(
        (target) =>
          target.externalMatchId,
      ),
    );

  if (
    uniqueExternalIds.size !== 10
  ) {
    throw new Error(
      "Football Data external IDs are not 10/10 unique",
    );
  }

  console.log("");
  console.log(
    "=== 5. REAL TARGET SET ===",
  );

  for (
    let index = 0;
    index < targets.length;
    index += 1
  ) {
    const target =
      targets[index];

    console.log(
      `[TARGET] slot=${index + 1} | fd=${target.externalMatchId} | kickoff=${target.kickoffAt} | status=${target.status}`,
    );
  }

  const kickoffs =
    targets
      .map(
        (target) =>
          new Date(
            target.kickoffAt,
          ),
      )
      .sort(
        (a, b) =>
          a.getTime() -
          b.getTime(),
      );

  const firstKickoff =
    kickoffs[0];

  const lastKickoff =
    kickoffs[
      kickoffs.length - 1
    ];

  if (
    !firstKickoff ||
    !lastKickoff
  ) {
    throw new Error(
      "Kickoff window missing",
    );
  }

  const dateFrom =
    isoDate(
      firstKickoff.toISOString(),
    );

  const dateTo =
    addUtcDay(
      isoDate(
        lastKickoff.toISOString(),
      ),
    );

  console.log("");
  console.log(
    "=== 6. BASELINE RECEIPTS ===",
  );

  const {
    count:
      receiptsBefore,
    error:
      receiptsBeforeError,
  } =
    await client
      .from(
        "live_match_update_receipts",
      )
      .select(
        "id",
        {
          count: "exact",
          head: true,
        },
      )
      .in(
        "match_id",
        matchIds,
      );

  if (receiptsBeforeError) {
    throw receiptsBeforeError;
  }

  console.log(
    `[BASELINE] Round receipts: ${receiptsBefore ?? 0}`,
  );

  console.log("");
  console.log(
    "=== 7. ENQUEUE IMMEDIATE REAL POLL_BATCH ===",
  );

  const now =
    new Date();

  const correlationId =
    randomUUID();

  const activationKey = [
    "live",
    "poll-batch",
    "football_data",
    round.id,
    "prematch",
    "activation",
    now
      .toISOString()
      .slice(0, 13),
  ].join(":");

  const immediate =
    await enqueueLiveRuntimeJob(
      client,
      {
        jobType:
          "poll_batch",
        scopeType:
          "fantagol_round",
        scopeId:
          round.id,
        idempotencyKey:
          activationKey,
        priority:
          1,
        scheduledAt:
          now.toISOString(),
        payload: {
          provider_code:
            "football_data",
          mode:
            "prematch",
          competition_code:
            "SA",
          date_from:
            dateFrom,
          date_to:
            dateTo,
          polling_band:
            "activation_immediate",
          polling_reason:
            "a8d67e_real_activation",
          match_targets:
            targets.map(
              (target) => ({
                match_id:
                  target.matchId,
                external_match_id:
                  target.externalMatchId,
                fantagol_round_id:
                  round.id,
                league_round_ids:
                  leagueRoundIds,
                kickoff_at:
                  target.kickoffAt,
                current_status:
                  target.status,
              }),
            ),
        },
        correlationId,
        causationId:
          null,
      },
    );

  console.log(
    `[PASS] poll_batch job=${immediate.jobId} | inserted=${immediate.inserted} | status=${immediate.jobStatus}`,
  );

  console.log("");
  console.log(
    "=== 8. RUN REAL WORKER - POLL_BATCH ONLY ===",
  );

  const worker =
    await runLiveRuntimeWorkerOnce(
      {
        client,
        workerId:
          `a8d67e-${process.pid}`,
        jobTypes:
          ["poll_batch"],
        retryDelaySeconds:
          60,
      },
    );

  console.log(
    JSON.stringify(
      worker,
      null,
      2,
    ),
  );

  if (!worker.claimed) {
    throw new Error(
      "Worker did not claim poll_batch",
    );
  }

  if (!worker.completed) {
    throw new Error(
      `poll_batch failed: ${JSON.stringify(worker.error)}`,
    );
  }

  console.log(
    "[PASS] REAL poll_batch completed",
  );

  console.log("");
  console.log(
    "=== 9. VERIFY REAL INGESTION ===",
  );

  const {
    count:
      receiptsAfter,
    error:
      receiptsAfterError,
  } =
    await client
      .from(
        "live_match_update_receipts",
      )
      .select(
        "id",
        {
          count: "exact",
          head: true,
        },
      )
      .in(
        "match_id",
        matchIds,
      );

  if (receiptsAfterError) {
    throw receiptsAfterError;
  }

  console.log(
    `[RESULT] Round receipts before=${receiptsBefore ?? 0} after=${receiptsAfter ?? 0}`,
  );

  const {
    data: recentReceipts,
    error:
      recentReceiptsError,
  } =
    await client
      .from(
        "live_match_update_receipts",
      )
      .select("match_id,external_match_id,meaningful_change,change_type,processing_status,received_at")
      .in(
        "match_id",
        matchIds,
      )
      .order(
        "received_at",
        {
          ascending: false,
        },
      )
      .limit(20);

  if (recentReceiptsError) {
    throw recentReceiptsError;
  }

  for (
    const receipt of
    recentReceipts ?? []
  ) {
    console.log(
      `[RECEIPT] fd=${receipt.external_match_id} | status=${receipt.processing_status} | meaningful=${String(receipt.meaningful_change)} | change=${receipt.change_type ?? "-"}`,
    );
  }

  console.log("");
  console.log(
    "=== 10. SCHEDULE NEXT POLICY-DRIVEN AGGREGATE ===",
  );

  const next =
    await scheduleFootballDataAggregatedPolling(
      {
        client,
        targets,
        now:
          new Date(),
        correlationId,
        causationId:
          immediate.jobId,
        priority:
          10,
        competitionCode:
          "SA",
      },
    );

  if (
    next.length < 1
  ) {
    throw new Error(
      "No next aggregate poll scheduled",
    );
  }

  for (
    const scheduled of next
  ) {
    console.log(
      `[NEXT] mode=${scheduled.plan.mode} | band=${scheduled.decision.band} | interval=${scheduled.decision.intervalSeconds}s | at=${scheduled.nextPollAt} | job=${scheduled.job.jobId}`,
    );
  }

  const prematchNext =
    next.find(
      (item) =>
        item.plan.mode ===
        "prematch",
    );

  if (
    !prematchNext
  ) {
    throw new Error(
      "Expected next PREMATCH aggregate",
    );
  }

  /*
   * On 2026-08-09 this must be bootstrap_dormant / 21600s.
   */
  console.log(
    `[PASS] Next PREMATCH cadence = ${prematchNext.decision.intervalSeconds} seconds`,
  );

  console.log("");
  console.log(
    "================================================================",
  );
  console.log(
    "[PASS] A8D.6.7E REAL FOOTBALL DATA CYCLE COMPLETE",
  );
  console.log(
    "================================================================",
  );
  console.log("");
  console.log(
    "REAL FOOTBALL DATA REQUESTS: 1",
  );
  console.log(
    "REAL POLL_BATCH COMPLETED: YES",
  );
  console.log(
    "NEXT POLICY JOB SCHEDULED: YES",
  );
}

main().catch(
  (error) => {
    console.error("");
    console.error(
      "[FAIL] A8D.6.7E",
    );
    console.error(error);
    process.exitCode = 1;
  },
);