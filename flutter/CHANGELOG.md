# Changelog

All notable changes to `dropplink_flutter`. The version is shared with the Android, iOS and React Native
SDKs ([docs/sdk-spec.md](../docs/sdk-spec.md)).

## 0.2.0 - 2026-10-22

- `Dropplink.track(name, props:, revenue:)` records in-app events. The native SDK validates them, keeps them
  in an on-disk queue and sends them to `/v1/events` in the background. Revenue sent from the app is shown
  as app-reported; purchases that pay creators should come from the brand's server (`/v1/s2s/events`).
- `Dropplink.identify(userId, email:, phone:)` and `Dropplink.logout()` link and unlink the brand's user id.
  Email and phone are hashed on the device.
- `Dropplink.setTrackingEnabled` / `isTrackingEnabled` for consent: off clears the queue and stops events
  and identify. Attribution and deep links keep working.
- New `Revenue` class.
- The new calls never throw: native failures are swallowed.
- Built on `app.ondropp:dropplink-android` 0.2.0 and the `Dropplink` pod 0.2.0; reports `0.2.0-flutter`.

## 0.1.0 - 2026-10-20

First release.

- `Dropplink.initialize` starts the native SDK, which reports every launch to `/v1/init` in the background.
- `Dropplink.onDeepLink` streams the deferred deep link after a fresh install and App Link / Universal Link
  opens. A link that arrives before anything listens is delivered on the first listen.
- App Links (launch intent and `onNewIntent`) and Universal Links are forwarded to the native SDK
  automatically; `handleDeepLink` for apps that receive links themselves.
- `getAttribution` and `getInstallId`.
- Built on `app.ondropp:dropplink-android` 0.1.0 and the `Dropplink` pod 0.1.0.
