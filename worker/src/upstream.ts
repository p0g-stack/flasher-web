/** Shared request/response helpers and upstream limits for the edge worker. */

export const MAX_UPSTREAM_RESPONSE = 16 * 1024 * 1024;
export const UPSTREAM_TIMEOUT_MS = 35_000;

export const OTA_SERVICE_UNREACHABLE =
  "Could not reach the OTA service. Check your connection and try again.";
export const OTA_SERVICE_OVERSIZED = "The OTA service returned an oversized response.";

export function otaServiceHttpError(status: number): string {
  return `OTA service returned HTTP ${status}. Try again later.`;
}

/** An error whose message is safe to return to the client (never contains a URL). */
export class CatalogError extends Error {}

export class UpstreamTooLargeError extends Error {}

export function upstreamSignal(): AbortSignal {
  const signal = AbortSignal as unknown as {
    timeout?: (milliseconds: number) => AbortSignal;
  };
  return signal.timeout ? signal.timeout(UPSTREAM_TIMEOUT_MS) : new AbortController().signal;
}

/** Reads a response body, refusing to buffer more than `limit` bytes. */
export async function readBounded(
  response: Response,
  limit: number = MAX_UPSTREAM_RESPONSE,
): Promise<Uint8Array> {
  const declared = response.headers.get("content-length");
  if (declared !== null) {
    const length = Number(declared);
    if (Number.isFinite(length) && length > limit) {
      throw new UpstreamTooLargeError();
    }
  }
  if (response.body === null) {
    return new Uint8Array(0);
  }
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) {
        break;
      }
      total += value.byteLength;
      if (total > limit) {
        throw new UpstreamTooLargeError();
      }
      chunks.push(value);
    }
  } catch (error) {
    try {
      await reader.cancel();
    } catch {
      // The stream is already failing; the original error is the useful one.
    }
    throw error;
  }
  const body = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    body.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return body;
}

const REDIRECT_STATUSES = new Set([301, 302, 303, 307, 308]);

/** A proxy failure with a client-visible status and message. */
export class ProxyError extends Error {
  constructor(
    readonly status: number,
    message: string,
  ) {
    super(message);
  }
}

export interface FollowOptions {
  method: string;
  headers: Record<string, string>;
  maxRedirects?: number;
}

/**
 * Fetches `start`, handling every redirect manually so each hop can be
 * checked against `allowed`. Never follows a redirect to a different origin
 * unless that origin passes the same check.
 */
export async function fetchFollowing(
  start: URL,
  allowed: (url: URL) => boolean,
  options: FollowOptions,
): Promise<Response> {
  const maxRedirects = options.maxRedirects ?? 5;
  let current = start;
  let method = options.method;
  for (let hop = 0; hop <= maxRedirects; hop += 1) {
    let response: Response;
    try {
      response = await fetch(current.toString(), {
        method,
        headers: options.headers,
        redirect: "manual",
        signal: upstreamSignal(),
      });
    } catch {
      throw new ProxyError(502, OTA_SERVICE_UNREACHABLE);
    }
    if (!REDIRECT_STATUSES.has(response.status)) {
      return response;
    }
    const location = response.headers.get("Location");
    if (response.body !== null) {
      try {
        await response.body.cancel();
      } catch {
        // Discarding a redirect body may fail; it is irrelevant to the client.
      }
    }
    if (location === null) {
      throw new ProxyError(502, "The download server returned an invalid redirect.");
    }
    let next: URL;
    try {
      next = new URL(location, current);
    } catch {
      throw new ProxyError(502, "The download server returned an invalid redirect.");
    }
    if (!allowed(next)) {
      throw new ProxyError(
        502,
        "The download server redirected to a host that is not allowed.",
      );
    }
    if (response.status === 303) {
      method = "GET";
    }
    current = next;
  }
  throw new ProxyError(502, "The download server redirected too many times.");
}
