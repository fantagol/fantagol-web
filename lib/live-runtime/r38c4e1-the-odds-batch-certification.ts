import assert from "node:assert/strict";

import {
  TheOddsApiLiveAdapter,
} from "./the-odds-api-live-adapter";
import {
  supportsProviderBatchPolling,
} from "./provider-runtime";

async function main(): Promise<void> {
  const events = [
    {
      id: "e1",
      sport_key: "soccer_italy_serie_a",
      commence_time: "2026-08-22T16:30:00Z",
      home_team: "Home 1",
      away_team: "Away 1",
      bookmakers: [],
    },
    {
      id: "e2",
      sport_key: "soccer_italy_serie_a",
      commence_time: "2026-08-22T18:45:00Z",
      home_team: "Home 2",
      away_team: "Away 2",
      bookmakers: [],
    },
    {
      id: "unrequested",
      sport_key: "soccer_italy_serie_a",
      commence_time: "2026-08-22T20:45:00Z",
      home_team: "Ignore",
      away_team: "Ignore",
      bookmakers: [],
    },
  ];

  let requests = 0;
  let requestedUrl = "";

  const fetchImpl: typeof fetch =
    async (input) => {
      requests += 1;
      requestedUrl = String(input);

      return new Response(
        JSON.stringify(events),
        {
          status: 200,
          headers: {
            "content-type":
              "application/json",
            "x-requests-remaining":
              "480",
            "x-requests-used":
              "20",
            "x-requests-last":
              "1",
          },
        },
      );
    };

  const adapter =
    new TheOddsApiLiveAdapter({
      apiKey: "offline-test-key",
      fetchImpl,
    });

  assert.equal(
    supportsProviderBatchPolling(adapter),
    true,
  );

  const result =
    await adapter.pollMatches(
      {} as never,
      {
        providerCode:
          "the_odds_api",
        externalMatchIds:
          ["e1", "e2"],
        mode:
          "prematch",
        competitionCode:
          "SA",
      },
    );

  assert.equal(requests, 1);

  const url =
    new URL(requestedUrl);

  assert.equal(
    url.pathname,
    "/v4/sports/soccer_italy_serie_a/odds",
  );

  assert.equal(
    url.searchParams.get("markets"),
    "h2h,totals",
  );

  assert.equal(
    url.searchParams.get("regions"),
    "eu",
  );

  assert.equal(
    url.searchParams.get("eventIds"),
    "e1,e2",
  );

  assert.equal(
    result.providerCode,
    "the_odds_api",
  );

  assert.deepEqual(
    result.requestedExternalMatchIds,
    ["e1", "e2"],
  );

  assert.deepEqual(
    result.returnedExternalMatchIds,
    ["e1", "e2"],
  );

  assert.equal(
    result.results.length,
    2,
  );

  assert.equal(
    result.results[0]?.externalMatchId,
    "e1",
  );

  assert.equal(
    (
      result.results[0]?.payload as {
        eventOdds?: {
          id?: string;
        };
      }
    ).eventOdds?.id,
    "e1",
  );

  assert.equal(
    (
      result.transport as {
        quota?: {
          requestsLast?: number;
        };
      }
    ).quota?.requestsLast,
    1,
  );

  console.log(
    "[PASS] R38-C4-E1-R1 THE ODDS API BATCH CAPABILITY",
  );
  console.log(
    "[PASS] one package HTTP request -> requested event results",
  );
  console.log(
    "[PASS] unrequested event discarded",
  );
  console.log(
    "[PASS] h2h + totals package contract preserved",
  );
  console.log(
    "[PASS] quota metadata preserved",
  );
}

void main().catch((error: unknown) => {
  console.error(error);
  process.exitCode = 1;
});
