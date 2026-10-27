// @vitest-environment jsdom
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { createClient, DEFAULT_ENDPOINT } from '../src/browser/client';
import type { WebConfig } from '../src/browser/types';

const KEY = 'pk_3f9c1e2a7b6d4c80';
const CLICK = 'c_0123456789abcdef';
const OTHER_CLICK = 'c_fedcba9876543210';
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
// Tests run from web/; import.meta.url isn't a file URL under jsdom.
const contract = (path: string) => JSON.parse(readFileSync(resolve(process.cwd(), '../contract', path), 'utf8'));

type Body = { key: string; visitorId: string; sdkVersion: string; items: Record<string, unknown>[] };

let controller: AbortController;
let fetchMock: ReturnType<typeof vi.fn>;
const ok = () => new Response(JSON.stringify({ accepted: 1, duplicates: 0, rejected: [] }), { status: 200 });
const status = (code: number, headers: Record<string, string> = {}) =>
  new Response(JSON.stringify({ error: { code: 'x', message: 'x' } }), { status: code, headers });
const bodies = (): Body[] => fetchMock.mock.calls.map(([, init]) => JSON.parse(init.body));
const items = () => bodies().flatMap((b) => b.items);

function start(config: Partial<WebConfig> = {}) {
  return createClient({ key: KEY, ...config }, { signal: controller.signal });
}

function land(url: string) {
  history.replaceState(null, '', url);
}

function clearAll() {
  window.localStorage.clear();
  for (const c of document.cookie.split(';')) {
    const name = c.split('=')[0]?.trim();
    if (name) document.cookie = `${name}=; max-age=0; path=/`;
  }
}

beforeEach(() => {
  vi.useFakeTimers();
  clearAll();
  land('/');
  document.title = 'Red Shoe';
  controller = new AbortController();
  fetchMock = vi.fn().mockImplementation(async () => ok());
  vi.stubGlobal('fetch', fetchMock);
});

afterEach(() => {
  controller.abort();
  vi.unstubAllGlobals();
  vi.useRealTimers();
  vi.restoreAllMocks();
});

describe('landing and page views', () => {
  it("sends the landing's page view in the contract's shape, after a short pause", async () => {
    land(`/products/red-shoe?dropp_click_id=${CLICK}&utm_source=instagram&utm_medium=link&utm_campaign=summer`);
    start();
    expect(fetchMock).not.toHaveBeenCalled();
    await vi.advanceTimersByTimeAsync(2_000);

    const [url, init] = fetchMock.mock.calls[0]!;
    expect(url).toBe(DEFAULT_ENDPOINT);
    expect(init).toMatchObject({
      method: 'POST',
      keepalive: false,
      credentials: 'omit',
      headers: { 'content-type': 'text/plain;charset=UTF-8' },
    });
    const body = bodies()[0]!;
    const sample = contract('web/request.json');
    expect(Object.keys(body).sort()).toEqual(Object.keys(sample).sort());
    expect(body).toMatchObject({ key: KEY, sdkVersion: sample.sdkVersion });
    expect(body.visitorId).toMatch(UUID);
    expect(body.items).toEqual([
      {
        type: 'event',
        eventId: expect.stringMatching(UUID),
        sessionId: expect.stringMatching(UUID),
        name: 'page_view',
        ts: expect.any(Number),
        path: '/products/red-shoe',
        title: 'Red Shoe',
        referrer: '',
        utm: { source: 'instagram', medium: 'link', campaign: 'summer' },
        clickId: CLICK,
      },
    ]);
  });

  it('keeps the first click (cookie + storage) and strips it from the address bar', () => {
    land(`/?a=1&dropp_click_id=${CLICK}#top`);
    const first = start();
    expect(location.search).toBe('?a=1');
    expect(location.hash).toBe('#top');
    expect(document.cookie).toContain(`dropp_click_id=${CLICK}`);
    controller.abort();

    controller = new AbortController();
    land(`/?dropp_click_id=${OTHER_CLICK}`);
    const second = start();
    expect(first.getClickId()).toBe(CLICK);
    expect(second.getClickId()).toBe(CLICK);
  });

  it('keeps the visitor id in storage and the dropp_vid cookie', () => {
    const c = start();
    const vid = c.getVisitorId();
    expect(vid).toMatch(UUID);
    expect(document.cookie).toContain(`dropp_vid=${vid}`);
    controller.abort();
    controller = new AbortController();
    expect(start().getVisitorId()).toBe(vid);
  });

  it('counts single-page navigations, with the time spent on the page before', async () => {
    start();
    await vi.advanceTimersByTimeAsync(1_500);
    history.pushState({}, '', '/cart');
    await vi.advanceTimersByTimeAsync(2_100);
    const sent = items();
    expect(sent.map((i) => [i.type, i.name ?? null, i.path])).toEqual([
      ['event', 'page_view', '/'],
      ['engage', null, '/'],
      ['event', 'page_view', '/cart'],
    ]);
    expect(sent[1]!.ms).toBeGreaterThanOrEqual(1_000);
    // One session, and the landing details only on its first event.
    expect(new Set(sent.map((i) => i.sessionId)).size).toBe(1);
    expect(sent[2]).not.toHaveProperty('referrer');
  });

  it('starts a new session after 30 minutes idle, or on a new campaign landing', () => {
    start();
    const first = JSON.parse(window.localStorage.getItem('dl_sess')!).id;
    controller.abort();

    controller = new AbortController();
    start();
    expect(JSON.parse(window.localStorage.getItem('dl_sess')!).id).toBe(first);
    controller.abort();

    controller = new AbortController();
    land('/?utm_source=newsletter');
    start();
    const second = JSON.parse(window.localStorage.getItem('dl_sess')!).id;
    expect(second).not.toBe(first);
    controller.abort();

    vi.advanceTimersByTime(31 * 60_000);
    controller = new AbortController();
    land('/');
    start();
    expect(JSON.parse(window.localStorage.getItem('dl_sess')!).id).not.toBe(second);
  });

  it('sends what is queued with keepalive when the page is hidden', async () => {
    start();
    Object.defineProperty(document, 'visibilityState', { value: 'hidden', configurable: true });
    document.dispatchEvent(new Event('visibilitychange'));
    await vi.advanceTimersByTimeAsync(0);
    expect(fetchMock.mock.calls[0]![1].keepalive).toBe(true);
    Object.defineProperty(document, 'visibilityState', { value: 'visible', configurable: true });
  });
});

describe('track and identify', () => {
  it('validates events and props in the browser', async () => {
    const c = start();
    c.track('Add To Cart');
    c.track('add_to_cart', { 'sku': 'RS-9', 'price': 1499, 'email': 'a@b.co', 'bad key': 1, 'list': [1] as unknown as number });
    await vi.advanceTimersByTimeAsync(2_000);
    const added = items().filter((i) => i.name !== 'page_view');
    expect(added).toHaveLength(1);
    expect(added[0]).toMatchObject({ name: 'add_to_cart', props: { sku: 'RS-9', price: 1499 } });
  });

  it('identifies once per user, never with an email, and logs out', async () => {
    const c = start();
    c.identify('user_8812');
    c.identify('user_8812');
    c.identify('someone@example.com');
    c.logout();
    c.logout();
    await vi.advanceTimersByTimeAsync(2_000);
    expect(items().filter((i) => i.type === 'identify')).toEqual([
      { type: 'identify', ts: expect.any(Number), userId: 'user_8812' },
      { type: 'identify', ts: expect.any(Number), userId: null },
    ]);
  });
});

describe('consent', () => {
  it('with consent required, stores nothing (not even the click) and sends nothing until grant()', async () => {
    land(`/?dropp_click_id=${CLICK}`);
    const c = start({ consent: 'required' });
    c.track('view_item');
    c.identify('user_8812');
    await vi.advanceTimersByTimeAsync(5_000);
    expect(fetchMock).not.toHaveBeenCalled();
    expect(c.getVisitorId()).toBeNull();
    expect(window.localStorage.length).toBe(0);
    expect(document.cookie).not.toMatch(/dropp_(vid|click_id)=[^;]/);
    expect(location.search).toBe('');
    // Kept in memory for this page.
    expect(c.getClickId()).toBe(CLICK);

    c.grant();
    expect(JSON.parse(window.localStorage.getItem('dl_click')!)).toEqual({ id: CLICK, t: expect.any(Number) });
    expect(document.cookie).toContain(`dropp_click_id=${CLICK}`);
    expect(document.cookie).toContain('dropp_vid=');
    await vi.advanceTimersByTimeAsync(0);
    expect(items().map((i) => i.name ?? i.type)).toEqual(['page_view', 'view_item', 'identify']);
    expect(items()[0]!.clickId).toBe(CLICK);
    expect(c.getVisitorId()).toMatch(UUID);
    expect(c.getClickId()).toBe(CLICK);
  });

  it('with consent required, revoke() before grant() forgets the click held in memory', () => {
    land(`/?dropp_click_id=${CLICK}`);
    const c = start({ consent: 'required' });
    c.revoke();
    expect(c.getClickId()).toBeNull();
    c.grant();
    expect(window.localStorage.getItem('dl_click')).toBeNull();
    expect(document.cookie).not.toMatch(/dropp_click_id=[^;]/);
  });

  it('with consent required, a later page keeps the first click once granted', () => {
    land(`/?dropp_click_id=${CLICK}`);
    start({ consent: 'required' }).grant();
    controller.abort();
    controller = new AbortController();
    land(`/?dropp_click_id=${OTHER_CLICK}`);
    const c = start({ consent: 'required' });
    expect(c.getClickId()).toBe(CLICK);
  });

  it('with consent required, keeps the identified user in memory until grant()', async () => {
    const c = start({ consent: 'required' });
    c.identify('user_8812');
    expect(window.localStorage.getItem('dl_uid')).toBeNull();
    c.grant();
    expect(window.localStorage.getItem('dl_uid')).toBe('"user_8812"');
    await vi.advanceTimersByTimeAsync(0);
    expect(items().filter((i) => i.type === 'identify')).toEqual([{ type: 'identify', ts: expect.any(Number), userId: 'user_8812' }]);
  });

  it('revoke() clears everything stored and stops sending', async () => {
    land(`/?dropp_click_id=${CLICK}`);
    const c = start();
    c.revoke();
    expect(window.localStorage.getItem('dl_vid')).toBeNull();
    expect(document.cookie).not.toMatch(/dropp_(vid|click_id)=[^;]/);
    expect(c.getVisitorId()).toBeNull();
    c.track('view_item');
    await vi.advanceTimersByTimeAsync(5_000);
    expect(fetchMock).not.toHaveBeenCalled();
  });
});

describe('Global Privacy Control', () => {
  const setGpc = (value: boolean | undefined) => Object.defineProperty(navigator, 'globalPrivacyControl', { value, configurable: true });
  afterEach(() => setGpc(undefined));

  it('with GPC on, stores nothing, sends nothing, and grant() does not override it', async () => {
    setGpc(true);
    land(`/?dropp_click_id=${CLICK}`);
    const c = start();
    c.track('view_item');
    c.identify('user_8812');
    c.grant();
    await vi.advanceTimersByTimeAsync(5_000);
    await c.flush();
    expect(fetchMock).not.toHaveBeenCalled();
    expect(c.getVisitorId()).toBeNull();
    expect(c.getClickId()).toBeNull();
    expect(window.localStorage.length).toBe(0);
    expect(document.cookie).not.toMatch(/dropp_(vid|click_id)=[^;]/);
    // The click still leaves the address bar.
    expect(location.search).toBe('');
  });

  it('with GPC on, clears what an earlier visit stored', () => {
    land(`/?dropp_click_id=${CLICK}`);
    start().identify('user_8812');
    expect(window.localStorage.getItem('dl_vid')).not.toBeNull();
    controller.abort();
    controller = new AbortController();

    setGpc(true);
    land('/');
    start();
    for (const k of ['dl_vid', 'dl_sess', 'dl_click', 'dl_q', 'dl_uid']) expect(window.localStorage.getItem(k)).toBeNull();
    expect(document.cookie).not.toMatch(/dropp_(vid|click_id)=[^;]/);
  });

  it('is ignored when the brand sets respectGlobalPrivacyControl: false', async () => {
    setGpc(true);
    const c = start({ respectGlobalPrivacyControl: false });
    await vi.advanceTimersByTimeAsync(2_000);
    expect(items().map((i) => i.name)).toEqual(['page_view']);
    expect(c.getVisitorId()).toMatch(UUID);
  });

  it('with GPC off (false or absent), behaves as before', async () => {
    setGpc(false);
    start();
    await vi.advanceTimersByTimeAsync(2_000);
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });
});

describe('sending', () => {
  it('keeps the queue and retries with backoff on 503, honouring Retry-After', async () => {
    fetchMock.mockImplementationOnce(async () => status(503, { 'retry-after': '10' }));
    start();
    await vi.advanceTimersByTimeAsync(2_000);
    expect(fetchMock).toHaveBeenCalledTimes(1);
    await vi.advanceTimersByTimeAsync(7_000);
    expect(fetchMock).toHaveBeenCalledTimes(1);
    await vi.advanceTimersByTimeAsync(6_000);
    expect(fetchMock).toHaveBeenCalledTimes(2);
    expect(bodies()[1]!.items[0]!.eventId).toBe(bodies()[0]!.items[0]!.eventId);
  });

  it('stops on 403 (wrong key or website) and says why', async () => {
    const error = vi.spyOn(console, 'error').mockImplementation(() => {});
    fetchMock.mockImplementation(async () => status(403));
    const c = start();
    await vi.advanceTimersByTimeAsync(2_000);
    c.track('view_item');
    await vi.advanceTimersByTimeAsync(60_000);
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(error).toHaveBeenCalledWith(expect.stringContaining("Check data-key and the app's web domains"));
  });

  it('drops a batch the server refuses as malformed', async () => {
    fetchMock.mockImplementationOnce(async () => status(400));
    start();
    await vi.advanceTimersByTimeAsync(2_000);
    expect(JSON.parse(window.localStorage.getItem('dl_q')!).items).toEqual([]);
  });

  it('falls back to the API host when a first-party endpoint is missing', async () => {
    fetchMock.mockImplementationOnce(async () => status(404));
    start({ endpoint: 'https://go.brand.example/_d/e' });
    await vi.advanceTimersByTimeAsync(2_000);
    expect(fetchMock.mock.calls.map(([url]) => url)).toEqual(['https://go.brand.example/_d/e', DEFAULT_ENDPOINT]);
  });

  it('is off without a valid key', async () => {
    const error = vi.spyOn(console, 'error').mockImplementation(() => {});
    const c = createClient({ key: 'ak_nope' });
    c.track('view_item');
    await vi.advanceTimersByTimeAsync(5_000);
    expect(fetchMock).not.toHaveBeenCalled();
    expect(c.getVisitorId()).toBeNull();
    expect(error).toHaveBeenCalled();
  });
});
