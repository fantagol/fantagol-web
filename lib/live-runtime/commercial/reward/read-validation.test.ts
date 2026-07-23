import { describe, expect, it } from "vitest";

import {
  normalizeRewardClaimLookupResult,
  normalizeRewardClaims,
} from "./validation";

const CLAIM_ID = "11111111-1111-4111-8111-111111111111";

const VALID_CLAIM = {
  claim_id: CLAIM_ID,
  campaign_code: "LOYALTY_REWARD",
  source_code: "PROMOTION",
  reward_type: "PASS_REWARD",
  passes_awarded: 1,
  claim_status: "submitted",
  verification_status: "pending",
  submitted_at: "2026-07-23T20:00:00.000Z",
  verified_at: null,
  rejected_at: null,
  settled_at: null,
  expired_at: null,
};

describe("normalizeRewardClaims", () => {
  it("normalizes a reward claim list", () => {
    expect(normalizeRewardClaims([VALID_CLAIM])).toEqual([VALID_CLAIM]);
  });

  it("rejects a non-array payload", () => {
    expect(() => normalizeRewardClaims({})).toThrow(
      "reward_claims must be an array.",
    );
  });

  it("rejects invalid claim identifiers", () => {
    expect(() =>
      normalizeRewardClaims([
        {
          ...VALID_CLAIM,
          claim_id: "invalid",
        },
      ]),
    ).toThrow("reward_claims[0].claim_id must be a valid UUID.");
  });

  it("rejects invalid claim statuses", () => {
    expect(() =>
      normalizeRewardClaims([
        {
          ...VALID_CLAIM,
          claim_status: "unknown",
        },
      ]),
    ).toThrow("reward_claims[0].claim_status is invalid.");
  });

  it("rejects invalid nullable timestamps", () => {
    expect(() =>
      normalizeRewardClaims([
        {
          ...VALID_CLAIM,
          verified_at: "invalid",
        },
      ]),
    ).toThrow(
      "reward_claims[0].verified_at must be a valid timestamp or null.",
    );
  });
});

describe("normalizeRewardClaimLookupResult", () => {
  it("normalizes a found reward claim", () => {
    const result = normalizeRewardClaimLookupResult({
      found: true,
      ...VALID_CLAIM,
      external_claim_reference: null,
      server_time: "2026-07-23T20:01:00.000Z",
    });

    expect(result).toEqual({
      found: true,
      ...VALID_CLAIM,
      external_claim_reference: null,
      server_time: "2026-07-23T20:01:00.000Z",
    });
  });

  it("normalizes a missing reward claim", () => {
    expect(
      normalizeRewardClaimLookupResult({
        found: false,
        error_code: "REWARD_CLAIM_NOT_FOUND",
      }),
    ).toEqual({
      found: false,
      error_code: "REWARD_CLAIM_NOT_FOUND",
    });
  });

  it("rejects an unknown lookup error", () => {
    expect(() =>
      normalizeRewardClaimLookupResult({
        found: false,
        error_code: "UNKNOWN_ERROR",
      }),
    ).toThrow("reward_claim_lookup.error_code is invalid.");
  });

  it("requires the found discriminator", () => {
    expect(() =>
      normalizeRewardClaimLookupResult({
        ...VALID_CLAIM,
      }),
    ).toThrow("reward_claim_lookup.found must be a boolean.");
  });
});
