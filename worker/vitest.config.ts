import { cloudflareTest } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.toml" },
      // The pool's bundled workerd is older than the deploy compatibility date.
      miniflare: {
        compatibilityDate: "2026-08-01",
        bindings: {
          OTA_S3_ENDPOINT: "https://s3-pool.example",
          OTA_S3_BUCKET: "ota",
          OTA_S3_REGION: "garage",
          OTA_S3_ACCESS_KEY_ID: "local-key",
          OTA_S3_SECRET_ACCESS_KEY: "local-secret",
          OTA_PUBLIC_BASE: "https://public.example/",
        },
      },
    }),
  ],
});
