import { describe, expect, it } from 'vitest';
import { handleHosted } from '../src/hosted';
import { mockOutbound } from './outbound';

const origin = 'https://build.example';
const id = 'abcdefghijklmnopqrstuvwxyz123456';
const request = (path: string, init?: RequestInit) => new Request(`https://site.example${path}`, init);

describe('hosted build proxy', () => {
  it('fails closed for missing configuration, unsafe origins, upload types and oversized requests', async () => {
    expect((await handleHosted(request('/api/hosted/jobs'), undefined, undefined)).status).toBe(503);
    expect((await handleHosted(request('/api/hosted/jobs'), 'https://build.example/path', 'secret')).status).toBe(503);
    expect((await handleHosted(request('/api/hosted/jobs', {method:'POST', body:'zip', headers:{'content-type':'application/zip'}}), origin, 'secret')).status).toBe(415);
    expect((await handleHosted(request('/api/hosted/jobs', {method:'POST', body:'x'.repeat(16385), headers:{'content-type':'application/json'}}), origin, 'secret')).status).toBe(413);
    expect((await handleHosted(request('/api/hosted/jobs/../secrets'), origin, 'secret')).status).toBe(404);
  });

  it('forwards a bounded job request using only the configured credential', async () => {
    const mock = mockOutbound(call => {
      expect(call.url).toBe(`${origin}/api/hosted/jobs`);
      expect(call.headers.get('x-hosted-token')).toBe('server-secret');
      expect(call.headers.has('cookie')).toBe(false);
      expect(JSON.parse(call.body!)).toEqual({catalogId:'release-1'});
      return new Response('{"id":"job"}', {status:202, headers:{'set-cookie':'private=x'}});
    });
    try {
      const result = await handleHosted(request('/api/hosted/jobs', {method:'POST', headers:{'content-type':'application/json','x-hosted-token':'attacker','cookie':'user=1'},body:'{"catalogId":"release-1"}'}), origin, 'server-secret');
      expect(result.status).toBe(202);
      expect(result.headers.get('set-cookie')).toBeNull();
      expect(result.headers.get('cache-control')).toBe('private, no-store');
    } finally { mock.restore(); }
  });

  it('passes range responses without accepting backend redirects', async () => {
    const mock = mockOutbound(call => {
      expect(call.headers.get('range')).toBe('bytes=4-7');
      return new Response('4567', {status:206, headers:{'content-range':'bytes 4-7/10'}});
    });
    try {
      const response = await handleHosted(request(`/api/hosted/jobs/${id}/artifact`,{headers:{range:'bytes=4-7'}}),origin,'secret');
      expect(response.status).toBe(206);
      expect(response.headers.get('content-range')).toBe('bytes 4-7/10');
      expect(await response.text()).toBe('4567');
    } finally { mock.restore(); }
    const redirect = mockOutbound(() => new Response(null,{status:302,headers:{location:'https://attacker.test'}}));
    try { expect((await handleHosted(request(`/api/hosted/jobs/${id}`),origin,'secret')).status).toBe(502); }
    finally { redirect.restore(); }
  });

  it('permits only lease lifecycle methods on validated capability paths', async () => {
    const lease = 'lease_12345678901234567890';
    const mock = mockOutbound(call => new Response(null, { status: call.method === 'DELETE' ? 204 : 201 }));
    try {
      const path = `/api/hosted/jobs/${id}/lease`;
      expect((await handleHosted(request(path, { method: 'POST' }), origin, 'secret')).status).toBe(201);
      expect((await handleHosted(request(`${path}/${lease}/renew`, { method: 'POST' }), origin, 'secret')).status).toBe(201);
      expect((await handleHosted(request(`${path}/${lease}`, { method: 'DELETE' }), origin, 'secret')).status).toBe(204);
      expect((await handleHosted(request(path, { method: 'GET' }), origin, 'secret')).status).toBe(405);
      expect((await handleHosted(request(`${path}/bad`, { method: 'DELETE' }), origin, 'secret')).status).toBe(404);
    } finally { mock.restore(); }
  });
});
