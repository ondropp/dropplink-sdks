/**
 * Where the script keeps things (docs/sdk-spec.md section 12). localStorage holds the state; two first-party
 * cookies mirror the ids the brand's server needs (`dropp_vid`, `dropp_click_id`). Every access is guarded:
 * storage throws in some private modes and sandboxed iframes, and then the script simply keeps less.
 */
export const KEYS = {
  visitor: 'dl_vid',
  session: 'dl_sess',
  click: 'dl_click',
  queue: 'dl_q',
  user: 'dl_uid',
  consent: 'dl_consent',
} as const;

/** `window.` explicitly: Node 22+ has its own global `localStorage`, which a bare name would reach in SSR. */
function local(): Storage | null {
  try {
    return typeof window === 'undefined' ? null : window.localStorage;
  } catch {
    return null;
  }
}

export function load<T>(key: string): T | null {
  try {
    const raw = local()?.getItem(key) ?? null;
    return raw === null ? null : (JSON.parse(raw) as T);
  } catch {
    return null;
  }
}

export function save(key: string, value: unknown): void {
  try {
    local()?.setItem(key, JSON.stringify(value));
  } catch {
    // Full or blocked: nothing depends on it surviving.
  }
}

export function remove(key: string): void {
  try {
    local()?.removeItem(key);
  } catch {
    // Blocked.
  }
}

export function readCookie(name: string): string | null {
  try {
    const match = document.cookie.match(new RegExp(`(?:^|; )${name}=([^;]*)`));
    return match ? decodeURIComponent(match[1]!) : null;
  } catch {
    return null;
  }
}

export function writeCookie(name: string, value: string, days: number, domain?: string): void {
  try {
    const parts = [`${name}=${encodeURIComponent(value)}`, `max-age=${Math.round(days * 86_400)}`, 'path=/', 'samesite=lax'];
    if (location.protocol === 'https:') parts.push('secure');
    if (domain) parts.push(`domain=${domain}`);
    document.cookie = parts.join('; ');
  } catch {
    // Cookies blocked.
  }
}

export const clearCookie = (name: string, domain?: string) => writeCookie(name, '', 0, domain);

/** A random UUID v4, from `crypto.randomUUID` where it exists (it needs a secure context). */
export function uuid(): string {
  try {
    if (typeof crypto.randomUUID === 'function') return crypto.randomUUID();
    const b = crypto.getRandomValues(new Uint8Array(16));
    b[6] = (b[6]! & 0x0f) | 0x40;
    b[8] = (b[8]! & 0x3f) | 0x80;
    const h = Array.from(b, (x) => x.toString(16).padStart(2, '0')).join('');
    return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
  } catch {
    return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
      const r = (Math.random() * 16) | 0;
      return (c === 'x' ? r : (r & 3) | 8).toString(16);
    });
  }
}
