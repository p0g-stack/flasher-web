/**
 * POST /api/resolve
 *
 * Port of `resolve_link` / `usable_link` / `OtaPage` from upstream
 * `flasher_builder/ota_catalog.py`. Takes one catalog release entry, drives
 * the OTA site's own session (GET page, POST selection, optional
 * `resolve_json`) and returns a fresh signed link. Nothing is cached and no
 * URL is ever logged.
 */

import { json, jsonError } from "./http";
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

const SITE = "https://roms.danielspringer.at/index.php?view=ota";
const NA_API = "https://roms.danielspringer.at/api/na.php";
const SESSION_TIMEOUT_MS = 35_000;

export const DEVICE_NAMES: Record<string, string> = {
  "Oneplus 13": "OP 13",
  "Oneplus 13R": "OP 13R",
  "Oneplus 13S": "OP 13S",
  "Oneplus 13T": "OP 13T",
  "Oneplus 15": "OP 15",
  "Oneplus 15R": "OP 15R",
  "Oneplus 15T": "OP 15T",
  "Oneplus Ace 5": "OP ACE 5",
  "Oneplus Ace 5 Pro": "OP ACE 5 PRO",
  "Oneplus Ace 6": "OP ACE 6",
  "Oneplus Ace 6T": "OP ACE 6T",
  "Oneplus Pad 2 Pro": "OP PAD2 PRO",
  "Oneplus Pad 3": "OP PAD3",
  "Oneplus Pad 3 Pro": "OP PAD3 PRO",
  "Realme GT 7 Pro": "Realme GT7 PRO",
  "Realme NEO8": "Realme NEO 8",
  "OPPO Find X9 Ultra": "OPPO FIND X9 ULTRA",
};

const VERSION_UNAVAILABLE =
  "This version is no longer available on the OTA website. Fetch versions again.";
const UNREADABLE_PAGE = "The OTA website returned an unreadable page.";
const INVALID_LINK_RESPONSE = "The OTA website returned an invalid link response.";
const NO_FRESH_LINK =
  "The OTA website could not provide a fresh download link. Try another version or retry later.";

export interface CatalogEntry {
  device: string;
  region: string;
  version: string;
  source_url: string;
  package_type: string | null;
}

export function readCatalogEntry(value: unknown): CatalogEntry | null {
  if (!isRecordObject(value)) {
    return null;
  }
  const fields = ["device", "region", "version", "source_url"] as const;
  for (const field of fields) {
    const fieldValue = value[field];
    if (typeof fieldValue !== "string" || fieldValue === "") {
      return null;
    }
  }
  const packageType = value["package_type"];
  return {
    device: value["device"] as string,
    region: value["region"] as string,
    version: value["version"] as string,
    source_url: value["source_url"] as string,
    package_type: typeof packageType === "string" ? packageType : null,
  };
}

/** Port of upstream `uses_na_api`. */
export function usesNaApi(device: string, region: string): boolean {
  const otaDevice = DEVICE_NAMES[device] ?? device;
  return region === "NA" && (otaDevice === "OP 13" || otaDevice === "OP 15");
}

function decodeFormComponent(text: string): string {
  const spaced = text.replace(/\+/g, " ");
  try {
    return decodeURIComponent(spaced);
  } catch {
    return spaced;
  }
}

/** `urllib.parse.parse_qs` with the default `keep_blank_values=False`. */
export function pythonParseQs(query: string): Map<string, string[]> {
  const parsed = new Map<string, string[]>();
  for (const part of query.split("&")) {
    const separator = part.indexOf("=");
    if (separator < 0) {
      continue;
    }
    const name = decodeFormComponent(part.slice(0, separator));
    const value = decodeFormComponent(part.slice(separator + 1));
    if (value === "") {
      continue;
    }
    const values = parsed.get(name);
    if (values === undefined) {
      parsed.set(name, [value]);
    } else {
      values.push(value);
    }
  }
  return parsed;
}

/** Python's `float()` for the strings that appear in expiry parameters. */
function pythonFloat(text: string): number | null {
  const trimmed = text.trim();
  if (trimmed === "") {
    return null;
  }
  const normalized = trimmed.replace(/_/g, "");
  if (/^[+-]?(inf|infinity)$/i.test(normalized)) {
    return normalized.startsWith("-") ? -Infinity : Infinity;
  }
  if (/^[+-]?nan$/i.test(normalized)) {
    return NaN;
  }
  if (!/^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$/.test(normalized)) {
    return null;
  }
  return Number(normalized);
}

/** Port of upstream `usable_link`. */
export function usableLink(raw: string, nowSeconds: number = Date.now() / 1000): boolean {
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    return false;
  }
  if (url.protocol !== "https:" && url.protocol !== "http:") {
    return false;
  }
  if (url.hostname === "" || url.pathname.endsWith("/downloadCheck")) {
    return false;
  }
  const query = pythonParseQs(url.search.replace(/^\?/, ""));
  for (const name of ["x-oss-expires", "Expires", "expires"]) {
    const values = query.get(name);
    if (values !== undefined) {
      const expires = pythonFloat(values[0] ?? "");
      return expires !== null && expires > nowSeconds + 120;
    }
  }
  return true;
}

function setCookies(headers: Headers): string[] {
  const withGetter = headers as Headers & { getSetCookie?: () => string[] };
  if (typeof withGetter.getSetCookie === "function") {
    return withGetter.getSetCookie();
  }
  const joined = headers.get("set-cookie");
  if (joined === null || joined === "") {
    return [];
  }
  return joined.split(/,(?=[^;,]+=)/);
}

function sessionSignal(): AbortSignal {
  const signal = AbortSignal as unknown as {
    timeout?: (milliseconds: number) => AbortSignal;
  };
  return signal.timeout
    ? signal.timeout(SESSION_TIMEOUT_MS)
    : new AbortController().signal;
}

interface SiteResponse {
  body: Uint8Array;
}

/** One OTA-site session; cookies from every response ride on later requests. */
class OtaSession {
  private readonly cookies = new Map<string, string>();

  constructor(private readonly beforeFetch?: () => void) {}

  private cookieHeader(): string | null {
    if (this.cookies.size === 0) {
      return null;
    }
    return [...this.cookies.entries()].map(([name, value]) => `${name}=${value}`).join("; ");
  }

  private absorbCookies(headers: Headers): void {
    for (const cookie of setCookies(headers)) {
      const pair = cookie.split(";", 1)[0] ?? "";
      const separator = pair.indexOf("=");
      if (separator <= 0) {
        continue;
      }
      const name = pair.slice(0, separator).trim();
      if (name !== "") {
        this.cookies.set(name, pair.slice(separator + 1).trim());
      }
    }
  }

  async request(url: string, data?: Record<string, string>): Promise<SiteResponse> {
    const headers: Record<string, string> = { "User-Agent": "FlasherBuilder/1.0" };
    const cookie = this.cookieHeader();
    if (cookie !== null) {
      headers["Cookie"] = cookie;
    }
    let body: string | undefined;
    if (data !== undefined) {
      const form = new URLSearchParams();
      for (const [name, value] of Object.entries(data)) {
        form.set(name, value);
      }
      body = form.toString();
      headers["Content-Type"] = "application/x-www-form-urlencoded";
    }
    let response!: Response;
    try {
      let target = new URL(url);
      let method = body === undefined ? "GET" : "POST";
      for (let hop = 0; ; hop++) {
        this.beforeFetch?.();
        response = await fetch(target.toString(), {
          method, headers, body, signal: sessionSignal(),
          ...(this.beforeFetch ? { redirect: "manual" as const } : {}),
        });
        if (!this.beforeFetch || ![301, 302, 303, 307, 308].includes(response.status)) break;
        this.absorbCookies(response.headers);
        const location = response.headers.get("Location");
        await response.body?.cancel();
        if (!location || hop >= 5) throw new CatalogError(OTA_SERVICE_UNREACHABLE);
        const next = new URL(location, target);
        if (next.origin !== new URL(url).origin) throw new CatalogError(OTA_SERVICE_UNREACHABLE);
        if (response.status === 303 || ((response.status === 301 || response.status === 302) && method === "POST")) {
          method = "GET";
          body = undefined;
          delete headers["Content-Type"];
        }
        const cookies = this.cookieHeader();
        if (cookies) headers["Cookie"] = cookies;
        target = next;
      }
    } catch {
      throw new CatalogError(OTA_SERVICE_UNREACHABLE);
    }
    this.absorbCookies(response.headers);
    if (!response.ok) {
      throw new CatalogError(otaServiceHttpError(response.status));
    }
    try {
      return { body: await readBounded(response, MAX_UPSTREAM_RESPONSE) };
    } catch (error) {
      throw new CatalogError(
        error instanceof UpstreamTooLargeError ? OTA_SERVICE_OVERSIZED : OTA_SERVICE_UNREACHABLE,
      );
    }
  }
}

interface OtaPage {
  devices: unknown;
  result: Record<string, string>;
}

const NAMED_ATTRIBUTE_ENTITIES: Record<string, string> = {
  amp: "&",
  lt: "<",
  gt: ">",
  quot: '"',
  apos: "'",
  nbsp: "\u00a0",
};

/** `html.unescape` maps numeric references in this range to Windows-1252. */
const C1_REPLACEMENTS: Record<number, string> = {
  0x80: "\u20ac",
  0x82: "\u201a",
  0x83: "\u0192",
  0x84: "\u201e",
  0x85: "\u2026",
  0x86: "\u2020",
  0x87: "\u2021",
  0x88: "\u02c6",
  0x89: "\u2030",
  0x8a: "\u0160",
  0x8b: "\u2039",
  0x8c: "\u0152",
  0x8e: "\u017d",
  0x91: "\u2018",
  0x92: "\u2019",
  0x93: "\u201c",
  0x94: "\u201d",
  0x95: "\u2022",
  0x96: "\u2013",
  0x97: "\u2014",
  0x98: "\u02dc",
  0x99: "\u2122",
  0x9a: "\u0161",
  0x9b: "\u203a",
  0x9c: "\u0153",
  0x9e: "\u017e",
  0x9f: "\u0178",
};

/** HTMLRewriter returns raw attribute text; Python's parser unescapes it. */
export function decodeHtmlAttribute(value: string): string {
  return value.replace(/&(#(?:[0-9]+|[xX][0-9a-fA-F]+)|[a-zA-Z][a-zA-Z0-9]*);?/g, (match: string, body: string) => {
    if (body.startsWith("#")) {
      const hexadecimal = body[1] === "x" || body[1] === "X";
      const digits = body.slice(hexadecimal ? 2 : 1);
      if (digits === "") {
        return match;
      }
      const codePoint = Number.parseInt(digits, hexadecimal ? 16 : 10);
      if (!Number.isFinite(codePoint) || codePoint === 0 || codePoint > 0x10ffff) {
        return "\ufffd";
      }
      if (codePoint >= 0xd800 && codePoint <= 0xdfff) {
        return "\ufffd";
      }
      return C1_REPLACEMENTS[codePoint] ?? String.fromCodePoint(codePoint);
    }
    return NAMED_ATTRIBUTE_ENTITIES[body] ?? match;
  });
}

/** Port of upstream `OtaPage` / `parse_page` using the runtime HTML parser. */
export async function parsePage(body: Uint8Array): Promise<OtaPage> {
  let text: string;
  try {
    text = new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(body);
  } catch {
    throw new CatalogError(UNREADABLE_PAGE);
  }
  let devices: unknown = {};
  let result: Record<string, string> = {};
  let unreadable = false;
  const rewriter = new HTMLRewriter()
    .on('[id="device"]', {
      element(element) {
        const raw = element.getAttribute("data-devices");
        try {
          devices = JSON.parse(decodeHtmlAttribute(raw ?? "{}"));
        } catch {
          unreadable = true;
        }
      },
    })
    .on('[id="resultBox"]', {
      element(element) {
        const attributes: Record<string, string> = {};
        const entries = Object.entries(
          Object.fromEntries(element.attributes) as Record<string, string>,
        );
        for (const [name, value] of entries) {
          attributes[name] = decodeHtmlAttribute(value);
        }
        result = attributes;
      },
    });
  await rewriter.transform(new Response(text)).text();
  if (unreadable) {
    throw new CatalogError(UNREADABLE_PAGE);
  }
  return { devices, result };
}

function boundsOf(url: URL | null): {
  scheme: string;
  host: string;
  path: string;
  username: string;
  password: string;
} {
  if (url === null) {
    return { scheme: "", host: "", path: "", username: "", password: "" };
  }
  return {
    scheme: url.protocol,
    host: url.host,
    path: url.pathname,
    username: url.username,
    password: url.password,
  };
}

/** Port of upstream `resolve_link`. */
export async function resolveLink(entry: CatalogEntry, beforeFetch?: () => void): Promise<string> {
  const source = entry.source_url;
  let parsedSource: URL | null = null;
  try {
    parsedSource = new URL(source);
  } catch {
    parsedSource = null;
  }
  const parts = boundsOf(parsedSource);
  const sourceQuery = pythonParseQs(parsedSource?.search.replace(/^\?/, "") ?? "");

  if (
    usesNaApi(entry.device, entry.region) &&
    entry.package_type === "reconstructed_full" &&
    parts.scheme === "https:" &&
    parts.host === new URL(NA_API).host &&
    parts.username === "" &&
    parts.password === "" &&
    parts.path === "/download.php" &&
    usableLink(source)
  ) {
    return source;
  }

  const signedQueryNames = ["Expires", "expires", "x-oss-expires", "Signature", "x-oss-signature"];
  if (
    parts.path.toLowerCase().endsWith(".zip") &&
    !signedQueryNames.some((name) => sourceQuery.has(name)) &&
    usableLink(source)
  ) {
    return source;
  }

  const session = new OtaSession(beforeFetch);
  const page = await parsePage((await session.request(SITE)).body);
  let index: number;
  try {
    const devices = page.devices as Record<string, Record<string, string[]>>;
    const versions = devices[entry.device]?.[entry.region];
    if (!Array.isArray(versions)) {
      throw new TypeError("missing version list");
    }
    index = versions.indexOf(entry.version);
    if (index < 0) {
      throw new RangeError("version not listed");
    }
  } catch {
    throw new CatalogError(VERSION_UNAVAILABLE);
  }

  const selected = (
    await session.request(SITE, {
      device: entry.device,
      region: entry.region,
      version_index: String(index),
    })
  ).body;
  const result = (await parsePage(selected)).result;
  const url = result["data-url"] ?? "";
  if (result["data-link-ready"] === "1" && usableLink(url)) {
    return url;
  }

  const otaKey = result["data-ota-key"];
  const csrf = result["data-csrf"];
  if (otaKey !== undefined && otaKey !== "" && csrf !== undefined && csrf !== "") {
    let data: unknown;
    const resolveBody = (
      await session.request(`${SITE}&ota_action=resolve_json`, { k: otaKey, csrf })
    ).body;
    try {
      data = JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(resolveBody));
    } catch {
      throw new CatalogError(INVALID_LINK_RESPONSE);
    }
    if (isRecordObject(data)) {
      const resolved = data["url"];
      if (Boolean(data["ok"]) && typeof resolved === "string" && usableLink(resolved)) {
        return resolved;
      }
    }
  }
  throw new CatalogError(NO_FRESH_LINK);
}

export async function handleResolve(request: Request): Promise<Response> {
  let payload: unknown;
  try {
    payload = await request.json();
  } catch {
    return jsonError(400, "A catalog release entry is required.");
  }
  const entry = readCatalogEntry(payload);
  if (entry === null) {
    return jsonError(400, "A catalog release entry is required.");
  }
  try {
    return json({ url: await resolveLink(entry) });
  } catch (error) {
    return jsonError(502, error instanceof CatalogError ? error.message : NO_FRESH_LINK);
  }
}
