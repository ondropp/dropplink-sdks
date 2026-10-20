# Changelog

All notable changes to `@ondropp/dropplink-react-native`. The version is shared with the Android, iOS and
Flutter SDKs ([docs/sdk-spec.md](../docs/sdk-spec.md)).

## Unreleased

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
