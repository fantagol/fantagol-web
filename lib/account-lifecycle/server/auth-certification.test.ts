import { randomUUID } from "node:crypto";

import { loadEnvConfig } from "@next/env";
import { createClient } from "@supabase/supabase-js";
import { describe, expect, test } from "vitest";

loadEnvConfig(process.cwd());

const APPROVED_COMMAND_ID =
  "5407a305-a1ba-4d5d-aec8-c7d6580c72fc";

const APPROVED_AUTH_USER_ID =
  "3068cf3b-8251-4817-8a7b-377ef14ba71d";

function requireEnvironment(name: string): string {
  const value = process.env[name]?.trim();

  if (!value) {
    throw new Error(`Missing required environment variable: ${name}`);
  }

  return value;
}

describe("Phase 181 Auth worker certification", () => {
  test("deletes only the approved Supabase Auth identity", async () => {
    expect(
      process.env.ACCOUNT_ERASURE_CERTIFICATION_COMMAND_ID?.trim(),
    ).toBe(APPROVED_COMMAND_ID);

    expect(
      process.env.ACCOUNT_ERASURE_CERTIFICATION_AUTH_USER_ID?.trim(),
    ).toBe(APPROVED_AUTH_USER_ID);

    expect(process.env.ACCOUNT_ERASURE_SERVER_ENABLED).toBe("true");
    expect(process.env.ACCOUNT_ERASURE_CERTIFICATION_MODE).toBe("true");
    expect(process.env.ACCOUNT_ERASURE_AUTH_EXECUTION_ENABLED).toBe(
      "true",
    );

    const supabaseUrl = requireEnvironment(
      "NEXT_PUBLIC_SUPABASE_URL",
    );
    const serviceRoleKey = requireEnvironment(
      "SUPABASE_SERVICE_ROLE_KEY",
    );

    const supabase = createClient(supabaseUrl, serviceRoleKey, {
      auth: {
        autoRefreshToken: false,
        persistSession: false,
        detectSessionInUrl: false,
      },
    });

    const lookup = await supabase.auth.admin.getUserById(
      APPROVED_AUTH_USER_ID,
    );

    if (lookup.error) {
      throw new Error(
        `AUTH_CERTIFICATION_TARGET_LOOKUP_FAILED: ${lookup.error.message}`,
      );
    }

    expect(lookup.data.user?.id).toBe(APPROVED_AUTH_USER_ID);

    process.stdout.write(
      `${JSON.stringify(
        {
          certification: "PHASE_181_AUTH_WORKER_PREFLIGHT",
          commandId: APPROVED_COMMAND_ID,
          authUserId: APPROVED_AUTH_USER_ID,
          targetVerified: true,
        },
        null,
        2,
      )}\n`,
    );

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
          certification: "PHASE_181_AUTH_WORKER",
          commandId: APPROVED_COMMAND_ID,
          authUserId: APPROVED_AUTH_USER_ID,
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
