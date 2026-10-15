import { defineWorkersConfig } from "@cloudflare/vitest-pool-workers/config";

export default defineWorkersConfig({
  test: {
    poolOptions: {
      workers: {
        singleWorker: true,
        isolatedStorage: false,
        wrangler: { configPath: "./wrangler.jsonc" },
        miniflare: {
          // Shrunk so the tests can see them happen: unauthenticated sockets close after 300 ms, messages live 2 s.
          bindings: { AUTH_TIMEOUT_MS: "300", TTL_MS: "2000" },
        },
      },
    },
  },
});
