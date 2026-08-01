import { describe, expect, it } from "vitest";

import {
  normalizeStoragePath,
  normalizeStoragePaths,
} from "./storage-adapter";

describe("Storage erasure path normalization", () => {
  it("normalizes a public club-avatar URL", () => {
    expect(
      normalizeStoragePath(
        "https://example.supabase.co/storage/v1/object/public/club-avatars/user/avatar.png",
        "club-avatars",
      ),
    ).toBe("user/avatar.png");
  });

  it("deduplicates and sorts paths", () => {
    expect(
      normalizeStoragePaths(
        ["b.png", "a.png", "b.png"],
        "club-avatars",
      ),
    ).toEqual(["a.png", "b.png"]);
  });

  it("rejects traversal", () => {
    expect(() =>
      normalizeStoragePath("../secret", "club-avatars"),
    ).toThrow("Storage object path is invalid");
  });

  it("rejects unapproved buckets", () => {
    expect(() =>
      normalizeStoragePaths(["avatar.png"], "other"),
    ).toThrow("Storage bucket is not approved");
  });
});
