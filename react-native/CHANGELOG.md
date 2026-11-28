# Changelog

All notable changes to `@ondropp/dropplink-react-native`. The version is shared with the Android, iOS and
Flutter SDKs ([docs/sdk-spec.md](../docs/sdk-spec.md)).

## 0.2.1 - Unreleased

- Built on the `Dropplink` pod 0.2.1, which detects reinstalls on iOS with a Keychain key, and
  `app.ondropp:dropplink-android` 0.2.1. Reports `0.2.1-rn`. No JavaScript API changes.
- The podspec's git source now points at the `v<version>` tags the repo actually uses.

## 0.2.0 - 2026-10-22

Bridges the events, revenue and users API of `app.ondropp:dropplink-android` 0.2.0 and the `Dropplink`
pod 0.2.0 (docs/sdk-spec.md section 11). Validation, hashing, the on-disk queue and retries stay native.

- `Dropplink.track(name, { props, revenue })`. Prop booleans stay booleans across the bridge.
- `Dropplink.identify(userId, { email, phone })` and `Dropplink.logout()`.
- `Dropplink.setTrackingEnabled(enabled)` and `Dropplink.isTrackingEnabled()` for consent.
- New types `EventProps`, `Revenue`, `IdentifyTraits`.
- These calls never throw, including when the native module isn't linked.
- The server now sees `sdkVersion` `0.2.0-rn`.

## 0.1.0 - 2026-10-20

First release. A thin bridge over `app.ondropp:dropplink-android` 0.1.0 and the `Dropplink` pod 0.1.0;
all attribution, signing, storage and retry logic stays native.

- `Dropplink.initialize(config)` with `keyId`, `secret`, optional `debug` and `baseUrl`. Sends
  `platformWrapper = "rn"` so the server sees `sdkVersion` `0.1.0-rn`.
- `addDeepLinkListener(listener)` for the deferred deep link and App Link / Universal Link opens. The
  native SDK holds a link that arrives before the first JS listener and delivers it then.
- `handleDeepLink(url)`, `getAttribution()`, `getInstallId()`.
- `listenToLinking()` forwards React Native `Linking` URLs to `handleDeepLink`.
- `useDropplinkDeepLink(handler)` hook.
- Classic native module served through the New Architecture interop layer; React Native 0.76+.
