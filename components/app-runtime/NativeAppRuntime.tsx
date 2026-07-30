"use client";

import {
  App,
  type BackButtonListenerEvent,
  type URLOpenListenerEvent,
} from "@capacitor/app";
import type { PluginListenerHandle } from "@capacitor/core";
import { useEffect } from "react";
import { NATIVE_OAUTH_CALLBACK_URL } from "../../lib/auth/oauth-redirect";
import { isNativeFantaGolApp } from "../../lib/platform/app-mode";
import { supabase } from "../../lib/supabaseClient";

const LEAGUES_ENTRY_PATH = "/leghe";

const NATIVE_RESUME_EVENT = "fantagol:native-resume";
const NATIVE_BACK_EVENT = "fantagol:native-back";

const SESSION_REFRESH_TIMEOUT_MS = 8_000;
const RESUME_RENDER_CHECK_DELAY_MS = 400;

function getLeagueDashboardPath(pathname: string): string | null {
  const match = pathname.match(/^\/leghe\/([^/]+)(?:\/.*)?$/);

  if (!match) {
    return null;
  }

  return `/leghe/${match[1]}`;
}

function isLeagueDashboardPath(pathname: string): boolean {
  return /^\/leghe\/[^/]+\/?$/.test(pathname);
}

function isNativeExitPath(pathname: string): boolean {
  return (
    pathname === LEAGUES_ENTRY_PATH ||
    pathname === "/login" ||
    pathname === "/registrati" ||
    pathname === "/password-reset" ||
    isLeagueDashboardPath(pathname)
  );
}

function dispatchNativeResumeEvent(): void {
  window.dispatchEvent(
    new CustomEvent(NATIVE_RESUME_EVENT, {
      detail: {
        resumedAt: Date.now(),
      },
    }),
  );
}

function documentHasRenderedContent(): boolean {
  const body = document.body;

  if (!body) {
    return false;
  }

  return (
    body.childElementCount > 0 ||
    Boolean(body.textContent?.trim()) ||
    Boolean(document.querySelector("main"))
  );
}

async function refreshSessionAfterResume(): Promise<void> {
  let timeoutId: number | undefined;

  try {
    const timeoutRequest = new Promise<never>((_, reject) => {
      timeoutId = window.setTimeout(() => {
        reject(new Error("Native session refresh timed out."));
      }, SESSION_REFRESH_TIMEOUT_MS);
    });

    await Promise.race([supabase.auth.getSession(), timeoutRequest]);
  } finally {
    if (timeoutId !== undefined) {
      window.clearTimeout(timeoutId);
    }
  }
}

async function recoverAfterResume(): Promise<void> {
  dispatchNativeResumeEvent();

  try {
    await refreshSessionAfterResume();
  } catch {
    /*
     * Manteniamo la pagina corrente in caso di rete temporaneamente assente.
     * Supabase potrà riprovare alla richiesta successiva.
     */
  }

  window.setTimeout(() => {
    if (!documentHasRenderedContent()) {
      window.location.reload();
      return;
    }

    /*
     * Richiede un nuovo ciclo di rendering senza modificare la navigazione.
     */
    document.documentElement.style.setProperty(
      "--fantagol-native-resume",
      String(Date.now()),
    );

    void document.documentElement.getBoundingClientRect();
  }, RESUME_RENDER_CHECK_DELAY_MS);
}

function handleNativeBack(event: BackButtonListenerEvent): void {
  const pageBackEvent = new CustomEvent(NATIVE_BACK_EVENT, {
    cancelable: true,
    detail: {
      canGoBack: event.canGoBack,
      pathname: window.location.pathname,
    },
  });

  const pageDidNotHandleBack = window.dispatchEvent(pageBackEvent);

  if (!pageDidNotHandleBack) {
    return;
  }

  const pathname = window.location.pathname;

  if (isNativeExitPath(pathname)) {
    void App.exitApp();
    return;
  }

  const leagueDashboardPath = getLeagueDashboardPath(pathname);

  if (leagueDashboardPath && pathname !== leagueDashboardPath) {
    window.location.replace(leagueDashboardPath);
    return;
  }

  window.location.replace(LEAGUES_ENTRY_PATH);
}

function isNativeOAuthCallback(url: URL): boolean {
  const expected = new URL(NATIVE_OAUTH_CALLBACK_URL);

  return (
    url.protocol === expected.protocol &&
    url.hostname === expected.hostname &&
    url.pathname.replace(/\/+$/, "") ===
      expected.pathname.replace(/\/+$/, "")
  );
}

function handleNativeAppUrlOpen(event: URLOpenListenerEvent): void {
  let openedUrl: URL;

  try {
    openedUrl = new URL(event.url);
  } catch {
    return;
  }

  if (!isNativeOAuthCallback(openedUrl)) {
    return;
  }

  const callbackPath = `/auth/callback${openedUrl.search}${openedUrl.hash}`;

  window.location.replace(callbackPath);
}

export default function NativeAppRuntime() {
  useEffect(() => {
    if (!isNativeFantaGolApp()) {
      return;
    }

    let disposed = false;
    const handles: PluginListenerHandle[] = [];

    async function retainHandle(
      handlePromise: Promise<PluginListenerHandle>,
    ): Promise<void> {
      const handle = await handlePromise;

      if (disposed) {
        await handle.remove();
        return;
      }

      handles.push(handle);
    }

    async function registerListeners(): Promise<void> {
      await retainHandle(
        App.addListener("appUrlOpen", handleNativeAppUrlOpen),
      );

      const launchUrl = await App.getLaunchUrl();

      if (!disposed && launchUrl?.url) {
        handleNativeAppUrlOpen({
          url: launchUrl.url,
        });
      }

      await retainHandle(
        App.addListener("appStateChange", ({ isActive }) => {
          if (disposed || !isActive) {
            return;
          }

          void recoverAfterResume();
        }),
      );

      await retainHandle(
        App.addListener("backButton", handleNativeBack),
      );
    }

    void registerListeners();

    return () => {
      disposed = true;

      for (const handle of handles) {
        void handle.remove();
      }
    };
  }, []);

  return null;
}
