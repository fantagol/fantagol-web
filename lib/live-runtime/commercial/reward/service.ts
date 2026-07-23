import "server-only";

import { isJsonObject } from "../json";
import { callCommercialRuntimeRpc } from "../rpc";
import type {
  CommercialRewardCampaigns,
  CommercialRewardClaimLookupResult,
  CommercialRewardClaims,
  CommercialRewardClaimSubmissionResult,
  GetMyCommercialRewardClaimInput,
  GetMyCommercialRewardClaimsInput,
  SubmitCommercialRewardClaimInput,
} from "./types";
import {
  normalizeRewardCampaigns,
  normalizeRewardClaimLookupResult,
  normalizeRewardClaims,
  normalizeRewardClaimSubmissionResult,
} from "./validation";

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

const UPPER_CODE_PATTERN = /^[A-Z][A-Z0-9_]+$/;

function requireClaimId(value: string): string {
  const normalized = value.trim();

  if (!UUID_PATTERN.test(normalized)) {
    throw new TypeError("claimId must be a valid UUID.");
  }

  return normalized;
}

function normalizeClaimsLimit(value: number | undefined): number {
  const normalized = value ?? 50;

  if (!Number.isSafeInteger(normalized) || normalized < 1 || normalized > 200) {
    throw new TypeError("limit must be a safe integer between 1 and 200.");
  }

  return normalized;
}

function normalizeClaimsOffset(value: number | undefined): number {
  const normalized = value ?? 0;

  if (!Number.isSafeInteger(normalized) || normalized < 0) {
    throw new TypeError("offset must be a non-negative safe integer.");
  }

  return normalized;
}

function requireCampaignCode(value: string): string {
  const normalized = value.trim().toUpperCase();

  if (!normalized || !UPPER_CODE_PATTERN.test(normalized)) {
    throw new TypeError("campaignCode must be a valid uppercase code.");
  }

  return normalized;
}

function requireIdempotencyKey(value: string): string {
  const normalized = value.trim();

  if (normalized.length < 8 || normalized.length > 200) {
    throw new TypeError(
      "idempotencyKey must contain between 8 and 200 characters.",
    );
  }

  return normalized;
}

function normalizeExternalClaimReference(
  value: string | null | undefined,
): string | null {
  if (value === undefined || value === null) {
    return null;
  }

  const normalized = value.trim();

  if (normalized.length < 1 || normalized.length > 300) {
    throw new TypeError(
      "externalClaimReference must contain between 1 and 300 characters when present.",
    );
  }

  return normalized;
}

function normalizeEvidence(
  value: SubmitCommercialRewardClaimInput["evidence"],
) {
  const normalized = value ?? {};

  if (!isJsonObject(normalized)) {
    throw new TypeError("evidence must be a JSON object.");
  }

  return normalized;
}

export async function getRewardCampaigns(): Promise<CommercialRewardCampaigns> {
  const result = await callCommercialRuntimeRpc<unknown>(
    "get_reward_campaigns_rpc",
    {},
  );

  return normalizeRewardCampaigns(result.data);
}

export async function getMyRewardClaims(
  input: GetMyCommercialRewardClaimsInput = {},
): Promise<CommercialRewardClaims> {
  const limit = normalizeClaimsLimit(input.limit);

  const offset = normalizeClaimsOffset(input.offset);

  const result = await callCommercialRuntimeRpc<unknown>(
    "get_my_reward_claims_rpc",
    {
      p_limit: limit,
      p_offset: offset,
    },
  );

  return normalizeRewardClaims(result.data);
}

export async function getMyRewardClaim(
  input: GetMyCommercialRewardClaimInput,
): Promise<CommercialRewardClaimLookupResult> {
  const claimId = requireClaimId(input.claimId);

  const result = await callCommercialRuntimeRpc<unknown>(
    "get_my_reward_claim_rpc",
    {
      p_claim_id: claimId,
    },
  );

  return normalizeRewardClaimLookupResult(result.data);
}

export async function submitMyRewardClaim(
  input: SubmitCommercialRewardClaimInput,
): Promise<CommercialRewardClaimSubmissionResult> {
  const campaignCode = requireCampaignCode(input.campaignCode);

  const idempotencyKey = requireIdempotencyKey(input.idempotencyKey);

  const externalClaimReference = normalizeExternalClaimReference(
    input.externalClaimReference,
  );

  const evidence = normalizeEvidence(input.evidence);

  const result = await callCommercialRuntimeRpc<unknown>(
    "submit_my_reward_claim_rpc",
    {
      p_campaign_code: campaignCode,
      p_idempotency_key: idempotencyKey,
      p_external_claim_reference: externalClaimReference,
      p_evidence: evidence,
    },
  );

  return normalizeRewardClaimSubmissionResult(result.data);
}
