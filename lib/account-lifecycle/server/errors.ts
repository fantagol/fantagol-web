export class AccountErasureError extends Error {
  readonly code: string;
  readonly retryable: boolean;

  constructor(
    code: string,
    message: string,
    options?: {
      retryable?: boolean;
      cause?: unknown;
    },
  ) {
    super(message, { cause: options?.cause });
    this.name = new.target.name;
    this.code = code;
    this.retryable = options?.retryable ?? false;
  }
}

export class AccountErasureValidationError extends AccountErasureError {}

export class AccountErasureAuthorizationError extends AccountErasureError {}

export class AccountErasureLeaseError extends AccountErasureError {}

export class AccountErasureProviderError extends AccountErasureError {}

export class AccountErasureAmbiguousResultError extends AccountErasureError {}

export class AccountErasureContractError extends AccountErasureError {}

export function getSafeAccountErasureError(error: unknown): {
  code: string;
  message: string;
  retryable: boolean;
} {
  if (error instanceof AccountErasureError) {
    return {
      code: error.code,
      message: error.message,
      retryable: error.retryable,
    };
  }

  return {
    code: "ACCOUNT_ERASURE_UNEXPECTED_ERROR",
    message: "Unexpected account-erasure worker failure.",
    retryable: false,
  };
}
