import { AwsClient } from "aws4fetch";
import { ProxyError, readBounded, upstreamSignal } from "./upstream";

export interface BucketEnv {
  OTA_S3_ENDPOINT?: string;
  OTA_S3_BUCKET?: string;
  OTA_S3_REGION?: string;
  OTA_S3_ACCESS_KEY_ID?: string;
  OTA_S3_SECRET_ACCESS_KEY?: string;
  OTA_PUBLIC_BASE?: string;
}

/** Counts every outbound request, including resolver requests and redirects. */
export class RequestBudget {
  used = 0;
  constructor(readonly limit = 40, readonly deadline = Number.POSITIVE_INFINITY) {}
  take(): void {
    if (this.used >= this.limit || Date.now() >= this.deadline) throw new Error("Cache invocation request budget exhausted.");
    this.used++;
  }
  get remaining(): number { return this.limit - this.used; }
}

export class Bucket {
  private readonly signer: AwsClient;
  private readonly base: string;
  constructor(readonly env: BucketEnv, readonly budget = new RequestBudget()) {
    if (!env.OTA_S3_ENDPOINT || !env.OTA_S3_BUCKET || !env.OTA_S3_ACCESS_KEY_ID || !env.OTA_S3_SECRET_ACCESS_KEY) {
      throw new ProxyError(503, "The OTA bucket is not configured. Run ./tool/dev_garage.sh from the repository root, then start wrangler dev.");
    }
    this.base = `${env.OTA_S3_ENDPOINT.replace(/\/$/, "")}/${encodeURIComponent(env.OTA_S3_BUCKET)}/`;
    this.signer = new AwsClient({
      accessKeyId: env.OTA_S3_ACCESS_KEY_ID,
      secretAccessKey: env.OTA_S3_SECRET_ACCESS_KEY,
      service: "s3",
      region: env.OTA_S3_REGION || "garage",
      retries: 0,
    });
  }
  async request(key: string, init: RequestInit = {}, query?: URLSearchParams): Promise<Response> {
    this.budget.take();
    const url = new URL(this.base + key.split("/").map(encodeURIComponent).join("/"));
    if (query) url.search = query.toString();
    const headers = new Headers(init.headers);
    // Garage accepts HTTPS-authenticated unsigned payloads. Avoid hashing 8 MiB
    // in JavaScript: only the small canonical SigV4 request is hashed.
    headers.set("x-amz-content-sha256", "UNSIGNED-PAYLOAD");
    const signed = await this.signer.sign(url.toString(), { ...init, headers });
    return fetch(signed, { signal: upstreamSignal(), redirect: "manual" });
  }
  async get(key: string): Promise<Response | null> {
    const response = await this.request(key);
    if (response.status === 404) { await response.body?.cancel(); return null; }
    if (!response.ok) { await response.body?.cancel(); throw new Error("OTA bucket read failed."); }
    return response;
  }
  async put(key: string, body: BodyInit, headers: Record<string, string> = {}): Promise<void> {
    const response = await this.request(key, { method: "PUT", body, headers });
    await response.body?.cancel();
    if (!response.ok) throw new Error("OTA bucket write failed.");
  }
  async json<T>(key: string, limit = 256 * 1024): Promise<T | null> {
    const response = await this.get(key);
    return response ? JSON.parse(new TextDecoder().decode(await readBounded(response, limit))) as T : null;
  }
  async list(prefix: string, options: { delimiter?: string; token?: string; maxKeys?: number } = {}): Promise<{ keys: string[]; prefixes: string[]; next: string | null }> {
    const query = new URLSearchParams({ "list-type": "2", prefix, "max-keys": String(options.maxKeys ?? 1000) });
    if (options.delimiter) query.set("delimiter", options.delimiter);
    if (options.token) query.set("continuation-token", options.token);
    const response = await this.request("", {}, query);
    if (!response.ok) { await response.body?.cancel(); throw new Error("OTA bucket listing failed."); }
    const xml = new TextDecoder().decode(await readBounded(response, 1024 * 1024));
    return { keys: xmlValues(xml, "Key"), prefixes: xmlValues(xml, "Prefix").slice(1), next: xmlValues(xml, "NextContinuationToken")[0] ?? null };
  }
  async delete(keys: string[]): Promise<void> {
    if (keys.length === 0) return;
    if (keys.length > 1000) throw new Error("S3 deletes are limited to 1000 objects.");
    const body = `<Delete><Quiet>true</Quiet>${keys.map(key => `<Object><Key>${xmlEscape(key)}</Key></Object>`).join("")}</Delete>`;
    const response = await this.request("", { method: "POST", body, headers: { "Content-Type": "application/xml" } }, new URLSearchParams({ delete: "" }));
    const reply = new TextDecoder().decode(await readBounded(response, 256 * 1024));
    if (!response.ok || /<Error[\s>]/.test(reply)) throw new Error("OTA bucket deletion failed.");
  }
}

function xmlEscape(value: string): string {
  return value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&apos;");
}
function xmlValues(xml: string, tag: string): string[] {
  return Array.from(xml.matchAll(new RegExp(`<${tag}>([\\s\\S]*?)</${tag}>`, "g")), match =>
    match[1]!.replace(/&(amp|lt|gt|quot|apos);/g, (_, entity: string) => ({ amp: "&", lt: "<", gt: ">", quot: '"', apos: "'" })[entity]!));
}
