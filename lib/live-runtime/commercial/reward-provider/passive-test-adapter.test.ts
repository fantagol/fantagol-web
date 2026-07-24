import {
  describe,
  expect,
  it,
} from "vitest";

import type {
  JsonObject,
} from "../json";
import type {
  RewardProviderAdapterInput,
} from "./types";
import {
  RewardProviderAdapterRegistry,
} from "./registry";
import {
  RewardProviderPassiveVerificationService,
} from "./service";
import {
  PASSIVE_TEST_ADAPTER_CODE,
  PASSIVE_TEST_ADAPTER_VERSION,
  PASSIVE_TEST_PAYLOAD_HASH,
  PASSIVE_TEST_PROVIDER_CODE,
  PASSIVE_TEST_SIGNATURE,
  PASSIVE_TEST_SIGNATURE_HEADER,
  PassiveTestRewardProviderAdapter,
} from "./passive-test-adapter";

const CORRELATION_ID =
  "11111111-1111-4111-8111-111111111111";

const CAUSATION_ID =
  "22222222-2222-4222-8222-222222222222";

function createInput(
  overrides: {
    environment?: "test" | "live";
    signature?: string | null;
    payload?: JsonObject;
  } = {},
): RewardProviderAdapterInput {
  const signature =
    overrides.signature === undefined
      ? PASSIVE_TEST_SIGNATURE
      : overrides.signature;

  const headers:
    Record<string, string> = {};

  if (signature !== null) {
    headers[
      PASSIVE_TEST_SIGNATURE_HEADER
    ] = signature;
  }

  const payload =
    overrides.payload ?? {
      provider_event_id:
        "passive-event-0001",
      provider_event_type:
        "REWARDED_VIDEO_COMPLETED",
      external_claim_reference:
        "passive-claim-0001",
      completed: true,
      occurred_at:
        "2026-07-23T21:00:00.000Z",
    };

  return {
    headers,
    payload,
    rawPayload:
      JSON.stringify(payload),
    context: {
      environment:
        overrides.environment ??
        "test",
      receivedAt:
        "2026-07-23T21:00:01.000Z",
      correlationId:
        CORRELATION_ID,
      causationId:
        CAUSATION_ID,
    },
  };
}

describe(
  "PassiveTestRewardProviderAdapter",
  () => {
    it("exposes a stable adapter identity", () => {
      const adapter =
        new PassiveTestRewardProviderAdapter();

      expect(
        adapter.providerCode,
      ).toBe(
        PASSIVE_TEST_PROVIDER_CODE,
      );

      expect(
        adapter.adapterCode,
      ).toBe(
        PASSIVE_TEST_ADAPTER_CODE,
      );

      expect(
        adapter.adapterVersion,
      ).toBe(
        PASSIVE_TEST_ADAPTER_VERSION,
      );
    });

    it("normalizes a valid synthetic event", async () => {
      const adapter =
        new PassiveTestRewardProviderAdapter();

      const result =
        await adapter.verifyAndNormalize(
          createInput(),
        );

      expect(result).toEqual({
        verified: true,
        event: {
          provider_code:
            PASSIVE_TEST_PROVIDER_CODE,
          adapter_code:
            PASSIVE_TEST_ADAPTER_CODE,
          adapter_version:
            PASSIVE_TEST_ADAPTER_VERSION,
          environment: "test",
          source_code:
            "REWARDED_AD",
          provider_event_id:
            "passive-event-0001",
          provider_event_type:
            "REWARDED_VIDEO_COMPLETED",
          external_claim_reference:
            "passive-claim-0001",
          payload_hash:
            PASSIVE_TEST_PAYLOAD_HASH,
          payload: {
            provider_event_id:
              "passive-event-0001",
            provider_event_type:
              "REWARDED_VIDEO_COMPLETED",
            external_claim_reference:
              "passive-claim-0001",
            completed: true,
            occurred_at:
              "2026-07-23T21:00:00.000Z",
          },
          signature_verified: true,
          signature_algorithm:
            "PROVIDER_MANAGED",
          occurred_at:
            "2026-07-23T21:00:00.000Z",
          received_at:
            "2026-07-23T21:00:01.000Z",
          correlation_id:
            CORRELATION_ID,
          causation_id:
            CAUSATION_ID,
          metadata: {
            passive_test_adapter:
              true,
            synthetic_provider:
              true,
            network_access: false,
            persistence_access:
              false,
            settlement_access:
              false,
          },
        },
      });
    });

    it("rejects live environment usage", async () => {
      const adapter =
        new PassiveTestRewardProviderAdapter();

      const result =
        await adapter.verifyAndNormalize(
          createInput({
            environment: "live",
          }),
        );

      expect(result).toMatchObject({
        verified: false,
        error_code:
          "REWARD_PROVIDER_DISABLED",
        provider_code:
          PASSIVE_TEST_PROVIDER_CODE,
        provider_event_id:
          "passive-event-0001",
        correlation_id:
          CORRELATION_ID,
        metadata: {
          stage:
            "TEST_ENVIRONMENT_ENFORCEMENT",
          requested_environment:
            "live",
        },
      });
    });

    it("rejects a missing signature", async () => {
      const adapter =
        new PassiveTestRewardProviderAdapter();

      const result =
        await adapter.verifyAndNormalize(
          createInput({
            signature: null,
          }),
        );

      expect(result).toMatchObject({
        verified: false,
        error_code:
          "REWARD_PROVIDER_SIGNATURE_MISSING",
        metadata: {
          stage:
            "TEST_SIGNATURE_VERIFICATION",
        },
      });
    });

    it("rejects an invalid signature", async () => {
      const adapter =
        new PassiveTestRewardProviderAdapter();

      const result =
        await adapter.verifyAndNormalize(
          createInput({
            signature:
              "invalid-signature",
          }),
        );

      expect(result).toMatchObject({
        verified: false,
        error_code:
          "REWARD_PROVIDER_SIGNATURE_INVALID",
        metadata: {
          stage:
            "TEST_SIGNATURE_VERIFICATION",
        },
      });
    });

    const invalidPayloadCases:
      ReadonlyArray<{
        name: string;
        payload: JsonObject;
      }> = [
      {
        name:
          "missing provider event identifier",
        payload: {
          provider_event_type:
            "REWARDED_VIDEO_COMPLETED",
          external_claim_reference:
            "passive-claim-0001",
          completed: true,
          occurred_at:
            "2026-07-23T21:00:00.000Z",
        },
      },
      {
        name:
          "missing provider event type",
        payload: {
          provider_event_id:
            "passive-event-0001",
          external_claim_reference:
            "passive-claim-0001",
          completed: true,
          occurred_at:
            "2026-07-23T21:00:00.000Z",
        },
      },
      {
        name:
          "incomplete rewarded event",
        payload: {
          provider_event_id:
            "passive-event-0001",
          provider_event_type:
            "REWARDED_VIDEO_COMPLETED",
          external_claim_reference:
            "passive-claim-0001",
          completed: false,
          occurred_at:
            "2026-07-23T21:00:00.000Z",
        },
      },
      {
        name:
          "future occurrence timestamp",
        payload: {
          provider_event_id:
            "passive-event-0001",
          provider_event_type:
            "REWARDED_VIDEO_COMPLETED",
          external_claim_reference:
            "passive-claim-0001",
          completed: true,
          occurred_at:
            "2026-07-23T22:00:00.000Z",
        },
      },
    ];

    it.each(
      invalidPayloadCases,
    )(
      "rejects payload with $name",
      async ({ payload }) => {
        const adapter =
          new PassiveTestRewardProviderAdapter();

        const result =
          await adapter.verifyAndNormalize(
            createInput({
              payload,
            }),
          );

        expect(result).toMatchObject({
          verified: false,
          error_code:
            "REWARD_PROVIDER_PAYLOAD_INVALID",
          correlation_id:
            CORRELATION_ID,
          metadata: {
            stage:
              "TEST_PAYLOAD_NORMALIZATION",
            error_name:
              "TypeError",
          },
        });
      },
    );

    it("accepts nullable optional payload fields", async () => {
      const adapter =
        new PassiveTestRewardProviderAdapter();

      const result =
        await adapter.verifyAndNormalize(
          createInput({
            payload: {
              provider_event_id:
                "passive-event-0002",
              provider_event_type:
                "REWARDED_VIDEO_COMPLETED",
              external_claim_reference:
                null,
              completed: true,
              occurred_at: null,
            },
          }),
        );

      expect(result).toMatchObject({
        verified: true,
        event: {
          provider_event_id:
            "passive-event-0002",
          external_claim_reference:
            null,
          occurred_at: null,
          causation_id:
            CAUSATION_ID,
        },
      });
    });
  },
);

describe(
  "Passive test provider end-to-end pipeline",
  () => {
    it("verifies through registry and passive service", async () => {
      const registry =
        new RewardProviderAdapterRegistry();

      const adapter =
        new PassiveTestRewardProviderAdapter();

      registry.register({
        providerCode:
          adapter.providerCode,
        adapterCode:
          adapter.adapterCode,
        adapterVersion:
          adapter.adapterVersion,
        environment: "test",
        enabled: true,
        adapter,
      });

      const service =
        new RewardProviderPassiveVerificationService(
          registry,
        );

      const result =
        await service.verify({
          lookup: {
            providerCode:
              PASSIVE_TEST_PROVIDER_CODE,
            adapterCode:
              PASSIVE_TEST_ADAPTER_CODE,
            adapterVersion:
              PASSIVE_TEST_ADAPTER_VERSION,
            environment: "test",
          },
          input: createInput(),
        });

      expect(result).toMatchObject({
        verified: true,
        event: {
          provider_code:
            PASSIVE_TEST_PROVIDER_CODE,
          adapter_code:
            PASSIVE_TEST_ADAPTER_CODE,
          adapter_version:
            PASSIVE_TEST_ADAPTER_VERSION,
          environment: "test",
          provider_event_id:
            "passive-event-0001",
          signature_verified:
            true,
          correlation_id:
            CORRELATION_ID,
        },
      });
    });

    it("preserves a controlled signature failure through the service", async () => {
      const registry =
        new RewardProviderAdapterRegistry();

      const adapter =
        new PassiveTestRewardProviderAdapter();

      registry.register({
        providerCode:
          adapter.providerCode,
        adapterCode:
          adapter.adapterCode,
        adapterVersion:
          adapter.adapterVersion,
        environment: "test",
        enabled: true,
        adapter,
      });

      const service =
        new RewardProviderPassiveVerificationService(
          registry,
        );

      const result =
        await service.verify({
          lookup: {
            providerCode:
              PASSIVE_TEST_PROVIDER_CODE,
            environment: "test",
          },
          input: createInput({
            signature:
              "invalid-signature",
          }),
        });

      expect(result).toMatchObject({
        verified: false,
        error_code:
          "REWARD_PROVIDER_SIGNATURE_INVALID",
        provider_code:
          PASSIVE_TEST_PROVIDER_CODE,
        provider_event_id:
          "passive-event-0001",
        correlation_id:
          CORRELATION_ID,
      });
    });

    it("cannot be selected as a live adapter", async () => {
      const registry =
        new RewardProviderAdapterRegistry();

      const adapter =
        new PassiveTestRewardProviderAdapter();

      registry.register({
        providerCode:
          adapter.providerCode,
        adapterCode:
          adapter.adapterCode,
        adapterVersion:
          adapter.adapterVersion,
        environment: "test",
        enabled: true,
        adapter,
      });

      const service =
        new RewardProviderPassiveVerificationService(
          registry,
        );

      const result =
        await service.verify({
          lookup: {
            providerCode:
              PASSIVE_TEST_PROVIDER_CODE,
            environment: "live",
          },
          input: createInput({
            environment: "live",
          }),
        });

      expect(result).toMatchObject({
        verified: false,
        error_code:
          "REWARD_PROVIDER_NOT_REGISTERED",
        metadata: {
          stage:
            "ADAPTER_RESOLUTION",
          registry_error_code:
            "REWARD_PROVIDER_ADAPTER_NOT_FOUND",
        },
      });
    });
  },
);