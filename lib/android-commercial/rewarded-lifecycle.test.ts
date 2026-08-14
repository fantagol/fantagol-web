import {
  beforeEach,
  describe,
  expect,
  it,
  vi,
} from "vitest";

vi.mock(
  "./rewarded-ads",
  () => ({
    loadTestRewardedAd:
      vi.fn(),

    showTestRewardedAd:
      vi.fn(),
  }),
);

vi.mock(
  "./rewarded-claim",
  () => ({
    createRewardedAdClaimAttempt:
      vi.fn(),

    prepareRewardedAdClaim:
      vi.fn(),
  }),
);

import {
  isRewardedLifecycleBusy,
  resetRewardedLifecycleForTests,
  startRewardedAdLifecycle,
} from "./rewarded-lifecycle";

import type {
  PreparedRewardedAdClaim,
  RewardedAdClaimAttempt,
} from "./rewarded-claim";

const attempt:
  RewardedAdClaimAttempt = {
    attemptId:
      "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",

    idempotencyKey:
      "rewarded-ad:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",

    externalClaimReference:
      "admob:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
  };

const claim:
  PreparedRewardedAdClaim = {
    prepared:
      true,

    userId:
      "11111111-1111-4111-8111-111111111111",

    claimId:
      "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",

    claimStatus:
      "verification_pending",

    verificationStatus:
      "pending",

    campaignCode:
      "REWARDED_AD_FOUNDATION",

    sourceCode:
      "REWARDED_AD",

    passes:
      1,

    idempotencyKey:
      attempt.idempotencyKey,

    externalClaimReference:
      attempt.externalClaimReference,

    created:
      true,
  };

beforeEach(() => {
  resetRewardedLifecycleForTests();
});

describe(
  "Android rewarded lifecycle",
  () => {
    it("executes claim -> load -> show in strict order", async () => {
      const order:
        string[] = [];

      const result =
        await startRewardedAdLifecycle({
          createAttempt:
            () => {
              order.push(
                "create_attempt",
              );

              return attempt;
            },

          prepareClaim:
            async () => {
              order.push(
                "prepare_claim",
              );

              return claim;
            },

          loadAd:
            async () => {
              order.push(
                "load",
              );

              return {
                loaded:
                  true,

                testMode:
                  true,
              };
            },

          showAd:
            async () => {
              order.push(
                "show",
              );

              return {
                showRequested:
                  true,

                testMode:
                  true,

                economicallyAuthoritative:
                  false,
              };
            },
        });

      expect(order).toEqual([
        "create_attempt",
        "prepare_claim",
        "load",
        "show",
      ]);

      expect(result).toMatchObject({
        started:
          true,

        stage:
          "show_requested",

        attempt: {
          externalClaimReference:
            attempt.externalClaimReference,
        },

        claim: {
          claimId:
            claim.claimId,
        },
      });
    });

    it("never loads or shows if claim preparation fails", async () => {
      const loadAd =
        vi.fn();

      const showAd =
        vi.fn();

      await expect(
        startRewardedAdLifecycle({
          createAttempt:
            () =>
              attempt,

          prepareClaim:
            async () => {
              throw new Error(
                "claim failed",
              );
            },

          loadAd,
          showAd,
        }),
      ).rejects.toThrow(
        "claim failed",
      );

      expect(
        loadAd,
      ).not.toHaveBeenCalled();

      expect(
        showAd,
      ).not.toHaveBeenCalled();
    });

    it("never shows if rewarded loading fails", async () => {
      const showAd =
        vi.fn();

      await expect(
        startRewardedAdLifecycle({
          createAttempt:
            () =>
              attempt,

          prepareClaim:
            async () =>
              claim,

          loadAd:
            async () => {
              throw new Error(
                "load failed",
              );
            },

          showAd,
        }),
      ).rejects.toThrow(
        "load failed",
      );

      expect(
        showAd,
      ).not.toHaveBeenCalled();
    });

    it("rejects a non-loaded response before show", async () => {
      const showAd =
        vi.fn();

      await expect(
        startRewardedAdLifecycle({
          createAttempt:
            () =>
              attempt,

          prepareClaim:
            async () =>
              claim,

          loadAd:
            async () => ({
            loaded:
              false,

            testMode:
              true,
          }),

          showAd,
        }),
      ).rejects.toThrow(
        "REWARDED_LIFECYCLE_AD_NOT_LOADED",
      );

      expect(
        showAd,
      ).not.toHaveBeenCalled();
    });

    it("rejects claim/reference drift", async () => {
      const loadAd =
        vi.fn();

      const showAd =
        vi.fn();

      await expect(
        startRewardedAdLifecycle({
          createAttempt:
            () =>
              attempt,

          prepareClaim:
            async () => ({
              ...claim,

              externalClaimReference:
                "admob:WRONG",
            }),

          loadAd,
          showAd,
        }),
      ).rejects.toThrow(
        "REWARDED_LIFECYCLE_CLAIM_BINDING_INVALID",
      );

      expect(
        loadAd,
      ).not.toHaveBeenCalled();

      expect(
        showAd,
      ).not.toHaveBeenCalled();
    });

    it("prevents two concurrent rewarded lifecycle attempts", async () => {
      let resolveClaim:
        (
          value:
            PreparedRewardedAdClaim,
        ) => void =
          () => {};

      const pendingClaim =
        new Promise<
          PreparedRewardedAdClaim
        >((resolve) => {
          resolveClaim =
            resolve;
        });

      const first =
        startRewardedAdLifecycle({
          createAttempt:
            () =>
              attempt,

          prepareClaim:
            () =>
              pendingClaim,

          loadAd:
            async () => ({
            loaded:
              true,

            testMode:
              true,
          }),

          showAd:
            async () => ({
            showRequested:
              true,

            testMode:
              true,

            economicallyAuthoritative:
              false as const,
          }),
        });

      expect(
        isRewardedLifecycleBusy(),
      ).toBe(true);

      await expect(
        startRewardedAdLifecycle({
          createAttempt:
            () =>
              attempt,

          prepareClaim:
            async () =>
              claim,

          loadAd:
            async () => ({
            loaded:
              true,

            testMode:
              true,
          }),

          showAd:
            async () => ({
            showRequested:
              true,

            testMode:
              true,

            economicallyAuthoritative:
              false as const,
          }),
        }),
      ).rejects.toThrow(
        "REWARDED_LIFECYCLE_ALREADY_ACTIVE",
      );

      resolveClaim(
        claim,
      );

      await first;

      expect(
        isRewardedLifecycleBusy(),
      ).toBe(false);
    });

    it("a subsequent completed attempt receives a fresh attempt identity", async () => {
      const secondAttempt:
        RewardedAdClaimAttempt = {
        attemptId:
          "cccccccc-cccc-4ccc-8ccc-cccccccccccc",

        idempotencyKey:
          "rewarded-ad:cccccccc-cccc-4ccc-8ccc-cccccccccccc",

        externalClaimReference:
          "admob:cccccccc-cccc-4ccc-8ccc-cccccccccccc",
      };

      const secondClaim:
        PreparedRewardedAdClaim = {
        ...claim,

        claimId:
          "dddddddd-dddd-4ddd-8ddd-dddddddddddd",

        idempotencyKey:
          secondAttempt.idempotencyKey,

        externalClaimReference:
          secondAttempt.externalClaimReference,
      };

      let call =
        0;

      const createAttempt =
        () => {
          call += 1;

          return call === 1
            ? attempt
            : secondAttempt;
        };

      const prepareClaim =
        async (
          current:
            RewardedAdClaimAttempt,
        ) =>
          current.attemptId ===
            attempt.attemptId
            ? claim
            : secondClaim;

      const dependencies = {
        createAttempt,

        prepareClaim,

        loadAd:
          async () => ({
            loaded:
              true,

            testMode:
              true,
          }),

        showAd:
          async () => ({
            showRequested:
              true,

            testMode:
              true,

            economicallyAuthoritative:
              false as const,
          }),
      };

      const first =
        await startRewardedAdLifecycle(
          dependencies,
        );

      const second =
        await startRewardedAdLifecycle(
          dependencies,
        );

      expect(
        first.attempt.attemptId,
      ).not.toBe(
        second.attempt.attemptId,
      );

      expect(
        first.claim.externalClaimReference,
      ).not.toBe(
        second.claim.externalClaimReference,
      );
    });

    it("has no economic authority in the client lifecycle result", async () => {
      const result =
        await startRewardedAdLifecycle({
          createAttempt:
            () =>
              attempt,

          prepareClaim:
            async () =>
              claim,

          loadAd:
            async () => ({
            loaded:
              true,

            testMode:
              true,
          }),

          showAd:
            async () => ({
            showRequested:
              true,

            testMode:
              true,

            economicallyAuthoritative:
              false as const,
          }),
        });

      expect(
        Object.keys(result),
      ).not.toContain(
        "passesAwarded",
      );

      expect(
        Object.keys(result),
      ).not.toContain(
        "ledgerTransactionId",
      );

      expect(
        Object.keys(result),
      ).not.toContain(
        "settled",
      );
    });
  },
);
