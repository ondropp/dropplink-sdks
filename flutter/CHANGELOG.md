# Changelog

All notable changes to `dropplink_flutter`. The version is shared with the Android, iOS and React Native
SDKs ([docs/sdk-spec.md](../docs/sdk-spec.md)).

## 0.1.0 - 2026-10-20

First release.

- `Dropplink.initialize` starts the native SDK, which reports every launch to `/v1/init` in the background.
- `Dropplink.onDeepLink` streams the deferred deep link after a fresh install and App Link / Universal Link
  opens. A link that arrives before anything listens is delivered on the first listen.
- App Links (launch intent and `onNewIntent`) and Universal Links are forwarded to the native SDK
  automatically; `handleDeepLink` for apps that receive links themselves.
- `getAttribution` and `getInstallId`.
- Built on `app.ondropp:dropplink-android` 0.1.0 and the `Dropplink` pod 0.1.0.
