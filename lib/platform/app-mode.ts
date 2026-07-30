"use client";

import { Capacitor } from "@capacitor/core";
import { useEffect, useState } from "react";

export type FantaGolPlatformMode = "web" | "native";

export function isNativeFantaGolApp(): boolean {
  if (typeof window === "undefined") {
    return false;
  }

  return Capacitor.isNativePlatform();
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
