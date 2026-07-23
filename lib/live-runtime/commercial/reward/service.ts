import "server-only";

import { isJsonObject } from "../json";
import { callCommercialRuntimeRpc } from "../rpc";
import type {
  CommercialRewardCampaigns,
  CommercialRewardClaimSubmissionResult,
  SubmitCommercialRewardClaimInput,
} from "./types";
import {
  normalizeRewardCampaigns,
  normalizeRewardClaimSubmissionResult,
} from "./validation";

const UPPER_CODE_PATTERN =
  /^[A-Z][A-Z0-9_]+$/;

function requireCampaignCode(
  value: string,
): string {
  const normalized =
    value.trim().toUpperCase();

  if (
    !normalized ||
    !UPPER_CODE_PATTERN.test(normalized)
  ) {
    throw new TypeError(
      "campaignCode must be a valid uppercase code.",
    );
  }

  return normalized;
}

function requireIdempotencyKey(
  value: string,
): string {
  const normalized = value.trim();

  if (
    normalized.length < 8 ||
    normalized.length > 200
  ) {
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

  if (
    normalized.length < 1 ||
    normalized.length > 300
  ) {
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
    throw new TypeError(
      "evidence must be a JSON object.",
    );
  }

  return normalized;
}

export async function getRewardCampaigns(): Promise<CommercialRewardCampaigns> {
  const result =
    await callCommercialRuntimeRpc<unknown>(
      "get_reward_campaigns_rpc",
      {},
    );

  return normalizeRewardCampaigns(
    result.data,
  );
}

export async function submitMyRewardClaim(
  input: SubmitCommercialRewardClaimInput,
): Promise<CommercialRewardClaimSubmissionResult> {
  const campaignCode =
    requireCampaignCode(
      input.campaignCode,
    );

  const idempotencyKey =
    requireIdempotencyKey(
      input.idempotencyKey,
    );

  const externalClaimReference =
    normalizeExternalClaimReference(
      input.externalClaimReference,
    );

  const evidence =
    normalizeEvidence(
      input.evidence,
    );

  const result =
    await callCommercialRuntimeRpc<unknown>(
      "submit_my_reward_claim_rpc",
      {
        p_campaign_code: campaignCode,
        p_idempotency_key: idempotencyKey,
        p_external_claim_reference:
          externalClaimReference,
        p_evidence: evidence,
      },
    );

  return normalizeRewardClaimSubmissionResult(
    result.data,
  );
}
