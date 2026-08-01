import type { SupabaseClient } from "@supabase/supabase-js";

import {
  AccountErasureAmbiguousResultError,
  AccountErasureProviderError,
} from "./errors";
import { digestJson } from "./contracts";
import type {
  AuthCommandTarget,
  AuthExecutionResult,
} from "./types";

function isUserNotFound(message: string): boolean {
  const normalized = message.toLowerCase();

  return (
    normalized.includes("user not found") ||
    normalized.includes("not found")
  );
}

async function authUserExists(
  client: SupabaseClient,
  authUserId: string,
): Promise<boolean> {
  const { data, error } =
    await client.auth.admin.getUserById(authUserId);

  if (error) {
    if (isUserNotFound(error.message)) return false;

    throw new AccountErasureProviderError(
      "AUTH_USER_LOOKUP_FAILED",
      "Unable to verify the Supabase Auth identity.",
      { retryable: true, cause: error },
    );
  }

  return Boolean(data.user);
}

export async function executeAuthDeletion(
  client: SupabaseClient,
  target: AuthCommandTarget,
): Promise<AuthExecutionResult> {
  const existedBefore = await authUserExists(client, target.authUserId);

  if (existedBefore) {
    const { error } = await client.auth.admin.deleteUser(
      target.authUserId,
      false,
    );

    if (error) {
      throw new AccountErasureAmbiguousResultError(
        "AUTH_DELETE_RESULT_AMBIGUOUS",
        "Supabase Auth deletion did not return a verified success.",
        { retryable: true, cause: error },
      );
    }
  }

  const existsAfter = await authUserExists(client, target.authUserId);

  if (existsAfter) {
    throw new AccountErasureProviderError(
      "AUTH_DELETE_FAILED",
      "Supabase Auth identity still exists after deletion.",
      { retryable: true },
    );
  }

  return {
    status: existedBefore
      ? "verified_success"
      : "verified_already_absent",
    providerRequestId: null,
    resultDigest: digestJson({
      provider: "supabase_auth",
      operation: "admin.deleteUser",
      verifiedAbsent: true,
    }),
    affectedObjectCount: existedBefore ? 1 : 0,
    residualObjectCount: null,
    publicEvidence: {
      verified_absent: true,
      provider_code: "supabase_auth",
      provider_operation: "admin.deleteUser",
      hard_delete: true,
    },
    restrictedEvidence: {
      deleted_auth_user_id: target.authUserId,
    },
  };
}
