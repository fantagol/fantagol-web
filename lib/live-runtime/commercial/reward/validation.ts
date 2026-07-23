import type { JsonObject } from "../json";
import { isJsonObject } from "../json";
import type {
  CommercialRewardCampaign,
  CommercialRewardCampaigns,
  CommercialRewardType,
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
