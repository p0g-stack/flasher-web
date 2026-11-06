/**
 * GET /api/catalog?na=0|1
 *
 * Proxies Daniel Springer's OTA catalog (https://roms.danielspringer.at),
 * passing the client's ETag through and caching the feed for 15 minutes in
 * the Cache API. Ports the shape checks from upstream
 * `flasher_builder/ota_catalog.py` (`validate_catalog`).
 */

import { jsonError } from "./http";
import { isRecordObject } from "./shape";
import {
  CatalogError,
  MAX_UPSTREAM_RESPONSE,
  OTA_SERVICE_OVERSIZED,
  OTA_SERVICE_UNREACHABLE,
  UpstreamTooLargeError,
  otaServiceHttpError,
  readBounded,
  upstreamSignal,
} from "./upstream";

const ORIGIN = "https://roms.danielspringer.at";
const API_URL = `${ORIGIN}/api/ota.php`;
const NA_API_URL = `${ORIGIN}/api/na.php`;

export const CATALOG_TTL_SECONDS = 900;
const CATALOG_CACHE_CONTROL = `public, max-age=${CATALOG_TTL_SECONDS}`;
const CATALOG_USER_AGENT = "FlasherBuilder/1.0";

const RELEASE_STRING_FIELDS = [
  "id",
  "device",
  "region",
  "version",
  "source_url",
] as const;

function hasHttpScheme(value: string): boolean {
  try {
    const scheme = new URL(value).protocol;
    return scheme === "http:" || scheme === "https:";
  } catch {
    return false;
  }
}

/** Port of upstream `validate_catalog`. Throws `CatalogError` on mismatch. */
export function validateCatalog(data: unknown): void {
  if (!isRecordObject(data) || String(data["api_version"]) !== "1" || !Array.isArray(data["releases"])) {
    throw new CatalogError("The OTA service returned an unsupported catalog format.");
  }
  const ids = new Set<string>();
  for (const entry of data["releases"] as unknown[]) {
    if (!isRecordObject(entry)) {
      throw new CatalogError("The OTA catalog contains an incomplete release.");
    }
    for (const field of RELEASE_STRING_FIELDS) {
      const value = entry[field];
      if (typeof value !== "string" || value === "") {
        throw new CatalogError("The OTA catalog contains an incomplete release.");
      }
    }
    const id = entry["id"] as string;
    if (ids.has(id) || !hasHttpScheme(entry["source_url"] as string)) {
      throw new CatalogError("The OTA catalog contains an invalid release.");
    }
    ids.add(id);
  }
}

/** Weak comparison of an `If-None-Match` list against one entity tag. */
export function matchesEtag(ifNoneMatch: string, etag: string): boolean {
  const normalize = (value: string): string => {
    const trimmed = value.trim();
    return trimmed.startsWith("W/") ? trimmed.slice(2) : trimmed;
  };
  const wanted = normalize(etag);
  return ifNoneMatch
    .split(",")
    .some((candidate) => candidate.trim() === "*" || normalize(candidate) === wanted);
}

async function readCached(cache: Cache, key: Request): Promise<Response | null> {
  try {
    return (await cache.match(key)) ?? null;
  } catch {
    return null;
  }
}

export async function handleCatalog(
  request: Request,
  url: URL,
  cache: Cache,
): Promise<Response> {
  const naParam = url.searchParams.get("na");
  if (naParam !== null && naParam !== "0" && naParam !== "1") {
    return jsonError(400, 'The "na" parameter must be 0 or 1.');
  }
  const na = naParam === "1";
  const cacheKey = new Request(`${url.origin}/api/catalog?na=${na ? "1" : "0"}`);
  const ifNoneMatch = request.headers.get("If-None-Match");

  const cached = await readCached(cache, cacheKey);
  if (cached !== null) {
    const etag = cached.headers.get("ETag");
    if (ifNoneMatch !== null && etag !== null && matchesEtag(ifNoneMatch, etag)) {
      return new Response(null, {
        status: 304,
        headers: { "Cache-Control": CATALOG_CACHE_CONTROL, ETag: etag },
      });
    }
    return cached;
  }

  const upstreamHeaders: Record<string, string> = {
    "User-Agent": CATALOG_USER_AGENT,
  };
  if (ifNoneMatch !== null) {
    upstreamHeaders["If-None-Match"] = ifNoneMatch;
  }

  let response: Response;
  try {
    response = await fetch(na ? NA_API_URL : API_URL, {
      headers: upstreamHeaders,
      signal: upstreamSignal(),
    });
  } catch {
    return jsonError(502, OTA_SERVICE_UNREACHABLE);
  }

  if (response.status === 304) {
    const etag = response.headers.get("ETag") ?? ifNoneMatch;
    const headers = new Headers({ "Cache-Control": CATALOG_CACHE_CONTROL });
    if (etag !== null) {
      headers.set("ETag", etag);
    }
    return new Response(null, { status: 304, headers });
  }

  if (!response.ok) {
    return jsonError(502, otaServiceHttpError(response.status));
  }

  let body: Uint8Array;
  try {
    body = await readBounded(response, MAX_UPSTREAM_RESPONSE);
  } catch (error) {
    return jsonError(
      502,
      error instanceof UpstreamTooLargeError ? OTA_SERVICE_OVERSIZED : OTA_SERVICE_UNREACHABLE,
    );
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(body));
  } catch {
    return jsonError(502, "The OTA service returned invalid JSON.");
  }
  try {
    validateCatalog(parsed);
  } catch (error) {
    return jsonError(
      502,
      error instanceof CatalogError
        ? error.message
        : "The OTA service returned an unsupported catalog format.",
    );
  }

  const etag = response.headers.get("ETag");
  const headers = new Headers({
    "Content-Type": "application/json; charset=utf-8",
    "Cache-Control": CATALOG_CACHE_CONTROL,
  });
  if (etag !== null) {
    headers.set("ETag", etag);
  }
  const result = new Response(body, { status: 200, headers });
  try {
    await cache.put(cacheKey, result.clone());
  } catch {
    // A cache write failure must never fail the request.
  }
  return result;
}
