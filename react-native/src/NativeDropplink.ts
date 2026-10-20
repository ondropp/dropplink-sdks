import { TurboModuleRegistry, type TurboModule } from 'react-native';

/**
 * The native module's interface. Implemented by `RNDropplinkModule` (Kotlin) and `RNDropplink`
 * (Swift) as classic native modules, which RN 0.76+ serves through the TurboModule interop layer.
 * See README "Architecture".
 */
export interface Spec extends TurboModule {
  /** `baseUrl: null` lets the native SDK apply its default. `platformWrapper` is set natively. */
  initializeSdk(config: {
    keyId: string;
    secret: string;
    debug: boolean;
    baseUrl: string | null;
  }): Promise<void>;
  handleDeepLink(url: string): Promise<void>;
  getAttribution(): Promise<Object | null>;
  getInstallId(): Promise<string | null>;
  /**
   * `true` installs the native deep-link listener (delivering any link the native SDK buffered),
   * `false` removes it so the native SDK buffers again.
   */
  setDeepLinkListenerEnabled(enabled: boolean): void;

  // Required by NativeEventEmitter.
  addListener(eventName: string): void;
  removeListeners(count: number): void;
}

export const MODULE_NAME = 'RNDropplink';
export const DEEP_LINK_EVENT = 'DropplinkDeepLink';

// `get` (not `getEnforcing`) so importing the package never throws, e.g. in Jest or on web.
// TurboModuleRegistry falls back to NativeModules and the interop layer by itself.
export default TurboModuleRegistry.get<Spec>(MODULE_NAME);
