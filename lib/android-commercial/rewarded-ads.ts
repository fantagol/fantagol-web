import {
  Capacitor,
  registerPlugin,
} from "@capacitor/core";

export interface FantaGolRewardedAdsStatus {
  mobileAdsInitialized: boolean;
  rewardedReady: boolean;
  testMode: boolean;
  adUnitId: string;
  canRequestAds: boolean;
}

export interface FantaGolRewardedConsentResult {
  canRequestAds: boolean;
  privacyOptionsRequired: string;
}

export interface FantaGolRewardedLoadResult {
  loaded: boolean;
  testMode: boolean;
}

export interface FantaGolRewardedSsvOptions {
  userId: string;
  customData: string;
}

export interface FantaGolRewardedShownEvent {
  testMode: true;
}

export interface FantaGolRewardEarnedEvent {
  amount: number;
  type: string;
  testMode: true;
  economicallyAuthoritative: false;
}

export interface FantaGolRewardedDismissedEvent {
  testMode: true;
}

export interface FantaGolRewardedShowFailedEvent {
  testMode: true;
  message: string;
}

interface FantaGolRewardedAdsNativePlugin {
  requestConsent():
    Promise<FantaGolRewardedConsentResult>;

  getStatus():
    Promise<FantaGolRewardedAdsStatus>;

  loadRewarded():
    Promise<FantaGolRewardedLoadResult>;

  configureSsv(
    options:
      FantaGolRewardedSsvOptions,
  ): Promise<{
    configured: boolean;
  }>;

  showRewarded(): Promise<{
    showRequested: boolean;
    testMode: boolean;
    economicallyAuthoritative: false;
  }>;

  addListener(
    eventName: "rewardedShown",
    listener: (
      event: FantaGolRewardedShownEvent
    ) => void,
  ): Promise<{
    remove(): Promise<void>;
  }>;

  addListener(
    eventName: "rewardEarned",
    listener: (
      event: FantaGolRewardEarnedEvent
    ) => void,
  ): Promise<{
    remove(): Promise<void>;
  }>;

  addListener(
    eventName: "rewardedDismissed",
    listener: (
      event: FantaGolRewardedDismissedEvent
    ) => void,
  ): Promise<{
    remove(): Promise<void>;
  }>;

  addListener(
    eventName: "rewardedShowFailed",
    listener: (
      event: FantaGolRewardedShowFailedEvent
    ) => void,
  ): Promise<{
    remove(): Promise<void>;
  }>;
}

const nativePlugin =
  registerPlugin<
    FantaGolRewardedAdsNativePlugin
  >(
    "FantaGolRewardedAds",
  );

export function isFantaGolAndroidApp():
  boolean {
  return (
    Capacitor.isNativePlatform() &&
    Capacitor.getPlatform() ===
      "android"
  );
}

function requireAndroidApp(): void {
  if (!isFantaGolAndroidApp()) {
    throw new Error(
      "FANTAGOL_REWARDED_ADS_ANDROID_ONLY",
    );
  }
}

export async function requestRewardedAdsConsent():
  Promise<FantaGolRewardedConsentResult> {
  requireAndroidApp();

  return nativePlugin.requestConsent();
}

export async function getRewardedAdsStatus():
  Promise<FantaGolRewardedAdsStatus> {
  requireAndroidApp();

  return nativePlugin.getStatus();
}

export async function loadTestRewardedAd():
  Promise<FantaGolRewardedLoadResult> {
  requireAndroidApp();

  return nativePlugin.loadRewarded();
}

export async function showTestRewardedAd():
  Promise<{
    showRequested: boolean;
    testMode: boolean;
    economicallyAuthoritative: false;
  }> {
  requireAndroidApp();

  return nativePlugin.showRewarded();
}

export function onRewardedShown(
  listener:
    (
      event:
        FantaGolRewardedShownEvent,
    ) => void,
) {
  requireAndroidApp();

  return nativePlugin.addListener(
    "rewardedShown",
    listener,
  );
}

export function onRewardEarned(
  listener:
    (
      event:
        FantaGolRewardEarnedEvent,
    ) => void,
) {
  requireAndroidApp();

  return nativePlugin.addListener(
    "rewardEarned",
    listener,
  );
}

export function onRewardedDismissed(
  listener:
    (
      event:
        FantaGolRewardedDismissedEvent,
    ) => void,
) {
  requireAndroidApp();

  return nativePlugin.addListener(
    "rewardedDismissed",
    listener,
  );
}

export function onRewardedShowFailed(
  listener:
    (
      event:
        FantaGolRewardedShowFailedEvent,
    ) => void,
) {
  requireAndroidApp();

  return nativePlugin.addListener(
    "rewardedShowFailed",
    listener,
  );
}
export async function configureRewardedAdSsv(
  options:
    FantaGolRewardedSsvOptions,
): Promise<{
  configured: boolean;
}> {
  requireAndroidApp();

  const userId =
    options.userId.trim();

  const customData =
    options.customData.trim();

  if (!userId) {
    throw new TypeError(
      "userId is required.",
    );
  }

  if (!customData) {
    throw new TypeError(
      "customData is required.",
    );
  }

  return nativePlugin.configureSsv({
    userId,
    customData,
  });
}
