export type AccountDeletionLifecycleStatus =
  | "active"
  | "delete_requested"
  | "deletion_scheduled"
  | "erasure_running"
  | "erasure_blocked"
  | "deleted"
  | "deletion_cancelled"
  | "deletion_failed";

export type AccountDeletionFrontendState = {
  lifecycle_status: AccountDeletionLifecycleStatus;
  has_open_request: boolean;
  request_status: string | null;
  requested_at: string | null;
  scheduled_for: string | null;
  cancellation_allowed: boolean;
  cooling_off_seconds_remaining: number;
  cooling_off_seconds: number | null;
  automatic_execution_enabled: boolean;
  request_enabled: boolean;
  public_request_enabled: boolean;
  confirmation_phrase: string;
  reauthentication_methods: string[];
  policy_code: string | null;
  policy_version: number | null;
  blocked: boolean;
  blocker_code: string | null;
  failed: boolean;
  failure_code: string | null;
  engine_lifecycle_status: string;
  engine_runtime_enabled: boolean;
  engine_certified: boolean;
  erasure_execution_enabled: boolean;
  frontend_contract_version: string;
};

export type AccountDeletionPolicy = {
  policy_code: string;
  policy_version: number;
  display_name: string;
  description: string | null;
  cooling_off_seconds: number;
  public_request_enabled: boolean;
  authenticated_request_enabled: boolean;
  automatic_execution_enabled: boolean;
  confirmation_phrase: string;
  data_handling: {
    auth_identity: string;
    direct_personal_data: string;
    competitive_history: string;
    commercial_evidence: string;
  };
};

export type ReauthGrantResponse = {
  grantToken: string;
  expiresAt: string;
  confirmationMethod:
    | "password_reauthentication"
    | "oauth_reauthentication";
};
