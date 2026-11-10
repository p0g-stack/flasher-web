import { Bucket, RequestBudget, type BucketEnv } from "./bucket";
import { blockKey, CATALOG_ORIGIN, COMPLETE_PREFIX, fillBlock, getManifest, RELEASE_PREFIX, validId, type Release } from "./blocks";
import { validateCatalog } from "./catalog";
import { MAX_UPSTREAM_RESPONSE, readBounded, upstreamSignal } from "./upstream";

interface WarmEnv extends BucketEnv { ASSETS: Fetcher }
interface CatalogSnapshot { etag: string | null; releases: Release[]; checkedAt: number }
export interface WarmResult { subrequests: number; warmed: number; deleted: number; selected: number; exhausted: boolean }

/** Derive labels, including OP PAD2 / Oneplus Pad 2, without a device registry. */
export function deviceKey(label: string): string {
  return label.toLowerCase().replace(/^oneplus\b/, "op").replace(/[^a-z0-9]/g, "");
}

/** One latest release per supported device/region; order-independent ties. */
export function selectLatest(releases: Release[], devices: Record<string, unknown>): Release[] {
  const supported = new Set(Object.keys(devices).map(deviceKey));
  const latest = new Map<string, Release>();
  for (const release of releases) {
    if (!validId(release.id) || !supported.has(deviceKey(release.device))) continue;
    const key = `${deviceKey(release.device)}/${release.region}`;
    const previous = latest.get(key);
    if (!previous || compareRelease(release, previous) > 0) latest.set(key, release);
  }
  return [...latest.values()].sort((a, b) => `${deviceKey(a.device)}/${a.region}`.localeCompare(`${deviceKey(b.device)}/${b.region}`));
}
function compareRelease(a: Release, b: Release): number {
  // Dedicated reconstructed-full NA entries have no is_latest flag. Published
  // time and natural version order decide duplicates returned by that feed.
  const timestamp = (a.published ?? (Date.parse(a.build_timestamp ?? "") || 0)) - (b.published ?? (Date.parse(b.build_timestamp ?? "") || 0));
  const latest = Number(a.is_latest === true) - Number(b.is_latest === true);
  return timestamp || latest || a.version.localeCompare(b.version, "en", { numeric: true }) || a.id.localeCompare(b.id);
}

async function poll(bucket: Bucket, feed: string): Promise<Release[]> {
  const key = `ota/v1/catalog/${feed}.json`;
  const previous = await bucket.json<CatalogSnapshot>(key, MAX_UPSTREAM_RESPONSE);
  // A one-minute warmer must not poll the catalog more often than the
  // provider's recommended 900-second interval.
  if (previous && Number.isFinite(previous.checkedAt) && Date.now() - previous.checkedAt < 900_000) return previous.releases;
  bucket.budget.take();
  const response = await fetch(`${CATALOG_ORIGIN}${feed}?latest=1`, {
    headers: { "User-Agent": "FlasherBuilder/1.0", ...(previous?.etag ? { "If-None-Match": previous.etag } : {}) },
    signal: upstreamSignal(), redirect: "manual",
  });
  if (response.status === 304 && previous) {
    await bucket.put(key, JSON.stringify({ ...previous, checkedAt: Date.now() }), { "Content-Type": "application/json", "Cache-Control": "no-store" });
    return previous.releases;
  }
  if (!response.ok) { await response.body?.cancel(); throw new Error("OTA catalog polling failed; no cache objects were deleted."); }
  const data = JSON.parse(new TextDecoder().decode(await readBounded(response)));
  validateCatalog(data);
  const snapshot: CatalogSnapshot = { etag: response.headers.get("ETag"), releases: data.releases, checkedAt: Date.now() };
  await bucket.put(key, JSON.stringify(snapshot), { "Content-Type": "application/json", "Cache-Control": "no-store" });
  return snapshot.releases;
}

/** Bucket contents are the only progress state. Every run recomputes gaps. */
export async function warmCache(env: WarmEnv, scheduledTime = Date.now()): Promise<WarmResult> {
  const budget = new RequestBudget(48, Date.now() + 12 * 60_000);
  const bucket = new Bucket(env, budget);
  const result: WarmResult = { subrequests: 0, warmed: 0, deleted: 0, selected: 0, exhausted: false };
  try {
    // Finish both conditional polls and validate the asset before any deletion.
    const regular = await poll(bucket, "ota.php");
    const na = await poll(bucket, "na.php");
    budget.take();
    const tablesResponse = await env.ASSETS.fetch(new Request("https://assets/upstream/tables.json"));
    if (!tablesResponse.ok) throw new Error("The supported-device asset is unavailable.");
    const tables = JSON.parse(new TextDecoder().decode(await readBounded(tablesResponse, 256 * 1024)));
    if (!tables.devices || typeof tables.devices !== "object" || Array.isArray(tables.devices) || Object.keys(tables.devices).length === 0) throw new Error("The supported-device table is invalid.");
    const selected = selectLatest([...regular, ...na], tables.devices);
    if (selected.length === 0) throw new Error("The catalog has no supported releases; refusing to delete the cache.");
    result.selected = selected.length;
    const current = new Set(selected.map(entry => `${RELEASE_PREFIX}${entry.id}/`));
    const markers = (await bucket.list(COMPLETE_PREFIX)).keys;
    const root = await bucket.list(RELEASE_PREFIX, { delimiter: "/" });
    // Markers are retired before any data; deletion is a bounded 1000-key
    // batch. Unfinished deletion is rediscovered from the bucket next time.
    for (const prefix of root.prefixes) {
      if (current.has(prefix) || budget.remaining < 5) continue;
      const id = prefix.slice(RELEASE_PREFIX.length, -1);
      const retired = await bucket.list(`${COMPLETE_PREFIX}${id}/`);
      await bucket.delete(retired.keys);
      const page = await bucket.list(prefix);
      await bucket.delete(page.keys);
      result.deleted += page.keys.length + retired.keys.length;
    }
    const fingerprints = new Map(await Promise.all(selected.map(async release =>
      [release.id, await releaseFingerprint(release)] as const)));
    const incomplete = selected.filter(release =>
      !markers.some(key => key.startsWith(`${COMPLETE_PREFIX}${release.id}/${fingerprints.get(release.id)}/`)));
    // No persisted cursor. Rotate incomplete releases to avoid starvation when
    // a release is large or its upstream is temporarily unavailable.
    const start = incomplete.length ? Math.floor(scheduledTime / 60_000) % incomplete.length : 0;
    const ordered = [...incomplete.slice(start), ...incomplete.slice(0, start)];
    for (const release of ordered) {
      if (budget.remaining < 10) { result.exhausted = true; break; }
      try {
        const manifest = await getManifest(bucket, release.id, release);
        const obsoleteMarkers = markers.filter(key => key.startsWith(`${COMPLETE_PREFIX}${release.id}/`));
        await bucket.delete(obsoleteMarkers);
        const generations = await bucket.list(`${RELEASE_PREFIX}${release.id}/`, { delimiter: "/" });
        for (const prefix of generations.prefixes) {
          if (prefix === `${RELEASE_PREFIX}${release.id}/${manifest.identity}/`) continue;
          if (budget.remaining < 4) { result.exhausted = true; break; }
          const obsolete = await bucket.list(prefix);
          await bucket.delete(obsolete.keys);
          result.deleted += obsolete.keys.length;
          if (obsolete.next) { result.exhausted = true; break; }
        }
        if (result.exhausted) break;
        const present = await listGeneration(bucket, `${RELEASE_PREFIX}${release.id}/${manifest.identity}/`);
        const count = Math.ceil(manifest.length / manifest.blockSize);
        let filled = false;
        for (let n = 0; n < count; n++) {
          if (present.has(blockKey(manifest, n))) continue;
          // LIST already proved absence; a steady block costs CDN GET + PUT.
          // Reserve room for a renewed resolver or a redirect at the edge.
          if (budget.remaining < 4) { result.exhausted = true; break; }
          await fillBlock(bucket, manifest, n, release, true);
          result.warmed++;
          filled = true;
        }
        if (result.exhausted) break;
        const proof = filled ? await listGeneration(bucket, `${RELEASE_PREFIX}${release.id}/${manifest.identity}/`) : present;
        if (Array.from({ length: count }, (_, n) => blockKey(manifest, n)).every(key => proof.has(key))) {
          await bucket.put(`${COMPLETE_PREFIX}${release.id}/${fingerprints.get(release.id)}/${manifest.identity}`, JSON.stringify(manifest), { "Content-Type": "application/json", "Cache-Control": "no-store" });
        }
      } catch (error) {
        if (budget.remaining === 0 || Date.now() >= budget.deadline) throw error;
        // A broken upstream release must not starve other devices. Never log a
        // resolved URL or its signature, including through an exception string.
        console.warn("OTA warm release unavailable", release.id);
      }
    }
  } catch (error) {
    if (budget.remaining === 0 || Date.now() >= budget.deadline) result.exhausted = true;
    else throw error;
  } finally {
    result.subrequests = budget.used;
  }
  return result;
}

async function listGeneration(bucket: Bucket, prefix: string): Promise<Set<string>> {
  const keys = new Set<string>();
  let token: string | undefined;
  do {
    const page = await bucket.list(prefix, { token });
    for (const key of page.keys) keys.add(key);
    token = page.next ?? undefined;
  } while (token);
  return keys;
}

async function releaseFingerprint(release: Release): Promise<string> {
  const source = new URL(release.source_url);
  for (const key of [...source.searchParams.keys()]) {
    if (/^(expires|signature|x-oss-|x-amz-)/i.test(key)) source.searchParams.delete(key);
  }
  const bytes = new TextEncoder().encode(JSON.stringify([release.id, release.size ?? null, release.md5 ?? null, release.version, source.toString()]));
  const hash = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(hash), byte => byte.toString(16).padStart(2, "0")).join("");
}
