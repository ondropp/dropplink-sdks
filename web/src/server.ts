/** `@ondropp/dropplink-web/server`: for the brand's backend only. Holds the server key. */
export { DropplinkServer, readClickId, readVisitorId } from './server/DropplinkServer';
export { DropplinkError } from './server/DropplinkError';
export type { Deletion, EventProps, RejectCode, Revenue, ServerConfig, ServerEvent, TrackResult, Warning } from './server/types';
export { CLICK_PARAM, VISITOR_COOKIE } from './shared/clickId';
export { VERSION } from './version';
