import type { SupabaseClient } from "@supabase/supabase-js";

import type {
  LiveProviderBatchAdapter,
  ProviderBatchPollRequest,
  ProviderBatchPollResult,
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

function requireIsoDate(
  value: string | undefined,
  field: string,
): string {
  if (
    typeof value !== "string" ||
    !/^\d{4}-\d{2}-\d{2}$/.test(value)
  ) {
    throw new FootballDataConfigurationError(
      `${field} must use YYYY-MM-DD.`,
    );
  }

  return value;
}

export function buildFootballDataBatchEndpoint(
  request: ProviderBatchPollRequest,
): string {
  const mode = request.mode ?? "live";

  const competitionCode =
    request.competitionCode?.trim() || "SA";

  const params = new URLSearchParams();

  params.set("competitions", competitionCode);

  if (mode === "live") {
    params.set("status", "LIVE");

    return `/matches?${params.toString()}`;
  }

  const dateFrom =
    requireIsoDate(
      request.dateFrom,
      "dateFrom",
    );

  const dateTo =
    requireIsoDate(
      request.dateTo,
      "dateTo",
    );

  if (dateTo <= dateFrom) {
    throw new FootballDataConfigurationError(
      "dateTo must be later than dateFrom.",
    );
  }

  params.set("dateFrom", dateFrom);
  params.set("dateTo", dateTo);

  return `/matches?${params.toString()}`;
}
export class FootballDataLiveAdapter implements LiveProviderBatchAdapter {
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
  async pollMatches(
    _client: SupabaseClient,
    request: ProviderBatchPollRequest,
  ): Promise<ProviderBatchPollResult> {
    if (request.providerCode !== "football_data") {
      throw new FootballDataConfigurationError(
        `FootballDataLiveAdapter cannot handle '${request.providerCode}'.`,
      );
    }

    const requestedExternalMatchIds = [
      ...new Set(
        request.externalMatchIds.map((value) => value.trim()),
      ),
    ];

    if (requestedExternalMatchIds.length === 0) {
      throw new FootballDataConfigurationError(
        "Football-Data batch polling requires at least one match id.",
      );
    }

    for (const externalMatchId of requestedExternalMatchIds) {
      if (!/^\d+$/.test(externalMatchId)) {
        throw new FootballDataConfigurationError(
          `Invalid Football-Data match id '${externalMatchId}'.`,
        );
      }
    }

    const requestedIdSet =
      new Set(requestedExternalMatchIds);

    const controller = new AbortController();
    const timeout =
      setTimeout(
        () => controller.abort(),
        this.timeoutMs,
      );

    try {
      const endpoint = buildFootballDataBatchEndpoint(request);

      const response = await this.fetchImpl(
        `${this.baseUrl}${endpoint}`,
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

      const responseBody =
        await readResponseBody(response);

      const rateLimit =
        readRateLimitMetadata(response.headers);

      if (!response.ok) {
        throw new FootballDataHttpError({
          message:
            `Football-Data request failed with HTTP ${response.status}.`,
          status: response.status,
          retryAfterSeconds:
            parseIntegerHeader(
              response.headers.get("retry-after"),
            ) ??
            rateLimit.requestCounterResetSeconds,
          responseBody,
        });
      }

      if (
        typeof responseBody !== "object" ||
        responseBody === null ||
        Array.isArray(responseBody) ||
        !Array.isArray(
          (responseBody as Record<string, unknown>).matches,
        )
      ) {
        throw new FootballDataConfigurationError(
          "Football-Data batch response must contain a matches array.",
        );
      }

      const fetchedAt = new Date().toISOString();

      const rawMatches =
        (responseBody as {
          matches: unknown[];
        }).matches;

      const results: ProviderPollResult[] = [];

      for (const rawMatch of rawMatches) {
        if (
          typeof rawMatch !== "object" ||
          rawMatch === null ||
          Array.isArray(rawMatch)
        ) {
          continue;
        }

        const id =
          (rawMatch as Record<string, unknown>).id;

        if (
          typeof id !== "number" ||
          !requestedIdSet.has(String(id))
        ) {
          continue;
        }

        const externalMatchId = String(id);

        results.push({
          providerCode: request.providerCode,
          externalMatchId,
          fetchedAt,
          payload: {
            match: rawMatch,
            transport: {
              provider: "football_data",
              endpoint,
              mode: "aggregated",
              rateLimit,
            },
          },
        });
      }

      return {
        providerCode: request.providerCode,
        fetchedAt,
        results,
        requestedExternalMatchIds,
        returnedExternalMatchIds:
          results.map(
            (result) => result.externalMatchId,
          ),
        transport: {
          provider: "football_data",
          endpoint,
          mode: "aggregated",
          requestCount: 1,
          rateLimit,
        },
      };
    } catch (error) {
      if (
        error instanceof Error &&
        (
          error.name === "AbortError" ||
          controller.signal.aborted
        )
      ) {
        throw new FootballDataTimeoutError(
          this.timeoutMs,
        );
      }

      throw error;
    } finally {
      clearTimeout(timeout);
    }
  }
}
