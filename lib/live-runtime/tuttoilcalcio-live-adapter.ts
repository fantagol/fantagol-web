import type { SupabaseClient } from "@supabase/supabase-js";

import type {
  LiveProviderAdapter,
  ProviderPollRequest,
  ProviderPollResult,
} from "./provider-runtime";
import { fetchTuttoilcalcioFixture } from "./tuttoilcalcio-live-provider";

const DEFAULT_TIMEOUT_MS = 12_000;

export type TuttoilcalcioLiveAdapterOptions = {
  baseUrl?: string;
  locale?: string;
  timeoutMs?: number;
};

export class TuttoilcalcioLiveAdapter implements LiveProviderAdapter {
  private readonly baseUrl: string | undefined;
  private readonly locale: string | undefined;
  private readonly timeoutMs: number;

  constructor(options: TuttoilcalcioLiveAdapterOptions = {}) {
    this.baseUrl = options.baseUrl;
    this.locale = options.locale;
    this.timeoutMs = options.timeoutMs ?? DEFAULT_TIMEOUT_MS;
  }

  async pollMatch(
    _client: SupabaseClient,
    request: ProviderPollRequest,
  ): Promise<ProviderPollResult> {
    if (request.providerCode !== "tuttoilcalcio") {
      throw new Error(
        `TuttoilcalcioLiveAdapter cannot handle '${request.providerCode}'.`,
      );
    }

    const externalMatchId = request.externalMatchId.trim();

    if (!/^\d+$/.test(externalMatchId)) {
      throw new Error(
        `Invalid Tuttoilcalcio fixture id '${request.externalMatchId}'.`,
      );
    }

    const controller = new AbortController();
    const timeout =
      setTimeout(
        () => controller.abort(),
        this.timeoutMs,
      );

    try {
      const observation =
        await fetchTuttoilcalcioFixture(
          externalMatchId,
          {
            signal: controller.signal,
            baseUrl: this.baseUrl,
            locale: this.locale,
          },
        );

      if (observation.sourceFixtureId !== externalMatchId) {
        throw new Error(
          `TUTTOILCALCIO_FIXTURE_ID_MISMATCH:${externalMatchId}:${observation.sourceFixtureId}`,
        );
      }

      return {
        providerCode: request.providerCode,
        externalMatchId,
        fetchedAt: observation.observedAt,
        payload: observation.payload,
      };
    } catch (error) {
      if (
        error instanceof Error &&
        (
          error.name === "AbortError" ||
          controller.signal.aborted
        )
      ) {
        throw new Error(
          `TUTTOILCALCIO_TIMEOUT:${this.timeoutMs}`,
        );
      }

      throw error;
    } finally {
      clearTimeout(timeout);
    }
  }
}
