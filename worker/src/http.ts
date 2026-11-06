/** Small JSON/response helpers; API responses are never cached unless stated. */

export const NO_STORE = "no-store";

export function jsonError(
  status: number,
  error: string,
  headers: Record<string, string> = {},
): Response {
  return new Response(JSON.stringify({ error }), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": NO_STORE,
      ...headers,
    },
  });
}

export function json(body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status: 200,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": NO_STORE,
    },
  });
}

export function methodNotAllowed(allow: string): Response {
  return jsonError(405, "Method not allowed.", { Allow: allow });
}
