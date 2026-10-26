import type { EventProps } from '../shared/types';

export type { EventProps };

/** Mirrors `POST /v1/s2s/events` in dropp-attribution (contract/schemas/s2s-events-*.json). */

export interface ServerConfig {
  /** The app's server key, `sk_<id>.<secret>`, from Settings → SDK keys. Read it from the environment. */
  serverKey: string;
  /** Default `https://attribution.ondropp.app`. */
  baseUrl?: string;
  /** Per request. Default 10 000 ms. */
  timeoutMs?: number;
  /** Retries after a `429`, a `5xx`, a timeout or a network error. Default 3. */
  maxRetries?: number;
  /** For tests, or a runtime without a global `fetch`. */
  fetch?: typeof fetch;
}

export interface Revenue {
  /** At most 2 decimals; negative for a refund (with the refunded order's `orderId`). */
  amount: number;
  /** ISO 4217, e.g. `INR`. */
  currency: string;
  orderId?: string;
}

export interface ServerEvent {
  /** Your own stable id, like the order id, so a webhook that fires twice is stored once. */
  eventId: string;
  /** `snake_case`, e.g. `purchase`. */
  name: string;
  /** When it happened: a `Date`, or unix seconds. Default: now. */
  ts?: Date | number;
  /** The id your app passes to `identify`. */
  userId?: string | null;
  installId?: string | null;
  /** The `dropp_click_id` the order came with (`readClickId`), when the site doesn't run the web script. */
  clickId?: string | null;
  /**
   * The web script's visitor id (`readVisitorId`, or `dropplink.getVisitorId()` at checkout): credits that
   * visitor's first Dropplink click, and with `userId` shows the visitor as that user (verified).
   */
  visitorId?: string | null;
  props?: EventProps;
  revenue?: Revenue;
}

export type RejectCode = 'invalid_event' | 'too_old' | 'too_far_in_future' | 'unknown_install';

export type Warning =
  | { eventId: string; code: 'pii_in_props'; props: string[] }
  /** Stored, but the click credited nothing: not this app's, a bot's, more than 30 days old, or malformed. */
  | { eventId: string; code: 'unknown_click'; clickId: string }
  /** No website visitor with that id for this app (or it was malformed): stored organic, or waits for its user. */
  | { eventId: string; code: 'unknown_visitor'; visitorId: string };

export interface TrackResult {
  accepted: number;
  duplicates: number;
  /** Waiting for your app to identify the user. */
  pending: number;
  /** `index` is the event's position in what you passed to `track`. */
  rejected: { index: number; eventId: string | null; code: RejectCode; message: string }[];
  warnings: Warning[];
}

export interface Deletion {
  requestId: string;
  status: 'pending' | 'done' | 'failed';
  requestedAt: string;
  completedAt: string | null;
  counts: { identities: number; events: number; pendingEvents: number; installs: number; webVisitors: number } | null;
}
