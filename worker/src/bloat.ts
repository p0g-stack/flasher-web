/**
 * GET /api/bloat/<asset_name>
 *
 * Streaming proxy for Flasher_Builder's GitHub release bloat assets. GitHub
 * answers with a redirect to its object store; both destination hosts are
 * allowlisted explicitly, and the client's Range header is passed through.
 */

import { jsonError } from "./http";
import { ProxyError, fetchFollowing } from "./upstream";

const BLOAT_PREFIX =
  "https://github.com/koaaN/Flasher_Builder/releases/download/bloat-assets-v1/";
const BLOAT_HOSTS: Record<string, true> = {
  "github.com": true,
  "release-assets.githubusercontent.com": true,
  "objects.githubusercontent.com": true,
};
const ASSET_NAME = /^[A-Za-z0-9._-]+$/;
const BLOAT_ROUTE = "/api/bloat/";

const FORWARDED_RESPONSE_HEADERS = [
  "Content-Range",
  "Content-Length",
  "Accept-Ranges",
  "ETag",
  "Last-Modified",
  "Content-Type",
];

function bloatHopAllowed(url: URL): boolean {
  return (
    url.protocol === "https:" &&
    url.port === "" &&
    url.username === "" &&
    url.password === "" &&
    BLOAT_HOSTS[url.hostname] === true
  );
}

/** Asset name from a `/api/bloat/...` path, or null when it is not a bare name. */
export function bloatAssetName(pathname: string): string | null {
  const raw = pathname.slice(BLOAT_ROUTE.length);
  let name: string;
  try {
    name = decodeURIComponent(raw);
  } catch {
    return null;
  }
  if (name === "." || name === ".." || !ASSET_NAME.test(name)) {
    return null;
  }
  return name;
}

export async function handleBloat(request: Request, pathname: string): Promise<Response> {
  const name = bloatAssetName(pathname);
  if (name === null) {
    return jsonError(400, "Invalid bloat asset name.");
  }
  const headers: Record<string, string> = {};
  const range = request.headers.get("Range");
  if (range !== null) {
    headers["Range"] = range;
  }

  let upstream: Response;
  try {
    upstream = await fetchFollowing(new URL(`${BLOAT_PREFIX}${name}`), bloatHopAllowed, {
      method: "GET",
      headers,
    });
  } catch (error) {
    if (error instanceof ProxyError) {
      return jsonError(error.status, error.message);
    }
    return jsonError(502, "The bloat asset could not be proxied.");
  }

  if (upstream.status >= 400) {
    if (upstream.body !== null) {
      try {
        await upstream.body.cancel();
      } catch {
        // Nothing to release.
      }
    }
    return jsonError(upstream.status, `Bloat asset server returned HTTP ${upstream.status}.`);
  }

  const responseHeaders = new Headers({ "Cache-Control": "no-store" });
  for (const header of FORWARDED_RESPONSE_HEADERS) {
    const value = upstream.headers.get(header);
    if (value !== null) {
      responseHeaders.set(header, value);
    }
  }
  return new Response(upstream.body, { status: upstream.status, headers: responseHeaders });
}
