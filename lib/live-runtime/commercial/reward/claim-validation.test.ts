import {
  describe,
  expect,
  it,
} from "vitest";

import {
  normalizeRewardClaimSubmissionResult,
} from "./validation";

const CLAIM_ID =
  "11111111-1111-4111-8111-111111111111";

const SERVER_TIME =
  "2026-07-23T21:00:00.000Z";

function createSuccess() {
  return {
    submitted: true,
    created: true,
    claim_id: CLAIM_ID,
    claim_status:
      "verification_pending",
    verification_status: "pending",
    campaign_code:
      "LEAGUE_FIRST_ROUND_COMPLETED",
    source_code: "LOYALTY_EVENT",
    passes: 1,
    server_time: SERVER_TIME,
  };
}

describe(
  "normalizeRewardClaimSubmissionResult success",
  () => {
    it("accepts a newly created claim", () => {
      expect(
        normalizeRewardClaimSubmissionResult(
          createSuccess(),
        ),
      ).toEqual(createSuccess());
    });

    it("accepts an existing idempotent claim without source_code", () => {
      const payload = {
        ...createSuccess(),
        created: false,
      };

      delete (
        payload as Partial<
          ReturnType<typeof createSuccess>
        >
      ).source_code;

      expect(
        normalizeRewardClaimSubmissionResult(
          payload,
        ),
      ).toEqual(payload);
    });

    it.each([
      "submitted",
      "verification_pending",
      "verified",
      "rejected",
      "settled",
      "expired",
    ] as const)(
      "accepts claim status %s",
      (claim_status) => {
        const result =
          normalizeRewardClaimSubmissionResult({
            ...createSuccess(),
            claim_status,
          });

        expect(
          result.submitted &&
            result.claim_status,
        ).toBe(claim_status);
      },
    );

    it.each([
      "pending",
      "processing",
      "verified",
      "rejected",
      "expired",
    ] as const)(
      "accepts verification status %s",
      (verification_status) => {
        const result =
          normalizeRewardClaimSubmissionResult({
            ...createSuccess(),
            verification_status,
          });

        expect(
          result.submitted &&
            result.verification_status,
        ).toBe(verification_status);
      },
    );

    it("rejects an invalid claim UUID", () => {
      expect(() =>
        normalizeRewardClaimSubmissionResult({
          ...createSuccess(),
          claim_id: "invalid",
        }),
      ).toThrow(
        "reward_claim_submission.claim_id must be a valid UUID.",
      );
    });

    it("rejects an invalid claim status", () => {
      expect(() =>
        normalizeRewardClaimSubmissionResult({
          ...createSuccess(),
          claim_status: "queued",
        }),
      ).toThrow(
        "reward_claim_submission.claim_status is invalid.",
      );
    });

    it("rejects an invalid verification status", () => {
      expect(() =>
        normalizeRewardClaimSubmissionResult({
          ...createSuccess(),
          verification_status: "unknown",
        }),
      ).toThrow(
        "reward_claim_submission.verification_status is invalid.",
      );
    });

    it.each([
      0,
      -1,
      1.5,
      Number.MAX_SAFE_INTEGER + 1,
    ])(
      "rejects invalid passes %s",
      (passes) => {
        expect(() =>
          normalizeRewardClaimSubmissionResult({
            ...createSuccess(),
            passes,
          }),
        ).toThrow(
          "reward_claim_submission.passes must be a positive safe integer.",
        );
      },
    );

    it("rejects an invalid server timestamp", () => {
      expect(() =>
        normalizeRewardClaimSubmissionResult({
          ...createSuccess(),
          server_time: "invalid",
        }),
      ).toThrow(
        "reward_claim_submission.server_time must be a valid timestamp.",
      );
    });
  },
);

describe(
  "normalizeRewardClaimSubmissionResult failure",
  () => {
    it.each([
      {
        error_code:
          "REWARD_CAMPAIGN_NOT_AVAILABLE",
        campaign_code:
          "UNAVAILABLE_CAMPAIGN",
      },
      {
        error_code:
          "REWARD_SOURCE_NOT_AVAILABLE",
        source_code:
          "UNAVAILABLE_SOURCE",
      },
      {
        error_code:
          "REWARD_USER_CLAIM_LIMIT_REACHED",
        campaign_code:
          "LIMITED_CAMPAIGN",
      },
      {
        error_code:
          "COMMERCIAL_WALLET_NOT_ACTIVE",
      },
    ] as const)(
      "accepts failure $error_code",
      (failure) => {
        const payload = {
          submitted: false,
          ...failure,
          server_time: SERVER_TIME,
        };

        expect(
          normalizeRewardClaimSubmissionResult(
            payload,
          ),
        ).toEqual(payload);
      },
    );

    it("accepts cooldown failure with retry timestamp", () => {
      const payload = {
        submitted: false,
        error_code:
          "REWARD_CLAIM_COOLDOWN_ACTIVE",
        retry_after:
          "2026-07-23T22:00:00.000Z",
        server_time: SERVER_TIME,
      };

      expect(
        normalizeRewardClaimSubmissionResult(
          payload,
        ),
      ).toEqual(payload);
    });

    it("rejects an unsupported failure code", () => {
      expect(() =>
        normalizeRewardClaimSubmissionResult({
          submitted: false,
          error_code:
            "WELCOME_BONUS_NOT_AVAILABLE",
          server_time: SERVER_TIME,
        }),
      ).toThrow(
        "reward_claim_submission.error_code is invalid.",
      );
    });

    it("rejects invalid retry_after", () => {
      expect(() =>
        normalizeRewardClaimSubmissionResult({
          submitted: false,
          error_code:
            "REWARD_CLAIM_COOLDOWN_ACTIVE",
          retry_after: "invalid",
          server_time: SERVER_TIME,
        }),
      ).toThrow(
        "reward_claim_submission.retry_after must be a valid timestamp when present.",
      );
    });

    it("rejects a missing submitted discriminator", () => {
      expect(() =>
        normalizeRewardClaimSubmissionResult({
          server_time: SERVER_TIME,
        }),
      ).toThrow(
        "reward_claim_submission.submitted must be a boolean.",
      );
    });

    it("rejects a non-object payload", () => {
      expect(() =>
        normalizeRewardClaimSubmissionResult(
          null,
        ),
      ).toThrow(
        "reward_claim_submission must be a JSON object.",
      );
    });
  },
);
