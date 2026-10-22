import { readFileSync } from 'node:fs';
import { describe, expect, it, vi } from 'vitest';
import pkg from '../package.json';
import { DropplinkError, DropplinkServer, VERSION, readClickId, readVisitorId, type ServerEvent } from '../src/server';

const KEY = 'sk_5a7c9e1b3d2f4a60.secret_value';
const CLICK = 'c_0123456789abcdef';
const contract = (path: string) => JSON.parse(readFileSync(new URL(`../../contract/${path}`, import.meta.url), 'utf8'));

const ok = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });
const fail = (status: number, code: string, headers: Record<string, string> = {}) =>
  new Response(JSON.stringify({ error: { code, message: code } }), { status, headers: { 'content-type': 'application/json', ...headers } });
const empty = { accepted: 0, duplicates: 0, pending: 0, rejected: [], warnings: [] };

function client(fetchMock: ReturnType<typeof vi.fn>, extra: Partial<ConstructorParameters<typeof DropplinkServer>[0]> = {}) {
  return new DropplinkServer({ serverKey: KEY, fetch: fetchMock as unknown as typeof fetch, ...extra });
}

const sentBody = (fetchMock: ReturnType<typeof vi.fn>, call = 0) => JSON.parse(fetchMock.mock.calls[call]![1].body);

describe('DropplinkServer config', () => {
  it('needs a full server key token', () => {
    expect(() => new DropplinkServer({ serverKey: 'ak_0123456789abcdef' })).toThrow(/sk_<id>\.<secret>/);
    expect(() => new DropplinkServer({ serverKey: 'sk_5a7c9e1b3d2f4a60' })).toThrow();
    expect(() => new DropplinkServer({ serverKey: ` ${KEY} ` })).not.toThrow();
  });

  it('shares the SDKs version', () => {
    expect(VERSION).toBe(pkg.version);
  });
});

describe('track', () => {
  it("sends the contract's request shape with the bearer key", async () => {
    const fetchMock = vi.fn().mockResolvedValue(ok(contract('s2s/events-response.json')));
    const request = contract('s2s/events-request.json') as { events: ServerEvent[] };
    const result = await client(fetchMock).track(request.events);

    const [url, init] = fetchMock.mock.calls[0]!;
    expect(url).toBe('https://attribution.ondropp.app/v1/s2s/events');
    expect(init.method).toBe('POST');
    expect(init.headers.Authorization).toBe(`Bearer ${KEY}`);
    expect(init.headers['Content-Type']).toBe('application/json');
    expect(init.headers['User-Agent']).toBe(`dropplink-web/${VERSION}`);
    expect(sentBody(fetchMock)).toEqual(request);
    expect(result).toEqual(contract('s2s/events-response.json'));
  });

  it('sends a website order with its clickId, ts from a Date, and leaves out empty ids', async () => {
    const fetchMock = vi.fn().mockResolvedValue(ok({ ...empty, accepted: 1 }));
    await client(fetchMock).track({
      eventId: 'order-W5521',
      clickId: CLICK,
      userId: null,
      installId: undefined,
      name: 'purchase',
      ts: new Date(1760700300_000),
      revenue: { amount: 1499, currency: 'INR', orderId: 'W5521' },
    });
    expect(sentBody(fetchMock)).toEqual({
      events: [
        {
          eventId: 'order-W5521',
          clickId: CLICK,
          name: 'purchase',
          ts: 1760700300,
          revenue: { amount: 1499, currency: 'INR', orderId: 'W5521' },
        },
      ],
    });
  });

  it('matches the server schema for clickId', () => {
    const schema = contract('schemas/s2s-events-request.json');
    expect(schema.properties.events.items.properties.clickId.pattern).toBe('^c_[0-9a-f]{8,32}$');
  });

  it('drops a malformed clickId with an unknown_click warning instead of losing the order', async () => {
    const fetchMock = vi.fn().mockResolvedValue(ok({ ...empty, accepted: 1 }));
    const result = await client(fetchMock).track({ eventId: 'o1', userId: 'u1', clickId: 'tampered', name: 'purchase', ts: 1760700300 });
    expect(sentBody(fetchMock).events[0]).toEqual({ eventId: 'o1', userId: 'u1', name: 'purchase', ts: 1760700300 });
    expect(result.warnings).toEqual([{ eventId: 'o1', code: 'unknown_click', clickId: 'tampered' }]);
  });

  it('splits into batches of 100 and maps rejected indexes back to the input', async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(ok({ ...empty, accepted: 100 }))
      .mockResolvedValueOnce(ok({ ...empty, accepted: 4, rejected: [{ index: 1, eventId: 'e101', code: 'too_old', message: 'old' }] }));
    const events = Array.from({ length: 105 }, (_, i) => ({ eventId: `e${i}`, userId: 'u', name: 'purchase', ts: 1760700300 }));
    const result = await client(fetchMock).track(events);
    expect(fetchMock).toHaveBeenCalledTimes(2);
    expect(sentBody(fetchMock, 0).events).toHaveLength(100);
    expect(sentBody(fetchMock, 1).events).toHaveLength(5);
    expect(result.accepted).toBe(104);
    expect(result.rejected).toEqual([{ index: 101, eventId: 'e101', code: 'too_old', message: 'old' }]);
  });

  it('keeps each request under the 64 KB body limit', async () => {
    const fetchMock = vi.fn().mockImplementation(async () => ok(empty));
    const big = 'x'.repeat(256);
    const props = Object.fromEntries(Array.from({ length: 20 }, (_, i) => [`p${i}`, big]));
    await client(fetchMock).track(Array.from({ length: 30 }, (_, i) => ({ eventId: `e${i}`, userId: 'u', name: 'purchase', props })));
    expect(fetchMock.mock.calls.length).toBeGreaterThan(1);
    for (const [, init] of fetchMock.mock.calls) expect(init.body.length).toBeLessThan(64 * 1024);
  });

  it('retries 429 and 5xx, honouring Retry-After', async () => {
    vi.useFakeTimers();
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(fail(429, 'rate_limited', { 'retry-after': '2' }))
      .mockResolvedValueOnce(fail(503, 'storage_unavailable'))
      .mockResolvedValueOnce(ok({ ...empty, accepted: 1 }));
    const pending = client(fetchMock).track({ eventId: 'o1', userId: 'u', name: 'purchase' });
    await vi.advanceTimersByTimeAsync(1999);
    expect(fetchMock).toHaveBeenCalledTimes(1);
    await vi.advanceTimersByTimeAsync(10_000);
    expect((await pending).accepted).toBe(1);
    expect(fetchMock).toHaveBeenCalledTimes(3);
    vi.useRealTimers();
  });

  it('throws the server error at once for a 4xx, and after the retries for a 5xx', async () => {
    const unauthorized = vi.fn().mockResolvedValue(fail(401, 'invalid_key'));
    await expect(client(unauthorized).track({ eventId: 'o1', userId: 'u', name: 'purchase' })).rejects.toMatchObject({
      name: 'DropplinkError',
      status: 401,
      code: 'invalid_key',
    });
    expect(unauthorized).toHaveBeenCalledTimes(1);

    const down = vi.fn().mockImplementation(async () => fail(503, 'storage_unavailable'));
    const error = await client(down, { maxRetries: 0 })
      .track({ eventId: 'o1', userId: 'u', name: 'purchase' })
      .catch((e) => e);
    expect(error).toBeInstanceOf(DropplinkError);
    expect(error.retryable).toBe(true);
  });

  it('reports network errors and timeouts as retryable', async () => {
    const offline = vi.fn().mockRejectedValue(new TypeError('fetch failed'));
    await expect(client(offline, { maxRetries: 0 }).track({ eventId: 'o1', userId: 'u', name: 'p' })).rejects.toMatchObject({
      code: 'network_error',
      status: null,
    });
    const slow = vi.fn().mockRejectedValue(Object.assign(new Error('t'), { name: 'TimeoutError' }));
    await expect(client(slow, { maxRetries: 0 }).track({ eventId: 'o1', userId: 'u', name: 'p' })).rejects.toMatchObject({
      code: 'timeout',
    });
  });

  it('sends nothing for an empty list', async () => {
    const fetchMock = vi.fn();
    expect(await client(fetchMock).track([])).toEqual(empty);
    expect(fetchMock).not.toHaveBeenCalled();
  });
});

describe('deletion', () => {
  it('deletes a user (URL-encoded) and reads the request back', async () => {
    const deletion = contract('s2s/deletion.pending.json');
    const fetchMock = vi.fn().mockImplementation(async () => ok(deletion, 202));
    const c = client(fetchMock, { baseUrl: 'http://localhost:4100/' });
    expect(await c.deleteUser('user 8812')).toEqual(deletion);
    await c.getDeletion(deletion.requestId);
    expect(fetchMock.mock.calls.map(([url, init]) => [init.method, url])).toEqual([
      ['DELETE', 'http://localhost:4100/v1/s2s/users/user%208812'],
      ['GET', `http://localhost:4100/v1/s2s/deletions/${deletion.requestId}`],
    ]);
    expect(fetchMock.mock.calls[0]![1].headers['Content-Type']).toBeUndefined();
  });
});

describe('readClickId', () => {
  it('reads a valid click from a Cookie header', () => {
    expect(readClickId(`theme=dark; dropp_click_id=${CLICK}; cart=abc`)).toBe(CLICK);
    expect(readClickId(`dropp_click_id=${encodeURIComponent(CLICK)}`)).toBe(CLICK);
  });

  it('returns null for a missing, malformed or tampered cookie', () => {
    expect(readClickId(undefined)).toBeNull();
    expect(readClickId('theme=dark')).toBeNull();
    expect(readClickId('dropp_click_id=nope')).toBeNull();
    expect(readClickId('dropp_click_id=%E0%A4%A')).toBeNull();
    expect(readClickId('x_dropp_click_id=c_0123456789abcdef')).toBeNull();
  });
});

describe('website visitors', () => {
  const VID = '0b6e5c1a-3f2d-4c8e-9a71-5d4b2e6f8c10';

  it('sends visitorId (lower-cased) and matches the server schema', async () => {
    const fetchMock = vi.fn().mockImplementation(async () => ok({ ...empty, accepted: 1 }));
    await client(fetchMock).track({ eventId: 'o1', visitorId: VID.toUpperCase(), name: 'purchase', ts: 1760700300 });
    expect(sentBody(fetchMock).events[0]).toEqual({ eventId: 'o1', visitorId: VID, name: 'purchase', ts: 1760700300 });
    const schema = contract('schemas/s2s-events-request.json');
    expect(schema.properties.events.items.properties.visitorId).toBeDefined();
  });

  it('drops a malformed visitorId with an unknown_visitor warning', async () => {
    const fetchMock = vi.fn().mockImplementation(async () => ok({ ...empty, accepted: 1 }));
    const result = await client(fetchMock).track({ eventId: 'o1', userId: 'u1', visitorId: 'nope', name: 'purchase', ts: 1760700300 });
    expect(sentBody(fetchMock).events[0]).not.toHaveProperty('visitorId');
    expect(result.warnings).toEqual([{ eventId: 'o1', code: 'unknown_visitor', visitorId: 'nope' }]);
  });

  it('reads the dropp_vid cookie', () => {
    expect(readVisitorId(`a=1; dropp_vid=${VID}; dropp_click_id=c_0123456789abcdef`)).toBe(VID);
    expect(readVisitorId('dropp_vid=not-a-uuid')).toBeNull();
    expect(readVisitorId(undefined)).toBeNull();
  });
});
