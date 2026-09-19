export const DEFAULT_LIVE_FRONTEND_REFRESH_INTERVAL_MS =
  30_000;

type LiveFrontendRefreshTrigger =
  | "interval"
  | "visibility"
  | "focus"
  | "online";

export type InstallLiveFrontendRefreshInput = {
  refresh: (
    trigger: LiveFrontendRefreshTrigger,
  ) => void | Promise<void>;
  intervalMs?: number;
};

/**
 * Lightweight browser-side recovery for publication-backed LIVE read models.
 *
 * Contract:
 * - no provider access;
 * - no writes;
 * - no Supabase realtime channel dependency;
 * - interval polling pauses while the document is hidden;
 * - returning to foreground/focus/online requests a fresh backend read;
 * - overlapping refreshes are coalesced.
 *
 * The caller owns the read callback. Editable pages must pass a projection-only
 * callback so drafts and unsaved local inputs are never reloaded by this loop.
 */
export function installLiveFrontendRefresh(
  input: InstallLiveFrontendRefreshInput,
): () => void {
  const intervalMs =
    input.intervalMs ??
    DEFAULT_LIVE_FRONTEND_REFRESH_INTERVAL_MS;

  if (
    !Number.isFinite(intervalMs) ||
    intervalMs < 5_000
  ) {
    throw new Error(
      "LIVE_FRONTEND_REFRESH_INVALID_INTERVAL",
    );
  }

  let disposed = false;
  let inFlight = false;
  let lastStartedAt = 0;

  const run = async (
    trigger: LiveFrontendRefreshTrigger,
  ) => {
    if (disposed || inFlight) {
      return;
    }

    if (
      trigger === "interval" &&
      document.visibilityState !== "visible"
    ) {
      return;
    }

    /*
     * visibilitychange and focus can fire back-to-back for the same resume.
     * Keep one backend read for that browser transition.
     */
    const now = Date.now();
    if (
      trigger !== "interval" &&
      now - lastStartedAt < 1_000
    ) {
      return;
    }

    inFlight = true;
    lastStartedAt = now;

    try {
      await input.refresh(trigger);
    } catch (error) {
      console.error(
        "LIVE_FRONTEND_REFRESH_ERROR",
        {
          trigger,
          error,
        },
      );
    } finally {
      inFlight = false;
    }
  };

  const timer =
    window.setInterval(
      () => {
        void run("interval");
      },
      intervalMs,
    );

  const handleVisibilityChange = () => {
    if (
      document.visibilityState === "visible"
    ) {
      void run("visibility");
    }
  };

  const handleFocus = () => {
    void run("focus");
  };

  const handleOnline = () => {
    void run("online");
  };

  document.addEventListener(
    "visibilitychange",
    handleVisibilityChange,
  );
  window.addEventListener(
    "focus",
    handleFocus,
  );
  window.addEventListener(
    "online",
    handleOnline,
  );

  return () => {
    disposed = true;
    window.clearInterval(timer);

    document.removeEventListener(
      "visibilitychange",
      handleVisibilityChange,
    );
    window.removeEventListener(
      "focus",
      handleFocus,
    );
    window.removeEventListener(
      "online",
      handleOnline,
    );
  };
}