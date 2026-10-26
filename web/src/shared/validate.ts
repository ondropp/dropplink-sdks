/**
 * The checks the server makes (`src/contracts/sdk.ts`, `src/lib/pii.ts` in dropp-attribution), run in the
 * browser so a bad event is dropped with a debug log instead of being refused.
 */
import type { EventProps } from './types';

const EVENT_NAME = /^[a-z][a-z0-9_]{0,63}$/;
const PROP_KEY = /^[A-Za-z0-9_]{1,40}$/;
const EMAIL = /[^\s@]+@[^\s@]+\.[^\s@]{2,}/;
const MAX_PROPS = 20;
const MAX_STRING = 256;

const looksLikeEmail = (v: string) => EMAIL.test(v);

function looksLikePhone(v: string): boolean {
  const digits = v.trim().replace(/[\s().-]/g, '');
  return /^\+\d{10,15}$/.test(digits) || /^(?:0|91)?[6-9]\d{9}$/.test(digits);
}

export const isEventName = (name: unknown): name is string => typeof name === 'string' && EVENT_NAME.test(name);

/** Keeps at most 20 valid props; drops personal data, bad keys and values that aren't scalars. */
export function cleanProps(props: unknown, warn: (message: string) => void): EventProps | undefined {
  if (!props || typeof props !== 'object') return undefined;
  const out: EventProps = {};
  let kept = 0;
  for (const [key, value] of Object.entries(props)) {
    if (kept >= MAX_PROPS) {
      warn(`prop "${key}" dropped: at most ${MAX_PROPS} props`);
      continue;
    }
    if (!PROP_KEY.test(key)) {
      warn(`prop "${key}" dropped: keys are 1–40 letters, digits or _`);
      continue;
    }
    let clean: string | number | boolean | null;
    if (value === null || typeof value === 'boolean') clean = value;
    else if (typeof value === 'number' && Number.isFinite(value)) clean = value;
    else if (typeof value === 'string') clean = value.slice(0, MAX_STRING);
    else {
      warn(`prop "${key}" dropped: values are strings, numbers, booleans or null`);
      continue;
    }
    if (typeof clean === 'string' && (looksLikeEmail(clean) || looksLikePhone(clean))) {
      warn(`prop "${key}" dropped: it looks like an email or a phone number`);
      continue;
    }
    out[key] = clean;
    kept++;
  }
  return kept ? out : undefined;
}

/** The brand's own opaque user id: 1–128 characters, never an email or a phone number. */
export function cleanUserId(userId: unknown): string | null {
  if (typeof userId !== 'string') return null;
  const id = userId.trim();
  return !id || id.length > 128 || looksLikeEmail(id) || looksLikePhone(id) ? null : id;
}
