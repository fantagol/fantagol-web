import type {
  CreateLiveRuntimeWorkflowInput,
  LiveRuntimeWorkflowStepDefinition,
} from "./workflow-types";

export type LiveRuntimeWorkflowDefinition =
  CreateLiveRuntimeWorkflowInput;

export type BuildLiveRuntimeWorkflowDefinitionInput = {
  workflowType: string;
  scopeType: CreateLiveRuntimeWorkflowInput["scopeType"];
  scopeId: string;
  idempotencyKey: string;
  steps: LiveRuntimeWorkflowStepDefinition[];
  workflowVersion?: number;
  metadata?: Record<string, unknown>;
  correlationId?: string | null;
  causationId?: string | null;
  triggerJobId?: string | null;
};

export type BuildSingleStepWorkflowDefinitionInput = Omit<
  BuildLiveRuntimeWorkflowDefinitionInput,
  "steps"
> & {
  step: LiveRuntimeWorkflowStepDefinition;
};

export type BuildLinearWorkflowDefinitionInput = Omit<
  BuildLiveRuntimeWorkflowDefinitionInput,
  "steps"
> & {
  steps: Array<Omit<LiveRuntimeWorkflowStepDefinition, "dependsOn">>;
};

export class LiveRuntimeWorkflowDefinitionError extends Error {
  readonly code = "LIVE_RUNTIME_INVALID_WORKFLOW_DEFINITION";
  readonly details: Record<string, unknown>;

  constructor(message: string, details: Record<string, unknown> = {}) {
    super(message);
    this.name = "LiveRuntimeWorkflowDefinitionError";
    this.details = details;
  }
}

function requireNonEmptyString(value: string, field: string): string {
  const normalized = value.trim();

  if (!normalized) {
    throw new LiveRuntimeWorkflowDefinitionError(
      `${field} must be a non-empty string`,
      { field, value },
    );
  }

  return normalized;
}

function cloneJsonObject(
  value: Record<string, unknown> | undefined,
): Record<string, unknown> {
  return value ? { ...value } : {};
}

function normalizeStep(
  step: LiveRuntimeWorkflowStepDefinition,
  index: number,
): LiveRuntimeWorkflowStepDefinition {
  const stepKey = requireNonEmptyString(step.stepKey, `steps[${index}].stepKey`);
  const dependsOn = [...new Set(step.dependsOn ?? [])].map((dependency) =>
    requireNonEmptyString(dependency, `steps[${index}].dependsOn`),
  );

  if (dependsOn.includes(stepKey)) {
    throw new LiveRuntimeWorkflowDefinitionError(
      "A workflow step cannot depend on itself",
      { stepKey },
    );
  }

  if (step.stepOrder !== undefined && step.stepOrder < 0) {
    throw new LiveRuntimeWorkflowDefinitionError(
      "stepOrder must be greater than or equal to zero",
      { stepKey, stepOrder: step.stepOrder },
    );
  }

  if (step.priority !== undefined && step.priority < 0) {
    throw new LiveRuntimeWorkflowDefinitionError(
      "priority must be greater than or equal to zero",
      { stepKey, priority: step.priority },
    );
  }

  if (step.maxAttempts !== undefined && step.maxAttempts <= 0) {
    throw new LiveRuntimeWorkflowDefinitionError(
      "maxAttempts must be greater than zero",
      { stepKey, maxAttempts: step.maxAttempts },
    );
  }

  if (step.scheduledAt !== undefined) {
    const scheduledAt = new Date(step.scheduledAt);

    if (Number.isNaN(scheduledAt.getTime())) {
      throw new LiveRuntimeWorkflowDefinitionError(
        "scheduledAt must be a valid ISO date",
        { stepKey, scheduledAt: step.scheduledAt },
      );
    }
  }

  return {
    ...step,
    stepKey,
    dependsOn,
    payload: cloneJsonObject(step.payload),
  };
}

function assertDependenciesExist(
  steps: LiveRuntimeWorkflowStepDefinition[],
): void {
  const stepKeys = new Set(steps.map((step) => step.stepKey));

  for (const step of steps) {
    for (const dependency of step.dependsOn ?? []) {
      if (!stepKeys.has(dependency)) {
        throw new LiveRuntimeWorkflowDefinitionError(
          "Workflow dependency does not reference a defined step",
          { stepKey: step.stepKey, dependency },
        );
      }
    }
  }
}

function assertAcyclic(steps: LiveRuntimeWorkflowStepDefinition[]): void {
  const dependencies = new Map(
    steps.map((step) => [step.stepKey, step.dependsOn ?? []] as const),
  );
  const visiting = new Set<string>();
  const visited = new Set<string>();

  function visit(stepKey: string): void {
    if (visited.has(stepKey)) {
      return;
    }

    if (visiting.has(stepKey)) {
      throw new LiveRuntimeWorkflowDefinitionError(
        "Workflow dependencies must form an acyclic graph",
        { stepKey },
      );
    }

    visiting.add(stepKey);

    for (const dependency of dependencies.get(stepKey) ?? []) {
      visit(dependency);
    }

    visiting.delete(stepKey);
    visited.add(stepKey);
  }

  for (const step of steps) {
    visit(step.stepKey);
  }
}

export function buildLiveRuntimeWorkflowDefinition(
  input: BuildLiveRuntimeWorkflowDefinitionInput,
): LiveRuntimeWorkflowDefinition {
  const workflowType = requireNonEmptyString(
    input.workflowType,
    "workflowType",
  );
  const scopeId = requireNonEmptyString(input.scopeId, "scopeId");
  const idempotencyKey = requireNonEmptyString(
    input.idempotencyKey,
    "idempotencyKey",
  );

  if (input.workflowVersion !== undefined && input.workflowVersion <= 0) {
    throw new LiveRuntimeWorkflowDefinitionError(
      "workflowVersion must be greater than zero",
      { workflowVersion: input.workflowVersion },
    );
  }

  if (input.steps.length === 0) {
    throw new LiveRuntimeWorkflowDefinitionError(
      "A workflow must contain at least one step",
    );
  }

  const steps = input.steps.map(normalizeStep);
  const uniqueStepKeys = new Set(steps.map((step) => step.stepKey));

  if (uniqueStepKeys.size !== steps.length) {
    throw new LiveRuntimeWorkflowDefinitionError(
      "Workflow step keys must be unique",
      { stepKeys: steps.map((step) => step.stepKey) },
    );
  }

  assertDependenciesExist(steps);
  assertAcyclic(steps);

  return {
    workflowType,
    scopeType: input.scopeType,
    scopeId,
    idempotencyKey,
    steps,
    workflowVersion: input.workflowVersion ?? 1,
    metadata: cloneJsonObject(input.metadata),
    correlationId: input.correlationId ?? null,
    causationId: input.causationId ?? null,
    triggerJobId: input.triggerJobId ?? null,
  };
}

export function buildSingleStepWorkflowDefinition(
  input: BuildSingleStepWorkflowDefinitionInput,
): LiveRuntimeWorkflowDefinition {
  return buildLiveRuntimeWorkflowDefinition({
    ...input,
    steps: [{ ...input.step, dependsOn: [] }],
  });
}

export function buildLinearWorkflowDefinition(
  input: BuildLinearWorkflowDefinitionInput,
): LiveRuntimeWorkflowDefinition {
  return buildLiveRuntimeWorkflowDefinition({
    ...input,
    steps: input.steps.map((step, index) => ({
      ...step,
      dependsOn: index === 0 ? [] : [input.steps[index - 1].stepKey],
    })),
  });
}
