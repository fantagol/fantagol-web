import {
  createPublicKey,
  createVerify,
} from "node:crypto";

import {
  ADMOB_REWARDED_EVENT_TYPE,
  ADMOB_REWARDED_SOURCE_CODE,
  normalizeAdMobRewardedSsvIdentity,
} from "./admob-ssv-contract";

export const ADMOB_SSV_PUBLIC_KEYS_URL =
  "https://www.gstatic.com/admob/reward/verifier-keys.json";

export const ADMOB_SSV_KEY_CACHE_TTL_MS =
  6 * 60 * 60 * 1000;

const SIGNATURE_MARKER =
  "&signature=";

const KEY_ID_MARKER =
  "&key_id=";

export type AdMobSsvVerificationFailureCode =
  | "SSV_QUERY_MISSING"
  | "SSV_SIGNATURE_MISSING"
  | "SSV_KEY_ID_MISSING"
  | "SSV_SIGNATURE_ORDER_INVALID"
  | "SSV_PARAMETER_MISSING"
  | "SSV_PARAMETER_INVALID"
  | "SSV_KEY_FETCH_FAILED"
  | "SSV_KEY_RESPONSE_INVALID"
  | "SSV_KEY_NOT_FOUND"
  | "SSV_SIGNATURE_INVALID";

export class AdMobSsvVerificationError
  extends Error {
  readonly code:
    AdMobSsvVerificationFailureCode;

  readonly retryable: boolean;

  constructor(
    code:
      AdMobSsvVerificationFailureCode,
    message: string,
    retryable = false,
  ) {
    super(message);

    this.name =
      "AdMobSsvVerificationError";

    this.code = code;
    this.retryable = retryable;
  }
}

export interface AdMobSsvPublicKeyRecord {
  readonly keyId: number;
  readonly pem: string;
}

interface AdMobSsvPublicKeyResponse {
  readonly keys:
    readonly AdMobSsvPublicKeyRecord[];
}

export interface AdMobSsvParsedEnvelope {
  readonly rawQuery: string;
  readonly signedContent: string;
  readonly signature: string;
  readonly keyId: number;
}

export interface VerifiedAdMobRewardedSsv {
  readonly verified: true;

  readonly sourceCode:
    typeof ADMOB_REWARDED_SOURCE_CODE;

  readonly providerEventType:
    typeof ADMOB_REWARDED_EVENT_TYPE;

  readonly providerEventId: string;

  readonly externalClaimReference:
    string | null;

  readonly providerUserId:
    string | null;

  readonly transactionId: string;
  readonly timestampMs: number;
  readonly adNetwork: string;
  readonly adUnit: string;
  readonly rewardAmount: string;
  readonly rewardItem: string;
  readonly keyId: number;

  readonly rawQuery: string;
  readonly signedContent: string;
}

export interface AdMobSsvVerifierDependencies {
  readonly fetchImpl?:
    typeof fetch;

  readonly now?:
    () => number;

  readonly publicKeysUrl?:
    string;
}

interface PublicKeyCache {
  expiresAt: number;
  keys:
    ReadonlyMap<
      number,
      string
    >;
}

let publicKeyCache:
  PublicKeyCache | null = null;

function decodeQueryComponent(
  value: string,
  fieldName: string,
): string {
  try {
    return decodeURIComponent(
      value.replace(/\+/g, "%20"),
    );
  }
  catch {
    throw new AdMobSsvVerificationError(
      "SSV_PARAMETER_INVALID",
      `Invalid percent encoding for ${fieldName}.`,
    );
  }
}

function requiredParameter(
  params: URLSearchParams,
  name: string,
): string {
  const value =
    params.get(name)?.trim() ?? "";

  if (!value) {
    throw new AdMobSsvVerificationError(
      "SSV_PARAMETER_MISSING",
      `Missing required SSV parameter: ${name}.`,
    );
  }

  return value;
}

function parsePositiveInteger(
  value: string,
  name: string,
): number {
  if (!/^\d+$/.test(value)) {
    throw new AdMobSsvVerificationError(
      "SSV_PARAMETER_INVALID",
      `${name} must be a positive integer.`,
    );
  }

  const parsed = Number(value);

  if (
    !Number.isSafeInteger(parsed) ||
    parsed < 0
  ) {
    throw new AdMobSsvVerificationError(
      "SSV_PARAMETER_INVALID",
      `${name} is outside the supported numeric range.`,
    );
  }

  return parsed;
}

export function parseAdMobSsvEnvelope(
  requestUrl: string,
): AdMobSsvParsedEnvelope {
  const questionMark =
    requestUrl.indexOf("?");

  if (
    questionMark < 0 ||
    questionMark ===
      requestUrl.length - 1
  ) {
    throw new AdMobSsvVerificationError(
      "SSV_QUERY_MISSING",
      "AdMob SSV callback query is missing.",
    );
  }

  const rawQuery =
    requestUrl.slice(
      questionMark + 1,
    );

  const signatureIndex =
    rawQuery.indexOf(
      SIGNATURE_MARKER,
    );

  if (signatureIndex < 0) {
    throw new AdMobSsvVerificationError(
      "SSV_SIGNATURE_MISSING",
      "AdMob SSV signature is missing.",
    );
  }

  const keyIdIndex =
    rawQuery.indexOf(
      KEY_ID_MARKER,
      signatureIndex +
        SIGNATURE_MARKER.length,
    );

  if (keyIdIndex < 0) {
    throw new AdMobSsvVerificationError(
      "SSV_KEY_ID_MISSING",
      "AdMob SSV key_id is missing.",
    );
  }

  const afterKeyId =
    rawQuery.slice(
      keyIdIndex +
        KEY_ID_MARKER.length,
    );

  if (
    afterKeyId.includes("&")
  ) {
    throw new AdMobSsvVerificationError(
      "SSV_SIGNATURE_ORDER_INVALID",
      "key_id must be the final SSV parameter.",
    );
  }

  const signedContent =
    rawQuery.slice(
      0,
      signatureIndex,
    );

  if (!signedContent) {
    throw new AdMobSsvVerificationError(
      "SSV_QUERY_MISSING",
      "Signed SSV content is empty.",
    );
  }

  const encodedSignature =
    rawQuery.slice(
      signatureIndex +
        SIGNATURE_MARKER.length,
      keyIdIndex,
    );

  const encodedKeyId =
    afterKeyId;

  if (!encodedSignature) {
    throw new AdMobSsvVerificationError(
      "SSV_SIGNATURE_MISSING",
      "AdMob SSV signature is empty.",
    );
  }

  if (!encodedKeyId) {
    throw new AdMobSsvVerificationError(
      "SSV_KEY_ID_MISSING",
      "AdMob SSV key_id is empty.",
    );
  }

  const signature =
    decodeQueryComponent(
      encodedSignature,
      "signature",
    );

  const keyIdText =
    decodeQueryComponent(
      encodedKeyId,
      "key_id",
    );

  const keyId =
    parsePositiveInteger(
      keyIdText,
      "key_id",
    );

  return Object.freeze({
    rawQuery,
    signedContent,
    signature,
    keyId,
  });
}

function decodeUrlSafeBase64(
  value: string,
): Buffer {
  const normalized =
    value
      .replace(/-/g, "+")
      .replace(/_/g, "/");

  const padding =
    normalized.length % 4;

  const padded =
    padding === 0
      ? normalized
      : normalized +
        "=".repeat(4 - padding);

  try {
    const result =
      Buffer.from(
        padded,
        "base64",
      );

    if (result.length === 0) {
      throw new Error(
        "Decoded signature is empty.",
      );
    }

    return result;
  }
  catch {
    throw new AdMobSsvVerificationError(
      "SSV_SIGNATURE_INVALID",
      "AdMob SSV signature is not valid URL-safe base64.",
    );
  }
}

async function fetchAdMobPublicKeys(
  dependencies:
    AdMobSsvVerifierDependencies,
): Promise<
  ReadonlyMap<
    number,
    string
  >
> {
  const fetchImpl =
    dependencies.fetchImpl ??
    fetch;

  const now =
    dependencies.now ??
    Date.now;

  const currentTime =
    now();

  if (
    publicKeyCache &&
    publicKeyCache.expiresAt >
      currentTime
  ) {
    return publicKeyCache.keys;
  }

  const response =
    await fetchImpl(
      dependencies.publicKeysUrl ??
        ADMOB_SSV_PUBLIC_KEYS_URL,
      {
        method: "GET",
        cache: "no-store",
        headers: {
          accept:
            "application/json",
        },
      },
    ).catch((error) => {
      throw new AdMobSsvVerificationError(
        "SSV_KEY_FETCH_FAILED",
        error instanceof Error
          ? error.message
          : "Unable to fetch AdMob public keys.",
        true,
      );
    });

  if (!response.ok) {
    throw new AdMobSsvVerificationError(
      "SSV_KEY_FETCH_FAILED",
      `AdMob key server returned HTTP ${response.status}.`,
      true,
    );
  }

  let payload:
    AdMobSsvPublicKeyResponse;

  try {
    payload =
      await response.json() as
        AdMobSsvPublicKeyResponse;
  }
  catch {
    throw new AdMobSsvVerificationError(
      "SSV_KEY_RESPONSE_INVALID",
      "AdMob public-key response is not valid JSON.",
      true,
    );
  }

  if (
    !payload ||
    !Array.isArray(payload.keys) ||
    payload.keys.length === 0
  ) {
    throw new AdMobSsvVerificationError(
      "SSV_KEY_RESPONSE_INVALID",
      "AdMob public-key response contains no keys.",
      true,
    );
  }

  const keys =
    new Map<number, string>();

  for (
    const candidate
    of payload.keys
  ) {
    if (
      !candidate ||
      !Number.isSafeInteger(
        candidate.keyId,
      ) ||
      candidate.keyId < 0 ||
      typeof candidate.pem !==
        "string" ||
      !candidate.pem.includes(
        "BEGIN PUBLIC KEY",
      )
    ) {
      throw new AdMobSsvVerificationError(
        "SSV_KEY_RESPONSE_INVALID",
        "AdMob public-key response contains an invalid key.",
        true,
      );
    }

    keys.set(
      candidate.keyId,
      candidate.pem,
    );
  }

  publicKeyCache =
    Object.freeze({
      expiresAt:
        currentTime +
        ADMOB_SSV_KEY_CACHE_TTL_MS,
      keys,
    });

  return keys;
}

function verifySignature(
  signedContent: string,
  signature: string,
  pem: string,
): void {
  const verifier =
    createVerify("SHA256");

  verifier.update(
    signedContent,
    "utf8",
  );

  verifier.end();

  let verified = false;

  try {
    verified =
      verifier.verify(
        createPublicKey(pem),
        decodeUrlSafeBase64(
          signature,
        ),
      );
  }
  catch {
    verified = false;
  }

  if (!verified) {
    throw new AdMobSsvVerificationError(
      "SSV_SIGNATURE_INVALID",
      "AdMob SSV signature verification failed.",
    );
  }
}

export async function verifyAdMobRewardedSsv(
  requestUrl: string,
  dependencies:
    AdMobSsvVerifierDependencies = {},
): Promise<
  VerifiedAdMobRewardedSsv
> {
  const envelope =
    parseAdMobSsvEnvelope(
      requestUrl,
    );

  const publicKeys =
    await fetchAdMobPublicKeys(
      dependencies,
    );

  const publicKey =
    publicKeys.get(
      envelope.keyId,
    );

  if (!publicKey) {
    throw new AdMobSsvVerificationError(
      "SSV_KEY_NOT_FOUND",
      `No AdMob public key for key_id ${envelope.keyId}.`,
      true,
    );
  }

  verifySignature(
    envelope.signedContent,
    envelope.signature,
    publicKey,
  );

  // Parsing happens only AFTER verification.
  const params =
    new URLSearchParams(
      envelope.signedContent,
    );

  const transactionId =
    requiredParameter(
      params,
      "transaction_id",
    );

  const timestampText =
    requiredParameter(
      params,
      "timestamp",
    );

  const timestampMs =
    parsePositiveInteger(
      timestampText,
      "timestamp",
    );

  const adNetwork =
    requiredParameter(
      params,
      "ad_network",
    );

  const adUnit =
    requiredParameter(
      params,
      "ad_unit",
    );

  const rewardAmount =
    requiredParameter(
      params,
      "reward_amount",
    );

  const rewardItem =
    requiredParameter(
      params,
      "reward_item",
    );

  const customData =
    params.get("custom_data");

  const userId =
    params.get("user_id");

  const identity =
    normalizeAdMobRewardedSsvIdentity({
      transaction_id:
        transactionId,
      custom_data:
        customData,
      user_id:
        userId,
    });

  return Object.freeze({
    verified: true,

    sourceCode:
      ADMOB_REWARDED_SOURCE_CODE,

    providerEventType:
      ADMOB_REWARDED_EVENT_TYPE,

    providerEventId:
      identity.providerEventId,

    externalClaimReference:
      identity.externalClaimReference,

    providerUserId:
      identity.providerUserId,

    transactionId,
    timestampMs,
    adNetwork,
    adUnit,
    rewardAmount,
    rewardItem,
    keyId:
      envelope.keyId,

    rawQuery:
      envelope.rawQuery,

    signedContent:
      envelope.signedContent,
  });
}

export function resetAdMobSsvPublicKeyCacheForTests():
  void {
  publicKeyCache = null;
}
