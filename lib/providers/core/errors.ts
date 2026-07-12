export type ProviderErrorCode =
  | "PROVIDER_CONFIGURATION_MISSING"
  | "PROVIDER_UNAUTHORIZED"
  | "PROVIDER_RATE_LIMITED"
  | "PROVIDER_RESPONSE_INVALID"
  | "PROVIDER_ENTITY_NOT_FOUND"
  | "PROVIDER_REQUEST_FAILED";

export class ProviderError extends Error {
  readonly code: ProviderErrorCode;
  readonly providerCode: string;
  readonly retryable: boolean;
  readonly causeValue?: unknown;

  constructor(args: {
    code: ProviderErrorCode;
    providerCode: string;
    message: string;
    retryable: boolean;
    cause?: unknown;
  }) {
    super(args.message);
    this.name = "ProviderError";
    this.code = args.code;
    this.providerCode = args.providerCode;
    this.retryable = args.retryable;
    this.causeValue = args.cause;
  }
}
