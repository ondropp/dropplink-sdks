# Changelog

All notable changes to the Dropplink Android SDK (`app.ondropp:dropplink-android`). The version is shared
with the iOS, Flutter and React Native SDKs ([docs/sdk-spec.md](../docs/sdk-spec.md)).

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
