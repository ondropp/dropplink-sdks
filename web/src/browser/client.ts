import { CLICK_PARAM, CLICK_WINDOW_DAYS, VISITOR_COOKIE, isClickId } from '../shared/clickId';
import type { EventProps } from '../shared/types';
import { cleanProps, cleanUserId, isEventName } from '../shared/validate';
import { VERSION } from '../version';
import { KEYS, clearCookie, load, readCookie, remove, save, uuid, writeCookie } from './storage';
import type { DropplinkWeb, Utm, WebConfig, WebEventItem, WebItem } from './types';

// The website collector (docs/sdk-spec.md section 12; wire contract: dropp-attribution docs/web-api.md).
// Behaviour only: the key is public, so nothing sent from here is trusted for money or credit.

const SDK_VERSION = `${VERSION}-web`;
export const DEFAULT_ENDPOINT = 'https://attribution.ondropp.app/v1/web/e';

const SESSION_IDLE_MS = 30 * 60_000;
const VISITOR_COOKIE_DAYS = 395;
/** Queued items kept in localStorage; page views and engaged time go first when it's full. */
const MAX_QUEUE = 200;
/** The server refuses events more than 2 days old; the queue gives up after one. */
const MAX_ITEM_AGE_MS = 24 * 3_600_000;
/** Held in memory while consent is pending. */
const MAX_WAITING = 50;
/** The server takes 50 items and 64 KB per batch. */
const MAX_BATCH_ITEMS = 50;
const MAX_BATCH_CHARS = 60_000;
const DEBOUNCE_MS = 2_000;
const SEND_AT_ONCE = 20;
const MAX_BACKOFF_MS = 5 * 60_000;
/** Less visible time than this on a page isn't worth an item. */
const MIN_ENGAGED_MS = 1_000;
/** Statuses our collector never sends, so a custom endpoint answering them is a proxy problem: try ours. */
const FALLBACK_STATUSES = new Set([0, 404, 405, 502]);
const UTM_KEYS = ['source', 'medium', 'campaign', 'content', 'term'] as const;
const WEB_KEY = /^pk_[a-f0-9]{16}$/;

const now = () => Math.floor(Date.now() / 1000);

interface QueuedItem {
  qid: string;
  at: number;
  item: WebItem;
}
interface Click {
  id: string;
  /** When the visitor landed with it (ms). */
  t: number;
}
interface Session {
  id: string;
  last: number;
  click?: string;
}

const NOOP: DropplinkWeb = {
  track() {},
  identify() {},
  logout() {},
  grant() {},
  revoke() {},
  getVisitorId: () => null,
  getClickId: () => null,
  flush: async () => {},
};

/**
 * Starts the collector: page views (including single-page navigations), engaged time per page, sessions, the
 * landing's UTM tags and Dropplink click, and a retrying offline queue. `signal` stops it (tests, hot reload).
 * Does nothing (and returns a no-op client) during server-side rendering, without a valid key, or in an
 * automated browser.
 */
export function createClient(config: WebConfig, { signal }: { signal?: AbortSignal } = {}): DropplinkWeb {
  const log = (m: string) => config.debug && console.log(`[Dropplink] ${m}`);
  const warn = (m: string) => config.debug && console.warn(`[Dropplink] ${m}`);

  if (typeof window === 'undefined' || typeof document === 'undefined') return NOOP;
  if (!WEB_KEY.test(config.key ?? '')) {
    console.error('[Dropplink] Missing or invalid web key (data-key="pk_…"); the script is off.');
    return NOOP;
  }
  if (navigator.webdriver) {
    log('automated browser, not tracking');
    return NOOP;
  }

  // Global Privacy Control: the visitor's browser says "don't sell or share my data" (CCPA and other US state
  // laws treat it as a valid opt-out). Honoured unless the brand turns it off: nothing is stored or sent, and
  // grant() can't override it, because a cookie banner's "accept" doesn't withdraw the browser's signal.
  const gpc =
    config.respectGlobalPrivacyControl !== false &&
    (navigator as Navigator & { globalPrivacyControl?: boolean }).globalPrivacyControl === true;

  const endpoint = config.endpoint ?? DEFAULT_ENDPOINT;
  const fallback = endpoint === DEFAULT_ENDPOINT ? null : DEFAULT_ENDPOINT;
  const cookieDomain = config.cookieDomain;
  let consented = !gpc && (config.consent !== 'required' || load(KEYS.consent) === 'granted');
  if (gpc) clearStored();
  let waiting: QueuedItem[] = [];
  let stopped = false;
  let flushing: Promise<void> | null = null;
  let timer: ReturnType<typeof setTimeout> | null = null;
  let backoff = 0;

  // ── The landing: UTM tags and the Dropplink click ──────────────────────────────────────────────────
  const params = new URLSearchParams(location.search);
  const clickParam = params.get(CLICK_PARAM);
  const utm: Utm = {};
  for (const k of UTM_KEYS) {
    const v = params.get(`utm_${k}`);
    if (v) utm[k] = v.slice(0, 128);
  }
  const hasUtm = Object.keys(utm).length > 0;
  const landingClick = isClickId(clickParam) ? clickParam : undefined;
  // First touch: keep the first click, as the server does. Before consent it stays in memory (nothing is
  // stored on the device until grant()) and is persisted by grant().
  let memoryClick: Click | null = null;
  if (landingClick && !gpc && !storedClick()) {
    const click = { id: landingClick, t: Date.now() };
    if (consented) persistClick(click);
    else memoryClick = click;
  }
  // A copied URL shouldn't pass the click on. UTM tags stay for the site's own analytics.
  if (clickParam !== null) {
    try {
      params.delete(CLICK_PARAM);
      const rest = params.toString();
      history.replaceState(history.state, '', `${location.pathname}${rest ? `?${rest}` : ''}${location.hash}`);
    } catch {
      // Sandboxed frames can refuse replaceState.
    }
  }
  /** The first event of this page load carries the landing's UTM tags and click. */
  let landing = true;

  function persistClick(click: Click): void {
    save(KEYS.click, click);
    const daysLeft = CLICK_WINDOW_DAYS - (Date.now() - click.t) / 86_400_000;
    if (daysLeft > 0) writeCookie(CLICK_PARAM, click.id, daysLeft, cookieDomain);
  }

  function storedClick(): string | null {
    if (gpc) return null;
    if (memoryClick && Date.now() - memoryClick.t < CLICK_WINDOW_DAYS * 86_400_000) return memoryClick.id;
    const saved = load<{ id: string; t: number }>(KEYS.click);
    if (saved && isClickId(saved.id) && Date.now() - saved.t < CLICK_WINDOW_DAYS * 86_400_000) return saved.id;
    const cookie = readCookie(CLICK_PARAM);
    return isClickId(cookie) ? cookie : null;
  }

  /** Everything this script keeps on the device, except the visitor's consent answer. */
  function clearStored(): void {
    for (const k of [KEYS.visitor, KEYS.session, KEYS.click, KEYS.queue, KEYS.user]) remove(k);
    clearCookie(VISITOR_COOKIE, cookieDomain);
    clearCookie(CLICK_PARAM, cookieDomain);
  }

  function visitorId(): string {
    let id = load<string>(KEYS.visitor) ?? readCookie(VISITOR_COOKIE);
    if (!id || !/^[0-9a-f-]{36}$/.test(id)) id = uuid();
    save(KEYS.visitor, id);
    writeCookie(VISITOR_COOKIE, id, VISITOR_COOKIE_DAYS, cookieDomain);
    return id;
  }

  // ── Sessions: 30 minutes idle, or a new campaign landing, starts a new one ──────────────────────────
  let memorySession: Session | null = null;
  const readSession = () => (consented ? load<Session>(KEYS.session) : memorySession);
  const writeSession = (s: Session) => (consented ? save(KEYS.session, s) : (memorySession = s));
  // The signed-in user, also kept in memory until consent.
  let memoryUser: string | null = null;
  const readUser = () => (consented ? load<string>(KEYS.user) : memoryUser);
  const writeUser = (id: string | null) => {
    if (!consented) memoryUser = id;
    else if (id === null) remove(KEYS.user);
    else save(KEYS.user, id);
  };

  function session(touch: boolean): { id: string; isNew: boolean } {
    const t = Date.now();
    const current = readSession();
    const newCampaign = landing && (landingClick ? current?.click !== landingClick : hasUtm);
    if (current && t - current.last < SESSION_IDLE_MS && !newCampaign) {
      if (touch) writeSession({ ...current, last: t });
      return { id: current.id, isNew: false };
    }
    const next: Session = { id: uuid(), last: t, ...(landingClick ? { click: landingClick } : {}) };
    writeSession(next);
    return { id: next.id, isNew: true };
  }

  // ── The queue: localStorage, flushed after a short pause, retried with backoff ───────────────────────
  const readQueue = (): QueuedItem[] => {
    const q = load<{ v: number; items: QueuedItem[] }>(KEYS.queue);
    return (q?.v === 1 && Array.isArray(q.items) ? q.items : []).filter((i) => Date.now() - i.at < MAX_ITEM_AGE_MS);
  };
  const writeQueue = (items: QueuedItem[]) => save(KEYS.queue, { v: 1, items });

  function enqueue(item: WebItem): void {
    // Under GPC nothing will ever be sent from this page, so nothing waits either.
    if (signal?.aborted || gpc) return;
    const entry: QueuedItem = { qid: uuid(), at: Date.now(), item };
    if (!consented) {
      waiting.push(entry);
      if (waiting.length > MAX_WAITING) waiting.shift();
      return;
    }
    const items = readQueue();
    items.push(entry);
    while (items.length > MAX_QUEUE) {
      const cheap = items.findIndex((q) => q.item.type === 'engage' || (q.item.type === 'event' && q.item.name === 'page_view'));
      items.splice(cheap >= 0 ? cheap : 0, 1);
    }
    writeQueue(items);
    schedule(items.length >= SEND_AT_ONCE ? 0 : DEBOUNCE_MS);
  }

  function schedule(ms: number): void {
    if (timer) clearTimeout(timer);
    timer = setTimeout(
      () => {
        timer = null;
        void flush(false);
      },
      Math.max(ms, backoff)
    );
  }

  function nextBatch(items: QueuedItem[]): { taken: QueuedItem[]; body: string } {
    const vid = visitorId();
    const taken: QueuedItem[] = [];
    let body = '';
    for (const q of items.slice(0, MAX_BATCH_ITEMS)) {
      const candidate = JSON.stringify({
        key: config.key,
        visitorId: vid,
        sdkVersion: SDK_VERSION,
        items: [...taken, q].map((x) => x.item),
      });
      if (candidate.length > MAX_BATCH_CHARS && taken.length) break;
      taken.push(q);
      body = candidate;
    }
    return { taken, body };
  }

  async function post(url: string, body: string, keepalive: boolean): Promise<Response | null> {
    try {
      // text/plain: a "simple" request, so the browser sends no CORS preflight. fetch + keepalive rather than
      // sendBeacon, which blockers target more.
      return await fetch(url, {
        method: 'POST',
        body,
        keepalive,
        credentials: 'omit',
        headers: { 'content-type': 'text/plain;charset=UTF-8' },
      });
    } catch {
      return null;
    }
  }

  function retryLater(res: Response | null): void {
    const retryAfter = Number(res?.headers.get('retry-after')) * 1000 || 0;
    backoff = Math.min(MAX_BACKOFF_MS, Math.max(retryAfter, backoff ? backoff * 2 : 2_000));
    const wait = backoff * (0.8 + Math.random() * 0.4);
    log(`send failed (${res?.status ?? 'network'}), retrying in ${Math.round(wait / 1000)}s`);
    schedule(wait);
  }

  /** One batch. Returns whether to keep going. */
  async function sendOnce(keepalive: boolean): Promise<boolean> {
    const { taken, body } = nextBatch(readQueue());
    if (!taken.length) return false;
    let res = await post(endpoint, body, keepalive);
    if (fallback && FALLBACK_STATUSES.has(res?.status ?? 0)) res = await post(fallback, body, keepalive);
    const status = res?.status ?? 0;
    const sent = new Set(taken.map((q) => q.qid));
    const drop = () => writeQueue(readQueue().filter((q) => !sent.has(q.qid)));

    if (res?.ok) {
      drop();
      backoff = 0;
      if (config.debug) {
        const r = (await res.json().catch(() => null)) as { accepted?: number; rejected?: { message: string; index: number }[] } | null;
        log(`sent ${taken.length}: ${r?.accepted ?? '?'} stored`);
        for (const x of r?.rejected ?? []) warn(`item ${x.index} refused: ${x.message}`);
      }
      return true;
    }
    if (status === 401 || status === 403) {
      // A wrong key or a site not in the app's web domains: retrying won't help until the page is fixed.
      stopped = true;
      const r = (await res?.json().catch(() => null)) as { error?: { code?: string; message?: string } } | null;
      console.error(
        `[Dropplink] ${r?.error?.message ?? 'Refused'} (${r?.error?.code ?? status}). Check data-key and the app's web domains.`
      );
      return false;
    }
    if (status === 400 || status === 413) {
      // Malformed: keeping it would block everything behind it.
      drop();
      warn(`batch refused (${status}) and dropped`);
      return true;
    }
    retryLater(res);
    return false;
  }

  /** `keepalive` (the page is going away): one batch, sent so it survives the unload. */
  function flush(keepalive: boolean): Promise<void> {
    if (!consented || stopped) return Promise.resolve();
    if (flushing) return flushing;
    flushing = (async () => {
      try {
        while ((await sendOnce(keepalive)) && !keepalive);
      } finally {
        flushing = null;
      }
    })();
    return flushing;
  }

  // ── Page views and engaged time ───────────────────────────────────────────────────────────────────────
  let lastUrl = '';
  let lastPath = location.pathname;
  let visibleSince: number | null = document.visibilityState === 'visible' ? Date.now() : null;
  let engagedMs = 0;

  function event(name: string, props?: EventProps): void {
    const s = session(true);
    const item: WebEventItem = {
      type: 'event',
      eventId: uuid(),
      sessionId: s.id,
      name,
      ts: now(),
      path: location.pathname.slice(0, 512) || '/',
    };
    if (name === 'page_view' && document.title) item.title = document.title.slice(0, 200);
    if (s.isNew || landing) {
      if (s.isNew) item.referrer = document.referrer.slice(0, 1024);
      if (hasUtm) item.utm = utm;
      if (landingClick) item.clickId = landingClick;
      landing = false;
    }
    if (props) item.props = props;
    enqueue(item);
  }

  function pageView(): void {
    const url = location.pathname + location.search;
    if (url === lastUrl) return;
    if (lastUrl) engage();
    lastUrl = url;
    lastPath = location.pathname;
    event('page_view');
  }

  function engage(): void {
    if (visibleSince !== null) {
      engagedMs += Date.now() - visibleSince;
      visibleSince = document.visibilityState === 'visible' ? Date.now() : null;
    }
    if (engagedMs >= MIN_ENGAGED_MS) {
      enqueue({ type: 'engage', eventId: uuid(), sessionId: session(true).id, ts: now(), path: lastPath, ms: Math.round(engagedMs) });
    }
    engagedMs = 0;
  }

  const leave = () => {
    engage();
    visibleSince = null;
    void flush(true);
  };
  document.addEventListener('visibilitychange', () => (document.visibilityState === 'hidden' ? leave() : (visibleSince = Date.now())), {
    signal,
  });
  window.addEventListener('pagehide', leave, { signal });
  signal?.addEventListener('abort', () => {
    if (timer) clearTimeout(timer);
    stopped = true;
  });

  if (config.spa !== false) {
    // After the router has updated the URL and title.
    const onNavigate = () => setTimeout(pageView, 0);
    for (const method of ['pushState', 'replaceState'] as const) {
      const original = history[method];
      history[method] = function (this: History, ...args: Parameters<History['pushState']>) {
        const result = original.apply(this, args);
        onNavigate();
        return result;
      };
      signal?.addEventListener('abort', () => (history[method] = original));
    }
    window.addEventListener('popstate', onNavigate, { signal });
  }

  const client: DropplinkWeb = {
    track(name, props) {
      if (!isEventName(name)) {
        warn(`event "${String(name)}" dropped: names are snake_case, e.g. add_to_cart`);
        return;
      }
      event(name, cleanProps(props, warn));
      log(`track ${name}`);
    },
    identify(userId) {
      const id = cleanUserId(userId);
      if (!id) {
        warn('identify dropped: pass your own opaque user id (1–128 chars), never an email or a phone number');
        return;
      }
      if (readUser() === id) return;
      writeUser(id);
      enqueue({ type: 'identify', ts: now(), userId: id });
      log(`identify ${id}`);
    },
    logout() {
      if (readUser() === null) return;
      writeUser(null);
      enqueue({ type: 'identify', ts: now(), userId: null });
    },
    grant() {
      if (gpc) {
        log('Global Privacy Control is on in this browser: grant() ignored, nothing is stored or sent');
        return;
      }
      if (consented) return;
      consented = true;
      save(KEYS.consent, 'granted');
      if (memorySession) save(KEYS.session, memorySession);
      if (memoryUser) save(KEYS.user, memoryUser);
      if (memoryClick) persistClick(memoryClick);
      memoryClick = null;
      visitorId();
      const held = waiting;
      waiting = [];
      writeQueue([...readQueue(), ...held]);
      log(`consent granted, sending ${held.length} waiting`);
      schedule(0);
    },
    revoke() {
      consented = false;
      waiting = [];
      memoryUser = null;
      memoryClick = null;
      // Under GPC nothing is written, not even the answer.
      if (!gpc) save(KEYS.consent, 'denied');
      clearStored();
      log('consent withdrawn, stored data cleared');
    },
    getVisitorId: () => (consented ? visitorId() : null),
    getClickId: () => storedClick(),
    flush: () => flush(false),
  };

  if (consented) visitorId();
  pageView();
  log(`started: ${endpoint}${gpc ? ' (Global Privacy Control: nothing stored or sent)' : consented ? '' : ' (waiting for consent)'}`);
  return client;
}
