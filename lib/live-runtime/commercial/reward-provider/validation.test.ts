import {
  describe,
  expect,
  it,
} from "vitest";

import {
  normalizeCanonicalRewardProviderEvent,
  normalizeRewardProviderVerificationResult,
} from "./validation";

const CORRELATION_ID =
  "11111111-1111-4111-8111-111111111111";

const CAUSATION_ID =
  "22222222-2222-4222-8222-222222222222";

const PAYLOAD_HASH =
  "a".repeat(64);

function createEvent() {
  return {
    provider_code: "REWARDED_AD_TEST",
    adapter_code:
      "REWARDED_AD_TEST_ADAPTER",
    adapter_version: 1,
    environment: "test",
    source_code: "REWARDED_AD",
    provider_event_id:
      "provider-event-0001",
    provider_event_type:
      "REWARDED_VIDEO_COMPLETED",
    external_claim_reference:
      "reward-claim-0001",
    payload_hash: PAYLOAD_HASH,
    payload: {
      placement: "control_room",
      completed: true,
    },
    signature_verified: true,
    signature_algorithm:
      "HMAC_SHA256",
    occurred_at:
      "2026-07-23T20:00:00.000Z",
    received_at:
      "2026-07-23T20:00:01.000Z",
    correlation_id: CORRELATION_ID,
    causation_id: CAUSATION_ID,
    metadata: {
      passive_runtime: true,
    },
  };
}

describe(
  "normalizeCanonicalRewardProviderEvent",
  () => {
    it("accepts a complete canonical event", () => {
      const event = createEvent();

      expect(
        normalizeCanonicalRewardProviderEvent(
          event,
        ),
      ).toEqual(event);
    });

    it.each([
      "test",
      "live",
    ] as const)(
      "accepts environment %s",
      (environment) => {
        const result =
          normalizeCanonicalRewardProviderEvent({
            ...createEvent(),
            environment,
          });

        expect(result.environment)
          .toBe(environment);
      },
    );

    it("accepts nullable optional references", () => {
      const result =
        normalizeCanonicalRewardProviderEvent({
          ...createEvent(),
          external_claim_reference: null,
          signature_algorithm: null,
          occurred_at: null,
          causation_id: null,
        });

      expect(result).toMatchObject({
        external_claim_reference: null,
        signature_algorithm: null,
        occurred_at: null,
        causation_id: null,
      });
    });

    it("preserves JSON extension fields", () => {
      const result =
        normalizeCanonicalRewardProviderEvent({
          ...createEvent(),
          provider_region: "EU",
        });

      expect(result.provider_region)
        .toBe("EU");
    });

    it("rejects invalid provider codes", () => {
      expect(() =>
        normalizeCanonicalRewardProviderEvent({
          ...createEvent(),
          provider_code:
            "invalid-provider",
        }),
      ).toThrow(
        "reward_provider_event.provider_code must be an uppercase code.",
      );
    });

    it("rejects invalid adapter versions", () => {
      expect(() =>
        normalizeCanonicalRewardProviderEvent({
          ...createEvent(),
          adapter_version: 0,
        }),
      ).toThrow(
        "reward_provider_event.adapter_version must be a positive safe integer.",
      );
    });

    it("rejects unsupported environments", () => {
      expect(() =>
        normalizeCanonicalRewardProviderEvent({
          ...createEvent(),
          environment: "staging",
        }),
      ).toThrow(
        "reward_provider_event.environment is invalid.",
      );
    });

    it("rejects oversized event identifiers", () => {
      expect(() =>
        normalizeCanonicalRewardProviderEvent({
          ...createEvent(),
          provider_event_id:
            "x".repeat(301),
        }),
      ).toThrow(
        "reward_provider_event.provider_event_id must contain between 1 and 300 characters.",
      );
    });

    it("rejects non-SHA256 payload hashes", () => {
      expect(() =>
        normalizeCanonicalRewardProviderEvent({
          ...createEvent(),
          payload_hash: "invalid",
        }),
      ).toThrow(
        "reward_provider_event.payload_hash must be a lowercase SHA-256 hexadecimal digest.",
      );
    });

    it("rejects uppercase payload hashes", () => {
      expect(() =>
        normalizeCanonicalRewardProviderEvent({
          ...createEvent(),
          payload_hash:
            "A".repeat(64),
        }),
      ).toThrow(
        "reward_provider_event.payload_hash must be a lowercase SHA-256 hexadecimal digest.",
      );
    });

    it("rejects array payloads", () => {
      expect(() =>
        normalizeCanonicalRewardProviderEvent({
          ...createEvent(),
          payload: [],
        }),
      ).toThrow(
        "reward_provider_event.payload must be a JSON object.",
      );
    });

    it("rejects invalid signature algorithms", () => {
      expect(() =>
        normalizeCanonicalRewardProviderEvent({
          ...createEvent(),
          signature_algorithm:
            "MD5",
        }),
      ).toThrow(
        "reward_provider_event.signature_algorithm is invalid.",
      );
    });

    it("rejects future event occurrence", () => {
      expect(() =>
        normalizeCanonicalRewardProviderEvent({
          ...createEvent(),
          occurred_at:
            "2026-07-23T20:00:02.000Z",
          received_at:
            "2026-07-23T20:00:01.000Z",
        }),
      ).toThrow(
        "reward_provider_event.occurred_at cannot be later than received_at.",
      );
    });

    it("rejects invalid correlation identifiers", () => {
      expect(() =>
        normalizeCanonicalRewardProviderEvent({
          ...createEvent(),
          correlation_id: "invalid",
        }),
      ).toThrow(
        "reward_provider_event.correlation_id must contain between 36 and 36 characters.",
      );
    });
  },
);

describe(
  "normalizeRewardProviderVerificationResult",
  () => {
    it("accepts a verified event", () => {
      const payload = {
        verified: true,
        event: createEvent(),
      };

      expect(
        normalizeRewardProviderVerificationResult(
          payload,
        ),
      ).toEqual(payload);
    });

    it("rejects verified results with an unverified signature", () => {
      expect(() =>
        normalizeRewardProviderVerificationResult({
          verified: true,
          event: {
            ...createEvent(),
            signature_verified: false,
          },
        }),
      ).toThrow(
        "reward_provider_verification.event.signature_verified must be true for a verified result.",
      );
    });

    it.each([
      "REWARD_PROVIDER_NOT_REGISTERED",
      "REWARD_PROVIDER_DISABLED",
      "REWARD_PROVIDER_BINDING_NOT_FOUND",
      "REWARD_PROVIDER_BINDING_DISABLED",
      "REWARD_PROVIDER_PAYLOAD_INVALID",
      "REWARD_PROVIDER_SIGNATURE_MISSING",
      "REWARD_PROVIDER_SIGNATURE_INVALID",
      "REWARD_PROVIDER_EVENT_EXPIRED",
      "REWARD_PROVIDER_EVENT_REPLAYED",
      "REWARD_PROVIDER_VERIFICATION_FAILED",
    ] as const)(
      "accepts verification failure %s",
      (error_code) => {
        const payload = {
          verified: false,
          error_code,
          error_message:
            "Verification rejected.",
          provider_code:
            "REWARDED_AD_TEST",
          provider_event_id:
            "provider-event-0001",
          correlation_id:
            CORRELATION_ID,
          metadata: {},
        };

        expect(
          normalizeRewardProviderVerificationResult(
            payload,
          ),
        ).toEqual(payload);
      },
    );

    it("accepts nullable failure context", () => {
      const payload = {
        verified: false,
        error_code:
          "REWARD_PROVIDER_PAYLOAD_INVALID",
        error_message: null,
        provider_code: null,
        provider_event_id: null,
        correlation_id:
          CORRELATION_ID,
        metadata: {},
      };

      expect(
        normalizeRewardProviderVerificationResult(
          payload,
        ),
      ).toEqual(payload);
    });

    it("rejects unknown failure codes", () => {
      expect(() =>
        normalizeRewardProviderVerificationResult({
          verified: false,
          error_code:
            "UNKNOWN_PROVIDER_ERROR",
          error_message: null,
          provider_code: null,
          provider_event_id: null,
          correlation_id:
            CORRELATION_ID,
          metadata: {},
        }),
      ).toThrow(
        "reward_provider_verification.error_code is invalid.",
      );
    });

    it("requires the verified discriminator", () => {
      expect(() =>
        normalizeRewardProviderVerificationResult({
          event: createEvent(),
        }),
      ).toThrow(
        "reward_provider_verification.verified must be a boolean.",
      );
    });

    it("rejects non-object results", () => {
      expect(() =>
        normalizeRewardProviderVerificationResult(
          null,
        ),
      ).toThrow(
        "reward_provider_verification must be a JSON object.",
      );
    });
  },
);