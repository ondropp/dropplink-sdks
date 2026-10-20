# Dropplink SDK spec

_v0.1 · 2026-10-20 · The single source of truth for what every Dropplink SDK does. Each platform's code
implements this document; a behaviour change lands here first, in the same commit as the code._

The wire contract (request/response shapes, signing) is owned by `dropp-attribution` and copied into
[`contract/`](../contract). This spec covers everything the wire contract doesn't: public API, storage,
retries, deep-link delivery and logging.

- [1. Platforms](#1-platforms)
- [2. Public API](#2-public-api)
- [3. Lifecycle](#3-lifecycle)
- [4. Requests and signing](#4-requests-and-signing)
- [5. Errors and retries](#5-errors-and-retries)
- [6. Storage](#6-storage)
- [7. Deep links](#7-deep-links)
- [8. Logging](#8-logging)
- [9. Rules every SDK follows](#9-rules-every-sdk-follows)
- [10. Testing](#10-testing)

## 1. Platforms

| Folder | Package | Language | Distribution | Min OS |
| --- | --- | --- | --- | --- |
| `android/` | `app.ondropp:dropplink-android` | Kotlin | Maven Central | Android 5.0 (API 21) |
| `ios/` | `Dropplink` | Swift | Swift Package Manager, CocoaPods | iOS 13 |
| `flutter/` | `dropplink` | Dart | pub.dev | Wraps the native SDKs |
| `react-native/` | `@ondropp/dropplink-react-native` | TypeScript | npm | Wraps the native SDKs |

**Native SDKs hold all the logic.** The Flutter and React Native packages are thin bridges: they forward
calls to the native SDK and convert results. No signing, storage or retry logic is duplicated in Dart or JS.

All four share one version number (`0.1.0`), released together (see [releasing.md](./releasing.md)). The
`sdkVersion` sent to the server is the SDK's own version, with a suffix for wrappers so the dashboard can
tell them apart: `0.1.0` (native), `0.1.0-flutter`, `0.1.0-rn`.

## 2. Public API

Names are the same on every platform, adapted to the language's conventions.

| Call | Does |
| --- | --- |
| `initialize(config)` | Starts the SDK. Call once, as early as possible (Android `Application.onCreate`, iOS `application(_:didFinishLaunchingWithOptions:)`). Sends `/v1/init` in the background. Safe to call again: later calls are ignored. |
| `setDeepLinkListener(listener)` | Receives every deep link: the deferred one after a fresh install, and App Link / Universal Link opens. A link that arrives before a listener is set is held in memory and delivered when one is set. |
| `handleDeepLink(url)` | Reports an App Link / Universal Link the OS opened the app with. Resolves it through `/v1/deeplink` and delivers the result to the listener. Ignores URLs that aren't `http(s)`. |
| `getAttribution()` | The last attribution the server returned (`type`, `method`, `linkId`, `source`, …), or `null` before the first successful init. Cached on disk. |
| `getInstallId()` | This install's id. Developers paste it into the dashboard's **Install debugger**. |

### Config

| Field | Required | Default | |
| --- | --- | --- | --- |
| `keyId` | yes | | `ak_…` SDK key id for this platform, from the dashboard |
| `secret` | yes | | The key's secret |
| `debug` | no | `false` | Turns on logging (section 8). Never ship `true`. |
| `baseUrl` | no | `https://attribution.ondropp.app` | For local testing against `http://10.0.2.2:4100` etc. |

### Types

```
DeepLink    { path: String, params: Map<String, String>, url: String?, isDeferred: Boolean }
Attribution { type: "attributed" | "organic", method: "install_referrer" | "fingerprint" | "none",
              clickId?, linkId?, campaignId?, creatorId?, source?, confidence?, attributedAt? }
```

`DeepLink.url` is the opened URL for App Link opens and `null` for deferred links. `isDeferred` is `true`
only for the link delivered by `/v1/init` after a fresh install.

### Example (Kotlin)

```kotlin
class App : Application() {
    override fun onCreate() {
        super.onCreate()
        Dropplink.initialize(this, DropplinkConfig(keyId = BuildConfig.DROPPLINK_KEY_ID, secret = BuildConfig.DROPPLINK_SECRET))
        Dropplink.setDeepLinkListener { link -> router.open(link.path, link.params) }
    }
}
// In the launcher activity's onCreate and onNewIntent:
intent?.data?.let { Dropplink.handleDeepLink(it) }
```

## 3. Lifecycle

On `initialize`, on a background thread:

1. Load or create the **install id**: a random UUID v4, created on the first launch after install and
   persisted (section 6). Never regenerated, not even after an error.
2. **Android only, until attributed:** read the Play Install Referrer (`com.android.installreferrer:installreferrer`).
   Parse `click_id` out of the raw string. If the API fails or isn't available, send no `installReferrer`
   this launch and try again next launch. Once a response has said `attributed`, stop reading it.
3. Build and send `POST /v1/init` (section 4).
4. On `200`: store `attribution`; if `attribution.type == "attributed"`, set the `attributed` flag. If
   `deepLink` is non-null, deliver it to the listener with `isDeferred = true`. The server sends it at most
   once per install, so the SDK never stores or re-delivers it.
5. On failure: section 5. The next app launch tries again from step 1.

One init per process launch. `handleDeepLink` calls made before init finishes are queued and sent after
it, so the install exists on the server first.

## 4. Requests and signing

Exactly as [`dropp-attribution` docs/sdk-api.md](../../dropp-attribution-server/docs/sdk-api.md):

```
X-Key-Id:    <keyId>
X-Timestamp: <unix seconds>
X-Signature: hex(HMAC_SHA256(key = UTF-8 secret, msg = timestamp + "\n" + hex(SHA256(body bytes))))
Content-Type: application/json
```

- Serialize the body **once** to bytes, sign those bytes, send those bytes.
- Timestamp in **seconds**, never milliseconds.
- Lower-case hex.
- Timeouts: 10 s connect, 10 s read.

### `/v1/init` body

| Field | Android | iOS |
| --- | --- | --- |
| `installId` | stored UUID | stored UUID |
| `platform` | `"android"` | `"ios"` |
| `appVersion` | `versionName` (fallback `"unknown"`) | `CFBundleShortVersionString` (fallback `"unknown"`) |
| `sdkVersion` | section 1 | section 1 |
| `device.model` | `Build.MODEL` | hardware identifier from `utsname.machine`, e.g. `iPhone16,1` |
| `device.osVersion` | `Build.VERSION.RELEASE` | `UIDevice.current.systemVersion` |
| `device.locale` | BCP 47, e.g. `en-IN` | BCP 47, e.g. `en-IN` |
| `device.timezone` | IANA name, e.g. `Asia/Kolkata` | `TimeZone.current.identifier` |
| `device.screen` | `{ w, h, dpr }` from display metrics, integer pixels | `{ w, h, dpr }` in pixels (`bounds × scale`) |
| `installReferrer` | `{ raw, clickId?, referrerClickTs?, installBeginTs? }` until attributed | never sent |

Truncate strings to the contract's max lengths (model 100, osVersion 32, locale 35, timezone 64) rather
than letting the server reject the request.

## 5. Errors and retries

| Response | SDK does |
| --- | --- |
| Network error, timeout, `5xx`, `429` | Retry up to 3 times in this launch, backoff 1 s, 2 s, 4 s (± 20% jitter). Then give up until next launch. |
| `401 stale_timestamp` | Same as above, and log "Device clock looks wrong" in debug mode. |
| `401 invalid_key` | Stop. No retries this launch. Log loudly in debug mode: the key is unknown, revoked or the app was deleted. |
| `400 platform_mismatch` | Stop. Log: "This is a <platform> key, used in an <other> app". |
| Any other `4xx` | Stop. Log the `error.code`, `message` and `details`. It's an SDK bug or bad config, and retrying won't help. |

Errors never reach the host app as exceptions. Public calls never throw (except the config validation
below) and never block the main thread.

`initialize` with an empty `keyId`, a `keyId` not starting with `ak_`, or an empty `secret` logs an error
and disables the SDK (in debug builds of the host app it may throw / assert, so the mistake is caught
early).

## 6. Storage

| Key | Value |
| --- | --- |
| `installId` | UUID string |
| `attributed` | boolean |
| `attribution` | the last attribution JSON |

Android: a JSON file `dropplink.json` in `Context.noBackupFilesDir`. iOS: `UserDefaults(suiteName: "app.ondropp.dropplink")`.
The secret is never stored by the SDK; it lives in the app's build config.

Why `noBackupFilesDir` on Android: Auto Backup restores `SharedPreferences` onto a new phone, and two
devices would then share one install id. Files in `noBackupFilesDir` are never backed up, so brands don't
need to edit their backup rules.

## 7. Deep links

Two sources, one listener:

| Source | How it arrives | `isDeferred` | `url` |
| --- | --- | --- | --- |
| Fresh install from a link | `deepLink` in the `/v1/init` response | `true` | `null` |
| App already installed, link tapped | OS opens the app with the URL → app calls `handleDeepLink(url)` → `POST /v1/deeplink` | `false` | the URL |

- `/v1/deeplink` returning `{ clickId: null, deepLink: null }` means the URL isn't a Dropplink link for this
  app: deliver nothing.
- `clickId` set but `deepLink: null` means the link has no deep link path: deliver nothing (the click is
  still recorded server-side).
- Listener callbacks run on the main thread / main isolate / JS thread.
- If no listener is set yet, keep the **latest** pending link in memory and deliver it as soon as one is set.
  Never persist it.

## 8. Logging

Off unless `debug: true`. Tag / subsystem `Dropplink`. On every init in debug mode, log:

```
Dropplink: install id 6f1c2a9e-… (paste into Dropplink → Install debugger)
Dropplink: init 200 attributed via install_referrer, link 6711a0…, deep link /product/123
```

Never log the secret, the signature or full request bodies. Device details and the install id are fine.

## 9. Rules every SDK follows

1. **Never crash or slow the host app.** All work off the main thread; every failure caught.
2. **No third-party dependencies** beyond what the platform requires (Android: the Play Install Referrer
   library). Use the platform's HTTP, JSON and crypto. Fewer dependencies, fewer conflicts in brands' apps.
3. **Small public surface.** Only section 2 is public. Everything else is `internal` / not exported, so it
   can change without a major version.
4. **Unknown response fields are ignored**, so the server can add fields without breaking old SDKs.
5. **Privacy:** no advertising ids, no contacts, no location. Only what section 4 lists.
6. **Semantic versioning.** Breaking a section 2 API is a major version.

## 10. Testing

Every native SDK has unit tests that:

1. Reproduce every `signature` in `contract/hmac/vectors.json`.
2. Build an init body and check it has the fields and types of `contract/init/request.<platform>.json`.
3. Parse `contract/init/response.attributed.json`, `response.organic.json` and both `deeplink/response.*.json`.
4. Check the retry rules of section 5 against a fake HTTP layer.
5. Check a pending deep link is delivered once a listener is set.

Wrappers test their bridge (method names, argument conversion) with the platform's mocking tools.

`scripts/sync-contract.sh` re-copies the fixtures from the server repo. Run it whenever the server's
`npm run fixtures` output changes, and commit the result.
