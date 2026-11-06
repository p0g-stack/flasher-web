import { cloudflareTest } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.toml" },
      // The pool's bundled workerd is older than the deploy compatibility date.
      miniflare: { compatibilityDate: "2026-08-01" },
    }),
  ],
});
