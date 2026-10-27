// @vitest-environment jsdom
import { expect, it, vi } from 'vitest';

it('the script tag reads its tag, sends beside itself on the link domain, and replays queued calls', async () => {
  vi.useFakeTimers();
  const fetchMock = vi.fn().mockImplementation(async () => new Response('{"accepted":2,"duplicates":0,"rejected":[]}'));
  vi.stubGlobal('fetch', fetchMock);

  const tag = document.createElement('script');
  tag.src = 'https://go.brand.example/_d/s.js';
  tag.dataset.key = 'pk_3f9c1e2a7b6d4c80';
  Object.defineProperty(document, 'currentScript', { value: tag, configurable: true });
  // The snippet's stub, with a call made before the script loaded.
  (window as unknown as { dropplink: { q: unknown[][] } }).dropplink = { q: [['track', 'view_item', { sku: 'RS-9' }]] };

  await import('../src/global');
  await vi.advanceTimersByTimeAsync(2_000);

  const g = (window as unknown as { dropplink: { getVisitorId(): string | null } }).dropplink;
  expect(typeof g.getVisitorId).toBe('function');
  const [url, init] = fetchMock.mock.calls[0]!;
  expect(url).toBe('https://go.brand.example/_d/e');
  expect(JSON.parse(init.body).items.map((i: { name: string }) => i.name)).toEqual(['page_view', 'view_item']);
  vi.useRealTimers();
});

it('the script tag reads data-respect-global-privacy-control', async () => {
  vi.resetModules();
  vi.useFakeTimers();
  const fetchMock = vi.fn().mockImplementation(async () => new Response('{"accepted":1,"duplicates":0,"rejected":[]}'));
  vi.stubGlobal('fetch', fetchMock);
  Object.defineProperty(navigator, 'globalPrivacyControl', { value: true, configurable: true });

  const tag = document.createElement('script');
  tag.src = 'https://go.brand.example/_d/s.js';
  tag.dataset.key = 'pk_3f9c1e2a7b6d4c80';
  tag.dataset.respectGlobalPrivacyControl = 'false';
  Object.defineProperty(document, 'currentScript', { value: tag, configurable: true });
  delete (window as unknown as { dropplink?: unknown }).dropplink;

  await import('../src/global');
  await vi.advanceTimersByTimeAsync(2_000);
  expect(fetchMock).toHaveBeenCalledTimes(1);

  // Without the attribute, GPC wins.
  vi.resetModules();
  fetchMock.mockClear();
  delete tag.dataset.respectGlobalPrivacyControl;
  delete (window as unknown as { dropplink?: unknown }).dropplink;
  await import('../src/global');
  await vi.advanceTimersByTimeAsync(5_000);
  expect(fetchMock).not.toHaveBeenCalled();

  Object.defineProperty(navigator, 'globalPrivacyControl', { value: undefined, configurable: true });
  vi.useRealTimers();
});
