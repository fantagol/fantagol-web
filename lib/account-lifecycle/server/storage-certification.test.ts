import { randomUUID } from "node:crypto";

import { loadEnvConfig } from "@next/env";
import { describe, expect, test } from "vitest";

loadEnvConfig(process.cwd());

const APPROVED_COMMAND_ID =
  "3366f771-4be9-40cc-8657-80d7eb2b4960";

describe("Phase 180 Storage worker certification", () => {
  test("executes only the approved Storage command", async () => {
    const commandId =
      process.env.ACCOUNT_ERASURE_CERTIFICATION_COMMAND_ID?.trim();

    expect(commandId).toBe(APPROVED_COMMAND_ID);
    expect(process.env.ACCOUNT_ERASURE_SERVER_ENABLED).toBe("true");
    expect(process.env.ACCOUNT_ERASURE_CERTIFICATION_MODE).toBe("true");

    const { executeAccountErasureExternalCommand } = await import(
      "./worker"
    );

    const correlationId = randomUUID();

    const result = await executeAccountErasureExternalCommand({
      commandId: APPROVED_COMMAND_ID,
      correlationId,
    });

    process.stdout.write(
      `${JSON.stringify(
        {
          certification: "PHASE_180_STORAGE_WORKER",
          commandId: APPROVED_COMMAND_ID,
          correlationId,
          result,
        },
        null,
        2,
      )}\n`,
    );

    expect(result).toBeDefined();
  });
});
