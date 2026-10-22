# Dropplink SDK spec

_v0.2 · 2026-10-22 · The single source of truth for what every Dropplink SDK does. Each platform's code
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
- [11. Events, revenue and users](#11-events-revenue-and-users)
- [12. Web](#12-web)

## 1. Platforms

| Folder | Package | Language | Distribution | Min OS |
| --- | --- | --- | --- | --- |
| `android/` | `app.ondropp:dropplink-android` | Kotlin | Maven Central | Android 5.0 (API 21) |
| `ios/` | `Dropplink` | Swift | Swift Package Manager, CocoaPods | iOS 13 |
| `flutter/` | `dropplink` | Dart | pub.dev | Wraps the native SDKs |
| `react-native/` | `@ondropp/dropplink-react-native` | TypeScript | npm | Wraps the native SDKs |
| `web/` | `@ondropp/dropplink-web` | TypeScript | npm, and a script tag served by the link domain | Browsers from 2019 (ES2019, `fetch` keepalive) |

**Native SDKs hold all the logic.** The Flutter and React Native packages are thin bridges: they forward
calls to the native SDK and convert results. No signing, storage or retry logic is duplicated in Dart or JS.

All five share one version number (`0.2.0`), released together (see [releasing.md](./releasing.md)). The
`sdkVersion` sent to the server is the SDK's own version, with a suffix for wrappers so the dashboard can
tell them apart: `0.2.0` (native), `0.2.0-flutter`, `0.2.0-rn`, `0.2.0-web`.

The web SDK is the exception to "native holds the logic": a browser has no native layer, so it has its own
implementation of §12. Sections 2–11 describe the app SDKs.

## 2. Public API

Names are the same on every platform, adapted to the language's conventions.

| Call | Does |
| --- | --- |
| `initialize(config)` | Starts the SDK. Call once, as early as possible (Android `Application.onCreate`, iOS `application(_:didFinishLaunchingWithOptions:)`). Sends `/v1/init` in the background. Safe to call again: later calls are ignored. |
| `setDeepLinkListener(listener)` | Receives every deep link: the deferred one after a fresh install, and App Link / Universal Link opens. A link that arrives before a listener is set is held in memory and delivered when one is set. |
| `handleDeepLink(url)` | Reports an App Link / Universal Link the OS opened the app with. Resolves it through `/v1/deeplink` and delivers the result to the listener. Ignores URLs that aren't `http(s)`. |
| `getAttribution()` | The last attribution the server returned (`type`, `method`, `linkId`, `source`, …), or `null` before the first successful init. Cached on disk. |
| `getInstallId()` | This install's id. Developers paste it into the dashboard's **Install debugger**. |
| `track(name, props?, revenue?)` | Records an in-app event (section 11). Validated, written to the on-disk queue and sent in the background. Never throws, never blocks. |
| `identify(userId, email?, phone?)` | Links the brand's own user id to this install, when the user signs up or logs in. `email` / `phone` are optional and hashed on the device before they leave it. |
| `logout()` | Unlinks the user (`/v1/identify` with `userId: null`). Events after it carry no user. |
| `setTrackingEnabled(enabled)` | `false` clears the queue and stops events and identify, persisted across launches (for consent). Install attribution and deep links keep working. Default `true`. |
| `isTrackingEnabled()` | The current setting. |

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
Revenue     { amount: Double, currency: String, orderId: String? }
Attribution { type: "attributed" | "organic", method: "install_referrer" | "fingerprint" | "none",
              clickId?, linkId?, campaignId?, creatorId?, source?, confidence?, attributedAt? }
```

`DeepLink.url` is the opened URL for App Link opens and `null` for deferred links. `isDeferred` is `true`
only for the link delivered by `/v1/init` after a fresh install.

### Signatures

| | `track` | `identify` | `Revenue` |
| --- | --- | --- | --- |
| Kotlin | `track(name: String, props: Map<String, Any?>? = null, revenue: Revenue? = null)` (`@JvmStatic @JvmOverloads`) | `identify(userId: String, email: String? = null, phone: String? = null)` | `data class Revenue(val amount: Double, val currency: String, val orderId: String? = null)` |
| Swift | `track(_ name: String, props: [String: Any]? = nil, revenue: Revenue? = nil)` | `identify(userId: String, email: String? = nil, phone: String? = nil)` | `struct Revenue { amount: Double; currency: String; orderId: String? }` |
| Dart | `Future<void> track(String name, {Map<String, Object?>? props, Revenue? revenue})` | `Future<void> identify(String userId, {String? email, String? phone})` | `class Revenue { double amount; String currency; String? orderId }` |
| TypeScript | `track(name: string, options?: { props?: EventProps; revenue?: Revenue }): void` | `identify(userId: string, traits?: { email?: string; phone?: string }): void` | `{ amount: number; currency: string; orderId?: string }` |

`logout()`, `setTrackingEnabled(enabled)` and `isTrackingEnabled()` keep their names everywhere
(Swift: `Dropplink.isTrackingEnabled` is a static property; Dart and TypeScript return `Future<bool>` /
`Promise<bool>` because the value lives in the native SDK).

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
| `trackingEnabled` | boolean, absent = `true` |

Android: a JSON file `dropplink.json` in `Context.noBackupFilesDir`. iOS: `UserDefaults(suiteName: "app.ondropp.dropplink")`.

The event queue (section 11) is a separate JSON file, `dropplink-queue.json`, in the same directory on
Android and in `Application Support/Dropplink/` on iOS (excluded from backup). It is rewritten atomically
(write to a temp file, then rename) on every change, so a kill mid-write never corrupts it. A file that
fails to parse is discarded with a debug log, never a crash.
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
6. Build an events body and an identify body matching `contract/events/request.json` and
   `contract/identify/request.json` / `request.logout.json`; parse `contract/events/response.partial.json`.
7. Check the queue rules of section 11: the response table, the caps and drop order, ordering of
   identify before later events, persistence across a restart, and `setTrackingEnabled(false)`.
8. Check local validation against each event in `contract/events/invalid/`: `name-not-snake-case` and
   `negative-revenue` are dropped; `currency-lower-case` is upper-cased and `three-decimals` rounded
   (section 11), so both are sent fixed; `event-id-not-uuid` and `ts-not-integer` can't happen because
   the SDK creates `eventId` and `ts` itself. A new fixture with no expectation fails the test.

Wrappers test their bridge (method names, argument conversion) with the platform's mocking tools.

`scripts/sync-contract.sh` re-copies the fixtures from the server repo. Run it whenever the server's
`npm run fixtures` output changes, and commit the result.

## 11. Events, revenue and users

Server side: `/v1/events` and `/v1/identify` in
[`dropp-attribution` docs/sdk-api.md](../../dropp-attribution-server/docs/sdk-api.md). Revenue the app
reports is shown as **app-reported**. Revenue that pays creators comes from the brand's server
(`/v1/s2s/events`), so the docs tell brands to send purchases from their backend and use `track` for the
funnel.

### `track`

The SDK creates the `eventId` (UUID v4) and `ts` (unix **seconds**, device clock) when `track` is called,
and stores both with the event, so every retry sends the same values. It then checks the event locally
and, if it's invalid, logs why (debug mode) and drops it, instead of letting the server reject it:

| Rule | Locally |
| --- | --- |
| `name` matches `^[a-z][a-z0-9_]{0,63}$` | Drop the event |
| At most 20 props; keys `^[A-Za-z0-9_]{1,40}$` | Drop the bad keys; keep 20 valid ones (the first 20 by insertion order where the platform's map keeps order, else by sorted key, as on iOS) |
| Prop values: string ≤ 256 chars, finite number, boolean, null | Truncate long strings to 256; drop other value types (lists, maps, NaN) |
| Prop value contains an email or is a phone number (server's `pii.ts` rules) | Drop the prop (the server would drop it anyway) |
| `revenue.amount` finite and ≥ 0 | Drop the event (refunds come from the brand's server) |
| `revenue.amount` more than 2 decimals | Round half-up to 2 decimals |
| `revenue.currency` | Trim and upper-case; must then match `^[A-Z]{3}$`, else drop the event |
| `revenue.orderId` 1–128 chars | Empty → omitted; longer → drop the event |

The server's PII rules, ported exactly: an email is `[^\s@]+@[^\s@]+\.[^\s@]{2,}` anywhere in the value; a
phone is the whole value, after removing spaces, `(`, `)`, `.` and `-`, matching `^\+\d{10,15}$` or
`^(?:0|91)?[6-9]\d{9}$`.

### `identify` and `logout`

- `userId` is trimmed; 1–128 chars, and not an email or a phone number (same rules), else the call is
  dropped with a debug log. Brands should pass an opaque id.
- `email`: trimmed, lower-cased, must contain `@`; sent as `traits.emailHash` = lower-case hex
  SHA-256 of the UTF-8 bytes. `phone`: spaces, `-`, `(`, `)` and `.` removed; must then match
  `^\+[1-9]\d{7,14}$` (E.164), else that trait is dropped with a debug log. Sent as `traits.phoneHash`.
  Plain values never leave the device and are never stored.
- Calling `identify` with the same user id as the last one queued or sent is a no-op (traits included),
  so brands can call it on every launch. The last identified user id is kept in the queue file's
  metadata. The server allows 5 identifies a minute per install, so this matters.
- `logout()` queues `{ userId: null }` (no traits) and forgets the last user id.

### The queue

`track`, `identify` and `logout` append an entry to the on-disk queue and return. Entries keep their
order, so an identify always reaches the server before the events tracked after it.

```
{ "v": 1, "lastUserId": "user_8812" | null,
  "items": [ { "kind": "event", "eventId", "name", "ts", "props"?, "revenue"? },
             { "kind": "identify", "userId": "user_8812" | null, "traits"? } ] }
```

**When it sends:** 1 s after the last `track`/`identify` (debounce), when the app goes to the background,
and right after every successful `/v1/init`. Never before this launch's init has succeeded, because the
server must know the install. One flush at a time.

**A flush** takes items from the head: an `identify` is sent alone to `/v1/identify`; otherwise up to 100
consecutive events (stopping before the next identify) and at most 60 KB of body go in one
`/v1/events` request. It repeats until the queue is empty or a request fails.

| Response | Do |
| --- | --- |
| `200` (events) | Remove every event in the batch: accepted, duplicates and rejected. Log each `rejected` entry and each `warnings` entry in debug mode. |
| `200` (identify) | Remove it. |
| `429`, `503`, other `5xx`, network error, timeout | Keep everything. Retry with exponential backoff: 1 s, 2 s, 4 s … capped at 5 min, ± 20% jitter. A `Retry-After` header (seconds) wins when it is longer. |
| `401 stale_timestamp` | As above, and log "Device clock looks wrong". |
| Other `401` | Keep everything; stop sending until the next launch. Log loudly. |
| `404 unknown_install` | Run `/v1/init` again, then retry. If that init fails, or the retry gets `404 unknown_install` again, back off as for `503` (never loop init → events). |
| `400`, or any other `4xx` (`403`, `413`, a `404` that isn't `unknown_install`) | The batch is malformed (an SDK bug) or the identify was refused: remove that batch / identify and log the `error`. Keeping it would block everything queued behind it. |
| Anything else (e.g. `3xx`) | As for `503`. |

The backoff resets after any `200`. Retries continue for as long as the process lives; whatever is left
is sent on the next launch.

**Caps:** at most 1,000 events and 1 MB in the file. When adding an event would exceed either, drop the
oldest **non-revenue** event first; if only revenue events are left, drop the new event if it has no
revenue, else the oldest revenue event. Identify entries are never dropped. On load and before every
flush, drop events whose `ts` is more than 7 days old (the server rejects them).

**`setTrackingEnabled(false)`** empties the queue (and `lastUserId`), stops `track`, `identify`, `logout`
and flushing, and persists the setting. `setTrackingEnabled(true)` resumes; nothing tracked while it was
off is recovered.

### Logging (debug mode)

```
Dropplink: track add_to_cart (queued, 3 waiting)
Dropplink: events 200: 3 accepted, 0 duplicates, 0 rejected
Dropplink: event "Add To Cart" dropped: name must be snake_case, e.g. add_to_cart
Dropplink: identify user_8812 sent
```

Never log prop values, email, phone, or hashes.

## 12. Web

For brands' websites (`web/`). Server side: `dropp-attribution` docs/web-api.md and plan 5.16. It
records **behaviour**: which Dropplink link brought a visitor, their sessions, page views, funnel events and
time on page. It never reports money and never sets a user's credit: the key is public, so anything the
browser sends is unverified. Orders come from the brand's server (`/v1/s2s/events` with `visitorId`).

### Loading

```html
<script src="https://go.brand.com/_d/s.js" data-key="pk_…" defer></script>
```

The script comes from the app's link domain, so it and its requests are first-party for the brand's site
(`go.brand.com` and `brand.com` are one site), and blocklists written against our domain don't match. It
posts back to the path next to its own: `/_d/s.js` → `/_d/e`, `/v1/web/s.js` → `/v1/web/e`.

| Attribute (`window.DropplinkConfig` key) | Default | |
| --- | --- | --- |
| `data-key` (`key`) | required | The app's web key `pk_…`. Anything else turns the script off with a console error. |
| `data-endpoint` (`endpoint`) | next to the script | A full URL, for a proxy on the brand's own origin. |
| `data-consent` (`consent`) | `granted` | `required`: see Consent. |
| `data-spa` (`spa`) | `true` | `"false"` turns off page views on `history.pushState` / `replaceState` / `popstate`. |
| `data-cookie-domain` (`cookieDomain`) | the page's host | e.g. `.brand.com`, so every subdomain's server reads the cookies. |
| `data-debug` (`debug`) | `false` | Logs to the console with the prefix `[Dropplink]`. |

Calls made before the script loads are queued by a stub and replayed in order:

```html
<script>!function(w){var d=w.dropplink=w.dropplink||{q:[]};["track","identify","logout","grant","revoke"]
.forEach(function(m){d[m]=d[m]||function(){d.q.push([m].concat([].slice.call(arguments)))}})}(window)</script>
```

npm: `import { init } from "@ondropp/dropplink-web"; const dropplink = init({ key, endpoint })`. Same
behaviour; `endpoint` defaults to `https://attribution.ondropp.app/v1/web/e`, so pass the link domain's.

### Public API (`window.dropplink`)

| Call | Does |
| --- | --- |
| `track(name, props?)` | A funnel event. Standard names: `view_item`, `add_to_cart`, `begin_checkout`, `sign_up`, `purchase` (no amount; revenue comes from the server). `page_view` is automatic. Validated as in §11 (name, props, personal values). |
| `identify(userId)` | After login: links the visitor to the brand's user id for the journey view. Same user id rules as §11; a repeat of the last id is a no-op. Unverified: it never moves credit. |
| `logout()` | Sends `userId: null` and forgets the last id. |
| `grant()` / `revoke()` | Consent. See below. |
| `getVisitorId()` | The visitor id, for the brand's checkout to send with the order. `null` before consent. |
| `getClickId()` | The first Dropplink click in the last 30 days, or `null`. |
| `flush()` | Sends what's queued now. Returns a promise; never rejects. |

Nothing throws. Without `window` (server rendering) every call is a no-op.

### Storage

| localStorage | Cookie (first-party, `SameSite=Lax`, `Secure` on https) | |
| --- | --- | --- |
| `dl_vid` | `dropp_vid`, 395 days, refreshed on every send | Visitor id, a UUID v4 |
| `dl_click` `{ id, t }` | `dropp_click_id`, 30 days | The **first** valid `dropp_click_id` the site was opened with (first touch). A later click doesn't replace it. |
| `dl_sess` `{ id, last, click? }` | | Session: renewed after **30 minutes** idle, or when a page opens with a different click id or with UTM tags |
| `dl_q` `{ v: 1, items }` | | The send queue |
| `dl_uid`, `dl_consent` | | The last identified user id; the consent state |

The cookies exist for the brand's **server**: at checkout it reads `dropp_vid` (and `dropp_click_id`) and
sends them with the order. Safari limits storage written by page scripts to 7 days; the brand's server
should also save them on the cart or session at landing.

On load, `dropp_click_id` is removed from the address bar (`history.replaceState`), so a URL the visitor
shares doesn't carry their click.

### What it sends

`POST` with `content-type: text/plain;charset=UTF-8` (no CORS preflight), `credentials: "omit"`,
`keepalive: true` when the page is being hidden. Body:
`{ key, visitorId, sdkVersion: "0.2.0-web", items: [...] }` (`contract/web/request.json`). Items:

| `type` | When | Fields |
| --- | --- | --- |
| `event` | `page_view` on load and on each SPA route change to a new path or query; `track` | `eventId` (UUID), `sessionId`, `name`, `ts` (seconds), `path` (`location.pathname` only: queries can hold personal data), `title` (page views), `props`. On the first event of a session: `referrer`, `utm` and `clickId` from the landing URL. |
| `engage` | The page is hidden, left, or the SPA route changes, after ≥ 1 s visible | `eventId`, `sessionId`, `ts`, `path`, `ms` visible on that page |
| `identify` | `identify` / `logout` | `ts`, `userId` or `null` |

Nothing is sent from `navigator.webdriver` browsers.

### Queue and retries

Items are written to `dl_q` before sending, so a reload, a closed tab or a network drop loses nothing:
the next page sends them, and the server drops repeats by `eventId`.

- **When:** 2 s after the last item (debounce), at once at 20 waiting, and when the page is hidden.
  One send at a time per page; tabs share the queue and the server dedupes.
- **Batch:** up to 50 items and 60 KB (the `keepalive` limit is 64 KB).
- **Caps:** 200 items; over it, the oldest page view or engage goes first. Items older than 24 hours are
  dropped (the server refuses them after 2 days).

| Response | Do |
| --- | --- |
| `200` | Remove the batch. Debug: log `rejected`. |
| `400`, `413` | Remove the batch (a script bug); log. |
| `401`, `403` | Wrong key, or this website isn't in the app's web domains. Keep the queue, stop sending on this page, `console.error` once. |
| No response, `404`, `405`, `502` from the link domain | Send the same batch to `https://attribution.ondropp.app/v1/web/e` (the link domain isn't routed or reachable). Not `503`: the collector sends that itself. |
| `429`, `5xx`, no response | Keep; retry after 2 s, doubling to 5 min, ± 20%. `Retry-After` wins when longer. |

### Consent

With `consent: "required"`, until `grant()`: only the click id is kept (`dl_click` and its cookie,
needed to credit an order); no visitor id, no session or queue in storage, nothing sent. Events on the
current page wait in memory (at most 50) and are sent on `grant()`. `revoke()` stops everything and
deletes all of the above, the click id included. The choice is stored in `dl_consent`.

### Testing

`web/test` (vitest + jsdom) covers: the landing fields and the contract shape (`contract/web/request.json`),
first touch, URL cleaning and cookies, sessions, SPA page views and engaged time, keepalive on hide,
validation, retries / Retry-After / reload, 400 and 403, the fallback host, consent, automated browsers,
and the script tag's attributes and stub queue.
