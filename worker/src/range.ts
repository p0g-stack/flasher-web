/** Single-range parsing for the streaming OTA proxy. */

/** A proxied range may not exceed 64 MiB, matching one extraction chunk. */
export const MAX_OTA_RANGE_BYTES = 64 * 1024 * 1024;

/**
 * Returns the `Range` header to forward, or null when the request is not a
 * single satisfiable bounded/suffix range. Open-ended ranges are clamped so a
 * client cannot ask the edge for an arbitrarily large body.
 */
export function parseSingleRange(value: string): string | null {
  const match = /^bytes=(\d*)-(\d*)$/i.exec(value.trim());
  if (match === null) {
    return null;
  }
  const startText = match[1] ?? "";
  const endText = match[2] ?? "";
  if (startText === "" && endText === "") {
    return null;
  }
  const start = startText === "" ? null : Number(startText);
  const end = endText === "" ? null : Number(endText);
  if (start !== null && !Number.isSafeInteger(start)) {
    return null;
  }
  if (end !== null && !Number.isSafeInteger(end)) {
    return null;
  }
  if (start !== null && end !== null) {
    if (end < start || end - start + 1 > MAX_OTA_RANGE_BYTES) {
      return null;
    }
    return `bytes=${start}-${end}`;
  }
  if (start !== null) {
    return `bytes=${start}-${start + MAX_OTA_RANGE_BYTES - 1}`;
  }
  if (end === null || end === 0 || end > MAX_OTA_RANGE_BYTES) {
    return null;
  }
  return `bytes=-${end}`;
}
