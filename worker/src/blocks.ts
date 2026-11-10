import { Bucket, type BucketEnv, RequestBudget } from "./bucket";
import { validateCatalog } from "./catalog";
import { json, jsonError } from "./http";
import { OTA_REQUEST_HEADERS, otaUrlAllowed } from "./ota";
import { readCatalogEntry, resolveLink, usableLink, type CatalogEntry } from "./resolve";
import { ProxyError, readBounded, upstreamSignal } from "./upstream";

export const BLOCK_SIZE = 8 * 1024 * 1024;
export const RELEASE_PREFIX = "ota/v1/releases/";
export const COMPLETE_PREFIX = "ota/v1/complete/";
export const CATALOG_ORIGIN = "https://roms.danielspringer.at/api/";
export interface Release extends CatalogEntry {
  id: string;
  size?: number;
  md5?: string;
  is_latest?: boolean;
  published?: number;
  build_timestamp?: string;
}
export interface BlockManifest {
  id: string;
  identity: string;
  etag: string;
  length: number;
  blockSize: number;
  created: string;
}

export function validId(id: string): boolean { return /^[A-Za-z0-9_-]{1,128}$/.test(id); }
export function manifestKey(id: string): string { return `${RELEASE_PREFIX}${id}/manifest.json`; }
export function blockKey(manifest: BlockManifest, n: number): string {
  return `${RELEASE_PREFIX}${manifest.id}/${manifest.identity}/${n}`;
}
export function strongEtag(etag: string | null): etag is string {
  return etag !== null && /^"[^"\x00-\x20\x7f]+"$/.test(etag);
}
export function validateManifest(value: BlockManifest, id: string): BlockManifest {
  if (!value || value.id !== id || !/^[a-f0-9]{64}$/.test(value.identity) || !strongEtag(value.etag) ||
      !Number.isSafeInteger(value.length) || value.length <= 0 || value.blockSize !== BLOCK_SIZE ||
      typeof value.created !== "string" || !Number.isFinite(Date.parse(value.created))) {
    throw new ProxyError(502, "The OTA cache manifest is invalid.");
  }
  return value;
}

// Only completed, immutable values may cross Worker request contexts. Never
// cache promises, streams or resolvers here: another request cannot own them.
const links = new Map<string, { url: string; until: number }>();
function scope(bucket: Bucket, id: string): string {
  return `${bucket.env.OTA_S3_ENDPOINT}/${bucket.env.OTA_S3_BUCKET}/${id}`;
}

async function loadRelease(id: string, budget: RequestBudget): Promise<Release> {
  for (const feed of ["ota.php", "na.php"]) {
    budget.take();
    const response = await fetch(`${CATALOG_ORIGIN}${feed}?id=${encodeURIComponent(id)}`, { headers: { "User-Agent": "FlasherBuilder/1.0" }, redirect: "manual", signal: upstreamSignal() });
    if (!response.ok) { await response.body?.cancel(); throw new ProxyError(502, `Could not read the OTA catalog (HTTP ${response.status}).`); }
    const data = JSON.parse(new TextDecoder().decode(await readBounded(response)));
    validateCatalog(data);
    const release = data.releases.find((entry: Release) => entry.id === id) as Release | undefined;
    if (release && readCatalogEntry(release)) return release;
  }
  throw new ProxyError(404, "The catalog release does not exist.");
}

async function signedLink(bucket: Bucket, id: string, release?: Release): Promise<string> {
  const key = scope(bucket, id);
  const cached = links.get(key);
  if (cached && cached.until > Date.now() && usableLink(cached.url)) return cached.url;
  links.delete(key);
  const url = await resolveLink(release ?? await loadRelease(id, bucket.budget), () => bucket.budget.take());
  if (!otaUrlAllowed(new URL(url))) throw new ProxyError(502, "The resolved OTA host is not allowed.");
  // Never keep a signed link longer than two minutes, even without an expiry.
  if (links.size >= 32) links.delete(links.keys().next().value!);
  links.set(key, { url, until: Date.now() + 120_000 });
  return url;
}

async function upstreamRange(bucket: Bucket, url: string, start: number, end: number, etag?: string): Promise<Response> {
  let target = new URL(url);
  for (let redirects = 0; redirects <= 3; redirects++) {
    if (!otaUrlAllowed(target)) throw new ProxyError(502, "The resolved OTA host is not allowed.");
    bucket.budget.take();
    const response = await fetch(target.toString(), {
      headers: { ...OTA_REQUEST_HEADERS, Range: `bytes=${start}-${end}`, ...(etag ? { "If-Match": etag } : {}) },
      redirect: "manual",
      signal: upstreamSignal(),
    });
    if (![301, 302, 303, 307, 308].includes(response.status)) return response;
    const location = response.headers.get("Location");
    await response.body?.cancel();
    if (!location) throw new ProxyError(502, "The OTA redirect is invalid.");
    target = new URL(location, target);
  }
  throw new ProxyError(502, "Too many OTA redirects.");
}

async function createManifest(bucket: Bucket, id: string, release?: Release, refresh = false): Promise<BlockManifest> {
  if (!refresh) {
    const existing = await bucket.json<BlockManifest>(manifestKey(id));
    if (existing) return validateManifest(existing, id);
  }
  const entry = release ?? await loadRelease(id, bucket.budget);
  const response = await upstreamRange(bucket, await signedLink(bucket, id, entry), 0, 0);
  const range = /^bytes 0-0\/(\d+)$/.exec(response.headers.get("Content-Range") ?? "");
  const etag = response.headers.get("ETag");
  const length = Number(range?.[1]);
  if (response.status !== 206 || !range || !strongEtag(etag) || !Number.isSafeInteger(length) || length <= 0 ||
      (entry.size !== undefined && (!Number.isSafeInteger(entry.size) || entry.size !== length))) {
    await response.body?.cancel();
    throw new ProxyError(502, "The OTA probe did not provide a stable ranged file.");
  }
  if ((await readBounded(response, 1)).byteLength !== 1) throw new ProxyError(502, "The OTA probe was truncated.");
  const hash = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(JSON.stringify([id, etag, length])));
  const identity = Array.from(new Uint8Array(hash), byte => byte.toString(16).padStart(2, "0")).join("");
  const manifest: BlockManifest = { id, identity, etag, length, blockSize: BLOCK_SIZE, created: new Date().toISOString() };
  const generationKey = `${RELEASE_PREFIX}${id}/${identity}/manifest.json`;
  const generation = await bucket.json<BlockManifest>(generationKey);
  const pinned = generation ? validateManifest(generation, id) : manifest;
  if (!generation) await bucket.put(generationKey, JSON.stringify(pinned), { "Content-Type": "application/json", "Cache-Control": "public, max-age=31536000, immutable" });
  if (refresh) {
    const markers = await bucket.list(`${COMPLETE_PREFIX}${id}/`);
    await bucket.delete(markers.keys);
  }
  await bucket.put(manifestKey(id), JSON.stringify(pinned), { "Content-Type": "application/json", "Cache-Control": "no-store" });
  return pinned;
}

export function getManifest(bucket: Bucket, id: string, release?: Release): Promise<BlockManifest> {
  return createManifest(bucket, id, release);
}

export async function fillBlock(bucket: Bucket, manifest: BlockManifest, n: number, release?: Release, knownMissing = false): Promise<Uint8Array> {
  const key = blockKey(manifest, n);
  const start = n * BLOCK_SIZE;
  const end = Math.min(start + BLOCK_SIZE, manifest.length) - 1;
  // LIST-proven cron misses need only CDN GET + PUT. Every request owns its
  // own I/O; concurrent writes to this immutable key contain identical bytes.
  if (!knownMissing) {
    const existing = await bucket.get(key);
    if (existing) {
      if (existing.headers.get("x-amz-meta-ota-etag") !== manifest.etag) {
        await existing.body?.cancel();
        throw new ProxyError(502, "The cached block identity does not match its manifest.");
      }
      const body = await readBounded(existing, end - start + 1);
      if (body.byteLength !== end - start + 1) throw new ProxyError(502, "The cached OTA block is truncated.");
      return body;
    }
  }
  const response = await upstreamRange(bucket, await signedLink(bucket, manifest.id, release), start, end, manifest.etag);
  if (response.status === 412 || (strongEtag(response.headers.get("ETag")) && response.headers.get("ETag") !== manifest.etag)) {
    await response.body?.cancel();
    links.delete(scope(bucket, manifest.id));
    await createManifest(bucket, manifest.id, undefined, true);
    throw new ProxyError(409, "The upstream OTA changed generation. Reopen the OTA.");
  }
  if (response.status !== 206 || response.headers.get("Content-Range") !== `bytes ${start}-${end}/${manifest.length}` ||
      response.headers.get("ETag") !== manifest.etag ||
      (response.headers.has("Content-Encoding") && response.headers.get("Content-Encoding") !== "identity")) {
    await response.body?.cancel();
    throw new ProxyError(502, "The OTA block changed identity or did not match the requested range.");
  }
  const body = await readBounded(response, end - start + 1);
  if (body.byteLength !== end - start + 1) throw new ProxyError(502, "The OTA block is truncated.");
  await bucket.put(key, body, { "Content-Type": "application/octet-stream", "Cache-Control": "public, max-age=31536000, immutable", "x-amz-meta-ota-etag": manifest.etag });
  return body;
}

export async function handleBlock(url: URL, env: BucketEnv): Promise<Response> {
  const id = url.searchParams.get("id") ?? "";
  if (!validId(id)) return jsonError(400, "A valid catalog release id is required.");
  const bucket = new Bucket(env);
  const manifest = await getManifest(bucket, id);
  if (url.pathname === "/api/manifest") {
    const response = json(manifest);
    response.headers.set("X-Cache-Subrequests", String(bucket.budget.used));
    return response;
  }
  const identity = url.searchParams.get("v");
  if (identity !== manifest.identity) return jsonError(409, "The OTA manifest identity changed. Reopen the OTA.");
  const raw = url.searchParams.get("n") ?? "";
  const n = Number(raw);
  if (!/^(0|[1-9]\d*)$/.test(raw) || !Number.isSafeInteger(n) || n >= Math.ceil(manifest.length / BLOCK_SIZE)) {
    return jsonError(416, "The OTA block number is outside the file.");
  }
  const body = await fillBlock(bucket, manifest, n);
  return new Response(body, { headers: { "Content-Type": "application/octet-stream", "Content-Length": String(body.byteLength), "Cache-Control": "no-store", "x-amz-meta-ota-etag": manifest.etag, "X-Cache-Subrequests": String(bucket.budget.used) } });
}
