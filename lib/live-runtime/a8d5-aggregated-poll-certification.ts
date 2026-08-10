import { strict as assert } from "node:assert";

import type { SupabaseClient } from "@supabase/supabase-js";

import { FootballDataLiveAdapter } from "./football-data-live-adapter";
import { ProviderRuntimeRegistry } from "./provider-runtime";
import { executeProviderBatchPoll } from "./provider-runtime-runner";

let fetchCount = 0;

const fakeMatch = (
  id: number,
  home: string,
  away: string,
) => ({
  area: {
    id: 2072,
    name: "Italy",
    code: "ITA",
  },
  competition: {
    id: 2019,
    name: "Serie A",
    code: "SA",
    type: "LEAGUE",
    emblem: null,
  },
  season: {
    id: 999,
    startDate: "2026-08-01",
    endDate: "2027-05-31",
    currentMatchday: 1,
    winner: null,
  },
  id,
  utcDate: "2026-08-22T16:30:00Z",
  status: "IN_PLAY",
  matchday: 1,
  stage: "REGULAR_SEASON",
  group: null,
  lastUpdated: "2026-08-22T16:31:00Z",
  homeTeam: {
    id: id * 10 + 1,
    name: home,
    shortName: home,
    tla: home.slice(0, 3).toUpperCase(),
    crest: null,
  },
  awayTeam: {
    id: id * 10 + 2,
    name: away,
    shortName: away,
    tla: away.slice(0, 3).toUpperCase(),
    crest: null,
  },
  score: {
    winner: null,
    duration: "REGULAR",
    fullTime: {
      home: 0,
      away: 0,
    },
    halfTime: {
      home: null,
      away: null,
    },
  },
});

const fetchImpl: typeof fetch =
  async (input) => {
    fetchCount += 1;

    const url = String(input);

    assert.equal(
      url,
      "https://api.football-data.org/v4/matches?competitions=SA&status=LIVE",
    );

    return new Response(
      JSON.stringify({
        filters: {
          status: ["IN_PLAY", "PAUSED"],
        },
        resultSet: {
          count: 3,
          first: null,
          last: null,
          played: 0,
        },
        matches: [
          fakeMatch(1001, "Inter", "Monza"),
          fakeMatch(1002, "Udinese", "Como"),
          fakeMatch(9999, "Other", "Match"),
        ],
      }),
      {
        status: 200,
        headers: {
          "content-type": "application/json",
          "x-api-version": "v4",
          "x-authenticated-client": "offline-test",
          "x-requestsavailable": "9",
          "x-requestcounter-reset": "60",
        },
      },
    );
  };

async function main() {
  const registry =
    new ProviderRuntimeRegistry();

  registry.register(
    "football_data",
    new FootballDataLiveAdapter({
      apiToken: "OFFLINE_TEST_TOKEN",
      fetchImpl,
    }),
  );

  const result =
    await executeProviderBatchPoll(
      {} as SupabaseClient,
      registry,
      "football_data",
      ["1001", "1002"],
    );

  assert.equal(fetchCount, 1);

  assert.equal(
    result.providerCode,
    "football_data",
  );

  assert.deepEqual(
    result.requestedExternalMatchIds,
    ["1001", "1002"],
  );

  assert.deepEqual(
    result.returnedExternalMatchIds,
    ["1001", "1002"],
  );

  assert.equal(result.results.length, 2);

  assert.equal(
    result.results[0]?.externalMatchId,
    "1001",
  );

  assert.equal(
    result.results[1]?.externalMatchId,
    "1002",
  );

  for (const item of result.results) {
    assert.equal(
      item.providerCode,
      "football_data",
    );

    assert.equal(
      typeof item.fetchedAt,
      "string",
    );

    assert.equal(
      typeof item.payload,
      "object",
    );
  }

  console.log("");
  console.log(
    "[PASS] A8D.5 AGGREGATED POLL CONTRACT",
  );
  console.log("");
  console.log(
    `HTTP requests simulated: ${fetchCount}`,
  );
  console.log(
    `Requested matches: ${result.requestedExternalMatchIds.length}`,
  );
  console.log(
    `Returned matches: ${result.results.length}`,
  );
  console.log(
    `Returned IDs: ${result.returnedExternalMatchIds.join(",")}`,
  );
  console.log("");
  console.log(
    "[PASS] 1 HTTP request -> N ProviderPollResult",
  );
  console.log(
    "[PASS] Match-specific ProviderPollResult preserved",
  );
  console.log(
    "[PASS] Unrequested provider match discarded",
  );
}

void main();