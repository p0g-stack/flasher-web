import { SELF } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { jsonResponse, mockOutbound } from "./outbound";

const UPSTREAM_ORIGIN = "https://roms.danielspringer.at";
const CATALOG = {
  api_version: "1",
  count: 1,
  releases: [
    {
      id: "op13-glo-13.0.0.1",
      device: "Oneplus 13",
      region: "GLO",
      version: "13.0.0.1",
      source_url: "https://ota.oneplus.com/ota/full.zip",
    },
  ],
};

async function clearCatalogCache(): Promise<void> {
  for (const na of ["0", "1"]) {
    await caches.default.delete(new Request(`http://example.com/api/catalog?na=${na}`));
  }
}

beforeEach(clearCatalogCache);

describe("GET /api/catalog", () => {
  it("proxies the feed, returns its ETag, and caches it for 15 minutes", async () => {
    const out = mockOutbound(() =>
      jsonResponse(CATALOG, { headers: { ETag: '"catalog-1"' } }),
    );
    try {
      const first = await SELF.fetch("http://example.com/api/catalog");
      expect(first.status).toBe(200);
      expect(first.headers.get("etag")).toBe('"catalog-1"');
      expect(first.headers.get("cache-control")).toBe("public, max-age=900");
      expect(await first.json()).toEqual(CATALOG);
      expect(out.calls).toHaveLength(1);
      expect(out.calls[0]?.url).toBe(`${UPSTREAM_ORIGIN}/api/ota.php`);

      const second = await SELF.fetch("http://example.com/api/catalog?na=0");
      expect(second.status).toBe(200);
      expect(await second.json()).toEqual(CATALOG);
      expect(out.calls).toHaveLength(1);
    } finally {
      out.restore();
    }
  });

  it("uses the NA feed for na=1 with a separate cache entry", async () => {
    const out = mockOutbound(() => jsonResponse({ api_version: "1", releases: [] }));
    try {
      const response = await SELF.fetch("http://example.com/api/catalog?na=1");
      expect(response.status).toBe(200);
      expect(out.calls[0]?.url).toBe(`${UPSTREAM_ORIGIN}/api/na.php`);
    } finally {
      out.restore();
    }
  });

  it("forwards If-None-Match and answers 304", async () => {
    const out = mockOutbound((call) => {
      expect(call.headers.get("if-none-match")).toBe('"catalog-1"');
      return new Response(null, { status: 304, headers: { ETag: '"catalog-1"' } });
    });
    try {
      const response = await SELF.fetch("http://example.com/api/catalog", {
        headers: { "If-None-Match": '"catalog-1"' },
      });
      expect(response.status).toBe(304);
      expect(response.headers.get("etag")).toBe('"catalog-1"');
      expect(out.calls).toHaveLength(1);
    } finally {
      out.restore();
    }
  });

  it("rejects an oversized feed", async () => {
    const oversized = "x".repeat(16 * 1024 * 1024 + 1);
    const out = mockOutbound(() => new Response(oversized, { status: 200 }));
    try {
      const response = await SELF.fetch("http://example.com/api/catalog");
      expect(response.status).toBe(502);
      expect(await response.json()).toEqual({
        error: "The OTA service returned an oversized response.",
      });
    } finally {
      out.restore();
    }
  });

  it("rejects a catalog in an unsupported format", async () => {
    const out = mockOutbound(() => jsonResponse({ api_version: "2", releases: [] }));
    try {
      const response = await SELF.fetch("http://example.com/api/catalog");
      expect(response.status).toBe(502);
      expect(await response.json()).toEqual({
        error: "The OTA service returned an unsupported catalog format.",
      });
    } finally {
      out.restore();
    }
  });

  it("rejects invalid JSON and upstream failures", async () => {
    let out = mockOutbound(() => new Response("not json", { status: 200 }));
    try {
      const invalid = await SELF.fetch("http://example.com/api/catalog");
      expect(invalid.status).toBe(502);
      expect(await invalid.json()).toEqual({
        error: "The OTA service returned invalid JSON.",
      });
    } finally {
      out.restore();
    }
    out = mockOutbound(() => new Response("boom", { status: 500 }));
    try {
      const failed = await SELF.fetch("http://example.com/api/catalog");
      expect(failed.status).toBe(502);
      expect(await failed.json()).toEqual({
        error: "OTA service returned HTTP 500. Try again later.",
      });
    } finally {
      out.restore();
    }
  });

  it("rejects unsupported methods and unknown API routes", async () => {
    const post = await SELF.fetch("http://example.com/api/catalog", { method: "POST" });
    expect(post.status).toBe(405);
    expect(post.headers.get("allow")).toBe("GET");
    const unknown = await SELF.fetch("http://example.com/api/unknown");
    expect(unknown.status).toBe(404);
  });
});
