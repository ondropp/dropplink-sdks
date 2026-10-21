import { Linking, NativeEventEmitter, Platform } from 'react-native';
import NativeDropplink, { DEEP_LINK_EVENT, type Spec } from './NativeDropplink';
import type {
  Attribution,
  DeepLink,
  DeepLinkListener,
  DropplinkConfig,
  EventProps,
  IdentifyTraits,
  Revenue,
  Subscription,
} from './types';

const LINKING_ERROR =
  `'@ondropp/dropplink-react-native' doesn't seem to be linked. Make sure:\n\n` +
  Platform.select({ ios: "- You have run 'pod install'\n", default: '' }) +
  '- You rebuilt the app after installing the package\n' +
  '- You are not using Expo Go (use a development build)\n';

function native(): Spec {
  if (!NativeDropplink) throw new Error(LINKING_ERROR);
  return NativeDropplink;
}

// Events and users must never throw into the host app (docs/sdk-spec.md section 2), not even when
// the module isn't linked: warn once in development and drop the call.
let warnedUnavailable = false;
function safely(call: (module: Spec) => void): void {
  try {
    call(native());
  } catch (e) {
    if (!warnedUnavailable && typeof __DEV__ !== 'undefined' && __DEV__) {
      warnedUnavailable = true;
      console.warn('Dropplink:', e instanceof Error ? e.message : e);
    }
  }
}

let emitter: NativeEventEmitter | undefined;
let listenerCount = 0;
let initialUrlHandled = false;

// Native maps cross the bridge with nulls for absent fields; normalise them to the TS types.

function toDeepLink(raw: Record<string, unknown>): DeepLink {
  return {
    path: String(raw.path ?? '/'),
    params: (raw.params as Record<string, string> | null) ?? {},
    url: (raw.url as string | null | undefined) ?? null,
    isDeferred: raw.isDeferred === true,
  };
}

function toAttribution(raw: Object | null): Attribution | null {
  if (raw == null) return null;
  const out: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(raw)) {
    if (value != null) out[key] = value;
  }
  return out as Attribution;
}

export const Dropplink = {
  /**
   * Starts the SDK. Call once, as early as possible (top of `index.js`). Later calls are ignored
   * by the native SDK, as are calls after a native `Dropplink.initialize` in MainApplication /
   * AppDelegate.
   */
  initialize(config: DropplinkConfig): Promise<void> {
    return native().initializeSdk({
      keyId: config.keyId,
      secret: config.secret,
      debug: config.debug ?? false,
      baseUrl: config.baseUrl ?? null,
    });
  },

  /**
   * Receives every deep link: the deferred one after a fresh install and App Link / Universal
   * Link opens. The native SDK holds a link that arrives before the first listener is added and
   * delivers it then.
   */
  addDeepLinkListener(listener: DeepLinkListener): Subscription {
    const module = native();
    emitter ??= new NativeEventEmitter(module);
    const sub = emitter.addListener(DEEP_LINK_EVENT, (raw) =>
      listener(toDeepLink(raw as Record<string, unknown>))
    );
    if (listenerCount++ === 0) module.setDeepLinkListenerEnabled(true);

    let removed = false;
    return {
      remove() {
        if (removed) return;
        removed = true;
        sub.remove();
        if (--listenerCount === 0) module.setDeepLinkListenerEnabled(false);
      },
    };
  },

  /**
   * Reports an App Link / Universal Link the OS opened the app with. The result arrives on the
   * deep-link listener. Non-http(s) URLs are ignored natively.
   */
  handleDeepLink(url: string): Promise<void> {
    return native().handleDeepLink(url);
  },

  /** The last attribution the server returned, or `null` before the first successful init. */
  async getAttribution(): Promise<Attribution | null> {
    return toAttribution(await native().getAttribution());
  },

  /** This install's id, for the dashboard's Install debugger. */
  async getInstallId(): Promise<string | null> {
    return (await native().getInstallId()) ?? null;
  },

  /**
   * Forwards React Native `Linking` URLs (the launch URL and every later `url` event) to
   * `handleDeepLink`, so App Links / Universal Links work with one call. Returns an unsubscribe
   * function. The launch URL is forwarded once per JS context, however often this is called.
   */
  listenToLinking(): () => void {
    const forward = (url: string | null | undefined) => {
      if (url) Dropplink.handleDeepLink(url).catch(() => {});
    };

    // The launch URL is a one-off for this JS context, not tied to the subscription: forward it
    // even if unsubscribed meanwhile (e.g. a StrictMode mount/unmount/mount).
    if (!initialUrlHandled) {
      initialUrlHandled = true;
      Linking.getInitialURL()
        .then(forward)
        .catch(() => {});
    }
    const sub = Linking.addEventListener('url', ({ url }) => forward(url));
    return () => sub.remove();
  },

  /**
   * Records an in-app event, e.g. `track('add_to_cart', { props: { sku: 'A1' } })`. The native SDK
   * validates it (invalid events are dropped with a debug log), queues it on disk and sends it in
   * the background. Never throws.
   */
  track(
    name: string,
    options?: { props?: EventProps; revenue?: Revenue }
  ): void {
    const revenue = options?.revenue;
    safely((m) =>
      m.track(
        name,
        options?.props ?? null,
        revenue
          ? {
              amount: revenue.amount,
              currency: revenue.currency,
              orderId: revenue.orderId ?? null,
            }
          : null
      )
    );
  },

  /**
   * Links the brand's own user id to this install. Call after sign-up / login; calling again with
   * the same id is a no-op natively, so calling it on every launch is fine. `email` and `phone`
   * are hashed on the device. Never throws.
   */
  identify(userId: string, traits?: IdentifyTraits): void {
    safely((m) =>
      m.identify(userId, traits?.email ?? null, traits?.phone ?? null)
    );
  },

  /** Unlinks the user; later events carry no user. Never throws. */
  logout(): void {
    safely((m) => m.logout());
  },

  /**
   * `false` clears the native event queue and stops events and identify until set back to `true`
   * (for consent). Persisted natively across launches. Attribution and deep links keep working.
   */
  setTrackingEnabled(enabled: boolean): void {
    safely((m) => m.setTrackingEnabled(enabled));
  },

  /**
   * The current setting (default `true`). Resolves `false` if the native module isn't linked or
   * fails, since nothing is tracked then. Never rejects.
   */
  async isTrackingEnabled(): Promise<boolean> {
    try {
      return (await native().isTrackingEnabled()) === true;
    } catch {
      return false;
    }
  },
};
