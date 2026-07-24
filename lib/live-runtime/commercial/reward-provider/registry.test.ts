import {
  describe,
  expect,
  it,
  vi,
} from "vitest";

import type {
  RewardProviderAdapter,
  RewardProviderAdapterInput,
} from "./types";
import {
  RewardProviderAdapterRegistry,
  RewardProviderAdapterRegistryError,
} from "./registry";

function createAdapter(
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
    verifyAndNormalize: vi.fn(
      async (
        input:
          RewardProviderAdapterInput,
      ) => {
        void input;

        return {
        verified: false as const,
        error_code:
          "REWARD_PROVIDER_VERIFICATION_FAILED" as const,
        error_message:
          "Passive test adapter.",
        provider_code:
          "REWARDED_AD_TEST",
        provider_event_id: null,
        correlation_id:
          "11111111-1111-4111-8111-111111111111",
          metadata: {},
        };
      },
    ),
  };
}

describe(
  "RewardProviderAdapterRegistry",
  () => {
    it("registers and resolves an enabled adapter", () => {
      const registry =
        new RewardProviderAdapterRegistry();

      const adapter = createAdapter();

      registry.register({
        providerCode:
          "REWARDED_AD_TEST",
        adapterCode:
          "REWARDED_AD_TEST_ADAPTER",
        adapterVersion: 1,
        environment: "test",
        enabled: true,
        adapter,
      });

      expect(
        registry.resolve({
          providerCode:
            "REWARDED_AD_TEST",
          adapterCode:
            "REWARDED_AD_TEST_ADAPTER",
          adapterVersion: 1,
          environment: "test",
        }),
      ).toBe(adapter);

      expect(registry.size()).toBe(1);
    });

    it("supports distinct environments", () => {
      const registry =
        new RewardProviderAdapterRegistry();

      const testAdapter =
        createAdapter();

      const liveAdapter =
        createAdapter();

      registry.register({
        providerCode:
          "REWARDED_AD_TEST",
        adapterCode:
          "REWARDED_AD_TEST_ADAPTER",
        adapterVersion: 1,
        environment: "test",
        enabled: true,
        adapter: testAdapter,
      });

      registry.register({
        providerCode:
          "REWARDED_AD_TEST",
        adapterCode:
          "REWARDED_AD_TEST_ADAPTER",
        adapterVersion: 1,
        environment: "live",
        enabled: true,
        adapter: liveAdapter,
      });

      expect(
        registry.resolve({
          providerCode:
            "REWARDED_AD_TEST",
          environment: "test",
        }),
      ).toBe(testAdapter);

      expect(
        registry.resolve({
          providerCode:
            "REWARDED_AD_TEST",
          environment: "live",
        }),
      ).toBe(liveAdapter);
    });

    it("rejects duplicate registrations", () => {
      const registry =
        new RewardProviderAdapterRegistry();

      const registration = {
        providerCode:
          "REWARDED_AD_TEST",
        adapterCode:
          "REWARDED_AD_TEST_ADAPTER",
        adapterVersion: 1,
        environment: "test" as const,
        enabled: true,
        adapter: createAdapter(),
      };

      registry.register(registration);

      expect(() =>
        registry.register(registration),
      ).toThrowError(
        expect.objectContaining({
          code:
            "REWARD_PROVIDER_ADAPTER_ALREADY_REGISTERED",
        }),
      );
    });

    it("rejects registration identity mismatches", () => {
      const registry =
        new RewardProviderAdapterRegistry();

      expect(() =>
        registry.register({
          providerCode:
            "REWARDED_AD_TEST",
          adapterCode:
            "REWARDED_AD_TEST_ADAPTER",
          adapterVersion: 2,
          environment: "test",
          enabled: true,
          adapter: createAdapter({
            adapterVersion: 1,
          }),
        }),
      ).toThrowError(
        expect.objectContaining({
          code:
            "REWARD_PROVIDER_ADAPTER_IDENTITY_MISMATCH",
        }),
      );
    });

    it("rejects disabled adapters", () => {
      const registry =
        new RewardProviderAdapterRegistry();

      registry.register({
        providerCode:
          "REWARDED_AD_TEST",
        adapterCode:
          "REWARDED_AD_TEST_ADAPTER",
        adapterVersion: 1,
        environment: "test",
        enabled: false,
        adapter: createAdapter(),
      });

      expect(() =>
        registry.resolve({
          providerCode:
            "REWARDED_AD_TEST",
          environment: "test",
        }),
      ).toThrowError(
        expect.objectContaining({
          code:
            "REWARD_PROVIDER_ADAPTER_DISABLED",
        }),
      );
    });

    it("rejects unknown adapters", () => {
      const registry =
        new RewardProviderAdapterRegistry();

      expect(() =>
        registry.resolve({
          providerCode:
            "REWARDED_AD_TEST",
          environment: "test",
        }),
      ).toThrowError(
        expect.objectContaining({
          code:
            "REWARD_PROVIDER_ADAPTER_NOT_FOUND",
        }),
      );
    });

    it("rejects ambiguous selections", () => {
      const registry =
        new RewardProviderAdapterRegistry();

      registry.register({
        providerCode:
          "REWARDED_AD_TEST",
        adapterCode:
          "REWARDED_AD_TEST_ADAPTER",
        adapterVersion: 1,
        environment: "test",
        enabled: true,
        adapter: createAdapter(),
      });

      registry.register({
        providerCode:
          "REWARDED_AD_TEST",
        adapterCode:
          "REWARDED_AD_TEST_ADAPTER_V2",
        adapterVersion: 2,
        environment: "test",
        enabled: true,
        adapter: createAdapter({
          adapterCode:
            "REWARDED_AD_TEST_ADAPTER_V2",
          adapterVersion: 2,
        }),
      });

      expect(() =>
        registry.resolve({
          providerCode:
            "REWARDED_AD_TEST",
          environment: "test",
        }),
      ).toThrowError(
        expect.objectContaining({
          code:
            "REWARD_PROVIDER_ADAPTER_SELECTION_AMBIGUOUS",
        }),
      );
    });

    it("resolves an explicit version without ambiguity", () => {
      const registry =
        new RewardProviderAdapterRegistry();

      const firstAdapter =
        createAdapter();

      const secondAdapter =
        createAdapter({
          adapterCode:
            "REWARDED_AD_TEST_ADAPTER_V2",
          adapterVersion: 2,
        });

      registry.register({
        providerCode:
          "REWARDED_AD_TEST",
        adapterCode:
          "REWARDED_AD_TEST_ADAPTER",
        adapterVersion: 1,
        environment: "test",
        enabled: true,
        adapter: firstAdapter,
      });

      registry.register({
        providerCode:
          "REWARDED_AD_TEST",
        adapterCode:
          "REWARDED_AD_TEST_ADAPTER_V2",
        adapterVersion: 2,
        environment: "test",
        enabled: true,
        adapter: secondAdapter,
      });

      expect(
        registry.resolve({
          providerCode:
            "REWARDED_AD_TEST",
          adapterCode:
            "REWARDED_AD_TEST_ADAPTER_V2",
          adapterVersion: 2,
          environment: "test",
        }),
      ).toBe(secondAdapter);
    });

    it("reports exact registration presence", () => {
      const registry =
        new RewardProviderAdapterRegistry();

      registry.register({
        providerCode:
          "REWARDED_AD_TEST",
        adapterCode:
          "REWARDED_AD_TEST_ADAPTER",
        adapterVersion: 1,
        environment: "test",
        enabled: true,
        adapter: createAdapter(),
      });

      expect(
        registry.has({
          providerCode:
            "REWARDED_AD_TEST",
          adapterCode:
            "REWARDED_AD_TEST_ADAPTER",
          adapterVersion: 1,
          environment: "test",
        }),
      ).toBe(true);

      expect(
        registry.has({
          providerCode:
            "REWARDED_AD_TEST",
          adapterCode:
            "REWARDED_AD_TEST_ADAPTER",
          adapterVersion: 1,
          environment: "live",
        }),
      ).toBe(false);
    });

    it("returns immutable registration snapshots", () => {
      const registry =
        new RewardProviderAdapterRegistry();

      registry.register({
        providerCode:
          "REWARDED_AD_TEST",
        adapterCode:
          "REWARDED_AD_TEST_ADAPTER",
        adapterVersion: 1,
        environment: "test",
        enabled: true,
        adapter: createAdapter(),
      });

      const registrations =
        registry.listRegistrations();

      expect(
        Object.isFrozen(
          registrations[0],
        ),
      ).toBe(true);
    });

    it("uses stable registry error instances", () => {
      const error =
        new RewardProviderAdapterRegistryError(
          "REWARD_PROVIDER_ADAPTER_NOT_FOUND",
          "Missing adapter.",
        );

      expect(error).toBeInstanceOf(Error);
      expect(error.name).toBe(
        "RewardProviderAdapterRegistryError",
      );
      expect(error.code).toBe(
        "REWARD_PROVIDER_ADAPTER_NOT_FOUND",
      );
    });
  },
);