# Changelog

All notable changes to the Dropplink iOS SDK. The version is shared with the Android, Flutter and React
Native SDKs ([docs/sdk-spec.md](../docs/sdk-spec.md)).

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
