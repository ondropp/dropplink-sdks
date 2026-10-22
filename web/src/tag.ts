import { type Dropplink, type DropplinkConfig, createDropplink } from "./core.js";

// The script-tag build (dist/dropplink.js), served by the link domain at /_d/s.js:
//
//   <script src="https://go.brand.com/_d/s.js" data-key="pk_…" defer></script>
//
// Calls made before it loads are queued by this stub and replayed:
//
//   <script>!function(w){var d=w.dropplink=w.dropplink||{q:[]};["track","identify","logout","grant","revoke"]
//   .forEach(function(m){d[m]=d[m]||function(){d.q.push([m].concat([].slice.call(arguments)))}})}(window)</script>

type Stub = { q?: unknown[][] } & Partial<Dropplink>;

declare global {
  interface Window {
    dropplink?: Stub | Dropplink;
    DropplinkConfig?: Partial<DropplinkConfig>;
  }
}

(() => {
  const tag = (document.currentScript ?? document.querySelector("script[data-key]")) as HTMLScriptElement | null;
  const data = tag?.dataset ?? {};
  const fromWindow = window.DropplinkConfig ?? {};

  // Batches go back to wherever the script came from: /_d/s.js → /_d/e, /v1/web/s.js → /v1/web/e.
  let endpoint = fromWindow.endpoint ?? data.endpoint;
  if (!endpoint && tag?.src) {
    try {
      const src = new URL(tag.src);
      if (/\/s\.js$/.test(src.pathname)) endpoint = `${src.origin}${src.pathname.replace(/s\.js$/, "e")}`;
    } catch {
      // Keep the default.
    }
  }

  const config: DropplinkConfig = {
    key: fromWindow.key ?? data.key ?? "",
    endpoint,
    consent: (fromWindow.consent ?? data.consent) === "required" ? "required" : "granted",
    spa: fromWindow.spa ?? data.spa !== "false",
    cookieDomain: fromWindow.cookieDomain ?? data.cookieDomain,
    debug: fromWindow.debug ?? data.debug === "true",
  };

  const stub = window.dropplink as Stub | undefined;
  const queued = Array.isArray(stub?.q) ? stub.q : [];
  const sdk = createDropplink(config);
  window.dropplink = sdk;
  for (const [method, ...args] of queued) {
    const fn = (sdk as unknown as Record<string, unknown>)[method as string];
    if (typeof fn === "function") {
      try {
        (fn as (...a: unknown[]) => unknown).apply(sdk, args);
      } catch {
        // A bad queued call must not stop the rest.
      }
    }
  }
})();
