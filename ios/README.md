# Dropplink iOS SDK

Install attribution and deep links for apps promoted with Dropplink links:

- Attributes each install to the Dropplink link that drove it.
- Delivers the **deferred deep link** after a fresh install, so the first launch opens the right screen.
- Resolves **Universal Link** opens of Dropplink links into the same deep link format.
- Sends **in-app events** and links your **users** to their install, through an on-disk queue that
  survives being offline or killed.

iOS 13+, Swift 5.9+, no third-party dependencies. Behaviour is specified in
[docs/sdk-spec.md](../docs/sdk-spec.md), shared with the Android, Flutter and React Native SDKs.

- [Install](#install)
- [Keys](#keys)
- [Initialize](#initialize)
- [Universal Links](#universal-links)
- [Events, revenue and users](#events-revenue-and-users)
- [API](#api)
- [Test your integration](#test-your-integration)
- [Troubleshooting](#troubleshooting)
- [Privacy](#privacy)
- [Developing the SDK](#developing-the-sdk)

## Install

### Swift Package Manager

Xcode → **File → Add Package Dependencies…**, enter the repository URL, pick version `0.2.0`, add the
`Dropplink` library to your app target. Or in `Package.swift`:

```swift
.package(url: "https://github.com/ondropp/dropplink-sdks.git", from: "0.2.0"),
// target dependencies:
.product(name: "Dropplink", package: "dropplink-sdks"),
```

### CocoaPods

```ruby
pod 'Dropplink', '~> 0.2.0'
```

## Keys

Create an **iOS** SDK key for your app in the Dropplink dashboard. You get a key id (`ak_…`) and a secret.
Use the iOS key: an Android key fails with `platform_mismatch`.

Keep them out of source code. Put them in an xcconfig that isn't committed and read them through
Info.plist:

```
// Dropplink.xcconfig (add to .gitignore; set as the target's base configuration)
DROPPLINK_KEY_ID = ak_3f9c1e2a7b6d4c80
DROPPLINK_SECRET = …
```

```xml
<!-- Info.plist -->
<key>DropplinkKeyId</key>   <string>$(DROPPLINK_KEY_ID)</string>
<key>DropplinkSecret</key>  <string>$(DROPPLINK_SECRET)</string>
```

In CI, generate the xcconfig from secrets. The secret ships inside the app, as every client SDK key does:
signing stops casual abuse and replays, not a determined attacker. Never use it on a server.

## Initialize

Call `initialize` once, as early as possible, and set the listener right after. Both return immediately;
the network call runs in the background.

**SwiftUI**

```swift
import Dropplink
import SwiftUI

@main
struct MyApp: App {
    init() {
        let info = Bundle.main.infoDictionary ?? [:]
        Dropplink.initialize(config: DropplinkConfig(
            keyId: info["DropplinkKeyId"] as? String ?? "",
            secret: info["DropplinkSecret"] as? String ?? "",
            debug: false // true while integrating; never ship true
        ))
        Dropplink.setDeepLinkListener { link in
            // Main thread. link.path e.g. "/product/123", link.params ["variant": "red"]
            Router.shared.open(link.path, params: link.params)
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .onOpenURL { Dropplink.handleDeepLink($0) }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { Dropplink.handleUserActivity($0) }
        }
    }
}
```

**UIKit**

```swift
func application(_ application: UIApplication,
                 didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    Dropplink.initialize(config: DropplinkConfig(keyId: …, secret: …))
    Dropplink.setDeepLinkListener { link in self.router.open(link.path, params: link.params) }
    return true
}
```

The listener receives both kinds of link. If a link arrives before a listener is set, the latest one is
held in memory and delivered when you set it, so it's fine to set the listener once your router exists.

## Universal Links

When the app is already installed, tapping a Dropplink link opens the app directly. Forward that URL to the
SDK so it can resolve the link's deep link path and record the open.

1. Register your link domain (e.g. `go.brand.com`) for the app in the Dropplink dashboard. Dropplink serves the
   `apple-app-site-association` file for it.
2. Target → **Signing & Capabilities → + Associated Domains** → add `applinks:go.brand.com`.
3. Forward opens:

**SwiftUI**: the `onOpenURL` / `onContinueUserActivity` modifiers shown above.

**UIKit with scenes** (`SceneDelegate`):

```swift
func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
           options connectionOptions: UIScene.ConnectionOptions) {
    // Cold start from a Universal Link
    connectionOptions.userActivities.forEach { Dropplink.handleUserActivity($0) }
}

func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
    // App already running
    Dropplink.handleUserActivity(userActivity)
}
```

**UIKit without scenes** (`AppDelegate`):

```swift
func application(_ application: UIApplication, continue userActivity: NSUserActivity,
                 restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
    Dropplink.handleUserActivity(userActivity)
}
```

`handleDeepLink` ignores URLs that aren't `http(s)` and links that aren't Dropplink links for your app (the
listener isn't called), so you can forward every URL your app receives. Links reported before init
finishes are sent right after it.

## Events, revenue and users

```swift
// The funnel. Names are snake_case; up to 20 props of String, number, Bool or NSNull.
Dropplink.track("add_to_cart", props: ["sku": "TSHIRT-M", "qty": 1])
Dropplink.track("purchase", revenue: Revenue(amount: 499, currency: "INR", orderId: "A1023"))

// On sign-up and login: your own opaque user id. Email / phone are optional and hashed (SHA-256)
// on the device; the plain values never leave it. Same user id again is a no-op, so calling it on
// every launch is fine.
Dropplink.identify(userId: user.id, email: user.email, phone: user.phoneE164)

// On logout: events after it carry no user.
Dropplink.logout()

// Consent: false clears the queue and stops events and identify, remembered across launches.
// Install attribution and deep links keep working.
Dropplink.setTrackingEnabled(consented)
let enabled = Dropplink.isTrackingEnabled   // true by default
```

**Purchases that pay creators must be sent from your server** with `/v1/s2s/events` (server key).
Revenue sent with `track` is shown in the dashboard as **app-reported** only: the app's SDK key ships in
the app, so it can't be trusted for payouts. Use `track` for the funnel, your backend for money.

How it behaves:

- Calls return at once. Each entry is written to a queue file (`Application Support/Dropplink/`, excluded
  from backup) and sent 1 s after the last call, when the app goes to the background, and after each
  successful init. Nothing is sent before this launch's init succeeds.
- Entries keep their order, so an `identify` reaches the server before the events tracked after it.
- Offline or server errors: retried with backoff (1 s up to 5 min) while the app runs, and on the next
  launch. Each event has an id created at `track` time, so retries never double count.
- Checked on the device, with a debug log for anything dropped: names must match `^[a-z][a-z0-9_]{0,63}$`;
  bad prop keys, unsupported values and values that contain an email or are a phone number are dropped;
  strings are cut to 256 characters; `revenue.amount` must be ≥ 0 (rounded to 2 decimals) and `currency`
  ISO 4217 (`" inr"` becomes `"INR"`). User ids that are emails or phone numbers are refused.
- At most 1,000 events / 1 MB wait in the queue; the oldest events without revenue go first. Events older
  than 7 days are dropped (the server rejects them).

```
Dropplink: track add_to_cart (queued, 3 waiting)
Dropplink: events 200: 3 accepted, 0 duplicates, 0 rejected
Dropplink: event "Add To Cart" dropped: name must be snake_case, e.g. add_to_cart
Dropplink: identify user_8812 sent
```

## API

```swift
public enum Dropplink {
    static let version: String                                  // "0.2.0"
    static func initialize(config: DropplinkConfig)
    static func setDeepLinkListener(_ listener: ((DeepLink) -> Void)?)
    static func handleDeepLink(_ url: URL)
    @discardableResult static func handleUserActivity(_ activity: NSUserActivity) -> Bool
    static var attribution: Attribution? { get }                // nil before the first successful init
    static var installId: String? { get }                       // nil before initialize

    static func track(_ name: String, props: [String: Any]? = nil, revenue: Revenue? = nil)
    static func identify(userId: String, email: String? = nil, phone: String? = nil)
    static func logout()
    static func setTrackingEnabled(_ enabled: Bool)
    static var isTrackingEnabled: Bool { get }                  // true by default
}

public struct Revenue {
    init(amount: Double, currency: String, orderId: String? = nil)
}

public struct DropplinkConfig {
    init(keyId: String, secret: String, debug: Bool = false,
         baseURL: URL = URL(string: "https://attribution.ondropp.app")!,
         platformWrapper: String? = nil)                        // set only by the Flutter / RN packages
}

public struct DeepLink {
    let path: String                 // "/product/123"
    let params: [String: String]
    let url: URL?                    // the opened URL; nil for the deferred link
    let isDeferred: Bool             // true only for the link delivered after a fresh install
}

public struct Attribution: Codable {
    let type: String                 // "attributed" | "organic"
    let method: String               // "fingerprint" on iOS | "install_referrer" | "none"
    let clickId, linkId, campaignId, creatorId, source, attributedAt: String?
    let confidence: Double?
}
```

All calls are thread-safe, never throw and never block on the network. `attribution` is cached on disk,
so it's available immediately on later launches.

## Test your integration

1. Set `debug: true` and run the app. In Console.app filter by `subsystem:app.ondropp.dropplink` (or watch
   Xcode's console):

   ```
   Dropplink: install id 0b9e8d7c-6a5f-4e3d-8c2b-1a0f9e8d7c6b (paste into Dropplink → Install debugger)
   Dropplink: init 200 attributed via fingerprint, link 6711a0…, deep link /product/123
   ```

2. Paste the install id into **Dropplink dashboard → Install debugger** to see the device's inits, its
   attribution and the click it matched.
3. Deferred deep link: delete the app, tap a Dropplink link in Safari on the same network, install and launch
   from Xcode. The first init attributes the install (by fingerprint) and the listener receives the link
   with `isDeferred == true`.
4. Universal Link: with the app installed, tap a Dropplink link in Notes or Messages (typing it into Safari's
   address bar doesn't trigger Universal Links). The listener receives it with `isDeferred == false`.

## Troubleshooting

With `debug: true`, failures are logged with the server's error code:

| Log | Cause | Fix |
| --- | --- | --- |
| `invalid config, SDK disabled: …` | Empty `keyId` / `secret`, or `keyId` doesn't start with `ak_`. Logged even without `debug`. | Check the xcconfig values reach Info.plist (`$(DROPPLINK_KEY_ID)` not substituted means the xcconfig isn't set on the target). |
| `401 invalid_key` | The key is unknown or revoked, or its app was deleted. SDK stops until next launch. | Copy the key again from the dashboard. |
| `400 platform_mismatch` | An Android key in an iOS app. | Use the app's **iOS** key. |
| `401 bad_signature` | Wrong secret for this key id. | Copy the secret again; check for trailing spaces. |
| `401 stale_timestamp` ("Device clock looks wrong") | The device clock is more than 5 minutes off. Retried with backoff. | Set the device to automatic time. |
| `400 validation_failed` | The server rejected the body. Logged with `details`. | Likely an SDK bug: report it with the log line. |
| `network error` / `5xx` / `429` | Retried 3 times (1 s, 2 s, 4 s), then again on next launch. | Nothing; check connectivity or `baseURL`. |
| `… is not a Dropplink link for this app` | `handleDeepLink` got a URL that isn't one of your app's links. | Expected for other URLs. |
| `… has no deep link path` | The link was opened but has no deep link path set. | Set a deep link path on the link in the dashboard. |
| `event "…" dropped: …` / `prop … dropped: …` | `track` was called with an invalid name, prop or revenue. | Fix the call; the log says which rule. |
| `events and identify paused until next launch` | `/v1/events` or `/v1/identify` got a `401` (or an unexpected `4xx`). Events stay queued. | Check the key and secret, as for init. |
| `events will be retried in … s` | Offline or a server error; the queue backs off up to 5 min. | Nothing. |

No link delivered? Check the listener is set (it runs on the main thread), that Associated Domains has
your link domain, and that `onContinueUserActivity` / `scene(_:continue:)` forwards to the SDK.

## Privacy

For install attribution the SDK sends only: a random install id (created by the SDK, not an advertising or
vendor id), app and SDK version, device model, OS version, locale, time zone and screen size. No IDFA, no
contacts, no precise location (the server records country, region and city), no tracking. It stores the install id, last attribution and the
`setTrackingEnabled` choice in `UserDefaults(suiteName: "app.ondropp.dropplink")`.

If you call `track` / `identify`, it also sends the events and props you pass, your user id and SHA-256
hashes of the email / phone you pass (never the plain values; they aren't stored either). Waiting entries
are kept in `Application Support/Dropplink/dropplink-queue.json`, excluded from backup.
`setTrackingEnabled(false)` deletes them and stops sending.

`PrivacyInfo.xcprivacy` is bundled: `NSPrivacyTracking = false`, UserDefaults access with reason `CA92.1`,
the install id declared as a Device ID (analytics and app functionality, linked to the user, not tracking),
and Coarse Location, User ID, Email Address, Phone Number, Product Interaction and Purchase History (analytics, linked to the
user, not tracking) for apps that use `identify` and `track`. `NSPrivacyTracking = false` holds only while the
server's IP + device matching is off for your iOS app.

Full list of what is sent and stored, and retention: [docs/privacy.md](../docs/privacy.md). App Store privacy
answers per feature: [docs/store-disclosures.md](../docs/store-disclosures.md). Consent (EU / UK, children):
[docs/consent.md](../docs/consent.md).

## Developing the SDK

```sh
cd ios
swift build
swift test          # runs on macOS; loads fixtures from ../contract
```

Tests reproduce the signing vectors in `contract/hmac/vectors.json`, check the init, events and identify
bodies against `contract/`, decode every response fixture, run `contract/events/invalid/` through local
validation, and cover the retry rules and the event queue with a fake HTTP layer and a manual scheduler. `Example/` has a SwiftUI sample app.

`pod lib lint Dropplink.podspec --allow-warnings` validates the CocoaPods build.

Release note: this package lives in `ios/` of a monorepo. SwiftPM resolves a remote package from the
repository root and CocoaPods trunk resolves podspec paths from the repository root, so publishing needs
either a root-level `Package.swift` / `Dropplink.podspec` pointing at `ios/Sources/Dropplink`, or a mirror
repository containing just `ios/`. Local installs (`Add Local…`, `pod 'Dropplink', :path => '…/ios'`) work
as is.

Layout of `Sources/Dropplink/`:

| File | |
| --- | --- |
| `Dropplink.swift`, `DropplinkConfig.swift`, `Models.swift` | Public API |
| `DropplinkCore.swift` | Lifecycle, deep link queue, state |
| `APIClient.swift`, `RetryPolicy.swift`, `Signer.swift`, `HTTPClient.swift` | Signed requests and retries |
| `InitBody.swift` | `/v1/init` body and device details |
| `Storage.swift`, `DeepLinkDispatcher.swift`, `Logger.swift` | Persistence, listener delivery, logging |
| `Events.swift` | `Revenue` and the queue / wire types of `/v1/events` and `/v1/identify` |
| `EventValidation.swift` | Local checks of `track` and `identify` (spec §11), PII rules, trait hashing |
| `EventQueue.swift` | Caps, drop order, pruning and batching; the queue file |
| `EventPipeline.swift`, `Scheduler.swift` | Flush scheduling, the response table and backoff |
