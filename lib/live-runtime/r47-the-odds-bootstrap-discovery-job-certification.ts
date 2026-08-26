import { strict as assert } from "node:assert";

import {
  parseTheOddsBootstrapDiscoveryPlan,
} from "./poll-batch-handler";

const normal =
  parseTheOddsBootstrapDiscoveryPlan({
    providerCode:
      "the_odds_api",
    mode:
      "prematch",
    payload: {
      provider_code:
        "the_odds_api",
      mode:
        "prematch",
      match_targets: [
        {
          match_id:
            "internal-1",
          external_match_id:
            "external-1",
        },
      ],
    },
  });

assert.equal(
  normal.bootstrapDiscovery,
  false,
);

const discovery =
  parseTheOddsBootstrapDiscoveryPlan({
    providerCode:
      "the_odds_api",
    mode:
      "prematch",
    payload: {
      provider_code:
        "the_odds_api",
      mode:
        "prematch",
      bootstrap_discovery:
        true,
      fantagol_round_id:
        "43e943c7-df99-4c0b-8732-e6f505694271",
      competition_code:
        "SA",
    },
  });

assert.equal(
  discovery.bootstrapDiscovery,
  true,
);

if (
  discovery.bootstrapDiscovery
) {
  assert.equal(
    discovery.fantagolRoundId,
    "43e943c7-df99-4c0b-8732-e6f505694271",
  );

  assert.equal(
    discovery.competitionCode,
    "SA",
  );
}

assert.throws(
  () =>
    parseTheOddsBootstrapDiscoveryPlan({
      providerCode:
        "football_data",
      mode:
        "prematch",
      payload: {
        bootstrap_discovery:
          true,
        fantagol_round_id:
          "round-1",
      },
    }),
  /THE_ODDS_BOOTSTRAP_DISCOVERY_PROVIDER_INVALID/,
);

assert.throws(
  () =>
    parseTheOddsBootstrapDiscoveryPlan({
      providerCode:
        "the_odds_api",
      mode:
        "live",
      payload: {
        bootstrap_discovery:
          true,
        fantagol_round_id:
          "round-1",
      },
    }),
  /THE_ODDS_BOOTSTRAP_DISCOVERY_MODE_INVALID/,
);

assert.throws(
  () =>
    parseTheOddsBootstrapDiscoveryPlan({
      providerCode:
        "the_odds_api",
      mode:
        "prematch",
      payload: {
        bootstrap_discovery:
          true,
        fantagol_round_id:
          "round-1",
        match_targets: [],
      },
    }),
  /THE_ODDS_BOOTSTRAP_DISCOVERY_MATCH_TARGETS_FORBIDDEN/,
);

assert.throws(
  () =>
    parseTheOddsBootstrapDiscoveryPlan({
      providerCode:
        "the_odds_api",
      mode:
        "prematch",
      payload: {
        bootstrap_discovery:
          true,
      },
    }),
  /Missing required field 'fantagol_round_id'/,
);

console.log(
  "[PASS] normal poll_batch remains match-target based",
);

console.log(
  "[PASS] bootstrap discovery payload recognized",
);

console.log(
  "[PASS] bootstrap provider locked to the_odds_api",
);

console.log(
  "[PASS] bootstrap mode locked to prematch",
);

console.log(
  "[PASS] hybrid match_targets payload rejected",
);

console.log(
  "[PASS] bootstrap round identity required",
);
