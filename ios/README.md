# Dropplink iOS SDK

Install attribution and deep links for apps promoted with Dropp links:

- Attributes each install to the Dropp link that drove it.
- Delivers the **deferred deep link** after a fresh install, so the first launch opens the right screen.
- Resolves **Universal Link** opens of Dropp links into the same deep link format.

iOS 13+, Swift 5.9+, no third-party dependencies. Behaviour is specified in
[docs/sdk-spec.md](../docs/sdk-spec.md), shared with the Android, Flutter and React Native SDKs.

- [Install](#install)
- [Keys](#keys)
- [Initialize](#initialize)
- [Universal Links](#universal-links)
- [API](#api)
- [Test your integration](#test-your-integration)
- [Troubleshooting](#troubleshooting)
- [Privacy](#privacy)
- [Developing the SDK](#developing-the-sdk)

## Install

### Swift Package Manager

Xcode → **File → Add Package Dependencies…**, enter the repository URL, pick version `0.1.0`, add the
`Dropplink` library to your app target. Or in `Package.swift`:

```swift
.package(url: "https://github.com/ondropp/dropplink-sdks.git", from: "0.1.0"),
// target dependencies:
.product(name: "Dropplink", package: "dropplink-sdks"),
```

### CocoaPods

```ruby
pod 'Dropplink', '~> 0.1.0'
```

## Keys

Create an **iOS** SDK key for your app in the Dropp dashboard. You get a key id (`ak_…`) and a secret.
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

When the app is already installed, tapping a Dropp link opens the app directly. Forward that URL to the
SDK so it can resolve the link's deep link path and record the open.

1. Register your link domain (e.g. `go.brand.com`) for the app in the Dropp dashboard. Dropp serves the
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

`handleDeepLink` ignores URLs that aren't `http(s)` and links that aren't Dropp links for your app (the
listener isn't called), so you can forward every URL your app receives. Links reported before init
finishes are sent right after it.

## API

```swift
public enum Dropplink {
    static let version: String                                  // "0.1.0"
    static func initialize(config: DropplinkConfig)
    static func setDeepLinkListener(_ listener: ((DeepLink) -> Void)?)
    static func handleDeepLink(_ url: URL)
    @discardableResult static func handleUserActivity(_ activity: NSUserActivity) -> Bool
    static var attribution: Attribution? { get }                // nil before the first successful init
    static var installId: String? { get }                       // nil before initialize
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

2. Paste the install id into **Dropp dashboard → Install debugger** to see the device's inits, its
   attribution and the click it matched.
3. Deferred deep link: delete the app, tap a Dropp link in Safari on the same network, install and launch
   from Xcode. The first init attributes the install (by fingerprint) and the listener receives the link
   with `isDeferred == true`.
4. Universal Link: with the app installed, tap a Dropp link in Notes or Messages (typing it into Safari's
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

No link delivered? Check the listener is set (it runs on the main thread), that Associated Domains has
your link domain, and that `onContinueUserActivity` / `scene(_:continue:)` forwards to the SDK.

## Privacy

The SDK sends only: a random install id (created by the SDK, not an advertising or vendor id), app and SDK
version, device model, OS version, locale, time zone and screen size. No IDFA, no contacts, no location,
no tracking. It stores the install id and last attribution in `UserDefaults(suiteName: "app.ondropp.dropplink")`.

`PrivacyInfo.xcprivacy` is bundled: `NSPrivacyTracking = false`, UserDefaults access with reason `CA92.1`,
and the install id declared as a Device ID used for analytics, not linked to the user and not used for
tracking. Reflect that in your App Store privacy details.

## Developing the SDK

```sh
cd ios
swift build
swift test          # runs on macOS; loads fixtures from ../contract
```

Tests reproduce the signing vectors in `contract/hmac/vectors.json`, check the init body against
`contract/init/request.ios.json`, decode every response fixture, and cover the retry rules with a fake HTTP
layer. `Example/` has a SwiftUI sample app.

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
