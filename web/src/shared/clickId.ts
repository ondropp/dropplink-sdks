/**
 * The query parameter dropp-attribution adds to every website a link sends a visitor to, and the cookie the
 * script keeps it in. The brand's server can read the same cookie (`readClickId`).
 */
export const CLICK_PARAM = 'dropp_click_id';

/** The first-party cookie holding the visitor id; the brand's server sends it with orders as `visitorId`. */
export const VISITOR_COOKIE = 'dropp_vid';

/** The server's own rule (`src/contracts/s2s.ts`): `c_` and 8–32 lower-case hex characters. */
const CLICK_ID = /^c_[0-9a-f]{8,32}$/;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** A click is credited for events up to this long after it, so the click is kept as long. */
export const CLICK_WINDOW_DAYS = 30;

export type ClickId = `c_${string}`;

export function isClickId(value: unknown): value is ClickId {
  return typeof value === 'string' && CLICK_ID.test(value);
}

export function isUuid(value: unknown): value is string {
  return typeof value === 'string' && UUID.test(value);
}
