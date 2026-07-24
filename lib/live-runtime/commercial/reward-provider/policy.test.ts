import {
  describe,
  expect,
  it,
} from "vitest";

import {
  PASSIVE_TEST_ADAPTER_CODE,
  PASSIVE_TEST_ADAPTER_VERSION,
  PASSIVE_TEST_PROVIDER_CODE,
  PassiveTestRewardProviderAdapter,
} from "./passive-test-adapter";
import {
  REWARD_PROVIDER_POLICY,
  resolveRewardProviderPolicy,
} from "./policy";

describe(
  "reward provider resolution policy",
  () => {
    it("exposes an immutable canonical policy", () => {
      expect(
        Object.isFrozen(
          REWARD_PROVIDER_POLICY,
        ),
      ).toBe(true);

      expect(
        REWARD_PROVIDER_POLICY,
      ).toEqual([
        {
          providerCode:
            PASSIVE_TEST_PROVIDER_CODE,
          adapterCode:
            PASSIVE_TEST_ADAPTER_CODE,
          adapterVersion:
            PASSIVE_TEST_ADAPTER_VERSION,
          allowedEnvironments:
            ["test"],
          priority: 10,
          enabled: true,
          synthetic: true,
          passive: true,
          status: "AVAILABLE",
        },
      ]);

      expect(
        Object.isFrozen(
          REWARD_PROVIDER_POLICY[0],
        ),
      ).toBe(true);

      expect(
        Object.isFrozen(
          REWARD_PROVIDER_POLICY[0]
            .allowedEnvironments,
        ),
      ).toBe(true);
    });

    it("resolves the passive adapter only for test environment", () => {
      const resolved =
        resolveRewardProviderPolicy(
          "test",
        );

      expect(
        resolved,
      ).toHaveLength(1);

      expect(
        resolved[0],
      ).toMatchObject({
        providerCode:
          PASSIVE_TEST_PROVIDER_CODE,
        adapterCode:
          PASSIVE_TEST_ADAPTER_CODE,
        adapterVersion:
          PASSIVE_TEST_ADAPTER_VERSION,
        environment: "test",
        priority: 10,
        enabled: true,
        synthetic: true,
        passive: true,
        status: "AVAILABLE",
      });

      expect(
        resolved[0].createAdapter(),
      ).toBeInstanceOf(
        PassiveTestRewardProviderAdapter,
      );
    });

    it("resolves no adapters for live environment", () => {
      expect(
        resolveRewardProviderPolicy(
          "live",
        ),
      ).toEqual([]);
    });

    it("returns immutable and isolated resolution arrays", () => {
      const first =
        resolveRewardProviderPolicy(
          "test",
        );

      const second =
        resolveRewardProviderPolicy(
          "test",
        );

      expect(
        first,
      ).not.toBe(
        second,
      );

      expect(
        first,
      ).toEqual(
        second,
      );

      expect(
        Object.isFrozen(first),
      ).toBe(true);

      expect(
        Object.isFrozen(first[0]),
      ).toBe(true);
    });

    it("does not expose adapter factories through the public catalog", () => {
      expect(
        "createAdapter" in
          REWARD_PROVIDER_POLICY[0],
      ).toBe(false);
    });

    it("uses deterministic policy ordering", () => {
      const priorities =
        REWARD_PROVIDER_POLICY.map(
          (descriptor) =>
            descriptor.priority,
        );

      expect(
        priorities,
      ).toEqual(
        [...priorities].sort(
          (left, right) =>
            left - right,
        ),
      );
    });
  },
);