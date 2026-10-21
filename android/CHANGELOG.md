# Changelog

All notable changes to the Dropplink Android SDK (`app.ondropp:dropplink-android`). The version is shared
with the iOS, Flutter and React Native SDKs ([docs/sdk-spec.md](../docs/sdk-spec.md)).

## 0.2.0 - Unreleased

In-app events, revenue and users (spec section 11).

- `Dropplink.track(name, props, revenue)` records an event: checked locally (snake_case name, up to 20
  props, no emails or phone numbers in values, revenue rounded to 2 decimals with an upper-case ISO 4217
  currency), written to `dropplink-queue.json` in `noBackupFilesDir` and sent to `/v1/events` in batches
  (up to 100 events / 60 KB). `eventId` and `ts` are fixed when `track` is called, so retries are safe.
- `Dropplink.identify(userId, email, phone)` and `Dropplink.logout()` send `/v1/identify` in queue order,
  so events after a login carry the user. Email and phone are SHA-256 hashed on the device; repeating the
  same user id is a no-op.
- `Dropplink.setTrackingEnabled(enabled)` / `isTrackingEnabled()`: `false` clears the queue and stops
  events and identify, persisted across launches. Attribution and deep links are unaffected.
- `Revenue(amount, currency, orderId)`. App-reported revenue; purchases that pay creators belong in the
  brand's server via `/v1/s2s/events`.
- The queue is sent 1 s after the last call, when the app goes to the background and after each successful
  init (never before it). Network errors, `429`, `5xx` and `stale_timestamp` back off from 1 s to 5 min
  (± 20%, honouring a longer `Retry-After`); other `401`s pause it until the next launch; `404
  unknown_install` re-runs init; `400` drops the batch. At most 1,000 events / 1 MB (oldest non-revenue
  events dropped first) and nothing older than 7 days.
- `sdkVersion` is now `0.2.0`.

## 0.1.0 - 2026-10-20

First release.

- `Dropplink.initialize(context, config)` sends `/v1/init` once per launch on a background thread, signed
  with HMAC-SHA256, including the Play Install Referrer until the install is attributed. Network errors,
  `5xx`, `429` and `stale_timestamp` are retried 3 times (1 s, 2 s, 4 s ± 20%); `invalid_key` and
  `platform_mismatch` stop the SDK until next launch.
- `setDeepLinkListener` delivers the deferred deep link after a fresh install and App Link opens, on the
  main thread. The latest link waits in memory until a listener is set.
- `handleDeepLink(Uri)` / `handleDeepLink(String)` resolve App Links through `/v1/deeplink`; links reported
  before init finishes are sent after it.
- `getAttribution()` (cached in `dropplink.json` in `noBackupFilesDir`) and `getInstallId()`.
- `Attribution.toMap()` / `DeepLink.toMap()` and `DropplinkConfig.platformWrapper` for the Flutter and
  React Native packages.
- minSdk 21. Only dependency: `com.android.installreferrer:installreferrer:2.2`. Consumer R8 rules keep the
  public API.
