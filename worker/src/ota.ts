/**
 * GET/HEAD /api/ota?u=<encoded https url>
 *
 * Streaming Range proxy for resolved OTA links. Only HTTPS on allowlisted
 * hosts is reachable, redirects are validated hop by hop, and the upstream
 * request carries the OTA server headers from upstream `remote_zip.HEADERS`.
 */

import { jsonError } from "./http";
import { parseSingleRange } from "./range";
import { ProxyError, fetchFollowing } from "./upstream";

const OTA_HOST_SUFFIXES = [
  "allawnofs.com",
  "allawnfs.com",
  "allawnos.com",
  "oneplus.com",
  "oneplus.net",
  "oppo.com",
  "coloros.com",
  "realme.com",
  "heytapimage.com",
];

const OTA_CATALOG_HOST = "roms.danielspringer.at";
const OTA_CATALOG_PATH = "/download.php";

/** Verbatim port of upstream `remote_zip.HEADERS` plus per-request Range. */
export const OTA_REQUEST_HEADERS: Record<string, string> = {
  "User-Agent": "Dalvik/2.1.0 (Linux; U; Android 16; CPH2653 Build/AP3A.240617.008)",
  userId: "oplus-ota|15002017",
  language: "en-US",
  brand: "oneplus-exp",
  "Accept-Encoding": "identity",
};

const FORWARDED_RESPONSE_HEADERS = [
  "Content-Range",
  "Content-Length",
  "Accept-Ranges",
  "ETag",
  "Last-Modified",
  "Content-Type",
];

/** Host-suffix match with a DNS label boundary, HTTPS only, default port. */
export function otaUrlAllowed(url: URL): boolean {
  if (url.protocol !== "https:" || url.username !== "" || url.password !== "" || url.port !== "") {
    return false;
  }
  const host = url.hostname;
  if (host === OTA_CATALOG_HOST) {
    return url.pathname === OTA_CATALOG_PATH;
  }
  return OTA_HOST_SUFFIXES.some(
    (suffix) => host === suffix || host.endsWith(`.${suffix}`),
  );
}

function readTarget(raw: string | null): URL | null {
  if (raw === null || raw === "") {
    return null;
  }
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    return null;
  }
  return otaUrlAllowed(url) ? url : null;
}

function rangeNotSatisfiable(): Response {
  return jsonError(416, "The requested byte range is not supported.", {
    "Content-Range": "bytes */*",
  });
}

async function upstreamFailure(response: Response, rangeRequested: boolean): Promise<Response> {
  if (response.body !== null) {
    try {
      await response.body.cancel();
    } catch {
      // Nothing to release.
    }
  }
  if (rangeRequested && response.status === 200) {
    return jsonError(502, "The OTA server does not support HTTP ranges.");
  }
  const headers: Record<string, string> = {};
  const contentRange = response.headers.get("Content-Range");
  if (contentRange !== null) {
    headers["Content-Range"] = contentRange;
  }
  return jsonError(response.status, `OTA server returned HTTP ${response.status}.`, headers);
}

export async function handleOta(request: Request, url: URL): Promise<Response> {
  const target = readTarget(url.searchParams.get("u"));
  if (target === null) {
    return jsonError(
      400,
      "The OTA URL must be an allowlisted HTTPS address.",
    );
  }
  const isHead = request.method === "HEAD";
  const rangeHeader = request.headers.get("Range");
  let range: string | null = null;
  if (rangeHeader !== null) {
    range = parseSingleRange(rangeHeader);
    if (range === null) {
      return rangeNotSatisfiable();
    }
  } else if (!isHead) {
    return jsonError(400, "A Range header is required.", {
      "Accept-Ranges": "bytes",
    });
  }

  const headers: Record<string, string> = { ...OTA_REQUEST_HEADERS };
  if (range !== null) {
    headers["Range"] = range;
  }

  let upstream: Response;
  try {
    upstream = await fetchFollowing(target, otaUrlAllowed, {
      method: request.method,
      headers,
    });
  } catch (error) {
    if (error instanceof ProxyError) {
      return jsonError(error.status, error.message);
    }
    return jsonError(502, "The OTA download could not be proxied.");
  }

  if (upstream.status >= 400 || (range !== null && upstream.status === 200)) {
    return upstreamFailure(upstream, range !== null);
  }

  const responseHeaders = new Headers({ "Cache-Control": "no-store" });
  for (const name of FORWARDED_RESPONSE_HEADERS) {
    const value = upstream.headers.get(name);
    if (value !== null) {
      responseHeaders.set(name, value);
    }
  }
  return new Response(isHead ? null : upstream.body, {
    status: upstream.status,
    headers: responseHeaders,
  });
}
