import {
  PASSIVE_TEST_ADAPTER_CODE,
  PASSIVE_TEST_ADAPTER_VERSION,
  PASSIVE_TEST_PROVIDER_CODE,
  PassiveTestRewardProviderAdapter,
} from "./passive-test-adapter";
import type {
  RewardProviderBootstrapEnvironment,
} from "./bootstrap";
import type {
  RewardProviderAdapter,
} from "./types";

export type RewardProviderPolicyStatus =
  | "DECLARED"
  | "AVAILABLE";

export interface RewardProviderPolicyDescriptor {
  readonly providerCode: string;
  readonly adapterCode: string;
  readonly adapterVersion: number;
  readonly allowedEnvironments:
    ReadonlyArray<
      RewardProviderBootstrapEnvironment
    >;
  readonly priority: number;
  readonly enabled: boolean;
  readonly synthetic: boolean;
  readonly passive: true;
  readonly status:
    RewardProviderPolicyStatus;
}

export interface RewardProviderResolvedPolicyDescriptor
  extends RewardProviderPolicyDescriptor {
  readonly environment:
    RewardProviderBootstrapEnvironment;
  readonly createAdapter:
    () => RewardProviderAdapter;
}

interface RewardProviderPolicyDefinition
  extends RewardProviderPolicyDescriptor {
  readonly createAdapter?:
    () => RewardProviderAdapter;
}

function freezeEnvironmentList(
  environments:
    ReadonlyArray<
      RewardProviderBootstrapEnvironment
    >,
): ReadonlyArray<
  RewardProviderBootstrapEnvironment
> {
  return Object.freeze([
    ...environments,
  ]);
}

function freezePolicyDefinition(
  definition:
    RewardProviderPolicyDefinition,
): RewardProviderPolicyDefinition {
  return Object.freeze({
    ...definition,
    allowedEnvironments:
      freezeEnvironmentList(
        definition.allowedEnvironments,
      ),
  });
}

const POLICY_DEFINITIONS:
  ReadonlyArray<
    RewardProviderPolicyDefinition
  > = Object.freeze([
    freezePolicyDefinition({
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
      createAdapter:
        () =>
          new PassiveTestRewardProviderAdapter(),
    }),
  ]);

function comparePolicyDescriptors(
  left:
    RewardProviderPolicyDescriptor,
  right:
    RewardProviderPolicyDescriptor,
): number {
  if (left.priority !== right.priority) {
    return left.priority - right.priority;
  }

  const providerComparison =
    left.providerCode.localeCompare(
      right.providerCode,
    );

  if (providerComparison !== 0) {
    return providerComparison;
  }

  const adapterComparison =
    left.adapterCode.localeCompare(
      right.adapterCode,
    );

  if (adapterComparison !== 0) {
    return adapterComparison;
  }

  return (
    left.adapterVersion -
    right.adapterVersion
  );
}

function toPublicDescriptor(
  definition:
    RewardProviderPolicyDefinition,
): RewardProviderPolicyDescriptor {
  return Object.freeze({
    providerCode:
      definition.providerCode,
    adapterCode:
      definition.adapterCode,
    adapterVersion:
      definition.adapterVersion,
    allowedEnvironments:
      definition.allowedEnvironments,
    priority:
      definition.priority,
    enabled:
      definition.enabled,
    synthetic:
      definition.synthetic,
    passive:
      definition.passive,
    status:
      definition.status,
  });
}

export const REWARD_PROVIDER_POLICY:
  ReadonlyArray<
    RewardProviderPolicyDescriptor
  > = Object.freeze(
    [...POLICY_DEFINITIONS]
      .sort(
        comparePolicyDescriptors,
      )
      .map(
        toPublicDescriptor,
      ),
  );

export function resolveRewardProviderPolicy(
  environment:
    RewardProviderBootstrapEnvironment,
): ReadonlyArray<
  RewardProviderResolvedPolicyDescriptor
> {
  const resolved =
    POLICY_DEFINITIONS
      .filter(
        (definition) =>
          definition.enabled &&
          definition.status ===
            "AVAILABLE" &&
          definition.allowedEnvironments.includes(
            environment,
          ) &&
          definition.createAdapter !==
            undefined,
      )
      .sort(
        comparePolicyDescriptors,
      )
      .map(
        (
          definition,
        ): RewardProviderResolvedPolicyDescriptor => {
          const createAdapter =
            definition.createAdapter;

          if (!createAdapter) {
            throw new Error(
              "Available reward provider policy is missing its adapter factory.",
            );
          }

          return Object.freeze({
            ...toPublicDescriptor(
              definition,
            ),
            environment,
            createAdapter,
          });
        },
      );

  return Object.freeze(
    resolved,
  );
}