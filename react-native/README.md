# Dropplink for React Native

`@ondropp/dropplink-react-native` attributes installs to the Dropplink link, channel and creator that
brought them, delivers deep links (the deferred one after a fresh install, and App Link / Universal
Link opens), and records in-app events and the signed-in user.

It is a thin bridge over the native SDKs
([`app.ondropp:dropplink-android`](../android) and the [`Dropplink`](../ios) pod). Install ids, the Play
Install Referrer, request signing, storage, retries and pending-link buffering all happen natively; the JS
only forwards calls and converts results. Behaviour is defined in [docs/sdk-spec.md](../docs/sdk-spec.md).

- [Requirements](#requirements)
- [Install](#install)
- [Keys](#keys)
- [Initialize](#initialize)
- [Deep links](#deep-links)
- [App Links (Android)](#app-links-android)
- [Universal Links (iOS)](#universal-links-ios)
- [Events, revenue and users](#events-revenue-and-users)
- [API](#api)
- [Test your integration](#test-your-integration)
- [Troubleshooting](#troubleshooting)
- [Architecture](#architecture)
- [Development](#development)

## Requirements

- React Native 0.76 or newer, New or old Architecture.
- Android 7.0 (API 24)+, iOS: React Native's minimum.
- Expo: works in a [development build](https://docs.expo.dev/develop/development-builds/introduction/)
  (`npx expo prebuild`), not in Expo Go.

## Install

```sh
npm install @ondropp/dropplink-react-native
cd ios && pod install
```

Autolinking registers the native module on both platforms. Rebuild the app (`npx react-native run-android`
/ `run-ios`); a Metro reload alone doesn't pick up native code.

## Keys

Each app has two SDK keys in the Dropplink dashboard (**SDK setup**): one for Android and one for iOS. A key
is a key id (`ak_…`) and a secret.

**Never hard-code the secret in JS that is committed to git.** Load it from build configuration instead,
for example with [`react-native-config`](https://github.com/lugg/react-native-config) and a git-ignored
`.env`:

```sh
# .env (in .gitignore)
DROPPLINK_ANDROID_KEY_ID=ak_...
DROPPLINK_ANDROID_SECRET=...
DROPPLINK_IOS_KEY_ID=ak_...
DROPPLINK_IOS_SECRET=...
```

In CI, write the `.env` from secrets before building. Any other build-time mechanism (Gradle
`BuildConfig` fields, xcconfig, `babel-plugin-transform-inline-environment-variables`) works too; the
SDK only needs the two strings at `initialize`.

## Initialize

Call `initialize` once, as early as possible: at the top of `index.js`, before `AppRegistry.registerComponent`,
so the install is reported even if the user leaves the first screen quickly.

```js
// index.js
import { AppRegistry, Platform } from 'react-native';
import Config from 'react-native-config';
import { Dropplink } from '@ondropp/dropplink-react-native';
import App from './App';

Dropplink.initialize({
  keyId: Platform.select({ ios: Config.DROPPLINK_IOS_KEY_ID, default: Config.DROPPLINK_ANDROID_KEY_ID }),
  secret: Platform.select({ ios: Config.DROPPLINK_IOS_SECRET, default: Config.DROPPLINK_ANDROID_SECRET }),
  debug: __DEV__, // native logs, tag "Dropplink". Never ship true.
}).catch((e) => console.warn('Dropplink.initialize failed', e));

AppRegistry.registerComponent('MyApp', () => App);
```

`initialize` returns immediately; `/v1/init` is sent in the background by the native SDK. Later calls
are ignored. You can also initialize natively (`Dropplink.initialize(...)` in `MainApplication.onCreate`
/ `AppDelegate`) if you want it to run before the JS bundle loads. The JS `initialize` is then a no-op,
but pass `platformWrapper = "rn"` in the native config so the dashboard shows the right SDK.

`baseUrl` defaults to `https://attribution.ondropp.app`. Override it only for local testing (for example
`http://10.0.2.2:4100` from the Android emulator).

## Deep links

One listener receives both kinds of link:

| Link | `isDeferred` | `url` |
| --- | --- | --- |
| Fresh install from a Dropplink link (delivered after the first `/v1/init`) | `true` | `null` |
| App already installed, link tapped (App Link / Universal Link) | `false` | the opened URL |

```tsx
import { useEffect } from 'react';
import { Dropplink, useDropplinkDeepLink } from '@ondropp/dropplink-react-native';

export default function App() {
  // Every Dropplink deep link while App is mounted.
  useDropplinkDeepLink((link) => navigation.navigate(routeFor(link.path), link.params));

  // Forwards the launch URL and later Linking 'url' events to Dropplink.handleDeepLink.
  useEffect(() => Dropplink.listenToLinking(), []);
  // ...
}
```

Without the hook:

```ts
const sub = Dropplink.addDeepLinkListener((link) => { /* ... */ });
sub.remove();
```

If a link arrives before any JS listener is added (the deferred link usually does, because `/v1/init`
can finish before your navigator mounts), the native SDK holds the latest one in memory and delivers it
when the first listener is added. Add your listener where you can navigate, not earlier.

`listenToLinking()` wires React Native's `Linking` (`getInitialURL()` and `'url'` events) into
`handleDeepLink`. It returns an unsubscribe function. You can forward every URL: non-`http(s)` URLs and
URLs that aren't Dropplink links for your app are ignored natively (the listener isn't called). If you
already handle `Linking` yourself, call `Dropplink.handleDeepLink(url)` from there instead.

## App Links (Android)

1. Register your link domain (e.g. `go.brand.com`) for the app in the Dropplink dashboard. Dropplink serves
   `/.well-known/assetlinks.json` for it; add your release (and Play App Signing) SHA-256 fingerprints there.
2. Add a verified intent filter to the main activity in `android/app/src/main/AndroidManifest.xml`:

   ```xml
   <activity android:name=".MainActivity" android:launchMode="singleTask" ...>
     <intent-filter android:autoVerify="true">
       <action android:name="android.intent.action.VIEW" />
       <category android:name="android.intent.category.DEFAULT" />
       <category android:name="android.intent.category.BROWSABLE" />
       <data android:scheme="https" android:host="go.brand.com" />
     </intent-filter>
   </activity>
   ```

React Native's `Linking` already reads the intent's URL (launch and `onNewIntent`), so
`listenToLinking()` is all the JS needs. Check verification with
`adb shell pm get-app-links <your.package>`.

## Universal Links (iOS)

1. Register your link domain for the app in the Dropplink dashboard. Dropplink serves
   `apple-app-site-association` for it.
2. Xcode → target → **Signing & Capabilities → + Associated Domains** → `applinks:go.brand.com`.
3. Let React Native's `Linking` see Universal Links. In `AppDelegate`, forward user activities to
   `RCTLinkingManager` (the React Native template may already include this):

   ```swift
   // AppDelegate.swift
   import React

   func application(_ application: UIApplication, continue userActivity: NSUserActivity,
                    restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
     RCTLinkingManager.application(application, continue: userActivity, restorationHandler: restorationHandler)
   }

   func application(_ app: UIApplication, open url: URL,
                    options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
     RCTLinkingManager.application(app, open: url, options: options)
   }
   ```

   ```objc
   // AppDelegate.mm
   #import <React/RCTLinkingManager.h>

   - (BOOL)application:(UIApplication *)application continueUserActivity:(NSUserActivity *)userActivity
     restorationHandler:(void (^)(NSArray<id<UIUserActivityRestoring>> *))restorationHandler {
     return [RCTLinkingManager application:application continueUserActivity:userActivity
                        restorationHandler:restorationHandler];
   }
   ```

Then `listenToLinking()` forwards them. Tap links from Notes or Messages to test; typing one into Safari's
address bar doesn't open Universal Links.

## Events, revenue and users

```ts
// Funnel events. Names are snake_case; up to 20 props of string, number, boolean or null.
Dropplink.track('add_to_cart', { props: { sku: 'A1', qty: 2 } });
Dropplink.track('purchase', { revenue: { amount: 499, currency: 'INR', orderId: 'ord_123' } });

// After sign-up / login. Calling it again with the same id is a no-op, so every launch is fine.
// Pass an opaque id, not an email. email / phone are optional and hashed on the device.
Dropplink.identify(user.id, { email: user.email, phone: user.phone });

// On logout. Later events carry no user.
Dropplink.logout();

// Consent: false clears queued events and stops events and identify, persisted across launches.
// Install attribution and deep links keep working.
Dropplink.setTrackingEnabled(userConsented);
const enabled = await Dropplink.isTrackingEnabled();
```

These calls return immediately and never throw. The native SDK checks each event (invalid ones are dropped
with a debug log), keeps a queue on disk and sends it in the background, after `/v1/init` and with
retries.

**Revenue:** revenue sent with `track` is shown in the dashboard as **app-reported**. Purchases that pay
creators must come from your server: send them to `/v1/s2s/events` from your backend when the order is
confirmed, and use `track` in the app for the funnel (views, add to cart, checkout started).

## API

```ts
import { Dropplink, useDropplinkDeepLink } from '@ondropp/dropplink-react-native';

Dropplink.initialize(config: DropplinkConfig): Promise<void>
Dropplink.addDeepLinkListener(listener: (link: DeepLink) => void): { remove(): void }
Dropplink.handleDeepLink(url: string): Promise<void>
Dropplink.getAttribution(): Promise<Attribution | null>   // null before the first successful init
Dropplink.getInstallId(): Promise<string | null>          // null before initialize
Dropplink.listenToLinking(): () => void                   // returns unsubscribe
Dropplink.track(name: string, options?: { props?: EventProps; revenue?: Revenue }): void
Dropplink.identify(userId: string, traits?: IdentifyTraits): void
Dropplink.logout(): void
Dropplink.setTrackingEnabled(enabled: boolean): void
Dropplink.isTrackingEnabled(): Promise<boolean>           // false if the module isn't linked
useDropplinkDeepLink(handler: (link: DeepLink) => void): void

type DropplinkConfig = { keyId: string; secret: string; debug?: boolean; baseUrl?: string };
type DeepLink = { path: string; params: Record<string, string>; url: string | null; isDeferred: boolean };
type Attribution = {
  type: 'attributed' | 'organic';
  method: 'install_referrer' | 'fingerprint' | 'none';
  clickId?: string; linkId?: string; campaignId?: string; creatorId?: string;
  source?: string; confidence?: number; attributedAt?: string;
};
type EventProps = Record<string, string | number | boolean | null>;
type Revenue = { amount: number; currency: string; orderId?: string };
type IdentifyTraits = { email?: string; phone?: string };
```

Promises resolve once the native call has been handed off; they don't wait for the network. The event and
user calls never throw (if the module isn't linked they do nothing and warn once in development). The other
promises reject
only if the native module isn't linked, or (`initialize`, Android) on invalid config in a debuggable
build of the host app, so the mistake shows up during development; release builds log it and disable
the SDK. Network and server errors never reach JS; they are logged natively when `debug` is on.
`getAttribution()` is cached on disk natively, so later launches have it immediately.

## Test your integration

1. Run with `debug: true`. Logcat (`adb logcat -s Dropplink`) or the Xcode console shows:

   ```
   Dropplink: install id 6f1c2a9e-… (paste into Dropplink → Install debugger)
   Dropplink: init 200 attributed via install_referrer, link 6711a0…, deep link /product/123
   ```

   Or show `await Dropplink.getInstallId()` on a debug screen.
2. Paste the install id into **Dropplink dashboard → Install debugger** to see the device's inits, its
   attribution and the click it matched.
3. Deferred deep link: uninstall, tap a Dropplink link, install and launch. Android attributes by Play
   Install Referrer (install through a Play internal test track to get a real referrer); iOS by
   fingerprint (same network). The listener receives the link with `isDeferred: true`.
4. App Link / Universal Link: with the app installed, tap a link. The listener receives it with
   `isDeferred: false`.

The [example](./example) app shows the install id, attribution and last deep link on one screen.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `'@ondropp/dropplink-react-native' doesn't seem to be linked` | Native code isn't in the binary. | `pod install`, rebuild the app; use a development build, not Expo Go. |
| `Invalid DropplinkConfig … Dropplink is disabled` (Android) / `invalid config, SDK disabled` (iOS) | Empty `keyId` / `secret`, or `keyId` doesn't start with `ak_`. Usually the `.env` value didn't reach the build. | Log `Config.DROPPLINK_…` presence (not the value); rebuild after editing `.env`. |
| `401 invalid_key` | Key unknown or revoked, or the app was deleted. | Copy the key again from the dashboard. |
| `400 platform_mismatch` | Android key in the iOS app or vice versa. | Pick the key per platform with `Platform.select`. |
| `401 bad_signature` | Wrong secret for the key id. | Copy the secret again; check for trailing spaces. |
| `401 stale_timestamp` | Device clock is off by more than 5 minutes. Retried. | Set the device to automatic time. |
| `network error` / `5xx` / `429` | Retried 3 times (1 s, 2 s, 4 s), then next launch. | Check connectivity and `baseUrl`. |
| Deep link listener never called | No listener added, or the URL never reached `handleDeepLink`. | Add the listener / `useDropplinkDeepLink`; call `listenToLinking()`; check App Links verification / Associated Domains and the iOS `RCTLinkingManager` hooks. |
| `not a Dropplink link` (debug log) | `handleDeepLink` got another URL. | Expected; ignore. |
| `no deep link path` / `no path for this link` (debug log) | The link has no deep link path set. | Set one on the link in the dashboard. |
| Listener fires twice | Two listeners added (e.g. hook in two mounted components). | Keep one listener near your navigator. |

## Architecture

The module is a **classic native module** (`ReactContextBaseJavaModule` on Android, `RCTEventEmitter` +
`RCT_EXTERN_MODULE` on iOS) looked up through `TurboModuleRegistry.get('RNDropplink')`, with a typed
`Spec` in [`src/NativeDropplink.ts`](./src/NativeDropplink.ts).

Why not a codegen TurboModule: React Native 0.76+ enables the New Architecture by default and serves
classic modules through its interop layer, so this one module works on both architectures with no
codegen, no generated C++ and no `#ifdef RCT_NEW_ARCH_ENABLED` branches. Every call is a cheap,
asynchronous hand-off to the native SDK, so a TurboModule's synchronous JSI calls would buy nothing. If the
interop layer is ever removed, adding `codegenConfig` to `package.json` and making the native classes
extend the generated specs is a contained change; the JS API and `Spec` stay the same.

Deep links are emitted as the `DropplinkDeepLink` event (`RCTDeviceEventEmitter` on Android,
`sendEvent` on iOS). The JS adds the native SDK listener when its first JS listener is added and removes it
when the last one goes, so the native SDK keeps buffering links while nobody in JS is listening. On a JS
reload the native listener is cleared too.

The native config is always created with `platformWrapper = "rn"`, so the server sees `sdkVersion`
`0.2.0-rn`.

## Development

```sh
npm ci
npm run typecheck
npm run lint
npm test            # Jest, native module mocked
npm run prepare     # react-native-builder-bob → lib/
```

Native code is compiled by the host app's build. To try it end to end, see [example/README.md](./example/README.md).
CI: [`.github/workflows/react-native.yml`](../.github/workflows/react-native.yml).
