import {
  generateKeyPairSync,
  sign,
} from "node:crypto";

import {
  beforeEach,
  describe,
  expect,
  it,
} from "vitest";

import {
  AdMobSsvVerificationError,
  parseAdMobSsvEnvelope,
  resetAdMobSsvPublicKeyCacheForTests,
  verifyAdMobRewardedSsv,
} from "./admob-ssv-verifier";

function toUrlSafeBase64(
  input: Buffer,
): string {
  return input
    .toString("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "");
}

function createFixture() {
  const {
    privateKey,
    publicKey,
  } =
    generateKeyPairSync(
      "ec",
      {
        namedCurve:
          "prime256v1",
      },
    );

  const signedContent = [
    "ad_network=5450213213286189855",
    "ad_unit=123456789",
    "custom_data=claim-rewarded-0001",
    "reward_amount=1",
    "reward_item=Premium%20Pass",
    "timestamp=1786737600000",
    "transaction_id=18fa792de1bca816048293fc71035638",
    "user_id=11111111-1111-4111-8111-111111111111",
  ].join("&");

  const signature =
    sign(
      "SHA256",
      Buffer.from(
        signedContent,
        "utf8",
      ),
      privateKey,
    );

  const url =
    "https://fantagol.app/api/commercial/rewarded-ad/ssv?" +
    signedContent +
    "&signature=" +
    encodeURIComponent(
      toUrlSafeBase64(
        signature,
      ),
    ) +
    "&key_id=12345";

  const pem =
    publicKey.export({
      format: "pem",
      type: "spki",
    }).toString();

  return {
    url,
    pem,
    signedContent,
  };
}

function publicKeyFetch(
  pem: string,
) {
  return async () =>
    new Response(
      JSON.stringify({
        keys: [
          {
            keyId: 12345,
            pem,
          },
        ],
      }),
      {
        status: 200,
        headers: {
          "content-type":
            "application/json",
        },
      },
    );
}

describe(
  "AdMob rewarded SSV verifier",
  () => {
    beforeEach(() => {
      resetAdMobSsvPublicKeyCacheForTests();
    });

    it("preserves the exact signed query bytes", () => {
      const fixture =
        createFixture();

      const envelope =
        parseAdMobSsvEnvelope(
          fixture.url,
        );

      expect(
        envelope.signedContent,
      ).toBe(
        fixture.signedContent,
      );

      expect(
        envelope.keyId,
      ).toBe(12345);
    });

    it("verifies a correctly signed callback", async () => {
      const fixture =
        createFixture();

      const verified =
        await verifyAdMobRewardedSsv(
          fixture.url,
          {
            fetchImpl:
              publicKeyFetch(
                fixture.pem,
              ) as typeof fetch,
          },
        );

      expect(
        verified.verified,
      ).toBe(true);

      expect(
        verified.providerEventId,
      ).toBe(
        "18fa792de1bca816048293fc71035638",
      );

      expect(
        verified.externalClaimReference,
      ).toBe(
        "claim-rewarded-0001",
      );

      expect(
        verified.providerUserId,
      ).toBe(
        "11111111-1111-4111-8111-111111111111",
      );

      expect(
        verified.rewardAmount,
      ).toBe("1");
    });

    it("rejects content modified after signing", async () => {
      const fixture =
        createFixture();

      const tampered =
        fixture.url.replace(
          "reward_amount=1",
          "reward_amount=100",
        );

      await expect(
        verifyAdMobRewardedSsv(
          tampered,
          {
            fetchImpl:
              publicKeyFetch(
                fixture.pem,
              ) as typeof fetch,
          },
        ),
      ).rejects.toMatchObject({
        code:
          "SSV_SIGNATURE_INVALID",
      });
    });

    it("rejects parameter reordering after signing", async () => {
      const fixture =
        createFixture();

      const reordered =
        fixture.url.replace(
          "ad_network=5450213213286189855&ad_unit=123456789",
          "ad_unit=123456789&ad_network=5450213213286189855",
        );

      await expect(
        verifyAdMobRewardedSsv(
          reordered,
          {
            fetchImpl:
              publicKeyFetch(
                fixture.pem,
              ) as typeof fetch,
          },
        ),
      ).rejects.toMatchObject({
        code:
          "SSV_SIGNATURE_INVALID",
      });
    });

    it("rejects an unknown key id", async () => {
      const fixture =
        createFixture();

      const wrongKey =
        fixture.url.replace(
          "key_id=12345",
          "key_id=99999",
        );

      await expect(
        verifyAdMobRewardedSsv(
          wrongKey,
          {
            fetchImpl:
              publicKeyFetch(
                fixture.pem,
              ) as typeof fetch,
          },
        ),
      ).rejects.toMatchObject({
        code:
          "SSV_KEY_NOT_FOUND",
        });
    });

    it("rejects parameters after key_id", () => {
      const fixture =
        createFixture();

      expect(() =>
        parseAdMobSsvEnvelope(
          fixture.url +
            "&unexpected=true",
        ),
      ).toThrow(
        AdMobSsvVerificationError,
      );
    });

    it("keeps verification independent from economic settlement", async () => {
      const fixture =
        createFixture();

      const verified =
        await verifyAdMobRewardedSsv(
          fixture.url,
          {
            fetchImpl:
              publicKeyFetch(
                fixture.pem,
              ) as typeof fetch,
          },
        );

      expect(
        Object.keys(
          verified,
        ),
      ).not.toContain(
        "passesAwarded",
      );

      expect(
        Object.keys(
          verified,
        ),
      ).not.toContain(
        "ledgerId",
      );
    });
  },
);
