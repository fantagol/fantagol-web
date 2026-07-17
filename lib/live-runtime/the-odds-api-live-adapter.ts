import type { SupabaseClient } from "@supabase/supabase-js";

import type {
  LiveProviderAdapter,
  ProviderPollRequest,
  ProviderPollResult,
} from "./provider-runtime";

const DEFAULT_BASE_URL = "https://api.the-odds-api.com/v4";
const DEFAULT_TIMEOUT_MS = 12_000;
const DEFAULT_SPORT_KEY = "soccer_italy_serie_a";
const DEFAULT_REGIONS = ["eu"];
const DEFAULT_MARKETS = ["h2h", "totals"];

export type TheOddsApiLiveAdapterOptions = {
  apiKey?: string;
  baseUrl?: string;
  timeoutMs?: number;
  sportKey?: string;
  regions?: string[];
  markets?: string[];
  bookmakers?: string[];
  oddsFormat?: "decimal" | "american";
  dateFormat?: "iso" | "unix";
  fetchImpl?: typeof fetch;
};

export type TheOddsApiQuotaMetadata = {
  requestsRemaining: number | null;
  requestsUsed: number | null;
  requestsLast: number | null;
};

export class TheOddsApiConfigurationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "TheOddsApiConfigurationError";
  }
}

export class TheOddsApiHttpError extends Error {
  readonly status: number;
  readonly retryAfterSeconds: number | null;
  readonly responseBody: unknown;
  readonly quota: TheOddsApiQuotaMetadata;

  constructor(input: {
    message: string;
    status: number;
    retryAfterSeconds: number | null;
    responseBody: unknown;
    quota: TheOddsApiQuotaMetadata;
  }) {
    super(input.message);
    this.name = "TheOddsApiHttpError";
    this.status = input.status;
    this.retryAfterSeconds = input.retryAfterSeconds;
    this.responseBody = input.responseBody;
    this.quota = input.quota;
  }
}

export class TheOddsApiTimeoutError extends Error {
  constructor(timeoutMs: number) {
    super(`The Odds API request timed out after ${timeoutMs} ms.`);
    this.name = "TheOddsApiTimeoutError";
  }
}

function parseIntegerHeader(value: string | null): number | null {
  if (value === null || value.trim() === "") {
    return null;
  }

  const parsed = Number.parseInt(value, 10);
  return Number.isFinite(parsed) ? parsed : null;
}

function readQuotaMetadata(headers: Headers): TheOddsApiQuotaMetadata {
  return {
    requestsRemaining: parseIntegerHeader(
      headers.get("x-requests-remaining"),
    ),
    requestsUsed: parseIntegerHeader(headers.get("x-requests-used")),
    requestsLast: parseIntegerHeader(headers.get("x-requests-last")),
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

function resolveApiKey(explicitKey?: string): string {
  const apiKey =
    explicitKey ??
    process.env.THE_ODDS_API_KEY ??
    process.env.ODDS_API_KEY;

  if (!apiKey) {
    throw new TheOddsApiConfigurationError(
      "Missing THE_ODDS_API_KEY environment variable.",
    );
  }

  return apiKey;
}

function requireNonEmptyValues(
  label: string,
  values: string[],
): string[] {
  const normalized = values
    .map((value) => value.trim())
    .filter((value) => value.length > 0);

  if (normalized.length === 0) {
    throw new TheOddsApiConfigurationError(
      `${label} must contain at least one value.`,
    );
  }

  return normalized;
}

export class TheOddsApiLiveAdapter implements LiveProviderAdapter {
  private readonly apiKey: string;
  private readonly baseUrl: string;
  private readonly timeoutMs: number;
  private readonly sportKey: string;
  private readonly regions: string[];
  private readonly markets: string[];
  private readonly bookmakers: string[];
  private readonly oddsFormat: "decimal" | "american";
  private readonly dateFormat: "iso" | "unix";
  private readonly fetchImpl: typeof fetch;

  constructor(options: TheOddsApiLiveAdapterOptions = {}) {
    this.apiKey = resolveApiKey(options.apiKey);
    this.baseUrl = (options.baseUrl ?? DEFAULT_BASE_URL).replace(/\/+$/, "");
    this.timeoutMs = options.timeoutMs ?? DEFAULT_TIMEOUT_MS;
    this.sportKey = (options.sportKey ?? DEFAULT_SPORT_KEY).trim();
    this.regions = requireNonEmptyValues(
      "regions",
      options.regions ?? DEFAULT_REGIONS,
    );
    this.markets = requireNonEmptyValues(
      "markets",
      options.markets ?? DEFAULT_MARKETS,
    );
    this.bookmakers = (options.bookmakers ?? [])
      .map((value) => value.trim())
      .filter((value) => value.length > 0);
    this.oddsFormat = options.oddsFormat ?? "decimal";
    this.dateFormat = options.dateFormat ?? "iso";
    this.fetchImpl = options.fetchImpl ?? fetch;

    if (!this.sportKey) {
      throw new TheOddsApiConfigurationError(
        "sportKey cannot be empty.",
      );
    }
  }

  async pollMatch(
    _client: SupabaseClient,
    request: ProviderPollRequest,
  ): Promise<ProviderPollResult> {
    if (request.providerCode !== "the_odds_api") {
      throw new TheOddsApiConfigurationError(
        `TheOddsApiLiveAdapter cannot handle '${request.providerCode}'.`,
      );
    }

    const eventId = request.externalMatchId.trim();

    if (!eventId) {
      throw new TheOddsApiConfigurationError(
        "The Odds API event id cannot be empty.",
      );
    }

    const query = new URLSearchParams({
      apiKey: this.apiKey,
      regions: this.regions.join(","),
      markets: this.markets.join(","),
      oddsFormat: this.oddsFormat,
      dateFormat: this.dateFormat,
    });

    if (this.bookmakers.length > 0) {
      query.set("bookmakers", this.bookmakers.join(","));
    }

    const endpoint =
      `/sports/${encodeURIComponent(this.sportKey)}` +
      `/events/${encodeURIComponent(eventId)}/odds`;

    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), this.timeoutMs);

    try {
      const response = await this.fetchImpl(
        `${this.baseUrl}${endpoint}?${query.toString()}`,
        {
          method: "GET",
          headers: {
            Accept: "application/json",
          },
          cache: "no-store",
          signal: controller.signal,
        },
      );

      const responseBody = await readResponseBody(response);
      const quota = readQuotaMetadata(response.headers);

      if (!response.ok) {
        throw new TheOddsApiHttpError({
          message:
            `The Odds API request failed with HTTP ${response.status}.`,
          status: response.status,
          retryAfterSeconds: parseIntegerHeader(
            response.headers.get("retry-after"),
          ),
          responseBody,
          quota,
        });
      }

      return {
        providerCode: request.providerCode,
        externalMatchId: eventId,
        fetchedAt: new Date().toISOString(),
        payload: {
          eventOdds: responseBody,
          transport: {
            provider: "the_odds_api",
            endpoint,
            sportKey: this.sportKey,
            regions: this.regions,
            markets: this.markets,
            bookmakers: this.bookmakers,
            oddsFormat: this.oddsFormat,
            dateFormat: this.dateFormat,
            quota,
          },
        },
      };
    } catch (error) {
      if (
        error instanceof Error &&
        (error.name === "AbortError" || controller.signal.aborted)
      ) {
        throw new TheOddsApiTimeoutError(this.timeoutMs);
      }

      throw error;
    } finally {
      clearTimeout(timeout);
    }
  }
}
