# Changelog

All notable changes to the Dropplink iOS SDK. The version is shared with the Android, Flutter and React
Native SDKs ([docs/sdk-spec.md](../docs/sdk-spec.md)).

## 0.2.0 - Unreleased

In-app events, revenue and users (spec §11).

- `Dropplink.track(_:props:revenue:)` records an event with optional props and `Revenue(amount:currency:orderId:)`.
  Checked on the device (snake_case names, ≤ 20 props, no emails or phone numbers in values, revenue ≥ 0
  rounded to 2 decimals, ISO 4217 currency); invalid events and props are dropped with a debug log.
  Revenue from the app is shown as app-reported: purchases that pay creators must come from the brand's
  server (`/v1/s2s/events`).
- `Dropplink.identify(userId:email:phone:)` links the brand's user id to the install; email and phone are
  SHA-256 hashed on the device. Repeating the same user id is a no-op. `Dropplink.logout()` unlinks it.
- `Dropplink.setTrackingEnabled(_:)` / `Dropplink.isTrackingEnabled`: `false` clears the queue and stops
  events and identify, persisted across launches. Attribution and deep links keep working.
- Events and identify go through an on-disk queue (`Application Support/Dropplink/dropplink-queue.json`,
  excluded from backup, written atomically), sent in order 1 s after the last call, when the app goes to
  the background (with a background task) and after each successful init. Batches of ≤ 100 events / 60 KB.
  Network errors, `429` and `5xx` back off 1 s → 5 min (± 20%, honouring `Retry-After`) for as long as the
  app runs; `404 unknown_install` re-runs init; `400` drops the batch. At most 1,000 events / 1 MB, oldest
  non-revenue events dropped first; events older than 7 days are dropped.
- Privacy manifest declares Coarse Location, User ID, Email Address, Phone Number, Product Interaction and Purchase History
  (analytics, linked, not tracking). The install id's Device ID entry is now linked to the user (it is, once
  `identify` runs) and adds the App Functionality purpose (deep links).
- Reinstall detection: a random key in the Keychain (this device only, never synced) survives the app
  being deleted and is sent as `reinstallKey` on `/v1/init`, so a reinstall isn't counted (or billed) as
  a new install. Needs server support for `reinstallKey` (Dropplink attribution, iOS phase 4).
- `sdkVersion` is now `0.2.0`.

## 0.1.0 - 2026-10-20

First release.

- `Dropplink.initialize(config:)` sends `/v1/init` once per launch in the background, signed with
  HMAC-SHA256, and retries network errors, `5xx`, `429` and `stale_timestamp` 3 times (1 s, 2 s, 4 s ± 20%).
- `setDeepLinkListener(_:)` delivers the deferred deep link after a fresh install and Universal Link opens,
  on the main thread. The latest link waits in memory until a listener is set.
- `handleDeepLink(_:)` and `handleUserActivity(_:)` resolve Universal Links through `/v1/deeplink`; links
  reported before init finishes are sent after it.
- `attribution` (cached in `UserDefaults` suite `app.ondropp.dropplink`) and `installId`.
- Swift Package Manager and CocoaPods. iOS 13+. Privacy manifest included. No third-party dependencies.
