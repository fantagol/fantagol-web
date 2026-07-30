"use client";

import { useEffect, useState } from "react";

export type FantaGolPlatformMode = "web" | "native";

const PLATFORM_QUERY_KEY = "fantagol_app";
const PLATFORM_STORAGE_KEY = "fantagol:platform";
const ANDROID_PLATFORM_VALUE = "android";

function readExplicitPlatformFromLocation(): string | null {
  if (typeof window === "undefined") {
    return null;
  }

  return new URLSearchParams(window.location.search).get(
    PLATFORM_QUERY_KEY,
  );
}

function persistAndroidPlatform(): void {
  try {
    window.localStorage.setItem(
      PLATFORM_STORAGE_KEY,
      ANDROID_PLATFORM_VALUE,
    );
  }
  catch {
    /*
     * La modalità nativa rimane valida per la pagina corrente anche
     * quando localStorage non è disponibile.
     */
  }
}

function readPersistedPlatform(): string | null {
  try {
    return window.localStorage.getItem(PLATFORM_STORAGE_KEY);
  }
  catch {
    return null;
  }
}

export function isNativeFantaGolApp(): boolean {
  if (typeof window === "undefined") {
    return false;
  }

  const explicitPlatform = readExplicitPlatformFromLocation();

  if (explicitPlatform === ANDROID_PLATFORM_VALUE) {
    persistAndroidPlatform();
    return true;
  }

  return readPersistedPlatform() === ANDROID_PLATFORM_VALUE;
}

export function getFantaGolPlatformMode(): FantaGolPlatformMode {
  return isNativeFantaGolApp() ? "native" : "web";
}

export function useNativeAppMode(): boolean {
  const [isNativeApp, setIsNativeApp] = useState(false);

  useEffect(() => {
    setIsNativeApp(isNativeFantaGolApp());
  }, []);

  return isNativeApp;
}
