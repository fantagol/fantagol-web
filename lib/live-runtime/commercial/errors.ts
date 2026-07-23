import type {
  CommercialRuntimeRpcFailure,
  CommercialRuntimeRpcName,
} from "./types";

export const COMMERCIAL_RUNTIME_ERROR_CODES = {
  PURCHASE_NOT_FOUND: "COMMERCIAL_PURCHASE_NOT_FOUND",
  AUTHORIZATION_NOT_FOUND:
    "COMMERCIAL_PURCHASE_AUTHORIZATION_NOT_FOUND",
  AUTHORIZATION_ALREADY_DECIDED:
    "COMMERCIAL_PURCHASE_AUTHORIZATION_ALREADY_DECIDED",
  AUTHORIZATION_DECISION_INVALID:
    "COMMERCIAL_PURCHASE_AUTHORIZATION_DECISION_INVALID",
  AUTHORIZATION_IDEMPOTENCY_CONFLICT:
    "COMMERCIAL_PURCHASE_AUTHORIZATION_IDEMPOTENCY_CONFLICT",
  RUNTIME_POLICY_NOT_FOUND:
    "COMMERCIAL_PURCHASE_RUNTIME_POLICY_NOT_FOUND",
  RUNTIME_POLICY_NOT_APPROVED:
    "COMMERCIAL_PURCHASE_RUNTIME_POLICY_NOT_APPROVED",
  RUNTIME_EVENT_ARGUMENT_INVALID:
    "COMMERCIAL_PURCHASE_RUNTIME_EVENT_ARGUMENT_INVALID",
  PURCHASE_ALREADY_TERMINAL:
    "PURCHASE_ALREADY_TERMINAL",
} as const;

export type CommercialRuntimeErrorCode =
  (typeof COMMERCIAL_RUNTIME_ERROR_CODES)[keyof typeof COMMERCIAL_RUNTIME_ERROR_CODES];

export class CommercialRuntimeError extends Error {
  readonly rpcName: CommercialRuntimeRpcName;
  readonly code: string | null;
  readonly details: string | null;
  readonly hint: string | null;
  readonly causeValue: unknown;

  constructor(
    failure: CommercialRuntimeRpcFailure,
    causeValue?: unknown,
  ) {
    super(failure.message);

    this.name = "CommercialRuntimeError";
    this.rpcName = failure.rpcName;
    this.code = failure.code;
    this.details = failure.details;
    this.hint = failure.hint;
    this.causeValue = causeValue;
  }
}

export function isCommercialRuntimeError(
  value: unknown,
): value is CommercialRuntimeError {
  return value instanceof CommercialRuntimeError;
}

export function hasCommercialRuntimeErrorCode(
  value: unknown,
  code: CommercialRuntimeErrorCode,
): boolean {
  return (
    value instanceof CommercialRuntimeError &&
    value.code === code
  );
}
