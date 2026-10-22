import { COOKIES, KEYS, deleteCookie, getCookie, read, remove, setCookie, uuid, write } from "./storage.js";
import { type EventProps, cleanProps, cleanUserId, validClickId, validEventName } from "./validate.js";

// The website SDK (docs/sdk-spec.md §12). It records which Dropplink link brought a visitor and what they
// do on the site: page views, the brand's funnel events, time on page. It never reports money: orders
// come from the brand's server with the `dropp_vid` / `dropp_click_id` cookies this script sets.

export const VERSION = "0.2.0";
export const SDK_VERSION = `${VERSION}-web`;
export const DEFAULT_ENDPOINT = "https://attribution.ondropp.app/v1/web/e";

export interface DropplinkConfig {
  /** The app's web key, `pk_…`, from the dashboard. */
  key: string;
  /** Where batches go. The script tag defaults to its own link domain (`https://go.brand.com/_d/e`). */
  endpoint?: string;
  /** `required`: nothing but the click id is kept or sent until `grant()`. Default `granted`. */
  consent?: "granted" | "required";
  /** Page views on `history.pushState` / `popstate`, for single-page apps. Default `true`. */
  spa?: boolean;
  /** Set the cookies on a parent domain (`.brand.com`) so every subdomain's server can read them. */
  cookieDomain?: string;
  debug?: boolean;
}

export interface Dropplink {
  /** A funnel event: `view_item`, `add_to_cart`, `begin_checkout`, `sign_up`, `purchase`, or your own. */
  track(name: string, props?: EventProps): void;
  /** Links this visitor to your user id after login, for the journey view. Never moves credit. */
  identify(userId: string): void;
  logout(): void;
  /** Consent given: starts sending, including what was recorded on this page while waiting. */
  grant(): void;
  /** Consent withdrawn: stops, and clears everything the script stored, the click id included. */
  revoke(): void;
  /** For your server: send it with the order as `visitorId`. Null before consent. */
  getVisitorId(): string | null;
  /** The first Dropplink click in the last 30 days, also in the `dropp_click_id` cookie. */
  getClickId(): string | null;
  /** Sends what's queued now. */
  flush(): Promise<void>;
}

type Utm = Partial<Record<"source" | "medium" | "campaign" | "content" | "term", string>>;

type WireItem =
  | {
      type: "event";
      eventId: string;
      sessionId: string;
      name: string;
      ts: number;
      path: string;
      title?: string;
      referrer?: string;
      utm?: Utm;
      clickId?: string;
      props?: EventProps;
    }
  | { type: "engage"; eventId: string; sessionId: string; ts: number; path: string; ms: number }
  | { type: "identify"; ts: number; userId: string | null };

/** A queued item: the wire item plus a local id and when it was queued. */
type Queued = { qid: string; at: number; item: WireItem };

const SESSION_TIMEOUT_MS = 30 * 60_000;
const CLICK_TTL_DAYS = 30;
const VISITOR_COOKIE_DAYS = 395;
const QUEUE_MAX_ITEMS = 200;
const QUEUE_MAX_AGE_MS = 24 * 3600_000;
const PENDING_CONSENT_MAX = 50;
const BATCH_MAX_ITEMS = 50;
/** fetch keepalive bodies are limited to 64 KB. */
const BATCH_MAX_BYTES = 60_000;
const FLUSH_DELAY_MS = 2_000;
const FLUSH_NOW_AT = 20;
const BACKOFF_MAX_MS = 5 * 60_000;
const MIN_ENGAGE_MS = 1_000;
/**
 * The first-party host isn't routed (or isn't reachable): try the API host. Statuses our collector never
 * returns, plus no response at all. Not 503: the collector sends it itself, with Retry-After.
 */
const FALL_BACK_ON = new Set([0, 404, 405, 502]);

const nowSec = () => Math.floor(Date.now() / 1000);

/** `signal` stops the instance (listeners, history hooks, timers); for tests, not part of the public API. */
export function createDropplink(config: DropplinkConfig, internal: { signal?: AbortSignal } = {}): Dropplink {
  const { signal } = internal;
  const log = (message: string) => {
    if (config.debug) console.log(`[Dropplink] ${message}`);
  };
  const warn = (message: string) => {
    if (config.debug) console.warn(`[Dropplink] ${message}`);
  };

  const noop: Dropplink = {
    track() {},
    identify() {},
    logout() {},
    grant() {},
    revoke() {},
    getVisitorId: () => null,
    getClickId: () => null,
    flush: async () => {},
  };
  if (typeof window === "undefined" || typeof document === "undefined") return noop;
  if (!/^pk_[a-f0-9]{16}$/.test(config.key ?? "")) {
    console.error("[Dropplink] Missing or invalid web key (data-key=\"pk_…\"); the script is off.");
    return noop;
  }
  // Headless browsers and automation: never counted.
  if (navigator.webdriver) {
    log("automated browser, not tracking");
    return noop;
  }

  const endpoint = config.endpoint ?? DEFAULT_ENDPOINT;
  const fallback = endpoint === DEFAULT_ENDPOINT ? null : DEFAULT_ENDPOINT;
  const cookieDomain = config.cookieDomain;
  let consented = config.consent !== "required" || read<string>(KEYS.consent) === "granted";
  /** Events from before consent, on this page only. */
  let waiting: Queued[] = [];
  /** A 401/403 means a wrong key or a website missing from the app's domains; retrying won't help. */
  let refused = false;
  let inFlight: Promise<void> | null = null;
  let timer: ReturnType<typeof setTimeout> | null = null;
  let backoffMs = 0;

  // ── Landing: the click id and campaign tags this page was opened with ─────────────────────────────
  const params = new URLSearchParams(location.search);
  const landingClick = params.get("dropp_click_id");
  const utm: Utm = {};
  for (const k of ["source", "medium", "campaign", "content", "term"] as const) {
    const v = params.get(`utm_${k}`);
    if (v) utm[k] = v.slice(0, 128);
  }
  const hasUtm = Object.keys(utm).length > 0;
  const landingClickId = validClickId(landingClick) ? landingClick : undefined;

  // The first click in 30 days is kept (first touch); a later one only marks its own session.
  if (landingClickId && !storedClick()) {
    write(KEYS.click, { id: landingClickId, t: Date.now() });
    setCookie(COOKIES.click, landingClickId, CLICK_TTL_DAYS, cookieDomain);
  }
  // Take the click id off the address bar, so a shared URL doesn't carry this visitor's click.
  if (landingClick !== null) {
    try {
      params.delete("dropp_click_id");
      const query = params.toString();
      history.replaceState(history.state, "", `${location.pathname}${query ? `?${query}` : ""}${location.hash}`);
    } catch {
      // Sandboxed frames can refuse replaceState.
    }
  }
  /** Referrer, UTM tags and click id go on the first event of the session this page starts. */
  let landingPending = true;

  function storedClick(): string | null {
    const c = read<{ id: string; t: number }>(KEYS.click);
    if (c && validClickId(c.id) && Date.now() - c.t < CLICK_TTL_DAYS * 86_400_000) return c.id;
    const cookie = getCookie(COOKIES.click);
    return validClickId(cookie) ? cookie : null;
  }

  // ── Visitor and session ────────────────────────────────────────────────────────────────────────────
  function visitorId(): string {
    let id = read<string>(KEYS.visitor) ?? getCookie(COOKIES.visitor);
    if (!id || !/^[0-9a-f-]{36}$/.test(id)) id = uuid();
    write(KEYS.visitor, id);
    setCookie(COOKIES.visitor, id, VISITOR_COOKIE_DAYS, cookieDomain);
    return id;
  }

  type StoredSession = { id: string; last: number; click?: string };
  /** Before consent the session lives in memory only. */
  let memorySession: StoredSession | null = null;
  const loadSession = () => (consented ? read<StoredSession>(KEYS.session) : memorySession);
  const saveSession = (v: StoredSession) => (consented ? write(KEYS.session, v) : (memorySession = v));

  /** The current session, renewed after 30 minutes idle or when a new campaign landing starts one. */
  function session(touch: boolean): { id: string; isNew: boolean } {
    const now = Date.now();
    const s = loadSession();
    const newCampaign = landingPending && (landingClickId ? s?.click !== landingClickId : hasUtm);
    if (s && now - s.last < SESSION_TIMEOUT_MS && !newCampaign) {
      if (touch) saveSession({ ...s, last: now });
      return { id: s.id, isNew: false };
    }
    const fresh = { id: uuid(), last: now, ...(landingClickId ? { click: landingClickId } : {}) };
    saveSession(fresh);
    return { id: fresh.id, isNew: true };
  }

  // ── Queue ──────────────────────────────────────────────────────────────────────────────────────────
  const loadQueue = (): Queued[] => {
    const q = read<{ v: number; items: Queued[] }>(KEYS.queue);
    const items = q?.v === 1 && Array.isArray(q.items) ? q.items : [];
    return items.filter((x) => Date.now() - x.at < QUEUE_MAX_AGE_MS);
  };
  const saveQueue = (items: Queued[]) => write(KEYS.queue, { v: 1, items });

  function enqueue(item: WireItem) {
    if (signal?.aborted) return;
    const queued: Queued = { qid: uuid(), at: Date.now(), item };
    if (!consented) {
      waiting.push(queued);
      if (waiting.length > PENDING_CONSENT_MAX) waiting.shift();
      return;
    }
    const items = loadQueue();
    items.push(queued);
    // Over the cap, the oldest page views and engaged time go before funnel events and identifies.
    while (items.length > QUEUE_MAX_ITEMS) {
      const i = items.findIndex((x) => x.item.type === "engage" || (x.item.type === "event" && x.item.name === "page_view"));
      items.splice(i >= 0 ? i : 0, 1);
    }
    saveQueue(items);
    schedule(items.length >= FLUSH_NOW_AT ? 0 : FLUSH_DELAY_MS);
  }

  function schedule(delay: number) {
    if (timer) clearTimeout(timer);
    timer = setTimeout(() => {
      timer = null;
      void flush(false);
    }, Math.max(delay, backoffMs));
  }

  function batch(items: Queued[]): { taken: Queued[]; body: string } {
    const vid = visitorId();
    const taken: Queued[] = [];
    let body = "";
    for (const q of items.slice(0, BATCH_MAX_ITEMS)) {
      const next = JSON.stringify({ key: config.key, visitorId: vid, sdkVersion: SDK_VERSION, items: [...taken, q].map((x) => x.item) });
      if (next.length > BATCH_MAX_BYTES && taken.length) break;
      taken.push(q);
      body = next;
    }
    return { taken, body };
  }

  async function post(url: string, body: string, keepalive: boolean): Promise<Response | null> {
    try {
      return await fetch(url, {
        method: "POST",
        body,
        keepalive,
        credentials: "omit",
        // text/plain needs no CORS preflight.
        headers: { "content-type": "text/plain;charset=UTF-8" },
      });
    } catch {
      return null;
    }
  }

  function backoff(res: Response | null) {
    const retryAfter = Number(res?.headers.get("retry-after")) * 1000 || 0;
    backoffMs = Math.min(BACKOFF_MAX_MS, Math.max(retryAfter, backoffMs ? backoffMs * 2 : 2_000));
    const jittered = backoffMs * (0.8 + Math.random() * 0.4);
    log(`send failed (${res?.status ?? "network"}), retrying in ${Math.round(jittered / 1000)}s`);
    schedule(jittered);
  }

  async function sendOnce(keepalive: boolean): Promise<boolean> {
    const { taken, body } = batch(loadQueue());
    if (!taken.length) return false;
    let res = await post(endpoint, body, keepalive);
    if (fallback && FALL_BACK_ON.has(res?.status ?? 0)) res = await post(fallback, body, keepalive);

    const status = res?.status ?? 0;
    const sent = new Set(taken.map((x) => x.qid));
    // Re-read: another tab may have queued items since.
    const drop = () => saveQueue(loadQueue().filter((x) => !sent.has(x.qid)));
    if (res?.ok) {
      drop();
      backoffMs = 0;
      if (config.debug) {
        const json = (await res.json().catch(() => null)) as { accepted?: number; rejected?: Array<{ index: number; message: string }> } | null;
        log(`sent ${taken.length}: ${json?.accepted ?? "?"} stored`);
        for (const r of json?.rejected ?? []) warn(`item ${r.index} refused: ${r.message}`);
      }
      return true;
    }
    if (status === 401 || status === 403) {
      refused = true;
      const json = (await res?.json().catch(() => null)) as { error?: { code?: string; message?: string } } | null;
      console.error(`[Dropplink] ${json?.error?.message ?? "Refused"} (${json?.error?.code ?? status}). Check data-key and the app's web domains.`);
      return false;
    }
    if (status === 400 || status === 413) {
      // Malformed: a script bug. Keeping it would block everything behind it.
      drop();
      warn(`batch refused (${status}) and dropped`);
      return true;
    }
    backoff(res);
    return false;
  }

  /** One flush at a time; repeats while there's more and sends succeed. */
  function flush(keepalive: boolean): Promise<void> {
    if (!consented || refused) return Promise.resolve();
    if (inFlight) return inFlight;
    inFlight = (async () => {
      try {
        while (await sendOnce(keepalive)) {
          if (keepalive) break;
        }
      } finally {
        inFlight = null;
      }
    })();
    return inFlight;
  }

  // ── Page views and engaged time ────────────────────────────────────────────────────────────────────
  let lastPage = "";
  let currentPath = location.pathname;
  let visibleSince: number | null = document.visibilityState === "visible" ? Date.now() : null;
  let engagedMs = 0;

  function event(name: string, props?: EventProps) {
    const s = session(true);
    const item: WireItem = {
      type: "event",
      eventId: uuid(),
      sessionId: s.id,
      name,
      ts: nowSec(),
      path: location.pathname.slice(0, 512) || "/",
    };
    if (name === "page_view" && document.title) item.title = document.title.slice(0, 200);
    if (s.isNew || landingPending) {
      // The session's landing: where the visitor came from.
      if (s.isNew) item.referrer = document.referrer.slice(0, 1024);
      if (hasUtm) item.utm = utm;
      if (landingClickId) item.clickId = landingClickId;
      landingPending = false;
    }
    if (props) item.props = props;
    enqueue(item);
  }

  function pageView() {
    const page = location.pathname + location.search;
    if (page === lastPage) return;
    if (lastPage) endEngagement();
    lastPage = page;
    currentPath = location.pathname;
    event("page_view");
  }

  function endEngagement() {
    if (visibleSince !== null) {
      engagedMs += Date.now() - visibleSince;
      visibleSince = document.visibilityState === "visible" ? Date.now() : null;
    }
    if (engagedMs >= MIN_ENGAGE_MS) {
      enqueue({ type: "engage", eventId: uuid(), sessionId: session(true).id, ts: nowSec(), path: currentPath, ms: Math.round(engagedMs) });
    }
    engagedMs = 0;
  }

  const onHide = () => {
    endEngagement();
    visibleSince = null;
    // keepalive: the request survives the page closing. Its response may never arrive, so the items
    // stay queued and go again on the next page; the server drops the repeats.
    void flush(true);
  };
  document.addEventListener(
    "visibilitychange",
    () => {
      if (document.visibilityState === "hidden") onHide();
      else visibleSince = Date.now();
    },
    { signal },
  );
  window.addEventListener("pagehide", onHide, { signal });
  signal?.addEventListener("abort", () => {
    if (timer) clearTimeout(timer);
    refused = true;
  });

  if (config.spa !== false) {
    const onRoute = () => setTimeout(pageView, 0);
    for (const method of ["pushState", "replaceState"] as const) {
      const original = history[method];
      history[method] = function (this: History, ...args: Parameters<History["pushState"]>) {
        const result = original.apply(this, args);
        onRoute();
        return result;
      };
      signal?.addEventListener("abort", () => (history[method] = original));
    }
    window.addEventListener("popstate", onRoute, { signal });
  }

  // ── Public API ─────────────────────────────────────────────────────────────────────────────────────
  const api: Dropplink = {
    track(name, props) {
      if (!validEventName(name)) {
        warn(`event "${String(name)}" dropped: names are snake_case, e.g. add_to_cart`);
        return;
      }
      event(name, cleanProps(props, warn));
      log(`track ${name}`);
    },
    identify(userId) {
      const id = cleanUserId(userId);
      if (!id) {
        warn("identify dropped: pass your own opaque user id (1–128 chars), never an email or a phone number");
        return;
      }
      if (read<string>(KEYS.user) === id) return;
      write(KEYS.user, id);
      enqueue({ type: "identify", ts: nowSec(), userId: id });
      log(`identify ${id}`);
    },
    logout() {
      if (read<string>(KEYS.user) === null) return;
      remove(KEYS.user);
      enqueue({ type: "identify", ts: nowSec(), userId: null });
    },
    grant() {
      if (consented) return;
      consented = true;
      write(KEYS.consent, "granted");
      if (memorySession) write(KEYS.session, memorySession);
      visitorId();
      const held = waiting;
      waiting = [];
      saveQueue([...loadQueue(), ...held]);
      log(`consent granted, sending ${held.length} waiting`);
      schedule(0);
    },
    revoke() {
      consented = false;
      waiting = [];
      write(KEYS.consent, "denied");
      for (const k of [KEYS.visitor, KEYS.session, KEYS.click, KEYS.queue, KEYS.user]) remove(k);
      deleteCookie(COOKIES.visitor, cookieDomain);
      deleteCookie(COOKIES.click, cookieDomain);
      log("consent withdrawn, stored data cleared");
    },
    getVisitorId: () => (consented ? visitorId() : null),
    getClickId: () => storedClick(),
    flush: () => flush(false),
  };

  // Only once the page has a visitor id may it be shared with the brand's server.
  if (consented) visitorId();
  pageView();
  log(`started: ${endpoint}${consented ? "" : " (waiting for consent)"}`);
  return api;
}
