import { createExecutionContext, SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import worker, { type Env } from "../src/index";
import { BLOCK_SIZE, blockKey, COMPLETE_PREFIX, manifestKey, RELEASE_PREFIX, type BlockManifest, type Release } from "../src/blocks";
import { selectLatest, warmCache } from "../src/warm";
import { mockOutbound, jsonResponse, type OutboundCall, type OutboundMock } from "./outbound";

let serial = 0;
function release(id: string, extra: Partial<Release> = {}): Release {
  return { id, device: "OP 13", region: "GLO", version: "16.0.1", source_url: `https://ota.oneplus.com/${id}.zip`, package_type: null, size: 12, is_latest: true, ...extra };
}
interface Stored { body: string; headers: Headers }
class FakeCache {
  readonly objects = new Map<string, Stored>();
  readonly actions: string[] = [];
  readonly env: Env;
  readonly mock: OutboundMock;
  readonly tags = new Map<string, string>();
  regular: Release[];
  na: Release[] = [];
  conditional = false;
  failCatalog = false;
  malformed: ((call: OutboundCall) => Response | null) | null = null;
  asyncCdn = false;
  constructor(releases = [release("test-id")], endpoint = `https://s3-${++serial}.example`) {
    this.regular = releases;
    this.env = {
      OTA_S3_ENDPOINT: endpoint, OTA_S3_BUCKET: "ota", OTA_S3_REGION: "garage",
      OTA_S3_ACCESS_KEY_ID: "local-key", OTA_S3_SECRET_ACCESS_KEY: "local-secret", OTA_PUBLIC_BASE: "https://public.example/",
      ASSETS: { fetch: async () => jsonResponse({ devices: { "Oneplus 13": "13", "Oneplus Pad 2 Pro": "Pad2Pro" } }) } as unknown as Fetcher,
    };
    this.mock = mockOutbound(async call => {
      const url = new URL(call.url);
      if (url.origin === endpoint) return this.s3(call, url);
      if (url.hostname === "roms.danielspringer.at" && url.pathname.startsWith("/api/")) {
        if (this.failCatalog) return new Response("offline", { status: 503 });
        const list = url.pathname.endsWith("na.php") ? this.na : this.regular;
        if (this.conditional && call.headers.get("If-None-Match") === '"catalog"') return new Response(null, { status: 304 });
        return jsonResponse({ api_version: "1", releases: url.searchParams.has("id") ? list.filter(entry => entry.id === url.searchParams.get("id")) : list }, { headers: { ETag: '"catalog"' } });
      }
      if (url.hostname === "ota.oneplus.com") {
        const overridden = this.malformed?.(call);
        if (overridden) return overridden;
        const id = url.pathname.slice(1, -4);
        const entry = [...this.regular, ...this.na].find(entry => entry.id === id)!;
        const tag = this.tags.get(id) ?? '"upstream"';
        if (call.headers.has("If-Match") && call.headers.get("If-Match") !== tag) return new Response(null, { status: 412 });
        const range = /^bytes=(\d+)-(\d+)$/.exec(call.headers.get("Range") ?? "")!;
        const start = Number(range[1]), end = Number(range[2]);
        expect(end).toBeLessThan(entry.size!);
        if (this.asyncCdn) await crypto.subtle.digest("SHA-256", new Uint8Array(1));
        return new Response("x".repeat(end - start + 1), { status: 206, headers: { "Content-Range": `bytes ${start}-${end}/${entry.size}`, "Content-Length": String(end - start + 1), ETag: tag } });
      }
      throw new Error(`Unexpected fake host ${url.hostname}`);
    });
  }
  restore(): void { this.mock.restore(); }
  async get(path: string): Promise<Response> {
    return worker.fetch(new Request(`https://worker.example${path}`), this.env, createExecutionContext());
  }
  private s3(call: OutboundCall, url: URL): Response {
    expect(call.headers.get("Authorization")).toMatch(/^AWS4-HMAC-SHA256 Credential=local-key\//);
    expect(call.headers.get("x-amz-content-sha256")).toBe("UNSIGNED-PAYLOAD");
    const key = decodeURIComponent(url.pathname.slice("/ota/".length));
    if (url.searchParams.has("list-type")) {
      const prefix = url.searchParams.get("prefix") ?? "";
      const delimiter = url.searchParams.get("delimiter");
      const keys = [...this.objects.keys()].filter(key => key.startsWith(prefix)).sort();
      const prefixes = new Set<string>();
      const direct: string[] = [];
      for (const key of keys) {
        const tail = key.slice(prefix.length);
        if (delimiter && tail.includes(delimiter)) prefixes.add(prefix + tail.split(delimiter)[0] + delimiter);
        else direct.push(key);
      }
      return new Response(`<ListBucketResult><Prefix>${prefix}</Prefix>${direct.map(key => `<Contents><Key>${key}</Key></Contents>`).join("")}${[...prefixes].map(value => `<CommonPrefixes><Prefix>${value}</Prefix></CommonPrefixes>`).join("")}</ListBucketResult>`);
    }
    if (url.searchParams.has("delete")) {
      for (const match of call.body!.matchAll(/<Key>(.*?)<\/Key>/g)) {
        this.actions.push(`delete:${match[1]}`);
        this.objects.delete(match[1]!);
      }
      return new Response("<DeleteResult/>");
    }
    if (call.method === "PUT") {
      this.actions.push(`put:${key}`);
      this.objects.set(key, { body: call.body!, headers: new Headers(call.headers) });
      return new Response(null);
    }
    expect(call.method).toBe("GET");
    const object = this.objects.get(key);
    return object ? new Response(object.body, { headers: object.headers }) : new Response(null, { status: 404 });
  }
}

async function open(fake: FakeCache, id = "test-id"): Promise<BlockManifest> {
  const response = await fake.get(`/api/manifest?id=${id}`);
  expect(response.status).toBe(200);
  return response.json<BlockManifest>();
}

describe("edge byte cache", () => {
  it("explains how to start an unconfigured local bucket", async () => {
    const fake = new FakeCache();
    try {
      const response = await worker.fetch(new Request("https://worker.example/api/manifest?id=test-id"), { ...fake.env, OTA_S3_ENDPOINT: undefined }, createExecutionContext());
      expect(response.status).toBe(503);
      expect((await response.json<{ error: string }>()).error).toContain("./tool/dev_garage.sh");
    } finally { fake.restore(); }
  });

  it("keeps concurrent immutable fills request-local and reuses stored bytes", async () => {
    const fake = new FakeCache();
    try {
      const [manifest, duplicate] = await Promise.all([open(fake), open(fake)]);
      expect(duplicate.identity).toBe(manifest.identity);
      expect(manifest).toMatchObject({ id: "test-id", etag: '"upstream"', length: 12, blockSize: BLOCK_SIZE });
      expect(manifest.identity).toMatch(/^[a-f0-9]{64}$/);
      expect(fake.objects.has(`${RELEASE_PREFIX}test-id/${manifest.identity}/manifest.json`)).toBe(true);
      const path = `/api/block?id=test-id&v=${manifest.identity}&n=0`;
      const responses = await Promise.all([fake.get(path), fake.get(path)]);
      expect(await responses[0].text()).toBe("x".repeat(12));
      expect(await responses[1].text()).toBe("x".repeat(12));
      expect(responses[0].headers.get("x-amz-meta-ota-etag")).toBe(manifest.etag);
      expect(fake.actions.filter(action => action === `put:${blockKey(manifest, 0)}`).length).toBeGreaterThanOrEqual(1);
      const cdnCalls = fake.mock.calls.filter(call => new URL(call.url).hostname === "ota.oneplus.com").length;
      const again = await fake.get(path);
      expect(again.status).toBe(200);
      expect(await again.text()).toBe("x".repeat(12));
      expect(fake.mock.calls.filter(call => new URL(call.url).hostname === "ota.oneplus.com")).toHaveLength(cdnCalls);
      expect((await open(fake)).identity).toBe(manifest.identity);
    } finally { fake.restore(); }
  });

  it("serves 20 parallel cold misses in independent Worker contexts, including duplicates", async () => {
    const releases = Array.from({ length: 12 }, (_, n) => release(`parallel-${n}`));
    const fake = new FakeCache(releases, "https://s3-pool.example");
    fake.asyncCdn = true;
    try {
      const manifests = await Promise.all(releases.map(async entry => {
        const reply = await SELF.fetch(`https://worker.example/api/manifest?id=${entry.id}`);
        expect(reply.status).toBe(200);
        return reply.json<BlockManifest>();
      }));
      const replies = await Promise.all(Array.from({ length: 20 }, (_, n) => {
        const manifest = manifests[n % manifests.length]!;
        return SELF.fetch(`https://worker.example/api/block?id=${manifest.id}&v=${manifest.identity}&n=0`);
      }));
      for (const reply of replies) {
        expect(reply.status).toBe(200);
        expect(new TextDecoder().decode(await reply.arrayBuffer())).toBe("x".repeat(12));
      }
      for (const manifest of manifests) expect(fake.objects.get(blockKey(manifest, 0))?.body).toBe("x".repeat(12));
    } finally { fake.restore(); }
  });

  it("aligns middle/tail blocks and refuses invalid number or generation", async () => {
    const fake = new FakeCache([release("test-id", { size: BLOCK_SIZE + 3 })]);
    try {
      const manifest = await open(fake);
      const response = await fake.get(`/api/block?id=test-id&v=${manifest.identity}&n=1`);
      expect(response.status).toBe(200);
      expect(await response.text()).toBe("xxx");
      expect(fake.mock.calls.at(-2)?.headers.get("Range")).toBe(`bytes=${BLOCK_SIZE}-${BLOCK_SIZE + 2}`);
      expect((await fake.get(`/api/block?id=test-id&v=${manifest.identity}&n=2`)).status).toBe(416);
      expect((await fake.get(`/api/block?id=test-id&v=wrong&n=0`)).status).toBe(409);
      expect((await fake.get("/api/manifest?id=../escape")).status).toBe(400);
    } finally { fake.restore(); }
  });

  it("never stores a wrong Content-Range or truncated body", async () => {
    const fake = new FakeCache();
    try {
      const manifest = await open(fake);
      fake.malformed = () => new Response("xxx", { status: 206, headers: { "Content-Range": "bytes 0-2/12", ETag: manifest.etag } });
      expect((await fake.get(`/api/block?id=test-id&v=${manifest.identity}&n=0`)).status).toBe(502);
      expect(fake.objects.has(blockKey(manifest, 0))).toBe(false);
      fake.malformed = () => new Response("xxx", { status: 206, headers: { "Content-Range": "bytes 0-11/12", ETag: manifest.etag } });
      expect((await fake.get(`/api/block?id=test-id&v=${manifest.identity}&n=0`)).status).toBe(502);
      expect(fake.objects.has(blockKey(manifest, 0))).toBe(false);
    } finally { fake.restore(); }
  });

  it("publishes a changed upstream generation but fails the old pinned read", async () => {
    const fake = new FakeCache();
    try {
      const old = await open(fake);
      fake.objects.set(`${COMPLETE_PREFIX}test-id/fingerprint/${old.identity}`, { body: "complete", headers: new Headers() });
      fake.tags.set("test-id", '"replacement"');
      const response = await fake.get(`/api/block?id=test-id&v=${old.identity}&n=0`);
      expect(response.status).toBe(409);
      expect(fake.objects.has(blockKey(old, 0))).toBe(false);
      const current = await open(fake);
      expect(current.etag).toBe('"replacement"');
      expect(current.identity).not.toBe(old.identity);
      expect(fake.objects.has(`${RELEASE_PREFIX}test-id/${old.identity}/manifest.json`)).toBe(true);
      expect(fake.objects.has(`${COMPLETE_PREFIX}test-id/fingerprint/${old.identity}`)).toBe(false);
      expect((await fake.get(`/api/block?id=test-id&v=${current.identity}&n=0`)).status).toBe(200);
      const retirement = await warmCache(fake.env, 0);
      expect(retirement.deleted).toBe(1);
      expect(fake.objects.has(`${RELEASE_PREFIX}test-id/${old.identity}/manifest.json`)).toBe(false);
      expect(fake.objects.has(blockKey(current, 0))).toBe(true);
    } finally { fake.restore(); }
  });

  it("rejects a missing strong ETag or catalog-length mismatch before writing", async () => {
    const fake = new FakeCache();
    try {
      fake.malformed = () => new Response("x", { status: 206, headers: { "Content-Range": "bytes 0-0/12", ETag: 'W/"weak"' } });
      expect((await fake.get("/api/manifest?id=test-id")).status).toBe(502);
      fake.malformed = () => new Response("x", { status: 206, headers: { "Content-Range": "bytes 0-0/13", ETag: '"strong"' } });
      expect((await fake.get("/api/manifest?id=test-id")).status).toBe(502);
      expect(fake.objects.has(manifestKey("test-id"))).toBe(false);
    } finally { fake.restore(); }
  });
});

describe("cron cache plan", () => {
  it("derives supported labels, ignores unsupported devices, selects latest per region", () => {
    const releases = [release("old", { is_latest: false }), release("new"), release("cn", { region: "CN" }), release("pad", { device: "OP PAD2 PRO" }), release("unsupported", { device: "OP 10" })];
    expect(selectLatest(releases.reverse(), { "Oneplus 13": "13", "Oneplus Pad 2 Pro": "Pad2Pro" }).map(entry => entry.id)).toEqual(["cn", "new", "pad"]);
  });

  it("warms through fill path, marks proven completion, polls with ETag, retires markers first", async () => {
    const fake = new FakeCache([release("current")]);
    try {
      fake.objects.set(`${RELEASE_PREFIX}old/generation/0`, { body: "old", headers: new Headers() });
      fake.objects.set(`${COMPLETE_PREFIX}old/fingerprint/generation`, { body: "old", headers: new Headers() });
      const result = await warmCache(fake.env, 0);
      expect(result).toMatchObject({ warmed: 1, deleted: 2, selected: 1, exhausted: false });
      expect(result.subrequests).toBeLessThanOrEqual(48);
      const manifest = JSON.parse(fake.objects.get(manifestKey("current"))!.body) as BlockManifest;
      expect(fake.objects.has(blockKey(manifest, 0))).toBe(true);
      expect([...fake.objects.keys()].some(key => key.startsWith(`${COMPLETE_PREFIX}current/`))).toBe(true);
      expect(fake.actions.indexOf(`delete:${COMPLETE_PREFIX}old/fingerprint/generation`)).toBeLessThan(fake.actions.indexOf(`delete:${RELEASE_PREFIX}old/generation/0`));
      const before = fake.mock.calls.length;
      fake.conditional = true;
      for (const feed of ["ota.php", "na.php"]) {
        const key = `ota/v1/catalog/${feed}.json`;
        const stored = fake.objects.get(key)!;
        fake.objects.set(key, { ...stored, body: JSON.stringify({ ...JSON.parse(stored.body), checkedAt: 0 }) });
      }
      const repeat = await warmCache(fake.env, 900_000);
      expect(repeat.warmed).toBe(0);
      expect(fake.mock.calls.slice(before).filter(call => new URL(call.url).hostname === "ota.oneplus.com")).toHaveLength(0);
      expect(fake.mock.calls.slice(before).filter(call => call.headers.has("If-None-Match"))).toHaveLength(2);
      const after = fake.mock.calls.length;
      const cached = await warmCache(fake.env, 60_000);
      expect(cached.warmed).toBe(0);
      expect(fake.mock.calls.slice(after).filter(call => new URL(call.url).hostname === "roms.danielspringer.at")).toHaveLength(0);
    } finally { fake.restore(); }
  });

  it("hard-counts its Free budget and rotates incomplete releases without a cursor", async () => {
    const fake = new FakeCache(Array.from({ length: 24 }, (_, n) => release(`release-${n}`, { region: `R${n}` })));
    try {
      const first = await warmCache(fake.env, 0);
      expect(first.exhausted).toBe(true);
      expect(first.warmed).toBeGreaterThan(0);
      expect(first.subrequests).toBe(fake.mock.calls.length + 1);
      expect(first.subrequests).toBeLessThanOrEqual(48);
      const completed = [...fake.objects.keys()].filter(key => key.startsWith(COMPLETE_PREFIX));
      fake.conditional = true;
      const before = fake.mock.calls.length;
      const second = await warmCache(fake.env, 900_000);
      expect(second.warmed).toBeGreaterThan(0);
      expect(second.subrequests).toBe(fake.mock.calls.length - before + 1);
      expect(second.subrequests).toBeLessThanOrEqual(48);
      expect([...fake.objects.keys()].filter(key => key.startsWith(COMPLETE_PREFIX)).length).toBeGreaterThan(completed.length);
    } finally { fake.restore(); }
  });

  it("does not delete anything when the catalog cannot be refreshed", async () => {
    const fake = new FakeCache();
    try {
      fake.objects.set(`${RELEASE_PREFIX}old/0`, { body: "old", headers: new Headers() });
      fake.failCatalog = true;
      await expect(warmCache(fake.env, 0)).rejects.toThrow("catalog polling failed");
      expect(fake.objects.has(`${RELEASE_PREFIX}old/0`)).toBe(true);
      expect(fake.actions.filter(action => action.startsWith("delete:"))).toEqual([]);
    } finally { fake.restore(); }
  });
});
