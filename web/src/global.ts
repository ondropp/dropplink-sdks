import { createClient } from './browser/client';
import type { DropplinkWeb, WebConfig } from './browser/types';

/**
 * The script-tag build (`dist/dropplink.min.js`, served by dropp-attribution as `/_d/s.js` on the app's link
 * domain). It reads its settings from the tag (or `window.DropplinkConfig`), sends to `/_d/e` beside itself, and
 * replays calls queued before it loaded:
 *
 *   <script>window.dropplink=window.dropplink||{q:[]};['track','identify','logout','grant','revoke'].forEach(function(m){dropplink[m]=dropplink[m]||function(){dropplink.q.push([m].concat([].slice.call(arguments)))}});</script>
 *   <script src="https://go.yourbrand.com/_d/s.js" data-key="pk_…" async></script>
 */
type Queued = [keyof DropplinkWeb, ...unknown[]];
type Globals = { dropplink?: DropplinkWeb | { q?: Queued[] }; DropplinkConfig?: Partial<WebConfig> };

(() => {
  if (typeof document === 'undefined') return;
  const tag = (document.currentScript ?? document.querySelector('script[data-key]')) as HTMLScriptElement | null;
  const data = tag?.dataset ?? {};
  const g = window as unknown as Globals;
  const fromWindow = g.DropplinkConfig ?? {};

  let endpoint = fromWindow.endpoint ?? data.endpoint;
  // Served as …/s.js: send to …/e on the same host (first-party on the link domain).
  if (!endpoint && tag?.src) {
    try {
      const src = new URL(tag.src);
      if (/\/s\.js$/.test(src.pathname)) endpoint = `${src.origin}${src.pathname.replace(/s\.js$/, 'e')}`;
    } catch {
      // A relative or odd src: use the default endpoint.
    }
  }

  const config: WebConfig = {
    key: fromWindow.key ?? data.key ?? '',
    endpoint,
    consent: (fromWindow.consent ?? data.consent) === 'required' ? 'required' : 'granted',
    spa: fromWindow.spa ?? data.spa !== 'false',
    cookieDomain: fromWindow.cookieDomain ?? data.cookieDomain,
    debug: fromWindow.debug ?? data.debug === 'true',
  };

  const stub = g.dropplink as { q?: Queued[] } | undefined;
  const queued = Array.isArray(stub?.q) ? stub.q : [];
  const client = createClient(config);
  g.dropplink = client;
  for (const [method, ...args] of queued) {
    const fn = client[method] as ((...a: unknown[]) => unknown) | undefined;
    if (typeof fn === 'function') {
      try {
        fn.apply(client, args);
      } catch {
        // A bad queued call never stops the others.
      }
    }
  }
})();
