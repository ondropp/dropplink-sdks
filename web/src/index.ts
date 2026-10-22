import { createClient } from './browser/client';
import type { DropplinkWeb, WebConfig } from './browser/types';

let client: DropplinkWeb | null = null;

/**
 * Starts the website collector once per page and returns it; later calls return the same client. Safe during
 * server-side rendering (a no-op client). With a bundler:
 *
 *   import { init } from '@ondropp/dropplink-web';
 *   const dropplink = init({ key: 'pk_…', endpoint: 'https://go.yourbrand.com/_d/e' });
 *   dropplink.track('add_to_cart', { sku: 'RS-9' });
 */
export function init(config: WebConfig): DropplinkWeb {
  if (typeof window === 'undefined') return createClient(config);
  client ??= createClient(config);
  return client;
}

export { createClient } from './browser/client';
export type { DropplinkWeb, WebConfig } from './browser/types';
export type { EventProps } from './shared/types';
export { CLICK_PARAM, VISITOR_COOKIE } from './shared/clickId';
export { VERSION } from './version';
