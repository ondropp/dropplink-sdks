import { CLICK_PARAM, VISITOR_COOKIE, isClickId, isUuid } from '../shared/clickId';
import { VERSION } from '../version';
import { DropplinkError } from './DropplinkError';
import type { Deletion, ServerConfig, ServerEvent, TrackResult } from './types';

const DEFAULT_BASE_URL = 'https://attribution.ondropp.app';
const SERVER_KEY = /^sk_[a-f0-9]{16}\.\S+$/;
/** The server's limits: 100 events and 64 KB per request. */
const MAX_BATCH = 100;
const MAX_BATCH_BYTES = 60_000;
const MAX_RETRY_WAIT_MS = 60_000;

type WireEvent = Omit<ServerEvent, 'ts'> & { ts: number };

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
const jitter = (ms: number) => ms * (0.8 + Math.random() * 0.4);

/**
 * The server half of Dropplink for websites (docs/sdk-spec.md section 12): sends orders, refunds and other
 * events from the brand's backend with the app's server key, and deletes users' data. Node 18+, Bun, Deno and
 * edge runtimes (anything with `fetch`). Never import it into code that runs in a browser.
 */
export class DropplinkServer {
  private readonly token: string;
  private readonly baseUrl: string;
  private readonly timeoutMs: number;
  private readonly maxRetries: number;
  private readonly fetchImpl: typeof fetch;

  constructor(config: ServerConfig) {
    if (typeof window !== 'undefined' && typeof document !== 'undefined') {
      throw new Error('Dropplink: the server key must never reach a browser. Use DropplinkServer on your backend only.');
    }
    const token = config?.serverKey?.trim() ?? '';
    if (!SERVER_KEY.test(token)) {
      throw new Error('Dropplink: serverKey must be the full server key token, sk_<id>.<secret>, from Settings → SDK keys.');
    }
    const fetchImpl = config.fetch ?? globalThis.fetch;
    if (typeof fetchImpl !== 'function')
      throw new Error('Dropplink: no fetch in this runtime. Use Node 18 or later, or pass config.fetch.');
    this.token = token;
    this.baseUrl = (config.baseUrl ?? DEFAULT_BASE_URL).replace(/\/+$/, '');
    this.timeoutMs = config.timeoutMs ?? 10_000;
    this.maxRetries = Math.max(0, config.maxRetries ?? 3);
    this.fetchImpl = fetchImpl;
  }

  /**
   * Sends events, in batches of up to 100. Each is stored, a duplicate, pending (waiting for your app to
   * identify the user) or rejected, as the result says. Throws `DropplinkError` when a request fails after
   * its retries; sending the same events again is safe.
   */
  async track(events: ServerEvent | ServerEvent[]): Promise<TrackResult> {
    const list = Array.isArray(events) ? events : [events];
    const result: TrackResult = { accepted: 0, duplicates: 0, pending: 0, rejected: [], warnings: [] };
    if (list.length === 0) return result;

    const wire = list.map((e) => this.toWire(e, result));
    for (const { start, items } of batches(wire)) {
      const body = await this.request<TrackResult>('POST', '/v1/s2s/events', { events: items });
      result.accepted += body.accepted;
      result.duplicates += body.duplicates;
      result.pending += body.pending;
      result.rejected.push(...body.rejected.map((r) => ({ ...r, index: r.index + start })));
      result.warnings.push(...body.warnings);
    }
    return result;
  }

  /** Deletes a user's data (account deletion, DPDP and GDPR requests). Poll `getDeletion` until it's `done`. */
  deleteUser(userId: string): Promise<Deletion> {
    return this.request('DELETE', `/v1/s2s/users/${encodeURIComponent(userId)}`);
  }

  getDeletion(requestId: string): Promise<Deletion> {
    return this.request('GET', `/v1/s2s/deletions/${encodeURIComponent(requestId)}`);
  }

  /** Normalizes `ts` and drops a malformed click id, which would otherwise get the whole event rejected. */
  private toWire(e: ServerEvent, result: TrackResult): WireEvent {
    const ts = e.ts instanceof Date ? Math.floor(e.ts.getTime() / 1000) : (e.ts ?? Math.floor(Date.now() / 1000));
    const { clickId, visitorId, userId, installId, ...rest } = e;
    const wire: WireEvent = { ...rest, ts };
    if (userId) wire.userId = userId;
    if (installId) wire.installId = installId;
    if (isClickId(clickId)) wire.clickId = clickId;
    else if (clickId) result.warnings.push({ eventId: e.eventId, code: 'unknown_click', clickId });
    if (isUuid(visitorId)) wire.visitorId = visitorId.toLowerCase();
    else if (visitorId) result.warnings.push({ eventId: e.eventId, code: 'unknown_visitor', visitorId });
    return wire;
  }

  private async request<T>(method: string, path: string, json?: unknown): Promise<T> {
    const body = json === undefined ? undefined : JSON.stringify(json);
    for (let attempt = 0; ; attempt++) {
      let error: DropplinkError;
      let retryAfterMs = 0;
      try {
        const res = await this.fetchImpl(`${this.baseUrl}${path}`, {
          method,
          body,
          headers: {
            'Authorization': `Bearer ${this.token}`,
            'User-Agent': `dropplink-web/${VERSION}`,
            ...(body !== undefined && { 'Content-Type': 'application/json' }),
          },
          signal: AbortSignal.timeout(this.timeoutMs),
        });
        if (res.ok) return (await res.json()) as T;
        error = await errorFrom(res);
        retryAfterMs = Number(res.headers.get('retry-after') ?? 0) * 1000 || 0;
      } catch (e) {
        if (e instanceof DropplinkError) throw e;
        const timedOut = e instanceof Error && (e.name === 'TimeoutError' || e.name === 'AbortError');
        error = new DropplinkError(
          null,
          timedOut ? 'timeout' : 'network_error',
          `Dropplink: ${timedOut ? 'request timed out' : 'network error'}`
        );
      }
      if (!error.retryable || attempt >= this.maxRetries) throw error;
      // 1 s, 2 s, 4 s … ± 20%; a longer Retry-After wins.
      await sleep(Math.min(MAX_RETRY_WAIT_MS, Math.max(jitter(1000 * 2 ** attempt), retryAfterMs)));
    }
  }
}

async function errorFrom(res: Response): Promise<DropplinkError> {
  try {
    const body = (await res.json()) as { error?: { code?: string; message?: string; details?: { path: string; message: string }[] } };
    if (body?.error?.code)
      return new DropplinkError(res.status, body.error.code, body.error.message ?? body.error.code, body.error.details);
  } catch {
    // Not JSON (a proxy's error page).
  }
  return new DropplinkError(res.status, `http_${res.status}`, `Dropplink: HTTP ${res.status}`);
}

/** Splits events into requests the server accepts: at most 100 and ~60 KB each. */
function batches(events: WireEvent[]): { start: number; items: WireEvent[] }[] {
  const out: { start: number; items: WireEvent[] }[] = [];
  let current: WireEvent[] = [];
  let start = 0;
  let bytes = 0;
  events.forEach((e, i) => {
    const size = JSON.stringify(e).length + 1;
    if (current.length && (current.length === MAX_BATCH || bytes + size > MAX_BATCH_BYTES)) {
      out.push({ start, items: current });
      current = [];
      start = i;
      bytes = 0;
    }
    current.push(e);
    bytes += size;
  });
  if (current.length) out.push({ start, items: current });
  return out;
}

/** A cookie's value from a request's `Cookie` header, or `null`. */
function cookieValue(cookieHeader: string | null | undefined, name: string): string | null {
  if (!cookieHeader) return null;
  for (const part of cookieHeader.split(';')) {
    const eq = part.indexOf('=');
    if (eq === -1 || part.slice(0, eq).trim() !== name) continue;
    try {
      return decodeURIComponent(part.slice(eq + 1).trim());
    } catch {
      return null;
    }
  }
  return null;
}

/**
 * The web script's visitor id from a request's `Cookie` header (the `dropp_vid` cookie). Read it when the order
 * is created, store it on the order, and send it as `visitorId` when the order is paid.
 */
export function readVisitorId(cookieHeader: string | null | undefined): string | null {
  const value = cookieValue(cookieHeader, VISITOR_COOKIE);
  return isUuid(value) ? value.toLowerCase() : null;
}

/**
 * The visitor's first Dropplink click from a request's `Cookie` header (`dropp_click_id`), for sites that don't
 * run the web script's visitor id, or as a fallback beside it.
 */
export function readClickId(cookieHeader: string | null | undefined): string | null {
  const value = cookieValue(cookieHeader, CLICK_PARAM);
  return isClickId(value) ? value : null;
}
