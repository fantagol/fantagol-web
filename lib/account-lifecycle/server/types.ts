import type { SupabaseClient } from "@supabase/supabase-js";

export type AccountErasureCommandType =
  | "DELETE_STORAGE_ASSETS"
  | "DELETE_SUPABASE_AUTH_IDENTITY";

export type AccountErasureReceiptStatus =
  | "verified_success"
  | "verified_already_absent";

export type JsonObject = Record<string, unknown>;

export type PreparedExternalCommand = {
  commandId: string;
  commandType: AccountErasureCommandType;
  commandStatus: string;
  providerCode: string;
  providerOperation: string;
  requestDigest: string;
  idempotencyKey: string;
  restrictedPayload: JsonObject;
};

export type ClaimedExternalCommand = PreparedExternalCommand & {
  attemptId: string;
  attemptNumber: number;
  leaseToken: string;
  leaseExpiresAt: string;
};

export type StorageCommandTarget = {
  bucketCode: string;
  authUserId: string | null;
  normalizedPaths: string[];
  candidateCount: number;
  requiresResidualScan: boolean;
};

export type AuthCommandTarget = {
  authUserId: string;
  hardDelete: true;
};

export type StorageExecutionResult = {
  status: AccountErasureReceiptStatus;
  providerRequestId: string | null;
  resultDigest: string;
  affectedObjectCount: number;
  residualObjectCount: number;
  publicEvidence: JsonObject;
  restrictedEvidence: JsonObject;
};

export type AuthExecutionResult = {
  status: AccountErasureReceiptStatus;
  providerRequestId: string | null;
  resultDigest: string;
  affectedObjectCount: number;
  residualObjectCount: null;
  publicEvidence: JsonObject;
  restrictedEvidence: JsonObject;
};

export type ExternalCommandExecutionResult = {
  accepted: boolean;
  commandId: string;
  commandType: AccountErasureCommandType;
  attemptId: string;
  receiptId: string;
  receiptType: string;
  status: "completed";
  correlationId: string;
};

export type AccountErasureWorkerDependencies = {
  client: SupabaseClient;
  workerId: string;
  logger?: AccountErasureLogger;
};

export type AccountErasureLogger = {
  info(message: string, fields?: JsonObject): void;
  warn(message: string, fields?: JsonObject): void;
  error(message: string, fields?: JsonObject): void;
};
