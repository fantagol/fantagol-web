package app.fantagol.android;

import android.app.Activity;
import android.content.pm.ApplicationInfo;
import android.util.Log;

import androidx.annotation.NonNull;

import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;

import com.google.android.libraries.ads.mobile.sdk.MobileAds;
import com.google.android.libraries.ads.mobile.sdk.initialization.InitializationConfig;
import com.google.android.libraries.ads.mobile.sdk.rewarded.RewardedAd;
import com.google.android.libraries.ads.mobile.sdk.rewarded.RewardedAdEventCallback;
import com.google.android.libraries.ads.mobile.sdk.common.FullScreenContentError;
import com.google.android.libraries.ads.mobile.sdk.common.AdLoadCallback;
import com.google.android.libraries.ads.mobile.sdk.rewarded.ServerSideVerificationOptions;
import com.google.android.libraries.ads.mobile.sdk.common.AdRequest;
import com.google.android.libraries.ads.mobile.sdk.common.RequestConfiguration;
import com.google.android.libraries.ads.mobile.sdk.common.LoadAdError;

import java.util.Collections;

import com.google.android.ump.ConsentInformation;
import com.google.android.ump.ConsentRequestParameters;
import com.google.android.ump.FormError;
import com.google.android.ump.UserMessagingPlatform;

@CapacitorPlugin(name = "FantaGolRewardedAds")
public class FantaGolRewardedAdsPlugin extends Plugin {

    private static final String LOG_TAG =
            "FantaGolRewardedAds";

    private static final String REWARDED_AD_UNIT_ID =
            "ca-app-pub-9854419372662665/8637423907";

    private static final String DEBUG_TEST_DEVICE_ID =
            "7857E577E6C3CCCDD5EB3A1D82D75FCC";

    private ConsentInformation consentInformation;
    private RewardedAd rewardedAd;
    private String pendingSsvUserId;
    private String pendingSsvCustomData;
    private boolean mobileAdsInitialized = false;

    @Override
    public void load() {
        super.load();

        Activity activity = getActivity();

        if (activity != null) {
            consentInformation =
                    UserMessagingPlatform.getConsentInformation(activity);

            bootstrapConsentAtAppLaunch(
                    activity
            );
        }
    }

    private void bootstrapConsentAtAppLaunch(
            @NonNull Activity activity
    ) {
        if (consentInformation == null) {
            consentInformation =
                    UserMessagingPlatform.getConsentInformation(activity);
        }

        ConsentRequestParameters params =
                new ConsentRequestParameters.Builder()
                        .build();

        consentInformation.requestConsentInfoUpdate(
                activity,
                params,
                () -> UserMessagingPlatform
                        .loadAndShowConsentFormIfRequired(
                                activity,
                                formError -> {
                                    if (formError != null) {
                                        Log.e(
                                                LOG_TAG,
                                                "FANTAGOL_UMP_FORM_ERROR" +
                                                        " code=" +
                                                        formError.getErrorCode() +
                                                        " message=" +
                                                        formError.getMessage()
                                        );

                                        logConsentState(
                                                "form_error"
                                        );

                                        return;
                                    }

                                    logConsentState(
                                            "consent_resolved"
                                    );

                                    initializeMobileAdsIfAllowed(
                                            activity
                                    );
                                }
                        ),
                requestConsentError -> {
                    Log.e(
                            LOG_TAG,
                            "FANTAGOL_UMP_UPDATE_ERROR" +
                                    " code=" +
                                    requestConsentError.getErrorCode() +
                                    " message=" +
                                    requestConsentError.getMessage()
                    );

                    logConsentState(
                            "update_error"
                    );

                    /*
                     * Fail closed.
                     *
                     * loadRewarded() still checks canRequestAds()
                     * and refuses the ad if the session is not ready.
                     */
                }
        );
    }

    private void logConsentState(
            @NonNull String stage
    ) {
        boolean canRequestAds =
                consentInformation != null &&
                consentInformation.canRequestAds();

        String privacyOptionsRequired =
                consentInformation == null
                        ? "UNKNOWN"
                        : consentInformation
                                .getPrivacyOptionsRequirementStatus()
                                .name();

        int consentStatus =
                consentInformation == null
                        ? -1
                        : consentInformation
                                .getConsentStatus();

        Log.i(
                LOG_TAG,
                "FANTAGOL_UMP_STATUS" +
                        " stage=" + stage +
                        " consentStatus=" + consentStatus +
                        " canRequestAds=" + canRequestAds +
                        " privacyOptionsRequired=" +
                        privacyOptionsRequired +
                        " mobileAdsInitialized=" +
                        mobileAdsInitialized
        );
    }

    private void initializeMobileAdsIfAllowed(
            @NonNull Activity activity
    ) {
        if (mobileAdsInitialized) {
            return;
        }

        if (
                consentInformation != null &&
                !consentInformation.canRequestAds()
        ) {
            return;
        }

        new Thread(
                () -> {
                    InitializationConfig.Builder
                            initializationBuilder =
                            new InitializationConfig.Builder(
                                    "ca-app-pub-9854419372662665~5503356074"
                            );

                    boolean debugBuild =
                            (
                                    activity
                                            .getApplicationInfo()
                                            .flags &
                                    ApplicationInfo.FLAG_DEBUGGABLE
                            ) != 0;

                    if (debugBuild) {
                        RequestConfiguration
                                requestConfiguration =
                                new RequestConfiguration.Builder()
                                        .setTestDeviceIds(
                                                Collections.singletonList(
                                                        DEBUG_TEST_DEVICE_ID
                                                )
                                        )
                                        .build();

                        initializationBuilder
                                .setRequestConfiguration(
                                        requestConfiguration
                                );

                        Log.i(
                                LOG_TAG,
                                "FANTAGOL_ADMOB_TEST_DEVICE_CONFIGURED" +
                                        " deviceId=" +
                                        DEBUG_TEST_DEVICE_ID
                        );
                    }

                    MobileAds.initialize(
                            activity,
                            initializationBuilder.build(),
                            initializationStatus -> {
                                mobileAdsInitialized = true;

                                logConsentState(
                                        "mobile_ads_initialized"
                                );
                            }
                    );
                }
        ).start();
    }

    @PluginMethod
    public void requestConsent(PluginCall call) {

        Activity activity = getActivity();

        if (activity == null) {
            call.reject("ANDROID_ACTIVITY_UNAVAILABLE");
            return;
        }

        if (consentInformation == null) {
            consentInformation =
                    UserMessagingPlatform.getConsentInformation(activity);
        }

        ConsentRequestParameters params =
                new ConsentRequestParameters.Builder()
                        .build();

        consentInformation.requestConsentInfoUpdate(
                activity,
                params,
                () -> UserMessagingPlatform
                        .loadAndShowConsentFormIfRequired(
                                activity,
                                formError -> {
                                    if (formError != null) {
                                        rejectConsent(
                                                call,
                                                formError
                                        );
                                        return;
                                    }

                                    initializeMobileAdsIfAllowed(
                                            activity
                                    );

                                    JSObject result =
                                            new JSObject();

                                    result.put(
                                            "canRequestAds",
                                            consentInformation.canRequestAds()
                                    );

                                    result.put(
                                            "privacyOptionsRequired",
                                            consentInformation
                                                    .getPrivacyOptionsRequirementStatus()
                                                    .name()
                                    );

                                    call.resolve(result);
                                }
                        ),
                requestConsentError ->
                        rejectConsent(
                                call,
                                requestConsentError
                        )
        );
    }

    private void rejectConsent(
            PluginCall call,
            FormError error
    ) {
        call.reject(
                "UMP_CONSENT_ERROR:" +
                        error.getErrorCode() +
                        ":" +
                        error.getMessage()
        );
    }

    @PluginMethod
    public void getStatus(PluginCall call) {

        logConsentState(
                "get_status"
        );

        JSObject result =
                new JSObject();

        result.put(
                "mobileAdsInitialized",
                mobileAdsInitialized
        );

        result.put(
                "rewardedReady",
                rewardedAd != null
        );

        result.put(
                "testMode",
                true
        );

        result.put(
                "adUnitId",
                REWARDED_AD_UNIT_ID
        );

        if (consentInformation != null) {
            result.put(
                    "canRequestAds",
                    consentInformation.canRequestAds()
            );
        }
        else {
            result.put(
                    "canRequestAds",
                    false
            );
        }

        call.resolve(result);
    }

    private void applyPendingSsv(
            @NonNull RewardedAd ad
    ) {
        if (
                pendingSsvUserId == null ||
                pendingSsvCustomData == null
        ) {
            return;
        }

        ServerSideVerificationOptions options =
                new ServerSideVerificationOptions(
                        pendingSsvUserId,
                        pendingSsvCustomData
                );

        ad.setServerSideVerificationOptions(
                options
        );
    }

    private void clearPendingSsv() {
        pendingSsvUserId = null;
        pendingSsvCustomData = null;
    }

    @PluginMethod
    public void loadRewarded(PluginCall call) {

        Activity activity = getActivity();

        if (activity == null) {
            call.reject("ANDROID_ACTIVITY_UNAVAILABLE");
            return;
        }

        if (
                consentInformation == null ||
                !consentInformation.canRequestAds()
        ) {
            call.reject("CONSENT_NOT_READY");
            return;
        }

        initializeMobileAdsIfAllowed(activity);

        AdRequest request =
                new AdRequest.Builder(
                        REWARDED_AD_UNIT_ID
                ).build();

        RewardedAd.load(
                request,
                new AdLoadCallback<RewardedAd>() {

                    @Override
                    public void onAdLoaded(
                            @NonNull RewardedAd ad
                    ) {
                        applyPendingSsv(ad);

                        rewardedAd = ad;

                        rewardedAd.setAdEventCallback(
                                new RewardedAdEventCallback() {

                                    @Override
                                    public void onAdShowedFullScreenContent() {
                                        JSObject event =
                                                new JSObject();

                                        event.put(
                                                "testMode",
                                                true
                                        );

                                        notifyListeners(
                                                "rewardedShown",
                                                event
                                        );
                                    }

                                    @Override
                                    public void onAdDismissedFullScreenContent() {
                                        rewardedAd = null;
                                        clearPendingSsv();

                                        JSObject event =
                                                new JSObject();

                                        event.put(
                                                "testMode",
                                                true
                                        );

                                        notifyListeners(
                                                "rewardedDismissed",
                                                event
                                        );
                                    }

                                    @Override
                                    public void onAdFailedToShowFullScreenContent(
                                            FullScreenContentError error
                                    ) {
                                        rewardedAd = null;
                                        clearPendingSsv();

                                        JSObject event =
                                                new JSObject();

                                        event.put(
                                                "testMode",
                                                true
                                        );

                                        event.put(
                                                "message",
                                                error.getMessage()
                                        );

                                        notifyListeners(
                                                "rewardedShowFailed",
                                                event
                                        );
                                    }
                                }
                        );

                        JSObject result =
                                new JSObject();

                        result.put(
                                "loaded",
                                true
                        );

                        result.put(
                                "testMode",
                                true
                        );

                        call.resolve(result);
                    }

                    @Override
                    public void onAdFailedToLoad(
                            @NonNull LoadAdError error
                    ) {
                        rewardedAd = null;

                        call.reject(
                                "REWARDED_LOAD_FAILED:" +
                                        error.getCode() +
                                        ":" +
                                        error.getMessage()
                        );
                    }
                }
        );
    }

    @PluginMethod
    public void showRewarded(
            PluginCall call
    ) {

        Activity activity = getActivity();

        if (activity == null) {
            call.reject(
                    "ANDROID_ACTIVITY_UNAVAILABLE"
            );
            return;
        }

        if (rewardedAd == null) {
            call.reject(
                    "REWARDED_NOT_LOADED"
            );
            return;
        }

        RewardedAd adToShow =
                rewardedAd;

        adToShow.show(
                activity,
                rewardItem -> {

                    JSObject event =
                            new JSObject();

                    event.put(
                            "amount",
                            rewardItem.getAmount()
                    );

                    event.put(
                            "type",
                            rewardItem.getType()
                    );

                    event.put(
                            "testMode",
                            true
                    );

                    event.put(
                            "economicallyAuthoritative",
                            false
                    );

                    notifyListeners(
                            "rewardEarned",
                            event
                    );
                }
        );

        JSObject result =
                new JSObject();

        result.put(
                "showRequested",
                true
        );

        result.put(
                "testMode",
                true
        );

        result.put(
                "economicallyAuthoritative",
                false
        );

        call.resolve(result);
    }
    @PluginMethod
    public void configureSsv(
            PluginCall call
    ) {

        String userId =
                call.getString("userId");

        String customData =
                call.getString("customData");

        String normalizedUserId =
                userId == null
                        ? ""
                        : userId.trim();

        String normalizedCustomData =
                customData == null
                        ? ""
                        : customData.trim();

        if (normalizedUserId.isEmpty()) {
            call.reject("SSV_USER_ID_REQUIRED");
            return;
        }

        if (normalizedCustomData.isEmpty()) {
            call.reject("SSV_CUSTOM_DATA_REQUIRED");
            return;
        }

        pendingSsvUserId =
                normalizedUserId;

        pendingSsvCustomData =
                normalizedCustomData;

        /*
         * Defensive support for an already-loaded ad.
         * The canonical lifecycle remains:
         *
         * claim -> configure SSV -> load -> show
         */
        if (rewardedAd != null) {
            applyPendingSsv(
                    rewardedAd
            );
        }

        JSObject result =
                new JSObject();

        result.put(
                "configured",
                true
        );

        call.resolve(result);
    }
}
