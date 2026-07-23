import {
  describe,
  expect,
  expectTypeOf,
  it,
  vi,
} from "vitest";

vi.mock("server-only", () => ({}));

vi.mock("@/lib/supabase/service", () => ({
  getSupabaseServiceClient: vi.fn(),
}));

import * as commercial from "./index";

import {
  COMMERCIAL_RUNTIME_ERROR_CODES,
  CommercialRuntimeError,
  hasCommercialRuntimeErrorCode,
  isCommercialRuntimeError,
} from "./errors";

import {
  decideCommercialPurchaseAuthorization,
  evaluateCommercialPurchaseReadiness,
  getCommercialPurchaseRuntime,
  getCommercialPurchaseRuntimeTimeline,
  requestCommercialPurchaseAuthorization,
} from "./purchase/service";

import {
  getRewardCampaigns,
} from "./reward/service";

import {
  getCommercialProducts,
} from "./product/service";

import {
  getMyCommercialLedger,
} from "./ledger/service";

import {
  getMyCommercialWallet,
} from "./wallet/service";

import type {
  CommercialRuntimeErrorCode as DirectCommercialRuntimeErrorCode,
} from "./errors";

import type {
  JsonObject as DirectJsonObject,
  JsonPrimitive as DirectJsonPrimitive,
  JsonValue as DirectJsonValue,
} from "./json";

import type {
  CommercialPurchaseAuthorizationDecision as DirectCommercialPurchaseAuthorizationDecision,
  CommercialPurchaseAuthorizationResult as DirectCommercialPurchaseAuthorizationResult,
  CommercialPurchaseReadinessResult as DirectCommercialPurchaseReadinessResult,
  CommercialPurchaseRuntimeSnapshot as DirectCommercialPurchaseRuntimeSnapshot,
  CommercialPurchaseRuntimeTimeline as DirectCommercialPurchaseRuntimeTimeline,
  DecideCommercialPurchaseAuthorizationInput as DirectDecideCommercialPurchaseAuthorizationInput,
  EvaluateCommercialPurchaseReadinessInput as DirectEvaluateCommercialPurchaseReadinessInput,
  GetCommercialPurchaseRuntimeInput as DirectGetCommercialPurchaseRuntimeInput,
  GetCommercialPurchaseTimelineInput as DirectGetCommercialPurchaseTimelineInput,
  RequestCommercialPurchaseAuthorizationInput as DirectRequestCommercialPurchaseAuthorizationInput,
} from "./purchase/types";

import type {
  CommercialRewardCampaign as DirectCommercialRewardCampaign,
  CommercialRewardCampaigns as DirectCommercialRewardCampaigns,
  CommercialRewardType as DirectCommercialRewardType,
} from "./reward/types";

import type {
  CommercialProduct as DirectCommercialProduct,
  CommercialProducts as DirectCommercialProducts,
  GetCommercialProductsInput as DirectGetCommercialProductsInput,
} from "./product/types";

import type {
  CommercialLedger as DirectCommercialLedger,
  CommercialLedgerEntry as DirectCommercialLedgerEntry,
  GetMyCommercialLedgerInput as DirectGetMyCommercialLedgerInput,
} from "./ledger/types";

import type {
  CommercialWallet as DirectCommercialWallet,
  CommercialWalletStatus as DirectCommercialWalletStatus,
} from "./wallet/types";

import type {
  CommercialRuntimeEvent as DirectCommercialRuntimeEvent,
  CommercialRuntimeRpcFailure as DirectCommercialRuntimeRpcFailure,
  CommercialRuntimeRpcName as DirectCommercialRuntimeRpcName,
  CommercialRuntimeRpcResult as DirectCommercialRuntimeRpcResult,
} from "./types";

import type {
  CommercialPurchaseAuthorizationDecision,
  CommercialPurchaseAuthorizationResult,
  CommercialPurchaseReadinessResult,
  CommercialPurchaseRuntimeSnapshot,
  CommercialPurchaseRuntimeTimeline,
  CommercialRuntimeErrorCode,
  CommercialRewardCampaign,
  CommercialRewardCampaigns,
  CommercialRewardType,
  CommercialProduct,
  CommercialProducts,
  CommercialLedger,
  CommercialLedgerEntry,
  CommercialWallet,
  CommercialWalletStatus,
  CommercialRuntimeEvent,
  CommercialRuntimeRpcFailure,
  CommercialRuntimeRpcName,
  CommercialRuntimeRpcResult,
  DecideCommercialPurchaseAuthorizationInput,
  EvaluateCommercialPurchaseReadinessInput,
  GetCommercialPurchaseRuntimeInput,
  GetCommercialPurchaseTimelineInput,
  GetCommercialProductsInput,
  GetMyCommercialLedgerInput,
  JsonObject,
  JsonPrimitive,
  JsonValue,
  RequestCommercialPurchaseAuthorizationInput,
} from "./index";

const EXPECTED_RUNTIME_EXPORTS = [
  "COMMERCIAL_RUNTIME_ERROR_CODES",
  "CommercialRuntimeError",
  "decideCommercialPurchaseAuthorization",
  "evaluateCommercialPurchaseReadiness",
  "getCommercialPurchaseRuntime",
  "getCommercialPurchaseRuntimeTimeline",
  "getRewardCampaigns",
  "getCommercialProducts",
  "getMyCommercialLedger",
  "getMyCommercialWallet",
  "hasCommercialRuntimeErrorCode",
  "isCommercialRuntimeError",
  "requestCommercialPurchaseAuthorization",
] as const;

describe("commercial public runtime export surface", () => {
  it("exports exactly the approved runtime symbols", () => {
    expect(
      Object.keys(commercial).sort(),
    ).toEqual([...EXPECTED_RUNTIME_EXPORTS].sort());
  });

  it("exports thirteen unique runtime symbols", () => {
    expect(EXPECTED_RUNTIME_EXPORTS).toHaveLength(13);
    expect(
      new Set(EXPECTED_RUNTIME_EXPORTS).size,
    ).toBe(13);
  });

  it("re-exports the error code registry by identity", () => {
    expect(
      commercial.COMMERCIAL_RUNTIME_ERROR_CODES,
    ).toBe(COMMERCIAL_RUNTIME_ERROR_CODES);
  });

  it("re-exports CommercialRuntimeError by identity", () => {
    expect(
      commercial.CommercialRuntimeError,
    ).toBe(CommercialRuntimeError);
  });

  it("re-exports isCommercialRuntimeError by identity", () => {
    expect(
      commercial.isCommercialRuntimeError,
    ).toBe(isCommercialRuntimeError);
  });

  it("re-exports hasCommercialRuntimeErrorCode by identity", () => {
    expect(
      commercial.hasCommercialRuntimeErrorCode,
    ).toBe(hasCommercialRuntimeErrorCode);
  });

  it("re-exports evaluateCommercialPurchaseReadiness by identity", () => {
    expect(
      commercial.evaluateCommercialPurchaseReadiness,
    ).toBe(evaluateCommercialPurchaseReadiness);
  });

  it("re-exports requestCommercialPurchaseAuthorization by identity", () => {
    expect(
      commercial.requestCommercialPurchaseAuthorization,
    ).toBe(requestCommercialPurchaseAuthorization);
  });

  it("re-exports decideCommercialPurchaseAuthorization by identity", () => {
    expect(
      commercial.decideCommercialPurchaseAuthorization,
    ).toBe(decideCommercialPurchaseAuthorization);
  });

  it("re-exports getCommercialPurchaseRuntime by identity", () => {
    expect(
      commercial.getCommercialPurchaseRuntime,
    ).toBe(getCommercialPurchaseRuntime);
  });

  it("re-exports getCommercialPurchaseRuntimeTimeline by identity", () => {
    expect(
      commercial.getCommercialPurchaseRuntimeTimeline,
    ).toBe(getCommercialPurchaseRuntimeTimeline);
  });

  it("re-exports getRewardCampaigns by identity", () => {
    expect(
      commercial.getRewardCampaigns,
    ).toBe(getRewardCampaigns);
  });

  it("re-exports getCommercialProducts by identity", () => {
    expect(
      commercial.getCommercialProducts,
    ).toBe(getCommercialProducts);
  });

  it("re-exports getMyCommercialLedger by identity", () => {
    expect(
      commercial.getMyCommercialLedger,
    ).toBe(getMyCommercialLedger);
  });

  it("re-exports getMyCommercialWallet by identity", () => {
    expect(
      commercial.getMyCommercialWallet,
    ).toBe(getMyCommercialWallet);
  });

  it("does not expose internal runtime helpers", () => {
    expect(commercial).not.toHaveProperty(
      "callCommercialRuntimeRpc",
    );
    expect(commercial).not.toHaveProperty(
      "normalizeCommercialPurchaseReadinessResult",
    );
    expect(commercial).not.toHaveProperty(
      "normalizeCommercialPurchaseAuthorizationResult",
    );
    expect(commercial).not.toHaveProperty(
      "normalizeCommercialPurchaseRuntimeSnapshot",
    );
    expect(commercial).not.toHaveProperty(
      "normalizeCommercialPurchaseRuntimeTimeline",
    );
    expect(commercial).not.toHaveProperty(
      "normalizeRewardCampaigns",
    );
    expect(commercial).not.toHaveProperty(
      "normalizeCommercialProducts",
    );
    expect(commercial).not.toHaveProperty(
      "normalizeCommercialLedger",
    );
    expect(commercial).not.toHaveProperty(
      "normalizeCommercialWallet",
    );
    expect(commercial).not.toHaveProperty(
      "isJsonObject",
    );
    expect(commercial).not.toHaveProperty(
      "asJsonObject",
    );
  });
});

describe("commercial public type export surface", () => {
  it("re-exports CommercialRuntimeErrorCode", () => {
    expectTypeOf<
      CommercialRuntimeErrorCode
    >().toEqualTypeOf<
      DirectCommercialRuntimeErrorCode
    >();
  });

  it("re-exports JsonPrimitive", () => {
    expectTypeOf<JsonPrimitive>().toEqualTypeOf<
      DirectJsonPrimitive
    >();
  });

  it("re-exports JsonValue", () => {
    expectTypeOf<JsonValue>().toEqualTypeOf<
      DirectJsonValue
    >();
  });

  it("re-exports JsonObject", () => {
    expectTypeOf<JsonObject>().toEqualTypeOf<
      DirectJsonObject
    >();
  });

  it("re-exports CommercialPurchaseAuthorizationDecision", () => {
    expectTypeOf<
      CommercialPurchaseAuthorizationDecision
    >().toEqualTypeOf<
      DirectCommercialPurchaseAuthorizationDecision
    >();
  });

  it("re-exports CommercialPurchaseAuthorizationResult", () => {
    expectTypeOf<
      CommercialPurchaseAuthorizationResult
    >().toEqualTypeOf<
      DirectCommercialPurchaseAuthorizationResult
    >();
  });

  it("re-exports CommercialPurchaseReadinessResult", () => {
    expectTypeOf<
      CommercialPurchaseReadinessResult
    >().toEqualTypeOf<
      DirectCommercialPurchaseReadinessResult
    >();
  });

  it("re-exports CommercialPurchaseRuntimeSnapshot", () => {
    expectTypeOf<
      CommercialPurchaseRuntimeSnapshot
    >().toEqualTypeOf<
      DirectCommercialPurchaseRuntimeSnapshot
    >();
  });

  it("re-exports CommercialPurchaseRuntimeTimeline", () => {
    expectTypeOf<
      CommercialPurchaseRuntimeTimeline
    >().toEqualTypeOf<
      DirectCommercialPurchaseRuntimeTimeline
    >();
  });

  it("re-exports DecideCommercialPurchaseAuthorizationInput", () => {
    expectTypeOf<
      DecideCommercialPurchaseAuthorizationInput
    >().toEqualTypeOf<
      DirectDecideCommercialPurchaseAuthorizationInput
    >();
  });

  it("re-exports EvaluateCommercialPurchaseReadinessInput", () => {
    expectTypeOf<
      EvaluateCommercialPurchaseReadinessInput
    >().toEqualTypeOf<
      DirectEvaluateCommercialPurchaseReadinessInput
    >();
  });

  it("re-exports GetCommercialPurchaseRuntimeInput", () => {
    expectTypeOf<
      GetCommercialPurchaseRuntimeInput
    >().toEqualTypeOf<
      DirectGetCommercialPurchaseRuntimeInput
    >();
  });

  it("re-exports GetCommercialPurchaseTimelineInput", () => {
    expectTypeOf<
      GetCommercialPurchaseTimelineInput
    >().toEqualTypeOf<
      DirectGetCommercialPurchaseTimelineInput
    >();
  });

  it("re-exports RequestCommercialPurchaseAuthorizationInput", () => {
    expectTypeOf<
      RequestCommercialPurchaseAuthorizationInput
    >().toEqualTypeOf<
      DirectRequestCommercialPurchaseAuthorizationInput
    >();
  });

  it("re-exports CommercialRewardCampaign", () => {
    expectTypeOf<
      CommercialRewardCampaign
    >().toEqualTypeOf<
      DirectCommercialRewardCampaign
    >();
  });

  it("re-exports CommercialRewardCampaigns", () => {
    expectTypeOf<
      CommercialRewardCampaigns
    >().toEqualTypeOf<
      DirectCommercialRewardCampaigns
    >();
  });

  it("re-exports CommercialRewardType", () => {
    expectTypeOf<
      CommercialRewardType
    >().toEqualTypeOf<
      DirectCommercialRewardType
    >();
  });

  it("re-exports CommercialProduct", () => {
    expectTypeOf<
      CommercialProduct
    >().toEqualTypeOf<
      DirectCommercialProduct
    >();
  });

  it("re-exports CommercialProducts", () => {
    expectTypeOf<
      CommercialProducts
    >().toEqualTypeOf<
      DirectCommercialProducts
    >();
  });

  it("re-exports GetCommercialProductsInput", () => {
    expectTypeOf<
      GetCommercialProductsInput
    >().toEqualTypeOf<
      DirectGetCommercialProductsInput
    >();
  });

  it("re-exports CommercialLedger", () => {
    expectTypeOf<
      CommercialLedger
    >().toEqualTypeOf<
      DirectCommercialLedger
    >();
  });

  it("re-exports CommercialLedgerEntry", () => {
    expectTypeOf<
      CommercialLedgerEntry
    >().toEqualTypeOf<
      DirectCommercialLedgerEntry
    >();
  });

  it("re-exports GetMyCommercialLedgerInput", () => {
    expectTypeOf<
      GetMyCommercialLedgerInput
    >().toEqualTypeOf<
      DirectGetMyCommercialLedgerInput
    >();
  });

  it("re-exports CommercialWallet", () => {
    expectTypeOf<
      CommercialWallet
    >().toEqualTypeOf<
      DirectCommercialWallet
    >();
  });

  it("re-exports CommercialWalletStatus", () => {
    expectTypeOf<
      CommercialWalletStatus
    >().toEqualTypeOf<
      DirectCommercialWalletStatus
    >();
  });

  it("re-exports CommercialRuntimeEvent", () => {
    expectTypeOf<
      CommercialRuntimeEvent
    >().toEqualTypeOf<
      DirectCommercialRuntimeEvent
    >();
  });

  it("re-exports CommercialRuntimeRpcFailure", () => {
    expectTypeOf<
      CommercialRuntimeRpcFailure
    >().toEqualTypeOf<
      DirectCommercialRuntimeRpcFailure
    >();
  });

  it("re-exports CommercialRuntimeRpcName", () => {
    expectTypeOf<
      CommercialRuntimeRpcName
    >().toEqualTypeOf<
      DirectCommercialRuntimeRpcName
    >();
  });

  it("re-exports CommercialRuntimeRpcResult", () => {
    type Payload = {
      purchaseId: string;
      ready: boolean;
    };

    expectTypeOf<
      CommercialRuntimeRpcResult<Payload>
    >().toEqualTypeOf<
      DirectCommercialRuntimeRpcResult<Payload>
    >();
  });
});
