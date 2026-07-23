import {
  describe,
  expect,
  it,
} from "vitest";

import {
  normalizeRewardCampaigns,
} from "./validation";

const CAMPAIGN_ID =
  "11111111-1111-4111-8111-111111111111";

function createCampaign() {
  return {
    campaign_id: CAMPAIGN_ID,
    campaign_code:
      "LEAGUE_FIRST_ROUND_COMPLETED",
    source_code: "LOYALTY_EVENT",
    title: "Prima giornata completata",
    description:
      "Reward sorpresa per un risultato verificato.",
    reward_type: "PASS_REWARD",
    passes_per_claim: 1,
    cooldown_seconds: 0,
    starts_at:
      "2026-08-01T00:00:00.000Z",
    ends_at:
      "2027-06-30T23:59:59.000Z",
    metadata: {
      surprise_reward: true,
    },
  };
}

describe("normalizeRewardCampaigns", () => {
  it("accepts a complete campaign catalog", () => {
    const payload = [
      createCampaign(),
    ];

    expect(
      normalizeRewardCampaigns(payload),
    ).toEqual(payload);
  });

  it("accepts an empty catalog", () => {
    expect(
      normalizeRewardCampaigns([]),
    ).toEqual([]);
  });

  it.each([
    "PASS_REWARD",
    "PASS_PROMOTION",
    "PASS_GIFT",
    "PASS_REFERRAL",
  ] as const)(
    "accepts reward type %s",
    (reward_type) => {
      const result =
        normalizeRewardCampaigns([
          {
            ...createCampaign(),
            reward_type,
          },
        ]);

      expect(
        result[0].reward_type,
      ).toBe(reward_type);
    },
  );

  it("accepts nullable description and validity timestamps", () => {
    const result =
      normalizeRewardCampaigns([
        {
          ...createCampaign(),
          description: null,
          starts_at: null,
          ends_at: null,
        },
      ]);

    expect(result[0]).toMatchObject({
      description: null,
      starts_at: null,
      ends_at: null,
    });
  });

  it("preserves JSON-compatible extension fields", () => {
    const result =
      normalizeRewardCampaigns([
        {
          ...createCampaign(),
          display_priority: 10,
        },
      ]);

    expect(
      result[0].display_priority,
    ).toBe(10);
  });

  it("rejects a non-array payload", () => {
    expect(() =>
      normalizeRewardCampaigns({}),
    ).toThrow(
      "reward_campaigns must be an array.",
    );
  });

  it("rejects a non-object campaign", () => {
    expect(() =>
      normalizeRewardCampaigns([null]),
    ).toThrow(
      "reward_campaigns[0] must be a JSON object.",
    );
  });

  it("rejects an invalid campaign UUID", () => {
    expect(() =>
      normalizeRewardCampaigns([
        {
          ...createCampaign(),
          campaign_id: "invalid",
        },
      ]),
    ).toThrow(
      "reward_campaigns[0].campaign_id must be a valid UUID.",
    );
  });

  it.each([
    "campaign_code",
    "source_code",
  ] as const)(
    "rejects invalid uppercase code %s",
    (fieldName) => {
      expect(() =>
        normalizeRewardCampaigns([
          {
            ...createCampaign(),
            [fieldName]: "invalid-code",
          },
        ]),
      ).toThrow(
        `reward_campaigns[0].${fieldName} must be an uppercase code.`,
      );
    },
  );

  it("rejects an empty title", () => {
    expect(() =>
      normalizeRewardCampaigns([
        {
          ...createCampaign(),
          title: "   ",
        },
      ]),
    ).toThrow(
      "reward_campaigns[0].title must be a non-empty string.",
    );
  });

  it("rejects an invalid description", () => {
    expect(() =>
      normalizeRewardCampaigns([
        {
          ...createCampaign(),
          description: "",
        },
      ]),
    ).toThrow(
      "reward_campaigns[0].description must be a non-empty string or null.",
    );
  });

  it("rejects an invalid reward type", () => {
    expect(() =>
      normalizeRewardCampaigns([
        {
          ...createCampaign(),
          reward_type: "WELCOME_BONUS",
        },
      ]),
    ).toThrow(
      "reward_campaigns[0].reward_type is invalid.",
    );
  });

  it.each([
    0,
    -1,
    1.5,
    Number.MAX_SAFE_INTEGER + 1,
  ])(
    "rejects invalid passes_per_claim %s",
    (passes_per_claim) => {
      expect(() =>
        normalizeRewardCampaigns([
          {
            ...createCampaign(),
            passes_per_claim,
          },
        ]),
      ).toThrow(
        "reward_campaigns[0].passes_per_claim must be a positive safe integer.",
      );
    },
  );

  it.each([
    -1,
    1.5,
    Number.MAX_SAFE_INTEGER + 1,
  ])(
    "rejects invalid cooldown_seconds %s",
    (cooldown_seconds) => {
      expect(() =>
        normalizeRewardCampaigns([
          {
            ...createCampaign(),
            cooldown_seconds,
          },
        ]),
      ).toThrow(
        "reward_campaigns[0].cooldown_seconds must be a non-negative safe integer.",
      );
    },
  );

  it.each([
    "starts_at",
    "ends_at",
  ] as const)(
    "rejects invalid timestamp %s",
    (fieldName) => {
      expect(() =>
        normalizeRewardCampaigns([
          {
            ...createCampaign(),
            [fieldName]: "invalid",
          },
        ]),
      ).toThrow(
        `reward_campaigns[0].${fieldName} must be a valid timestamp or null.`,
      );
    },
  );

  it("rejects an invalid validity interval", () => {
    expect(() =>
      normalizeRewardCampaigns([
        {
          ...createCampaign(),
          starts_at:
            "2027-01-01T00:00:00.000Z",
          ends_at:
            "2026-01-01T00:00:00.000Z",
        },
      ]),
    ).toThrow(
      "reward_campaigns[0].ends_at must be later than starts_at.",
    );
  });

  it("rejects non-object metadata", () => {
    expect(() =>
      normalizeRewardCampaigns([
        {
          ...createCampaign(),
          metadata: [],
        },
      ]),
    ).toThrow(
      "reward_campaigns[0].metadata must be a JSON object.",
    );
  });
});
