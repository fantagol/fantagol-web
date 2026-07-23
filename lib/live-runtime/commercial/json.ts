export type JsonPrimitive = string | number | boolean | null;

export type JsonValue =
  | JsonPrimitive
  | JsonObject
  | JsonValue[];

export type JsonObject = {
  [key: string]: JsonValue;
};

export function isJsonObject(value: unknown): value is JsonObject {
  return (
    typeof value === "object" &&
    value !== null &&
    !Array.isArray(value)
  );
}

export function asJsonObject(
  value: unknown,
  context: string,
): JsonObject {
  if (!isJsonObject(value)) {
    throw new TypeError(`${context} must be a JSON object.`);
  }

  return value;
}
