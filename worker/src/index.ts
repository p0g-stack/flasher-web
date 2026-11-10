/**
 * Edge worker: same-origin `/api/*` routes plus the Flutter web build.
 *
 * Only /api/* reaches this module (`run_worker_first` in wrangler.toml);
 * everything else is served by the static-asset binding.
 */

import { handleBloat } from "./bloat";
import { handleCatalog } from "./catalog";
import { handleBlock } from "./blocks";
import type { BucketEnv } from "./bucket";
import { json, jsonError, methodNotAllowed } from "./http";
import { handleOta } from "./ota";
import { handleResolve } from "./resolve";
import { CatalogError, ProxyError } from "./upstream";
import { warmCache } from "./warm";

export interface Env extends BucketEnv {
  ASSETS: Fetcher;
}

const API_PREFIX = "/api/";

export default {
  async fetch(request, env, ctx): Promise<Response> {
    const url = new URL(request.url);
    const path = url.pathname;
    if (!path.startsWith(API_PREFIX)) {
      return env.ASSETS.fetch(request);
    }
    try {
      if (path === "/api/block-config") {
        if (request.method !== "GET") return methodNotAllowed("GET");
        return json({ publicBase: env.OTA_PUBLIC_BASE || null });
      }
      if (path === "/api/manifest" || path === "/api/block") {
        if (request.method !== "GET") return methodNotAllowed("GET");
        return await handleBlock(url, env);
      }
      if (path === "/api/catalog") {
        if (request.method !== "GET") {
          return methodNotAllowed("GET");
        }
        return await handleCatalog(request, url, caches.default);
      }
      if (path === "/api/resolve") {
        if (request.method !== "POST") {
          return methodNotAllowed("POST");
        }
        return await handleResolve(request);
      }
      if (path === "/api/ota") {
        if (request.method !== "GET" && request.method !== "HEAD") {
          return methodNotAllowed("GET, HEAD");
        }
        return await handleOta(request, url);
      }
      if (path.startsWith(API_PREFIX + "bloat/")) {
        if (request.method !== "GET") {
          return methodNotAllowed("GET");
        }
        return await handleBloat(request, path);
      }
      return jsonError(404, "Unknown API route.");
    } catch (error) {
      if (error instanceof ProxyError) return jsonError(error.status, error.message);
      if (error instanceof CatalogError) return jsonError(502, error.message);
      return jsonError(502, "The edge worker could not complete this request.");
    }
  },
  async scheduled(event, env, ctx): Promise<void> {
    ctx.waitUntil(warmCache(env, event.scheduledTime).then(result => {
      console.log("OTA cache warm", JSON.stringify(result));
    }));
  },
} satisfies ExportedHandler<Env>;
