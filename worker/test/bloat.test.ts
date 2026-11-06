import { SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { mockOutbound, redirectResponse } from "./outbound";

const GITHUB_PREFIX =
  "https://github.com/koaaN/Flasher_Builder/releases/download/bloat-assets-v1/";
const ASSET = "bloat-15-CN_BLOAT-my_preload-f8a7f665242c.img";
const OBJECT_URL = "https://release-assets.githubusercontent.com/github-production-release-asset/1?token=signed";

function bloatRequest(name: string, init: RequestInit = {}): Promise<Response> {
  return SELF.fetch(`http://example.com/api/bloat/${name}`, init);
}

describe("GET /api/bloat", () => {
  it("follows GitHub's redirect and streams the requested range", async () => {
    const out = mockOutbound((call) => {
      if (call.url === `${GITHUB_PREFIX}${ASSET}`) {
        expect(call.headers.get("range")).toBe("bytes=0-99");
        return redirectResponse(OBJECT_URL);
      }
      if (call.url === OBJECT_URL) {
        expect(call.headers.get("range")).toBe("bytes=0-99");
        return new Response("x".repeat(100), {
          status: 206,
          headers: {
            "Content-Range": "bytes 0-99/1823779125",
            "Content-Length": "100",
            "Accept-Ranges": "bytes",
          },
        });
      }
      throw new Error(`unexpected request ${call.url}`);
    });
    try {
      const response = await bloatRequest(ASSET, { headers: { Range: "bytes=0-99" } });
      expect(response.status).toBe(206);
      expect(response.headers.get("content-range")).toBe("bytes 0-99/1823779125");
      expect(response.headers.get("cache-control")).toBe("no-store");
      expect(new TextDecoder().decode(await response.arrayBuffer()).length).toBe(100);
      expect(out.calls).toHaveLength(2);
    } finally {
      out.restore();
    }
  });

  it("streams a full object when no range is requested", async () => {
    const out = mockOutbound(() => new Response("asset", { status: 200 }));
    try {
      const response = await bloatRequest(ASSET);
      expect(response.status).toBe(200);
      expect(await response.text()).toBe("asset");
    } finally {
      out.restore();
    }
  });

  it("rejects asset names outside [A-Za-z0-9._-]+", async () => {
    for (const name of ["%2E%2E%2Fetc%2Fpasswd", "bloat%20asset.img", "asset%2F..%2Fother"]) {
      const response = await bloatRequest(name);
      expect(response.status, name).toBe(400);
    }
  });

  it("refuses a redirect outside GitHub's release hosts", async () => {
    const out = mockOutbound(() => redirectResponse("https://evil.example/asset"));
    try {
      const response = await bloatRequest(ASSET, { headers: { Range: "bytes=0-9" } });
      expect(response.status).toBe(502);
      expect(out.calls).toHaveLength(1);
    } finally {
      out.restore();
    }
  });

  it("reports a missing asset with the upstream status", async () => {
    const out = mockOutbound(() => new Response("missing", { status: 404 }));
    try {
      const response = await bloatRequest(ASSET);
      expect(response.status).toBe(404);
      expect(await response.json()).toEqual({
        error: "Bloat asset server returned HTTP 404.",
      });
    } finally {
      out.restore();
    }
  });
});
