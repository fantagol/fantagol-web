import { fileURLToPath } from "node:url";

import { defineConfig } from "vitest/config";

export default defineConfig({
  resolve: {
    alias: {
      "server-only": fileURLToPath(
        new URL(
          "./scripts/account-lifecycle/server-only-stub.ts",
          import.meta.url,
        ),
      ),
    },
  },
  test: {
    environment: "node",
    isolate: true,
    maxWorkers: 1,
  },
});
