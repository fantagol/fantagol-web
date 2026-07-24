import {
  describe,
  expect,
  it,
  vi,
} from "vitest";

import type {
  CanonicalRewardProviderEvent,
  RewardProviderAdapter,
  RewardProviderAdapterInput,
  RewardProviderVerificationResult,
} from "./types";
import {
  RewardProviderAdapterRegistry,
} from "./registry";
import {
  RewardProviderPassiveVerificationService,
} from "./service";

const CORRELATION_ID =
  "11111111-1111-4111-8111-111111111111";

const CAUSATION_ID =
  "22222222-2222-4222-8222-222222222222";

const PAYLOAD_HASH =
  "a".repeat(64);

function createInput(
  environment:
    "test" | "live" = "test",
): RewardProviderAdapterInput {
  return {
    headers: {
      "x-provider-signature":
        "test-signature",
    },
    payload: {
      provider_event_id:
        "provider-event-0001",
    },
    rawPayload:
      '{"provider_event_id":"provider-event-0001"}',
    context: {
      environment,
      receivedAt:
        "2026-07-23T20:00:01.000Z",
      correlationId:
        CORRELATION_ID,
      causationId:
        CAUSATION_ID,
    },
  };
}

function createCanonicalEvent(
  overrides: Partial<
    CanonicalRewardProviderEvent
  > = {},
): CanonicalRewardProviderEvent {
  return {
    provider_code:
      "REWARDED_AD_TEST",
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
      completed: true,
    },
    signature_verified: true,
    signature_algorithm:
      "HMAC_SHA256",
    occurred_at:
      "2026-07-23T20:00:00.000Z",
    received_at:
      "2026-07-23T20:00:01.000Z",
    correlation_id:
      CORRELATION_ID,
    causation_id:
      CAUSATION_ID,
    metadata: {
      passive_runtime: true,
    },
    ...overrides,
  };
}

function createAdapter(
  result:
    RewardProviderVerificationResult,
  overrides: Partial<
    Pick<
      RewardProviderAdapter,
      | "providerCode"
      | "adapterCode"
      | "adapterVersion"
    >
  > = {},
): RewardProviderAdapter {
  return {
    providerCode:
      overrides.providerCode ??
      "REWARDED_AD_TEST",
    adapterCode:
      overrides.adapterCode ??
      "REWARDED_AD_TEST_ADAPTER",
    adapterVersion:
      overrides.adapterVersion ?? 1,
    verifyAndNormalize:
      vi.fn(async () => result),
  };
}

function registerAdapter(
  registry:
    RewardProviderAdapterRegistry,
  adapter: RewardProviderAdapter,
  options: {
    environment?: "test" | "live";
    enabled?: boolean;
  } = {},
): void {
  registry.register({
    providerCode:
      adapter.providerCode,
    adapterCode:
      adapter.adapterCode,
    adapterVersion:
      adapter.adapterVersion,
    environment:
      options.environment ?? "test",
    enabled:
      options.enabled ?? true,
    adapter,
  });
}

describe(
  "RewardProviderPassiveVerificationService",
  () => {
    it("returns a verified canonical event", async () => {
      const registry =
        new RewardProviderAdapterRegistry();

      const event =
        createCanonicalEvent();

      const adapter =
        createAdapter({
          verified: true,
          event,
        });

      registerAdapter(
        registry,
        adapter,
      );

      const service =
        new RewardProviderPassiveVerificationService(
          registry,
        );

      await expect(
        service.verify({
          lookup: {
            providerCode:
              "REWARDED_AD_TEST",
            environment: "test",
          },
          input: createInput(),
        }),
      ).resolves.toEqual({
        verified: true,
        event,
      });

      expect(
        adapter.verifyAndNormalize,
      ).toHaveBeenCalledTimes(1);
    });

    it("preserves a canonical adapter failure", async () => {
      const registry =
        new RewardProviderAdapterRegistry();

      const failure:
        RewardProviderVerificationResult = {
          verified: false,
          error_code:
            "REWARD_PROVIDER_SIGNATURE_INVALID",
          error_message:
            "Invalid signature.",
          provider_code:
            "REWARDED_AD_TEST",
          provider_event_id:
            "provider-event-0001",
          correlation_id:
            CORRELATION_ID,
          metadata: {
            signature_checked: true,
          },
        };

      const adapter =
        createAdapter(failure);

      registerAdapter(
        registry,
        adapter,
      );

      const service =
        new RewardProviderPassiveVerificationService(
          registry,
        );

      await expect(
        service.verify({
          lookup: {
            providerCode:
              "REWARDED_AD_TEST",
            environment: "test",
          },
          input: createInput(),
        }),
      ).resolves.toEqual(failure);
    });

    it("maps an unknown adapter to provider not registered", async () => {
      const service =
        new RewardProviderPassiveVerificationService(
          new RewardProviderAdapterRegistry(),
        );

      const result =
        await service.verify({
          lookup: {
            providerCode:
              "REWARDED_AD_TEST",
            environment: "test",
          },
          input: createInput(),
        });

      expect(result).toMatchObject({
        verified: false,
        error_code:
          "REWARD_PROVIDER_NOT_REGISTERED",
        correlation_id:
          CORRELATION_ID,
        metadata: {
          stage:
            "ADAPTER_RESOLUTION",
          registry_error_code:
            "REWARD_PROVIDER_ADAPTER_NOT_FOUND",
        },
      });
    });

    it("maps a disabled adapter to provider disabled", async () => {
      const registry =
        new RewardProviderAdapterRegistry();

      const adapter =
        createAdapter({
          verified: true,
          event:
            createCanonicalEvent(),
        });

      registerAdapter(
        registry,
        adapter,
        {
          enabled: false,
        },
      );

      const service =
        new RewardProviderPassiveVerificationService(
          registry,
        );

      const result =
        await service.verify({
          lookup: {
            providerCode:
              "REWARDED_AD_TEST",
            environment: "test",
          },
          input: createInput(),
        });

      expect(result).toMatchObject({
        verified: false,
        error_code:
          "REWARD_PROVIDER_DISABLED",
        metadata: {
          registry_error_code:
            "REWARD_PROVIDER_ADAPTER_DISABLED",
        },
      });

      expect(
        adapter.verifyAndNormalize,
      ).not.toHaveBeenCalled();
    });

    it("rejects ambiguous adapter resolution", async () => {
      const registry =
        new RewardProviderAdapterRegistry();

      const firstAdapter =
        createAdapter({
          verified: true,
          event:
            createCanonicalEvent(),
        });

      const secondAdapter =
        createAdapter(
          {
            verified: true,
            event:
              createCanonicalEvent({
                adapter_code:
                  "REWARDED_AD_TEST_ADAPTER_V2",
                adapter_version: 2,
              }),
          },
          {
            adapterCode:
              "REWARDED_AD_TEST_ADAPTER_V2",
            adapterVersion: 2,
          },
        );

      registerAdapter(
        registry,
        firstAdapter,
      );

      registerAdapter(
        registry,
        secondAdapter,
      );

      const service =
        new RewardProviderPassiveVerificationService(
          registry,
        );

      const result =
        await service.verify({
          lookup: {
            providerCode:
              "REWARDED_AD_TEST",
            environment: "test",
          },
          input: createInput(),
        });

      expect(result).toMatchObject({
        verified: false,
        error_code:
          "REWARD_PROVIDER_VERIFICATION_FAILED",
        metadata: {
          registry_error_code:
            "REWARD_PROVIDER_ADAPTER_SELECTION_AMBIGUOUS",
        },
      });
    });

    it("rejects lookup and context environment mismatches", async () => {
      const registry =
        new RewardProviderAdapterRegistry();

      const adapter =
        createAdapter({
          verified: true,
          event:
            createCanonicalEvent(),
        });

      registerAdapter(
        registry,
        adapter,
      );

      const service =
        new RewardProviderPassiveVerificationService(
          registry,
        );

      const result =
        await service.verify({
          lookup: {
            providerCode:
              "REWARDED_AD_TEST",
            environment: "test",
          },
          input: createInput("live"),
        });

      expect(result).toMatchObject({
        verified: false,
        error_code:
          "REWARD_PROVIDER_PAYLOAD_INVALID",
        metadata: {
          stage:
            "REQUEST_CONTEXT_VALIDATION",
          lookup_environment:
            "test",
          context_environment:
            "live",
        },
      });

      expect(
        adapter.verifyAndNormalize,
      ).not.toHaveBeenCalled();
    });

    it("converts adapter exceptions into controlled failures", async () => {
      const registry =
        new RewardProviderAdapterRegistry();

      const adapter:
        RewardProviderAdapter = {
          providerCode:
            "REWARDED_AD_TEST",
          adapterCode:
            "REWARDED_AD_TEST_ADAPTER",
          adapterVersion: 1,
          verifyAndNormalize:
            vi.fn(async () => {
              throw new Error(
                "Provider adapter crashed.",
              );
            }),
        };

      registerAdapter(
        registry,
        adapter,
      );

      const service =
        new RewardProviderPassiveVerificationService(
          registry,
        );

      const result =
        await service.verify({
          lookup: {
            providerCode:
              "REWARDED_AD_TEST",
            environment: "test",
          },
          input: createInput(),
        });

      expect(result).toMatchObject({
        verified: false,
        error_code:
          "REWARD_PROVIDER_VERIFICATION_FAILED",
        error_message:
          "Provider adapter crashed.",
        metadata: {
          stage:
            "ADAPTER_VERIFICATION",
          error_name: "Error",
        },
      });
    });

    it("rejects malformed adapter results", async () => {
      const registry =
        new RewardProviderAdapterRegistry();

      const adapter:
        RewardProviderAdapter = {
          providerCode:
            "REWARDED_AD_TEST",
          adapterCode:
            "REWARDED_AD_TEST_ADAPTER",
          adapterVersion: 1,
          verifyAndNormalize:
            vi.fn(
              async () =>
                ({
                  verified: true,
                  event: null,
                }) as unknown as
                  RewardProviderVerificationResult,
            ),
        };

      registerAdapter(
        registry,
        adapter,
      );

      const service =
        new RewardProviderPassiveVerificationService(
          registry,
        );

      const result =
        await service.verify({
          lookup: {
            providerCode:
              "REWARDED_AD_TEST",
            environment: "test",
          },
          input: createInput(),
        });

      expect(result).toMatchObject({
        verified: false,
        error_code:
          "REWARD_PROVIDER_VERIFICATION_FAILED",
        metadata: {
          stage:
            "ADAPTER_VERIFICATION",
          error_name: "TypeError",
        },
      });
    });

    it.each([
      {
        name: "provider identity",
        overrides: {
          provider_code:
            "REWARDED_AD_OTHER",
        },
      },
      {
        name: "adapter identity",
        overrides: {
          adapter_code:
            "REWARDED_AD_OTHER_ADAPTER",
        },
      },
      {
        name: "adapter version",
        overrides: {
          adapter_version: 2,
        },
      },
      {
        name: "event environment",
        overrides: {
          environment:
            "live" as const,
        },
      },
      {
        name: "correlation identifier",
        overrides: {
          correlation_id:
            "33333333-3333-4333-8333-333333333333",
        },
      },
    ])(
      "rejects canonical $name mismatches",
      async ({ overrides }) => {
        const registry =
          new RewardProviderAdapterRegistry();

        const adapter =
          createAdapter({
            verified: true,
            event:
              createCanonicalEvent(
                overrides,
              ),
          });

        registerAdapter(
          registry,
          adapter,
        );

        const service =
          new RewardProviderPassiveVerificationService(
            registry,
          );

        const result =
          await service.verify({
            lookup: {
              providerCode:
                "REWARDED_AD_TEST",
              environment: "test",
            },
            input: createInput(),
          });

        expect(result).toMatchObject({
          verified: false,
          error_code:
            "REWARD_PROVIDER_VERIFICATION_FAILED",
          metadata: {
            stage:
              "CANONICAL_IDENTITY_VALIDATION",
          },
        });
      },
    );

    it("resolves an explicitly selected adapter version", async () => {
      const registry =
        new RewardProviderAdapterRegistry();

      const firstAdapter =
        createAdapter({
          verified: true,
          event:
            createCanonicalEvent(),
        });

      const secondEvent =
        createCanonicalEvent({
          adapter_code:
            "REWARDED_AD_TEST_ADAPTER_V2",
          adapter_version: 2,
        });

      const secondAdapter =
        createAdapter(
          {
            verified: true,
            event: secondEvent,
          },
          {
            adapterCode:
              "REWARDED_AD_TEST_ADAPTER_V2",
            adapterVersion: 2,
          },
        );

      registerAdapter(
        registry,
        firstAdapter,
      );

      registerAdapter(
        registry,
        secondAdapter,
      );

      const service =
        new RewardProviderPassiveVerificationService(
          registry,
        );

      await expect(
        service.verify({
          lookup: {
            providerCode:
              "REWARDED_AD_TEST",
            adapterCode:
              "REWARDED_AD_TEST_ADAPTER_V2",
            adapterVersion: 2,
            environment: "test",
          },
          input: createInput(),
        }),
      ).resolves.toEqual({
        verified: true,
        event: secondEvent,
      });

      expect(
        firstAdapter.verifyAndNormalize,
      ).not.toHaveBeenCalled();

      expect(
        secondAdapter.verifyAndNormalize,
      ).toHaveBeenCalledTimes(1);
    });
  },
);