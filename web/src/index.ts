import { type Dropplink, type DropplinkConfig, createDropplink } from "./core.js";

export type { Dropplink, DropplinkConfig } from "./core.js";
export type { EventProps, PropValue } from "./validate.js";
export { VERSION } from "./core.js";

let instance: Dropplink | null = null;

/**
 * Starts the SDK (npm builds; a script tag starts itself). Call once, as early as possible, in the
 * browser. Later calls return the first instance.
 *
 * ```ts
 * import { init } from "@ondropp/dropplink-web";
 * const dropplink = init({ key: "pk_…", endpoint: "https://go.brand.com/_d/e" });
 * dropplink.track("add_to_cart", { sku: "RS-9" });
 * ```
 */
export function init(config: DropplinkConfig): Dropplink {
  instance ??= createDropplink(config);
  return instance;
}
