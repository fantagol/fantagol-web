import type { SupabaseClient } from "@supabase/supabase-js";

import {
  AccountErasureContractError,
  AccountErasureProviderError,
} from "./errors";
import { digestJson } from "./contracts";
import type {
  StorageCommandTarget,
  StorageExecutionResult,
} from "./types";

const APPROVED_BUCKETS = new Set(["club-avatars"]);
const PUBLIC_OBJECT_MARKER = "/storage/v1/object/public/";

export function normalizeStoragePath(
  value: string,
  bucketCode: string,
): string {
  let candidate = value.trim();

  if (candidate.includes("://")) {
    const url = new URL(candidate);
    const markerIndex = url.pathname.indexOf(PUBLIC_OBJECT_MARKER);

    if (markerIndex < 0) {
      throw new AccountErasureContractError(
        "STORAGE_PATH_INVALID",
        "Storage URL does not use the approved public-object format.",
      );
    }

    const remainder = decodeURIComponent(
      url.pathname.slice(markerIndex + PUBLIC_OBJECT_MARKER.length),
    );
    const prefix = `${bucketCode}/`;

    if (!remainder.startsWith(prefix)) {
      throw new AccountErasureContractError(
        "STORAGE_BUCKET_NOT_ALLOWED",
        "Storage URL targets a different bucket.",
      );
    }

    candidate = remainder.slice(prefix.length);
  }

  candidate = decodeURIComponent(candidate).replace(/^\/+/, "");

  if (
    candidate === "" ||
    candidate.includes("\0") ||
    candidate.split("/").some((part) => part === "..")
  ) {
    throw new AccountErasureContractError(
      "STORAGE_PATH_INVALID",
      "Storage object path is invalid.",
    );
  }

  return candidate;
}

export function normalizeStoragePaths(
  paths: string[],
  bucketCode: string,
): string[] {
  if (!APPROVED_BUCKETS.has(bucketCode)) {
    throw new AccountErasureContractError(
      "STORAGE_BUCKET_NOT_ALLOWED",
      "Storage bucket is not approved for account erasure.",
    );
  }

  return [...new Set(paths.map((path) =>
    normalizeStoragePath(path, bucketCode),
  ))].sort();
}

async function listUserPrefix(
  client: SupabaseClient,
  bucketCode: string,
  authUserId: string,
): Promise<string[]> {
  const { data, error } = await client.storage
    .from(bucketCode)
    .list(authUserId, {
      limit: 1000,
      offset: 0,
      sortBy: { column: "name", order: "asc" },
    });

  if (error) {
    throw new AccountErasureProviderError(
      "STORAGE_LIST_FAILED",
      "Unable to list account Storage assets.",
      { retryable: true, cause: error },
    );
  }

  return (data ?? []).map((item) => `${authUserId}/${item.name}`);
}

export async function executeStorageDeletion(
  client: SupabaseClient,
  target: StorageCommandTarget,
): Promise<StorageExecutionResult> {
  const discovered =
    target.authUserId === null
      ? []
      : await listUserPrefix(
          client,
          target.bucketCode,
          target.authUserId,
        );

  const normalized = normalizeStoragePaths(
    [...target.normalizedPaths, ...discovered],
    target.bucketCode,
  );

  for (let offset = 0; offset < normalized.length; offset += 100) {
    const batch = normalized.slice(offset, offset + 100);
    const { error } = await client.storage
      .from(target.bucketCode)
      .remove(batch);

    if (error) {
      throw new AccountErasureProviderError(
        "STORAGE_DELETE_FAILED",
        "Unable to remove account Storage assets.",
        { retryable: true, cause: error },
      );
    }
  }

  const residual =
    target.requiresResidualScan && target.authUserId
      ? await listUserPrefix(
          client,
          target.bucketCode,
          target.authUserId,
        )
      : [];

  if (residual.length > 0) {
    throw new AccountErasureProviderError(
      "STORAGE_RESIDUAL_OBJECTS",
      "Storage residual objects remain after deletion.",
      { retryable: true },
    );
  }

  const resultDigest = digestJson({
    bucketCode: target.bucketCode,
    normalizedPaths: normalized,
    residualCount: residual.length,
  });

  return {
    status:
      normalized.length === 0
        ? "verified_already_absent"
        : "verified_success",
    providerRequestId: null,
    resultDigest,
    affectedObjectCount: normalized.length,
    residualObjectCount: 0,
    publicEvidence: {
      bucket_code: target.bucketCode,
      candidate_count: normalized.length,
      deleted_count: normalized.length,
      residual_count: 0,
      path_digest: digestJson(normalized),
    },
    restrictedEvidence: {
      normalized_paths: normalized,
    },
  };
}
