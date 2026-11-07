import { jsonError, methodNotAllowed } from './http';

/** Proxy only the hosted job API to an operator-configured backend. */
export async function handleHosted(request: Request, origin: string | undefined, token: string | undefined): Promise<Response> {
  if (!origin || !token) return jsonError(503, 'Hosted builds are not configured.');
  let backend: URL;
  try {
    backend = new URL(origin);
    const local = backend.protocol === 'http:' && (backend.hostname === 'localhost' || backend.hostname === '127.0.0.1' || backend.hostname === '[::1]');
    if ((!local && backend.protocol !== 'https:') || backend.username || backend.password || backend.pathname !== '/' || backend.search || backend.hash) throw new Error('invalid origin');
  } catch {
    return jsonError(503, 'Hosted build origin is invalid.');
  }
  const url = new URL(request.url);
  const jobs = url.pathname === '/api/hosted/jobs';
  const item = /^\/api\/hosted\/jobs\/[A-Za-z0-9_-]{16,128}(?:\/(?:artifact|manifest))?$/.test(url.pathname);
  const leaseCreate = /^\/api\/hosted\/jobs\/[A-Za-z0-9_-]{16,128}\/lease$/.test(url.pathname);
  const leaseRenew = /^\/api\/hosted\/jobs\/[A-Za-z0-9_-]{16,128}\/lease\/[A-Za-z0-9_-]{16,128}\/renew$/.test(url.pathname);
  const leaseDelete = /^\/api\/hosted\/jobs\/[A-Za-z0-9_-]{16,128}\/lease\/[A-Za-z0-9_-]{16,128}$/.test(url.pathname);
  if ((!jobs && !item && !leaseCreate && !leaseRenew && !leaseDelete) || url.search) return jsonError(404, 'Unknown hosted build route.');
  const method = jobs || leaseCreate || leaseRenew ? 'POST' : leaseDelete ? 'DELETE' : 'GET, HEAD';
  if (!method.split(', ').includes(request.method)) return methodNotAllowed(method);
  const headers = new Headers({ 'X-Hosted-Token': token });
  if (url.pathname.endsWith('/artifact')) headers.set('Accept-Encoding', 'identity');
  for (const name of ['range', 'if-range', 'if-none-match']) {
    const value = request.headers.get(name);
    if (value) headers.set(name, value);
  }
  let body: Uint8Array | undefined;
  if (jobs) {
    if (!/^application\/json(?:\s*;|$)/i.test(request.headers.get('content-type') || '')) return jsonError(415, 'JSON required.');
    const reader = request.body?.getReader();
    if (!reader) return jsonError(400, 'JSON required.');
    const chunks: Uint8Array[] = [];
    let length = 0;
    while (true) {
      const part = await reader.read();
      if (part.done) break;
      length += part.value.byteLength;
      if (length > 16384) { await reader.cancel(); return jsonError(413, 'Request too large.'); }
      chunks.push(part.value);
    }
    body = new Uint8Array(length);
    let offset = 0;
    for (const chunk of chunks) { body.set(chunk, offset); offset += chunk.length; }
    headers.set('Content-Type', 'application/json');
  }
  const target = new URL(url.pathname, backend);
  const response = await fetch(target, { method: request.method, headers, body, redirect: 'manual' });
  if ([301, 302, 303, 307, 308].includes(response.status)) return jsonError(502, 'Hosted backend returned a redirect.');
  const responseHeaders = new Headers(response.headers);
  responseHeaders.set('Cache-Control', 'private, no-store');
  responseHeaders.delete('Set-Cookie');
  return new Response(response.body, { status: response.status, headers: responseHeaders });
}
