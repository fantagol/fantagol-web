import {
  resolveRewardProviderPolicy,
} from "./policy";
import {
  RewardProviderAdapterRegistry,
} from "./registry";
import type {
  RewardProviderAdapterInput,
} from "./types";

export type RewardProviderBootstrapEnvironment =
  RewardProviderAdapterInput[
    "context"
  ]["environment"];

export interface RewardProviderBootstrapOptions {
  readonly environment:
    RewardProviderBootstrapEnvironment;
}

export interface RewardProviderRegisteredAdapterDescriptor {
  readonly providerCode: string;
  readonly adapterCode: string;
  readonly adapterVersion: number;
  readonly environment:
    RewardProviderBootstrapEnvironment;
  readonly enabled: true;
  readonly synthetic: boolean;
  readonly passive: true;
}

export interface RewardProviderBootstrapResult {
  readonly environment:
    RewardProviderBootstrapEnvironment;
  readonly registry:
    RewardProviderAdapterRegistry;
  readonly registeredAdapters:
    ReadonlyArray<
      RewardProviderRegisteredAdapterDescriptor
    >;
}

function freezeDescriptor(
  descriptor:
    RewardProviderRegisteredAdapterDescriptor,
): RewardProviderRegisteredAdapterDescriptor {
  return Object.freeze({
    ...descriptor,
  });
}

function createFrozenManifest(
  descriptors:
    ReadonlyArray<
      RewardProviderRegisteredAdapterDescriptor
    >,
): ReadonlyArray<
  RewardProviderRegisteredAdapterDescriptor
> {
  return Object.freeze(
    descriptors.map(
      freezeDescriptor,
    ),
  );
}

export function bootstrapRewardProviderRegistry(
  options:
    RewardProviderBootstrapOptions,
): RewardProviderBootstrapResult {
  const registry =
    new RewardProviderAdapterRegistry();

  const registeredAdapters:
    RewardProviderRegisteredAdapterDescriptor[] =
      [];

  const resolvedPolicy =
    resolveRewardProviderPolicy(
      options.environment,
    );

  for (
    const descriptor of
    resolvedPolicy
  ) {
    const adapter =
      descriptor.createAdapter();

    registry.register({
      providerCode:
        descriptor.providerCode,
      adapterCode:
        descriptor.adapterCode,
      adapterVersion:
        descriptor.adapterVersion,
      environment:
        descriptor.environment,
      enabled: true,
      adapter,
    });

    registeredAdapters.push({
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
    });
  }

  return Object.freeze({
    environment:
      options.environment,
    registry,
    registeredAdapters:
      createFrozenManifest(
        registeredAdapters,
      ),
  });
}