# Privacy: what the Dropplink SDKs collect

_For brands and their privacy counsel. Covers SDK version 0.2.0. The behaviour is defined in
[sdk-spec.md](./sdk-spec.md); if the two ever disagree, the spec is right and this page is a bug._

Related: [store-disclosures.md](./store-disclosures.md) (Google Play Data safety and Apple App Privacy answers)
and [consent.md](./consent.md) (wiring the SDKs to a consent banner, GPC, children's apps).

- [Roles](#roles)
- [Never collected](#never-collected)
- [Android and iOS (and Flutter / React Native)](#android-and-ios-and-flutter--react-native)
- [Web script](#web-script)
- [Web server half](#web-server-half)
- [Retention on our side](#retention-on-our-side)
- [Install matching by IP and device (fingerprinting)](#install-matching-by-ip-and-device-fingerprinting)
- [Deletion](#deletion)

## Roles

- **The brand** (you) decides to measure which links, creators and campaigns bring installs, visits and
  orders, chooses which SDK features to use and what to pass to them, and talks to its users. For your end
  users' data you are the **controller** (GDPR / UK GDPR) or the **business** (CCPA and other US state laws).
- **Dropplink** processes that data on your behalf and only on your instructions, to give you attribution and
  analytics for your own app and website. For end-user data we are a **processor** / **service provider**: we
  don't sell it, don't share it for cross-context behavioural advertising, and don't combine one brand's
  end-user data with another's. The details are in the data processing agreement you sign with us.
- You are responsible for your privacy notice, your cookie banner, collecting consent where the law needs it
  (see [consent.md](./consent.md)) and your store disclosures (see [store-disclosures.md](./store-disclosures.md)).
  The SDKs give you the switches; they can't know which law applies to a given user.

## Never collected

By any SDK, on any platform:

- Advertising identifiers (IDFA, Google Advertising ID / `AD_ID`), the iOS vendor id (IDFV), `ANDROID_ID`,
  IMEI, serial numbers, MAC addresses.
- Contacts, precise location (GPS, Wi-Fi, Bluetooth), photos, health, financial account data. (Our server
  records the country, region and city a request comes from, from Cloudflare's headers; never the IP itself.)
- Plain email addresses or phone numbers: `identify` hashes them on the device (SHA-256) and the plain values
  are never sent or stored. Event props and user ids that look like an email or a phone number are dropped by
  the SDK before sending (and again by the server).
- Anything from other apps installed on the device.

The Android library asks for one permission, `INTERNET`. The Play Install Referrer library it depends on adds
`com.google.android.finsky.permission.BIND_GET_INSTALL_REFERRER_SERVICE` (it lets the app read its own install
referrer from the Play Store). The SDK does not use `ACCESS_NETWORK_STATE`, does not declare or read `AD_ID`,
and has no other dependency.

## Android and iOS (and Flutter / React Native)

Flutter and React Native forward every call to the native SDK, so what's below applies to them unchanged
(their `sdkVersion` carries a `-flutter` / `-rn` suffix).

### What is sent, and when

All requests go over HTTPS to `attribution.ondropp.app` and are signed with your app's SDK key.

| When | Field | What it is |
| --- | --- | --- |
| Every app launch, after `initialize` (`/v1/init`) | `installId` | A random UUID created by the SDK on the first launch after install. Not derived from the device or any OS id; reinstalling the app creates a new one. |
| | `platform`, `appVersion`, `sdkVersion` | `android` / `ios`, your app's version name, the SDK version. |
| | `device.model` | Android `Build.MODEL` (e.g. `Pixel 8`); iOS hardware identifier (e.g. `iPhone16,1`). |
| | `device.osVersion`, `device.locale`, `device.timezone`, `device.screen` | OS version, language and region (e.g. `en-IN`), IANA time zone (e.g. `Asia/Kolkata`), screen width, height and pixel ratio. |
| | `installReferrer` (Android only, until the install is attributed) | The Google Play install referrer string for this install (what the Dropplink link put in the Play Store URL, e.g. `utm_source=…&click_id=c_…`), the click id parsed from it, and the referrer click / install begin timestamps. |
| | IP address | Not sent by the SDK, but seen by our server as the source of every request. Hashed there with a salt that changes daily; the plain address is not stored. See [fingerprinting](#install-matching-by-ip-and-device-fingerprinting). |
| | HTTP headers | The platform HTTP client's default `User-Agent`, plus the signing headers (`X-Key-Id`, `X-Timestamp`, `X-Signature`). |
| An App Link / Universal Link opens the app and you call `handleDeepLink` (`/v1/deeplink`) | `installId`, `url` | The full link URL that opened the app, including its query string. |
| You call `track` (`/v1/events`) | `eventId`, `name`, `ts`, `props`, `revenue` | A random event id, the event name you chose, the device time, up to 20 props you pass (strings ≤ 256 chars, numbers, booleans), and optionally `{ amount, currency, orderId }`. Sent in batches with the `installId`. |
| You call `identify` (`/v1/identify`) | `userId` | Your own user id (1–128 chars; refused if it looks like an email or phone number). Linked to the `installId`. |
| | `traits.emailHash`, `traits.phoneHash` | Only if you pass `email` / `phone`: lower-case hex SHA-256 of the normalised value (email trimmed and lower-cased; phone in E.164). Hashed data is still personal data: it identifies the same person to anyone who hashes the same address. |
| You call `logout` | `userId: null` | Unlinks the user from the install. |
| Server response | `attribution` | Which link / campaign / creator the install came from, stored on the device for `getAttribution()`. |

Nothing about consent is sent to the server: `setTrackingEnabled(false)` simply stops `track`, `identify` and
`logout` from producing requests. **It does not stop `/v1/init` or `/v1/deeplink`**: install attribution and
deep links keep working, so the install id, device fields, Android install referrer and IP still reach our
server on each launch. To stop those too, don't call `initialize` (see [consent.md](./consent.md)).

### What is stored on the device

| Platform | Where | Contents |
| --- | --- | --- |
| Android | `dropplink.json` in `Context.noBackupFilesDir` | `installId`, `attributed` flag, last `attribution`, `trackingEnabled` (only when `false`) |
| Android | `dropplink-queue.json`, same folder | Events and identify / logout calls not yet sent, plus the last identified user id. At most 1,000 events / 1 MB; events older than 7 days are dropped. |
| iOS | `UserDefaults(suiteName: "app.ondropp.dropplink")` | `installId`, `attributed`, `attribution`, `trackingEnabled` |
| iOS | `Application Support/Dropplink/dropplink-queue.json`, excluded from backup | As on Android |

The Android folder is never backed up, so a restored phone gets a new install id. On iOS the UserDefaults
suite follows the app's normal backup rules; the queue folder is excluded. Nothing is stored outside your
app's sandbox, and everything is removed when the app is uninstalled. The SDK key's secret is never stored by
the SDK (it is in your app's build config). `setTrackingEnabled(false)` empties the queue file and forgets the
last user id; the install id and attribution stay.

## Web script

The script tag (`/_d/s.js` on your link domain) or `init()` from `@ondropp/dropplink-web`. It does nothing in
automated browsers (`navigator.webdriver`), and nothing at all when the visitor's browser sends **Global
Privacy Control** (unless you set `respectGlobalPrivacyControl: false`; see [consent.md](./consent.md#us-global-privacy-control)).

### What is sent, and when

Batches are posted to your link domain's `/_d/e` (forwarded to us) or to `attribution.ondropp.app`, with
`credentials: "omit"` (the browser sends no cookies with them). Nothing is sent before consent when
`consent: 'required'` is set.

| Field | What it is |
| --- | --- |
| `key`, `sdkVersion` | Your public web key; the script version. |
| `visitorId` | A random UUID created by the script on first visit (after consent, with `consent: 'required'`). |
| Page view (`page_view` event, automatic) | `eventId`, `sessionId` (random, 30 minutes idle), `ts`, `path` (`location.pathname`, **without** the query string), page `title`. |
| First event of a session / page load | `referrer` (`document.referrer`, the full URL the browser reports, ≤ 1,024 chars), UTM tags from the landing URL, and the Dropplink `clickId` (`dropp_click_id`) the visitor landed with. |
| Engaged time (`engage`, automatic) | Milliseconds the page was visible, with its `path`. |
| `track(name, props)` | The event name and up to 20 props you pass; email- and phone-like values are dropped. |
| `identify(userId)` / `logout()` | Your own user id (unverified), or `null`. No email or phone on web. |
| IP address, `User-Agent` | Not sent by the script; seen by the server as part of every request. IP hashed with a daily salt. |

### What is stored in the browser

localStorage (this origin only; no expiry of its own, removed by `revoke()` or when the visitor clears site data):

| Key | Contents | Before consent (`consent: 'required'`) |
| --- | --- | --- |
| `dl_vid` | Visitor UUID | Not created |
| `dl_sess` | `{ id, last, click? }`: current session | Memory only |
| `dl_click` | `{ id, t }`: first Dropplink click id and when (used for 30 days) | Memory only, stored by `grant()` |
| `dl_q` | Items not yet sent (≤ 200, dropped after 24 h) | Memory only (≤ 50) |
| `dl_uid` | Last user id passed to `identify` | Memory only |
| `dl_consent` | `"granted"` / `"denied"` after `grant()` / `revoke()` | Written by `grant()` / `revoke()` |

Cookies (first-party, set by the script, `path=/`, `SameSite=Lax`, `Secure` on HTTPS, on your `cookieDomain` if set):

| Cookie | Contents | Lifetime | Purpose |
| --- | --- | --- | --- |
| `dropp_vid` | Visitor UUID | 395 days, renewed on each visit | Lets your server send the visitor id with orders (`readVisitorId`). Not set before consent. |
| `dropp_click_id` | The first Dropplink click id (`c_…`) | 30 days from the landing | Lets your server credit an order to the click (`readClickId`). Not set before consent. |

Safari and other browsers with tracking prevention may shorten script-set cookies and storage (Safari: 7 days).

**Before consent** (`consent: 'required'`) the script writes nothing to localStorage or cookies. The click id
the visitor landed with is kept in memory for the page; `grant()` stores it (with its original 30-day window)
and sends what waited, and `revoke()` forgets it. If the visitor leaves without answering, nothing remains on
their device. In the default mode (`consent: 'granted'`) everything is stored from the first page view.

Under Global Privacy Control nothing is stored (and anything stored on an earlier visit is cleared, except the
`dl_consent` answer); `getVisitorId()` and `getClickId()` return `null`. The click id is still removed from
the address bar.

## Web server half

`@ondropp/dropplink-web/server` runs on your backend with your secret server key. It sends what you give it:
orders and refunds (`eventId`, `name`, `ts`, `revenue`, `props`), with `userId`, `installId`, `clickId` or
`visitorId` to tie them to a person or a click. It stores nothing. `deleteUser(userId)` requests deletion.

## Retention on our side

| Data | Kept for |
| --- | --- |
| Link clicks | 30 days |
| Web sessions | 90 days |
| App and web events, web visitors, install activity | 395 days (13 months) |
| Daily IP salts | 9 days; once a salt is deleted, the IP hashes made with it can no longer be matched to an IP address |

Records not listed here (installs and their attribution, user ids linked with `identify`, email / phone hashes)
are governed by your data processing agreement and are removed by [deletion](#deletion).

## Install matching by IP and device (fingerprinting)

When an install arrives without a click id (always on iOS; on Android when the install referrer has none), the
server can fall back to matching it with a recent click by hashed IP address and device characteristics
(model, OS version, locale, time zone, screen). Attribution made this way is reported as `method:
"fingerprint"` with a `confidence`. It happens on our server; the SDKs send the same fields either way.

- **iOS:** Apple does not allow fingerprinting, whatever the App Tracking Transparency answer. The SDK's
  privacy manifest declares `NSPrivacyTracking = false` and no tracking domains. **That declaration is only
  safe if this fallback is turned off for your iOS app.** It is a server setting for your app in Dropplink,
  not something in the SDK; ask us to confirm it is off before you submit to the App Store. With it off, a
  fresh iOS install can't be matched to the click before it (iOS has no install referrer), so it is reported
  as organic and gets no deferred deep link; links opened through Universal Links still work and are recorded.
- **EU / UK:** treat this matching as needing the user's consent. Keep it off for apps used in the EU / UK
  unless you collect consent before calling `initialize`.
- **Children's apps:** keep it off (see [consent.md](./consent.md#apps-for-children)).

## Deletion

- **A known user:** your backend calls `deleteUser(userId)` (`DELETE /v1/s2s/users/:userId`, server half) and
  can poll `getDeletion(requestId)`. It deletes that user's identities, events, pending events, installs and
  web visitors.
- **On the device:** uninstalling the app removes everything the mobile SDKs stored. On the web, `revoke()`
  clears every key and both cookies.
- **Anonymous installs and visitors** (no `identify`): the SDKs have no deletion call by install id or visitor
  id yet. Their data expires under the retention above; for an individual request in the meantime, contact
  Dropplink support with the install id (`getInstallId()`) or visitor id.
