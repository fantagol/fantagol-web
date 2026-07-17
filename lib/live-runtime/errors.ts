export type LiveRuntimeErrorCode =
  | "LIVE_RUNTIME_INVALID_MATCH"
  | "LIVE_RUNTIME_INVALID_DATE"
  | "LIVE_RUNTIME_INVALID_SCORE"
  | "LIVE_RUNTIME_INVALID_PAYLOAD_HASH"
  | "LIVE_RUNTIME_INVALID_JOB_PAYLOAD"
  | "LIVE_RUNTIME_UNSUPPORTED_JOB"
  | "LIVE_RUNTIME_UNSUPPORTED_STATUS"
  | "LIVE_RUNTIME_CONFIGURATION_ERROR"
  | "LIVE_RUNTIME_RPC_ERROR"
  | "LIVE_RUNTIME_INVALID_RPC_RESPONSE";

export class LiveRuntimeError extends Error {
  readonly code: LiveRuntimeErrorCode;
  readonly details?: Record<string, unknown>;

  constructor(input: {
    code: LiveRuntimeErrorCode;
    message: string;
    details?: Record<string, unknown>;
    cause?: unknown;
  }) {
    super(input.message, { cause: input.cause });
    this.name = "LiveRuntimeError";
    this.code = input.code;
    this.details = input.details;
  }
}
