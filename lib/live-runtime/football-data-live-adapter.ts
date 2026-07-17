import type { SupabaseClient } from "@supabase/supabase-js";

import type {
  LiveProviderAdapter,
  ProviderPollRequest,
  ProviderPollResult,
} from "./provider-runtime";

const DEFAULT_BASE_URL = "https://api.football-data.org/v4";
const DEFAULT_TIMEOUT_MS = 12_000;

export type FootballDataLiveAdapterOptions = {
  apiToken?: string;
  baseUrl?: string;
  timeoutMs?: number;
  fetchImpl?: typeof fetch;
};

export type FootballDataRateLimitMetadata = {
  apiVersion: string | null;
  authenticatedClient: string | null;
  requestCounterResetSeconds: number | null;
  requestsAvailable: number | null;
};

export class FootballDataConfigurationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "FootballDataConfigurationError";
  }
}

export class FootballDataHttpError extends Error {
  readonly status: number;
  readonly retryAfterSeconds: number | null;
  readonly responseBody: unknown;

  constructor(input: {
    message: string;
    status: number;
    retryAfterSeconds: number | null;
    responseBody: unknown;
  }) {
    super(input.message);
    this.name = "FootballDataHttpError";
    this.status = input.status;
    this.retryAfterSeconds = input.retryAfterSeconds;
    this.responseBody = input.responseBody;
  }
}

export class FootballDataTimeoutError extends Error {
  constructor(timeoutMs: number) {
    super(`Football-Data request timed out after ${timeoutMs} ms.`);
    this.name = "FootballDataTimeoutError";
  }
}

function parseIntegerHeader(value: string | null): number | null {
  if (value === null || value.trim() === "") {
    return null;
  }

  const parsed = Number.parseInt(value, 10);
  return Number.isFinite(parsed) ? parsed : null;
}

function readRateLimitMetadata(
  headers: Headers,
): FootballDataRateLimitMetadata {
  return {
    apiVersion: headers.get("x-api-version"),
    authenticatedClient: headers.get("x-authenticated-client"),
    requestCounterResetSeconds: parseIntegerHeader(
      headers.get("x-requestcounter-reset"),
    ),
    requestsAvailable: parseIntegerHeader(
      headers.get("x-requestsavailable"),
    ),
  };
}

async function readResponseBody(response: Response): Promise<unknown> {
  const contentType = response.headers.get("content-type") ?? "";

  if (contentType.includes("application/json")) {
    return response.json();
  }

  const text = await response.text();
  return text.length > 0 ? text : null;
}

function resolveApiToken(explicitToken?: string): string {
  const token =
    explicitToken ??
    process.env.FOOTBALL_DATA_API_TOKEN ??
    process.env.FOOTBALL_DATA_TOKEN;

  if (!token) {
    throw new FootballDataConfigurationError(
      "Missing FOOTBALL_DATA_API_TOKEN environment variable.",
    );
  }

  return token;
}

export class FootballDataLiveAdapter implements LiveProviderAdapter {
  private readonly apiToken: string;
  private readonly baseUrl: string;
  private readonly timeoutMs: number;
  private readonly fetchImpl: typeof fetch;

  constructor(options: FootballDataLiveAdapterOptions = {}) {
    this.apiToken = resolveApiToken(options.apiToken);
    this.baseUrl = (options.baseUrl ?? DEFAULT_BASE_URL).replace(/\/+$/, "");
    this.timeoutMs = options.timeoutMs ?? DEFAULT_TIMEOUT_MS;
    this.fetchImpl = options.fetchImpl ?? fetch;
  }

  async pollMatch(
    _client: SupabaseClient,
    request: ProviderPollRequest,
  ): Promise<ProviderPollResult> {
    if (request.providerCode !== "football_data") {
      throw new FootballDataConfigurationError(
        `FootballDataLiveAdapter cannot handle '${request.providerCode}'.`,
      );
    }

    const externalMatchId = request.externalMatchId.trim();

    if (!/^\d+$/.test(externalMatchId)) {
      throw new FootballDataConfigurationError(
        `Invalid Football-Data match id '${request.externalMatchId}'.`,
      );
    }

    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), this.timeoutMs);

    try {
      const response = await this.fetchImpl(
        `${this.baseUrl}/matches/${encodeURIComponent(externalMatchId)}`,
        {
          method: "GET",
          headers: {
            Accept: "application/json",
            "X-Auth-Token": this.apiToken,
          },
          cache: "no-store",
          signal: controller.signal,
        },
      );

      const responseBody = await readResponseBody(response);
      const rateLimit = readRateLimitMetadata(response.headers);

      if (!response.ok) {
        throw new FootballDataHttpError({
          message:
            `Football-Data request failed with HTTP ${response.status}.`,
          status: response.status,
          retryAfterSeconds:
            parseIntegerHeader(response.headers.get("retry-after")) ??
            rateLimit.requestCounterResetSeconds,
          responseBody,
        });
      }

      return {
        providerCode: request.providerCode,
        externalMatchId,
        fetchedAt: new Date().toISOString(),
        payload: {
          match: responseBody,
          transport: {
            provider: "football_data",
            endpoint: `/matches/${externalMatchId}`,
            rateLimit,
          },
        },
      };
    } catch (error) {
      if (
        error instanceof Error &&
        (error.name === "AbortError" ||
          controller.signal.aborted)
      ) {
        throw new FootballDataTimeoutError(this.timeoutMs);
      }

      throw error;
    } finally {
      clearTimeout(timeout);
    }
  }
}
