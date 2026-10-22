import type { EventProps } from '../shared/types';

export interface WebConfig {
  /** The app's public web key, `pk_…`, from Settings → Project details → Website. */
  key: string;
  /**
   * Where batches go. The script tag served from your link domain (`https://go.yourbrand.com/_d/s.js`) sets
   * `https://go.yourbrand.com/_d/e` by itself: first-party, so blocklists don't match it. Default: the API host.
   */
  endpoint?: string;
  /**
   * `'required'`: keep only the click id until you call `grant()` (for a cookie banner). Events tracked before
   * that wait in memory (up to 50) and are sent on `grant()`. Default `'granted'`.
   */
  consent?: 'granted' | 'required';
  /** Count `pushState` / `popstate` navigations as page views (single-page apps). Default `true`. */
  spa?: boolean;
  /** Share the visitor across subdomains, e.g. `.yourbrand.com`. Default: this host only. */
  cookieDomain?: string;
  /** Logs to the console. Never ship it on. */
  debug?: boolean;
}

/** What `init` returns, and `window.dropplink` is. No call throws or blocks the page. */
export interface DropplinkWeb {
  /**
   * A funnel or custom event, e.g. `view_item`, `add_to_cart`, `begin_checkout`, `sign_up`. `page_view` is
   * automatic. Behaviour only: revenue is sent by your server (`DropplinkServer.track`).
   */
  track(name: string, props?: EventProps): void;
  /** Your own user id after sign-in. Unverified: shown in the visitor's journey, never used for credit. */
  identify(userId: string): void;
  logout(): void;
  /** Consent given: starts storing and sending, including what waited. */
  grant(): void;
  /** Consent withdrawn: clears the visitor id, session, click, queue and user, and stops sending. */
  revoke(): void;
  /** Send with orders as `visitorId`. `null` until consent is granted. */
  getVisitorId(): string | null;
  /** The first Dropplink click this visitor landed with (last 30 days), or `null`. */
  getClickId(): string | null;
  /** Sends what's queued now. */
  flush(): Promise<void>;
}

// ── Wire items (dropp-attribution `src/contracts/web.ts`) ─────────────────────────────────────────────

export interface Utm {
  source?: string;
  medium?: string;
  campaign?: string;
  content?: string;
  term?: string;
}

export interface WebEventItem {
  type: 'event';
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

export interface WebEngageItem {
  type: 'engage';
  eventId: string;
  sessionId: string;
  ts: number;
  path: string;
  ms: number;
}

export interface WebIdentifyItem {
  type: 'identify';
  ts: number;
  userId: string | null;
}

export type WebItem = WebEventItem | WebEngageItem | WebIdentifyItem;
