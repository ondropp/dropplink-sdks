// Node 22+ defines its own global localStorage/sessionStorage, which wins over jsdom's in Vitest. Browser
// tests need jsdom's, as a real page has.
const dom = (globalThis as { jsdom?: { window: Window } }).jsdom;
if (dom) {
  for (const kind of ['localStorage', 'sessionStorage'] as const) {
    Object.defineProperty(globalThis, kind, { value: dom.window[kind], configurable: true, writable: true });
  }
}
