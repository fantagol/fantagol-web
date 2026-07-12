import { ProviderError } from "./errors";

export async function providerFetchJson<T>(args: {
  providerCode: string;
  url: string;
  init?: RequestInit;
}): Promise<T> {
  let response: Response;

  try {
    response = await fetch(args.url, {
      ...args.init,
      cache: "no-store",
    });
  } catch (cause) {
    throw new ProviderError({
      code: "PROVIDER_REQUEST_FAILED",
      providerCode: args.providerCode,
      message: `Request failed for provider ${args.providerCode}`,
      retryable: true,
      cause,
    });
  }

  if (response.status === 401 || response.status === 403) {
    throw new ProviderError({
      code: "PROVIDER_UNAUTHORIZED",
      providerCode: args.providerCode,
      message: `Provider ${args.providerCode} rejected the credentials`,
      retryable: false,
    });
  }

  if (response.status === 429) {
    throw new ProviderError({
      code: "PROVIDER_RATE_LIMITED",
      providerCode: args.providerCode,
      message: `Provider ${args.providerCode} rate limit reached`,
      retryable: true,
    });
  }

  if (!response.ok) {
    throw new ProviderError({
      code: "PROVIDER_REQUEST_FAILED",
      providerCode: args.providerCode,
      message: `Provider ${args.providerCode} returned HTTP ${response.status}`,
      retryable: response.status >= 500,
    });
  }

  try {
    return (await response.json()) as T;
  } catch (cause) {
    throw new ProviderError({
      code: "PROVIDER_RESPONSE_INVALID",
      providerCode: args.providerCode,
      message: `Provider ${args.providerCode} returned invalid JSON`,
      retryable: false,
      cause,
    });
  }
}
