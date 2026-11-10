/**
 * The resolved-OTA link rules the block fill path shares: which hosts may be
 * reached and the upstream `remote_zip.HEADERS` port the CDN expects.
 *
 * Only HTTPS on allowlisted hosts is reachable; signed URLs never reach the
 * client and are never stored.
 */

const OTA_HOST_SUFFIXES = [
  "allawnofs.com",
  "allawnfs.com",
  "allawnos.com",
  "oneplus.com",
  "oneplus.net",
  "oppo.com",
  "coloros.com",
  "realme.com",
  "heytapimage.com",
];

const OTA_CATALOG_HOST = "roms.danielspringer.at";
const OTA_CATALOG_PATH = "/download.php";

/** Verbatim port of upstream `remote_zip.HEADERS` plus per-request Range. */
export const OTA_REQUEST_HEADERS: Record<string, string> = {
  "User-Agent": "Dalvik/2.1.0 (Linux; U; Android 16; CPH2653 Build/AP3A.240617.008)",
  userId: "oplus-ota|15002017",
  language: "en-US",
  brand: "oneplus-exp",
  "Accept-Encoding": "identity",
};

/** Host-suffix match with a DNS label boundary, HTTPS only, default port. */
export function otaUrlAllowed(url: URL): boolean {
  if (url.protocol !== "https:" || url.username !== "" || url.password !== "" || url.port !== "") {
    return false;
  }
  const host = url.hostname;
  if (host === OTA_CATALOG_HOST) {
    return url.pathname === OTA_CATALOG_PATH;
  }
  return OTA_HOST_SUFFIXES.some(
    (suffix) => host === suffix || host.endsWith(`.${suffix}`),
  );
}
