import type {
  AccountErasureLogger,
  JsonObject,
} from "./types";

const FORBIDDEN_KEYS = new Set([
  "authUserId",
  "auth_user_id",
  "email",
  "normalizedPaths",
  "normalized_paths",
  "restrictedPayload",
  "restricted_payload",
  "restrictedEvidence",
  "restricted_evidence",
  "serviceRoleKey",
  "executionSecret",
]);

function sanitize(fields: JsonObject | undefined): JsonObject | undefined {
  if (!fields) return undefined;

  return Object.fromEntries(
    Object.entries(fields)
      .filter(([key]) => !FORBIDDEN_KEYS.has(key))
      .map(([key, value]) => [
        key,
        typeof value === "string" && value.length > 500
          ? `${value.slice(0, 500)}…`
          : value,
      ]),
  );
}

export const consoleAccountErasureLogger: AccountErasureLogger = {
  info(message, fields) {
    console.info(message, sanitize(fields));
  },
  warn(message, fields) {
    console.warn(message, sanitize(fields));
  },
  error(message, fields) {
    console.error(message, sanitize(fields));
  },
};
