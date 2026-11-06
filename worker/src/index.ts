/**
 * Edge worker: same-origin `/api/*` routes plus the Flutter web build.
 *
 * Only /api/* reaches this module (`run_worker_first` in wrangler.toml);
 * everything else is served by the static-asset binding.
 */

import { handleBloat } from "./bloat";
import { handleCatalog } from "./catalog";
import { jsonError, methodNotAllowed } from "./http";
import { handleOta } from "./ota";
import { handleResolve } from "./resolve";

export interface Env {
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
    } catch {
      return jsonError(502, "The edge worker could not complete this request.");
    }
  },
} satisfies ExportedHandler<Env>;
