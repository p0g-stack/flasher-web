import { SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { mockOutbound, redirectResponse } from "./outbound";

const FILE_HOST = "https://ota.oneplus.com";
const FILE_URL = `${FILE_HOST}/ota/full/13.0.0.1.zip?x-oss-expires=9999999999&Signature=fixture`;

function otaRequest(url: string, init: RequestInit = {}): Promise<Response> {
  return SELF.fetch(`http://example.com/api/ota?u=${encodeURIComponent(url)}`, init);
}

function rangeRequest(url: string, range: string): Promise<Response> {
  return otaRequest(url, { headers: { Range: range } });
}

function otaHeaders(): Record<string, string> {
  return {
    "User-Agent": "Dalvik/2.1.0 (Linux; U; Android 16; CPH2653 Build/AP3A.240617.008)",
    userId: "oplus-ota|15002017",
    language: "en-US",
    brand: "oneplus-exp",
    "Accept-Encoding": "identity",
  };
}

function rangedReply(body = "0123456789"): Response {
  return new Response(body, {
    status: 206,
    headers: {
      "Content-Range": "bytes 0-9/100",
      "Content-Length": String(body.length),
      "Accept-Ranges": "bytes",
      ETag: '"ota-1"',
      "Last-Modified": "Wed, 21 Oct 2015 07:28:00 GMT",
      "Content-Type": "application/zip",
    },
  });
}

describe("GET /api/ota", () => {
  it("rejects hosts outside the allowlist, plain http, lookalikes and ports", async () => {
    const targets = [
      "https://evil.example/full.zip",
      "http://ota.oneplus.com/full.zip",
      "https://eviloneplus.com/full.zip",
      "https://user@ota.oneplus.com/full.zip",
      "https://ota.oneplus.com:8443/full.zip",
      "https://roms.danielspringer.at/other.php",
    ];
    for (const target of targets) {
      const response = await rangeRequest(target, "bytes=0-9");
      expect(response.status, target).toBe(400);
    }
  });

  it("requires a Range header for GET", async () => {
    const response = await otaRequest(FILE_URL);
    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({ error: "A Range header is required." });
  });

  it("streams a single range with the OTA headers and upstream metadata", async () => {
    const out = mockOutbound((call) => {
      expect(call.method).toBe("GET");
      expect(call.headers.get("range")).toBe("bytes=0-9");
      for (const [name, value] of Object.entries(otaHeaders())) {
        expect(call.headers.get(name), name).toBe(value);
      }
      return rangedReply();
    });
    try {
      const response = await rangeRequest(FILE_URL, "bytes=0-9");
      expect(response.status).toBe(206);
      expect(response.headers.get("content-range")).toBe("bytes 0-9/100");
      expect(response.headers.get("accept-ranges")).toBe("bytes");
      expect(response.headers.get("etag")).toBe('"ota-1"');
      expect(response.headers.get("last-modified")).toBe("Wed, 21 Oct 2015 07:28:00 GMT");
      expect(response.headers.get("cache-control")).toBe("no-store");
      expect(new TextDecoder().decode(await response.arrayBuffer())).toBe("0123456789");
      expect(out.calls).toHaveLength(1);
    } finally {
      out.restore();
    }
  });

  it("allows an allowlisted subdomain and an exact catalog download path", async () => {
    const out = mockOutbound(() => rangedReply());
    try {
      const subdomain = await rangeRequest("https://cdn.allawnofs.com/full.zip", "bytes=0-9");
      expect(subdomain.status).toBe(206);
      const catalog = await rangeRequest(
        "https://roms.danielspringer.at/download.php?file=13",
        "bytes=0-9",
      );
      expect(catalog.status).toBe(206);
      expect(out.calls.map((call) => call.url)).toEqual([
        "https://cdn.allawnofs.com/full.zip",
        "https://roms.danielspringer.at/download.php?file=13",
      ]);
    } finally {
      out.restore();
    }
  });

  it("clamps an open-ended range to 64 MiB", async () => {
    const out = mockOutbound((call) => {
      expect(call.headers.get("range")).toBe("bytes=100-67108963");
      return rangedReply();
    });
    try {
      const response = await rangeRequest(FILE_URL, "bytes=100-");
      expect(response.status).toBe(206);
    } finally {
      out.restore();
    }
  });

  it("rejects a range larger than 64 MiB and malformed ranges", async () => {
    for (const range of ["bytes=0-67108864", "bytes=10-5", "bytes=0-1,5-6", "items=0-1"]) {
      const response = await rangeRequest(FILE_URL, range);
      expect(response.status, range).toBe(416);
      expect(response.headers.get("content-range")).toBe("bytes */*");
    }
  });

  it("follows only allowlisted redirects", async () => {
    let out = mockOutbound(() => redirectResponse("https://evil.example/stolen"));
    try {
      const response = await rangeRequest(FILE_URL, "bytes=0-9");
      expect(response.status).toBe(502);
      expect(out.calls).toHaveLength(1);
    } finally {
      out.restore();
    }

    out = mockOutbound((call) => {
      if (call.url === FILE_HOST + "/ota/full/13.0.0.1.zip?x-oss-expires=9999999999&Signature=fixture") {
        return redirectResponse("https://cdn.allawnos.com/signed/real");
      }
      return rangedReply();
    });
    try {
      const response = await rangeRequest(FILE_URL, "bytes=0-9");
      expect(response.status).toBe(206);
      expect(out.calls).toHaveLength(2);
      expect(out.calls[1]?.headers.get("range")).toBe("bytes=0-9");
    } finally {
      out.restore();
    }
  });

  it("refuses an upstream that ignores the range", async () => {
    const out = mockOutbound(() => new Response("full", { status: 200 }));
    try {
      const response = await rangeRequest(FILE_URL, "bytes=0-9");
      expect(response.status).toBe(502);
      expect(await response.json()).toEqual({
        error: "The OTA server does not support HTTP ranges.",
      });
    } finally {
      out.restore();
    }
  });

  it("answers HEAD without requiring a range", async () => {
    const out = mockOutbound(() =>
      new Response(null, {
        status: 200,
        headers: { "Content-Length": "1234", "Accept-Ranges": "bytes" },
      }),
    );
    try {
      const response = await otaRequest(FILE_URL, { method: "HEAD" });
      expect(response.status).toBe(200);
      expect(response.headers.get("content-length")).toBe("1234");
      expect(await response.text()).toBe("");
      expect(out.calls[0]?.method).toBe("HEAD");
    } finally {
      out.restore();
    }
  });
});
