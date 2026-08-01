export type AccountLifecycleActivationState = {
  activation_level: number;
  activation_mode: "certification" | "production" | "disabled" | "suspended";
  desired_state: string;
  observed_state: string;
  claims_enabled: boolean;
  workers_enabled: boolean;
  storage_provider_enabled: boolean;
  auth_provider_enabled: boolean;
  approved_account_lifecycle_id: string;
  approved_erasure_run_id: string;
  run_status: string;
  run_blocker_code: string | null;
  next_step_code: string | null;
  next_step_order: number | null;
  next_step_status: string | null;
  completed_step_count: number;
  external_command_count: number;
  external_attempt_count: number;
  external_receipt_count: number;
  server_time: string;
};

export type AccountLifecycleCertificationCycleResult = {
  result_code: string;
  correlation_id?: string;
  erasure_run_id?: string;
  run_status?: string;
  launch?: Record<string, unknown>;
  step?: Record<string, unknown>;
};
