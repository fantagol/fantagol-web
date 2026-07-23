import type { JsonObject } from "../json";
import { isJsonObject } from "../json";
import type {
  CommercialRewardCampaign,
  CommercialRewardCampaigns,
  CommercialRewardClaimStatus,
  CommercialRewardClaimSubmissionErrorCode,
  CommercialRewardClaimSubmissionResult,
  CommercialRewardType,
  CommercialRewardVerificationStatus,
} from "./types";

type UnknownObject = Record<string, unknown>;

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

const UPPER_CODE_PATTERN =
  /^[A-Z][A-Z0-9_]+$/;

const REWARD_TYPES =
  new Set<CommercialRewardType>([
    "PASS_REWARD",
    "PASS_PROMOTION",
    "PASS_GIFT",
    "PASS_REFERRAL",
  ]);

const CLAIM_STATUSES =
  new Set<CommercialRewardClaimStatus>([
    "submitted",
    "verification_pending",
    "verified",
    "rejected",
    "settled",
    "expired",
  ]);

const VERIFICATION_STATUSES =
  new Set<CommercialRewardVerificationStatus>([
    "pending",
    "processing",
    "verified",
    "rejected",
    "expired",
  ]);

const SUBMISSION_ERROR_CODES =
  new Set<CommercialRewardClaimSubmissionErrorCode>([
    "REWARD_CAMPAIGN_NOT_AVAILABLE",
    "REWARD_SOURCE_NOT_AVAILABLE",
    "REWARD_USER_CLAIM_LIMIT_REACHED",
    "REWARD_CLAIM_COOLDOWN_ACTIVE",
    "COMMERCIAL_WALLET_NOT_ACTIVE",
  ]);

function requireObject(
  value: unknown,
  context: string,
): JsonObject {
  if (!isJsonObject(value)) {
    throw new TypeError(
      `${context} must be a JSON object.`,
    );
  }

  return value;
}

function requireArray(
  value: unknown,
  context: string,
): unknown[] {
  if (!Array.isArray(value)) {
    throw new TypeError(
      `${context} must be an array.`,
    );
  }

  return value;
}

function requireBoolean(
  object: UnknownObject,
  fieldName: string,
  context: string,
): boolean {
  const value = object[fieldName];

  if (typeof value !== "boolean") {
    throw new TypeError(
      `${context}.${fieldName} must be a boolean.`,
    );
  }

  return value;
}

function requireLiteralTrue(
  object: UnknownObject,
  fieldName: string,
  context: string,
): true {
  if (
    requireBoolean(
      object,
      fieldName,
      context,
    ) !== true
  ) {
    throw new TypeError(
      `${context}.${fieldName} must be true.`,
    );
  }

  return true;
}

function requireLiteralFalse(
  object: UnknownObject,
  fieldName: string,
  context: string,
): false {
  if (
    requireBoolean(
      object,
      fieldName,
      context,
    ) !== false
  ) {
    throw new TypeError(
      `${context}.${fieldName} must be false.`,
    );
  }

  return false;
}

function requireUuid(
  object: UnknownObject,
  fieldName: string,
  context: string,
): string {
  const value = object[fieldName];

  if (
    typeof value !== "string" ||
    !UUID_PATTERN.test(value.trim())
  ) {
    throw new TypeError(
      `${context}.${fieldName} must be a valid UUID.`,
    );
  }

  return value.trim();
}

function requireNonEmptyString(
  object: UnknownObject,
  fieldName: string,
  context: string,
): string {
  const value = object[fieldName];

  if (
    typeof value !== "string" ||
    !value.trim()
  ) {
    throw new TypeError(
      `${context}.${fieldName} must be a non-empty string.`,
    );
  }

  return value;
}

function requireOptionalNonEmptyString(
  object: UnknownObject,
  fieldName: string,
  context: string,
): string | undefined {
  const value = object[fieldName];

  if (value === undefined) {
    return undefined;
  }

  if (
    typeof value !== "string" ||
    !value.trim()
  ) {
    throw new TypeError(
      `${context}.${fieldName} must be a non-empty string when present.`,
    );
  }

  return value;
}

function requireNullableString(
  object: UnknownObject,
  fieldName: string,
  context: string,
): string | null {
  const value = object[fieldName];

  if (value === null) {
    return null;
  }

  if (
    typeof value !== "string" ||
    !value.trim()
  ) {
    throw new TypeError(
      `${context}.${fieldName} must be a non-empty string or null.`,
    );
  }

  return value;
}

function requireUpperCode(
  object: UnknownObject,
  fieldName: string,
  context: string,
): string {
  const value = requireNonEmptyString(
    object,
    fieldName,
    context,
  );

  if (!UPPER_CODE_PATTERN.test(value)) {
    throw new TypeError(
      `${context}.${fieldName} must be an uppercase code.`,
    );
  }

  return value;
}

function requireOptionalUpperCode(
  object: UnknownObject,
  fieldName: string,
  context: string,
): string | undefined {
  const value = requireOptionalNonEmptyString(
    object,
    fieldName,
    context,
  );

  if (value === undefined) {
    return undefined;
  }

  if (!UPPER_CODE_PATTERN.test(value)) {
    throw new TypeError(
      `${context}.${fieldName} must be an uppercase code when present.`,
    );
  }

  return value;
}

function requireRewardType(
  value: unknown,
  context: string,
): CommercialRewardType {
  if (
    typeof value !== "string" ||
    !REWARD_TYPES.has(
      value as CommercialRewardType,
    )
  ) {
    throw new TypeError(
      `${context} is invalid.`,
    );
  }

  return value as CommercialRewardType;
}

function requireClaimStatus(
  value: unknown,
  context: string,
): CommercialRewardClaimStatus {
  if (
    typeof value !== "string" ||
    !CLAIM_STATUSES.has(
      value as CommercialRewardClaimStatus,
    )
  ) {
    throw new TypeError(
      `${context} is invalid.`,
    );
  }

  return value as CommercialRewardClaimStatus;
}

function requireVerificationStatus(
  value: unknown,
  context: string,
): CommercialRewardVerificationStatus {
  if (
    typeof value !== "string" ||
    !VERIFICATION_STATUSES.has(
      value as CommercialRewardVerificationStatus,
    )
  ) {
    throw new TypeError(
      `${context} is invalid.`,
    );
  }

  return value as CommercialRewardVerificationStatus;
}

function requireSubmissionErrorCode(
  value: unknown,
  context: string,
): CommercialRewardClaimSubmissionErrorCode {
  if (
    typeof value !== "string" ||
    !SUBMISSION_ERROR_CODES.has(
      value as CommercialRewardClaimSubmissionErrorCode,
    )
  ) {
    throw new TypeError(
      `${context} is invalid.`,
    );
  }

  return value as CommercialRewardClaimSubmissionErrorCode;
}

function requirePositiveSafeInteger(
  object: UnknownObject,
  fieldName: string,
  context: string,
): number {
  const value = object[fieldName];

  if (
    typeof value !== "number" ||
    !Number.isSafeInteger(value) ||
    value < 1
  ) {
    throw new TypeError(
      `${context}.${fieldName} must be a positive safe integer.`,
    );
  }

  return value;
}

function requireNonNegativeSafeInteger(
  object: UnknownObject,
  fieldName: string,
  context: string,
): number {
  const value = object[fieldName];

  if (
    typeof value !== "number" ||
    !Number.isSafeInteger(value) ||
    value < 0
  ) {
    throw new TypeError(
      `${context}.${fieldName} must be a non-negative safe integer.`,
    );
  }

  return value;
}

function requireTimestamp(
  object: UnknownObject,
  fieldName: string,
  context: string,
): string {
  const value = object[fieldName];

  if (
    typeof value !== "string" ||
    !value.trim() ||
    Number.isNaN(Date.parse(value))
  ) {
    throw new TypeError(
      `${context}.${fieldName} must be a valid timestamp.`,
    );
  }

  return value;
}

function requireOptionalTimestamp(
  object: UnknownObject,
  fieldName: string,
  context: string,
): string | undefined {
  const value = object[fieldName];

  if (value === undefined) {
    return undefined;
  }

  if (
    typeof value !== "string" ||
    !value.trim() ||
    Number.isNaN(Date.parse(value))
  ) {
    throw new TypeError(
      `${context}.${fieldName} must be a valid timestamp when present.`,
    );
  }

  return value;
}

function requireNullableTimestamp(
  object: UnknownObject,
  fieldName: string,
  context: string,
): string | null {
  const value = object[fieldName];

  if (value === null) {
    return null;
  }

  if (
    typeof value !== "string" ||
    !value.trim() ||
    Number.isNaN(Date.parse(value))
  ) {
    throw new TypeError(
      `${context}.${fieldName} must be a valid timestamp or null.`,
    );
  }

  return value;
}

function normalizeRewardCampaign(
  value: unknown,
  index: number,
): CommercialRewardCampaign {
  const context =
    `reward_campaigns[${index}]`;

  const object = requireObject(
    value,
    context,
  );

  const startsAt = requireNullableTimestamp(
    object,
    "starts_at",
    context,
  );

  const endsAt = requireNullableTimestamp(
    object,
    "ends_at",
    context,
  );

  if (
    startsAt !== null &&
    endsAt !== null &&
    Date.parse(startsAt) >= Date.parse(endsAt)
  ) {
    throw new TypeError(
      `${context}.ends_at must be later than starts_at.`,
    );
  }

  return {
    ...object,
    campaign_id: requireUuid(
      object,
      "campaign_id",
      context,
    ),
    campaign_code: requireUpperCode(
      object,
      "campaign_code",
      context,
    ),
    source_code: requireUpperCode(
      object,
      "source_code",
      context,
    ),
    title: requireNonEmptyString(
      object,
      "title",
      context,
    ),
    description: requireNullableString(
      object,
      "description",
      context,
    ),
    reward_type: requireRewardType(
      object.reward_type,
      `${context}.reward_type`,
    ),
    passes_per_claim:
      requirePositiveSafeInteger(
        object,
        "passes_per_claim",
        context,
      ),
    cooldown_seconds:
      requireNonNegativeSafeInteger(
        object,
        "cooldown_seconds",
        context,
      ),
    starts_at: startsAt,
    ends_at: endsAt,
    metadata: requireObject(
      object.metadata,
      `${context}.metadata`,
    ),
  };
}

export function normalizeRewardCampaigns(
  value: unknown,
): CommercialRewardCampaigns {
  return requireArray(
    value,
    "reward_campaigns",
  ).map(normalizeRewardCampaign);
}

export function normalizeRewardClaimSubmissionResult(
  value: unknown,
): CommercialRewardClaimSubmissionResult {
  const context =
    "reward_claim_submission";

  const object = requireObject(
    value,
    context,
  );

  if (object.submitted === true) {
    const sourceCode =
      requireOptionalUpperCode(
        object,
        "source_code",
        context,
      );

    return {
      ...object,
      submitted: requireLiteralTrue(
        object,
        "submitted",
        context,
      ),
      created: requireBoolean(
        object,
        "created",
        context,
      ),
      claim_id: requireUuid(
        object,
        "claim_id",
        context,
      ),
      claim_status: requireClaimStatus(
        object.claim_status,
        `${context}.claim_status`,
      ),
      verification_status:
        requireVerificationStatus(
          object.verification_status,
          `${context}.verification_status`,
        ),
      campaign_code: requireUpperCode(
        object,
        "campaign_code",
        context,
      ),
      ...(sourceCode === undefined
        ? {}
        : { source_code: sourceCode }),
      passes: requirePositiveSafeInteger(
        object,
        "passes",
        context,
      ),
      server_time: requireTimestamp(
        object,
        "server_time",
        context,
      ),
    };
  }

  if (object.submitted === false) {
    const campaignCode =
      requireOptionalUpperCode(
        object,
        "campaign_code",
        context,
      );

    const sourceCode =
      requireOptionalUpperCode(
        object,
        "source_code",
        context,
      );

    const retryAfter =
      requireOptionalTimestamp(
        object,
        "retry_after",
        context,
      );

    return {
      ...object,
      submitted: requireLiteralFalse(
        object,
        "submitted",
        context,
      ),
      error_code:
        requireSubmissionErrorCode(
          object.error_code,
          `${context}.error_code`,
        ),
      ...(campaignCode === undefined
        ? {}
        : { campaign_code: campaignCode }),
      ...(sourceCode === undefined
        ? {}
        : { source_code: sourceCode }),
      ...(retryAfter === undefined
        ? {}
        : { retry_after: retryAfter }),
      server_time: requireTimestamp(
        object,
        "server_time",
        context,
      ),
    };
  }

  throw new TypeError(
    `${context}.submitted must be a boolean.`,
  );
}
