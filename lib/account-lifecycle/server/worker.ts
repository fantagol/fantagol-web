import "server-only";

import { getSupabaseServiceClient } from "../../supabase/service";

import {
  assertUuid,
  parseAuthTarget,
  parseStorageTarget,
} from "./contracts";
import {
  AccountErasureAuthorizationError,
  AccountErasureContractError,
  getSafeAccountErasureError,
} from "./errors";
import { claimExternalCommand } from "./command-client";
import { recordExternalReceipt } from "./receipt-client";
import {
  finalizeExternalAttemptFailure,
  scheduleExternalCommandRetry,
} from "./failure-client";
import { executeAuthDeletion } from "./auth-admin-adapter";
import { executeStorageDeletion } from "./storage-adapter";
import { consoleAccountErasureLogger } from "./observability";
import type {
  AccountErasureWorkerDependencies,
  ClaimedExternalCommand,
  ExternalCommandExecutionResult,
} from "./types";

function requiredEnvironment(name: string): string {
  const value = process.env[name]?.trim();

  if (!value) {
    throw new AccountErasureAuthorizationError(
      "ACCOUNT_ERASURE_SERVER_CONFIGURATION_MISSING",
      `Required server configuration is missing: ${name}.`,
    );
  }

  return value;
}

function assertExecutionEnabled(commandId: string): void {
  if (process.env.ACCOUNT_ERASURE_SERVER_ENABLED !== "true") {
    throw new AccountErasureAuthorizationError(
      "ACCOUNT_ERASURE_SERVER_DISABLED",
      "Account-erasure server execution is disabled.",
    );
  }

  if (process.env.ACCOUNT_ERASURE_CERTIFICATION_MODE === "true") {
    const approvedCommandId = requiredEnvironment(
      "ACCOUNT_ERASURE_CERTIFICATION_COMMAND_ID",
    );

    if (approvedCommandId !== commandId) {
      throw new AccountErasureAuthorizationError(
        "ACCOUNT_ERASURE_CERTIFICATION_COMMAND_REJECTED",
        "Certification mode permits only the approved command.",
      );
    }
  }
}

export async function executeAccountErasureExternalCommand(
  input: {
    commandId: string;
    correlationId: string;
  },
  dependencies?: Partial<AccountErasureWorkerDependencies>,
): Promise<ExternalCommandExecutionResult> {
  assertUuid(input.commandId, "commandId");
  assertUuid(input.correlationId, "correlationId");
  assertExecutionEnabled(input.commandId);

  const client =
    dependencies?.client ?? getSupabaseServiceClient();
  const workerId =
    dependencies?.workerId ??
    requiredEnvironment("ACCOUNT_ERASURE_WORKER_ID");
  const logger =
    dependencies?.logger ?? consoleAccountErasureLogger;

  let claimedCommand: ClaimedExternalCommand | null = null;

  logger.info("Account-erasure external command starting.", {
    engine: "AccountErasureServerExecutionEngine",
    commandId: input.commandId,
    correlationId: input.correlationId,
    workerId,
  });

  try {
    const command = await claimExternalCommand(client, {
      commandId: input.commandId,
      workerId,
      correlationId: input.correlationId,
    });

    claimedCommand = command;

    const execution =
      command.commandType === "DELETE_STORAGE_ASSETS"
        ? await executeStorageDeletion(
            client,
            parseStorageTarget(command.restrictedPayload),
          )
        : command.commandType ===
            "DELETE_SUPABASE_AUTH_IDENTITY"
          ? await executeAuthDeletion(
              client,
              parseAuthTarget(command.restrictedPayload),
            )
          : (() => {
              throw new AccountErasureContractError(
                "ACCOUNT_ERASURE_COMMAND_TYPE_UNSUPPORTED",
                "Unsupported external command type.",
              );
            })();

    const receipt = await recordExternalReceipt(client, {
      commandId: command.commandId,
      attemptId: command.attemptId,
      workerId,
      leaseToken: command.leaseToken,
      receiptStatus: execution.status,
      providerRequestId: execution.providerRequestId,
      resultDigest: execution.resultDigest,
      publicEvidence: execution.publicEvidence,
      restrictedEvidence: execution.restrictedEvidence,
      affectedObjectCount: execution.affectedObjectCount,
      residualObjectCount: execution.residualObjectCount,
    });

    logger.info("Account-erasure external command completed.", {
      engine: "AccountErasureServerExecutionEngine",
      commandId: command.commandId,
      attemptId: command.attemptId,
      commandType: command.commandType,
      receiptId: receipt.receiptId,
      receiptType: receipt.receiptType,
      correlationId: input.correlationId,
      status: "completed",
    });

    return {
      accepted: true,
      commandId: command.commandId,
      commandType: command.commandType,
      attemptId: command.attemptId,
      receiptId: receipt.receiptId,
      receiptType: receipt.receiptType,
      status: "completed",
      correlationId: input.correlationId,
    };
  } catch (error) {
    const safeError = getSafeAccountErasureError(error);

    if (claimedCommand) {
      const outcome =
        safeError.code.includes("AMBIGUOUS")
          ? "ambiguous"
          : "failed";

      try {
        await finalizeExternalAttemptFailure(client, {
          commandId: claimedCommand.commandId,
          attemptId: claimedCommand.attemptId,
          workerId,
          leaseToken: claimedCommand.leaseToken,
          outcome,
          errorCode: safeError.code,
          errorClass:
            error instanceof Error ? error.name : "UnknownError",
          retryable: safeError.retryable,
          publicEvidence: {
            correlation_id: input.correlationId,
            failure_recorded: true,
          },
        });

        await scheduleExternalCommandRetry(
          client,
          claimedCommand.commandId,
        );
      } catch (recoveryError) {
        logger.error(
          "Account-erasure failure recording also failed.",
          {
            engine: "AccountErasureServerExecutionEngine",
            commandId: input.commandId,
            correlationId: input.correlationId,
            workerId,
            recoveryErrorCode:
              getSafeAccountErasureError(recoveryError).code,
          },
        );
      }
    }

    logger.error("Account-erasure external command failed.", {
      engine: "AccountErasureServerExecutionEngine",
      commandId: input.commandId,
      correlationId: input.correlationId,
      workerId,
      errorCode: safeError.code,
      retryable: safeError.retryable,
    });

    throw error;
  }
}
