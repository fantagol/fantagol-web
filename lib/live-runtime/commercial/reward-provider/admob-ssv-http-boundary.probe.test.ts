import {
  describe,
  expect,
  it,
  vi,
} from "vitest";

vi.mock(
  "server-only",
  () => ({}),
);

import {
  NextRequest,
} from "next/server";

import {
  ADMOB_SSV_VERIFICATION_PROBE_MARKER,
  createAdMobSsvGetHandler,
} from "@/app/api/commercial/rewarded-ad/ssv/route";

import type {
  VerifiedAdMobRewardedSsv,
} from "./admob-ssv-verifier";

function makeVerificationProbe():
  VerifiedAdMobRewardedSsv {
  return {
    verified: true,

    sourceCode:
      "REWARDED_AD",

    providerEventType:
      "REWARDED_VIDEO_COMPLETED",

    providerEventId:
      "admob-console-verification-probe",

    externalClaimReference:
      ADMOB_SSV_VERIFICATION_PROBE_MARKER,

    providerUserId:
      ADMOB_SSV_VERIFICATION_PROBE_MARKER,

    transactionId:
      "admob-console-verification-probe",

    timestampMs:
      1786748053432,

    adNetwork:
      "5450213213286189855",

    adUnit:
      "1234567890",

    rewardAmount:
      "1",

    rewardItem:
      "Reward",

    keyId:
      3335741209,

    rawQuery:
      "signed-query",

    signedContent:
      "signed-content",
  };
}

describe(
  "AdMob signed console verification probe",
  () => {
    it(
      "returns HTTP 200 after signature verification without economic processing",
      async () => {
        const verifiedProbe =
          makeVerificationProbe();

        const verify =
          vi.fn(
            async () =>
              verifiedProbe,
          );

        const register =
          vi.fn();

        const bindClaim =
          vi.fn();

        const settle =
          vi.fn();

        const handler =
          createAdMobSsvGetHandler(
            {
              verify,
              register,
              bindClaim,
              settle,
            } as unknown as Parameters<
              typeof createAdMobSsvGetHandler
            >[0],
          );

        const request =
          new NextRequest(
            "https://www.fantagol.app/api/commercial/rewarded-ad/ssv?probe=1",
          );

        const response =
          await handler(
            request,
          );

        expect(
          response.status,
        ).toBe(200);

        await expect(
          response.json(),
        ).resolves.toMatchObject({
          received: true,
          verified: true,
          verificationProbe: true,
          economicallyAuthoritative:
            false,
        });

        expect(
          verify,
        ).toHaveBeenCalledTimes(1);

        expect(
          register,
        ).not.toHaveBeenCalled();

        expect(
          bindClaim,
        ).not.toHaveBeenCalled();

        expect(
          settle,
        ).not.toHaveBeenCalled();
      },
    );
  },
);