/**
 * Outbound request mocks for the worker tests.
 *
 * The Workers test runner loads the worker under test into the same isolate
 * as the tests, so replacing the global `fetch` intercepts every upstream
 * request the worker makes. No test ever reaches the network.
 */

export interface OutboundCall {
  url: string;
  method: string;
  headers: Headers;
  body: string | null;
}

export type OutboundHandler = (call: OutboundCall) => Response | Promise<Response>;

export interface OutboundMock {
  calls: OutboundCall[];
  restore(): void;
}

export function mockOutbound(handler: OutboundHandler): OutboundMock {
  const original = globalThis.fetch;
  const calls: OutboundCall[] = [];
  const replacement = async (
    input: string | URL | Request,
    init?: RequestInit,
  ): Promise<Response> => {
    const request = new Request(input, init);
    const body =
      request.method === "GET" || request.method === "HEAD"
        ? null
        : new TextDecoder().decode(await request.arrayBuffer());
    const call: OutboundCall = {
      url: request.url,
      method: request.method,
      headers: request.headers,
      body,
    };
    calls.push(call);
    return handler(call);
  };
  globalThis.fetch = replacement as typeof fetch;
  return {
    calls,
    restore(): void {
      if (globalThis.fetch === (replacement as typeof fetch)) {
        globalThis.fetch = original;
      }
    },
  };
}

export function jsonResponse(
  body: unknown,
  init: { status?: number; headers?: Record<string, string> } = {},
): Response {
  return new Response(JSON.stringify(body), {
    status: init.status ?? 200,
    headers: { "Content-Type": "application/json", ...init.headers },
  });
}

export function htmlResponse(source: string, headers: Record<string, string> = {}): Response {
  return new Response(source, {
    status: 200,
    headers: { "Content-Type": "text/html; charset=utf-8", ...headers },
  });
}

export function redirectResponse(location: string, status = 302): Response {
  return new Response(null, { status, headers: { Location: location } });
}
