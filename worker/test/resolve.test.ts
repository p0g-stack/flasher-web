import { SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import keyedHtml from "./fixtures/ota-result-keyed.html?raw";
import resultHtml from "./fixtures/ota-result.html?raw";
import siteHtml from "./fixtures/ota-site.html?raw";
import { htmlResponse, jsonResponse, mockOutbound } from "./outbound";

const SITE = "https://roms.danielspringer.at/index.php?view=ota";
const FRESH_LINK =
  "https://ota.oneplus.com/ota/full/13.0.0.1.zip?x-oss-expires=9999999999&Signature=fixture";
const RESOLVED_LINK =
  "https://ota.oneplus.com/ota/full/13.0.0.1.zip?x-oss-expires=9999999999&Signature=resolved";

function release(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    id: "op13-glo-13.0.0.1",
    device: "OP 13",
    region: "GLO",
    version: "13.0.0.1",
    source_url: FRESH_LINK,
    package_type: "full",
    ...overrides,
  };
}

function resolveRequest(body: unknown): Promise<Response> {
  return SELF.fetch("http://example.com/api/resolve", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

describe("POST /api/resolve", () => {
  it("drives the site session and carries its cookie to the selection POST", async () => {
    const out = mockOutbound((call) => {
      if (call.method === "GET" && call.url === SITE) {
        return htmlResponse(siteHtml, {
          "Set-Cookie": "ota_session=abc123; Path=/; HttpOnly",
        });
      }
      if (call.method === "POST" && call.url === SITE) {
        return htmlResponse(resultHtml);
      }
      throw new Error(`unexpected request ${call.method} ${call.url}`);
    });
    try {
      const response = await resolveRequest(release());
      expect(response.status).toBe(200);
      expect(await response.json()).toEqual({ url: FRESH_LINK });
      expect(out.calls).toHaveLength(2);
      const selection = out.calls[1];
      expect(selection?.body).toBe("device=OP+13&region=GLO&version_index=0");
      expect(selection?.headers.get("cookie")).toBe("ota_session=abc123");
      expect(selection?.headers.get("user-agent")).toBe("FlasherBuilder/1.0");
    } finally {
      out.restore();
    }
  });

  it("falls back to resolve_json with the page's key and CSRF token", async () => {
    const out = mockOutbound((call) => {
      if (call.method === "GET" && call.url === SITE) {
        return htmlResponse(siteHtml, {
          "Set-Cookie": "ota_session=abc123; Path=/; HttpOnly",
        });
      }
      if (call.method === "POST" && call.url === SITE) {
        return htmlResponse(keyedHtml);
      }
      if (call.method === "POST" && call.url === `${SITE}&ota_action=resolve_json`) {
        return jsonResponse({ ok: true, url: RESOLVED_LINK });
      }
      throw new Error(`unexpected request ${call.method} ${call.url}`);
    });
    try {
      const response = await resolveRequest(release());
      expect(response.status).toBe(200);
      expect(await response.json()).toEqual({ url: RESOLVED_LINK });
      expect(out.calls).toHaveLength(3);
      const resolveCall = out.calls[2];
      expect(resolveCall?.body).toBe("k=OTA-KEY-1&csrf=csrf-token-1");
      expect(resolveCall?.headers.get("cookie")).toBe("ota_session=abc123");
    } finally {
      out.restore();
    }
  });

  it("reports a version that the site no longer lists", async () => {
    const out = mockOutbound(() => htmlResponse(siteHtml));
    try {
      const response = await resolveRequest(release({ version: "9.9.9" }));
      expect(response.status).toBe(502);
      expect(await response.json()).toEqual({
        error: "This version is no longer available on the OTA website. Fetch versions again.",
      });
      expect(out.calls).toHaveLength(1);
    } finally {
      out.restore();
    }
  });

  it("rejects an expired link and cannot refresh it without a key", async () => {
    const expired = '<div id="resultBox" data-url="https://ota.oneplus.com/x.zip?x-oss-expires=1000" data-link-ready="1"></div>';
    const out = mockOutbound((call) => {
      if (call.method === "GET") {
        return htmlResponse(siteHtml);
      }
      return htmlResponse(expired);
    });
    try {
      const response = await resolveRequest(release());
      expect(response.status).toBe(502);
      expect(await response.json()).toEqual({
        error: "The OTA website could not provide a fresh download link. Try another version or retry later.",
      });
    } finally {
      out.restore();
    }
  });

  it("reports an unreadable resolve_json response", async () => {
    const out = mockOutbound((call) => {
      if (call.method === "GET") {
        return htmlResponse(siteHtml);
      }
      return call.url.endsWith("ota_action=resolve_json")
        ? new Response("not json", { status: 200 })
        : htmlResponse(keyedHtml);
    });
    try {
      const response = await resolveRequest(release());
      expect(response.status).toBe(502);
      expect(await response.json()).toEqual({
        error: "The OTA website returned an invalid link response.",
      });
    } finally {
      out.restore();
    }
  });

  it("returns an unsigned direct ZIP without opening a session", async () => {
    const direct = "https://roms.danielspringer.at/ota/Oneplus13-full.zip";
    const out = mockOutbound(() => {
      throw new Error("no session expected");
    });
    try {
      const response = await resolveRequest(release({ source_url: direct }));
      expect(response.status).toBe(200);
      expect(await response.json()).toEqual({ url: direct });
      expect(out.calls).toHaveLength(0);
    } finally {
      out.restore();
    }
  });

  it("returns a usable NA reconstructed link directly", async () => {
    const direct =
      "https://roms.danielspringer.at/download.php?file=OP13&x-oss-expires=9999999999";
    const out = mockOutbound(() => {
      throw new Error("no session expected");
    });
    try {
      const response = await resolveRequest(
        release({
          device: "OP 13",
          region: "NA",
          package_type: "reconstructed_full",
          source_url: direct,
        }),
      );
      expect(response.status).toBe(200);
      expect(await response.json()).toEqual({ url: direct });
    } finally {
      out.restore();
    }
  });

  it("requires a catalog release entry", async () => {
    const response = await resolveRequest({ device: "Oneplus 13" });
    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({ error: "A catalog release entry is required." });
  });
});
