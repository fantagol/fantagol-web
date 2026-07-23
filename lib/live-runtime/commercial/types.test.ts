import { describe, expect, expectTypeOf, it } from "vitest";

import type {
  CommercialRuntimeEvent,
  CommercialRuntimeRpcFailure,
  CommercialRuntimeRpcName,
  CommercialRuntimeRpcResult,
} from "./types";

const COMMERCIAL_RUNTIME_RPC_NAMES = [
  "evaluate_commercial_purchase_runtime_readiness_internal",
  "request_commercial_purchase_authorization_internal",
  "decide_commercial_purchase_authorization_internal",
  "get_commercial_purchase_runtime_internal",
  "get_commercial_purchase_runtime_timeline_internal",
  "get_my_commercial_wallet_rpc",
] as const satisfies readonly CommercialRuntimeRpcName[];

describe("CommercialRuntimeRpcName", () => {
  it("contains the complete stable commercial RPC surface", () => {
    expect(COMMERCIAL_RUNTIME_RPC_NAMES).toEqual([
      "evaluate_commercial_purchase_runtime_readiness_internal",
      "request_commercial_purchase_authorization_internal",
      "decide_commercial_purchase_authorization_internal",
      "get_commercial_purchase_runtime_internal",
      "get_commercial_purchase_runtime_timeline_internal",
      "get_my_commercial_wallet_rpc",
    ]);
  });

  it("contains six unique RPC names", () => {
    expect(COMMERCIAL_RUNTIME_RPC_NAMES).toHaveLength(6);
    expect(
      new Set(COMMERCIAL_RUNTIME_RPC_NAMES).size,
    ).toBe(6);
  });

  it("matches the exported RPC name union", () => {
    type ListedRpcName =
      (typeof COMMERCIAL_RUNTIME_RPC_NAMES)[number];

    expectTypeOf<ListedRpcName>().toEqualTypeOf<
      CommercialRuntimeRpcName
    >();
  });

  it("rejects RPC names outside the public union", () => {
    // @ts-expect-error Invalid commercial runtime RPC name.
    const invalidRpcName: CommercialRuntimeRpcName =
      "unknown_commercial_runtime_rpc_internal";

    expect(invalidRpcName).toBe(
      "unknown_commercial_runtime_rpc_internal",
    );
  });
});

describe("CommercialRuntimeRpcFailure", () => {
  it("accepts the complete nullable failure contract", () => {
    const failure = {
      rpcName:
        "get_commercial_purchase_runtime_internal",
      code: null,
      message: "Commercial runtime failed.",
      details: null,
      hint: null,
    } satisfies CommercialRuntimeRpcFailure;

    expect(failure).toEqual({
      rpcName:
        "get_commercial_purchase_runtime_internal",
      code: null,
      message: "Commercial runtime failed.",
      details: null,
      hint: null,
    });
  });

  it("exposes the expected property types", () => {
    expectTypeOf<
      CommercialRuntimeRpcFailure["rpcName"]
    >().toEqualTypeOf<CommercialRuntimeRpcName>();

    expectTypeOf<
      CommercialRuntimeRpcFailure["code"]
    >().toEqualTypeOf<string | null>();

    expectTypeOf<
      CommercialRuntimeRpcFailure["message"]
    >().toEqualTypeOf<string>();

    expectTypeOf<
      CommercialRuntimeRpcFailure["details"]
    >().toEqualTypeOf<string | null>();

    expectTypeOf<
      CommercialRuntimeRpcFailure["hint"]
    >().toEqualTypeOf<string | null>();
  });
});

describe("CommercialRuntimeRpcResult", () => {
  it("preserves the generic data payload type", () => {
    type Payload = {
      purchaseId: string;
      ready: boolean;
    };

    type Result =
      CommercialRuntimeRpcResult<Payload>;

    expectTypeOf<Result["data"]>().toEqualTypeOf<
      Payload
    >();

    expectTypeOf<
      Result["rpcName"]
    >().toEqualTypeOf<CommercialRuntimeRpcName>();
  });

  it("accepts a typed RPC result object", () => {
    const result = {
      data: {
        purchaseId:
          "11111111-1111-4111-8111-111111111111",
        ready: true,
      },
      rpcName:
        "evaluate_commercial_purchase_runtime_readiness_internal",
    } satisfies CommercialRuntimeRpcResult<{
      purchaseId: string;
      ready: boolean;
    }>;

    expect(result.data.ready).toBe(true);
    expect(result.rpcName).toBe(
      "evaluate_commercial_purchase_runtime_readiness_internal",
    );
  });
});

describe("CommercialRuntimeEvent", () => {
  it("accepts the complete canonical event contract", () => {
    const event = {
      id: "event-001",
      purchase_id: "purchase-001",
      policy_id: null,
      authorization_id: "authorization-001",
      attempt_id: null,
      event_type: "authorization_requested",
      previous_state: "pending",
      next_state: "authorization_pending",
      actor: "commercial_runtime",
      reason: null,
      correlation_id: "correlation-001",
      causation_id: null,
      payload: {
        source: "unit-test",
        retryable: false,
      },
      occurred_at: "2026-07-23T15:00:00.000Z",
    } satisfies CommercialRuntimeEvent;

    expect(event.event_type).toBe(
      "authorization_requested",
    );
    expect(event.payload).toEqual({
      source: "unit-test",
      retryable: false,
    });
  });

  it("accepts additional JSON-compatible event fields", () => {
    const event = {
      id: "event-002",
      purchase_id: null,
      policy_id: null,
      authorization_id: null,
      attempt_id: null,
      event_type: "runtime_evaluated",
      previous_state: null,
      next_state: "ready",
      actor: "commercial_runtime",
      reason: "policy_approved",
      correlation_id: "correlation-002",
      causation_id: "event-001",
      payload: {},
      occurred_at: "2026-07-23T15:01:00.000Z",
      sequence_number: 2,
      certified: true,
      note: null,
      tags: ["runtime", "commercial"],
    } satisfies CommercialRuntimeEvent;

    expect(event.sequence_number).toBe(2);
    expect(event.certified).toBe(true);
    expect(event.tags).toEqual([
      "runtime",
      "commercial",
    ]);
  });

  it("exposes nullable identifier and state fields", () => {
    expectTypeOf<
      CommercialRuntimeEvent["purchase_id"]
    >().toEqualTypeOf<string | null>();

    expectTypeOf<
      CommercialRuntimeEvent["policy_id"]
    >().toEqualTypeOf<string | null>();

    expectTypeOf<
      CommercialRuntimeEvent["authorization_id"]
    >().toEqualTypeOf<string | null>();

    expectTypeOf<
      CommercialRuntimeEvent["attempt_id"]
    >().toEqualTypeOf<string | null>();

    expectTypeOf<
      CommercialRuntimeEvent["previous_state"]
    >().toEqualTypeOf<string | null>();

    expectTypeOf<
      CommercialRuntimeEvent["next_state"]
    >().toEqualTypeOf<string | null>();

    expectTypeOf<
      CommercialRuntimeEvent["reason"]
    >().toEqualTypeOf<string | null>();

    expectTypeOf<
      CommercialRuntimeEvent["causation_id"]
    >().toEqualTypeOf<string | null>();
  });

  it("requires the canonical event fields", () => {
    // @ts-expect-error Missing required CommercialRuntimeEvent fields.
    const incompleteEvent: CommercialRuntimeEvent = {
      id: "event-incomplete",
      payload: {},
    };

    expect(incompleteEvent.id).toBe(
      "event-incomplete",
    );
  });

  it("rejects non-JSON-compatible extension fields", () => {
    const invalidExtension = () => "invalid";

    const event = {
      id: "event-invalid-extension",
      purchase_id: null,
      policy_id: null,
      authorization_id: null,
      attempt_id: null,
      event_type: "runtime_evaluated",
      previous_state: null,
      next_state: null,
      actor: "commercial_runtime",
      reason: null,
      correlation_id: "correlation-invalid",
      causation_id: null,
      payload: {},
      occurred_at: "2026-07-23T15:02:00.000Z",
      // @ts-expect-error Functions are not JSON-compatible values.
      invalid_extension: invalidExtension,
    } satisfies CommercialRuntimeEvent;

    expect(typeof event.invalid_extension).toBe(
      "function",
    );
  });
});
