import { describe, expect, it } from "vitest";

import {
  normalizeCommercialPurchaseAuthorizationResult,
  normalizeCommercialPurchaseReadinessResult,
  normalizeCommercialPurchaseRuntimeSnapshot,
  normalizeCommercialPurchaseRuntimeTimeline,
} from "./validation";

const PURCHASE_ID =
  "11111111-1111-4111-8111-111111111111";
const POLICY_ID =
  "22222222-2222-4222-8222-222222222222";
const AUTHORIZATION_ID =
  "33333333-3333-4333-8333-333333333333";
const ATTEMPT_ID =
  "44444444-4444-4444-8444-444444444444";
const PROVIDER_ID =
  "55555555-5555-4555-8555-555555555555";
const PRODUCT_ID =
  "66666666-6666-4666-8666-666666666666";
const EVENT_ID =
  "77777777-7777-4777-8777-777777777777";
const OUTBOX_ID =
  "88888888-8888-4888-8888-888888888888";

const NOW = "2026-07-23T13:00:00.000Z";

describe(
  "normalizeCommercialPurchaseReadinessResult",
  () => {
    it("accepts an evaluated readiness payload", () => {
      const result =
        normalizeCommercialPurchaseReadinessResult({
          evaluated: true,
          purchase_id: PURCHASE_ID,
          runtime_state: "ready",
          readiness_status: "ready",
          automatic_execution_allowed: false,
          blockers: [],
          state_reason: "Purchase is ready.",
        });

      expect(result).toEqual({
        evaluated: true,
        purchase_id: PURCHASE_ID,
        runtime_state: "ready",
        readiness_status: "ready",
        automatic_execution_allowed: false,
        blockers: [],
        state_reason: "Purchase is ready.",
      });
    });

    it("accepts the purchase-not-found result", () => {
      const result =
        normalizeCommercialPurchaseReadinessResult({
          evaluated: false,
          error_code: "COMMERCIAL_PURCHASE_NOT_FOUND",
          purchase_id: PURCHASE_ID,
        });

      expect(result).toEqual({
        evaluated: false,
        error_code: "COMMERCIAL_PURCHASE_NOT_FOUND",
        purchase_id: PURCHASE_ID,
      });
    });

    it("rejects an unknown runtime state", () => {
      expect(() =>
        normalizeCommercialPurchaseReadinessResult({
          evaluated: true,
          purchase_id: PURCHASE_ID,
          runtime_state: "unknown_state",
          readiness_status: "ready",
          automatic_execution_allowed: false,
          blockers: [],
          state_reason: "Invalid state.",
        }),
      ).toThrow("readiness.runtime_state is invalid");
    });

    it("rejects automatic execution enablement", () => {
      expect(() =>
        normalizeCommercialPurchaseReadinessResult({
          evaluated: true,
          purchase_id: PURCHASE_ID,
          runtime_state: "ready",
          readiness_status: "ready",
          automatic_execution_allowed: true,
          blockers: [],
          state_reason: "Unsafe payload.",
        }),
      ).toThrow(
        "readiness.automatic_execution_allowed must be false",
      );
    });

    it("rejects an invalid discriminator", () => {
      expect(() =>
        normalizeCommercialPurchaseReadinessResult({
          evaluated: "true",
        }),
      ).toThrow("invalid discriminator");
    });
  },
);

describe(
  "normalizeCommercialPurchaseAuthorizationResult",
  () => {
    it("accepts a new authorization request", () => {
      const result =
        normalizeCommercialPurchaseAuthorizationResult({
          requested: true,
          authorization_id: AUTHORIZATION_ID,
          authorization_status: "requested",
          expires_at: NOW,
        });

      expect(result).toEqual({
        requested: true,
        authorization_id: AUTHORIZATION_ID,
        authorization_status: "requested",
        expires_at: NOW,
      });
    });

    it("accepts an existing authorization reuse", () => {
      const result =
        normalizeCommercialPurchaseAuthorizationResult({
          requested: false,
          reused_existing_authorization: true,
          authorization_id: AUTHORIZATION_ID,
          authorization_status: "approved",
        });

      expect(result).toEqual({
        requested: false,
        reused_existing_authorization: true,
        authorization_id: AUTHORIZATION_ID,
        authorization_status: "approved",
      });
    });

    it("accepts an approved decision", () => {
      const result =
        normalizeCommercialPurchaseAuthorizationResult({
          decided: true,
          authorization_id: AUTHORIZATION_ID,
          authorization_status: "approved",
          automatic_execution_scheduled: false,
        });

      expect(result).toEqual({
        decided: true,
        authorization_id: AUTHORIZATION_ID,
        authorization_status: "approved",
        automatic_execution_scheduled: false,
      });
    });

    it("rejects an invalid authorization status", () => {
      expect(() =>
        normalizeCommercialPurchaseAuthorizationResult({
          requested: true,
          authorization_id: AUTHORIZATION_ID,
          authorization_status: "pending",
          expires_at: NOW,
        }),
      ).toThrow(
        "authorization.authorization_status is invalid",
      );
    });

    it("rejects automatic execution scheduling", () => {
      expect(() =>
        normalizeCommercialPurchaseAuthorizationResult({
          decided: true,
          authorization_id: AUTHORIZATION_ID,
          authorization_status: "approved",
          automatic_execution_scheduled: true,
        }),
      ).toThrow(
        "authorization_decision.automatic_execution_scheduled must be false",
      );
    });

    it("rejects a result without a discriminator", () => {
      expect(() =>
        normalizeCommercialPurchaseAuthorizationResult({
          authorization_id: AUTHORIZATION_ID,
        }),
      ).toThrow("has no valid discriminator");
    });
  },
);

describe(
  "normalizeCommercialPurchaseRuntimeSnapshot",
  () => {
    it("accepts a minimal snapshot without runtime state", () => {
      const result =
        normalizeCommercialPurchaseRuntimeSnapshot({
          purchase: {
            id: PURCHASE_ID,
            product_id: PRODUCT_ID,
            provider_id: PROVIDER_ID,
            purchase_status: "pending",
            correlation_id: "purchase-correlation",
            created_at: NOW,
          },
          runtime_state: null,
          authorizations: [],
          attempts: [],
          outbox: [],
        });

      expect(result.runtime_state).toBeNull();
      expect(result.authorizations).toEqual([]);
      expect(result.attempts).toEqual([]);
      expect(result.outbox).toEqual([]);
      expect(result.purchase.id).toBe(PURCHASE_ID);
    });

    it("accepts a fully populated runtime snapshot", () => {
      const result =
        normalizeCommercialPurchaseRuntimeSnapshot({
          purchase: {
            id: PURCHASE_ID,
            product_id: PRODUCT_ID,
            provider_id: PROVIDER_ID,
            purchase_status: "paid",
            correlation_id: "purchase-correlation",
            created_at: NOW,
          },
          runtime_state: {
            purchase_id: PURCHASE_ID,
            policy_id: POLICY_ID,
            runtime_state: "authorized",
            readiness_status: "ready",
            current_action: "confirm_payment",
            active_authorization_id: AUTHORIZATION_ID,
            last_attempt_id: ATTEMPT_ID,
            next_action_at: null,
            attention_required: false,
            automatic_execution_allowed: false,
            state_reason: "Authorization approved.",
            state_version: 2,
            evaluated_at: NOW,
            updated_at: NOW,
            metadata: {
              source: "unit-test",
            },
          },
          authorizations: [
            {
              id: AUTHORIZATION_ID,
              purchase_id: PURCHASE_ID,
              policy_id: POLICY_ID,
              authorization_key: "authorization-key",
              authorization_status: "approved",
              requested_action: "confirm_payment",
              requested_by: "operator",
              decision_by: "reviewer",
              decision_reason: "Approved.",
              requested_at: NOW,
              expires_at: NOW,
              decided_at: NOW,
              correlation_id: "authorization-correlation",
              metadata: {},
            },
          ],
          attempts: [
            {
              id: ATTEMPT_ID,
              purchase_id: PURCHASE_ID,
              authorization_id: AUTHORIZATION_ID,
              provider_id: PROVIDER_ID,
              attempt_number: 1,
              execution_action: "confirm_payment",
              execution_status: "succeeded",
              idempotency_key: "attempt-key",
              worker_code: "commercial-worker",
              lease_token: null,
              leased_at: NOW,
              lease_expires_at: NOW,
              started_at: NOW,
              completed_at: NOW,
              next_retry_at: null,
              error_code: null,
              error_message: null,
              correlation_id: "attempt-correlation",
              causation_id: "authorization-correlation",
              request_snapshot: {},
              response_snapshot: {},
              metadata: {},
              created_at: NOW,
            },
          ],
          outbox: [
            {
              id: OUTBOX_ID,
              purchase_id: PURCHASE_ID,
              authorization_id: AUTHORIZATION_ID,
              requested_action: "confirm_payment",
              dispatch_status: "completed",
              idempotency_key: "outbox-key",
              available_at: NOW,
              dispatched_at: NOW,
              completed_at: NOW,
              correlation_id: "outbox-correlation",
              payload: {},
              error_code: null,
              error_message: null,
              created_at: NOW,
            },
          ],
        });

      expect(result.runtime_state?.runtime_state).toBe(
        "authorized",
      );
      expect(
        result.authorizations[0]?.authorization_status,
      ).toBe("approved");
      expect(result.attempts[0]?.execution_status).toBe(
        "succeeded",
      );
      expect(result.outbox[0]?.dispatch_status).toBe(
        "completed",
      );
    });

    it("rejects a non-array authorization collection", () => {
      expect(() =>
        normalizeCommercialPurchaseRuntimeSnapshot({
          purchase: {
            id: PURCHASE_ID,
            product_id: PRODUCT_ID,
            provider_id: PROVIDER_ID,
            purchase_status: "pending",
            correlation_id: "purchase-correlation",
            created_at: NOW,
          },
          runtime_state: null,
          authorizations: {},
          attempts: [],
          outbox: [],
        }),
      ).toThrow(
        "Commercial purchase runtime snapshot.authorizations must be an array",
      );
    });

    it("rejects an invalid nested outbox status", () => {
      expect(() =>
        normalizeCommercialPurchaseRuntimeSnapshot({
          purchase: {
            id: PURCHASE_ID,
            product_id: PRODUCT_ID,
            provider_id: PROVIDER_ID,
            purchase_status: "pending",
            correlation_id: "purchase-correlation",
            created_at: NOW,
          },
          runtime_state: null,
          authorizations: [],
          attempts: [],
          outbox: [
            {
              id: OUTBOX_ID,
              purchase_id: PURCHASE_ID,
              authorization_id: null,
              requested_action: "confirm_payment",
              dispatch_status: "queued",
              idempotency_key: "outbox-key",
              available_at: NOW,
              dispatched_at: null,
              completed_at: null,
              correlation_id: "outbox-correlation",
              payload: {},
              error_code: null,
              error_message: null,
              created_at: NOW,
            },
          ],
        }),
      ).toThrow("outbox[0].dispatch_status is invalid");
    });
  },
);

describe(
  "normalizeCommercialPurchaseRuntimeTimeline",
  () => {
    it("accepts a valid timeline", () => {
      const result =
        normalizeCommercialPurchaseRuntimeTimeline([
          {
            id: EVENT_ID,
            purchase_id: PURCHASE_ID,
            policy_id: POLICY_ID,
            authorization_id: AUTHORIZATION_ID,
            attempt_id: ATTEMPT_ID,
            event_type: "authorization_approved",
            previous_state: "ready",
            next_state: "authorized",
            actor: "reviewer",
            reason: "Approved.",
            correlation_id: "timeline-correlation",
            causation_id: "authorization-correlation",
            payload: {
              source: "unit-test",
            },
            occurred_at: NOW,
          },
        ]);

      expect(result).toHaveLength(1);
      expect(result[0]?.event_type).toBe(
        "authorization_approved",
      );
      expect(result[0]?.payload).toEqual({
        source: "unit-test",
      });
    });

    it("rejects a non-array timeline", () => {
      expect(() =>
        normalizeCommercialPurchaseRuntimeTimeline({}),
      ).toThrow(
        "Commercial purchase runtime timeline must be an array",
      );
    });

    it("rejects a non-object event payload", () => {
      expect(() =>
        normalizeCommercialPurchaseRuntimeTimeline([
          {
            id: EVENT_ID,
            purchase_id: PURCHASE_ID,
            policy_id: null,
            authorization_id: null,
            attempt_id: null,
            event_type: "runtime_evaluated",
            previous_state: null,
            next_state: "ready",
            actor: "runtime",
            reason: null,
            correlation_id: "timeline-correlation",
            causation_id: null,
            payload: [],
            occurred_at: NOW,
          },
        ]),
      ).toThrow(
        "Commercial purchase runtime timeline entry 0.payload must be a JSON object",
      );
    });

    it("rejects a missing required event field", () => {
      expect(() =>
        normalizeCommercialPurchaseRuntimeTimeline([
          {
            id: EVENT_ID,
            purchase_id: PURCHASE_ID,
            policy_id: null,
            authorization_id: null,
            attempt_id: null,
            previous_state: null,
            next_state: "ready",
            actor: "runtime",
            reason: null,
            correlation_id: "timeline-correlation",
            causation_id: null,
            payload: {},
            occurred_at: NOW,
          },
        ]),
      ).toThrow(
        "Commercial purchase runtime timeline entry 0.event_type must be a non-empty string",
      );
    });
  },
);
