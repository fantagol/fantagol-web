import { describe, expect, it } from "vitest";

import {
  COMMERCIAL_RUNTIME_ERROR_CODES,
  CommercialRuntimeError,
  hasCommercialRuntimeErrorCode,
  isCommercialRuntimeError,
} from "./errors";

const RPC_NAME =
  "get_commercial_purchase_runtime_internal";

const FAILURE = {
  rpcName: RPC_NAME,
  code: "P0001",
  message: "Commercial runtime failed.",
  details: "Runtime state is inconsistent.",
  hint: "Reconcile the purchase runtime.",
} as const;

describe("COMMERCIAL_RUNTIME_ERROR_CODES", () => {
  it("exposes the complete stable commercial error code contract", () => {
    expect(COMMERCIAL_RUNTIME_ERROR_CODES).toEqual({
      PURCHASE_NOT_FOUND:
        "COMMERCIAL_PURCHASE_NOT_FOUND",
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
    });
  });

  it("contains nine unique public error codes", () => {
    const codes = Object.values(
      COMMERCIAL_RUNTIME_ERROR_CODES,
    );

    expect(codes).toHaveLength(9);
    expect(new Set(codes).size).toBe(9);
  });
});

describe("CommercialRuntimeError", () => {
  it("is an Error and a CommercialRuntimeError instance", () => {
    const error = new CommercialRuntimeError(
      FAILURE,
    );

    expect(error).toBeInstanceOf(Error);
    expect(error).toBeInstanceOf(
      CommercialRuntimeError,
    );
  });

  it("sets the deterministic error name", () => {
    const error = new CommercialRuntimeError(
      FAILURE,
    );

    expect(error.name).toBe(
      "CommercialRuntimeError",
    );
  });

  it("uses the failure message as the Error message", () => {
    const error = new CommercialRuntimeError(
      FAILURE,
    );

    expect(error.message).toBe(
      "Commercial runtime failed.",
    );
  });

  it("copies the complete RPC failure contract", () => {
    const error = new CommercialRuntimeError(
      FAILURE,
    );

    expect(error).toMatchObject({
      rpcName: RPC_NAME,
      code: "P0001",
      details: "Runtime state is inconsistent.",
      hint: "Reconcile the purchase runtime.",
    });
  });

  it("preserves the supplied causeValue by identity", () => {
    const causeValue = {
      source: "postgrest",
      retryable: false,
    };

    const error = new CommercialRuntimeError(
      FAILURE,
      causeValue,
    );

    expect(error.causeValue).toBe(causeValue);
  });

  it("leaves causeValue undefined when it is omitted", () => {
    const error = new CommercialRuntimeError(
      FAILURE,
    );

    expect(error.causeValue).toBeUndefined();
  });

  it("preserves nullable failure fields", () => {
    const error = new CommercialRuntimeError({
      rpcName: RPC_NAME,
      code: null,
      message: "Runtime failure.",
      details: null,
      hint: null,
    });

    expect(error).toMatchObject({
      code: null,
      details: null,
      hint: null,
    });
  });
});

describe("isCommercialRuntimeError", () => {
  it("returns true for CommercialRuntimeError instances", () => {
    const error = new CommercialRuntimeError(
      FAILURE,
    );

    expect(
      isCommercialRuntimeError(error),
    ).toBe(true);
  });

  it.each([
    null,
    undefined,
    "CommercialRuntimeError",
    new Error("Generic error."),
    {
      name: "CommercialRuntimeError",
      message: "Structurally similar object.",
      rpcName: RPC_NAME,
      code: "P0001",
      details: null,
      hint: null,
    },
  ])(
    "returns false for non-commercial values",
    (value) => {
      expect(
        isCommercialRuntimeError(value),
      ).toBe(false);
    },
  );
});

describe("hasCommercialRuntimeErrorCode", () => {
  it("returns true when the commercial error code matches", () => {
    const code =
      COMMERCIAL_RUNTIME_ERROR_CODES
        .PURCHASE_NOT_FOUND;

    const error = new CommercialRuntimeError({
      ...FAILURE,
      code,
    });

    expect(
      hasCommercialRuntimeErrorCode(
        error,
        code,
      ),
    ).toBe(true);
  });

  it("returns false when the commercial error code differs", () => {
    const error = new CommercialRuntimeError({
      ...FAILURE,
      code:
        COMMERCIAL_RUNTIME_ERROR_CODES
          .PURCHASE_NOT_FOUND,
    });

    expect(
      hasCommercialRuntimeErrorCode(
        error,
        COMMERCIAL_RUNTIME_ERROR_CODES
          .AUTHORIZATION_NOT_FOUND,
      ),
    ).toBe(false);
  });

  it("returns false when the error code is null", () => {
    const error = new CommercialRuntimeError({
      ...FAILURE,
      code: null,
    });

    expect(
      hasCommercialRuntimeErrorCode(
        error,
        COMMERCIAL_RUNTIME_ERROR_CODES
          .PURCHASE_NOT_FOUND,
      ),
    ).toBe(false);
  });

  it("returns false for structurally similar non-instances", () => {
    const value = {
      name: "CommercialRuntimeError",
      message: "Commercial runtime failed.",
      rpcName: RPC_NAME,
      code:
        COMMERCIAL_RUNTIME_ERROR_CODES
          .PURCHASE_NOT_FOUND,
      details: null,
      hint: null,
    };

    expect(
      hasCommercialRuntimeErrorCode(
        value,
        COMMERCIAL_RUNTIME_ERROR_CODES
          .PURCHASE_NOT_FOUND,
      ),
    ).toBe(false);
  });
});
