import { randomUUID } from "node:crypto";

import { loadEnvConfig } from "@next/env";

loadEnvConfig(process.cwd());

const APPROVED_COMMAND_ID =
  "3366f771-4be9-40cc-8657-80d7eb2b4960";

async function main(): Promise<void> {
  const commandId =
    process.env.ACCOUNT_ERASURE_CERTIFICATION_COMMAND_ID?.trim();

  if (commandId !== APPROVED_COMMAND_ID) {
    throw new Error(
      "ACCOUNT_ERASURE_STORAGE_CERTIFICATION_COMMAND_MISMATCH",
    );
  }

  const { executeAccountErasureExternalCommand } = await import(
    "../../lib/account-lifecycle/server/worker"
  );

  const correlationId = randomUUID();

  const result = await executeAccountErasureExternalCommand({
    commandId,
    correlationId,
  });

  process.stdout.write(
    `${JSON.stringify(
      {
        certification: "PHASE_180_STORAGE_WORKER",
        commandId,
        correlationId,
        result,
      },
      null,
      2,
    )}\n`,
  );
}

main().catch((error: unknown) => {
  const message =
    error instanceof Error ? error.message : "UNKNOWN_ERROR";

  process.stderr.write(
    `${JSON.stringify(
      {
        certification: "PHASE_180_STORAGE_WORKER",
        status: "failed",
        error: message,
      },
      null,
      2,
    )}\n`,
  );

  process.exitCode = 1;
});
