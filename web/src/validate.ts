// Local checks before an event is queued (docs/sdk-spec.md §11, the same rules as the native SDKs), so
// the server never has to reject what the script could have fixed or dropped.

export type PropValue = string | number | boolean | null;
export type EventProps = Record<string, PropValue>;

const EVENT_NAME = /^[a-z][a-z0-9_]{0,63}$/;
const PROP_KEY = /^[A-Za-z0-9_]{1,40}$/;
const MAX_PROPS = 20;
const MAX_STRING = 256;

// The server's pii.ts rules, ported exactly.
const EMAIL = /[^\s@]+@[^\s@]+\.[^\s@]{2,}/;
export const looksLikeEmail = (v: string) => EMAIL.test(v);
export function looksLikePhone(v: string): boolean {
  const compact = v.trim().replace(/[\s().-]/g, "");
  return /^\+\d{10,15}$/.test(compact) || /^(?:0|91)?[6-9]\d{9}$/.test(compact);
}

export const validEventName = (name: unknown): name is string => typeof name === "string" && EVENT_NAME.test(name);

/** Keeps the first 20 valid props; truncates long strings; drops other types and personal values. */
export function cleanProps(props: unknown, log: (m: string) => void): EventProps | undefined {
  if (!props || typeof props !== "object") return undefined;
  const out: EventProps = {};
  let n = 0;
  for (const [key, raw] of Object.entries(props as Record<string, unknown>)) {
    if (n >= MAX_PROPS) {
      log(`prop "${key}" dropped: at most ${MAX_PROPS} props`);
      continue;
    }
    if (!PROP_KEY.test(key)) {
      log(`prop "${key}" dropped: keys are 1–40 letters, digits or _`);
      continue;
    }
    let value: PropValue;
    if (raw === null || typeof raw === "boolean") value = raw;
    else if (typeof raw === "number" && Number.isFinite(raw)) value = raw;
    else if (typeof raw === "string") value = raw.slice(0, MAX_STRING);
    else {
      log(`prop "${key}" dropped: values are strings, numbers, booleans or null`);
      continue;
    }
    if (typeof value === "string" && (looksLikeEmail(value) || looksLikePhone(value))) {
      log(`prop "${key}" dropped: it looks like an email or a phone number`);
      continue;
    }
    out[key] = value;
    n++;
  }
  return n ? out : undefined;
}

/** A user id: trimmed, 1–128 chars, never an email or a phone number. */
export function cleanUserId(userId: unknown): string | null {
  if (typeof userId !== "string") return null;
  const id = userId.trim();
  if (!id || id.length > 128 || looksLikeEmail(id) || looksLikePhone(id)) return null;
  return id;
}

/** Click ids the server issues: `c_` and hex. */
export const validClickId = (v: unknown): v is string => typeof v === "string" && /^c_[0-9a-f]{8,32}$/.test(v);
