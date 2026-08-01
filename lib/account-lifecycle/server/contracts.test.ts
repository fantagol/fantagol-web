import { describe, expect, it } from "vitest";

import {
  digestJson,
  parseAuthTarget,
  parseClaimedExternalCommand,
  parseStorageTarget,
} from "./contracts";

describe("account erasure server contracts", () => {
  it("parses a claimed Storage command", () => {
    const command = parseClaimedExternalCommand({
      command_id: "11111111-1111-4111-8111-111111111111",
      attempt_id: "22222222-2222-4222-8222-222222222222",
      attempt_number: 1,
      lease_token: "33333333-3333-4333-8333-333333333333",
      lease_expires_at: "2026-07-31T23:59:00Z",
      command_type: "DELETE_STORAGE_ASSETS",
      provider_code: "supabase_storage",
      provider_operation: "storage.remove",
      request_digest: "request",
      idempotency_key: "idem",
      restricted_payload: {
        bucket_code: "club-avatars",
        auth_user_id: null,
        normalized_paths: [],
        candidate_count: 0,
        requires_residual_scan: true,
      },
    });

    expect(command.commandType).toBe("DELETE_STORAGE_ASSETS");
    expect(command.attemptNumber).toBe(1);
  });

  it("rejects invalid Auth targets", () => {
    expect(() =>
      parseAuthTarget({
        auth_user_id: "not-a-uuid",
        hard_delete: true,
      }),
    ).toThrow("Auth deletion target is invalid");
  });

  it("parses Storage targets", () => {
    expect(
      parseStorageTarget({
        bucket_code: "club-avatars",
        auth_user_id:
          "11111111-1111-4111-8111-111111111111",
        normalized_paths: ["a/b.png"],
        candidate_count: 1,
        requires_residual_scan: true,
      }).candidateCount,
    ).toBe(1);
  });

  it("produces deterministic JSON digests", () => {
    expect(digestJson({ b: 2, a: 1 })).toBe(
      digestJson({ a: 1, b: 2 }),
    );
  });
});
