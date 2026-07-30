import { isNativeFantaGolApp } from "../platform/app-mode";

export const NATIVE_OAUTH_CALLBACK_URL = "fantagol://auth/callback";

export function createOAuthCallbackUrl(returnTo: string): string {
  const callbackUrl = isNativeFantaGolApp()
    ? new URL(NATIVE_OAUTH_CALLBACK_URL)
    : new URL("/auth/callback", window.location.origin);

  callbackUrl.searchParams.set("returnTo", returnTo);

  return callbackUrl.toString();
}
