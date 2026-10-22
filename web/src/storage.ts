// localStorage and cookies that never throw: private windows, blocked storage and full quotas all happen
// on real sites, and the script must keep the page working whatever the browser allows.

export const KEYS = {
  visitor: "dl_vid",
  session: "dl_sess",
  click: "dl_click",
  queue: "dl_q",
  user: "dl_uid",
  consent: "dl_consent",
} as const;

/** Cookies the brand's own server reads at checkout and sends back with the order (s2s). */
export const COOKIES = { visitor: "dropp_vid", click: "dropp_click_id" } as const;

export function read<T>(key: string): T | null {
  try {
    const raw = window.localStorage.getItem(key);
    return raw === null ? null : (JSON.parse(raw) as T);
  } catch {
    return null;
  }
}

export function write(key: string, value: unknown): void {
  try {
    window.localStorage.setItem(key, JSON.stringify(value));
  } catch {
    // Full or blocked: the script carries on in memory.
  }
}

export function remove(key: string): void {
  try {
    window.localStorage.removeItem(key);
  } catch {
    // Nothing to do.
  }
}

export function getCookie(name: string): string | null {
  try {
    const match = document.cookie.match(new RegExp(`(?:^|; )${name}=([^;]*)`));
    return match ? decodeURIComponent(match[1]!) : null;
  } catch {
    return null;
  }
}

export function setCookie(name: string, value: string, days: number, domain?: string): void {
  try {
    const parts = [
      `${name}=${encodeURIComponent(value)}`,
      `max-age=${Math.round(days * 86_400)}`,
      "path=/",
      "samesite=lax",
    ];
    if (location.protocol === "https:") parts.push("secure");
    if (domain) parts.push(`domain=${domain}`);
    document.cookie = parts.join("; ");
  } catch {
    // Cookies blocked.
  }
}

export const deleteCookie = (name: string, domain?: string) => setCookie(name, "", 0, domain);

export function uuid(): string {
  try {
    if (typeof crypto.randomUUID === "function") return crypto.randomUUID();
    const b = crypto.getRandomValues(new Uint8Array(16));
    b[6] = (b[6]! & 0x0f) | 0x40;
    b[8] = (b[8]! & 0x3f) | 0x80;
    const h = Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("");
    return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
  } catch {
    return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, (c) => {
      const r = (Math.random() * 16) | 0;
      return (c === "x" ? r : (r & 0x3) | 0x8).toString(16);
    });
  }
}
