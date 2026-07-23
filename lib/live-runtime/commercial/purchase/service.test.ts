import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  callCommercialRuntimeRpc: vi.fn(),
  normalizeAuthorization: vi.fn(),
  normalizeReadiness: vi.fn(),
  normalizeSnapshot: vi.fn(),
  normalizeTimeline: vi.fn(),
}));

vi.mock("server-only", () => ({}));

vi.mock("../rpc", () => ({
  callCommercialRuntimeRpc:
    mocks.callCommercialRuntimeRpc,
}));

vi.mock("./validation", () => ({
  normalizeCommercialPurchaseAuthorizationResult:
    mocks.normalizeAuthorization,
  normalizeCommercialPurchaseReadinessResult:
    mocks.normalizeReadiness,
  normalizeCommercialPurchaseRuntimeSnapshot:
    mocks.normalizeSnapshot,
  normalizeCommercialPurchaseRuntimeTimeline:
    mocks.normalizeTimeline,
}));

import {
  decideCommercialPurchaseAuthorization,
  evaluateCommercialPurchaseReadiness,
  getCommercialPurchaseRuntime,
  getCommercialPurchaseRuntimeTimeline,
  requestCommercialPurchaseAuthorization,
} from "./service";

const PURCHASE_ID =
  "11111111-1111-4111-8111-111111111111";
const AUTHORIZATION_ID =
  "22222222-2222-4222-8222-222222222222";

const readinessResult = {
  evaluated: true as const,
  purchase_id: PURCHASE_ID,
  runtime_state: "ready" as const,
  readiness_status: "ready" as const,
  automatic_execution_allowed: false as const,
  blockers: [],
  state_reason: "Purchase is ready.",
};

const authorizationResult = {
  requested: true as const,
  authorization_id: AUTHORIZATION_ID,
  authorization_status: "requested" as const,
  expires_at: "2026-07-23T15:00:00.000Z",
};

const snapshotResult = {
  purchase: {
    id: PURCHASE_ID,
    product_id:
      "33333333-3333-4333-8333-333333333333",
    provider_id:
      "44444444-4444-4444-8444-444444444444",
    purchase_status: "pending",
    correlation_id: "purchase-correlation",
    created_at: "2026-07-23T14:00:00.000Z",
  },
  runtime_state: null,
  authorizations: [],
  attempts: [],
  outbox: [],
};

const timelineResult: [] = [];

beforeEach(() => {
  vi.clearAllMocks();

  mocks.normalizeReadiness.mockReturnValue(
    readinessResult,
  );
  mocks.normalizeAuthorization.mockReturnValue(
    authorizationResult,
  );
  mocks.normalizeSnapshot.mockReturnValue(
    snapshotResult,
  );
  mocks.normalizeTimeline.mockReturnValue(
    timelineResult,
  );
});

describe(
  "evaluateCommercialPurchaseReadiness",
  () => {
    it("calls the exact RPC and normalizes its payload", async () => {
      const rawPayload = {
        source: "database",
      };

      mocks.callCommercialRuntimeRpc.mockResolvedValue({
        data: rawPayload,
        rpcName:
          "evaluate_commercial_purchase_runtime_readiness_internal",
      });

      const result =
        await evaluateCommercialPurchaseReadiness({
          purchaseId: PURCHASE_ID,
        });

      expect(
        mocks.callCommercialRuntimeRpc,
      ).toHaveBeenCalledOnce();

      expect(
        mocks.callCommercialRuntimeRpc,
      ).toHaveBeenCalledWith(
        "evaluate_commercial_purchase_runtime_readiness_internal",
        {
          p_purchase_id: PURCHASE_ID,
        },
      );

      expect(
        mocks.normalizeReadiness,
      ).toHaveBeenCalledOnce();

      expect(
        mocks.normalizeReadiness,
      ).toHaveBeenCalledWith(rawPayload);

      expect(result).toBe(readinessResult);
    });

    it("trims the purchase UUID before the RPC", async () => {
      mocks.callCommercialRuntimeRpc.mockResolvedValue({
        data: {},
        rpcName:
          "evaluate_commercial_purchase_runtime_readiness_internal",
      });

      await evaluateCommercialPurchaseReadiness({
        purchaseId: `  ${PURCHASE_ID}  `,
      });

      expect(
        mocks.callCommercialRuntimeRpc,
      ).toHaveBeenCalledWith(
        "evaluate_commercial_purchase_runtime_readiness_internal",
        {
          p_purchase_id: PURCHASE_ID,
        },
      );
    });

    it("rejects an invalid UUID before calling the RPC", async () => {
      await expect(
        evaluateCommercialPurchaseReadiness({
          purchaseId: "not-a-uuid",
        }),
      ).rejects.toThrow(
        "purchaseId must be a valid UUID.",
      );

      expect(
        mocks.callCommercialRuntimeRpc,
      ).not.toHaveBeenCalled();

      expect(
        mocks.normalizeReadiness,
      ).not.toHaveBeenCalled();
    });
  },
);

describe(
  "requestCommercialPurchaseAuthorization",
  () => {
    it("builds the exact RPC payload and defaults metadata", async () => {
      const rawPayload = {
        authorization: "raw",
      };

      mocks.callCommercialRuntimeRpc.mockResolvedValue({
        data: rawPayload,
        rpcName:
          "request_commercial_purchase_authorization_internal",
      });

      const result =
        await requestCommercialPurchaseAuthorization({
          purchaseId: PURCHASE_ID,
          requestedAction: "confirm_payment",
          authorizationKey: "  authorization-key  ",
          requestedBy: "  operator  ",
        });

      expect(
        mocks.callCommercialRuntimeRpc,
      ).toHaveBeenCalledWith(
        "request_commercial_purchase_authorization_internal",
        {
          p_purchase_id: PURCHASE_ID,
          p_requested_action: "confirm_payment",
          p_authorization_key: "authorization-key",
          p_requested_by: "operator",
          p_metadata: {},
        },
      );

      expect(
        mocks.normalizeAuthorization,
      ).toHaveBeenCalledWith(rawPayload);

      expect(result).toBe(authorizationResult);
    });

    it("forwards the supplied metadata unchanged", async () => {
      const metadata = {
        source: "control-room",
        retry: false,
      };

      mocks.callCommercialRuntimeRpc.mockResolvedValue({
        data: {},
        rpcName:
          "request_commercial_purchase_authorization_internal",
      });

      await requestCommercialPurchaseAuthorization({
        purchaseId: PURCHASE_ID,
        requestedAction: "confirm_payment",
        authorizationKey: "authorization-key",
        requestedBy: "operator",
        metadata,
      });

      expect(
        mocks.callCommercialRuntimeRpc,
      ).toHaveBeenCalledWith(
        "request_commercial_purchase_authorization_internal",
        expect.objectContaining({
          p_metadata: metadata,
        }),
      );
    });

    it.each([
      {
        field: "requestedAction",
        input: {
          purchaseId: PURCHASE_ID,
          requestedAction: "   ",
          authorizationKey: "authorization-key",
          requestedBy: "operator",
        },
        message: "requestedAction must not be empty.",
      },
      {
        field: "authorizationKey",
        input: {
          purchaseId: PURCHASE_ID,
          requestedAction: "confirm_payment",
          authorizationKey: "   ",
          requestedBy: "operator",
        },
        message: "authorizationKey must not be empty.",
      },
      {
        field: "requestedBy",
        input: {
          purchaseId: PURCHASE_ID,
          requestedAction: "confirm_payment",
          authorizationKey: "authorization-key",
          requestedBy: "   ",
        },
        message: "requestedBy must not be empty.",
      },
    ] as const)(
      "rejects an empty $field before calling the RPC",
      async ({ input, message }) => {
        await expect(
          requestCommercialPurchaseAuthorization(
            input as unknown as Parameters<
              typeof requestCommercialPurchaseAuthorization
            >[0],
          ),
        ).rejects.toThrow(message);

        expect(
          mocks.callCommercialRuntimeRpc,
        ).not.toHaveBeenCalled();

        expect(
          mocks.normalizeAuthorization,
        ).not.toHaveBeenCalled();
      },
    );
  },
);

describe(
  "decideCommercialPurchaseAuthorization",
  () => {
    it("builds the exact decision RPC payload", async () => {
      const rawPayload = {
        decision: "raw",
      };

      mocks.callCommercialRuntimeRpc.mockResolvedValue({
        data: rawPayload,
        rpcName:
          "decide_commercial_purchase_authorization_internal",
      });

      const result =
        await decideCommercialPurchaseAuthorization({
          authorizationId: AUTHORIZATION_ID,
          decision: "approved",
          decisionBy: "  reviewer  ",
          reason: "  Valid purchase  ",
        });

      expect(
        mocks.callCommercialRuntimeRpc,
      ).toHaveBeenCalledWith(
        "decide_commercial_purchase_authorization_internal",
        {
          p_authorization_id: AUTHORIZATION_ID,
          p_decision: "approved",
          p_decision_by: "reviewer",
          p_reason: "Valid purchase",
        },
      );

      expect(
        mocks.normalizeAuthorization,
      ).toHaveBeenCalledWith(rawPayload);

      expect(result).toBe(authorizationResult);
    });

    it("normalizes an empty decision reason to null", async () => {
      mocks.callCommercialRuntimeRpc.mockResolvedValue({
        data: {},
        rpcName:
          "decide_commercial_purchase_authorization_internal",
      });

      await decideCommercialPurchaseAuthorization({
        authorizationId: AUTHORIZATION_ID,
        decision: "rejected",
        decisionBy: "reviewer",
        reason: "   ",
      });

      expect(
        mocks.callCommercialRuntimeRpc,
      ).toHaveBeenCalledWith(
        "decide_commercial_purchase_authorization_internal",
        expect.objectContaining({
          p_reason: null,
        }),
      );
    });

    it("rejects an invalid authorization UUID", async () => {
      await expect(
        decideCommercialPurchaseAuthorization({
          authorizationId: "invalid",
          decision: "approved",
          decisionBy: "reviewer",
        }),
      ).rejects.toThrow(
        "authorizationId must be a valid UUID.",
      );

      expect(
        mocks.callCommercialRuntimeRpc,
      ).not.toHaveBeenCalled();
    });

    it("rejects an empty decision actor", async () => {
      await expect(
        decideCommercialPurchaseAuthorization({
          authorizationId: AUTHORIZATION_ID,
          decision: "approved",
          decisionBy: "   ",
        }),
      ).rejects.toThrow(
        "decisionBy must not be empty.",
      );

      expect(
        mocks.callCommercialRuntimeRpc,
      ).not.toHaveBeenCalled();
    });
  },
);

describe(
  "commercial purchase runtime readers",
  () => {
    it("gets the snapshot through its mandatory normalizer", async () => {
      const rawPayload = {
        snapshot: "raw",
      };

      mocks.callCommercialRuntimeRpc.mockResolvedValue({
        data: rawPayload,
        rpcName:
          "get_commercial_purchase_runtime_internal",
      });

      const result =
        await getCommercialPurchaseRuntime({
          purchaseId: PURCHASE_ID,
        });

      expect(
        mocks.callCommercialRuntimeRpc,
      ).toHaveBeenCalledWith(
        "get_commercial_purchase_runtime_internal",
        {
          p_purchase_id: PURCHASE_ID,
        },
      );

      expect(
        mocks.normalizeSnapshot,
      ).toHaveBeenCalledWith(rawPayload);

      expect(result).toBe(snapshotResult);
    });

    it("gets the timeline through its mandatory normalizer", async () => {
      const rawPayload = [
        {
          event: "raw",
        },
      ];

      mocks.callCommercialRuntimeRpc.mockResolvedValue({
        data: rawPayload,
        rpcName:
          "get_commercial_purchase_runtime_timeline_internal",
      });

      const result =
        await getCommercialPurchaseRuntimeTimeline({
          purchaseId: PURCHASE_ID,
        });

      expect(
        mocks.callCommercialRuntimeRpc,
      ).toHaveBeenCalledWith(
        "get_commercial_purchase_runtime_timeline_internal",
        {
          p_purchase_id: PURCHASE_ID,
        },
      );

      expect(
        mocks.normalizeTimeline,
      ).toHaveBeenCalledWith(rawPayload);

      expect(result).toBe(timelineResult);
    });
  },
);

describe(
  "commercial purchase service error propagation",
  () => {
    it("propagates RPC failures without invoking a validator", async () => {
      const rpcError = new Error(
        "Commercial runtime RPC failed.",
      );

      mocks.callCommercialRuntimeRpc.mockRejectedValue(
        rpcError,
      );

      await expect(
        getCommercialPurchaseRuntime({
          purchaseId: PURCHASE_ID,
        }),
      ).rejects.toBe(rpcError);

      expect(
        mocks.normalizeSnapshot,
      ).not.toHaveBeenCalled();
    });

    it("propagates validator failures after a successful RPC", async () => {
      const validationError = new TypeError(
        "Invalid commercial runtime payload.",
      );

      mocks.callCommercialRuntimeRpc.mockResolvedValue({
        data: {
          invalid: true,
        },
        rpcName:
          "get_commercial_purchase_runtime_internal",
      });

      mocks.normalizeSnapshot.mockImplementation(() => {
        throw validationError;
      });

      await expect(
        getCommercialPurchaseRuntime({
          purchaseId: PURCHASE_ID,
        }),
      ).rejects.toBe(validationError);

      expect(
        mocks.callCommercialRuntimeRpc,
      ).toHaveBeenCalledOnce();
    });
  },
);
