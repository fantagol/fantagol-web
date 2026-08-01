import { supabase } from "../supabaseClient";
import type {
  AccountDeletionFrontendState,
  AccountDeletionPolicy,
  ReauthGrantResponse,
} from "./types";

function requireData<T>(data: T | null, message: string): T {
  if (data === null) {
    throw new Error(message);
  }

  return data;
}

export async function getPublicAccountDeletionPolicy() {
  const { data, error } = await supabase.rpc(
    "get_account_deletion_public_policy_rpc",
  );

  if (error) throw error;
  return requireData(
    data as AccountDeletionPolicy | null,
    "Policy di eliminazione non disponibile.",
  );
}

export async function getMyAccountDeletionFrontendState() {
  const { data, error } = await supabase.rpc(
    "get_my_account_deletion_frontend_state_rpc",
  );

  if (error) throw error;
  return requireData(
    data as AccountDeletionFrontendState | null,
    "Stato account non disponibile.",
  );
}

export async function requestReauthGrant(input: {
  mode: "password" | "oauth_recent";
  password?: string;
}): Promise<ReauthGrantResponse> {
  const {
    data: { session },
    error: sessionError,
  } = await supabase.auth.getSession();

  if (sessionError) throw sessionError;
  if (!session?.access_token) {
    throw new Error("Sessione non disponibile. Accedi nuovamente.");
  }

  const response = await fetch("/api/account-lifecycle/reauth", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${session.access_token}`,
    },
    body: JSON.stringify(input),
  });

  const payload = (await response.json()) as {
    grantToken?: string;
    expiresAt?: string;
    confirmationMethod?: ReauthGrantResponse["confirmationMethod"];
    error?: string;
  };

  if (!response.ok) {
    throw new Error(payload.error || "Ri-autenticazione non riuscita.");
  }

  if (
    !payload.grantToken ||
    !payload.expiresAt ||
    !payload.confirmationMethod
  ) {
    throw new Error("Grant di ri-autenticazione non valido.");
  }

  return {
    grantToken: payload.grantToken,
    expiresAt: payload.expiresAt,
    confirmationMethod: payload.confirmationMethod,
  };
}

export async function requestMyAccountDeletion(input: {
  confirmationPhrase: string;
  reauthGrantToken: string;
  requestChannel: "authenticated_web" | "android_app";
}) {
  const { data, error } = await supabase.rpc(
    "request_my_account_deletion_rpc",
    {
      p_confirmation_phrase: input.confirmationPhrase,
      p_reauth_grant_token: input.reauthGrantToken,
      p_idempotency_key: crypto.randomUUID(),
      p_request_channel: input.requestChannel,
    },
  );

  if (error) throw error;
  return data as AccountDeletionFrontendState;
}

export async function cancelMyAccountDeletion() {
  const { data, error } = await supabase.rpc(
    "cancel_my_account_deletion_rpc",
    {
      p_idempotency_key: crypto.randomUUID(),
      p_cancellation_reason_code: "USER_REVOKED_FROM_FRONTEND",
    },
  );

  if (error) throw error;
  return data as AccountDeletionFrontendState;
}
