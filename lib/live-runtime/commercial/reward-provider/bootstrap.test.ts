import {
  describe,
  expect,
  it,
} from "vitest";

import type {
  JsonObject,
} from "../json";
import {
  PASSIVE_TEST_ADAPTER_CODE,
  PASSIVE_TEST_ADAPTER_VERSION,
  PASSIVE_TEST_PROVIDER_CODE,
  PASSIVE_TEST_SIGNATURE,
  PASSIVE_TEST_SIGNATURE_HEADER,
} from "./passive-test-adapter";
import {
  resolveRewardProviderPolicy,
} from "./policy";import {
  RewardProviderPassiveVerificationService,
} from "./service";
import {
  bootstrapRewardProviderRegistry,
} from "./bootstrap";
import type {
  RewardProviderAdapterInput,
} from "./types";

const CORRELATION_ID =
  "33333333-3333-4333-8333-333333333333";

function createInput(
  environment:
    RewardProviderAdapterInput[
      "context"
    ]["environment"],
): RewardProviderAdapterInput {
  const payload: JsonObject = {
    provider_event_id:
      "bootstrap-event-0001",
    provider_event_type:
      "REWARDED_VIDEO_COMPLETED",
    external_claim_reference:
      "bootstrap-claim-0001",
    completed: true,
    occurred_at:
      "2026-07-23T22:00:00.000Z",
  };

  return {
    headers: {
      [PASSIVE_TEST_SIGNATURE_HEADER]:
        PASSIVE_TEST_SIGNATURE,
    },
    payload,
    rawPayload:
      JSON.stringify(payload),
    context: {
      environment,
      receivedAt:
        "2026-07-23T22:00:01.000Z",
      correlationId:
        CORRELATION_ID,
      causationId: null,
    },
  };
}

describe(
  "bootstrapRewardProviderRegistry",
  () => {
    it("registers the passive synthetic adapter in test environment", async () => {
      const bootstrap =
        bootstrapRewardProviderRegistry({
          environment: "test",
        });

      expect(
        bootstrap.environment,
      ).toBe("test");

      expect(
        bootstrap.registeredAdapters,
      ).toEqual([
        {
          providerCode:
            PASSIVE_TEST_PROVIDER_CODE,
          adapterCode:
            PASSIVE_TEST_ADAPTER_CODE,
          adapterVersion:
            PASSIVE_TEST_ADAPTER_VERSION,
          environment: "test",
          enabled: true,
          synthetic: true,
          passive: true,
        },
      ]);

      const service =
        new RewardProviderPassiveVerificationService(
          bootstrap.registry,
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
          input:
            createInput("test"),
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
            "bootstrap-event-0001",
          correlation_id:
            CORRELATION_ID,
        },
      });
    });

    it("creates an empty live registry", async () => {
      const bootstrap =
        bootstrapRewardProviderRegistry({
          environment: "live",
        });

      expect(
        bootstrap.environment,
      ).toBe("live");

      expect(
        bootstrap.registeredAdapters,
      ).toEqual([]);

      const service =
        new RewardProviderPassiveVerificationService(
          bootstrap.registry,
        );

      const result =
        await service.verify({
          lookup: {
            providerCode:
              PASSIVE_TEST_PROVIDER_CODE,
            environment: "live",
          },
          input:
            createInput("live"),
        });

      expect(result).toMatchObject({
        verified: false,
        error_code:
          "REWARD_PROVIDER_NOT_REGISTERED",
        provider_code:
          PASSIVE_TEST_PROVIDER_CODE,
        provider_event_id: null,
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

    it("creates isolated registries for separate bootstrap calls", () => {
      const first =
        bootstrapRewardProviderRegistry({
          environment: "test",
        });

      const second =
        bootstrapRewardProviderRegistry({
          environment: "test",
        });

      expect(
        first.registry,
      ).not.toBe(
        second.registry,
      );

      expect(
        first.registeredAdapters,
      ).not.toBe(
        second.registeredAdapters,
      );

      expect(
        first.registeredAdapters,
      ).toEqual(
        second.registeredAdapters,
      );
    });

    it("returns a frozen bootstrap result and manifest", () => {
      const bootstrap =
        bootstrapRewardProviderRegistry({
          environment: "test",
        });

      expect(
        Object.isFrozen(bootstrap),
      ).toBe(true);

      expect(
        Object.isFrozen(
          bootstrap.registeredAdapters,
        ),
      ).toBe(true);

      expect(
        Object.isFrozen(
          bootstrap.registeredAdapters[0],
        ),
      ).toBe(true);
    });


    it("builds registrations from the canonical resolution policy", () => {
      const bootstrap =
        bootstrapRewardProviderRegistry({
          environment: "test",
        });

      expect(
        bootstrap.registeredAdapters,
      ).toEqual(
        resolveRewardProviderPolicy(
          "test",
        ).map(
          (descriptor) => ({
            providerCode:
              descriptor.providerCode,
            adapterCode:
              descriptor.adapterCode,
            adapterVersion:
              descriptor.adapterVersion,
            environment:
              descriptor.environment,
            enabled: true,
            synthetic:
              descriptor.synthetic,
            passive:
              descriptor.passive,
          }),
        ),
      );
    });
    it("does not register synthetic adapters in live environment", () => {
      const liveBootstrap =
        bootstrapRewardProviderRegistry({
          environment: "live",
        });

      expect(
        liveBootstrap.registeredAdapters.some(
          (descriptor) =>
            descriptor.synthetic,
        ),
      ).toBe(false);
    });
  },
);